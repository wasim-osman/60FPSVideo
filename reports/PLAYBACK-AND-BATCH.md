# Playback **and** batch conversion, output pinned to 60 fps

**Your two questions:**

1. Can the app do both real-time playback *and* batch conversion?
2. You want 60 fps, not 50. Most of your source files are movies at standard film rates
   (24 / 23.976 fps). Is that possible?

**Both answers are yes — and film-rate sources turn out to be the *good* case, not the hard one.**

Measured 2026-10-08 on Mac14,6 (Apple M2 Max, 38-core GPU, 64 GB), macOS 27.0.1 (26A434).
Raw output: [`analysis/benchmarks/final_bench_60fps.txt`](../analysis/benchmarks/final_bench_60fps.txt).

> **This report supersedes parts of [`60FPS-OUTPUT.md`](60FPS-OUTPUT.md).** That earlier report
> measured everything in a *lock-step* harness — submit one call, block until it completes, submit the
> next. That harness was leaving **35% of the hardware idle**. Two of its conclusions were wrong as a
> result, and both are corrected here (§4).

---

## 1. Play and batch are one engine with two schedulers

This is the single most useful thing to know: **the interpolation core is identical.** Only the
scheduling and I/O differ.

| | Playback | Batch |
| --- | --- | --- |
| Source | `AVAssetReader` on the file | `AVAssetReader` on the file |
| Interpolation | `VTFrameProcessor` | `VTFrameProcessor` — **same code** |
| Sink | `AVSampleBufferDisplayLayer` / Metal | `VTCompressionSession` → `AVAssetWriter` |
| Pacing | clock-driven, must keep up | as fast as possible |
| Workers | 1 | 3–4 concurrent |
| Latency matters? | yes (~100 ms budget) | no |

So you are not building two products. You are building one `Interpolator` module and giving it two
callers. Everything below applies to both.

---

## 2. The finding that changed the design: keep two requests in flight

A single `VTFrameProcessor` session that submits a call and blocks on the completion handler is
**round-trip-latency-bound**. The accelerator sits idle during every CPU↔accelerator handoff.

Submitting the next request *before* waiting for the previous one fixes it. Measured, interleaved to
cancel out thermal drift, 1920×1080, 24 → 60:

| Submission depth | Output fps | Per-call |
| --- | --- | --- |
| 1 (lock-step) | 60.9 | 41.1 ms |
| **2 (pipelined)** | **82.5** | **30.0 ms** |
| 3 | 82.4 | 30.3 ms |
| 4 | 82.8 | 30.2 ms |

**+35% for free, saturating at depth 2.** The same +35% gain appears at every source rate tested.

This is not an optimisation you can defer. At depth 1, 23.976 → 60 runs at **57 fps — it fails.**
At depth 2 it runs at **77 fps — it passes with 28% headroom.** Pipelining is the difference between
the app working and not working.

---

## 3. Your case: film-rate sources to 60 fps

24 → 60 is a 2.5× ratio. That is actually a *friendly* ratio:

- Only **four** distinct interpolation phases are ever needed (0.2, 0.4, 0.6, 0.8), and they repeat.
- **Two phases fit in one `process()` call**, and the optical-flow computation is shared between them.
- **20% of output frames are free.** Every second source frame lands exactly on a 60 fps output
  position, so it is passed through untouched — no interpolation, no cost.

### Measured, 1920×1080, depth 2

| Source | → 60.000 fps | Headroom vs the 60 fps target |
| --- | --- | --- |
| **23.976 (NTSC film)** | **76.8 fps** | **+28%** ✅ |
| **24.000 (film)** | **80.3 fps** | **+34%** ✅ |
| 25 (PAL film) | 75.8 fps | +26% ✅ |
| 29.97 | 64.7 fps | +8% ✅ |
| 50 (PAL) | 44.8 fps | −25% ❌ |
| 59.94 | 37.4 fps | −38% ❌ |

So: **your movie files are fine.** 24 and 23.976 both clear real-time at 1080p with comfortable
margin. The rates that fail (50, 59.94) are the ones you are *not* using.

> **Why 59.94 → 60 is the worst row in the table**, despite being the smallest ratio change: the two
> rates almost never coincide, so **600 of 601 output frames must be interpolated**, and each source
> interval carries only a single phase so there is nothing to batch. A near-1× ratio is the most
> expensive conversion there is. If your sources were 59.94 you would want to output 59.94 and skip
> interpolation entirely — see §5.

---

## 4. Two things I tested that did **not** work

I would rather tell you this than have you discover it later.

### 4a. Pre-computed optical flow is *slower*, not faster — do not use it

