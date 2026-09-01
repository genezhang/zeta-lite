# zeta-lite SQL Reference

zeta-lite is the Zeta database compiled to WebAssembly — the **same OLTP engine
core** as the native server and embedded library, packaged to run entirely in a
browser tab (or under WASI). Its SQL dialect is **PostgreSQL**: if a query works
against PostgreSQL, it almost certainly works here, with the divergences noted
below.

This document is self-contained — it describes exactly the SQL surface reachable
from the wasm build. It does **not** cover the server-only analytics,
distributed, and operational features (columnar OLAP, Iceberg, multi-shard 2PC,
backup/PITR, scheduled jobs, the server's built-in `embed()` model); those are
not compiled into this artifact at all. (`embed()` itself *is* compiled in — you
wire a model to it from JS, see [Wiring `embed()` from
JS](#wiring-embed-from-js).) See [Not in this build](#not-in-this-build).

- [Running SQL from JavaScript](#running-sql-from-javascript)
- [Value encoding (JS)](#value-encoding-js)
- [Availability](#availability)
- [Data types](#data-types)
- [Statements](#statements)
- [Operators](#operators)
- [Functions](#functions)
- [Zeta extensions](#zeta-extensions)
- [Divergences from PostgreSQL](#divergences-from-postgresql)
- [Not in this build](#not-in-this-build)
- [Limits](#limits)

---

## Running SQL from JavaScript

zeta-lite has no wire protocol — you call it directly through the `ZetaDb`
handle. There are three entry points, split by statement kind:

```js
import init, { ZetaDb } from "./pkg-web/zeta_wasm.js";
await init();                          // load the wasm module

const db = ZetaDb.open();             // fresh in-memory database

db.execDdl("CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT, year INT)");
db.execMut("INSERT INTO book VALUES (1, 'Dune', 1965), (2, 'Neuromancer', 1984)");

const res = db.query("SELECT title, year FROM book ORDER BY year");
// res.rows -> [ { title: 'Dune', year: 1965 }, { title: 'Neuromancer', year: 1984 } ]
```

| Method | Use for | Returns |
|---|---|---|
| `db.execDdl(sql)` | `CREATE` / `ALTER` / `DROP` / `TRUNCATE` | rows affected / ok |
| `db.execMut(sql)` | `INSERT` / `UPDATE` / `DELETE` / `MERGE` | rows affected |
| `db.query(sql)` | `SELECT` and other row-returning queries | `{ columns, rows }` |

**Parameters** are bound positionally to keep values out of the SQL text (this is
the safe path — never string-concatenate user input into SQL):

```js
db.query("SELECT * FROM book WHERE year > $1 AND title LIKE $2", [1970, "N%"]);
```

**Transactions** run as overlapping snapshot-isolated sessions — this is
zeta-lite's headline capability, and it works on a single browser thread. Use
`BEGIN` / `COMMIT` / `ROLLBACK` (and `SAVEPOINT`) as normal SQL; two handles can
hold concurrent open transactions over the same data and each sees its own
consistent snapshot.

**Durability** is via snapshots, not a background WAL: `db.exportSnapshot()`
returns a `Uint8Array` you can persist (e.g. to OPFS or IndexedDB), and
`ZetaDb.openFromSnapshot(bytes)` restores it. There is no filesystem in the
browser build, so `COPY TO <file>` is accepted but does nothing — export a
snapshot instead.

---

## Value encoding (JS)

Query results cross the wasm boundary as plain JS values. A few types do **not**
map to a native JS type and are encoded deliberately — parse them caller-side:

| Type | JS value |
|---|---|
| `BOOLEAN` | `true` / `false` |
| `SMALLINT` / `INTEGER` / `BIGINT` | number |
| `REAL` / `DOUBLE PRECISION` | number (non-finite → string) |
| `NUMERIC` / `DECIMAL` | **string** (exact — no float rounding) |
| `TEXT` / `VARCHAR` / `CHAR` | string |
| `BYTEA` | **array** of byte values (`[222, 173, ...]`) |
| `UUID` | string |
| `DATE` | **number** — days since Unix epoch |
| `TIMESTAMP` | **string** — microseconds since Unix epoch |
| `TIME` | **number** — microseconds since midnight |
| `INTERVAL` | **string** — e.g. `"1 months 2 days 10800000000 us"` |
| `ARRAY` / `VECTOR(n)` | array |
| `JSONB` | native JSON value |
| `NULL` | `null` (observable as `row.col === null`) |

`NUMERIC` is a string so you never lose precision to a JS float. `DATE` (days),
`TIMESTAMP` (µs since epoch), and `TIME` (µs since midnight) are numeric/string
forms you convert to a JS `Date` as you see fit — e.g. `new Date(days * 86400000)`
for a `DATE`. `BYTEA` comes back as an array of byte values (wrap it with
`new Uint8Array(bytes)` if you want a typed array), and `INTERVAL` as a
human-readable string rather than a structured object.

---

## Availability

The matrix below is **generated from a live probe** that runs every documented
SQL category against the actual wasm artifact, so it can't drift from what the
shipped binary does. A `✅` means the surface works in this build; `⚠️` means the
statement parses but isn't evaluated yet; `❌` means it is excluded from this
build by design (see [Not in this build](#not-in-this-build)).

> One caveat the probe can't express: a couple of **wire features** (`COPY TO`,
> `LISTEN`/`NOTIFY`) are *accepted* — they don't error — but are **no-ops** in
> the browser build (no filesystem, no wire). They show `✅` because they parse
> and run without throwing, not because they do something.

<!-- BEGIN GENERATED: availability (bun harness/gen_lite_sql_ref.mjs) -->

> **This table is generated** by `bun harness/gen_lite_sql_ref.mjs`, which runs every documented SQL category against the built wasm artifact and records what actually works. ✅ works · ⚠️ parsed but not yet evaluated · ❌ not in this build (by design). Do not edit by hand — re-run the generator.

**Data types**

| Surface | zeta-lite |
|---|:---:|
| ARRAY | ✅ |
| BYTEA | ✅ |
| DATE (→ number days) / TIMESTAMP (→ string µs) | ✅ |
| DECIMAL (→ string) | ✅ |
| ENUM | ✅ |
| INTEGER/TEXT/BOOLEAN | ✅ |
| JSONB | ✅ |
| SMALLINT/BIGINT/REAL/DOUBLE | ✅ |
| UUID | ✅ |
| VECTOR(4) | ✅ |

**Queries & DML**

| Surface | zeta-lite |
|---|:---:|
| CTE + window | ✅ |
| INSERT ... SELECT | ✅ |
| INSERT multi-row + DEFAULT | ✅ |
| MERGE (PG 15+) | ✅ |
| SELECT joins | ✅ |
| TRUNCATE | ✅ |
| UPDATE + DELETE | ✅ |

**Schema (DDL)**

| Surface | zeta-lite |
|---|:---:|
| ALTER TABLE add constraint | ✅ |
| ALTER TABLE add/drop/rename column | ✅ |
| CREATE INDEX (btree) | ✅ |
| CREATE INDEX (GIN) | ✅ |
| CREATE INDEX (GiST) | ✅ |
| CREATE/DROP PROPERTY GRAPH | ✅ |
| CREATE/DROP SEQUENCE | ✅ |
| CREATE/DROP VIEW | ✅ |
| DROP TABLE IF EXISTS / CASCADE | ✅ |
| EXPLAIN | ✅ |
| IDENTITY column | ✅ |
| SERIAL column | ✅ |

**Database branches**

| Surface | zeta-lite |
|---|:---:|
| ALTER BRANCH REBASE | ✅ |
| branch() reflects the active branch | ✅ |
| CREATE/switch/merge | ✅ |

**Multiple databases**

| Surface | zeta-lite |
|---|:---:|
| current_database() tracks the connected db | ✅ |
| databases() lists catalog databases, zeta first | ✅ |
| setDatabase rejects an unknown database | ✅ |
| setDatabase switches current db + unqualified resolution | ✅ |

**Transactions**

| Surface | zeta-lite |
|---|:---:|
| BEGIN/COMMIT | ✅ |
| ROLLBACK + SAVEPOINT | ✅ |

**Triggers**

| Surface | zeta-lite |
|---|:---:|
| BEFORE INSERT (PL/pgSQL body) | ✅ |
| SQL-statement body | ✅ |
| WHEN clause | ✅ |

**DO blocks**

| Surface | zeta-lite |
|---|:---:|
| DO block | ✅ |

**Operators**

| Surface | zeta-lite |
|---|:---:|
| array contains/contained (<@ >@ =) | ✅ |
| comparison + IS NULL + IN + LIKE + ILIKE | ✅ |
| JSONB -> / ->> / @> | ✅ |
| pattern ~ / ~* (regex) | ✅ |
| range operators | ✅ |
| SIMILAR TO | ✅ |
| vector distance (<-> <#> <=>) | ✅ |

**Functions**

| Surface | zeta-lite |
|---|:---:|
| aggregates (COUNT/SUM/AVG/MIN/MAX/ARRAY_AGG/STRING_AGG) | ✅ |
| array functions (incl. arr[lo:hi] slice) | ✅ |
| conditional/null (NULL → JS null) | ✅ |
| date/time family | ✅ |
| embed() — needs a JS provider via db.setEmbedFn(fn, dims) | ✅ |
| FTS (to_tsvector/to_tsquery/ts_rank/@@) | ✅ |
| JSONB family | ✅ |
| numeric family | ✅ |
| percentile_cont/disc | ✅ |
| set-returning (GENERATE_SERIES/UNNEST) | ✅ |
| size functions (pg_relation_size etc.) | ✅ |
| SQL/JSONPath (jsonb_path_* + STRICT/LAX prefix) | ✅ |
| string family | ✅ |
| uuid + sequence fns | ✅ |
| vector family | ✅ |
| window (RANK/DENSE_RANK/NTILE/LAG/LEAD/FIRST_VALUE) | ✅ |

**Session config**

| Surface | zeta-lite |
|---|:---:|
| SET (zeta.* GUC) | ✅ |
| SHOW (zeta.* GUC) <sub>plan error: statement is handled before planning</sub> | ⚠️ |

**Maintenance**

| Surface | zeta-lite |
|---|:---:|
| VACUUM / ANALYZE | ✅ |

**Wire features**

| Surface | zeta-lite |
|---|:---:|
| COPY TO file (no FS in browser build) | ✅ |
| LISTEN/NOTIFY (server-only) | ✅ |

**Server-only (not in this build)**

| Surface | zeta-lite |
|---|:---:|
| AOI agent verbs (server-only) | ❌ |
| backup/PITR verbs (server-only) | ❌ |
| scheduled jobs (server-only) | ❌ |

_Surface probe: 69 available, 1 partial, 3 excluded by design._

<!-- END GENERATED -->

---

## Data types

| SQL name | Aliases | Description |
|---|---|---|
| `BOOLEAN` | `BOOL` | true / false |
| `SMALLINT` | `INT2` | 16-bit signed integer |
| `INTEGER` | `INT`, `INT4` | 32-bit signed integer |
| `BIGINT` | `INT8` | 64-bit signed integer |
| `SERIAL` | — | auto-incrementing 32-bit integer |
| `BIGSERIAL` | — | auto-incrementing 64-bit integer |
| `REAL` | `FLOAT4` | 32-bit floating point |
| `DOUBLE PRECISION` | `FLOAT`, `FLOAT8` | 64-bit floating point |
| `NUMERIC` | `DECIMAL` | arbitrary-precision decimal |
| `TEXT` | — | variable-length string (unlimited) |
| `VARCHAR(n)` | `CHARACTER VARYING(n)` | variable-length string (max n chars) |
| `CHAR(n)` | `CHARACTER(n)` | mapped to `VARCHAR(n)` |
| `BYTEA` | — | variable-length binary data |
| `UUID` | — | universally unique identifier (v4) |
| `TIMESTAMP` | — | microseconds since Unix epoch |
| `DATE` | — | days since Unix epoch |
| `TIME` | — | microseconds since midnight |
| `INTERVAL` | — | duration (months, days, microseconds) |
| `ARRAY` | — | variable-length array of any type |
| `JSONB` | — | binary JSON with indexing support |
| `VECTOR(n)` | — | fixed-length array of 32-bit floats (pgvector-compatible) |
| `TSVECTOR` | — | preprocessed document for full-text search |
| `TSQUERY` | — | full-text search query expression |
| `ENUM` | — | user-defined label set (`CREATE TYPE name AS ENUM (...)`) |
| `INT4RANGE` / `INT8RANGE` | — | range of integers / bigints |
| `TSRANGE` / `DATERANGE` / `NUMRANGE` | — | range of timestamps / dates / numerics |

---

## Statements

### SELECT

Full `SELECT` surface: `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` / `NATURAL`
joins, subqueries, `WITH` and `WITH RECURSIVE` CTEs, window functions with frame
clauses, set operations (`UNION` / `INTERSECT` / `EXCEPT`), `GROUP BY` /
`HAVING`, `GROUPING SETS` / `ROLLUP` / `CUBE`, `DISTINCT` and `DISTINCT ON`,
`ORDER BY`, `LIMIT` / `OFFSET`, and `LATERAL` (including implicit LATERAL over
set-returning functions).

```sql
SELECT author, title,
       RANK() OVER (PARTITION BY author ORDER BY year) AS by_year
FROM book
WHERE year >= 1980
ORDER BY author, by_year;
```

### INSERT / UPDATE / DELETE

```sql
INSERT INTO book (id, title, year) VALUES (3, 'Snow Crash', 1992);
INSERT INTO book SELECT id + 100, title, year FROM book;   -- INSERT ... SELECT
UPDATE book SET year = year + 1 WHERE id = 3;
DELETE FROM book WHERE year < 1970;
```

`DEFAULT` values, multi-row `VALUES`, and `INSERT ... SELECT` are all supported.

### MERGE

PostgreSQL 15+ `MERGE` (upsert) is supported:

```sql
MERGE INTO book AS t
USING (SELECT 3 AS id, 'Snow Crash' AS title, 1992 AS year) AS s
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET title = s.title, year = s.year
WHEN NOT MATCHED THEN INSERT (id, title, year) VALUES (s.id, s.title, s.year);
```

### CREATE / DROP / ALTER TABLE

```sql
CREATE TABLE t (
  id     INTEGER PRIMARY KEY,
  name   TEXT NOT NULL,
  email  TEXT UNIQUE,
  parent INTEGER REFERENCES t(id),   -- FOREIGN KEY (RESTRICT)
  score  NUMERIC DEFAULT 0,
  CHECK (score >= 0)
);
ALTER TABLE t ADD COLUMN created DATE;
ALTER TABLE t DROP COLUMN created;
ALTER TABLE t RENAME COLUMN name TO full_name;
ALTER TABLE t ADD CONSTRAINT uq UNIQUE (email);
DROP TABLE IF EXISTS t CASCADE;
```

Constraints: `PRIMARY KEY`, `NOT NULL`, `DEFAULT`, `UNIQUE`, `FOREIGN KEY`
(RESTRICT), `CHECK`. `SERIAL` and `GENERATED ... AS IDENTITY` are both supported.
`TEMP` tables are supported.

### Indexes

```sql
CREATE INDEX idx_year   ON book (year);                    -- BTree (default)
CREATE INDEX idx_doc    ON t USING GIN (data);             -- JSONB containment
CREATE INDEX idx_vec    ON t USING HNSW (v vector_l2_ops); -- vector similarity
CREATE INDEX idx_fts    ON t USING GIN (to_tsvector('english', body)); -- FTS
DROP INDEX idx_year;
```

Index types: **BTree** (default), **GIN** (JSONB `@>` / `?` / `?&` / `?|`),
**HNSW** (vector L2 / cosine / inner product), **FTS** (`@@`). GiST is accepted.

### Views, sequences, types

```sql
CREATE VIEW recent AS SELECT * FROM book WHERE year >= 2000;
DROP VIEW recent;

CREATE SEQUENCE s START 100;
SELECT nextval('s'), currval('s');

CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
```

### Triggers and DO blocks

Row-level `BEFORE` / `AFTER` triggers on `INSERT` / `UPDATE` / `DELETE`, with
PL/pgSQL or SQL-statement bodies and an optional `WHEN` clause, plus anonymous
`DO` blocks:

```sql
CREATE FUNCTION stamp() RETURNS trigger AS $$
BEGIN NEW.created := current_date; RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER t_stamp BEFORE INSERT ON book
FOR EACH ROW WHEN (NEW.year IS NULL) EXECUTE FUNCTION stamp();

DO $$ BEGIN RAISE NOTICE 'hello'; END $$;
```

PL/pgSQL supports `IF` / `ELSIF` / `ELSE`, `RAISE`, `PERFORM`, and `DECLARE`.
(`LOOP` / `WHILE` / `FOR` and `EXCEPTION` blocks are not yet implemented — see
[Divergences](#divergences-from-postgresql).)

### Transaction control

```sql
BEGIN;
  UPDATE book SET year = 2000 WHERE id = 1;
  SAVEPOINT sp;
  DELETE FROM book WHERE id = 2;
  ROLLBACK TO SAVEPOINT sp;
COMMIT;
```

Snapshot isolation is the default; `SERIALIZABLE` (SSI) is available.

### EXPLAIN

`EXPLAIN` and `EXPLAIN ANALYZE` both work.

### CREATE PROPERTY GRAPH / GRAPH_TABLE

See [SQL/PGQ graph queries](#sqlpgq-graph-queries) under Zeta extensions.

---

## Operators

| Group | Operators |
|---|---|
| Comparison | `=` `<>` `!=` `<` `<=` `>` `>=` |
| Logical | `AND` `OR` `NOT` |
| Arithmetic | `+` `-` `*` `/` `%` `^` |
| String / array concat | `\|\|` |
| Cast | `::type` |
| Pattern | `LIKE` `ILIKE` `SIMILAR TO` `~` `~*` `!~` `!~*` |
| Null testing | `IS NULL` `IS NOT NULL` `IS DISTINCT FROM` |
| Membership | `IN` `NOT IN` `BETWEEN` |
| JSONB | `->` `->>` `#>` `#>>` `@>` `<@` `?` `?\|` `?&` |
| Array | `@>` `<@` `=` (contains / contained / equal) |
| Range | `@>` `<@` `&&` (overlap) and bound accessors |
| Vector distance | `<->` (L2) `<#>` (inner product) `<=>` (cosine) |

---

## Functions

The families below are all available. Individual function coverage tracks
PostgreSQL; the probe verifies one representative call per family.

- **Aggregates** — `COUNT`, `COUNT(DISTINCT)`, `SUM`, `AVG`, `MIN`, `MAX`,
  `STRING_AGG`, `BOOL_AND`, `BOOL_OR`, `BIT_AND`, `BIT_OR`, `ARRAY_AGG`,
  `JSONB_AGG`, `JSONB_OBJECT_AGG`, `PERCENTILE_CONT`, `PERCENTILE_DISC`.
  `FILTER (WHERE ...)` is supported.
- **Window** — `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, `LEAD`, `FIRST_VALUE`,
  `LAST_VALUE`, `NTH_VALUE`, `NTILE`, `CUME_DIST`, `PERCENT_RANK`, with frame
  clauses.
- **String** — `UPPER`, `LOWER`, `LENGTH`, `CONCAT`, `CONCAT_WS`, `SUBSTRING`,
  `REPLACE`, `SPLIT_PART`, `TRIM`, `LTRIM`, `RTRIM`, `LEFT`, `RIGHT`, `REPEAT`,
  `REVERSE`, `POSITION`, `STARTS_WITH`, `REGEXP_MATCH(ES)`, `REGEXP_REPLACE`.
- **Numeric** — `ABS`, `ROUND`, `CEIL`, `FLOOR`, `SQRT`, `POW`, `LOG`, `LN`,
  `MOD`, `SIGN`, `RANDOM`, `GREATEST`, `LEAST`.
- **Conditional / null** — `COALESCE`, `NULLIF`, `CASE`.
- **Date / time** — `CURRENT_TIMESTAMP`, `CURRENT_DATE`, `CURRENT_TIME`, `NOW`,
  `EXTRACT`, `DATE_TRUNC`, `TO_CHAR`, `TO_TIMESTAMP`, `MAKE_DATE`, `MAKE_TIME`,
  `MAKE_INTERVAL`, `AGE`.
- **UUID / sequence** — `GEN_RANDOM_UUID`, `NEXTVAL`, `CURRVAL`, `SETVAL`.
- **JSONB** — `JSONB_BUILD_OBJECT`, `JSONB_BUILD_ARRAY`, `JSONB_TYPEOF`,
  `JSONB_ARRAY_LENGTH`, `JSONB_PRETTY`, `JSONB_STRIP_NULLS`,
  `JSONB_EXTRACT_PATH(_TEXT)`, `JSONB_SET`, `TO_JSONB`.
- **SQL/JSONPath** — `JSONB_PATH_EXISTS`, `JSONB_PATH_QUERY(_ARRAY/_FIRST)` with
  `strict` / `lax` prefixes.
- **Full-text search** — `TO_TSVECTOR`, `TO_TSQUERY`, `PLAINTO_TSQUERY`,
  `TS_RANK`, and the `@@` match operator.
- **Vector** — distance operators plus vector helpers for HNSW search.
- **Set-returning** — `GENERATE_SERIES`, `UNNEST`, `JSONB_EACH(_TEXT)`,
  `JSONB_OBJECT_KEYS` (with implicit LATERAL).
- **Size** — `PG_RELATION_SIZE` and friends.

---

## Zeta extensions

Features beyond the PostgreSQL surface, all available in this build unless noted.

### Database branches (fork / rebase / merge)

Copy-on-write branches of the whole database. A branch is a fork point
(`fork_ts`); writes on the branch are isolated until merged back.

```sql
CREATE BRANCH feat;                 -- fork from current main
DROP BRANCH [IF EXISTS] feat;
MERGE BRANCH feat;                  -- publish the branch delta into main, drop it
ALTER BRANCH feat REBASE [DRY RUN]; -- move the fork point to latest main
```

- **Per-handle selection**: `db.setBranch("feat")` switches a handle onto a
  branch; `db.setBranch(null)` returns to main; `db.branch()` reports the current
  one. The name is re-resolved per statement, so a dropped/rebased branch errors
  at the next statement.
- **Isolation**: a branch sees main-as-of-`fork_ts` plus its own writes; main
  does not see branch writes until `MERGE BRANCH`.
- **Merge**: a clean `MERGE BRANCH` publishes the branch's delta (data +
  secondary indexes) into main as one transaction and returns an empty conflict
  report; a conflicting merge returns the conflict report and applies nothing.
- **Snapshots**: branches are **not** captured by `exportSnapshot()` — merge or
  drop them before exporting (it throws a clear error otherwise).

### Multiple databases

`CREATE DATABASE` / `DROP DATABASE` and per-handle selection via
`db.setDatabase("name")`; `current_database()` and `databases()` report state.
Databases are a **logical namespace over one shared catalog and log**, not
physically-isolated instances — so cross-database queries work in a single handle
via a fully-qualified `db.schema.table` name, and there is no per-database log
isolation. Each *table* still gets independent storage.

### SQL/PGQ graph queries

`CREATE PROPERTY GRAPH` names vertex/edge tables; `GRAPH_TABLE` runs ISO SQL/PGQ
`MATCH` patterns over them — one-hop, fixed-length VLP (`->{2}`), and range
quantifiers (`->{1,3}`).

```sql
CREATE PROPERTY GRAPH social
  VERTEX TABLES (person KEY (id) LABEL Person PROPERTIES (name))
  EDGE TABLES (knows KEY (id)
    SOURCE KEY (person1_id) REFERENCES person (id)
    DESTINATION KEY (person2_id) REFERENCES person (id)
    LABEL Knows);

SELECT * FROM GRAPH_TABLE(social
  MATCH (a:Person)-[:Knows]->(b:Person)
  COLUMNS (a.name AS src, b.name AS dst));
```

> Note: in a two-hop pattern, name the intermediate node (`(m:Person)`, not an
> anonymous `()`) to avoid an "ambiguous column" error.

### Vector search (bring your own embeddings)

Vector similarity search — the `VECTOR(n)` type, the distance operators
(`<->` L2, `<#>` inner product, `<=>` cosine), and the **HNSW** index — is fully
present and indexed in this build. There are two ways to get text into vectors:

1. **Bring your own vectors** (recommended for hosted / async models): compute
   the vector in JavaScript and bind it as a parameter. This is the only option
   when embedding is asynchronous (a network API, an async model), because it
   happens outside SQL.
2. **Register a synchronous provider** with `db.setEmbedFn(fn, dims)` so that
   `embed(text)` works *inside* SQL — see [Wiring `embed()` from
   JS](#wiring-embed-from-js) below. There is no built-in model in the browser
   (the ONNX runtime is ~120 MB and browser-hostile), so you supply the callback.

The bring-your-own-vectors pattern: produce the vector in JavaScript — from a
hosted embeddings API, a `transformers.js` model, or anything else — and pass it
in as a positional parameter. Everything downstream (indexing, ANN search,
ranking) runs in the engine exactly as it would with `embed()`.

```js
// 1. One-time schema: a VECTOR column + an HNSW index for fast ANN search.
db.execDdl(`
  CREATE TABLE docs (
    id    INTEGER PRIMARY KEY,
    body  TEXT,
    v     VECTOR(384)          -- match your model's output width
  )`);
db.execDdl("CREATE INDEX ON docs USING HNSW (v vector_cosine_ops)");

// 2. Your embedding function — whatever produces number[] of the right length.
//    (Here, a stand-in; swap in a real model / API call.)
async function embed(text) {
  // e.g. const out = await pipeline(text);  return Array.from(out.data);
  return /* number[] of length 384 */;
}

// 3. Ingest: embed in JS, bind the vector as a parameter (no embed() in SQL).
const v = await embed("the quick brown fox");
db.execMut("INSERT INTO docs (id, body, v) VALUES ($1, $2, $3)",
           [1, "the quick brown fox", v]);   // number[] binds to VECTOR

// 4. Query: embed the query text the same way, then order by distance.
const q = await embed("fast animal");
const hits = db.query(
  "SELECT id, body, v <=> $1 AS distance FROM docs ORDER BY distance LIMIT 5",
  [q]);
// hits.rows -> [ { id, body, distance }, ... ] nearest-first
```

A `VECTOR(n)` parameter accepts a JS `number[]` of length `n`; a length mismatch
is an error. Use the **same** embedding model for ingest and query — distances
are only meaningful within one embedding space. The `*_ops` on the HNSW index
must match the distance operator you search with (`vector_cosine_ops` ↔ `<=>`,
`vector_l2_ops` ↔ `<->`, `vector_ip_ops` ↔ `<#>`).

> **With an HNSW index, order by the distance *alias*, not the repeated
> expression.** Aliasing `v <=> $1 AS distance` in the SELECT list *and* writing
> `ORDER BY v <=> $1` trips the index rewrite (`column not found: distance`).
> `ORDER BY distance` — the alias — is the form that works and is accelerated;
> `ORDER BY v <=> $1` without selecting the distance also works. (Without the
> index, the repeated-expression form is fine too — this only bites the indexed
> path.)

#### Wiring `embed()` from JS

If your embedding is **synchronous**, register it once with `db.setEmbedFn(fn,
dims)` and then call `embed(text)` directly in SQL — the engine invokes your
callback at ingest and at query time, so you never thread vectors through
parameters by hand.

```js
// A synchronous provider: (text) => number[] | Float32Array of length `dims`.
db.setEmbedFn((text) => {
  const v = new Array(384).fill(0);
  // ... fill v from a synchronous model / hash / cache ...
  return v;
}, 384);                          // dims MUST equal your VECTOR(384)

db.execDdl("CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, v VECTOR(384))");
db.execDdl("CREATE INDEX ON docs USING HNSW (v vector_cosine_ops)");

// embed() now runs your callback inside SQL — no parameter binding needed.
db.execMut("INSERT INTO docs VALUES (1, 'hello', embed('hello'))");
const hits = db.query(
  "SELECT id, body, v <=> embed($1) AS distance FROM docs ORDER BY distance LIMIT 5",
  ["hi there"]);
```

Rules and limits:

- **The callback must be synchronous.** `embed()` is evaluated inside
  synchronous query execution on the single browser thread, so the callback
  cannot `await` — an `async` function (or one returning a `Promise`) is rejected
  with a clear error. For a **network / async** embedding API, use the
  bring-your-own-vectors pattern above instead; there is no way to await inside
  `embed()` without a Worker + `SharedArrayBuffer`, which this build avoids.
- The callback must return a `number[]` or `Float32Array` of exactly `dims`
  finite numbers; a wrong length, a non-number, a non-finite value (`NaN`/`Inf`),
  or a thrown error surfaces as an `embed(): …` execution error rather than a
  silent bad vector. `dims` of `0` is rejected at registration.
- Registration is **process-global** (one provider per module instance): it
  applies to every handle and replaces any previously registered provider.
- Without a registered provider, `embed()` errors — it is compiled in but has no
  default model in the browser build.

### HLC watermark

`SET [LOCAL] zeta.hlc_watermark = N` floors the local TSO to at least `N` — used
to order client-generated timestamps against engine-allocated ones.

---

## Divergences from PostgreSQL

zeta-lite targets the PostgreSQL surface but is not PostgreSQL.

**Not yet implemented** (error, or absent):
- Composite types (user-defined row types)
- `DECLARE CURSOR` / `FETCH` / `CLOSE` (server-side cursors)
- PL/pgSQL `LOOP` / `WHILE` / `FOR` and `EXCEPTION` blocks (`IF`/`ELSIF`/`ELSE`,
  `RAISE`, `PERFORM`, `DECLARE` work)
- `hstore`, PostGIS extensions
- Encryption at rest
- Intra-query parallelism
- `SHOW <guc>` / `RESET <guc>` — parsed, but errors rather than returning a value

**Accepted but not enforced** (no error — mind the gap):
- `PARTITION BY` — `CREATE TABLE ... PARTITION BY ...` succeeds, but the clause
  is ignored: you get an ordinary, unpartitioned table. (The browser build uses
  the in-memory engine, which is a single unpartitioned keyspace; the persistent
  engines auto-split large tables by key range internally, but that is a
  storage-scaling detail, not the declarative partitioning this clause requests.)

**Semantic differences:**
- **Multi-database** is a logical namespace over one shared catalog and log (see
  [Multiple databases](#multiple-databases)), not physically-isolated instances.
- `VACUUM` GCs dead MVCC versions (it is not a no-op); in the browser build there
  are no LSM SST files to compact. `ANALYZE` collects real statistics.
- Value encoding differs from PostgreSQL's — results come back as JS values, not
  wire text; see [Value encoding](#value-encoding-js).

---

## Not in this build

These features are **not usable in the wasm build**. Most are server-binary
features on a different axis from the SQL surface above — not compiled into the
artifact at all, not merely disabled at runtime (the exception is `embed()`,
noted below). If you need them, use the native server or embedded library.

- **Columnar / vectorized OLAP** — the analytical column store + vectorized
  engine (needs DataFusion, too large to ship in wasm).
- **Iceberg lakehouse** — the MPP worker pool and append-only event tables.
- **Distributed scale-out** — multi-shard 2PC, gRPC, HA/replication.
- **`embed()` / `embed_batch()`** — *compiled in*, but there is no **default**
  embedding provider (no bundled model in the browser), so a bare call errors at
  execution. You can register a **synchronous** JS provider with
  `db.setEmbedFn(fn, dims)` to make `embed()` work in SQL, or — for async /
  network embeddings — compute vectors in JS and bind them. See
  [Vector search](#vector-search-bring-your-own-embeddings) and
  [Wiring `embed()` from JS](#wiring-embed-from-js).
- **Scheduled jobs**, **backup / PITR verbs**, **AI-agent (AOI) verbs**.
- **Persistent LSM + Tantivy FTS index** — the browser build runs the
  filesystem-free Memory backend and the pure-Rust FTS-query path (full-text
  *queries* work; there is no persistent FTS index). The **WASI** build adds the
  Quartz engine for real-file persistence.

Durability in the browser is via `exportSnapshot()` / `openFromSnapshot()`, not
a background WAL.

---

## Limits

| Limit | Value |
|---|---|
| Max tables | 65,535 (2-byte table ID) |
| Max columns per table | no hard limit |
| Max row size | bounded by write buffer (64 MiB default) |
| Max primary key columns | no hard limit |
| Transaction timeout | 30 seconds (default) |
| Conflict detection window | 60 seconds |
