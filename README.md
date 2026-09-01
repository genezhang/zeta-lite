# zeta-lite

**An in-browser SQL database.** A WebAssembly build of the embedded
Zeta engine that runs entirely
client-side — no server, no network, no install. Think
[PGlite](https://pglite.dev), with a different architectural bet: a log-centric
async-MVCC core that supports **overlapping, snapshot-isolated transactions** on
a single thread.

> **Free to use, not open source.** The compiled build is free for any use,
> including commercial (see [LICENSE](LICENSE)). The engine source is not in this
> repo — it is the closed Zeta engine, available separately under NDA.
> Pre-release software.

- **~2.8 MB gzipped** — smaller than PGlite (~3 MB).
- **Real SQL** — the same parser / planner / optimizer / executor as the Zeta
  server: joins, CTEs, window functions, subqueries, aggregates, transactions,
  indexes, JSONB + GIN, vector search (HNSW), full-text search, SQL/PGQ graph
  queries, multi-database, and copy-on-write **database branching**.
- **Overlapping transactions** — multiple transactions hold distinct
  read/commit timestamps and interleave with snapshot-isolation conflict
  detection. PGlite's single-connection backend structurally cannot do this.
- **Streaming cursors** with O(batch) memory, not O(result).
- **OPFS persistence** — snapshot the whole database to a byte blob, store it in
  the browser's Origin Private File System, rehydrate on reload — no worker, no
  `SharedArrayBuffer`, no COOP/COEP headers.

---

## What's in this repo

| Path | Contents | License |
|---|---|---|
| `playground/` | The interactive SQL console (hand-authored HTML/JS) | Zeta Lite License |
| `playground/vendor/` | Bundled CodeMirror editor | MIT (its own `LICENSE-codemirror`) |
| `scripts/` | Fetch/verify the published `.wasm` artifact | Zeta Lite License |
| `docs/sql_reference.md` | The SQL surface reachable from this build | Zeta Lite License |

The compiled `zeta_wasm_bg.wasm` engine artifact is **not committed** to this
repo. It is published to npm (`zeta-lite`) and attached to GitHub Releases; the
scripts below fetch it into `playground/pkg-web/` for local use.

---

## Quick start — run the playground

```bash
# 1. Fetch the published wasm artifact into playground/pkg-web/
./scripts/fetch-artifact.sh            # latest release
# ./scripts/fetch-artifact.sh v0.1.0   # a specific tag

# 2. Serve the playground (any static server; wasm needs http://, not file://)
python3 -m http.server -d playground 8080
#   → open http://localhost:8080
```

The console ships with worked examples (the **Load example** menu): a guided
tour, joins, window functions, vector search, full-text search, JSONB, database
branching, multi-database, and SQL/PGQ graph queries.

For the full SQL surface — types, statements, functions, and exactly what is and
isn't in this build — see [`docs/sql_reference.md`](docs/sql_reference.md).

---

## Use as a library (npm)

```bash
npm install zeta-lite
```

```js
import { ZetaDb } from "zeta-lite";

const db = ZetaDb.open();

db.execDdl("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
db.execMut("INSERT INTO t VALUES ($1, $2)", [1, 42]);   // positional binds
const r = db.query("SELECT v FROM t WHERE id = $1", [1]); // { columns, rows }
console.log(r.rows[0].v); // 42

// Streaming — peak memory O(batch), not O(result-size):
const cur = db.stream("SELECT * FROM t");
for (let row = cur.next(); row !== null; row = cur.next()) { /* row.id, row.v */ }

// Overlapping, snapshot-isolated transactions:
const tx = db.begin();
tx.execMut("INSERT INTO t VALUES ($1, $2)", [2, 7]);
tx.commit();   // or tx.rollback(); dropping the handle without either rolls back
```

`params` is an optional array of positional binds (`$1, $2, …`) — pass an array
even for one value (`[42]`, not `42`). TypeScript types (`zeta_wasm.d.ts`) are
emitted for `ZetaDb`, `ZetaCursor`, and `ZetaTxn`.

---

## Persistence (OPFS)

The engine is in-memory; durability is a **snapshot** of the whole database
(catalog + rows + timestamp high-water) to a byte blob you store in OPFS and
replay on the next load.

```js
const root = await navigator.storage.getDirectory();
let db;
try {
  const fh = await root.getFileHandle("mydb.zeta");
  db = ZetaDb.openFromSnapshot(new Uint8Array(await (await fh.getFile()).arrayBuffer()));
} catch {
  db = ZetaDb.open();
}
// … writes …
const fh = await root.getFileHandle("mydb.zeta", { create: true });
const w = await fh.createWritable();
await w.write(db.exportSnapshot());   // Uint8Array
await w.close();
```

**Durability window — read this.** This is *snapshot* durability, not per-commit
fsync. A committed transaction is durable only **as of the last
`exportSnapshot()` you persisted to OPFS** — anything committed after that is
lost on a crash, reload, or tab close. Checkpoint after writes you need to keep.

---

## Concurrency — the honest boundary

Zeta's log-centric async MVCC lets **multiple transactions hold distinct
read/commit timestamps and interleave at statement boundaries** — transaction A
stays open on its snapshot while B commits, with SI conflict detection between
them.

**What this is not (yet):** simultaneous *in-flight* execution of one query
while another makes progress. The executor pulls rows synchronously, so within a
single statement there is no interior yield. The overlap is *transaction-lifetime*
overlap and cooperative interleaving *between* statements — not sub-statement
parallelism. True in-query parallelism needs threads (a future, header-gated
build). We claim the overlap we deliver, not more.

---

## Status & limitations

This is a **v0.1 preview**. Known boundaries:

- In-memory Memory-backend engine; durability is snapshot-based (above).
- No OLAP / columnar engine (needs a filesystem / larger artifact).
- `embed()` is compiled in but ships **no bundled model** — register a
  synchronous embedder from JS with `db.setEmbedFn(fn, dims)`, or compute
  vectors in JS and bind them. See
  [`docs/sql_reference.md`](docs/sql_reference.md#wiring-embed-from-js).
- Single-threaded; no in-query parallelism.
- The playground's schema sidebar lists all databases' tables (per-database
  filtering deferred).

---

## License

[Zeta Lite License](LICENSE) — **free to use, including commercially; not open
source.** The compiled build is free for any purpose; the only restrictions are
keeping notices intact, no reverse-engineering the `.wasm` to source, and no
using it to build a competing database. The engine source is not in this repo —
it is available separately under NDA. Bundled CodeMirror retains its own MIT
license.

For licensing questions or engine-source access: genegzhang@gmail.com
