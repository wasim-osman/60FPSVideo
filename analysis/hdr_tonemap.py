#!/usr/bin/env python3
"""HDR10 (PQ / BT.2020) -> SDR (BT.709) tone mapping, in numpy.

WHY THIS IS HAND-ROLLED
-----------------------
The standard ffmpeg HDR->SDR chain is built on `zscale` (libzimg):

    zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable,...
    zscale=t=bt709:m=bt709:r=tv,format=yuv420p

This machine's ffmpeg has no zscale, no libplacebo, no freetype - it is a slim
build. `scale_vt` (the VideoToolbox scaler, which does have color_transfer /
color_primaries options and would be the natural hardware route) fails with
ENOSYS here. `tonemap` exists but needs linear light, which is exactly the step
zscale was doing.

So the transfer-function maths is done explicitly. It is not complicated, it is
just three well-specified pieces:
  1. SMPTE ST 2084 (PQ) EOTF      : signal -> linear light, 1.0 == 10000 cd/m2
  2. BT.2020 -> BT.709 primaries  : 3x3 matrix in linear light
  3. BT.709 OETF                  : linear light -> signal

Tone mapping is applied as a LUMA-PRESERVING SCALE rather than per channel.
Per-channel tone mapping shifts hue (a saturated red highlight desaturates
toward white because R compresses while G and B do not). Scaling all three
channels by f(Y)/Y preserves hue and saturation, which is what you want when the
point of the exercise is to compare motion between two engines.
"""
import numpy as np

# ---------------------------------------------------------------- PQ constants
M1 = 2610.0 / 16384.0
M2 = 2523.0 / 4096.0 * 128.0
C1 = 3424.0 / 4096.0
C2 = 2413.0 / 4096.0 * 32.0
C3 = 2392.0 / 4096.0 * 32.0

# BT.2020 -> BT.709 primaries, linear light (ITU-R BT.2087)
M2020_TO_709 = np.array([
    [1.660491, -0.587641, -0.072850],
    [-0.124550, 1.132900, -0.008349],
    [-0.018151, -0.100579, 1.118730],
], dtype=np.float32)

Y709 = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def pq_eotf(x):
    """PQ signal [0,1] -> linear light [0,1], where 1.0 == 10000 cd/m2."""
    x = np.clip(x, 0.0, 1.0).astype(np.float32)
    p = np.power(x, np.float32(1.0 / M2))
    num = np.maximum(p - C1, 0.0)
    den = C2 - C3 * p
    return np.power(num / den, np.float32(1.0 / M1))


def pq_oetf(lin):
    """Inverse of pq_eotf - kept for round-trip tests."""
    lin = np.clip(lin, 0.0, 1.0).astype(np.float32)
    p = np.power(lin, np.float32(M1))
    num = C1 + C2 * p
    den = 1.0 + C3 * p
    return np.power(num / den, np.float32(M2))


def bt709_oetf(lin):
    lin = np.clip(lin, 0.0, 1.0)
    return np.where(lin < 0.018, 4.5 * lin,
                    1.099 * np.power(lin, 0.45) - 0.099)


# ---------------------------------------------------------------- tone curves
# All take x in "SDR reference-white units" (1.0 == diffuse white) and return a
# value in [0,1] where 1.0 is the target peak. W is the source peak in the same
# units, so every curve satisfies f(W) == 1 and f(0) == 0.
_H_A, _H_B, _H_C, _H_D, _H_E, _H_F = 0.15, 0.50, 0.10, 0.20, 0.02, 0.30


def _hable(v):
    return ((v * (_H_A * v + _H_C * _H_B) + _H_D * _H_E)
            / (v * (_H_A * v + _H_B) + _H_C * _H_D + _H_E)) - _H_E / _H_F


def curve_hable(x, W):
    # NOTE: _hable(0) is 1/30, not 0. Dividing by _hable(W) alone therefore maps
    # black to 0.047 - a visible grey veil over the whole image, which is exactly
    # what the first version of this did. Subtract the toe and rescale so that
    # f(0)==0 and f(W)==1.
    lo, hi = _hable(np.float32(0.0)), _hable(np.float32(W))
    return (_hable(x) - lo) / (hi - lo)


def curve_reinhard(x, W):
    return x * (1.0 + x / (W * W)) / (1.0 + x)


def curve_knee(x, W, k=0.75):
    """Linear below the knee, tanh shoulder above it. Preserves mid-tones."""
    return np.where(x < k, x, k + (1.0 - k) * np.tanh((x - k) / (1.0 - k)))


