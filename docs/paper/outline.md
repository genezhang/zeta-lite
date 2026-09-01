# Zeta-Lite: A Concurrent, Branchable In-Browser SQL Database for Agentic Memory

**Working title / arXiv outline.** Status: outline agreed, prose drafted (see `draft.md`).

> **Title note.** The title leads with position (in-browser SQL for agentic
> memory) and folds the two distinguishing systems claims into it as modifiers —
> **concurrent** (overlapping SI) and **branchable** (COW database branching).
> Kept to two adjectives on purpose: three tipped it into a feature list, and
> "feature-complete" was the weakest/most-pokeable lead, so completeness and the
> 2.87 MB size are carried in the abstract and §7 instead of the title. To keep
> the *systems* spine — and avoid reading as a pure application paper — §1 opens on
> the systems contribution and §3/§4/§7 stay firmly mechanism-and-evaluation.
> "Agentic memory" is the framing and the bridge to zengram-lite; it is not the
> unit of evaluation.

## Framing decisions (locked)

- **Spine:** systems/architecture. The contribution is the *engine* — a
  log-centric async-MVCC core that sustains overlapping, snapshot-isolated
  transactions on one wasm thread, delivering a full Postgres-compatible surface
  as a ~2.87 MB gzipped browser artifact. Feature breadth and the agentic-storage
  use case are *evidence the architecture holds up*, not the headline.
- **Positioning:** standalone paper. One forward cross-reference to zengram-lite
  (the agentic memory system built on this engine) in §6's last paragraph, no
  dependency. Clickgraph is unrelated and not mentioned.
- **Novelty (two-legged, defensible):** (i) a *feature-complete* PG surface —
  JSONB+GIN, FTS, HNSW vector, SQL/PGQ, multi-DB, and **copy-on-write database
  branching** — in a ~2.87 MB browser artifact, and (ii) *real concurrency*:
  overlapping snapshot-isolated transactions on a single wasm thread, a semantic
  no other in-browser SQL engine provides. The argument: completeness and
  concurrency are usually traded against size; the log-centric MVCC design
  collapses that trade-off. No single primitive (MVCC, wasm-SQL, HNSW) need be
  novel — the combination-under-constraint is.
- **Database branching is a headline feature, not a footnote.** COW branching of
  the *whole database* (fork → isolated writes → merge/rebase) is rare in any
  SQL engine — Postgres has none natively; Neon and Dolt make it their marquee
  capability at the storage/server layer — and, as far as we know, **no other
  in-browser SQL engine offers it at all**. It falls directly out of the
  log-centric MVCC core (a branch is a fork timestamp over the shared log), so
  zeta-lite gets at ~2.87 MB what specialized servers are built around. Its
  agentic use — cheap speculative forks an agent can explore and discard or
  merge — is a recurring thread, developed in §3.6 (mechanism) and §6.2
  (application).
- **Evaluation scope:** option (b) — size + functional coverage, PLUS the
  overlapping-SI concurrency result and the sustained-load stability soak. No raw
  throughput drag-race vs PGlite/SQLite (apples-to-oranges); the concurrency
  comparison is *capability* ("PGlite structurally cannot run this workload"),
  not speed.

---

## Abstract
Browser SQL is a real deployment target (PGlite established demand); prevailing
in-browser Postgres builds inherit a single-connection, blocking backend.
Zeta-lite compiles the *same* engine as the Zeta server to
`wasm32-unknown-unknown` and reaches the platform through JS bindings (not WASI),
keeping a log-centric MVCC core that lets transactions overlap under snapshot
isolation on one thread. Claim: full PG-compatible SQL surface — including
**copy-on-write whole-database branching**, a feature rare in server engines and
absent from other in-browser ones — plus overlapping SI and streaming cursors, at
~2.87 MB gzipped (smaller than PGlite ~3 MB), with snapshot-to-OPFS durability
requiring no worker / SharedArrayBuffer / COOP-COEP. v0.1 preview.

## 1. Introduction
- The browser as a first-class database host (local-first, privacy, offline,
  agentic clients).
- The gap: existing in-browser Postgres builds are structurally
  single-connection / blocking.
