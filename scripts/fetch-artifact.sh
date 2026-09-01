#!/usr/bin/env bash
# Fetch the published zeta-lite wasm artifact into playground/pkg-web/.
#
# The compiled engine (zeta_wasm_bg.wasm + wasm-bindgen JS glue) is NOT committed
# to this repo. It is built in the closed Zeta monorepo and attached to this
# repo's GitHub Releases as loose files with a SHA256SUMS manifest. This script
# pulls the web-target build so the playground can run without a Rust/wasm
# toolchain.
#
# Sources (in order of how you select them):
#   ./scripts/fetch-artifact.sh v0.1.0        # from GitHub Release tag v0.1.0
#   ./scripts/fetch-artifact.sh               # from the latest GitHub Release
#   ZETA_LITE_PKG=/path/to/pkg-web ./scripts/fetch-artifact.sh   # from a local build
#   ZETA_LITE_SOURCE=npm ./scripts/fetch-artifact.sh v0.1.0      # from npm (future)
#
# The GitHub-Release path uses plain curl against public release-asset URLs and
# verifies every file against the release's SHA256SUMS (fails closed on any
# mismatch or missing file). It works once the release is PUBLIC. Before launch,
# while the repo is still private, release assets are not reachable by anonymous
# curl — use the ZETA_LITE_PKG local path to smoke-test against your local build.
#
# Requires: curl + sha256sum (GitHub-Release path), or a local pkg-web dir via
# ZETA_LITE_PKG, or npm (ZETA_LITE_SOURCE=npm).
set -euo pipefail

repo_slug="${ZETA_LITE_REPO:-genezhang/zeta-lite}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
dest="$root/playground/pkg-web"
mkdir -p "$dest"

# The web-target files the playground imports (playground/index.html loads
# ./pkg-web/zeta_wasm.js). Keep this list in sync with a wasm-bindgen --target web
# output set.
files=(zeta_wasm.js zeta_wasm_bg.wasm zeta_wasm.d.ts zeta_wasm_bg.wasm.d.ts)

# These travel WITH the .wasm but are not imported by the playground:
#   - THIRD-PARTY-NOTICES.txt : third-party license notices (legally required).
#   - build-info.json         : provenance — which monorepo commit / zeta-wasm
#                               tag produced this artifact, for bug triage.
# Copied best-effort (warn, don't fail) so an older artifact that predates them
# doesn't break the fetch — but a current artifact always carries both.
sidecar_files=(THIRD-PARTY-NOTICES.txt build-info.json)

if [[ -n "${ZETA_LITE_PKG:-}" ]]; then
  echo "==> copying artifact from local build: $ZETA_LITE_PKG"
  for f in "${files[@]}"; do
    cp "$ZETA_LITE_PKG/$f" "$dest/$f"
  done
  for f in "${sidecar_files[@]}"; do
    if [[ -f "$ZETA_LITE_PKG/$f" ]]; then
      cp "$ZETA_LITE_PKG/$f" "$dest/$f"
    else
      echo "    (warning: $f not found in build — should ship with the .wasm)" >&2
    fi
  done

elif [[ "${ZETA_LITE_SOURCE:-github}" == "npm" ]]; then
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
  # Sidecars ship at the tarball's package root (npm `files` list); they may not
  # be inside a pkg-web/ subdir. Copy best-effort from either location.
  for f in "${sidecar_files[@]}"; do
    if [[ -f "$srcdir/$f" ]]; then
      cp "$srcdir/$f" "$dest/$f"
    elif [[ -f "$tmp/package/$f" ]]; then
      cp "$tmp/package/$f" "$dest/$f"
    else
      echo "    (warning: $f not found in package — should ship with the .wasm)" >&2
    fi
  done

else
  # Default: GitHub Release. Download loose assets by URL and verify every one
  # against the release's SHA256SUMS manifest (fail closed).
  tag="${1:-}"
  if [[ -z "$tag" ]]; then
    echo "==> resolving latest GitHub Release of $repo_slug"
    # The /releases/latest web URL redirects to /releases/tag/<tag>; read the
    # final URL to learn the tag without needing jq or the gh CLI.
    latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      "https://github.com/$repo_slug/releases/latest" 2>/dev/null || true)"
    tag="${latest_url##*/tag/}"
    if [[ -z "$tag" || "$tag" == "$latest_url" ]]; then
      echo "!! could not resolve a latest release for $repo_slug." >&2
      echo "   Pass an explicit tag (e.g. v0.1.0), or if the repo/release is still" >&2
      echo "   private, smoke-test with ZETA_LITE_PKG=/path/to/pkg-web instead." >&2
      exit 1
    fi
  fi
  # Normalize to a v-prefixed tag (release tags are v0.1.0).
  [[ "$tag" == v* ]] || tag="v$tag"
  base="https://github.com/$repo_slug/releases/download/$tag"
  echo "==> fetching zeta-lite $tag from GitHub Release assets"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # The integrity manifest is mandatory on this path — no manifest, no trust.
  if ! curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"; then
    echo "!! could not download $base/SHA256SUMS" >&2
    echo "   The release may be private (anonymous curl can't read private" >&2
    echo "   assets — use ZETA_LITE_PKG for local testing), the tag may be" >&2
    echo "   wrong, or the release may not carry a SHA256SUMS manifest." >&2
    exit 1
  fi

  # Download every asset named in the manifest (core files + whatever sidecars
  # the release shipped), so verification covers exactly what's published.
  manifest_names=()
  while read -r _sum name; do
    [[ -z "$name" ]] && continue
    name="${name#\*}"   # sha256sum manifests may prefix binary files with '*'
    manifest_names+=("$name")
  done < "$tmp/SHA256SUMS"

  for f in "${manifest_names[@]}"; do
    if ! curl -fsSL "$base/$f" -o "$tmp/$f"; then
      echo "!! listed in SHA256SUMS but not downloadable: $f" >&2
      exit 1
    fi
  done

  # Fail closed on any checksum mismatch or missing file.
  echo "    verifying SHA256SUMS…"
  if ! ( cd "$tmp" && sha256sum -c --strict SHA256SUMS ); then
    echo "!! checksum verification FAILED — refusing to install." >&2
    exit 1
  fi

  # Required web-target files must all be present in the verified set.
  for f in "${files[@]}"; do
    if [[ -f "$tmp/$f" ]]; then
      cp "$tmp/$f" "$dest/$f"
    else
      echo "!! $f not present in the release assets (SHA256SUMS listed:" >&2
      printf '   %s\n' "${manifest_names[@]}" >&2
      exit 1
    fi
  done
  # Sidecars: copy if the release carried them (they should).
  for f in "${sidecar_files[@]}"; do
    if [[ -f "$tmp/$f" ]]; then
      cp "$tmp/$f" "$dest/$f"
    else
      echo "    (warning: $f not in release assets — should ship with the .wasm)" >&2
    fi
  done
fi

echo "==> done. Artifact in $dest:"
ls -la "$dest"
if [[ -f "$dest/build-info.json" ]]; then
  echo
  echo "Provenance (build-info.json):"
  cat "$dest/build-info.json"
  echo
fi
echo
echo "Run the playground:"
echo "  python3 -m http.server -d playground 8080   # then open http://localhost:8080"
