#!/usr/bin/env python3
"""
gt_holdout.py - ground-truth quality test for both interpolation engines.

WHY THIS EXISTS
---------------
"Which engine looks better" cannot be settled by eye, and comparing the two
engines to *each other* only says whether they agree - not whether either is
right. Both could be equally wrong and agree perfectly.

So: construct a case where the correct answer is known.

  Take the source. Throw away every odd frame. You now have a source at exactly
  half the rate. Ask each engine to double it back up. The interpolated frames
  land at t=0.5 exactly - halfway between two survivors - which is precisely
  where the discarded frames used to be. Compare the engine's output against the
  real frame it was asked to reconstruct.

That is a true PSNR against ground truth, on the same content, for both engines.

It also scores two dumb baselines, because "better than the other engine" is the
wrong question. The right one is "better than just blending the neighbours":
  - repeat   : output the previous frame (what a bad player does)
  - blend50  : plain 50/50 average of the two neighbours (no motion model at all)

If a 4x-slower neural engine cannot beat a 50/50 blend on this content, the
content does not need it.

Usage:
  gt_holdout.py --src-rgb work/FNF_60FPS.rgb24 --src-nv12 work/FNF_60FPS.nv12 \
                --width 3840 --height 1632 --n-src 191 [--skip-render]
"""

import argparse
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)

SRC_RATE = "11988/1000"   # exactly half of 23976/1000
OUT_RATE = "23976/1000"


def decimate(src, dst, frame_bytes, n_src, keep_even=True):
    """Keep every other frame -> half-rate source."""
    if os.path.exists(dst) and os.path.getsize(dst) == (n_src + 1) // 2 * frame_bytes:
        return (n_src + 1) // 2
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for i in range(n_src):
            buf = fi.read(frame_bytes)
            if len(buf) != frame_bytes:
                break
            if (i % 2 == 0) == keep_even:
                fo.write(buf)
    return os.path.getsize(dst) // frame_bytes


def read_frame(path, frame_bytes, index):
    with open(path, "rb") as f:
        f.seek(frame_bytes * index)
        buf = f.read(frame_bytes)
    if len(buf) != frame_bytes:
        raise EOFError(f"{path} short read at {index}")
    return np.frombuffer(buf, dtype=np.uint8)


def luma_rgb(raw, w, h):
    a = raw.reshape(h, w, 3).astype(np.float32)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def luma_nv12(raw, w, h):
    """NV12 Y plane, studio range -> full range, to match the RGB path."""
    y = raw[: w * h].reshape(h, w).astype(np.float32)
    return np.clip((y - 16.0) * (255.0 / 219.0), 0.0, 255.0)