`60FPS-OUTPUT.md` recommended `VTOpticalFlowConfiguration` to buy margin for 24 → 60. I built it and
measured it. It loses.

| Path, 1080p 24 → 60 | Flow pass | Interp pass | Total | Output fps |
| --- | --- | --- | --- | --- |
| On-the-fly flow (default) | — | 8411 ms | **8411 ms** | **60.3** |
| Pre-computed flow (2 sessions) | 5057 ms | 4554 ms | **9611 ms** | **53.0** |

Pre-computing costs 21.1 ms/pair in the flow session and saves only 16.0 ms/pair in the interpolation
session. Apple's internal on-the-fly flow is already as efficient as the standalone flow session, so
splitting the work into two sessions just adds a round trip.

Incidentally, the dedicated flow session is cheap in *memory* — the field it produces for 1080p is
**240×135** (1/8 scale, two-component half-float, 129 KB), not a full-resolution buffer. It is fast to
move; it simply is not faster end-to-end. **Recommendation: leave `usePrecomputedFlow: false`.**

### 4b. The 640×360 low-latency "minimum size" was a false alarm

`60FPS-OUTPUT.md` reported that 640×360 failed with `-19740` and inferred a minimum size. That was
**transient resource contention** from another process, not a resolution limit. Re-tested 3× each:
640×360, 854×480 and 960×540 all pass.

The *upper* bound, however, is real and I re-verified it with an error-aware harness (§6d).

---

## 5. Choose your output rate deliberately: 60.000 vs 59.94

You said 60 fps. Worth knowing: if a source is in the NTSC family (23.976 / 29.97 / 59.94),
targeting **59.94** instead of **60.000** is both cheaper and cadence-correct.

| Source | → 59.94 | → 60.000 | Gain |
| --- | --- | --- | --- |
| 23.976 | **82.0 fps** (20% passthrough) | 77.6 fps (0% passthrough) | +5.7% |
| 29.97 | **76.7 fps** (50% passthrough) | 65.7 fps (0% passthrough) | +16.7% |
| 29.97 via low-latency path | **≈138.6 fps** (exact 2×) | n/a | **+111%** |
| 59.94 | passthrough — **free** | 37.4 fps | — |

Why the gap: `23.976 × 2.5 = 59.94` **exactly**, so every second source frame lands on an output
position and needs no work. `23.976 × 2.5 = 60.000` is not exact, so the frames never line up and
**every single output frame must be interpolated.**

**What I'd suggest:** make the target rate a per-job setting, defaulting to 59.94 when the source is
an NTSC-family rate and 60.000 otherwise. That is what SVP-class tools do, and it is why they are
fast on film material. On a modern 60.00 Hz Mac panel 60.000 is marginally better for display; on an
HDMI TV, 59.94 is the correct match. Either way, **your 23.976 sources work at 1080p in real time on
both settings** — this is a performance and correctness choice, not a feasibility one.

---

## 6. Full measured results

### 6a. Source rate sweep, 1920×1080

240 source intervals, two independent rounds. Depth 1 = lock-step, depth 2 = pipelined.

| Source | d1 r1 | d1 r2 | d2 r1 | d2 r2 | **d2 avg** | Passthrough |
| --- | --- | --- | --- | --- | --- | --- |
| 23.976 | 57.4 | 56.0 | 76.5 | 77.0 | **76.8** | 0.2% |
| 24 | 59.1 | 59.9 | 79.7 | 80.9 | **80.3** | 20% |
| 25 | 55.4 | 56.1 | 75.1 | 76.4 | **75.8** | 8% |
| 29.97 | 47.7 | 48.0 | 65.3 | 64.0 | **64.7** | 0.2% |
| 50 | 34.5 | 34.4 | 45.0 | 44.6 | **44.8** | 17% |
| 59.94 | 28.8 | 28.6 | 37.4 | 37.4 | **37.4** | 0.4% |

Round-to-round spread is ~1%, so these are trustworthy.

### 6b. Resolution sweep, 24 → 60

| Resolution | Depth 1 | **Depth 2** | 60 fps? |
| --- | --- | --- | --- |
| 1280×720 | 70.8 | **80.5** | ✅ |
| 1920×1080 | 60.4 | **80.8** | ✅ |
| 3840×2160 | 23.9 | **33.4** | ❌ — batch only |

### 6c. Low-latency path (30 → 60, exact 2×)

| Resolution | Per-call | Output fps |
| --- | --- | --- |
| 1280×720 | 4.24 ms | **472.0** |
| 1920×1080 | 14.43 ms | **138.6** |

### 6d. Low-latency resolution ceiling — verified error-aware

