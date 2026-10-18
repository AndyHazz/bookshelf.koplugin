"""Rasterize the binding fixture's rectangles and labels (requires Pillow).

Usage: python3 tests/render_book_bindings.py /tmp/book-bindings.png
This is a headless painter comparison, not a KOReader device screenshot.
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent.parent
svg = subprocess.check_output(["lua", "tests/render_book_bindings.lua"], cwd=root)
tree = ET.fromstring(svg)
image = Image.new("RGBA", (int(tree.attrib["width"]), int(tree.attrib["height"])))
draw = ImageDraw.Draw(image)
for node in tree.iter():
    attrs = node.attrib
    if node.tag.endswith("}rect"):
        x, y, w, h = (int(float(attrs[key])) for key in ("x", "y", "width", "height"))
        if w and h:
            draw.rectangle((x, y, x + w - 1, y + h - 1), fill=attrs["fill"])
    elif node.tag.endswith("}text"):
        x, y = int(attrs["x"]), int(attrs["y"])
        size = int(attrs["font-size"])
        weight = "Bold" if size >= 23 else "Regular"
        font = ImageFont.truetype(str(root / "fonts" / f"RobotoCondensed-{weight}.ttf"), size)
        layer = Image.new("RGBA", image.size)
        ImageDraw.Draw(layer).text(
            (x, y), node.text, font=font, fill=attrs.get("fill", "#222"),
            anchor="ms" if attrs.get("text-anchor") == "middle" else "ls",
        )
        if "transform" in attrs:
            angle, cx, cy = map(float, re.fullmatch(r"rotate\((\S+) (\S+) (\S+)\)", attrs["transform"]).groups())
            layer = layer.rotate(-angle, center=(cx, cy))
        image.alpha_composite(layer)
image.convert("RGB").save(sys.argv[1])
