#!/usr/bin/env python3
"""Draw the utilisation ceiling: sessions, stages, the GPU's flat profile, and the policy cost."""
from PIL import Image, ImageDraw, ImageFont

W, H = 1680, 1060
BG = (255, 255, 255)
INK = (28, 30, 34)
MUTED = (120, 126, 136)
GRID = (226, 229, 234)
BLUE = (52, 108, 196)
TEAL = (32, 148, 140)
PALE = (140, 176, 226)
GREY = (190, 200, 214)
ORANGE = (232, 138, 42)
RED = (200, 62, 62)
GREEN = (46, 150, 88)


def font(size, bold=False):
    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else
                 "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


F_TITLE = font(30, True)
F_SUB = font(17)
F_HEAD = font(20, True)
F_LAB = font(15)
F_SMALL = font(13)
F_BIG = font(26, True)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((54, 40), "Where the conversion's time actually goes", font=F_TITLE, fill=INK)
d.text((54, 80), "1200 source frames of the real 4K HDR film, 3840x1632, from -ss 900",
       font=F_SUB, fill=MUTED)


def panel(x, y, w, h, title, sub=None):
    """Draw the panel frame and return its inner box as (x, y, w, h)."""
    d.rounded_rectangle([x, y, x + w, y + h], radius=12, outline=GRID, width=2)
    d.text((x + 24, y + 18), title, font=F_HEAD, fill=INK)
    if sub:
        d.text((x + 24, y + 46), sub, font=F_SMALL, fill=MUTED)
    return (x + 24, y + 78, w - 48, h - 102)


# ---------------------------------------------------------------- A: sessions
ax, ay, aw, ah = panel(54, 126, 760, 400, "Sessions in parallel",
                       "the fourth is worth 1.15x; the fifth and sixth are worth less than nothing")
base_y = ay + ah - 40
top_y = ay + 8
data = [(1, 12.3, 52.1), (2, 20.2, None), (4, 23.3, 75.7), (6, 21.8, 68.8)]
bar_w, gap = 118, 44
span = len(data) * bar_w + (len(data) - 1) * gap
x0 = ax + (aw - span) / 2
for i, (sess, fps, gpu) in enumerate(data):
    bx = x0 + i * (bar_w + gap)
    bh = (fps / 26.0) * (base_y - top_y - 62)
    colour = GREEN if sess == 4 else BLUE
    d.rounded_rectangle([bx, base_y - bh, bx + bar_w, base_y], radius=6, fill=colour)
    d.text((bx + bar_w / 2, base_y - bh - 32), f"{fps:.1f}", font=F_BIG, fill=colour,
           anchor="mm")
    d.text((bx + bar_w / 2, base_y - bh - 10), "source fps", font=F_SMALL, fill=MUTED,
           anchor="mm")
    d.text((bx + bar_w / 2, base_y + 20), f"{sess} session" + ("s" if sess > 1 else ""),
           font=F_LAB, fill=INK, anchor="mm")
    if gpu is not None:
        d.text((bx + bar_w / 2, base_y + 42), f"GPU {gpu:.1f}%", font=F_SMALL,
               fill=MUTED, anchor="mm")
d.line([ax, base_y, ax + aw, base_y], fill=GRID, width=2)

# ---------------------------------------------------------------- B: stages
bx0, by0, bw, bh_ = panel(846, 126, 780, 400, "Four sessions: where the 51.6 s goes",
                          "the driver's own work, then the wait for a free slot")
segments = [("read", 10.2, BLUE), ("signature", 7.7, TEAL), ("load", 3.3, PALE),
            ("passthrough", 0.3, GREY)]
slot = 29.6
total = sum(v for _, v, _ in segments) + slot
bar_y = by0 + 30
bar_h = 54
bar_w_px = bw
x = bx0
for name, value, colour in segments:
    seg_w = (value / total) * bar_w_px
    d.rectangle([x, bar_y, x + seg_w, bar_y + bar_h], fill=colour)
    x += seg_w
slot_x = x
d.rectangle([slot_x, bar_y, bx0 + bar_w_px, bar_y + bar_h], fill=ORANGE)
d.text((bx0, bar_y - 26), "driver busy 21.6 s", font=F_LAB, fill=INK)
d.text((slot_x + 12, bar_y - 26), "waiting for a free slot  29.6 s", font=F_LAB, fill=ORANGE)
# legend, two columns
ly = bar_y + bar_h + 32
for i, (name, value, colour) in enumerate(segments):
    col = i % 2
    row = i // 2
    lx = bx0 + col * 215
    yy = ly + row * 30
    d.rectangle([lx, yy + 5, lx + 15, yy + 20], fill=colour)
    d.text((lx + 24, yy), f"{name}  {value:.1f}s", font=F_LAB, fill=INK)
