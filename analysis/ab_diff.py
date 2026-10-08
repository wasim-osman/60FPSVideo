#!/usr/bin/env python3
"""
ab_diff.py - quantify how different the two engines actually are.

The question "they look identical" has two possible causes:
  (a) the two engines genuinely produce near-identical output, or
  (b) the harness rendered the same thing twice / the comparison video is
      hiding the difference (scale, encode, full-speed playback).

This script settles it with numbers, streaming both raw engine outputs:

  * per-frame MAE / PSNR / p99 / max on luma, VT vs RIFE
  * a motion baseline: MAE between consecutive SOURCE frames, so we can say
    whether an engine-to-engine difference is large or small relative to the
    content's own frame-to-frame change
  * per-frame MAE of each engine against the *source* frames, to prove the
    interpolated frames are actually interpolated (and not duplicated)
  * where the divergence lives: which frames, and is it at cuts / fast motion

Usage:
  python ab_diff.py --vt work/FNF_60FPS_vt.nv12 --rife work/FNF_60FPS_rife.rgb24 \
                    --src work/FNF_60FPS.rgb24 --width 3840 --height 1632 \
                    --outdir out --csv out/ab_diff.csv
"""

import argparse
import csv
import math
import os
import sys
from fractions import Fraction

import numpy as np

SRC_NUM, SRC_DEN = 24000, 1001
OUT_NUM, OUT_DEN = 60000, 1001


def build_plan(n_src):
    """Exact-rational output plan: same arithmetic as the renderers."""
    ratio = Fraction(SRC_NUM * OUT_DEN, SRC_DEN * OUT_NUM)  # out-index -> src-index
    last = n_src - 1  # source-frame index of the final endpoint (exclusive)
    plan = []
    k = 0
    while k * ratio < last:
        t = k * ratio
        if t.denominator == 1:
            plan.append(("pass", int(t)))
        else:
            plan.append(("interp", int(t)))
        k += 1
    return plan


def read_frames(path, frame_bytes, n):
    with open(path, "rb") as f:
        for _ in range(n):
            buf = f.read(frame_bytes)
            if len(buf) != frame_bytes:
                return
            yield np.frombuffer(buf, dtype=np.uint8)


def luma_from_rgb24(raw, w, h):
    a = raw.reshape(h, w, 3).astype(np.float32)
    # BT.709 luma, matching the colour space of both outputs
    return (0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2])


def stats(d):
    """d = signed difference array (float)."""
    ad = np.abs(d)
    return {
        "mae": float(ad.mean()),
        "rmse": float(math.sqrt(float((d.astype(np.float64) ** 2).mean()))),
        "p99": float(np.percentile(ad, 99)),
        "p999": float(np.percentile(ad, 99.9)),
        "max": float(ad.max()),
        "frac_gt2": float((ad > 2).mean() * 100.0),
        "frac_gt8": float((ad > 8).mean() * 100.0),
    }


