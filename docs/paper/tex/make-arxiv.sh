#!/usr/bin/env bash
# Build a self-contained arXiv submission tarball.
#
# arXiv compiles the sources itself with pdfLaTeX and will NOT run Inkscape,
# shell scripts, or fetch anything. So the tarball ships:
#   - main.tex               the paper source
#   - figures/*.pdf          the pre-converted vector figure(s)
#   - 00README.XXX           tells arXiv to use pdflatex (no bibtex needed:
#                            references are inline \bibitem, so the .bbl is moot)
#
# The figure PDF is regenerated from the hand-authored SVG by
# figures/build-fig1.sh (needs Chrome + ghostscript) — run that first if the
# SVG changed. It is intentionally committed so arXiv can build without it.
set -euo pipefail
cd "$(dirname "$0")"

OUT="arxiv-zeta-lite.tar.gz"

# Clean local build so the tarball carries only sources arXiv needs.
latexmk -C >/dev/null 2>&1 || true

# arXiv processing hint: single pdflatex engine.
cat > 00README.XXX <<'EOF'
\pdflatex
EOF

tar --exclude='*.aux' --exclude='*.log' --exclude='*.out' \
    --exclude='*.fls' --exclude='*.fdb_latexmk' --exclude='*.bbl' \
    --exclude='*.blg' --exclude='.gitignore' --exclude="$OUT" \
    -czf "$OUT" \
    main.tex 00README.XXX figures/fig1-architecture.pdf

echo "wrote $(pwd)/$OUT"
tar -tzf "$OUT"
echo
echo "Local sanity build:"
latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex >/dev/null 2>&1 \
  && echo "  OK — main.pdf builds ($(pdfinfo main.pdf | awk '/Pages/{print $2}') pages)" \
  || echo "  FAILED — check: latexmk -pdf main.tex"
