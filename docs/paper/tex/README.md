# Zeta-Lite paper — LaTeX / arXiv source

This directory holds the arXiv-ready LaTeX build of the zeta-lite technical
report. The authoritative prose lives one level up in `../draft.md`; this is the
typeset version prepared for submission.

## Files

- `main.tex` — the paper (single file; references are inline `\bibitem`, so no
  external `.bib` and no BibTeX pass is required).
- `figures/fig1-architecture.pdf` — the architecture figure as a tight **vector**
  PDF (embedded fonts). Committed on purpose: arXiv builds the sources itself and
  will not run Inkscape or any converter.
- `figures/build-fig1.sh` — regenerates that PDF from the hand-authored SVG
  (`../figures/fig1-architecture.svg`) via headless Chrome + Ghostscript. Run it
  only when the SVG changes.
- `make-arxiv.sh` — produces `arxiv-zeta-lite.tar.gz`, the self-contained
  submission tarball, and does a local sanity build.

## Build locally

```sh
latexmk -pdf main.tex        # -> main.pdf (16 pages)
```

Requires a TeX Live with `booktabs`, `hyperref`, `microtype`, `graphicx`,
`listings`, `enumitem`, `geometry` (all standard). No shell-escape, no network.

## Regenerate the figure (only if the SVG changed)

```sh
cd figures && ./build-fig1.sh     # needs google-chrome-stable + gs
```

## Make the arXiv tarball

```sh
./make-arxiv.sh                   # -> arxiv-zeta-lite.tar.gz
```

Upload that tarball to arXiv. It contains `main.tex`, the figure PDF, and a
`00README.XXX` that pins the engine to pdfLaTeX. arXiv runs `pdflatex` twice
itself; the inline bibliography needs no BibTeX.

## Pre-submission checklist

- [ ] Upgrade draft-grade references to archival/DOI forms — verify the Berenson
      et al. SIGMOD 1995 page numbers and the Neon/Dolt/PlanetScale/SQLite URLs.
- [ ] Re-confirm the published-release wasm gzip size still matches the 2.87 MB
      quoted in the abstract and §7.4.

## arXiv categories

- **Primary:** `cs.DB` (Databases) — the paper's core.
- **Cross-list:** `cs.AI` (Artificial Intelligence) — the agentic-memory use
  case and title theme; and `cs.SE` (Software Engineering) — the one-codebase /
  build-target / wasm-vs-WASI design-space account (§3.1, §4).

These are set on the arXiv submission form, not in `main.tex`. The paper itself
carries a Keywords + ACM CCS block under the abstract for indexing.
