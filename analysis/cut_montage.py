#!/usr/bin/env python3
"""
cut_montage.py - show the ONE place the two engines differ.

The measurement says VT and RIFE agree to ~1/255 on 465 of 475 output frames, and
disagree violently on the 10 frames that straddle a scene cut. This builds a short
review clip of exactly those 10 frames, at quarter speed, three rows:

    VTFrameProcessor   (top)
    CoreML RIFE 4.25   (middle)
    |difference| x32   (bottom)

so the viewer can see both engines' cut artefacts side by side and see, in the
bottom row, that away from the cut the two are the same picture.

Labels are drawn with Pillow because this ffmpeg has no freetype (no drawtext).

Usage: cut_montage.py --cuts 16,173,253,271,421 --out out/FNF_60FPS_CUTS.mp4
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)

ROW_W, ROW_H = 1920, 816
FPS = 14.985          # quarter of 59.94
PAD = 12              # frames either side of the cut


def make_label(path, width, text, accent):
    from PIL import Image, ImageDraw, ImageFont
    hgt = 96
    img = Image.new("RGBA", (width, hgt), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # accent bar
    d.rectangle([0, hgt // 2 - 22, 8, hgt // 2 + 22], fill=accent + (255,))
    font = None
    for p in ("/System/Library/Fonts/SFNSMono.ttf",
              "/System/Library/Fonts/Menlo.ttc",
              "/System/Library/Fonts/Supplemental/Menlo.ttc",
              "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(p):
            try:
                font = ImageFont.truetype(p, 40)
                break
            except Exception:                                    # noqa: BLE001
                continue
    if font is None:
        font = ImageFont.load_default()
    # soft shadow so the text reads over any frame
    for dx, dy in ((2, 2),):
        d.text((28 + dx, hgt // 2 + dy), text, font=font, fill=(0, 0, 0, 220), anchor="lm")
    d.text((28, hgt // 2), text, font=font, fill=(255, 255, 255, 255), anchor="lm")
    img.save(path)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vt", default=os.path.expanduser("~/Desktop/FNF-60FPS-A-B/FNF_60FPS_VT.mp4"))
    ap.add_argument("--rife", default=os.path.expanduser("~/Desktop/FNF-60FPS-A-B/FNF_60FPS_RIFE.mp4"))
    ap.add_argument("--cuts", default="16,173,253,271,421")
    ap.add_argument("--out", default=os.path.join(PROJ, "out", "FNF_60FPS_CUTS.mp4"))
    ap.add_argument("--gain", type=float, default=4.0,
                    help="diff amplification. 4 keeps a typical 1/255 engine "
                         "difference nearly black while a 20/255 cut difference "
                         "shows clearly. 32 is dishonest: it makes sub-LSB "
                         "rounding look like a real disagreement.")
    args = ap.parse_args()

    tmp = os.path.join(PROJ, "work", "cutmontage")
    os.makedirs(tmp, exist_ok=True)

    l_vt = make_label(os.path.join(tmp, "l_vt.png"), ROW_W, "VTFrameProcessor", (91, 147, 255))
    l_rf = make_label(os.path.join(tmp, "l_rife.png"), ROW_W, "CoreML RIFE 4.25", (192, 132, 252))
    l_df = make_label(os.path.join(tmp, "l_diff.png"), ROW_W,
                      f"|difference| x{args.gain:.0f}   - white = {255.0/args.gain:.0f}/255 apart",
                      (255, 209, 102))

    step = 1.0 / args.gain
    segs = []
    for c in [int(x) for x in args.cuts.split(",")]:
        seg = os.path.join(tmp, f"seg_{c:04d}.mp4")
        sel = f"between(n,{c - PAD},{c + PAD})"
        stp = f"setpts=N/({FPS}*TB)"
        fc = (
            f"[0:v]select='{sel}',{stp},scale={ROW_W}:{ROW_H},setsar=1[v];"
            f"[1:v]select='{sel}',{stp},scale={ROW_W}:{ROW_H},setsar=1[r];"
            f"[0:v]select='{sel}',{stp},scale={ROW_W}:{ROW_H}[d0];"
            f"[1:v]select='{sel}',{stp},scale={ROW_W}:{ROW_H}[d1];"
            f"[d0][d1]blend=all_mode=difference,curves=all='0/0 {step:.6f}/1',format=yuv420p[dif];"
            f"[v][2:v]overlay=0:26[vv];"
            f"[r][3:v]overlay=0:26[rr];"
            f"[dif][4:v]overlay=0:26[dd];"
            f"[vv][rr][dd]vstack=inputs=3,format=yuv420p[out]"
        )
        cmd = ["ffmpeg", "-v", "error", "-y", "-i", args.vt, "-i", args.rife,
               "-i", l_vt, "-i", l_rf, "-i", l_df,
               "-filter_complex", fc, "-map", "[out]",
               "-r", str(FPS), "-c:v", "libx264", "-crf", "18",
               "-preset", "medium", "-pix_fmt", "yuv420p", seg]
        print(f"cut @k={c} -> {os.path.basename(seg)}", flush=True)
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"ffmpeg failed for cut {c}:\n{r.stderr[-1500:]}")
        segs.append(seg)

    lst = os.path.join(tmp, "concat.txt")
    with open(lst, "w") as f:
        for s in segs:
            f.write(f"file '{s}'\n")
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
                        "-i", lst, "-c", "copy", args.out], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"concat failed:\n{r.stderr[-1500:]}")
    size = os.path.getsize(args.out) / 1e6
    print(f"\nwrote {args.out}  ({size:.1f} MB)")


if __name__ == "__main__":
    main()
