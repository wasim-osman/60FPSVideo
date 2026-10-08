# VTFrameRateConversion throughput — Apple M2 Max (38-core GPU, 64 GB)

Measured 2026-10-08. macOS 27.0.1 (build 26A434). Xcode 27.1 / Swift 6.4.

Method: `process(parameters:completionHandler:)` + `DispatchSemaphore` for true
GPU synchronisation. 6-buffer IOSurface ring, recycled. 3 runs per configuration,
first 10 samples discarded as warm-up. Interpolation phase 0.5 (single midpoint,
i.e. 2x frame-rate conversion).

Correctness was verified at pixel level: the destination buffer is written and its
content differs from both the source and the next reference frame.

| Configuration      | n   | mean     | p50      | p95      | source fps | output fps (2x) | real-time 24->48? |
| ------------------ | --- | -------- | -------- | -------- | ---------- | --------------- | ----------------- |
| 640x360  normal    | 360 | 18.48 ms | 17.72 ms | 20.68 ms | 53.9       | 107.8           | yes               |
| 1280x720 normal    | 240 | 29.42 ms | 27.89 ms | 32.25 ms | 33.8       | 67.7            | yes               |
| 1920x1080 normal   | 240 | 28.53 ms | 27.21 ms | 32.57 ms | 34.8       | 69.7            | yes               |
| 1920x1080 quality  | 240 | 37.53 ms | 35.91 ms | 43.18 ms | 26.5       | 52.9            | yes (marginal)    |
| 3840x2160 normal   | 120 | 74.05 ms | 70.78 ms | 84.09 ms | 13.4       | 26.8            | no                |

## Reading of the numbers

- **1080p real-time is achievable.** 34.8 source fps against a 24 fps requirement
  gives roughly 45% headroom for a 24 -> 48 fps conversion, in `.normal` quality.
- **1080p at `.quality` is borderline** at 26.5 source fps. It clears 24 fps but with
  little margin; it would need pre-computed optical flow or a lower source rate.
- **4K is not real-time** on M2 Max at 13.4 source fps. 4K is still perfectly viable
  for offline conversion, where throughput matters more than latency.
- These figures include CPU-side harness overhead (synthetic frame generation, a
  per-call semaphore round trip, and CPU pixel reads). A production pipeline feeding
  `processWithCommandBuffer:parameters:` from an existing Metal pipeline should be
  faster.
- The latency distribution is tight (p50 to p95 is roughly +17%), so the pipeline is
  steady-state rather than bursty.

## Session start-up cost

| Configuration                            | Session start |
| ---------------------------------------- | ------------- |
| VTFrameRateConversion, quality, 1920x1080 | 11.53 s (first time, model load) |
| VTFrameRateConversion, normal, 1280x720   | 0.45-0.52 s |
| VTLowLatencyFrameInterpolation, 1920x1080 | 1.07 s |

Apple documents that low-latency frame interpolation model loading "may take longer
than a frame time", and that the UI thread must not be blocked during
`startSession`. The measured 11.5 s first-time load for the quality path is
consistent with that warning and confirms the session must be started off the
main thread, ideally during application launch.

## Stability findings (important for implementation)

Two behaviours were observed that a production implementation must design around.
Both were reproduced with a minimal harness and are not artefacts of the benchmark.

1. **The Swift `async` overlay does not wait for completion.**
   `try await processor.process(parameters:)` returned in ~0.08 ms and **never wrote
   the destination buffer** — the output was still the pre-fill pattern even after a
   300 ms delay. The `process(parameters:completionHandler:)` form, waited on with a
   semaphore, wrote correct interpolated output on the same inputs.
   *Implementation rule: use the completion-handler or Metal-command-buffer API, not
   the Swift `async` form.*

2. **Non-deterministic crashes under certain buffer strategies.**
   Allocating a distinct `CVPixelBuffer` per frame (~65+ surfaces) crashed
   consistently around 85-90 calls. A 6-buffer recycled ring completed every run.
   Crashes were also observed at process teardown after `endSession()` had returned
   successfully, with a non-deterministic trigger point.
   *Implementation rule: recycle a small fixed pool of IOSurface-backed buffers via
   `CVPixelBufferPool`; do not allocate per frame. Treat teardown as a risk area and
   isolate frame processing in its own process if stability cannot be guaranteed.*

## Reproduce

```
swiftc -O -o vtl vt_lat.swift
./vtl 1920 1080 normal 80      # emits one "LAT <ms>" line per completed call
```
