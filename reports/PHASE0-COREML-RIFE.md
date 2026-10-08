# Phase 0 — CoreML RIFE: convertibility proved, real-time disproved

**Date:** 2026-10-08 · **Machine:** Apple M2 Max, macOS 27.0.1
**Toolchain:** coremltools 9.0 · torch 2.7.0 · Python 3.11.15 · RIFE 4.25 (MIT)

---

## Verdict

| Question | Answer |
| --- | --- |
| Does RIFE convert to CoreML? | **Yes — completely.** Every op, including all 18 warps. |
| Does it stay faithful to PyTorch? | **Yes — 68.0 dB PSNR**, mean error 0.027/255. |
| Can it do real-time 1080p playback? | **No. 25.9 calls/s against 47.9–59.8 needed.** |
| Can the ANE help? | **No — it is 30× slower than the GPU.** |
| Is CoreML faster than ncnn+Vulkan? | **No — slightly slower (25.9 vs 28.5).** |

**Consequence for the build:** decision #2 was *"batch + playback, gated on measurement."* The gate
has now been measured and it **fails**. The RIFE quality tier ships **batch-only**. That is exactly
what the gate was for, and it is the honest answer rather than a promised feature that stutters.

---

## What was actually built

```
analysis/coreml/
├── Practical-RIFE/              upstream repo (MIT), for model/warplayer.py
├── models/rife425/train_log/    official 4.25 package: IFNet_HDv3.py + flownet.pkl
├── models/rife425lite/          official 4.25.lite package
├── convert_rife.py              the converter
├── bench_coreml.py              the speed harness
├── parity_check.py              the correctness harness
├── build/                       8 converted .mlpackage models
└── results/phase0_bench.txt     raw measurements
```

The weights are the **official Google Drive releases**, downloaded directly (22.9 MB zip, dated
2024-09-19). A HuggingFace mirror (`Upsampler/rife-4-25`) exists as a cross-check but was not needed.

### Two deliberate changes to the reference implementation

Both are documented in `convert_rife.py` and both are **proven equivalent by `--verify`**:

1. **The warp grid is precomputed as a constant buffer.** Upstream calls `torch.linspace` on every
   invocation and caches it in a module-level dict. That traces to an `aten::linspace` node.
   Replacing it with a registered buffer removes the op and lets the converter constant-fold it —
   the grid ends up as a plain `const` in the graph.

2. **`timestep` is an input tensor, not a baked constant.** Decision #4 originally chose "baked per
   phase". **That is not viable and I changed it.** The reason is arithmetic: a 24.000 → 59.94
   conversion has a ratio of 999/400, so the phase pattern only repeats after **999 source frames**
   and there are hundreds of distinct fractional phases. Baking would mean hundreds of models.
   Passing a `(1,1,1,1)` tensor costs one `tile` op and gives one model for every rate. Verified
   bit-identical.

---

## 1. Convertibility — solved, and the earlier report was right about the route

The whole RIFE 4.25 graph converts. From the saved `.mlpackage`:

```
MIL ops: 1098 total, 15 distinct
  const=785  conv=56  leaky_relu=56  add=55  slice_by_index=44  mul=29
  concat=19  resample=18  upsample_bilinear=11  transpose=10
  conv_transpose=7  pixel_shuffle=5  tile=1  sigmoid=1  sub=1

resample (the RIFE warp): 18   grid_sample leftovers: 0
```

**18 `resample` ops is exactly the number of warp calls in IFNet** (blocks 1–4 contribute 2 each,
plus 2 per block for the merged images, across 5 blocks). Zero unconverted `grid_sample` ops remain.

This settles the risk that `WHY-NOT-RIFE.md` and `BUILD-DECISIONS.md` §13.3 both carried. The
prediction there — *"`grid_sample` → MIL `resample`, with exactly RIFE's arguments"* — is confirmed
in practice, not just from the op registry.

---

## 2. Correctness — 68 dB, so fp16 is safe

`parity_check.py` runs identical structured inputs (smooth gradients plus a moving block — closer to
real footage than random noise) through the untouched upstream PyTorch path and through CoreML:

```
max abs diff : 0.060766   (15.50/255)
mean abs diff: 0.000106   ( 0.027/255)
PSNR         : 68.08 dB
p99.9 diff   : 0.000594   ( 0.15/255)
verdict      : PASS
```

The max is a single outlier pixel where fp16 rounding flipped a bilinear tap; 99.9% of pixels are
within 0.15/255. **The fp16 flow-precision worry is not real.** The `mlx-community/RIFE-4.25` card
warns that *"RIFE's coarse-to-fine flow is fp16-sensitive"* and ships fp32 for that reason — the
measurement does not support it, and fp16 is 7% faster at half the size.

---

## 3. Speed — the number that decides it

All at `compute_units = CPU_AND_GPU`, 20 iterations after 3 warm-ups:

