#!/usr/bin/env python3
"""Generate a macOS .icns icon for PathOfBuilding PoE2."""

import math
import os
import subprocess
import sys
import tempfile

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.exit("PIL not found: pip3 install Pillow")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "macos")


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx = cy = size / 2

    # Dark background with rounded corners (macOS icon shape)
    pad = int(size * 0.03)
    r = int(size * 0.22)
    draw.rounded_rectangle([pad, pad, size - pad - 1, size - pad - 1],
                           radius=r,
                           fill=(18, 12, 8, 255))

    # Subtle radial glow at centre
    glow_r = int(size * 0.28)
    for i in range(glow_r, 0, -1):
        alpha = int(60 * (1 - i / glow_r) ** 2)
        draw.ellipse([cx - i, cy - i, cx + i, cy + i],
                     fill=(160, 110, 30, alpha))

    # Three concentric golden rings (outer → inner, decreasing opacity)
    rings = [
        (0.42, 6, (212, 175, 55, 230)),   # outer – bright gold
        (0.30, 4, (180, 140, 40, 180)),   # mid
        (0.18, 3, (150, 110, 30, 130)),   # inner
    ]
    for rel_r, lw, colour in rings:
        rr = size * rel_r
        lw_scaled = max(1, int(lw * size / 256))
        for t in range(lw_scaled):
            o = t - lw_scaled // 2
            draw.ellipse([cx - rr + o, cy - rr + o,
                          cx + rr - o, cy + rr - o],
                         outline=colour)

    # Small node dots on the outer ring (like passive skill nodes)
    outer_r = size * 0.42
    node_r = max(2, int(size * 0.022))
    node_colour = (240, 200, 80, 255)
    n_nodes = 12
    for i in range(n_nodes):
        angle = 2 * math.pi * i / n_nodes - math.pi / 2
        nx = cx + outer_r * math.cos(angle)
        ny = cy + outer_r * math.sin(angle)
        draw.ellipse([nx - node_r, ny - node_r,
                      nx + node_r, ny + node_r],
                     fill=node_colour)

    # "PoB" text – try to load a system font, fall back to default
    font_size = max(8, int(size * 0.18))
    font = None
    for path in [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]:
        if os.path.exists(path):
            try:
                font = ImageFont.truetype(path, font_size)
                break
            except Exception:
                pass

    label = "PoB"
    sub_label = "PoE2"

    if font:
        bbox = draw.textbbox((0, 0), label, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
    else:
        tw, th = font_size * len(label) // 2, font_size

    tx = cx - tw / 2
    ty = cy - th / 2 - size * 0.035

    # Shadow
    shadow_draw = ImageDraw.Draw(img)
    shadow_draw.text((tx + 2, ty + 2), label, font=font, fill=(0, 0, 0, 180))

    # Gold gradient text simulation via two passes
    draw.text((tx, ty), label, font=font, fill=(240, 210, 80, 255))

    # Smaller sub-label "PoE2"
    sub_font_size = max(6, int(size * 0.085))
    sub_font = None
    for path in [
        "/System/Library/Fonts/Supplemental/Georgia.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]:
        if os.path.exists(path):
            try:
                sub_font = ImageFont.truetype(path, sub_font_size)
                break
            except Exception:
                pass

    if sub_font:
        sbbox = draw.textbbox((0, 0), sub_label, font=sub_font)
        stw = sbbox[2] - sbbox[0]
        sth = sbbox[3] - sbbox[1]
    else:
        stw, sth = sub_font_size * len(sub_label) // 2, sub_font_size

    stx = cx - stw / 2
    sty = ty + th + size * 0.01

    draw.text((stx + 1, sty + 1), sub_label, font=sub_font, fill=(0, 0, 0, 160))
    draw.text((stx, sty), sub_label, font=sub_font, fill=(200, 160, 60, 220))

    return img


def make_icns(out_path: str):
    iconset_dir = tempfile.mkdtemp(suffix=".iconset")
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for s in sizes:
        img = draw_icon(s)
        img.save(os.path.join(iconset_dir, f"icon_{s}x{s}.png"))
        if s <= 512:
            img2 = draw_icon(s * 2)
            img2.save(os.path.join(iconset_dir, f"icon_{s}x{s}@2x.png"))

    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", out_path], check=True)
    print(f"Created {out_path}")


if __name__ == "__main__":
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT_DIR, "AppIcon.icns")
    make_icns(dest)
