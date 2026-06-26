#!/usr/bin/env python3
"""build.py — render every Mermaid diagram, then compile the LaTeX document.

  diagrams/*.mmd --(render.py)--> figures/*.png  (always; text via Kroki/mmdc)
                                  figures/*.pdf  (vector, only when mmdc present)
  microarch.tex  --(latexmk)--> microarch.pdf

LaTeX prefers figures/<name>.pdf when it exists, else <name>.png
(\\DeclareGraphicsExtensions in microarch.tex), so installing mmdc upgrades all
figures to crisp vector automatically.

Usage: python3 build.py [--no-latex] [--force]
"""
import os, sys, glob, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
DIAG = os.path.join(HERE, "diagrams")
FIGS = os.path.join(HERE, "figures")
FORCE = "--force" in sys.argv


def render_all():
    for mmd in sorted(glob.glob(os.path.join(DIAG, "*.mmd"))):
        stem = os.path.splitext(os.path.basename(mmd))[0]
        png = os.path.join(FIGS, stem + ".png")
        if FORCE or (not os.path.exists(png)) or \
           os.path.getmtime(mmd) > os.path.getmtime(png):
            subprocess.run([sys.executable, os.path.join(DIAG, "render.py"), mmd],
                           check=True)
        print("figure:", stem)


def compile_tex():
    subprocess.run(["latexmk", "-pdf", "-interaction=nonstopmode",
                    "-halt-on-error", "microarch.tex"], cwd=HERE, check=False)
    pdf = os.path.join(HERE, "microarch.pdf")
    print("PDF:", pdf, "OK" if os.path.exists(pdf) else "MISSING")


if __name__ == "__main__":
    render_all()
    if "--no-latex" not in sys.argv:
        compile_tex()