def psnr(mae_sq, peak=255.0):
    if mae_sq <= 1e-12:
        return float("inf")
    return 10.0 * math.log10((peak * peak) / mae_sq)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vt", required=True, help="VT nv12 raw output")
    ap.add_argument("--rife", required=True, help="RIFE rgb24 raw output")
    ap.add_argument("--src", required=True, help="source rgb24 raw (the shared input)")
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--n-src", type=int, required=True)
    ap.add_argument("--outdir", default="out")
    ap.add_argument("--csv", default=None)
    args = ap.parse_args()

    w, h = args.width, args.height
    vt_fb = w * h * 3 // 2
    rgb_fb = w * h * 3

    plan = build_plan(args.n_src)
    n_out = len(plan)
    n_pass = sum(1 for k, _ in plan if k == "pass")
    print(f"plan: {n_out} out frames = {n_out - n_pass} interpolated + {n_pass} passthrough")

    os.makedirs(args.outdir, exist_ok=True)

    # ---- 1. motion baseline: how much does the content itself change per source frame?
    print("\n[1] motion baseline (source frame N vs N+1, luma MAE)")
    src_gen = read_frames(args.src, rgb_fb, args.n_src)
    prev = None
    base = []
    src_cache = {}
    for i, raw in enumerate(src_gen):
        y = luma_from_rgb24(raw, w, h)
        src_cache[i] = y
        if prev is not None:
            base.append(float(np.abs(y - prev).mean()))
        prev = y
    base = np.array(base)
    print(f"    consecutive-source MAE : mean {base.mean():7.3f}  "
          f"p50 {np.percentile(base,50):7.3f}  p95 {np.percentile(base,95):7.3f}  "
          f"max {base.max():7.3f}")
    print(f"    -> this is the amount of motion the interpolator must explain")
    print(f"    -> out-of-range frames (>3x p50, i.e. fast motion / cuts): "
          f"{int((base > 3*np.percentile(base,50)).sum())}")

    # ---- 2. VT vs RIFE, frame by frame
    print("\n[2] VT vs RIFE, per output frame (luma)")
    rows = []
    vt_gen = read_frames(args.vt, vt_fb, n_out)
    rife_gen = read_frames(args.rife, rgb_fb, n_out)

    for k, (raw_v, raw_r) in enumerate(zip(vt_gen, rife_gen)):
        # VT's NV12 Y plane is studio/limited range (16..235); RIFE's rgb24 was
        # expanded to full range (0..255) by ffmpeg. Comparing them raw invents a
        # ~16/255 offset that swamps the real signal. Normalise VT to full range.
        yv = raw_v[: w * h].reshape(h, w).astype(np.float32)
        yv = np.clip((yv - 16.0) * (255.0 / 219.0), 0.0, 255.0)
        yr = luma_from_rgb24(raw_r, w, h)
        s = stats(yv - yr)
        kind, si = plan[k]
        # each engine vs its own source frame (proves interpolation happened)
        dv = float(np.abs(yv - src_cache[si]).mean())
        dr = float(np.abs(yr - src_cache[si]).mean())
        rows.append(dict(k=k, kind=kind, src=si, **s, vt_vs_src=dv, rife_vs_src=dr))

    mae = np.array([r["mae"] for r in rows])
    interp_mask = np.array([r["kind"] == "interp" for r in rows])
    pass_mask = ~interp_mask

    def report(name, m):
        if m.sum() == 0:
            return
        print(f"    {name:24s} n={len(m):4d}  MAE mean {mae[m].mean():6.3f}  "
              f"p50 {np.percentile(mae[m],50):6.3f}  p95 {np.percentile(mae[m],95):6.3f}  "
              f"max {mae[m].max():7.3f}")

    report("all frames", np.ones(n_out, bool))
    report("interpolated frames", interp_mask)
    report("passthrough frames", pass_mask)

    # PSNR over the whole clip
    mse_all = float(np.mean([r["rmse"] ** 2 for r in rows]))
    print(f"    whole-clip PSNR(VT vs RIFE) : {psnr(mse_all):6.2f} dB")
    print(f"    frame k=0 (both = source 0) MAE : {rows[0]['mae']:.4f}  "
          f"(sanity: should be ~0)")

    # where is the divergence?
    order = np.argsort(-mae)
    print("\n[3] the 12 frames where the engines disagree most")
    print("    k     kind     src    MAE    p99    max   >2     >8    vt|src  rife|src")
    for idx in order[:12]:
        r = rows[idx]
        print(f"    {r['k']:4d}  {r['kind']:6s}  {r['src']:5d}  {r['mae']:6.3f} "
              f"{r['p99']:6.2f} {r['max']:6.1f} {r['frac_gt2']:5.2f}% {r['frac_gt8']:5.2f}% "
              f"{r['vt_vs_src']:7.3f} {r['rife_vs_src']:7.3f}")

    # ---- 4. is the divergence meaningful vs motion baseline?
    print("\n[4] interpretation")
    ratio = mae[interp_mask].mean() / base.mean()
    print(f"    engine-to-engine MAE on interpolated frames : {mae[interp_mask].mean():.3f}")
    print(f"    source-to-source MAE (motion)              : {base.mean():.3f}")
    print(f"    ratio engine-diff / motion                 : {ratio*100:.1f}%")
    print(f"    pixels differing by >2/255 on an average interpolated frame: "
          f"{np.mean([r['frac_gt2'] for r in rows if r['kind']=='interp']):.2f}%")

    # where do they differ? cluster the outliers
    thr = max(2.0, mae[interp_mask].mean() * 3)
    hot = [r["k"] for r in rows if r["mae"] > thr]
    clusters = []
    for k in hot:
        if clusters and k - clusters[-1][-1] <= 6:
            clusters[-1].append(k)
        else:
            clusters.append([k])
    print(f"\n    frames above {thr:.1f} MAE (3x the typical interpolated frame): {len(hot)} of {n_out}")
    print(f"    they form {len(clusters)} cluster(s):")
    for c in clusters:
        srcs = sorted({rows[k]["src"] for k in c})
        print(f"      out k={c[0]:3d}..{c[-1]:3d}  src {srcs}  "
              f"peak MAE {max(rows[k]['mae'] for k in c):6.2f}  "
              f"source-motion here {base[[s for s in srcs if s < len(base)]].max() if srcs else 0:6.2f}")
    print(f"    -> source-motion p95 is {np.percentile(base,95):.2f}; a cluster whose "
          f"local motion is far above that is a scene cut")

    # ---- 5. interpolation actually happening?
    vd = np.array([r["vt_vs_src"] for r in rows if r["kind"] == "interp"])
    rd = np.array([r["rife_vs_src"] for r in rows if r["kind"] == "interp"])
    print(f"\n[5] are the interpolated frames real? (MAE vs the nearest source frame)")
    print(f"    VT   : {vd.mean():7.3f}  (0 would mean duplicate frames)")
    print(f"    RIFE : {rd.mean():7.3f}")
    print(f"    both non-zero -> both engines are genuinely synthesising frames")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            wtr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            wtr.writeheader()
            wtr.writerows(rows)
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    sys.exit(main())
