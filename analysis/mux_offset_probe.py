#!/usr/bin/env python3
"""Settle whether a container's A/V offset is real or cosmetic.

The muxer reported that the audio in a muxed Matroska starts 253 ms after the
picture, while the same command into MP4 reports 3 ms. Packet inspection cannot
decide which is right: the packets are byte-identical and only their timestamps
moved, which is exactly what *both* a genuine desync and a container expressing a
codec delay look like from the outside.

So this decodes the audio out of each file and cross-correlates it. If the output's
samples are the source's samples delayed by 253 ms, the desync is real and audible.
If the lag is zero, the content is where it should be and only the header moved --
in which case a player compensates and the offset is a *statement about the codec*,
not a fault in the file.

Usage: mux_offset_probe.py SOURCE OUTPUT [--stream 0] [--seconds 2.0] [--max-lag 0.6]
"""
from __future__ import annotations

import argparse
import subprocess
import sys

import numpy as np

RATE = 48000


def decode(path: str, stream: int, seconds: float) -> np.ndarray:
    """Decode one audio stream to mono float32, from the very start of the file."""
    cmd = [
        "ffmpeg", "-hide_banner", "-v", "error", "-nostdin",
        "-i", path,
        "-map", f"0:a:{stream}",
        "-t", f"{seconds:.6f}",
        "-f", "s16le", "-acodec", "pcm_s16le",
        "-ac", "1", "-ar", str(RATE),
        "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<i2").astype(np.float32)


def first_audible(x: np.ndarray, floor: float) -> int | None:
    """Index of the first sample that is not silence, or None."""
    loud = np.flatnonzero(np.abs(x) > floor)
    return int(loud[0]) if loud.size else None


def best_lag(source: np.ndarray, output: np.ndarray, max_lag: int) -> tuple[int, float]:
    """Lag (in samples) at which `output` best matches `source`, and the correlation.

    Positive lag means the output's content is *later* than the source's, i.e. the
    muxed audio really does start late.
    """
    n = min(len(source), len(output))
    if n < max_lag * 2:
        raise SystemExit(f"not enough audio: {n} samples, need {max_lag * 2}")
    # Compare the first half of the output against a window of the source that
    # reaches `max_lag` earlier, so a late output still finds its match.
    window = output[: n // 2]
    window = window - window.mean()
    scores = []
    for lag in range(0, max_lag + 1):
        # output[i] should equal source[i + lag]
        ref = source[lag: lag + len(window)]
        if len(ref) != len(window):
            break
        ref = ref - ref.mean()
        denom = float(np.linalg.norm(ref) * np.linalg.norm(window))
        scores.append(float(np.dot(ref, window) / denom) if denom else 0.0)
    scores = np.asarray(scores)
    lag = int(np.argmax(scores))
    return lag, float(scores[lag])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--stream", type=int, default=0)
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--max-lag", type=float, default=0.6)
    args = ap.parse_args()

    max_lag = int(args.max_lag * RATE)
    src = decode(args.source, args.stream, args.seconds)
    out = decode(args.output, args.stream, args.seconds)
    print(f"decoded  source {len(src)} samples ({len(src)/RATE:.3f} s)")
    print(f"decoded  output {len(out)} samples ({len(out)/RATE:.3f} s)")

    # Silence before the content is the other way a late start shows up.
    floor = 8.0
    s0, o0 = first_audible(src, floor), first_audible(out, floor)
    fmt = lambda i: "never" if i is None else f"{i} ({i/RATE*1000:.1f} ms)"
    print(f"first audible sample: source {fmt(s0)}, output {fmt(o0)}")

    lag, score = best_lag(src, out, max_lag)
    print(f"best lag: {lag} samples = {lag/RATE*1000:.1f} ms  (correlation {score:.4f})")

    if lag == 0:
        print("\nVERDICT: the content is aligned. The offset is in the header only --")
        print("         the container is stating the codec's own delay, and a decoder")
        print("         that honours it will land the audio on the picture.")
    else:
        print(f"\nVERDICT: the audio really is {lag/RATE*1000:.1f} ms late in the decoded")
        print("         samples. This is an audible desync, not a header artefact.")

    # A second opinion that does not depend on the correlation being right: does
    # the output start with silence where the source already has sound?
    if o0 is not None and s0 is not None and o0 > s0 + RATE // 100:
        print(f"         (and the output's first sound arrives "
              f"{(o0-s0)/RATE*1000:.1f} ms later than the source's)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
