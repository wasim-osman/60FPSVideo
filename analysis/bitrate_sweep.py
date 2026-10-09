#!/usr/bin/env python3
"""Pick the batch converter's bit rate on evidence instead of taste.

BUILD-DECISIONS.md section 20, decision 4: "measure it, target visually lossless".

The question is not "how good does the output look". It is **at what rate does the
encode stop being the thing you can see**. So this encodes *the same interpolated
frames* at several rates and compares each against the uncompressed originals.

Comparing against the original disc would confound two different errors. The
interpolation already departs from the true pictures -- that is measured separately
in REAL-CONTENT-AB.md, against ground truth -- and the encode adds its own on top.
Only the second one is a bit-rate decision, so only the second one is measured here.
The test for "good enough" is therefore relative: an encode whose error sits well
below the error the interpolation already introduces is not what anyone will see.

Two clips, deliberately. The night chase is dark, and dark gradients are where a low
bit rate bands first. A rate that passes on the bright desert clip and fails on the
night one is not a rate.

usage: bitrate_sweep.py [--frames N] [--rates 20000000,45000000,90000000]
"""

import argparse
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HARNESS = os.path.join(ROOT, ".build", "debug", "interp-harness")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
WORK = "/tmp/bitrate-sweep"

# (label, packed path, width, height, format, extra harness args, metadata source)
#
# The metadata source is a real container, not the packed file: the point of passing
# it is to exercise `VideoEncodeSettings.forSource`, which reads ffprobe's colour tags
# and the HDR10 payloads, and a raw stream has neither. `vt_hdr_test.mp4` carries the
# disc's own values, verified byte-exact by analysis/probes/vt_hdr_encode.swift.
CLIPS = [
    ("bright 8-bit SDR", "work/bright.nv12", 3840, 1632, "nv12", [], None),
    ("night 10-bit HDR", "work/hdr_night.p010", 3840, 1632, "p010",
     ["--format", "p010"], "work/vt_hdr_test.mp4"),
]

FRAME_BYTES = {"nv12": lambda w, h: w * h * 3 // 2,
               "p010": lambda w, h: w * h * 3}


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"failed: {' '.join(command)}")
    return result


def read_frames(path, width, height, fmt):
    """Yield each frame as an array of code values.

    P010 keeps its 10-bit code in the top ten bits of a 16-bit little-endian word
    (invariant 20), so the shift is not optional: an unshifted read is wrong by 64x
    and wrong *plausibly*.
    """
    size = FRAME_BYTES[fmt](width, height)
    dtype = np.uint8 if fmt == "nv12" else np.dtype("<u2")
    shift = 0 if fmt == "nv12" else 6
    with open(path, "rb") as handle:
        while True:
            raw = handle.read(size)
            if len(raw) < size:
                return
            values = np.frombuffer(raw, dtype=dtype)
            yield (values >> shift) if shift else values


