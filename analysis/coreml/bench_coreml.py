#!/usr/bin/env python3
"""
Benchmark a CoreML RIFE model.

Phase 0's real question is a single number: can CoreML RIFE sustain 60 output
frames/second at 1080p? Each RIFE call produces exactly ONE interpolated frame,
so the requirement converts as:

    required calls/s = 59.94 * (interpolated fraction)

    23.976 -> 59.94   79.9% interpolated  -> 47.9 calls/s
    24.000 -> 59.94   99.8% interpolated  -> 59.8 calls/s
    29.97  -> 59.94   49.9% interpolated  -> 29.9 calls/s   (low-latency path)

So the bar is roughly 48-60 inferences/second at the source resolution.

Reports serial latency, single-stream throughput, and aggregate throughput with
several requests in flight (the VTFrameProcessor work showed depth-2 pipelining
matters a lot; the same may apply here).
"""

import argparse
import os
import statistics
import threading
import time

import numpy as np


def percentile(vals, p):
    vals = sorted(vals)
    if not vals:
        return float("nan")
    i = min(len(vals) - 1, int(round((p / 100.0) * (len(vals) - 1))))
    return vals[i]


def build_inputs(h, w):
    rng = np.random.default_rng(0)
    # RIFE consumes float RGB in [0,1]; random noise is the worst case for the
    # motion model but the cost is input-independent, which is what we measure.
    a = rng.random((1, 3, h, w), dtype=np.float32)
    b = rng.random((1, 3, h, w), dtype=np.float32)
    t = np.full((1, 1, 1, 1), 0.5, dtype=np.float32)
    return {"img0": a, "img1": b, "timestep": t}


def serial(model, inputs, iters, warmup):
    for _ in range(warmup):
        model.predict(inputs)
    lat = []
    t0 = time.perf_counter()
    for _ in range(iters):
        s = time.perf_counter()
        model.predict(inputs)
        lat.append((time.perf_counter() - s) * 1000.0)
    wall = time.perf_counter() - t0
    return lat, iters / wall


def concurrent(model, inputs, iters, warmup, threads):
    def worker(n):
        for _ in range(n):
            model.predict(inputs)

    per = max(1, iters // threads)
    for _ in range(warmup):
        model.predict(inputs)
    t0 = time.perf_counter()
    ts = [threading.Thread(target=worker, args=(per,)) for _ in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    wall = time.perf_counter() - t0
    return (per * threads) / wall


def report_placement(model_path, compute_units_name):
    """Which engine did each op land on? If `resample` is not on the ANE the
    quality tier is unlikely to be real-time, so this is worth knowing."""
    try:
        import coremltools as ct
        from coremltools.models.compute_plan import MLComputePlan

        units = {
            "ALL": ct.ComputeUnit.ALL,
            "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
            "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
            "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
        }[compute_units_name]

        plan = MLComputePlan.load_from_path(model_path, compute_units=units)
        prog = plan.model_structure.program
        counts = {}
        for fn in prog.functions.values():
            for blk in fn.block_specializations.values():
                for op in blk.operations:
                    dev = plan.get_compute_device_usage_for_mlprogram_operation(op)
                    name = getattr(dev, "device_type", dev)
                    counts[str(name)] = counts.get(str(name), 0) + 1
        print("  op placement:", counts)
    except Exception as e:
        print(f"  (compute-plan introspection unavailable: {type(e).__name__}: {e})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--height", type=int, default=1088)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--compute-units", default="ALL",
                    choices=["ALL", "CPU_AND_GPU", "CPU_AND_NE", "CPU_ONLY"])
    ap.add_argument("--placement", action="store_true")
    args = ap.parse_args()

    import coremltools as ct

    units = {
        "ALL": ct.ComputeUnit.ALL,
        "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
        "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
        "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
    }[args.compute_units]

    print(f"model  : {os.path.basename(args.model)}")
    print(f"size   : {args.width}x{args.height}   compute_units={args.compute_units}")

    model = ct.models.MLModel(args.model, compute_units=units)
    inputs = build_inputs(args.height, args.width)

    lat, fps1 = serial(model, inputs, args.iters, args.warmup)
    print(f"serial : {statistics.mean(lat):7.1f} ms/call  "
          f"(p50 {percentile(lat,50):.1f}  p90 {percentile(lat,90):.1f})  "
          f"-> {fps1:6.1f} calls/s")

    if args.threads > 1:
        for th in range(2, args.threads + 1):
            agg = concurrent(model, inputs, max(args.iters, th * 4), args.warmup, th)
            print(f"{th} thread(s): {agg:6.1f} calls/s aggregate "
                  f"({agg/th:.1f} per stream)")

    print()
    print("verdict against the 60 fps output requirement:")
    for label, frac in (("23.976->59.94", 0.799), ("24.000->59.94", 0.998),
                        ("29.97->59.94", 0.499)):
        need = 59.94 * frac
        best = fps1
        if args.threads > 1:
            best = max(best, concurrent(model, inputs, max(args.iters, args.threads * 4),
                                        args.warmup, args.threads))
        ok = "PASS" if best >= need else "FAIL"
        print(f"  {label}: needs {need:5.1f} calls/s, best {best:6.1f} -> {ok} "
              f"({best/need:.2f}x)")

    if args.placement:
        report_placement(args.model, args.compute_units)


if __name__ == "__main__":
    main()
