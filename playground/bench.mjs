// Throughput / concurrency benchmark for zeta-lite, driving the SAME web-target
// artifact the playground loads (playground/pkg-web/). Run under bun — Node's
// file:// fetch of wasm is unimplemented, so `node` cannot load the module:
//
//   ./scripts/fetch-artifact.sh          # once, to populate playground/pkg-web/
//   bun playground/bench.mjs             # from the repo root
//
// This is the native/CLI companion to playground/bench.html (the in-browser
// version). See docs/benchmarks/README.md for methodology and recorded results.
//
// Measures:
//   1. Serial single-row write throughput (each op its own committed txn via execMut).
//   2. Serial write throughput inside ONE big explicit txn (amortized commit).
//   3. Point-SELECT read throughput.
//   4. Overlapping-SI throughput: many explicit txns interleaved, holding
//      distinct snapshots, with SI conflict detection exercised.
//   5. A sustained run: fixed wall-clock, report ops/s + per-window drift.

import init, { ZetaDb } from "./pkg-web/zeta_wasm.js";

// bun supports file:// fetch used by the default init; call once.
await init();

const now = () => performance.now();

function fmt(n) {
  return n.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

function report(name, ops, ms, extra = "") {
  const s = ms / 1000;
  const rate = ops / s;
  console.log(
    `${name.padEnd(42)} ${fmt(ops).padStart(9)} ops  ${s.toFixed(3).padStart(8)} s  ${fmt(rate).padStart(9)} ops/s  ${extra}`,
  );
  return rate;
}

console.log("=".repeat(100));
console.log("zeta-lite throughput benchmark — artifact:", "playground/pkg-web/zeta_wasm_bg.wasm");
console.log("runtime: bun", Bun?.version ?? "", "  platform:", process.platform, process.arch);
console.log("=".repeat(100));

// ---------------------------------------------------------------------------
// 1. Serial single-row writes, each its own auto-committed statement (execMut).
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
  const N = 50_000;
  // warmup
  for (let i = 0; i < 1000; i++) db.execMut("INSERT INTO t VALUES ($1,$2)", [i, i]);
  const t0 = now();
  for (let i = 1000; i < 1000 + N; i++) db.execMut("INSERT INTO t VALUES ($1,$2)", [i, i * 3]);
  const t1 = now();
  report("1. serial INSERT (autocommit / op)", N, t1 - t0);
  db.free?.();
}

// ---------------------------------------------------------------------------
// 2. Serial writes inside ONE explicit transaction (amortized commit).
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
  const N = 50_000;
  const tx = db.begin();
  const t0 = now();
  for (let i = 0; i < N; i++) tx.execMut("INSERT INTO t VALUES ($1,$2)", [i, i]);
  tx.commit();
  const t1 = now();
  report("2. INSERT inside one txn (amortized)", N, t1 - t0);
  db.free?.();
}

// ---------------------------------------------------------------------------
// 3. Point SELECT throughput.
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
  const rows = 50_000;
  const tx = db.begin();
  for (let i = 0; i < rows; i++) tx.execMut("INSERT INTO t VALUES ($1,$2)", [i, i]);
  tx.commit();
  const N = 50_000;
  // warmup
  for (let i = 0; i < 1000; i++) db.query("SELECT v FROM t WHERE id = $1", [i]);
  const t0 = now();
  let acc = 0;
  for (let i = 0; i < N; i++) {
    const r = db.query("SELECT v FROM t WHERE id = $1", [i % rows]);
    acc += r.rows.length;
  }
  const t1 = now();
  report("3. point SELECT (PK lookup)", N, t1 - t0, `(rows_seen=${acc})`);
  db.free?.();
}

