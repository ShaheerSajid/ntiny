# ntiny microarchitecture document

Bottom-up, module-by-module reference for the ntiny core. Diagrams are Mermaid;
the prose lives in LaTeX; everything compiles to `microarch.pdf`.

## Layout
- `microarch.tex` — main LaTeX document (title, intro, `\input{src/*}`)
- `src/*.tex`      — one section per module (prose + figures)
- `diagrams/*.mmd` — Mermaid sources (minimal text; detail is in the prose)
- `diagrams/render.py` — render one `.mmd` -> `figures/*.svg,png` (mmdc or Kroki)
- `figures/*`      — generated svg/png/pdf (build artifacts)
- `build.py`       — render all diagrams -> PDF figures -> compile `microarch.pdf`

## Build
```
python3 build.py            # diagrams + PDF
python3 build.py --no-latex # diagrams only
```
Needs: `cairosvg` (svg->pdf), `latexmk`/`pdflatex`. Diagram rendering uses a
local `mmdc` (`npm i -g @mermaid-js/mermaid-cli`) if present, else Kroki (web).

## Conventions
See the Introduction section of the PDF for the shape/colour vocabulary.