d.text((bx0 + 452, bar_y + bar_h + 30),
       "The pool owns the\n"
       "whole 51.6 s. The driver's\n"
       "work happens underneath\n"
       "it, so removing all of it\n"
       "would save nothing.",
       font=F_LAB, fill=MUTED, spacing=7)

# ---------------------------------------------------------------- C: GPU
cx, cy, cw, ch = panel(54, 548, 760, 440, "GPU device utilisation, 97 samples",
                       "75 of 97 samples sit in the shaded 70-79% band - flat, not duty-cycling")
series = [30, 58, 70, 68, 73, 72, 75, 92, 72, 70, 73, 75, 79, 72, 73, 71, 70, 72, 73, 72,
          71, 69, 0, 72, 76, 74, 72, 72, 73, 70, 73, 72, 74, 75, 75, 74, 72, 69, 72, 67,
          73, 82, 71, 76, 69, 80, 72, 64, 72, 73, 68, 75, 71, 74, 65, 73, 71, 73, 80, 72,
          68, 73, 76, 74, 73, 75, 73, 71, 72, 0, 70, 76, 72, 68, 71, 75, 73, 71, 70, 77,
          78, 69, 68, 74, 0, 72, 57, 71, 74, 72, 70, 73, 72, 74, 70, 72, 74]
plot_x = cx + 46
plot_w = cw - 66
plot_h = ch - 92
plot_y = cy + 14
# highlight the 70-79% band
d.rectangle([plot_x, plot_y + plot_h * (1 - 0.79), plot_x + plot_w,
             plot_y + plot_h * (1 - 0.70)], fill=(242, 246, 252))
for frac in (0, 0.5, 1.0):
    y = plot_y + plot_h * (1 - frac)
    d.line([plot_x, y, plot_x + plot_w, y], fill=GRID, width=1)
    d.text((plot_x - 10, y), f"{int(frac*100)}%", font=F_SMALL, fill=MUTED, anchor="rm")
step = plot_w / (len(series) - 1)
points = [(plot_x + i * step, plot_y + plot_h * (1 - v / 100)) for i, v in enumerate(series)]
d.line(points, fill=BLUE, width=2, joint="curve")
d.text((plot_x - 6, plot_y + plot_h * (1 - 0.745)), "70-79", font=F_SMALL, fill=BLUE,
       anchor="rm")
d.text((plot_x, plot_y + plot_h + 20), "0 s", font=F_SMALL, fill=MUTED)
d.text((plot_x + plot_w, plot_y + plot_h + 20), "54 s", font=F_SMALL, fill=MUTED, anchor="ra")
d.text((plot_x + plot_w / 2, plot_y + plot_h + 42),
       "mean 75.7%   max 98%   (the dips to 0 are sampler misses)",
       font=F_SMALL, fill=MUTED, anchor="ma")

# ---------------------------------------------------------------- D: policy
dx, dy, dw, dh = panel(846, 548, 780, 440, "What macOS decides about the process",
                       "same conversion, same build, same machine - only the policy differs")
policies = [("default", 51.6, GREEN), ("utility tier", 53.7, BLUE),
            ("background", 180.5, RED)]
pbase = dy + dh - 74
ptop = dy + 44
pmax = 190.0
pw, pgap = 150, 90
pspan = len(policies) * pw + (len(policies) - 1) * pgap
px0 = dx + (dw - pspan) / 2
for i, (name, secs, colour) in enumerate(policies):
    bx = px0 + i * (pw + pgap)
    bh2 = (secs / pmax) * (pbase - ptop)
    d.rounded_rectangle([bx, pbase - bh2, bx + pw, pbase], radius=6, fill=colour)
    d.text((bx + pw / 2, pbase - bh2 - 30), f"{secs:.1f}s", font=F_BIG, fill=colour,
           anchor="mm")
    d.text((bx + pw / 2, pbase + 20), name, font=F_LAB, fill=INK, anchor="mm")
d.line([dx, pbase, dx + dw, pbase], fill=GRID, width=2)
d.text((px0 + 2 * (pw + pgap) + pw / 2, pbase + 44), "read 10.2 -> 75.7 s", font=F_SMALL,
       fill=MUTED, anchor="ma")
d.text((dx, dy + 2), "3.5x", font=F_BIG, fill=RED)
d.text((dx + 78, dy + 12), "the driver's threads are demoted off the performance cores",
       font=F_SMALL, fill=MUTED)

d.text((54, H - 44),
       "The CPU's 79% idle is structural - the work is per-pixel and on the GPU.  "
       "Four sessions is the framework's ceiling; two conversions at once are 31% slower than one.",
       font=F_SUB, fill=MUTED)

out = "/Users/Wasim/Desktop/FNF-60FPS-A-B/60FPS-utilisation-ceiling.png"
img.save(out)
print("wrote", out)