My first harness counted *errored* callbacks as successful work, which produced a false "4K passes"
reading. Rebuilt to fail loudly on any callback error:

| Resolution | Result |
| --- | --- |
| 1920×1080 | ✅ 138.6 fps, destination verified written |
| 1920×1088 | ❌ `-19730 Processor is not initialized` |
| 2048×1080 | ❌ same |
| 2048×1152 | ❌ same |
| 2560×1440 | ❌ same |
| 3840×2160 | ❌ same |

**The trap:** `startSession` *succeeds* at these sizes. The session appears healthy. Every
`process()` call then fails and **the destination buffer is never written.** If your code does not
check the completion-handler error, you will silently emit un-interpolated frames. Guard this
explicitly.

### 6e. Concurrency scaling — this is where batch throughput comes from

Separate processes, 1080p 24 → 60, each at depth 2:

| Concurrent workers | Per worker | **Aggregate** |
| --- | --- | --- |
| 1 | 81.8 fps | **81.8 fps** |
| 2 | 94.6 fps | **189.2 fps** |
| 3 | 75.2 fps | **225.6 fps** |
| 4 | 61.8 fps | **247.2 fps** |

The hardware sustains roughly **250 output fps** at 1080p; one process can only extract 82 of it.
**3–4 concurrent workers give ~3× the throughput of one** — and 4 workers still each run at 61.8 fps,
i.e. each individual job remains real-time-capable.

---

## 7. What playback can and cannot do

| Content | Real-time 60 fps playback on M2 Max |
| --- | --- |
| 1080p from 24 / 23.976 / 25 fps | **yes** — 76–80 fps, ~28–34% headroom |
| 1080p from 29.97 fps | **yes** — 64.7 fps (or 138.6 via low-latency if targeting 59.94) |
| 720p, any common rate | **yes** — comfortable |
| 1080p from 50 fps | **no** — 44.8 fps |
| **4K, any source rate** | **no** — 33.4 fps, needs 2× more |

**Latency.** To emit output frames inside source interval `[j, j+1)` you need source frame `j+1`
decoded. That is **one frame of lookahead = 41.7 ms at 24 fps**, plus decode (~5–10 ms) and
interpolation (~30 ms pipelined). Budget **~80–100 ms** end-to-end. Completely fine for watching a
film; not suitable for interactive or gaming use.

**So playback is a 1080p feature.** For 4K source files you have two options: downscale to 1080p for
playback (interpolate at 1080p — the low-latency path even supports 2× spatial upscaling in the same
session, but only for the exact-2× phase-0.5 case), or reserve 4K for batch conversion.

---

## 8. What batch can do

With 4 concurrent workers at 1080p, aggregate ≈ 247 output fps. A 60 fps output means 60 frames per
second of *output* time, so:

| Job (24 fps source) | Output frames | 1 worker (81.8 fps) | 2 workers (189 fps) | **4 workers (247 fps)** |
| --- | --- | --- | --- | --- |
| 1 h 30 m film | 324,000 | 66 min | 29 min | **22 min** |
| 2 h film | 432,000 | 88 min | 38 min | **29 min** |

A 23.976 fps source runs about 4% slower (76.8 fps vs 80.3 fps single-worker), so add a few minutes.
Concurrency scaling was measured at 1080p / 24 fps only.

So a feature-length film converts in **under half an hour** at 1080p, versus ~1.5 hours for a
single-threaded implementation. That is the difference between "batch mode is a checkbox" and "batch
mode is genuinely useful."

Batch is also where 4K and 50 fps sources live: 33.4 fps at 4K converts a 2 h film in about
3.6 hours with one worker. I did **not** measure concurrency scaling at 4K, so I will not quote a
four-worker figure for it.

---

## 9. Recommended architecture

```
                 ┌─────────────────────────────────────────┐
                 │  Interpolator  (one module, shared)     │
                 │                                         │
  AVAssetReader ─┤  plan(srcFps, dstFps) -> phase table    │
   (decode to    │      + passthrough mask                 │
    420v)        │                                         │
                 │  CVPixelBufferPool ring (recycled)      │
                 │  submission queue, depth 2 in flight    │
                 │  VTFrameProcessor + FRC configuration   │
                 └───────────────┬─────────────────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              │                                     │
      ┌───────▼────────┐                  ┌─────────▼──────────┐
      │   PLAYBACK     │                  │      BATCH         │
      │  depth 2       │                  │  depth 2           │
      │  1 worker      │                  │  3-4 workers       │
      │  clock-paced   │                  │  AVAssetWriter     │
      │  AVSampleBuffer│                  │  VTCompression     │
      │  DisplayLayer  │                  │  audio copied as-is│
      └────────────────┘                  └────────────────────┘
```

