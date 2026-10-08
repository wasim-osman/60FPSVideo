#!/usr/bin/env python3
"""Is the rare deviation at interval 177 the extraction, or the engine itself?

The extraction has to be checked against the inline loop, and it was: 478 frames,
worst difference 1 code step. But one pipeline run out of six produced two frames
that differed from the reference by up to 45 code steps on about 1% of samples —
and every later run matched exactly.

That leaves two explanations, and they call for opposite responses:

  1. a residual race in the extraction, which must be found and fixed;
  2. the engine itself not being reproducible to better than 1 code step, which
     invariant 18 already records, and which the extraction merely made visible by
     changing the timing.

The experiment that separates them is to run the *same* path repeatedly. If the
inline loop ever disagrees with itself, the variation is the engine's and no amount
of work on the extraction will remove it. If the inline loop is always stable and
only the pipeline wanders, it is the extraction.

Only the frames around interval 177 are compared, so each run can be deleted
immediately and the disk stays flat.
"""

import subprocess
import sys
from pathlib import Path

import numpy as np

WIDTH, HEIGHT = 3840, 1632
FRAME_SIZE = WIDTH * HEIGHT * 3 // 2
INPUT = "work/bright.nv12"
RATES = ("23.976", "59.94")
REFERENCE = "/tmp/full_inline.nv12"
WATCH = (443, 444)
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 5


def frame(path, index):
    with open(path, "rb") as handle:
        handle.seek(index * FRAME_SIZE)
        raw = handle.read(FRAME_SIZE)
    if len(raw) < FRAME_SIZE:
        return None
    return np.frombuffer(raw, dtype=np.uint8).astype(np.int32)


def run(extra, out):
    subprocess.run(
        [".build/debug/interp-harness", INPUT, str(WIDTH), str(HEIGHT),
         RATES[0], RATES[1], out, *extra],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out


def compare(path):
    result = []
    for k in WATCH:
        got = frame(path, k)
        if got is None:
            result.append((k, None, None))
            continue
        diff = np.abs(got - reference[k])
        result.append((k, int(diff.max()), int((diff > 1).sum())))
    return result


reference = {k: frame(REFERENCE, k) for k in WATCH}
if any(v is None for v in reference.values()):
    raise SystemExit(f"{REFERENCE} is missing or truncated — rerun the inline reference")

print(f"reference: {REFERENCE}")
print(f"{'path':>10} {'run':>4}   " +
      "   ".join(f"frame {k}: max / over-tolerance" for k in WATCH))
print("-" * 72)

outliers = {"inline": 0, "pipeline": 0}
for label, extra in (("inline", []), ("pipeline", ["--pipeline"])):
    for i in range(RUNS):
        path = f"/tmp/repeat_{label}_{i}.nv12"
        run(extra, path)
        cells = []
        bad = False
        for k, worst, over in compare(path):
            if worst is None:
                cells.append(f"frame {k}: MISSING")
                bad = True
                continue
            cells.append(f"frame {k}: {worst:3d} / {over:7d}")
            if over:
                bad = True
        if bad:
            outliers[label] += 1
        print(f"{label:>10} {i:>4}   " + "   ".join(cells), flush=True)
        Path(path).unlink()

print("-" * 72)
for label in ("inline", "pipeline"):
    print(f"{label:>10}: {outliers[label]} of {RUNS} runs disagreed with the reference")