| Model | Size | ms/call | **calls/s** | Mpx/s |
| --- | --- | --- | --- | --- |
| rife425 fp16 | 960×576 | 13.3 | **75.1** | 41.5 |
| rife425 fp16 | 1280×768 | 19.8 | **50.5** | 49.7 |
| rife425 fp16 | 1600×960 | 29.3 | **34.1** | 52.4 |
| **rife425 fp16** | **1920×1088** | **38.5** | **25.9** | 54.2 |
| rife425 fp32 | 1920×1088 | 42.0 | 23.8 | 50.4 |
| rife425.lite fp16 | 1920×1088 | 41.2 | 24.3 | 51.4 |

**Throughput is flat at ~50 Mpx/s.** Perfectly linear in pixel count, which is the signature of a
GPU-compute-bound workload. RIFE at 1080p is simply ~50 megapixels/second of work on this GPU, and
no framework choice changes that.

### Converting calls/s into the actual requirement

Each RIFE call produces exactly **one** interpolated frame, and passthrough frames are free:

| Conversion | Interpolated fraction | Calls/s needed | Have at 1080p | Result |
| --- | --- | --- | --- | --- |
| 23.976 → 59.94 | 79.9% | **47.9** | 25.9 | **FAIL — 0.54×** |
| 24.000 → 59.94 | 99.8% | **59.8** | 25.9 | **FAIL — 0.43×** |
| 29.97 → 59.94 | 49.9% | 29.9 | 25.9 | **FAIL — 0.87×** |

Even the most favourable case misses. **The RIFE tier cannot play 1080p in real time.**

### The resolution that *would* work

At ~50 Mpx/s, solving for the required call rate:

| Conversion | Max interpolation resolution |
| --- | --- |
| 23.976 → 59.94 | ~1362×766 |
| 24.000 → 59.94 | ~1219×685 |
| 29.97 → 59.94 | ~1724×969 |

So a real-time RIFE tier would have to interpolate at roughly **768p or below** — which defeats the
purpose of a tier whose entire justification is quality.

### It does not scale with concurrency

```
2 thread(s):   24.4 calls/s aggregate
3 thread(s):   24.1
4 thread(s):   24.3
6 thread(s):   24.3
```

Flat. Unlike `VTFrameProcessor` (which scaled 4 workers → 247 fps aggregate because it is
latency-bound), RIFE is **saturated on one GPU**, so batch throughput is ~25 calls/s no matter how
many workers you throw at it. A 2-hour film at 23.976 → 59.94 needs ~345,600 RIFE calls → **~3.7
hours**, against ~1.2 hours for the VTFrameProcessor engine.

---

## 4. The compute-unit trap — the single most important implementation detail

This cost me the first benchmark run, and it would cost the app its performance:

| `compute_units` | ms/call | calls/s | vs GPU |
| --- | --- | --- | --- |
| **`CPU_AND_GPU`** | **38.8** | **25.8** | 1.0× |
| `ALL` *(the default)* | 307.1 | 3.3 | **7.9× slower** |
| `CPU_ONLY` | 369.6 | 2.7 | 9.5× slower |
| `CPU_AND_NE` | 1186.5 | 0.84 | **30.6× slower** |

**`MLModelConfiguration.computeUnits = .all` — the default — is 8× slower than `.cpuAndGPU`.** The
CoreML planner sees the `resample` op, decides the ANE is the best home for the surrounding
convolutions, and then pays enormous transfer costs shuttling between engines.

This is a hard rule for the build:

> **Never use `.all` for the RIFE tier. Request `.cpuAndGPU` explicitly.**

---

## 5. The ANE is unusable for RIFE — and `align_corners` is not the reason

`CPU_AND_NE` at 1186 ms is *worse than CPU-only* (370 ms), which is the classic signature of a
partitioned graph paying per-op transfer costs rather than a slow-but-working ANE path.

I tested the obvious hypothesis. RIFE's warp needs `align_corners=True`, and the ANE is known to be
picky about `resample` arguments. `align_corners=True` is mathematically emulatable with
`align_corners=False` by a pure grid rescale:

```
align_corners=True : pixel = (g + 1)/2 × (N − 1)
align_corners=False: pixel = ((g + 1) × N − 1)/2
⇒ g_false = g_true × (N − 1)/N
```

Implemented, converted, and measured:

```
ac=True   CPU_AND_GPU   39.8 ms  |  CPU_AND_NE  1165.7 ms
ac=False  CPU_AND_GPU   38.8 ms  |  CPU_AND_NE  1186.5 ms
```

**No change.** `align_corners` is not the blocker; the `resample` op itself is not ANE-viable at
this size. The emulation is therefore a documented dead end — and it is not free: it drifts 5.2e-3
(1.3/255) through the 5 cascaded blocks because `border` clamping amplifies the grid rescale's
rounding. **Use `align_corners=True` directly.**

---

## 6. Three corrections to earlier reports

I would rather flag these than let them stand.

**6a. `align_corners` is `True`, not `False`.**

`BUILD-DECISIONS.md` §13.3 states the warp uses `align_corners=False`. That is wrong. From
`model/warplayer.py` line 28:

```python
return torch.nn.functional.grid_sample(input=tenInput, grid=g, mode='bilinear',
                                       padding_mode='border', align_corners=True)
```

