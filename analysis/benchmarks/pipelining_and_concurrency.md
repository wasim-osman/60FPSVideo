# Method: pipelining, pre-computed flow, and concurrency

Companion to `final_bench_60fps.txt` and `ntsc_target_family.txt`. Measured 2026-10-08 on
Mac14,6 (Apple M2 Max), macOS 27.0.1.

## The instrument

`analysis/probes/vt_pipeline.swift` (binary `vtofq`) is the main instrument:

```
vtofq W H SRC_FPS INTERVALS DEPTH [FMT] [OUT_FPS]
```

- `DEPTH` = how many `process()` calls are allowed to be in flight before waiting. **1** reproduces
  the old lock-step harness; **2** is the pipelined mode.
- `FMT` = `420v` (default) or `64rgba`.
- `OUT_FPS` = target rate, defaults to `60`. Pass `59.94` to test the NTSC target.
- Timestamps use a 90000 timescale, which represents 24000 / 30000 / 60000 / 25 / 50 and the NTSC
  1000/1001 rates exactly.

Each run simulates a real source: it builds the exact phase table for `SRC_FPS → OUT_FPS`, groups
the phases by source interval, and submits **one `process()` call per source interval** carrying
every interpolated frame that falls inside it. Frames that coincide with a source frame are counted
as passthrough and never submitted. Output correctness is verified after the timed loop by running
one call at phases `[0.4, 0.8]` and confirming the two destinations differ and are non-blank.

## Why depth 2 matters

A single `VTFrameProcessor` session is round-trip-latency-bound. At depth 1 the accelerator idles
during each CPU↔accelerator handoff. Measured interleaved (depth 1 / depth 2 alternating, 3 rounds)
at 1920×1080, 24 → 60:

| Depth | Output fps (3 rounds) |
| --- | --- |
| 1 | 60.8, 61.6, 60.4 |
| 2 | 83.5, 83.6, 80.4 |

Depth 3 and 4 add nothing. **Depth 2 is the whole win: +35%.**

## Pre-computed optical flow — negative result

`vt_optical_flow.swift` (binary `vtof`) runs three modes:

- `otf` — on-the-fly flow (baseline)
- `pre` — a dedicated `VTOpticalFlowConfiguration` session producing `VTFrameProcessorOpticalFlow`,
  fed into a `VTFrameRateConversionConfiguration(usePrecomputedFlow: true)` session
- `flow` — the flow session alone

At 1920×1080, 24 → 60, measured sequentially in one sitting:

| Mode | Flow pass | Interp pass | Total | Output fps |
| --- | --- | --- | --- | --- |
| `otf` | — | 8382–8411 ms | 8382–8411 ms | **60.3** |
| `pre` | 5057–5076 ms | 4554–4598 ms | 9611–9674 ms | **53.0** |

Pre-computing costs 21.1 ms/pair and saves only 16.0 ms/pair. **Net loss of 14%.** Apple's internal
on-the-fly flow is already as efficient as the standalone flow session, so splitting the work across
two sessions only adds a round trip.

`vt_of_diag.swift` (binary `vtofdiag`) documents the shapes: for a 1920×1080 source the flow field
is **240×135**, pixel format `843264104` (`TwoComponent16Half`) — a 1/8-scale field, 129 KB.
Source format `1380411457` (`64RGBAHalf`) is what `frameSupportedPixelFormats` *reports*, but 420v
is accepted and is what you want.

## Concurrency scaling

Separate OS processes, each at depth 2, 1920×1080, 24 → 60:

| Workers | Per worker | Aggregate |
| --- | --- | --- |
| 1 | 81.8 | 81.8 |
| 2 | 94.6 | 189.2 |
| 3 | 75.2 | 225.6 |
| 4 | 61.8 | 247.2 |

Aggregate ceiling is ~250 output fps at 1080p. A single process extracts only 82 of it.

## Two measurement traps I hit — both produced wrong conclusions first

1. **Errored callbacks counted as success.** `vt_ll_60.swift` incremented its produced counter after
   the semaphore wait regardless of the completion-handler error, so a size that failed *every* call
   still printed a plausible fps and looked like it worked. This made 4K look like it passed on the
   low-latency path. The probe now accumulates errors under a lock, exits 3, and prints `FAIL`.
   **Always check the completion-handler error.**
2. **Contention read as a resolution limit.** An earlier sweep ran while other work was in flight;
   several sizes failed with `-19740`. Re-tested in isolation, 3× each, they all pass. The apparent
   "minimum size" was an artefact.

A third trap, from the earlier round: the Swift `async` form of `process()` returns in 0.08 ms and
never writes the destination. All timing must use the completion-handler form.

## Reproduce

```bash
cd analysis/probes
swiftc -O -o vtofq vt_pipeline.swift
swiftc -O -o vtof  vt_optical_flow.swift
swiftc -O -o vtofdiag vt_of_diag.swift
swiftc -O -o vtll  vt_ll_60.swift

./vtofq 1920 1080 24 240 1              # lock-step     -> ~60 fps
./vtofq 1920 1080 24 240 2              # pipelined     -> ~80 fps
./vtofq 1920 1080 23.976 240 2 420v 59.94   # NTSC target -> ~82 fps
./vtofq 1920 1080 23.976 240 2 420v 60      # 60.000      -> ~77 fps
./vtof  1920 1080 24 240 otf 420v       # on-the-fly flow
./vtof  1920 1080 24 240 pre 420v       # pre-computed flow (slower)
bash ../benchmarks/run_final_bench.sh   # full sweep
```