- **Contributions** (the two-legged claim above, stated as one collapsed
  trade-off + supporting bullets):
  1. Overlapping-SI transactions on a single wasm thread, with the honest
     boundary (transaction-lifetime overlap, not sub-statement parallelism).
  2. A complete PG-compatible SQL surface at ~2.87 MB gzip, enumerated.
  3. **Copy-on-write database branching in the browser** — whole-database fork /
     merge / rebase, a capability rare in any SQL engine and (to our knowledge)
     absent from every other in-browser one — as a near-free consequence of the
     MVCC log, and its use as speculative exploration state for agents.
  4. Snapshot-to-OPFS durability without workers / SharedArrayBuffer / COOP-COEP.
  5. A design-space account of why the browser host interface is JS bindings, not
     WASI (§4).
  6. Position in the Zeta family — one codebase, smallest form factor.

## 2. Background & Related Work
- PGlite / Postgres-in-wasm: single-connection backend; the honest contrast.
- wa-sqlite / SQLite-wasm / DuckDB-wasm: OPFS VFS approaches, row vs columnar.
- MVCC & snapshot isolation: Berenson et al. (SI); PostgreSQL SI/SSI.
- wasm in data systems: prior art compiling engines to wasm.
- **Database branching prior art**: Dolt (Git-for-data, versioned storage
  engine), Neon (copy-on-write branches at the storage layer for Postgres),
  PlanetScale/MySQL branching (schema/deploy workflow). Position: all are
  server/storage-tier features; none run in-browser, and zeta-lite's is a direct
  consequence of the MVCC log rather than a bespoke subsystem.
- Delta: nobody offers overlapping SI transactions **or in-browser database
  branching** in a browser SQL engine at this size.

## 3. System Architecture
- **3.1 The Zeta family & the compile-down bet** — one engine, feature-gated
  form factors (embedded → OLTP/HTAP server → cluster → OLAP); zeta-lite =
  `--no-default-features --features wasm`, Memory backend only. Figure: family,
  zeta-lite highlighted.
- **3.2 Log-centric async MVCC core** — log as source of truth; versioned rows;
  read/commit timestamps; SI conflict detection. The section that earns the
  thesis.
- **3.3 Query path** — same parser/planner/optimizer/executor as the server;
  what "same SQL" concretely means.
- **3.4 Streaming cursors** — O(batch) not O(result) memory; why it matters under
  wasm linear-memory limits.
- **3.5 The Memory backend** — in-memory tables as the storage substrate.
- **3.6 Database branching as a consequence of the log** — the mechanism, and why
  it is nearly free here. A branch is a **fork timestamp (`fork_ts`) over the
  shared MVCC log**: the branch sees main-as-of-`fork_ts` plus its own writes;
  main does not see branch writes until `MERGE BRANCH` publishes the branch's
  delta (data + catalog) back. `ALTER BRANCH REBASE` moves the fork point to
  latest main; per-handle `setBranch()` selects the active branch, re-resolved
  per statement. Because versioning already exists for SI, whole-*database*
  branching (catalog + rows) needs no separate storage machinery — this is the
  same insight that makes §7.1's overlap cheap, applied at a coarser grain.
  Contrast: Postgres has no native branching; Neon/Dolt build a product around
  it at the storage/server layer; no in-browser SQL engine offers it. Note the
  honest edge (`exportSnapshot()` does not yet capture branches — merge or drop
  before export).

## 4. Executing in the Browser: wasm, not WASI
*(Named contribution — answers the wasm/WASI question, pre-empts the reviewer.)*
- **4.1 The two layers.** wasm = sandboxed compute VM, no ambient authority;
  WASI = a standardized *syscall ABI* granting OS capabilities to wasm on
  non-browser hosts.
- **4.2 Why the browser needs no WASI.** The browser is not a WASI host; the Web
  platform (JS, DOM, OPFS, WebCrypto, `performance.now`) already *is* the system
  interface. Table: capability → WASI syscall vs Web/JS binding.
- **4.3 Zeta-lite's binding strategy.** `wasm32-unknown-unknown` +
  `wasm-bindgen --target web`; `getrandom` → `crypto.getRandomValues`
  (`getrandom_backend="wasm_js"`), not `random_get`; persistence via
  `navigator.storage` OPFS, not `fd_write`/`path_open`.
