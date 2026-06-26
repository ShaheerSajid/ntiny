#!/usr/bin/env python3
"""render.py <file.mmd> — render a Mermaid diagram to ../figures/<name>.{svg,png}.

Prefers a local `mmdc` (mermaid-cli, offline); falls back to the Kroki web
service if mmdc is absent.
"""
import sys, os, shutil, subprocess, base64, zlib, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FIGS = os.path.normpath(os.path.join(HERE, "..", "figures"))
os.makedirs(FIGS, exist_ok=True)

src = sys.argv[1]
stem = os.path.splitext(os.path.basename(src))[0]
out_svg = os.path.join(FIGS, stem + ".svg")
out_png = os.path.join(FIGS, stem + ".png")
code = open(src).read()


def via_mmdc():
    if not shutil.which("mmdc"):
        return False
    cfg = os.path.join(HERE, "mmdc.json")
    if not os.path.exists(cfg):
        open(cfg, "w").write('{"theme":"neutral","flowchart":'
                             '{"htmlLabels":true,"curve":"basis"}}')
    for out in (out_svg, out_png):
        subprocess.run(["mmdc", "-i", src, "-o", out, "-c", cfg, "-b", "white",
                        "--scale", "2"], check=True)
    return True


def via_kroki(fmt, out):
    enc = base64.urlsafe_b64encode(zlib.compress(code.encode(), 9)).decode()
    req = urllib.request.Request(f"https://kroki.io/mermaid/{fmt}/{enc}",
                                 headers={"User-Agent": "curl/8"})
    open(out, "wb").write(urllib.request.urlopen(req, timeout=40).read())


if via_mmdc():
    print("mmdc  ->", os.path.relpath(out_svg))
else:
    via_kroki("svg", out_svg)
    via_kroki("png", out_png)
    print("kroki ->", os.path.relpath(out_svg))
