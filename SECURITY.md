# Security Policy

Zeta Lite is a WebAssembly build of the Zeta database engine that runs entirely
inside the browser (or a JS runtime) — in the page's own sandbox, with no server
and no network. Its security posture is shaped around being a well-behaved
client-side guest.

> Zeta Lite is free to use but not open source; the engine source is not in this
> repo. Please report vulnerabilities privately (see below) rather than in public
> issues, so a fix can ship before details are public.

## Reporting a Vulnerability

Report security issues **privately** — do not open a public issue.

- Preferred: GitHub's **"Report a vulnerability"** button under this
  repository's **Security** tab (private security advisories).
- Or email genegzhang@gmail.com.

Please include the version/tag, browser or runtime, a minimal reproduction if
possible, and the impact you observed. We aim to acknowledge within a few
business days.

## Security Model

### Runs in the host sandbox

The engine executes as WebAssembly inside the embedding page or runtime. It has
no ambient filesystem, network, or process access beyond what the host grants
through the JS API. Persistence is an explicit snapshot blob the host chooses to
store (e.g. in OPFS); the engine never writes anywhere on its own.

### Parameterized queries

Always pass query parameters as positional binds (`$1`, `$2`, …) with a values
array — never assemble SQL by concatenating untrusted strings. Bound parameters
are applied out-of-band, so untrusted values cannot change a query's structure.

### Untrusted SQL

The SQL parser bounds its own recursion and resource use and rejects
pathological input with an error rather than failing unsafely. Even so, treat
SQL text from untrusted sources with care and prefer parameterized queries.

### Data isolation

A database handle's data lives only in the wasm linear memory of the page that
created it. A snapshot blob is plaintext — if you persist it (OPFS,
IndexedDB, download), protect it the way you would any other client-side data;
it carries the full contents of the database.

## Scope

This policy covers the playground glue and the behavior of the engine as exposed
through the JS API in this repository. If unsure whether something is in scope,
report it privately and we will help triage.
