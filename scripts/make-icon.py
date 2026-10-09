#!/usr/bin/env python3
"""Draw the app icon and turn it into an .icns.

Run by scripts/bundle.sh. Kept as a script rather than a checked-in binary so the mark is
reviewable and reproducible — an icon that exists only as a blob in the repo is an icon nobody
can change.

The design is deliberately plain: a dark rounded square, "60", and one amber bar. It has to read
at 16 px in the Dock and in the menu bar's "About" panel, and detail does not survive that.
"""

import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

# The macOS icon grid: artwork occupies ~80% of the canvas, with the corner radius that
# proportion implies. A full-bleed rounded rect looks oversized next to Apple's own icons.
CANVAS = 1024
INSET = 100
SIDE = CANVAS - 2 * INSET
RADIUS = 185

TOP = (44, 44, 54)
BOTTOM = (18, 18, 24)
AMBER = (232, 163, 61)

FONTS = [
    "/System/Library/Fonts/SFNSDisplay-Bold.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
]


def load_font(size):
    for path in FONTS:
        if not os.path.exists(path):
            continue
        try:
            font = ImageFont.truetype(path, size)
        except OSError:
            continue
        # SFNS is a variable font and FreeType hands back the *default* instance — Regular.
        # Asking for the named instance is the difference between a mark that looks drawn and
        # one that looks like a placeholder. A static font raises here, which is fine: it is
        # already whatever weight it is.
        try:
            font.set_variation_by_name("Bold")
        except (OSError, ValueError):
            pass
        return font
    raise SystemExit("no usable font found; looked in: " + ", ".join(FONTS))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw():
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # Vertical gradient, built as one column and stretched. Cheaper and smoother than drawing
    # a line per row.
    column = Image.new("RGB", (1, SIDE))
    pixels = column.load()
    for y in range(SIDE):
        t = y / (SIDE - 1)
        pixels[0, y] = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    body = column.resize((SIDE, SIDE), Image.BILINEAR).convert("RGBA")
    canvas.paste(body, (INSET, INSET), rounded_mask(SIDE, RADIUS))

    draw_on = ImageDraw.Draw(canvas)

    # A single highlight along the top edge. This is what stops a flat gradient from looking
    # like a hole punched in the Dock.
    draw_on.rounded_rectangle(
        (INSET + 3, INSET + 3, INSET + SIDE - 3, INSET + SIDE - 3),
        radius=RADIUS - 3,
        outline=(255, 255, 255, 26),
        width=3,
    )

    font = load_font(430)
    text = "60"
    left, top, right, bottom = draw_on.textbbox((0, 0), text, font=font)
    x = INSET + (SIDE - (right - left)) / 2 - left
    # Optically centred rather than mathematically: digits have no descender, so a true centre
    # leaves the mark sitting visibly low.
    y = INSET + SIDE * 0.44 - (bottom - top) / 2 - top
    draw_on.text((x, y), text, font=font, fill=(245, 246, 250, 255))

    bar_w, bar_h = 250, 26
    bar_y = INSET + SIDE * 0.72
    draw_on.rounded_rectangle(
        (INSET + (SIDE - bar_w) / 2, bar_y, INSET + (SIDE + bar_w) / 2, bar_y + bar_h),
        radius=bar_h // 2,
        fill=AMBER + (255,),
    )

    return canvas


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "build/icon"
    os.makedirs(out_dir, exist_ok=True)

    master = draw()
    master.save(os.path.join(out_dir, "icon-1024.png"))

    iconset = os.path.join(out_dir, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    # The names are fixed by iconutil and the sizes are the ones macOS actually asks for.
    # 16 and 32 are drawn from the master rather than hand-hinted; at that size a separate
    # simplified mark would be better, and this is honest about not having one.
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    icns = os.path.join(out_dir, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print(f"wrote {icns}")


if __name__ == "__main__":
    main()