def curve_knee90(x, W):
    """Same shoulder, knee at 0.90 - identity for the bottom 90% of the range,
    so shadows and mid-tones pass through completely untouched. Measured on the
    test segment: indistinguishable from a hard clip for the specular highlights
    (they sit at 5-8x reference white, far above any knee), but it will not
    posterise a shot that actually has detail in the 90-200 nit band."""
    return curve_knee(x, W, 0.90)


def curve_clip(x, W):
    return np.minimum(x, 1.0)


CURVES = {"hable": curve_hable, "reinhard": curve_reinhard,
          "knee": curve_knee, "knee90": curve_knee90, "clip": curve_clip}


# ---------------------------------------------------------------- main entry
def tone_map(rgb16, curve="hable", ref_white=100.0, src_peak=1000.0,
             exposure=1.0, luts=None):
    """rgb16: uint16 (H,W,3) in full-range PQ / BT.2020 (as ffmpeg's rgb48le).
    Returns uint8 (H,W,3) BT.709, gamma encoded, full range.

    ref_white : source luminance that maps to SDR diffuse white, in cd/m2
    src_peak  : source peak luminance (1000 for this disc, per MaxCLL)
    exposure  : linear gain applied before tone mapping
    """
    if luts is None:
        a = rgb16.astype(np.float32) / 65535.0
        lin2020 = pq_eotf(a)
    else:
        lin2020 = luts["pq"][rgb16 >> 6]          # 10-bit source -> 1024 LUT

    lin709 = lin2020 @ M2020_TO_709.T             # still 0..1 == 0..10000 nits
    L = lin709 * np.float32(10000.0 / ref_white * exposure)
    Y = L @ Y709

    fn = CURVES[curve]
    W = np.float32(src_peak / ref_white)
    fY = fn(Y, W)
    scale = np.where(Y > 1e-7, fY / np.maximum(Y, 1e-7), 1.0)
    out = np.clip(L * scale[..., None], 0.0, 1.0)

    if luts is None:
        enc = bt709_oetf(out)
    else:
        enc = luts["oetf"][np.clip(out * 1023.0 + 0.5, 0, 1023).astype(np.uint16)]
    return np.rint(enc * 255.0).astype(np.uint8)


def build_luts():
    """10-bit-indexed PQ LUT (input is 10-bit in a 16-bit container) and a
    10-bit-indexed BT.709 OETF LUT. Turns the whole per-pixel colour pipeline
    into two gathers plus one 3x3 matmul."""
    idx10 = np.arange(1024, dtype=np.float32) / 1023.0
    # ffmpeg expands tv-range YUV to full-range RGB, so the LUT is on full range
    pq = pq_eotf(idx10).astype(np.float32)
    lin = np.arange(1024, dtype=np.float32) / 1023.0
    oetf = bt709_oetf(lin).astype(np.float32)
    return {"pq": pq, "oetf": oetf}


if __name__ == "__main__":
    import argparse
    from PIL import Image

    ap = argparse.ArgumentParser()
    ap.add_argument("raw16")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("--out", default="/tmp/hdrtest/preview.png")
    ap.add_argument("--preview-width", type=int, default=960)
    ap.add_argument("--curve", default="hable", choices=sorted(CURVES))
    ap.add_argument("--ref-white", type=float, default=100.0)
    ap.add_argument("--src-peak", type=float, default=1000.0)
    ap.add_argument("--exposure", type=float, default=1.0)
    args = ap.parse_args()

    a = np.fromfile(args.raw16, dtype="<u2").reshape(args.height, args.width, 3)

    # luminance statistics in nits, so the curve choice is informed not guessed
    lin = pq_eotf(a[::4, ::4].astype(np.float32) / 65535.0) * 10000.0
    Y = lin @ Y709
    print("source luminance (nits), sampled 1/16:")
    for p in (1, 5, 25, 50, 75, 90, 95, 99, 99.9, 100):
        print(f"   p{p:<5g} {np.percentile(Y, p):9.2f}")

    out = tone_map(a, curve=args.curve, ref_white=args.ref_white,
                   src_peak=args.src_peak, exposure=args.exposure)
    print(f"tone mapped: {args.curve}  ref_white={args.ref_white:g} nit  "
          f"src_peak={args.src_peak:g} nit  exposure={args.exposure:g}")
    print(f"   output mean {out.mean():6.1f}/255  p1 {np.percentile(out,1):5.1f}  "
          f"p99 {np.percentile(out,99):5.1f}  max {out.max()}")
    im = Image.fromarray(out)
    im = im.resize((args.preview_width,
                    round(args.preview_width * args.height / args.width)),
                   Image.LANCZOS)
    im.save(args.out)
    print(f"   wrote {args.out}")
