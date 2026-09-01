#!/usr/bin/env bash
# Cut a zeta-lite GitHub Release from a locally-built pkg-web/ directory.
#
# v0.1 distributes the wasm as loose GitHub Release assets (no npm). This script
# takes the web-target build produced in the closed monorepo, generates a
# SHA256SUMS manifest over every asset, and creates (or updates) the GitHub
# Release with those assets attached. scripts/fetch-artifact.sh then downloads
# and verifies them against that manifest.
#
# Usage:
#   scripts/cut-release.sh v0.1.0 /path/to/pkg-web
#   scripts/cut-release.sh v0.1.0 /path/to/pkg-web --draft   # stage without publishing
#
# The pkg-web dir must contain the 4 web-target files and should contain the two
# sidecars (notices + provenance). build-info.json is what lets a bug report name
# the exact engine build, so its absence is a hard error, not a warning.
#
# Requires: gh (authenticated), sha256sum. Run from a clean checkout on the tag's
# target commit (the release is created against the current default branch head
# unless the tag already exists).
set -euo pipefail

repo_slug="${ZETA_LITE_REPO:-genezhang/zeta-lite}"

tag="${1:-}"
pkg="${2:-}"
draft_flag=""
[[ "${3:-}" == "--draft" ]] && draft_flag="--draft"

if [[ -z "$tag" || -z "$pkg" ]]; then
  echo "usage: $0 <tag e.g. v0.1.0> <path/to/pkg-web> [--draft]" >&2
  exit 2
fi
[[ "$tag" == v* ]] || { echo "!! tag should be v-prefixed (e.g. v0.1.0), got: $tag" >&2; exit 2; }
[[ -d "$pkg" ]] || { echo "!! pkg-web dir not found: $pkg" >&2; exit 2; }

# Required web-target files — must all be present.
required=(zeta_wasm.js zeta_wasm_bg.wasm zeta_wasm.d.ts zeta_wasm_bg.wasm.d.ts)
# Sidecars that travel with the wasm.
notices="THIRD-PARTY-NOTICES.txt"
buildinfo="build-info.json"

missing=0
for f in "${required[@]}"; do
  [[ -f "$pkg/$f" ]] || { echo "!! missing required asset: $f" >&2; missing=1; }
done
[[ "$missing" == 0 ]] || exit 1

# Provenance is mandatory for a real release — refuse to ship an artifact that
# can't be traced back to an engine commit.
if [[ ! -f "$pkg/$buildinfo" ]]; then
  echo "!! $buildinfo is required (engine commit / zeta-wasm tag provenance)." >&2
  echo "   Have the monorepo build write it into pkg-web/. Example:" >&2
  echo '   { "package": "'"${tag#v}"'", "engineCommit": "<short-sha>",' >&2
  echo '     "monorepoTag": "zeta-wasm-'"$tag"'", "built": "'"$(date -u +%Y-%m-%d)"'" }' >&2
  exit 1
fi
if [[ ! -f "$pkg/$notices" ]]; then
  echo "!! $notices is required (third-party license notices ship with the wasm)." >&2
  exit 1
fi

echo "==> provenance for this release:"
cat "$pkg/$buildinfo"
echo

# Stage assets + a manifest in a temp dir so we never mutate the source build.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
assets=("${required[@]}" "$notices" "$buildinfo")
for f in "${assets[@]}"; do cp "$pkg/$f" "$tmp/$f"; done

echo "==> generating SHA256SUMS over ${#assets[@]} assets"
( cd "$tmp" && sha256sum "${assets[@]}" > SHA256SUMS )
cat "$tmp/SHA256SUMS" | awk '{print "    "substr($1,1,16)"…  "$2}'
echo

# Assemble the upload list (assets + the manifest itself).
upload=()
for f in "${assets[@]}" SHA256SUMS; do upload+=("$tmp/$f"); done

notes_file="$tmp/RELEASE_NOTES.md"
if [[ -f "$(dirname "$0")/../docs/release/${tag}.md" ]]; then
  cp "$(dirname "$0")/../docs/release/${tag}.md" "$notes_file"
  echo "==> using release notes: docs/release/${tag}.md"
else
  echo "==> no docs/release/${tag}.md found; using a minimal auto note"
  printf 'zeta-lite %s\n\nSee the repository README for details.\n' "$tag" > "$notes_file"
fi

# Create or update the release. If the tag exists we update assets; otherwise gh
# creates the tag against the current default-branch head.
if gh release view "$tag" -R "$repo_slug" >/dev/null 2>&1; then
  echo "==> release $tag exists — uploading/overwriting assets"
  gh release upload "$tag" "${upload[@]}" -R "$repo_slug" --clobber
  gh release edit "$tag" -R "$repo_slug" --notes-file "$notes_file"
else
  echo "==> creating release $tag ${draft_flag:+(draft)}"
  gh release create "$tag" "${upload[@]}" \
    -R "$repo_slug" \
    --title "zeta-lite $tag" \
    --notes-file "$notes_file" \
    $draft_flag
fi

echo
echo "==> done. Verify the consumer path:"
echo "    ./scripts/fetch-artifact.sh $tag     # downloads + checks SHA256SUMS"
echo "  (works once the release/repo is public; while private, use ZETA_LITE_PKG)"
