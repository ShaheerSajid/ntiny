#!/usr/bin/env python3
"""build.py — render every Mermaid diagram to a PDF figure, then compile the
LaTeX microarchitecture document.

  diagrams/*.mmd --(render.py)--> figures/*.svg --(cairosvg)--> figures/*.pdf
  microarch.tex  --(latexmk)--> microarch.pdf

Usage: python3 build.py [--no-latex]
"""
import os, sys, glob, subprocess
import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
DIAG = os.path.join(HERE, "diagrams")
FIGS = os.path.join(HERE, "figures")


def render_all():
    for mmd in sorted(glob.glob(os.path.join(DIAG, "*.mmd"))):
        stem = os.path.splitext(os.path.basename(mmd))[0]
        svg = os.path.join(FIGS, stem + ".svg")
        pdf = os.path.join(FIGS, stem + ".pdf")
        if (not os.path.exists(svg)) or os.path.getmtime(mmd) > os.path.getmtime(svg):
            subprocess.run([sys.executable, os.path.join(DIAG, "render.py"), mmd],
                           check=True)
        cairosvg.svg2pdf(url=svg, write_to=pdf)
        print("figure:", os.path.basename(pdf))


def compile_tex():
    subprocess.run(["latexmk", "-pdf", "-interaction=nonstopmode",
                    "-halt-on-error", "microarch.tex"], cwd=HERE, check=False)
    pdf = os.path.join(HERE, "microarch.pdf")
    print("PDF:", pdf, "OK" if os.path.exists(pdf) else "MISSING")


if __name__ == "__main__":
    render_all()
    if "--no-latex" not in sys.argv:
        compile_tex()
