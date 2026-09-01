# zeta-lite benchmarks

Reproducible throughput, concurrency, and stability measurements for the
zeta-lite wasm build. These are the numbers behind the technical report's
evaluation section; everything here runs against the **published** artifact
(`playground/pkg-web/`, fetched via `scripts/fetch-artifact.sh`) so the results
are reproducible without engine-source access.

There are two runnable benchmarks plus one recorded soak-test report:

| File | Runs where | Measures |
|---|---|---|
| `playground/bench.html` | a real browser (Chrome/Firefox) | throughput ceilings + SI conflict detection, in the actual target |
| `playground/bench.mjs` | `bun` (native, CLI) | the same measurements as a native upper-bound reference |
| `playground/endurance.html` | a real browser tab (foreground) | 10-min in-browser soak: throughput stability, linear-memory growth, **real OPFS** snapshot round-trip |
| `docs/benchmarks/endurance-fast.json` | recorded output of the monorepo soak harness (native) | sustained-load stability, **per-op-class latency**, memory, snapshot cost |
| `docs/benchmarks/endurance-browser-firefox.json` | recorded output of `endurance.html` (Firefox) | the in-browser soak result (complete JSON) |
| `docs/benchmarks/endurance-browser-chrome.json` | recorded output of `endurance.html` (Chrome) | the in-browser soak result (complete JSON) |

> **One "op" is one API call** — a single `execMut` (one autocommitted INSERT/
> UPDATE/DELETE), one `query` (a point SELECT by primary key), or one explicit
> `begin`/`execMut`/`commit` transaction, as labelled per line. This is a
> single-row OLTP unit, **not** a batch and not a scan. The engine is
> **single-threaded** — there is no parallelism; `crossOriginIsolated` is
> `false` and no `SharedArrayBuffer` is used.

> **Browser timer clamping — read before quoting sub-ms latencies.** Browsers
> clamp `performance.now()` to coarse resolution (~1 ms in Firefox) when a page is
> **not** cross-origin-isolated, as a timing-side-channel mitigation. zeta-lite is
> deliberately not COI (no `SharedArrayBuffer`), so any **per-op latency measured
> in-browser is unreliable** — sub-ms ops read as ~0 or snap to ~1000 µs. Per-op
> latency therefore comes only from the **native** soak harness
> (`endurance-fast.json`), where the timer is unclamped. Everything measured over
> intervals well above the clamp — throughput (5 s windows), linear-memory
> footprint (`byteLength`, not a timer), and OPFS round-trip cost (tens of ms) — is
> valid in-browser.

## Running them

```bash
# 0. Fetch the published wasm once (populates playground/pkg-web/, gitignored).
./scripts/fetch-artifact.sh

# 1. Native (CLI) throughput — needs bun (Node's file:// wasm fetch is unimplemented).
bun playground/bench.mjs

# 2. In-browser throughput — serve over http:// (wasm won't load from file://).
python3 -m http.server -d playground 8080
#    → open http://localhost:8080/bench.html, click "Run benchmark", copy results.

# 3. In-browser soak (10 min) — same server; keep the tab FOREGROUND.
#    → open http://localhost:8080/endurance.html, click "Run soak", copy results.
#      (background tabs throttle timers and invalidate a soak)
```

## Recorded results

### Environment

- **CPU:** AMD Ryzen AI MAX+ 395 (32 threads); engine uses one.
- **Artifact:** `zeta_wasm_bg.wasm`, 10,144,082 bytes raw / **2.87 MB gzipped**
  (gzip = transfer size; PGlite reference ~3.0 MB).
- **Runtimes:** Chrome 152 and Firefox 154 (browser targets, V8 + SpiderMonkey);
  bun 1.3.14 (native reference). Chrome captured via headless CDP; the GUI Chrome
  run matched it within run-to-run noise.
- Numbers vary a few percent run-to-run; these are representative single runs,
  not averaged. Re-run to reproduce the shape, not the last digit.

### Throughput and concurrency (`bench.html` / `bench.mjs`)

Each line is 50,000 ops unless noted. **The browser is within ~5–15% of native
bun** — the wasm form factor costs very little here, and the two browser engines
agree closely.

| Measurement | Chrome 152 | Firefox 154 | bun 1.3.14 (native ref) |
|---|---:|---:|---:|
| 1. serial INSERT (autocommit / op) | 121,743 ops/s | 98,619 ops/s | 116,474 ops/s |
| 2. INSERT inside one txn (amortized) | 77,030 ops/s | 77,882 ops/s | 84,327 ops/s |
| 3. point SELECT (PK lookup) | 267,953 ops/s | 282,486 ops/s | 315,345 ops/s |
| 4. overlapping SI txns, K=8, disjoint keys | 60,286 ops/s | 58,824 ops/s | 62,568 ops/s |
| 5. sustained mixed R/W (10 s wall-clock) | 228,284 ops/s | 221,399 ops/s | 240,841 ops/s |
| &nbsp;&nbsp;— per-window drift over the 10 s | **2.2%** | **1.1%** | 3.8% |

### Snapshot-isolation conflict detection (`bench.html` line 4b)

The concurrency claim, demonstrated rather than asserted. Two transactions open
on overlapping snapshots both `UPDATE` the **same** row; under snapshot
isolation exactly one may commit.