`mlx-community/RIFE-4.25`'s `config.json` agrees (`"grid_align_corners": true`). The report was
wrong; the source and the independent mirror both say `True`.

**6b. RIFE requires dimensions divisible by 64, not 16.**

This one bit me during the resolution sweep, and it is a real app-level constraint. `IFBlock.conv0`
is **two** stride-2 convolutions, applied at the coarsest pyramid level (`scale=16`). So `H/16` must
be divisible by 4:

```
H=1088, scale=16:  interp 68 → conv0 17 → lastconv 68 → restored 1088   OK
H= 544, scale=16:  interp 34 → conv0  9 → lastconv 36 → restored  576   MISMATCH
```

The floor rounding in the second stride-2 conv makes the ConvTranspose2d+PixelShuffle that restores
the size disagree with the frame being warped. **The app must pad every frame to a multiple of 64.**
That is why RIFE's own tooling pads to 128. Practical cost: 1080p → 1920×1088 (+0.7%), 720p →
1280×768 (+6.7%), 4K → 3840×2176 (+1.9%).

**6c. "lite" is not faster.**

`4.25.lite` differs from `4.25` in exactly one line — `block4` channels 32 → 24 — a 0.7% parameter
reduction. Measured it is **5% slower** (24.3 vs 25.9 calls/s), almost certainly because 24 is a
poor channel count for GPU vectorisation. **Use standard 4.25.**

---

## 7. What this means for the build

**Decision #2 gate: FAILED.** The quality tier is **batch-only**.

| | VTFrameProcessor (default) | RIFE / CoreML (quality) |
| --- | --- | --- |
| 1080p real-time playback | **80.8 fps — yes** | 25.9 calls/s — **no** |
| Concurrency scaling | 4 workers → 247 fps | **none — GPU saturated** |
| 2 h film, 1080p batch | ~1.2 h | ~3.7 h |
| Model size | system framework | 20 MB |
| Dependency | none | none (no Vulkan, no Homebrew) |
| Quality | Apple's engine | RIFE 4.25 |

**The conversion still achieved its goal — just not the one that was at risk.** It eliminated
Vulkan, MoltenVK, the Homebrew dependency, the RGB-float32 format conversion, and the ncnn custom
layer. What it did **not** do is make RIFE fast: 25.9 vs ncnn+Vulkan's 28.5 is a **13% regression**.
The honest summary is that CoreML bought *shippability*, not speed.

### Rules this adds to the invariants list

9. **Request `.cpuAndGPU` for the RIFE tier.** `.all` is 8× slower. This is not a tuning
   preference; the default is actively wrong for this graph.
10. **Pad every frame to a multiple of 64.** RIFE's pyramid needs it; 16 is not enough.
11. **Use `align_corners=True`.** The `False` emulation buys nothing and costs 1.3/255.
12. **Use fp16.** 7% faster than fp32, half the size, 68 dB PSNR.
13. **Do not use `4.25.lite`.** It is slower than the standard model.

### Minor: model size is dominated by the baked grid

The 1080p model is 20 MB, of which ~8.4 MB is the constant warp grid (2 × 1088 × 1920 at fp16). A
runtime-generated grid would save it, but reintroduces the `linspace` op that coremltools handled
poorly. 20 MB is acceptable; noted rather than fixed.

---

## 8. Reproduce

```bash
VENV=/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml
cd "/Users/Wasim/Documents/Projects/60FPSVideo/analysis/coreml"

# prove the rewrite matches upstream, both grid modes
$VENV/bin/python convert_rife.py --verify --height 128 --width 192

# convert 1080p
$VENV/bin/python convert_rife.py --height 1088 --width 1920 --precision fp16

# correctness
$VENV/bin/python parity_check.py --model build/rife425_960x576_fp16.mlpackage \
                                 --height 576 --width 960

# speed (note: CPU_AND_GPU, not the default)
$VENV/bin/python bench_coreml.py --model build/rife425_1920x1088_fp16.mlpackage \
                                 --height 1088 --width 1920 --iters 20 \
                                 --compute-units CPU_AND_GPU
```

Environment: `uv venv --python 3.11 …/envs/coreml`, then
`uv pip install torch==2.7.0 coremltools numpy opencv-python-headless gdown`.
**Pin torch to 2.7.0** — coremltools 9.0 warns that newer torch is untested, and uv's default
(2.14.1) is far outside that window.

---

## Still open

| Item | Status |
| --- | --- |
| Can a *different* RIFE variant be real-time? | Not tested. The 50 Mpx/s ceiling is architectural, so a smaller model (older v4.x, ~139 layers) is the only lever — and it trades away the quality the tier exists for. |
| Is CoreML RIFE's output *better looking* than VTFP's? | **Unmeasurable by me.** Needs real film content and your eyes. PSNR against PyTorch proves faithfulness, not beauty. |
| Does 8-bit / 10-bit / HDR survive the pipeline? | Unverified. |
| Batch throughput end-to-end (decode + infer + encode + mux) | Only the inference stage is measured. ~3.7 h for a 2 h film is inference alone. |