- **4.4 Design-space discussion.** When WASI *would* matter (server/CLI wasm form
  factor); the WASI Preview 3 / Component Model trajectory and why JS-bindings
  remain the correct browser choice today.

## 5. Persistence: Snapshot-to-OPFS Durability
- **5.1 The model** — export whole DB (catalog + rows + timestamp high-water) to
  a byte blob; rehydrate via `openFromSnapshot`.
- **5.2 Why snapshot, not sync-per-write** — sync OPFS
  (`createSyncAccessHandle`) needs a Worker; snapshot-on-demand uses plain async
  OPFS on the main thread, avoiding COOP/COEP. An engineering result, stated as
  one.
- **5.3 The durability window (threats to validity)** — durable only as of the
  last persisted snapshot; be explicit.

## 6. The SQL Surface as Agentic Storage
*(Feature breadth, subordinate to the architecture thesis; bridge to zengram-lite.)*
- **6.1 The surface an agent wants** — enumerate with a one-line "why an agent
  wants this" each: JSONB+GIN (semi-structured tool output), FTS (keyword
  retrieval), HNSW + `embed()` wiring (semantic memory), SQL/PGQ (relationship /
  knowledge graphs over the agent's own data), multi-database (per-task logical
  namespaces). `embed()` ships no bundled model; `setEmbedFn` contract.
- **6.2 Database branching as agent exploration state (the standout).** The
  capability most SQL engines lack, and the one an agent loop most naturally
  wants. Frame branching as *speculative execution over state*: an agent forks a
  branch to try a hypothesis / a destructive plan / a tool sequence, inspects the
  outcome in isolation from the durable line, then **merges** if it worked or
  **drops** if it didn't — with `rebase` to re-anchor a long-lived exploration on
  newer committed facts. This is cheap (a fork timestamp, §3.6), whole-database
  (schema changes and rows both fork), and entirely client-side — an agent can
  branch-per-thought without a server round-trip. Contrast the alternatives an
  agent otherwise resorts to: manual snapshot/restore, copy-the-whole-DB, or
  application-level undo logs. Concrete worked example (fork → isolated writes →
  main unchanged → merge), mirroring the shipped branching demo. This is the
  substrate zengram-lite builds on.
- **6.3 Forward pointer** — these primitives (vector memory, graph queries, COW
  branching) are the foundation of zengram-lite, an agentic memory system for
  in-browser agents [forthcoming].

## 7. Evaluation: Throughput under Concurrency, Coverage, and Size
*(Reordered to lead with the money figure. Full recorded data: `docs/benchmarks/`.)*
- **7.1 Snapshot-isolation under contention (the money figure)** — two
  overlapping txns update the same row → one aborts, **5000/5000** across Chrome,
  Firefox, bun; 8 disjoint overlapping txns all commit. A single-connection
  engine cannot express this workload.
- **7.2 Throughput** — Chrome/Firefox/bun table; point SELECT ~268–315k ops/s;
  **browser within ~5–15% of native; Chrome ≈ Firefox** (not a JS-engine
  artifact). Per-op-class latency (point_read p50 4µs … txn p50 51µs) from the
  soak harness.
- **7.3 Sustained-load stability** — soak harness: throughput stability **1.00**
  over the run; memory growth in the insert-only phase is *data-driven*, the
  read-only settle phase is flat (+8 MB) — the actual leak test. Snapshot
  round-trip avg 44 ms.
- **7.4 Artifact size** — 10.14 MB raw / **2.87 MB gzip**; vs PGlite ~3 MB; the
  size/feature frontier.
- **7.5 Functional coverage** — the 88-assertion validation harness across all
  examples; SQL-surface completeness table.
- Methodology note: one "op" = one API call (single-row OLTP unit); single machine
  (Ryzen AI MAX+ 395), single-threaded engine (`crossOriginIsolated=false`).

## 8. Limitations & Future Work
- Single-threaded, no in-query parallelism (threads = future header-gated build).
- No OLAP / columnar in this artifact.
- Snapshot (not per-commit) durability.
- In-browser soak not yet run (soak numbers are bun/native; harness lives in the
  closed monorepo).
- Schema-sidebar per-DB filtering deferred.
- Forward pointers: threaded build, larger form factors, zengram-lite.

## 9. Conclusion
Restate the collapsed trade-off (completeness + concurrency at browser size) and
the family bet.