| | Chrome 152 | Firefox 154 | bun 1.3.14 |
|---|---:|---:|---:|
| Rounds (A and B both update row 1) | 5,000 | 5,000 | 5,000 |
| A commits | 5,000 | 5,000 | 5,000 |
| B commits | 0 | 0 | 0 |
| **B aborted (write-write conflict)** | **5,000 / 5,000** | **5,000 / 5,000** | **5,000 / 5,000** |

Complementary case (line 4): 8 transactions open concurrently on distinct
snapshots writing **disjoint** keys → all 40,000 commit, 0 conflicts. Overlap is
allowed; only true write-write conflicts abort. A single-connection browser
engine (e.g. PGlite) cannot express this workload at all — there is no second
open transaction to conflict with.

### Sustained-load stability (`endurance-fast.json`)

Recorded output of the monorepo soak harness (`crates/zeta-wasm/harness/
endurance.mjs`, `--fast` mode: 120 s sustained phase, 20k rows/table, 200 s
total). The harness **rate-limits to a deliberately modest 1,500 ops/s** — the
goal is stability under a realistic browser-app load, **not** peak throughput
(peak is the table above). Verbatim highlights:

- **Throughput stability: 1.00** — first quarter 1,500 ops/s → last quarter
  1,500 ops/s (floor for PASS is 0.70). No drift over the run.
- **Per-op-class latency** (mean / p50 / p99, µs):

  | class | ops | mean | p50 | p99 |
  |---|---:|---:|---:|---:|
  | point_read | 111,208 | 5 | 4 | 8 |
  | range_scan | 27,167 | 48 | 46 | 74 |
  | insert | 9,120 | 10 | 9 | 24 |
  | update | 18,137 | 13 | 12 | 37 |
  | delete | 5,378 | 20 | 19 | 63 |
  | txn (begin+write+commit) | 8,990 | 56 | 51 | 158 |

  A 4µs point read implies a single-thread read ceiling on the order of 10⁵–10⁶
  ops/s, consistent with the 282k–315k point-SELECT throughput above.

- **Memory — read this carefully.** During the *sustained* phase RSS grows
  +460 MB. This is **data-driven, not a leak**: the workload only ever inserts
  (new rows + in-RAM MVCC version log + versions pinned by a long-lived reader
  during a 20 s window), and wasm linear memory never shrinks. The **leak test
  is the settle phase**: 30 s of read-only load grows RSS **+8 MB** (budget 32),
  i.e. flat. No allocator leak.
- **Snapshot round-trip:** 8 export→rehydrate integrity cycles, avg **44 ms**,
  largest blob 1.99 MB. **Zero SQL errors or invariant violations** across the
  whole run (4,250 branch create/merge/drop cycles included).

The full curve (per-5s buckets, snapshot cycles, settle RSS series) is in
`endurance-fast.json`.

### In-browser soak (`endurance-browser-firefox.json`, `endurance-browser-chrome.json`)

`playground/endurance.html` ports that harness to a real browser tab — same
schema and 62/15/5/10/3/5 workload — with three browser-appropriate changes: it
measures the **wasm linear-memory footprint** (`memory.buffer.byteLength`) instead
of process RSS, paces itself in event-loop-friendly slices instead of busy-waiting,
and exercises a **real OPFS** save→load→open round-trip each snapshot cycle. Full
10-minute sustained runs in **Chrome 152 and Firefox 154** (20k rows/table,
1,500 ops/s, 825 s total each including branch/drain/settle) passed all criteria,
with the two engines agreeing closely:

- **Throughput stability: 1.00** in both browsers — first quarter 1,502 ops/s → last
  quarter 1,501 ops/s over **900,000 sustained ops** (Chrome and Firefox alike). Flat.
- **Leak check: +0 MB** over the 60 s read-only settle (budget 32), in both.
  Sustained-phase linear memory grew 131 → 195 MB — data-driven (insert-only +
  reader-pinned versions), the same pattern as native and expected; the settle
  phase, the actual leak test, is perfectly flat.
- **Real OPFS snapshot round-trip** (the measurement native cannot make), averaged
  over 10 cycles as the blob grew to ~4.8 MB — export / OPFS save / OPFS load /
  open+verify: **38 / 48 / 5 / 85 ms** (Firefox), **34 / 19 / 2 / 78 ms** (Chrome).
  A full durable round-trip is sub-200 ms in both; Chrome's OPFS writes are ~2.5×
  faster than Firefox's (a browser property, not an engine one).
- **Branch + snapshot churn** with **zero SQL errors or invariant violations** —
  6,793 branch merge/drop cycles and 10 OPFS round-trips in Firefox, 7,424 cycles
  and 10 round-trips in Chrome.
- **Per-op latency is intentionally omitted here** — browsers clamp
  `performance.now()` on non-COI pages (Firefox ~1 ms, Chrome ~100 µs), so sub-clamp
  timings quantize and are meaningless. Per-op latency is the native harness's job
  (`endurance-fast.json`, table above); the metrics quoted here are all measured
  over intervals well above the clamp.

## Notes on methodology

- `bench.mjs` and `bench.html` are intentionally the **same six measurements**
  so the browser/native gap is a like-for-like comparison.
- The soak harness itself lives in the closed monorepo (it drives four seeded
  tables, a long-lived reader txn, periodic snapshot cycles, and branch churn);
  only its recorded JSON output is committed here. The two public benches
  (`bench.*`) reproduce the throughput and SI-conflict results independently.
- These are single-run figures on one machine. For a paper, report the machine,
  the artifact gzip size, and the op definition alongside any number — a bare
  "ops/s" is meaningless without the op.