def score(err):
    mae = float(np.abs(err).mean())
    rmse = float(np.sqrt((err.astype(np.float64) ** 2).mean()))
    psnr = 10 * np.log10(255.0 ** 2 / (rmse ** 2)) if rmse > 0 else float("inf")
    return mae, psnr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-rgb", required=True)
    ap.add_argument("--src-nv12", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--n-src", type=int, required=True)
    ap.add_argument("--workdir", default=os.path.join(PROJ, "work", "gt"))
    ap.add_argument("--skip-render", action="store_true")
    args = ap.parse_args()

    w, h = args.width, args.height
    rgb_fb, nv12_fb = w * h * 3, w * h * 3 // 2
    wd = args.workdir
    os.makedirs(wd, exist_ok=True)

    dec_rgb = os.path.join(wd, "dec.rgb24")
    dec_nv12 = os.path.join(wd, "dec.nv12")
    out_vt = os.path.join(wd, "gt_vt.nv12")
    out_rife = os.path.join(wd, "gt_rife.rgb24")

    n_dec = decimate(args.src_rgb, dec_rgb, rgb_fb, args.n_src)
    decimate(args.src_nv12, dec_nv12, nv12_fb, args.n_src)
    n_out = 2 * (n_dec - 1)
    print(f"decimated: {n_dec} frames -> expecting {n_out} output frames "
          f"({n_out//2} passthrough + {n_out//2} interpolated at t=0.5)")

    if not args.skip_render:
        print("\n--- VTFrameProcessor ---", flush=True)
        r = subprocess.run(
            [os.path.join(HERE, "probes", "vtrender"), dec_nv12, str(w), str(h),
             SRC_RATE, OUT_RATE, out_vt, "2"],
            capture_output=True, text=True)
        sys.stderr.write(r.stderr)
        if r.returncode != 0:
            sys.exit("vtrender failed")

        print("\n--- CoreML RIFE ---", flush=True)
        py = "/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml/bin/python"
        r = subprocess.run(
            [py, os.path.join(HERE, "coreml", "rife_render.py"), dec_rgb, str(w), str(h),
             SRC_RATE, OUT_RATE, out_rife],
            capture_output=True, text=True)
        sys.stderr.write(r.stderr[-2000:])
        if r.returncode != 0:
            sys.exit("rife_render failed")

    for p in (out_vt, out_rife):
        if not os.path.exists(p):
            sys.exit(f"missing {p} - run without --skip-render")
    got_vt = os.path.getsize(out_vt) // nv12_fb
    got_rife = os.path.getsize(out_rife) // rgb_fb
    print(f"\nrendered: VT {got_vt} frames, RIFE {got_rife} frames, expected {n_out}")

    # ---- evaluate: odd output k=2m+1 must reconstruct original frame 2m+1
    n_eval = min(n_out // 2, (args.n_src - 1) // 2)

    print(f"\nscoring {n_eval} held-out frames against ground truth\n")
    print(f"{'frame':>6} {'src':>5} | {'repeat':>18} {'blend50':>18} "
          f"{'VT':>18} {'RIFE':>18}")
    print(f"{'':>6} {'':>5} | {'MAE':>8} {'PSNR':>9} {'MAE':>8} {'PSNR':>9} "
          f"{'MAE':>8} {'PSNR':>9} {'MAE':>8} {'PSNR':>9}")

    acc = {k: [] for k in ("repeat", "blend50", "vt", "rife")}
    rows = []
    for m in range(n_eval):
        truth_idx = 2 * m + 1
        prev_idx, next_idx = 2 * m, 2 * m + 2

        truth = luma_rgb(read_frame(args.src_rgb, rgb_fb, truth_idx), w, h)
        prev = luma_rgb(read_frame(args.src_rgb, rgb_fb, prev_idx), w, h)
        nxt = luma_rgb(read_frame(args.src_rgb, rgb_fb, next_idx), w, h)
        vt = luma_nv12(read_frame(out_vt, nv12_fb, 2 * m + 1), w, h)
        rf = luma_rgb(read_frame(out_rife, rgb_fb, 2 * m + 1), w, h)

        cands = {
            "repeat": prev,
            "blend50": 0.5 * (prev + nxt),
            "vt": vt,
            "rife": rf,
        }
        sc = {k: score(v - truth) for k, v in cands.items()}
        for k in acc:
            acc[k].append(sc[k])
        rows.append((m, truth_idx, sc))

        print(f"{2*m+1:6d} {truth_idx:5d} | "
              f"{sc['repeat'][0]:8.3f} {sc['repeat'][1]:9.2f} "
              f"{sc['blend50'][0]:8.3f} {sc['blend50'][1]:9.2f} "
              f"{sc['vt'][0]:8.3f} {sc['vt'][1]:9.2f} "
              f"{sc['rife'][0]:8.3f} {sc['rife'][1]:9.2f}", flush=True)

    print("\n" + "=" * 78)
    print(f"{'SUMMARY over ' + str(n_eval) + ' held-out frames':<30}"
          f"{'MAE mean':>12}{'MAE median':>13}{'PSNR mean':>12}")
    for k, label in (("repeat", "repeat previous frame"),
                     ("blend50", "50/50 linear blend"),
                     ("vt", "VTFrameProcessor"),
                     ("rife", "CoreML RIFE 4.25")):
        maes = np.array([s[0] for s in acc[k]])
        psnrs = np.array([s[1] for s in acc[k]])
        print(f"{label:<30}{maes.mean():12.3f}{np.median(maes):13.3f}"
              f"{psnrs.mean():12.2f}")

    # exclude the scene cuts - they are unrepresentative and un-winnable
    maes = {k: np.array([s[0] for s in acc[k]]) for k in acc}
    hot = maes["vt"] > np.median(maes["vt"]) * 2.5
    print(f"\nsame, excluding {int(hot.sum())} cut/outlier frames:")
    print(f"{'':<30}{'MAE mean':>12}{'MAE median':>13}{'PSNR mean':>12}")
    for k, label in (("repeat", "repeat previous frame"),
                     ("blend50", "50/50 linear blend"),
                     ("vt", "VTFrameProcessor"),
                     ("rife", "CoreML RIFE 4.25")):
        sel = ~hot
        maes_k = np.array([s[0] for s in acc[k]])[sel]
        psnrs_k = np.array([s[1] for s in acc[k]])[sel]
        print(f"{label:<30}{maes_k.mean():12.3f}{np.median(maes_k):13.3f}"
              f"{psnrs_k.mean():12.2f}")

    print(f"\nRIFE vs VT, median MAE : {np.median(maes['rife']):.3f} vs "
          f"{np.median(maes['vt']):.3f}")
    winner = "RIFE" if np.median(maes["rife"]) < np.median(maes["vt"]) else "VT"
    print(f"lower error on this content: {winner}")
    print(f"RIFE is 4.1x slower than VT at 4K. That is the trade.")


if __name__ == "__main__":
    main()
