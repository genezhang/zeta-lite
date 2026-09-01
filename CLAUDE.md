# CLAUDE.md — zeta-lite

Guidance for Claude Code when working in the **zeta-lite** public-facing repo.

## What this repo is

zeta-lite is the **public distribution repo** for the WebAssembly build of the
Zeta database engine — the in-browser teaser for the closed Zeta server/embedded
products. The compiled build is **free to use, including commercially, but not
open source**. It mirrors the `genezhang/zeta-embedded` distribution pattern: the
closed engine stays in the private monorepo (`genezhang/zeta`), and this repo
holds the **hand-authored surface** plus the mechanics to fetch/run the published
binary.

**This repo does NOT contain the engine source.** The compiled
`zeta_wasm_bg.wasm` is built in the monorepo (`crates/zeta-wasm`) and published
to npm / GitHub Releases. Do not attempt to add engine Rust source here.

## Layout

- `playground/` — the interactive SQL console (hand-authored HTML + JS glue).
  This is the real hand-authored content and where most edits happen.
  - `index.html` — the console page (copied from monorepo
    `crates/zeta-wasm/harness/playground.html`).
  - `console/` — pure JS glue (router, editor, format), unit-tested under Node
    with no DOM/wasm import. `*.test.mjs` are the CI-run tests.
  - `vendor/codemirror.mjs` — bundled editor (MIT, its own LICENSE file).
  - `pkg-web/` — **gitignored**; the fetched wasm artifact lands here.
- `scripts/` — `fetch-artifact.sh` (pull published wasm), `build-from-source.sh`
  (rebuild from the monorepo, maintainers only).
- `docs/sql_reference.md` — the SQL surface reachable from this build.
- `LICENSE` — Zeta Lite License (free to use, including commercially; **not**
  open source — the engine source is not in this repo).

## Source of truth

The playground is **downstream** of the monorepo's
`crates/zeta-wasm/harness/`. Substantive playground changes should be made there
first (where the engine + validation harness live), then synced here. This repo
is the distribution mirror, not the development home.

## Verifying changes

- Playground glue: `node --test playground/console/router.test.mjs`
- Full engine-driven validation (needs the fetched wasm):
  `./scripts/fetch-artifact.sh` then run `playground/playground_validate.mjs`
  under a JS runtime (88 assertions across all examples).
- Serve locally: `python3 -m http.server -d playground 8080` (wasm needs
  `http://`, not `file://`).

## Guardrails

- **Never commit the `.wasm`** or `pkg-web/` — they're published artifacts,
  gitignored on purpose.
- **Never push directly to `main`** — feature branch + PR.
- The engine source is closed and not in this repo; do not add anything that
  discloses closed engine internals beyond what the public JS API already
  exposes.
