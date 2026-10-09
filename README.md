# 60FPSVideo

Feasibility study and stack design for a **native Apple Silicon** video frame-interpolation
application — real-time playback **and** batch conversion, with output pinned to the 60-family
frame rate (**59.94 by default** — see `reports/BUILD-DECISIONS.md` §5).

The reference product analysed is **SVP 4 Mac** (`/Applications/SVP 4 Mac.app`), using
[`morluto/rea`](https://github.com/morluto/rea) as the reverse-engineering toolchain.

## Headline result

A native Apple Silicon implementation is **feasible**, and it does not require reimplementing
SVP's engine. Apple's `VTFrameProcessor` (VideoToolbox) provides first-party frame interpolation
that was measured **real-time at 1080p on an M2 Max**.

Both playback and batch conversion are achievable from one shared interpolation engine:

| Source → 60 fps @ 1920×1080 | Output fps | Real-time? |
| --- | --- | --- |
| **24.000 (film)** | **80.3** | **yes — 34% headroom** |
| **23.976 (NTSC film)** | **76.8** | **yes — 28% headroom** |
| 25 (PAL film) | 75.8 | yes |
| 29.97 | 64.7 | yes |
| 50 | 44.8 | no — batch only |
| 59.94 | 37.4 | no — batch only |
| 4K, 24 → 60 | 33.4 | no — batch only |

Measured at **60.000**. The shipped default is **59.94**, which for NTSC-family sources is the cheaper
target because the rates share a denominator: 23.976 → 59.94 runs at **79.1 fps** with **20% of output
frames needing no interpolation at all**, against 76.8 fps and 0% at 60.000. Integer rates (24.000, 25,
30, 50) are the other way round and keep their passthrough at 60.000, which is why the policy is a
setting with 59.94 as its default rather than a constant.

Batch throughput scales to **~247 output fps aggregate with 4 concurrent workers** — a 2 h film in
about 29 minutes at 1080p.

## Read this first

**→ [`reports/ENGINE-EQUIVALENCE.md`](reports/ENGINE-EQUIVALENCE.md)** ⭐ **latest**
**The RIFE tier question is closed.** VTFrameProcessor and CoreML RIFE 4.25 are statistically
indistinguishable on real 4K HDR film — 465 of 475 frames within 2/255, and on a ground-truth holdout
(delete every odd frame, re-create it at t=0.5, score) they differ by 0.105 MAE with |t| = 1.06, while
RIFE costs **4.06×** the time. Also documents the range bug that made the first pass wrong by 96%.

**→ [`reports/REAL-CONTENT-AB.md`](reports/REAL-CONTENT-AB.md)**
Real 4K HDR film from your own disc, both engines, one 8-second clip. Contains the measured cost of
the 4K decision (48% dropped frames in playback; 2.4–3.7× in batch), the exact-rational frame-rate
bug that was silently costing 20% of throughput, and the scene-change finding that adds a mandatory
Phase 1 deliverable. Artifacts: `~/Desktop/FNF-60FPS-A-B/`.

**→ [`reports/PHASE0-COREML-RIFE.md`](reports/PHASE0-COREML-RIFE.md)**
Phase 0 executed: RIFE 4.25 converted to CoreML (all 18 warps → `resample`, 68 dB PSNR), then
benchmarked. **Convertibility solved; real-time disproved** — 25.9 calls/s at 1080p against
47.9–59.8 needed. Includes the `.all`-is-8×-slower trap and three corrections to earlier reports.

**→ [`reports/BUILD-DECISIONS.md`](reports/BUILD-DECISIONS.md)**
The 14 build decisions with measured effects, your recorded choices, and the consequences of each.

**→ [`reports/PLAYBACK-AND-BATCH.md`](reports/PLAYBACK-AND-BATCH.md)**
Playback + batch in one app, film-rate sources to 60 fps, the pipelining finding that lifts
throughput 35%, 60.000 vs 59.94 target rates, concurrency scaling, recommended architecture, risks.

**→ [`reports/WHY-NOT-RIFE.md`](reports/WHY-NOT-RIFE.md)**
Why RIFE isn't the primary engine even though it's MIT and already arm64 — measured head-to-head
against `VTFrameProcessor`, plus the Vulkan/MoltenVK/VapourSynth deployment problem and the GPL-2.0
issue with MVTools.

**→ [`reports/FEASIBILITY-AND-STACK.md`](reports/FEASIBILITY-AND-STACK.md)**
Full analysis: what REA is, what it found in the bundle, the complete architecture matrix,
the legal position, the recommended stack, measured performance, and risks.

**→ [`reports/60FPS-OUTPUT.md`](reports/60FPS-OUTPUT.md)**
60 fps-only output: which source rates are easy, which are hard, measured throughput per
conversion, and the API resolution ceilings. *Partly superseded — see the correction banner.*

## Key findings at a glance

- **77 of 87** Mach-O binaries in SVP 4 Mac are already universal (x86_64 + arm64).
- Only **9** files are Intel-only, and they are the GUI, four optional extensions, and three
  third-party utilities — not the interpolation engine.
- `libsvpflow1/2` (the core engine) and `libRIFE` (neural interpolation) **already ship arm64
  slices**. SVP's build system carries a distinct `libsvpflow2_arm.1.dylib` target.
- **SVP 4 Mac does not use MVTools at all.** Its motion engine is its own `libsvpflow1/2`; MVTools
  belongs to SVP's Windows/AviSynth setups and is GPL-2.0, which blocks App Store distribution.
- SVP's licence forbids reverse engineering. The legitimate path is clean-room, on published
  algorithms plus MIT/GPL upstreams and Apple's public APIs.
- **Keeping two requests in flight lifts throughput 35%** — a single lock-step
  `VTFrameProcessor` session leaves a third of the hardware idle. This is the difference between
  23.976 → 60 passing (77 fps) and failing (57 fps).
- **Pre-computed optical flow is 14% *slower* than the default** — measured, and it contradicts
  the earlier recommendation in `60FPS-OUTPUT.md`.
- **For NTSC-family sources, targeting 59.94 instead of 60.000 is much cheaper** — 29.97 → 59.94
  runs at 139 fps via the low-latency path versus 65.7 fps for 29.97 → 60.000.
- **RIFE (ncnn + Vulkan/MoltenVK) runs at 0.47× real-time** at 1080p and peaks at 42 fps aggregate
  against `VTFrameProcessor`'s 247 fps — a **5.9× deficit** — and it needs VapourSynth plus a
  Homebrew Vulkan loader to run at all. RIFE is a *quality* option, not a performance one.
- Four sharp edges in `VTFrameProcessor` were reproduced and documented: the Swift `async`
  `process()` silently does no work; per-frame buffer allocation causes crashes; the low-latency
  path **silently** fails above 1920×1080 while `startSession` still reports success; and the
  `frameSupportedPixelFormats` property misreports which formats actually work.
- **RIFE converts to CoreML completely** — all 18 `grid_sample` warps become `resample`, zero
  leftovers, and the result is **68.0 dB PSNR** against PyTorch fp32. fp16 is *not* a quality
  problem, contrary to the MLX port's warning.
- **But CoreML RIFE is not real-time at 1080p**: 25.9 calls/s against the 47.9–59.8 required. RIFE
  is GPU-compute-bound at a hard **~50 Mpx/s** ceiling, so the quality tier is **batch-only**.
- **`.all` compute units — the CoreML default — is 8× slower than `.cpuAndGPU`** (307 ms vs 39 ms)
  for this graph. The ANE is worse still: 30× slower than the GPU.
- **RIFE needs frame dimensions divisible by 64**, not 16: `IFBlock.conv0` runs two stride-2 convs
  at scale=16, so 544 silently restores to 576 and the warp breaks.

## Layout

```
60FPSVideo/
├── reports/
│   ├── PHASE0-COREML-RIFE.md         CoreML conversion + speed spike        (latest)
│   ├── BUILD-DECISIONS.md            14 decisions, your choices, consequences
│   ├── PLAYBACK-AND-BATCH.md         playback + batch, 60 fps, film sources
│   ├── WHY-NOT-RIFE.md               RIFE/MVTools measured vs VTFrameProcessor
│   ├── 60FPS-OUTPUT.md               60 fps-only output, per-rate ceilings   (partly superseded)
│   └── FEASIBILITY-AND-STACK.md      architecture, legal position, stack
├── analysis/
│   ├── arch-matrix.tsv               87 Mach-O binaries + architecture slices
│   ├── rea/                          REA evidence bundles
│   ├── benchmarks/                   throughput data, method, stability findings
│   ├── probes/                       Swift benchmark / probe source
│   │   └── rife/                     RIFE benchmark (Python + VapourSynth, ncnn)
│   └── coreml/                       RIFE → CoreML conversion + benchmark
│       ├── convert_rife.py           converter (constant-grid, timestep-as-input)
│       ├── bench_coreml.py           speed harness
│       ├── parity_check.py           CoreML vs PyTorch correctness
│       ├── build/                    8 converted .mlpackage models
│       └── results/                  raw Phase 0 measurements
└── docs/
```

## Environment used

Mac14,6 — Apple M2 Max (38-core GPU, 64 GB), macOS 27.0.1 (26A434), Xcode 27.1 / Swift 6.4.

**A note on measurement.** This machine carries other load, and `VTFrameProcessor` clocks shift
between runs. Absolute figures move a few percent; depth-1/depth-2 comparisons were therefore run
*interleaved* so drift affects both arms equally. Treat ratios as solid and absolute values as
±5%.