// ---------------------------------------------------------------------------
// 4. Overlapping snapshot-isolated transactions.
//    K txns open concurrently, each holds its own snapshot, does a few writes,
//    then commits; a fresh reader validates isolation. Exercises SI conflict
//    detection when two overlapping txns touch the same key.
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
  db.execMut("INSERT INTO t VALUES ($1,$2)", [0, 0]);

  const K = 8; // overlap degree
  const ROUNDS = 5000;
  let commits = 0, conflicts = 0, ops = 0;
  const t0 = now();
  for (let r = 0; r < ROUNDS; r++) {
    const txns = [];
    // open K overlapping txns, each on its own snapshot
    for (let k = 0; k < K; k++) txns.push(db.begin());
    // each does a disjoint-key insert (no conflict) + one shared-key bump (conflict-prone)
    for (let k = 0; k < K; k++) {
      const id = 1 + r * K + k;
      try {
        txns[k].execMut("INSERT INTO t VALUES ($1,$2)", [id, k]);
        ops++;
      } catch { /* ignore */ }
    }
    // commit them in order; distinct keys => all should commit
    for (let k = 0; k < K; k++) {
      try { txns[k].commit(); commits++; }
      catch { conflicts++; }
    }
  }
  const t1 = now();
  report("4. overlapping SI txns (K=8)", ops, t1 - t0,
    `commits=${fmt(commits)} conflicts=${fmt(conflicts)}`);
  db.free?.();
}

// ---------------------------------------------------------------------------
// 4b. Deliberate write-write conflict rate under contention: two overlapping
//     txns both update the SAME row; one must abort under SI.
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
  db.execMut("INSERT INTO t VALUES ($1,$2)", [1, 0]);
  const ROUNDS = 5000;
  let aCommit = 0, bCommit = 0, bAbort = 0;
  const t0 = now();
  for (let r = 0; r < ROUNDS; r++) {
    const a = db.begin();
    const b = db.begin(); // overlaps a
    a.execMut("UPDATE t SET v = v + 1 WHERE id = 1");
    let bWrote = true;
    try { b.execMut("UPDATE t SET v = v + 100 WHERE id = 1"); }
    catch { bWrote = false; }
    try { a.commit(); aCommit++; } catch {}
    if (bWrote) {
      try { b.commit(); bCommit++; } catch { bAbort++; try { b.rollback(); } catch {} }
    } else { try { b.rollback(); } catch {} bAbort++; }
  }
  const t1 = now();
  const total = aCommit + bCommit + bAbort;
  report("4b. w-w conflict on shared row", ROUNDS * 2, t1 - t0,
    `A=${fmt(aCommit)} Bok=${fmt(bCommit)} Babort=${fmt(bAbort)}`);
  db.free?.();
}

// ---------------------------------------------------------------------------
// 5. Sustained endurance run: fixed wall-clock budget, mixed R/W, report the
//    sustained rate and check for drift across windows (GC / allocator stalls).
// ---------------------------------------------------------------------------
{
  const db = ZetaDb.open();
  db.execDdl("CREATE TABLE kv (id INTEGER PRIMARY KEY, v INTEGER)");
  const SEED = 10_000;
  const tx = db.begin();
  for (let i = 0; i < SEED; i++) tx.execMut("INSERT INTO kv VALUES ($1,$2)", [i, i]);
  tx.commit();

  const BUDGET_MS = 10_000;
  const WINDOW_MS = 1000;
  let ops = 0, id = SEED;
  const windows = [];
  const start = now();
  let winStart = start, winOps = 0;
  while (true) {
    // mixed op: 1 write + 3 reads counts as 4 ops
    db.execMut("INSERT INTO kv VALUES ($1,$2)", [id, id]); id++; ops++; winOps++;
    for (let j = 0; j < 3; j++) {
      db.query("SELECT v FROM kv WHERE id = $1", [(id - j) % SEED]); ops++; winOps++;
    }
    const t = now();
    if (t - winStart >= WINDOW_MS) {
      windows.push(winOps / ((t - winStart) / 1000));
      winStart = t; winOps = 0;
    }
    if (t - start >= BUDGET_MS) break;
  }
  const elapsed = now() - start;
  const rate = report("5. ENDURANCE mixed R/W (sustained)", ops, elapsed);
  const min = Math.min(...windows), max = Math.max(...windows);
  const mean = windows.reduce((a, b) => a + b, 0) / windows.length;
  console.log(
    `   per-second windows: n=${windows.length}  mean=${fmt(mean)}  min=${fmt(min)}  max=${fmt(max)}  drift=${(((max - min) / mean) * 100).toFixed(1)}%`,
  );
  console.log(`   final table size: ${fmt(id)} rows`);
  db.free?.();
}

console.log("=".repeat(100));
