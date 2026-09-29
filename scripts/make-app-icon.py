#!/usr/bin/env python3
"""Builds the macOS AppIcon set from the approved keycap artwork on Apple's macOS icon grid.

The brand pack's source is a full-bleed square with a dark background. macOS icons instead sit on
an 824 px rounded-square ("squircle") body inside a 1024 px canvas, with transparent margins and a
soft shadow, and the artwork fills most of the body. This crops the keycap from the approved
source without redrawing it, scales it onto that body, and writes every size the asset catalog
uses. Requires Pillow.

usage: scripts/make-app-icon.py [source.png] [output.appiconset]
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "brand/source/keybumps-key-with-accents.png"
OUTPUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "Keybumps/Resources/Assets.xcassets/AppIcon.appiconset"

CANVAS, BODY = 1024, 824          # Apple macOS icon grid
ARTWORK_FILL = 0.86               # keycap width as a share of the body width
SUPERSAMPLE = 4


def squircle_mask(size: int) -> Image.Image:
    """A continuous-corner rounded square (superellipse, n = 5), antialiased by supersampling."""
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    pixels = mask.load()
    half = big / 2
    for y in range(big):
        ny = abs((y + 0.5 - half) / half) ** 5
        for x in range(big):
            if abs((x + 0.5 - half) / half) ** 5 + ny <= 1:
                pixels[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    background = source.getpixel((4, 4))
    # Bounding box of everything that differs from the background (the keycap and accents).
    difference = Image.eval(source.convert("L"), lambda v: 0)
    px, dx = source.load(), difference.load()
    for y in range(source.height):
        for x in range(source.width):
            r, g, b = px[x, y]
            if abs(r - background[0]) + abs(g - background[1]) + abs(b - background[2]) > 40:
                dx[x, y] = 255
    left, top, right, bottom = difference.getbbox()
    artwork = source.crop((left, top, right, bottom))

    scale = BODY * ARTWORK_FILL / artwork.width
    artwork = artwork.resize((round(artwork.width * scale), round(artwork.height * scale)), Image.LANCZOS)

    body = Image.new("RGB", (BODY, BODY), background)
    body.paste(artwork, ((BODY - artwork.width) // 2, (BODY - artwork.height) // 2 + round(BODY * 0.02)))
    mask = squircle_mask(BODY)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (offset, offset + 12), mask)
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(14)))
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(body, (offset, offset), mask)
    icon = Image.alpha_composite(icon, layer)

    sizes = {16: [1, 2], 32: [1, 2], 128: [1, 2], 256: [1, 2], 512: [1, 2]}
    for point, scales in sizes.items():
        for factor in scales:
            pixels = point * factor
            name = f"icon_{point}x{point}{'@2x' if factor == 2 else ''}.png"
            icon.resize((pixels, pixels), Image.LANCZOS).save(OUTPUT / name)
    print(f"Wrote {OUTPUT} (keycap {artwork.width}x{artwork.height} on a {BODY} px body)")


if __name__ == "__main__":
    main()
