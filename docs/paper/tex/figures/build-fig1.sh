#!/usr/bin/env bash
# Reproducibly convert the hand-authored architecture SVG to a tight, vector PDF
# for LaTeX/arXiv. arXiv does not run Inkscape, so we ship the PDF, not the SVG.
#
# Pipeline: headless Chrome renders the SVG to a (letter-padded) vector PDF, then
# Ghostscript measures the content bounding box and crops to it with a small
# margin. Output stays vector (embedded fonts), which pdffonts can confirm.
#
# Requires: google-chrome-stable (or chromium), ghostscript (gs).
set -euo pipefail
cd "$(dirname "$0")"

SRC="../../figures/fig1-architecture.svg"
RAW="$(mktemp --suffix=.pdf)"
OUT="fig1-architecture.pdf"
MARGIN=4  # pts around the content box

CHROME="$(command -v google-chrome-stable || command -v google-chrome || command -v chromium || command -v chromium-browser)"

# 1. SVG -> vector PDF (padded to letter by Chrome).
"$CHROME" --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
  --print-to-pdf="$RAW" "file://$(readlink -f "$SRC")" >/dev/null 2>&1

# 2. Measure the content bounding box.
read -r x0 y0 x1 y1 < <(
  gs -q -dNOPAUSE -dBATCH -sDEVICE=bbox "$RAW" 2>&1 \
    | awk '/HiResBoundingBox/ {print $2, $3, $4, $5}'
)

# 3. Crop to the box + margin, preserving vector content.
W=$(awk "BEGIN{printf \"%d\", ($x1-$x0)+2*$MARGIN + 0.999}")
H=$(awk "BEGIN{printf \"%d\", ($y1-$y0)+2*$MARGIN + 0.999}")
OX=$(awk "BEGIN{printf \"%.3f\", -($x0-$MARGIN)}")
OY=$(awk "BEGIN{printf \"%.3f\", -($y0-$MARGIN)}")

gs -q -o "$OUT" -sDEVICE=pdfwrite \
   -dDEVICEWIDTHPOINTS="$W" -dDEVICEHEIGHTPOINTS="$H" -dFIXEDMEDIA \
   -c "<</PageOffset [$OX $OY]>> setpagedevice" -f "$RAW"

rm -f "$RAW"
echo "wrote $OUT (${W}x${H} pts)"
pdffonts "$OUT" | head -4