def compare(reference_path, candidate_path, width, height, fmt):
    """Per-sample error between two packed streams, globally and in flat regions.

    Two metrics, because they answer different questions. Global MAE says how much
    the encode moved the picture on average. The flat-region metric says whether it
    *banded*, which is the failure a bit rate actually causes on this content -- the
    night chase is full of dark gradients, and banding is structured error in exactly
    the places where there is nothing else to hide it.

    Banding is invisible to a global average: a smooth ramp quantised into steps can
    have a lower MAE than scattered noise and look far worse.
    """
    luma_samples = width * height
    worst = 0
    total = 0
    sum_abs = 0
    over_one = 0
    # 99.9th percentile rather than max: a single pixel is not a bit-rate decision.
    #
    # Bin by the format's maximum code value, not by 8-bit habit (invariant 20). A
    # 256-bin histogram clamps every 10-bit difference above 255, so a P010 run would
    # report a p99.9 of exactly 255 whenever the tail exceeded it -- a plausible
    # number that is really the clamp.
    max_code = 1023 if fmt == "p010" else 255
    histogram = np.zeros(max_code + 1, dtype=np.int64)
    flat_total = 0
    flat_sum_abs = 0
    flat_worst = 0
    frames = 0

    for a, b in zip(read_frames(reference_path, width, height, fmt),
                    read_frames(candidate_path, width, height, fmt)):
        difference = np.abs(a.astype(np.int32) - b.astype(np.int32))
        worst = max(worst, int(difference.max()))
        total += difference.size
        sum_abs += int(difference.sum())
        over_one += int((difference > 1).sum())
        np.add.at(histogram, np.minimum(difference, max_code), 1)

        # The flattest quarter of the frame, by local gradient of the *reference*.
        # Using the reference rather than the candidate matters: the mask has to
        # describe where the picture is smooth, not where the encode made it smooth.
        #
        # A forward difference is one sample shorter along the axis it differentiates,
        # so the two directions disagree on shape: axis 0 gives (h-1, w), axis 1 gives
        # (h, w-1). Crop both to the common interior (h-1, w-1) before combining -- and
        # crop the error array the same way, or the mask indexes the wrong pixels.
        luma = a[:luma_samples].reshape(height, width).astype(np.int32)
        vertical = np.abs(np.diff(luma, axis=0))[:, :-1]
        horizontal = np.abs(np.diff(luma, axis=1))[:-1, :]
        gradient = np.maximum(vertical, horizontal)
        if gradient.size:
            threshold = np.percentile(gradient, 25)
            flat = gradient <= threshold
            error = difference[:luma_samples].reshape(height, width)[:-1, :-1][flat]
            if error.size:
                flat_total += error.size
                flat_sum_abs += int(error.sum())
                flat_worst = max(flat_worst, int(error.max()))
        frames += 1

    if frames == 0:
        raise SystemExit(f"nothing to compare: {reference_path} vs {candidate_path}")
    cumulative = np.cumsum(histogram)
    p999 = int(np.searchsorted(cumulative, total * 0.999)) if total else 0
    return {
        "frames": frames,
        "mae": sum_abs / total,
        "p999": p999,
        "worst": worst,
        "over_one_pct": 100.0 * over_one / total,
        "flat_mae": (flat_sum_abs / flat_total) if flat_total else 0.0,
        "flat_worst": flat_worst,
        "flat_share": 100.0 * flat_total / total,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=60,
                        help="source frames to interpolate (default 60)")
    parser.add_argument("--rates", default="20000000,45000000,90000000",
                        help="comma-separated bits per second")
    args = parser.parse_args()
    rates = [int(r) for r in args.rates.split(",")]

    os.makedirs(WORK, exist_ok=True)
    if not os.path.exists(HARNESS):
        raise SystemExit(f"build the harness first: {HARNESS} is missing")

    print(f"source frames : {args.frames}  (about {args.frames * 2.5:.0f} output frames)")
    print(f"rates         : {', '.join(f'{r/1e6:.0f} Mbps' for r in rates)}")
    print()

    for label, packed, width, height, fmt, extra, metadata_source in CLIPS:
        source = os.path.join(ROOT, packed)
        if not os.path.exists(source):
            print(f"--- {label}: SKIPPED, {packed} not present")
            continue

        reference = os.path.join(WORK, f"ref_{fmt}.packed")
        print(f"--- {label}")
        if not os.path.exists(reference):
            began = time.time()
            run([HARNESS, source, str(width), str(height), "23.976", "auto",
                 reference, "--max-frames", str(args.frames)] + extra)
            print(f"    reference interpolated in {time.time() - began:.1f}s")
        reference_bytes = os.path.getsize(reference)
        reference_frames = reference_bytes // FRAME_BYTES[fmt](width, height)

        print(f"    {'target':>8}  {'file':>9}  {'actual':>8}  {'bpp':>7}  {'MAE':>6}  "
              f"{'p99.9':>6}  {'flatMAE':>8}  {'flatWorst':>9}")
        for rate in rates:
            encoded = os.path.join(WORK, f"enc_{fmt}_{rate}.mp4")
            decoded = os.path.join(WORK, f"dec_{fmt}_{rate}.packed")
            began = time.time()
            run([HARNESS, "--encode", reference, encoded, str(width), str(height),
                 "--format", fmt, "--rate", "59.94", "--bitrate", str(rate)]
                + (["--metadata-from", os.path.join(ROOT, metadata_source)]
                   if metadata_source else []))
            run([FFMPEG, "-hide_banner", "-v", "error", "-nostdin", "-y",
                 "-i", encoded, "-f", "rawvideo",
                 "-pix_fmt", "p010le" if fmt == "p010" else "nv12", decoded])
            stats = compare(reference, decoded, width, height, fmt)

            # The encoder undershoots on dark content -- fewer bits are needed, so a
            # target is not a rate. Everything below is computed from what was
            # actually written, because that is what a viewer sees.
            size = os.path.getsize(encoded)
            seconds = stats["frames"] / 59.94
            actual = size * 8 / seconds
            bpp = actual / (width * height * 59.94)
            # Code steps are only comparable across bit depths after normalising by
            # the format's maximum code value (invariant 20).
            scale = 1023.0 if fmt == "p010" else 255.0
            print(f"    {rate/1e6:6.0f} M  {size/1e6:7.1f} MB  {actual/1e6:6.1f} M  "
                  f"{bpp:7.4f}  {stats['mae']:6.3f}  {stats['p999']:6d}  "
                  f"{stats['flat_mae']:8.3f}  {stats['flat_worst']:9d}"
                  f"   ({stats['frames']} frames, {seconds:.1f}s, "
                  f"flat {stats['flat_share']:.0f}%)")
            # 8-bit-equivalent, so the two clips can be read on one scale.
            print(f"    {'':>8}  {'':>9}  {'':>8}  {'':>7}  "
                  f"{stats['mae']/scale*255:6.3f}  "
                  f"{stats['p999']/scale*255:6.1f}  "
                  f"{stats['flat_mae']/scale*255:8.3f}  "
                  f"{stats['flat_worst']/scale*255:9.1f}   <- in 8-bit-equivalent steps")
        print()

    print("Reference frames are the *uncompressed* interpolated output, so every")
    print("error above is the encode's alone. Pick the smallest rate whose MAE sits")
    print("well under the interpolation's own error against ground truth")
    print("(REAL-CONTENT-AB.md) -- below that, the encode is not what you can see.")


if __name__ == "__main__":
    main()
