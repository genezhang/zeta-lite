#!/usr/bin/env bash
# Fetch the published zeta-lite wasm artifact into playground/pkg-web/.
#
# The compiled engine (zeta_wasm_bg.wasm + wasm-bindgen JS glue) is NOT committed
# to this repo. It is published to npm as `zeta-lite` and attached to GitHub
# Releases. This script pulls the web-target build so the playground can run
# locally without a Rust/wasm toolchain.
#
# Usage:
#   ./scripts/fetch-artifact.sh            # latest published npm version
#   ./scripts/fetch-artifact.sh v0.1.0     # a specific release tag
#   ZETA_LITE_PKG=/path/to/pkg-web ./scripts/fetch-artifact.sh   # copy from a local build
#
# Requires: npm (default path) OR a local pkg-web dir via ZETA_LITE_PKG.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
dest="$root/playground/pkg-web"
mkdir -p "$dest"

# The web-target files the playground imports (playground/index.html loads
# ./pkg-web/zeta_wasm.js). Keep this list in sync with a wasm-bindgen --target web
# output set.
files=(zeta_wasm.js zeta_wasm_bg.wasm zeta_wasm.d.ts zeta_wasm_bg.wasm.d.ts)

# The third-party license notices legally travel WITH the .wasm. Copied
# best-effort (warn, don't fail) so an older artifact that predates the notices
# file doesn't break the fetch — but a current artifact always carries it.
notices_file="THIRD-PARTY-NOTICES.txt"

if [[ -n "${ZETA_LITE_PKG:-}" ]]; then
  echo "==> copying artifact from local build: $ZETA_LITE_PKG"
  for f in "${files[@]}"; do
    cp "$ZETA_LITE_PKG/$f" "$dest/$f"
  done
  if [[ -f "$ZETA_LITE_PKG/$notices_file" ]]; then
    cp "$ZETA_LITE_PKG/$notices_file" "$dest/$notices_file"
  else
    echo "    (warning: $notices_file not found in build — should ship with the .wasm)" >&2
  fi
else
  ver="${1:-latest}"
  # npm dist-tags use bare versions; strip a leading v from a git-style tag.
  ver="${ver#v}"
  echo "==> fetching zeta-lite@$ver from npm"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Supply-chain integrity: this pulls a prebuilt engine binary, so verify what
  # npm delivered before we trust it. `npm pack --json` reports the tarball's
  # sha512 integrity as an SRI string. If ZETA_LITE_SHA512 is set,
  # pin it to that FULL SRI value — the `sha512-<base64>` form printed below,
  # NOT a hex digest — and we fail closed on mismatch; otherwise we print the
  # integrity so a human / CI can record and compare it.
  pack_json="$(cd "$tmp" && npm pack "zeta-lite@$ver" --json 2>/dev/null)"
  tgz="$(printf '%s' "$pack_json" | sed -n 's/.*"filename": *"\([^"]*\)".*/\1/p' | head -1)"
  integrity="$(printf '%s' "$pack_json" | sed -n 's/.*"integrity": *"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$tgz" || ! -f "$tmp/$tgz" ]]; then
    # Fallback for older npm without a reliable --json filename field.
    tgz="$(cd "$tmp" && ls -1 zeta-lite-*.tgz 2>/dev/null | head -1)"
  fi
  [[ -n "$tgz" && -f "$tmp/$tgz" ]] || { echo "!! npm pack produced no tarball" >&2; exit 1; }
  echo "    integrity: ${integrity:-<unknown>}"
  if [[ -n "${ZETA_LITE_SHA512:-}" ]]; then
    if [[ "$integrity" != "$ZETA_LITE_SHA512" ]]; then
      echo "!! integrity mismatch — refusing to install." >&2
      echo "   expected: $ZETA_LITE_SHA512" >&2
      echo "   got:      ${integrity:-<none>}" >&2
      exit 1
    fi
    echo "    integrity pin OK"
  else
    echo "    (set ZETA_LITE_SHA512 to the release's published integrity to fail closed)"
  fi

  # Extract defensively: don't let a hostile tarball write outside $tmp via
  # absolute paths or ../ traversal. The real guard is `--no-absolute-names`
  # (strips leading '/') plus GNU tar's default refusal of `..` members. The
  # post-extraction realpath sweep below is belt-and-suspenders — it can only
  # observe paths already under $tmp, so it's a cheap backstop, not the
  # primary defense.
  tar --no-absolute-names --no-same-owner -xzf "$tmp/$tgz" -C "$tmp"
  while IFS= read -r -d '' p; do
    case "$(realpath -- "$p")" in
      "$tmp"/*) : ;;
      *) echo "!! tarball member escaped extraction dir: $p" >&2; exit 1 ;;
    esac
  done < <(find "$tmp" -mindepth 1 -path "$tmp/package" -prune -o -print0 2>/dev/null)

  # npm's bundler-target package ships zeta_wasm_bg.js; the web target the
  # playground wants ships zeta_wasm.js as a self-initializing module. Prefer a
  # pkg-web/ dir inside the tarball if present, else fall back to package/.
  srcdir="$tmp/package"
  [[ -d "$tmp/package/pkg-web" ]] && srcdir="$tmp/package/pkg-web"
  for f in "${files[@]}"; do
    if [[ -f "$srcdir/$f" ]]; then
      cp "$srcdir/$f" "$dest/$f"
    else
      echo "!! $f not found in published package — the npm package may ship the" >&2
      echo "   bundler target only. Build the web target from source instead" >&2
      echo "   (see scripts/build-from-source.sh) or attach pkg-web to the release." >&2
      exit 1
    fi
  done
  # The notices file ships at the tarball's package root (npm `files` list); it
  # may not be inside a pkg-web/ subdir. Copy best-effort from either location.
  if [[ -f "$srcdir/$notices_file" ]]; then
    cp "$srcdir/$notices_file" "$dest/$notices_file"
  elif [[ -f "$tmp/package/$notices_file" ]]; then
    cp "$tmp/package/$notices_file" "$dest/$notices_file"
  else
    echo "    (warning: $notices_file not found in package — should ship with the .wasm)" >&2
  fi
fi

echo "==> done. Artifact in $dest:"
ls -la "$dest"
echo
echo "Run the playground:"
echo "  python3 -m http.server -d playground 8080   # then open http://localhost:8080"
