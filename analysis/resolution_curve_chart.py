#!/usr/bin/env python3
"""Draw why 4K cannot reach 60 fps: the width staircase, the equal-pixel control, and SVP's model.

Numbers are from BUILD-DECISIONS.md section 29, measured on the release build:
192 source frames of the real film, 24000/1001 -> 60000/1001, depth 2.
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 1680, 1100
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
WASH = (253, 240, 240)


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
F_HUGE = font(44, True)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

d.text((54, 40), "Why this machine cannot interpolate 4K at 60 fps", font=F_TITLE, fill=INK)
d.text((54, 80), "Cost is a step function of frame WIDTH, not of pixel count  -  "
                 "and only the 1920-wide resolutions meet the film's budget",
       font=F_SUB, fill=MUTED)


def panel(x, y, w, h, title, sub=None):
    """Draw the panel frame and return its inner box as (x, y, w, h)."""
    d.rounded_rectangle([x, y, x + w, y + h], radius=12, outline=GRID, width=2)
    d.text((x + 24, y + 18), title, font=F_HEAD, fill=INK)
    if sub:
        d.text((x + 24, y + 46), sub, font=F_SMALL, fill=MUTED)
    return (x + 24, y + 78, w - 48, h - 102)


BUDGET = 41.7
Y_MAX = 115.0

# ---------------------------------------------------------------- A: the staircase
ax, ay, aw, ah = panel(54, 126, 1572, 452, "Cost against width",
                       "the film spends 41.7 ms per interval - every red bar is a dropped frame")
plot_x = ax + 58
plot_w = aw - 82
base_y = ay + ah - 58
top_y = ay + 10
span_h = base_y - top_y


def py(ms):
    return base_y - (ms / Y_MAX) * span_h


y_budget = py(BUDGET)
d.rectangle([plot_x, top_y, plot_x + plot_w, y_budget], fill=WASH)

for ms in (0, 20, 40, 60, 80, 100):
    y = py(ms)
    d.line([plot_x, y, plot_x + plot_w, y], fill=GRID, width=1)
    d.text((plot_x - 12, y), f"{ms}", font=F_SMALL, fill=MUTED, anchor="rm")
d.text((plot_x - 12, top_y - 4), "ms", font=F_SMALL, fill=MUTED, anchor="rm")

bars = [
    ("1920x816", 31.87, "1.57 Mpx"),
    ("1920x1088", 40.73, "2.09 Mpx"),
    ("1984x844", 52.01, "1.67 Mpx"),
    ("2048x870", 50.96, "1.78 Mpx"),
    ("2560x816", 78.53, "2.09 Mpx"),
    ("3384x1440", 81.55, "4.87 Mpx"),
    ("3840x1632", 104.7, "6.27 Mpx"),
]
bar_w, gap = 132, 54
span = len(bars) * bar_w + (len(bars) - 1) * gap
x0 = plot_x + (plot_w - span) / 2

d.line([plot_x, base_y, plot_x + plot_w, base_y], fill=GRID, width=2)

for i, (name, ms, mpx) in enumerate(bars):
    bx = x0 + i * (bar_w + gap)
    hgt = (ms / Y_MAX) * span_h
    colour = GREEN if ms <= BUDGET else RED
    d.rounded_rectangle([bx, base_y - hgt, bx + bar_w, base_y], radius=6, fill=colour)
    d.text((bx + bar_w / 2, base_y - hgt - 22), f"{ms:.2f}", font=F_BIG, fill=colour,
           anchor="mm")
    d.text((bx + bar_w / 2, base_y + 20), name, font=F_LAB, fill=INK, anchor="mm")
    d.text((bx + bar_w / 2, base_y + 40), mpx, font=F_SMALL, fill=MUTED, anchor="mm")

d.line([plot_x, y_budget, plot_x + plot_w, y_budget], fill=RED, width=2)
d.text((plot_x + 6, y_budget - 24), "41.7 ms budget  -  real time at 59.94",
       font=F_LAB, fill=RED, anchor="lm")
d.text((plot_x + 6, top_y + 8), "green = meets the budget      red = misses it",
       font=F_SMALL, fill=MUTED)

# the step, annotated between the 1920 and 1984 bars
step_x1 = x0 + 1 * (bar_w + gap) + bar_w
step_x2 = x0 + 2 * (bar_w + gap)
d.line([step_x1, py(41.7) - 46, step_x2, py(41.7) - 46], fill=TEAL, width=2)
d.text(((step_x1 + step_x2) / 2, py(41.7) - 62), "+3.3% width", font=F_SMALL, fill=TEAL,
       anchor="ma")
d.text(((step_x1 + step_x2) / 2, py(41.7) - 34), "+28% cost", font=F_SMALL, fill=TEAL,
       anchor="ma")

# ---------------------------------------------------------------- B: the control
bx, by, bw, bh = panel(54, 608, 760, 400, "The control that proves it",
                       "identical pixel counts, different width - so pixels cannot be the cost")
ctrl = [("1920x1088", 40.73, GREEN), ("2560x816", 78.53, RED)]
cbase = by + bh - 74
ctop = by + 46
cpw, cgap = 190, 130
cspan = len(ctrl) * cpw + (len(ctrl) - 1) * cgap
cx0 = bx + (bw - cspan) / 2
for i, (name, ms, colour) in enumerate(ctrl):
    cbx = cx0 + i * (cpw + cgap)
    hgt = (ms / 90.0) * (cbase - ctop)
    d.rounded_rectangle([cbx, cbase - hgt, cbx + cpw, cbase], radius=6, fill=colour)
    d.text((cbx + cpw / 2, cbase - hgt - 34), f"{ms:.2f} ms", font=F_BIG, fill=colour,
           anchor="mm")
    d.text((cbx + cpw / 2, cbase - hgt - 12), "per interval", font=F_SMALL, fill=MUTED,
           anchor="mm")
    d.text((cbx + cpw / 2, cbase + 22), name, font=F_LAB, fill=INK, anchor="mm")
    d.text((cbx + cpw / 2, cbase + 42), "2,088,960 px", font=F_SMALL, fill=MUTED, anchor="mm")
d.line([bx, cbase, bx + bw, cbase], fill=GRID, width=2)
d.text((bx, by + 2), "1.93x", font=F_BIG, fill=TEAL)
d.text((bx + 92, by + 12), "identical pixels, 33% more width", font=F_SMALL, fill=MUTED)

# ---------------------------------------------------------------- C: the motion model
cx, cy, cw, ch = panel(846, 608, 780, 400, "What SVP does instead",
                       "its own settings, read from ~/Library/Application Support/SVP4")
rows = [("SVP  -  block matching", "mv_grid: 12,  mv_refine: 0", "33,840", TEAL),
        ("this app  -  dense optical flow", "VTFrameProcessor, one model", "6,266,880", RED)]
ry = cy + 40
for title, sub, value, colour in rows:
    d.text((cx, ry), title, font=F_LAB, fill=INK)
    d.text((cx, ry + 20), sub, font=F_SMALL, fill=MUTED)
    d.text((cx + cw, ry - 6), value, font=F_BIG, fill=colour, anchor="ra")
    d.text((cx + cw, ry + 26), "motion vectors per frame", font=F_SMALL, fill=MUTED, anchor="ra")
    ry += 84
d.line([cx, ry - 12, cx + cw, ry - 12], fill=GRID, width=1)
d.text((cx, ry + 4), "185x", font=F_HUGE, fill=RED)
d.text((cx + 122, ry + 10), "as many motion estimates, every frame.\n"
                            "The API exposes no cheaper model - so this is not a tuning problem.",
       font=F_LAB, fill=INK, spacing=7)

d.text((54, H - 88),
       "SVP also resizes to 3384x1440 first - but that exact resolution still costs 81.55 ms here, 1.96x over budget,",
       font=F_SUB, fill=MUTED)
d.text((54, H - 62),
       "so the resize is a red herring.  And SVP is allowed to lower quality to hold the rate (fi_auto_adjust); this engine is not.",
       font=F_SUB, fill=MUTED)
d.text((54, H - 36),
       "Hardware decode is real (2.9x, bit-identical) but buys no wall time - at 4K the pool is the constraint.",
       font=F_SUB, fill=MUTED)

out = "/Users/Wasim/Desktop/FNF-60FPS-A-B/60FPS-width-staircase.png"
img.save(out)
print("wrote", out)