**Stack:** Swift 6 + SwiftUI · AVFoundation (`AVAssetReader`, `AVAssetWriter`,
`AVSampleBufferDisplayLayer`) · VideoToolbox (`VTFrameProcessor`, `VTCompressionSession`) · Metal only
if you need custom scaling. No Electron, no Qt, no Python.

### Five implementation rules that cost me hours to learn

1. **Use `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (420v).** It is exactly what VideoToolbox
   decodes to and exactly what `VTCompressionSession` encodes from, so there is **zero colour
   conversion** anywhere in the pipeline. Note the API's own `frameSupportedPixelFormats` property
   reports only `64RGBAHalf` for these configurations — that list is **misleading**; 420v works and
   is what you want. Do not add a YUV→RGBA→YUV round trip because the property told you to.
2. **Never use the Swift `async` form of `process()`.** `try await proc.process(parameters:)` returns
   in 0.08 ms and **never writes the destination buffer**. Use the completion-handler form with a
   `DispatchSemaphore`. This silently produced meaningless numbers in an earlier round of testing.
3. **Recycle buffers from a small `CVPixelBufferPool` ring.** Creating a fresh `CVPixelBuffer` per
   frame, especially with `kCVPixelBufferMetalCompatibilityKey`, crashes after ~65–90 frames.
4. **Always check the completion-handler error.** See §6d — the low-latency path fails *silently*
   above 1080p.
5. **Leave `usePrecomputedFlow: false`.** See §4a.

---

## 10. Honest risks

- **Interpolation quality is unverified.** SVP's optional neural tier is RIFE; Apple's
  `VTFrameRateConversion` is a completely different algorithm. I have confirmed the output frames are
  genuinely interpolated (phase 0.40 and phase 0.80 on the same source pair produce *different*
  pixels), but I have **not** compared visual quality against SVP, and I cannot — that needs real
  film content and your eyes. **Do this first.** If Apple's quality is not acceptable, the fallback
  is RIFE, which is MIT-licensed and already arm64 inside SVP — but **convert it to CoreML**, do not
  ship SVP's ncnn+Vulkan build. I measured that build at **0.47× real-time** at 1080p, 2.8× slower
  than Apple's engine, and it does not scale with concurrency. Full numbers and reasoning:
  [`WHY-NOT-RIFE.md`](WHY-NOT-RIFE.md).
- **The throughput numbers include harness overhead that production would not have.** The probe
  synthesises frames in CPU loops (~8 MB of pixel writes per call). A real pipeline that reads
  decoded frames straight out of VideoToolbox should be somewhat faster, so treat these figures as
  conservative.
- **Audio must be passed through untouched.** Copy the audio track with `AVAssetReader` →
  `AVAssetWriter` and do not re-encode it.
- **VFR and unusual sources.** Everything above assumes constant frame rate. Variable-frame-rate
  sources, interlaced content, and files with dropped frames need explicit handling; the phase table
  assumes a fixed source interval.
- **These are M2 Max numbers.** The 1080p low-latency ceiling and the ~250 fps aggregate ceiling may
  differ on M1/M3/M4. Re-measure on your target hardware.
- **Concurrency is a *hardware* ceiling, not a software one.** Four workers reach ~247 fps total;
  adding a fifth worker will not help.

---

## 11. Bottom line

| Question | Answer |
| --- | --- |
| Both playback and batch? | **Yes.** One interpolation engine, two schedulers. |
| 60 fps output (not 50)? | **Yes.** |
| Are 24 / 23.976 fps movie sources viable? | **Yes — they are the good case.** 76.8 and 80.3 fps at 1080p, ~28–34% headroom. |
| Real-time playback at 1080p? | **Yes**, ~80–100 ms latency. |
| Real-time playback at 4K? | **No.** 33.4 fps. Batch only. |
| Real-time playback of 50 fps sources? | **No.** 44.8 fps. Batch only. |
| Batch throughput? | **~247 fps aggregate with 4 workers** → a 2 h film in ~29 min at 1080p. |

**The one thing to do before committing to the design:** put real film content through Apple's
interpolator and judge the quality against SVP. Everything else here is measured and settled.

---

## 12. What was actually built — added 2026-10-09

The table above is the feasibility answer, written before any of it existed. This is the same
questions answered by the thing that now ships. The full record is `BUILD-DECISIONS.md`
§§13–25; this is the summary, and the row that changed is the 4K one.

| Question | Answer, measured on the built app |
| --- | --- |
| Both playback and batch? | **Yes.** One engine, two schedulers, and the batch converter is now the *only* consumer that does not drop anything. |
| 1080p real-time playback? | **Yes.** 59.94 out, sound in sync, the picture at the target rate. |
| 4K real-time playback? | **It plays, and it drops.** ~19 fps presented, ~half the intervals not computed, the picture a fifth of a second behind the clock — permanently, and not growing. That is §13's "keep true 4K and accept the drops", made concrete, and the app says so out loud instead of hiding it. |
| 50 fps sources? | Batch only, unchanged. |
| Batch throughput? | 4 workers, segments with resume, both containers, audio muxed once over the joined picture. |
| Output rate | 59.94 (`OutputRatePolicy.standard`), with `exactSixty` as an override. A policy is a *value*, so batch and playback cannot disagree. |
| HDR | 10-bit P010 end to end, disc metadata carried through, tone-mapped by the system compositor. Verified on the real UHD disc. |
| Sound | Both, as a setting: MP4 + AAC, or MKV + a bit-for-bit copy. On the real disc the copy is the **AC-3 5.1 compatibility track**, not the DTS-HD MA default — a real track off the disc, prepared in 1.67 s. |

### The three things the numbers above cost

**The sound is the clock.** A compressed stream cannot be retimed, so the soundtrack plays at
its own rate and the picture follows it. The clock's own rate stays 1 and the *sound* carries
the speed; putting it in both would advance a 2× film at 4×. The measured A/V lag oscillates
between 92 and 236 ms over a minute and does not grow — a constant offset is a player working
at its limit, and a growing one is a player that will be seconds out by the end of a reel. One
subtraction apart, which is why the harness traces rather than reporting a single number.

**A film is read in pieces and joined once.** A segment renders intervals `[a,b)` but must
*read* `[a−31, b+2]`: the cut verdict needs thirty intervals of history and two frames of
lookahead. Resume is **discard, not trust** — only the manifest says a file is complete, and it
is written after the segment is checked. Audio is muxed once over the joined picture, because
cutting a compressed stream forces a re-encode.

**Progress is counted in intervals, not frames.** A film of `n` frames has `n − 1` intervals and
the pipeline's last announced interval is `n − 2`; dividing by the frame count parks the bar at
99.99% for the last hour of a job, which reads as a hang. The bar also carries the **film's**
interval number rather than the run's, so a resumed job's bar does not restart at zero — a bar
that restarts at 0% on a 90%-finished job makes the user think their work was thrown away.

### Two things worth repeating here

**AVFoundation cannot open Matroska.** ffmpeg decodes and describes; AVFoundation encodes. The
sound therefore needs a route, and there are three with costs 1000× apart: `direct` (open in
place), `remux` (copy the track into MP4 — **1.94 s** for a whole feature film), `transcode`
(re-encode to AAC — **4.5 s per 120 s**, about 3.6 minutes). The app prefers a decodable track,
falls back to a copy, and only re-encodes if there is no choice — and it says which one it took
in the window, because "the sound is fine" and "the sound was re-encoded" are different claims.

**`-map_chapters -1` is not optional.** ffmpeg carries a Matroska's chapters into MP4 as a
`bin_data` track as long as the *whole film*: a 120-second extraction reported a duration of
**5811.447 s**, and `AVAsset.duration` believed it. Every downstream "is this the end of the
film" comparison was then wrong by a factor of 48.

---

## Reproduce

```bash
cd analysis/probes
swiftc -O -o vtofq vt_pipeline.swift       # pipelined arbitrary-phase probe (main instrument)
swiftc -O -o vtll  vt_ll_60.swift          # low-latency path, error-aware
swiftc -O -o vtof  vt_optical_flow.swift   # pre-computed flow A/B
swiftc -O -o vtofdiag vt_of_diag.swift     # optical-flow capability + buffer formats

# usage: vtofq W H SRC_FPS INTERVALS DEPTH [420v|64rgba] [OUT_FPS]
./vtofq 1920 1080 24      240 2          # 24 -> 60, pipelined      (80.3 fps)
./vtofq 1920 1080 24      240 1          # 24 -> 60, lock-step      (59.5 fps)
./vtofq 1920 1080 23.976  240 2 420v 59.94  # 23.976 -> 59.94       (82.0 fps)
./vtofq 1920 1080 23.976  240 2 420v 60     # 23.976 -> 60.000      (77.6 fps)
./vtofq 3840 2160 24      120 2          # 4K 24 -> 60             (33.4 fps)
./vtll  1920 1080 120                    # 30 -> 60 low-latency    (138.6 fps)

# full sweep
bash ../benchmarks/run_final_bench.sh
```
