#!/usr/bin/env bash
# Build the zeta-lite wasm artifact FROM SOURCE.
#
# This requires access to the closed Zeta monorepo (github.com/genezhang/zeta),
# which is NOT part of this repository. It is provided for maintainers and others
# who have engine-source access under NDA; ordinary users should use
# scripts/fetch-artifact.sh to pull the published (free) binary.
#
# It reproduces crates/zeta-wasm/npm/build-npm.sh from the monorepo, emitting the
# web-target build into this repo's playground/pkg-web/.
#
# Usage:
#   ZETA_REPO=/path/to/zeta ./scripts/build-from-source.sh
#
# Requires: the monorepo checkout, rustup wasm32-unknown-unknown target, and a
# wasm-bindgen CLI whose version matches the monorepo's Cargo.lock.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
dest="$root/playground/pkg-web"

repo="${ZETA_REPO:-}"
if [[ -z "$repo" || ! -d "$repo/crates/zeta-wasm" ]]; then
  echo "!! Set ZETA_REPO to a checkout of the closed Zeta monorepo." >&2
  echo "   e.g. ZETA_REPO=/home/you/zeta $0" >&2
  exit 1
fi

crate="$repo/crates/zeta-wasm"
echo "==> building zeta-wasm (release, Memory-only wasm surface) from $crate"
( cd "$crate" && \
  RUSTFLAGS='--cfg getrandom_backend="wasm_js"' \
    cargo build --release --no-default-features --features wasm \
    --target wasm32-unknown-unknown )

# zeta-wasm declares its own `[workspace]` (isolated, like zeta-embedded), so
# cargo writes to the CRATE-local target/, not the monorepo root's. Honor an
# explicit CARGO_TARGET_DIR first, then the crate-local dir, then the repo root
# — covering every layout instead of assuming one.
rel="wasm32-unknown-unknown/release/zeta_wasm.wasm"
wasm=""
for cand in "${CARGO_TARGET_DIR:+$CARGO_TARGET_DIR/$rel}" \
            "$crate/target/$rel" \
            "$repo/target/$rel"; do
  [[ -n "$cand" && -f "$cand" ]] && { wasm="$cand"; break; }
done
if [[ -z "$wasm" ]]; then
  echo "!! built wasm not found. Looked in:" >&2
  [[ -n "${CARGO_TARGET_DIR:-}" ]] && echo "   \$CARGO_TARGET_DIR/$rel" >&2
  echo "   $crate/target/$rel" >&2
  echo "   $repo/target/$rel" >&2
  echo "   (zeta-wasm is an isolated workspace — its build lands in the" >&2
  echo "    crate-local target/ unless CARGO_TARGET_DIR redirects it.)" >&2
  exit 1
fi
echo "==> found wasm: $wasm"

echo "==> wasm-bindgen --target web -> $dest"
mkdir -p "$dest"
wasm-bindgen --target web --out-dir "$dest" "$wasm"

echo "==> size report (gzip = transfer size)"
bg="$dest/zeta_wasm_bg.wasm"
raw=$(stat -c%s "$bg"); gz=$(gzip -c "$bg" | wc -c)
awk -v r="$raw" -v g="$gz" 'BEGIN{
  printf "    raw  : %.2f MB\n    gzip : %.2f MB   (PGlite reference ~3.0 MB)\n", r/1048576, g/1048576 }'
echo "==> done."
