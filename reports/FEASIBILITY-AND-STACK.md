# Native Apple Silicon 60fps Video Interpolation — Feasibility & Stack

**Target analysed:** `/Applications/SVP 4 Mac.app` (SVP 4 Mac 4.7.2.325, `com.svp-team.svpmanager`)
**Tooling used:** [`morluto/rea`](https://github.com/morluto/rea) v5.0.0 (MCP/CLI reverse-engineering tool)
**Test machine:** Mac14,6 — Apple M2 Max, 38-core GPU, 64 GB unified memory, macOS 27.0.1 (26A434), Xcode 27.1 / Swift 6.4
**Date:** 2026-10-08

---

## 1. Verdict

**Yes — a native Apple Silicon version is feasible, and the timing is unusually good.**

Three things make it feasible that did not exist when SVP 4 Mac was written:

1. **Apple ships a first-party frame-interpolation API.** `VTFrameProcessor` in VideoToolbox
   provides `VTFrameRateConversionConfiguration` (macOS 15.4+) and
   `VTLowLatencyFrameInterpolationConfiguration` (macOS 26+). These are exactly the
   capability SVP exists to provide, running on the Neural Engine and GPU. This was verified
   working on the target machine, not assumed.
2. **The open-source neural engine is already arm64 and MIT-licensed.** SVP ships
   `rife/libRIFE.dylib` as a universal binary alongside MIT-licensed RIFE model weights. RIFE is
   the realistic quality tier if `VTFrameProcessor` proves insufficient.
   *(Correction: earlier drafts of this report described `vapoursynth-mvtools` as SVP's
   motion-estimation engine and as an arm64 fallback. **MVTools is not in the SVP 4 Mac bundle at
   all** — SVP's Mac engine is its own `libsvpflow1/2`. MVTools belongs to SVP's Windows/AviSynth
   configurations, and it is GPL-2.0, which blocks App Store distribution. See
   [`WHY-NOT-RIFE.md`](WHY-NOT-RIFE.md).)*
3. **SVP's own engine is already arm64.** Binary analysis (Section 4) shows `libsvpflow1/2`,
   the RIFE engine, VapourSynth plugins, Qt 6.12, Python 3.11 and libmediainfo all ship as
   universal binaries. Only the GUI and the four optional extensions remain Intel-only.

**But there are two hard constraints you must design around:**

- **Legal.** SVP's licence states the software "must not be decompiled, disassembled, reverse
  engineered or otherwise modified." SVPflow itself is closed source. A clean-room
  reimplementation built on published algorithms, MIT/GPL upstreams, and Apple's public APIs is
  the legitimate path. Do not decompile SVP's binaries.
- **Not a port, a rebuild.** "Recreating a native Apple Silicon version" is not a matter of
  flipping a compile flag on SVP — the Intel-only pieces are the parts you would be replacing
  anyway. Treat this as a new product, not a port.

---

## 2. What `morluto/rea` is

REA is **"Reverse Engineer Anything"** — an MCP server plus CLI that gives an AI agent tooling to
inspect binaries, applications, and runtime behaviour, with every conclusion carrying its evidence.

| Property | Value |
| --- | --- |
| Language / runtime | TypeScript (ESM), Node.js ≥ 22.19 |
| Size | ~1,190 source files, 389 test files, 38 design docs |
| Distribution | `npx rea-agents setup`, npm package `rea-agents` |
| Licence | MIT |

**How it works.** The agent calls REA over MCP; REA inspects the target and returns findings with
provenance. Analysis runs locally. Results include the evidence *and* the stated limitations.

**Analysis providers**

| Target type | Engine required |
| --- | --- |
| Native binaries | Hopper, Ghidra, or IDA (external) |
| JavaScript / Electron | none — static |
| .NET assemblies | none — static |
| Apple `.app` / IPA / DMG | none — static, execution-free |
| Websites, network captures | Chrome-family browser / HAR |
| Android APK, firmware | JADX + JDK / Binwalk (Linux) |

REA's Apple-bundle projection is **execution-free**: it reports exact paths, content hashes,
detected formats, bundle anatomy, runtime-family hints, and path-based bridge hypotheses, without
running the target. That is what made it safe and appropriate to point at an installed commercial app.

---

## 3. What REA found in the app

REA was installed locally (v5.0.0, Node 22.22.2) and run against the bundle. Raw evidence is in
`analysis/rea/`.

### 3.1 `inspect-artifact` — complete bundle inventory

```
operation       inspect_artifact
subject         SVP 4 Mac.app
sha256          67bf6545bf5b54b2f3422b83862e137fbf5ba502e23db206407ae2a84a3a8764
nodes           3,387
occurrences     3,432
edges           3,404
coverage        complete-within-substeps (0 observations omitted)
limitations     "does not execute the artifact or claim format-specific semantics"
```

Every file in the bundle is inventoried with a SHA-256 digest. Output: 16 MB evidence bundle.

### 3.2 `project-apple-application-graph` — structural projection

```
platforms            [macos]
runtime_families     [javascript, native, swift-objective-c]
coverage             complete-within-inventory (inventory_complete: true)
```

| Component class | Count |
| --- | --- |
| Executables | 87 |
| Frameworks | 72 |
| Native libraries | 70 |
| JavaScript files | 10 |
| Bundle metadata | 11 |
| Signing | 11 |
| Bridge candidates | 870 |

### 3.3 `inspect-macho` — failed, and why that matters

```json
{ "code": "execution_failure", "provider_id": "native-macos",
  "operation": "inspect_macho", "retryable": false }
```

REA's `doctor` reports no analysis engine installed (Hopper absent, `GHIDRA_INSTALL_DIR` unset, no
IDA registration). Mach-O *parsing* therefore could not run through REA. The architecture work in
Section 4 was done directly with `lipo`/`otool`/`codesign`, which gave the same answers without a
decompiler — and without triggering the licence restriction on disassembly.

---

## 4. The architecture matrix — the central finding

All 87 Mach-O files in the bundle were inspected with `lipo -archs`. Full data:
`analysis/arch-matrix.tsv`.

| Slice composition | Count |
| --- | --- |
| Universal (`x86_64` + `arm64`) | 77 |
| `x86_64` only | **9** |
| `arm64` only | 1 |

### 4.1 The nine Intel-only files

These are the only things forcing Rosetta 2:

| Path | What it is |
| --- | --- |
| `Contents/MacOS/SVPManager` | The main Qt 6.12 GUI + orchestrator |
| `Contents/Frameworks/libQtWebApp.1.dylib` | Third-party Qt HTTP server (web UI / streaming) |
| `Contents/Resources/extensions/libsvplight.dylib` | SVPLight extension (ambient lighting) |
| `Contents/Resources/extensions/libsvpcode.dylib` | SVPcode extension (transcoding) |
| `Contents/Resources/extensions/libsvpcast.dylib` | SVPcast extension (streaming) |
| `Contents/Resources/extensions/libsvptube.dylib` | SVPtube extension (online video) |
| `Contents/Resources/extensions/tube/libmain.dylib` | SVPtube core |
| `Contents/Resources/extensions/code/mkvmerge` | MKVToolNix (third-party) |
| `Contents/Resources/utils/clinfo` | OpenCL info utility (third-party) |

### 4.2 Already arm64-native

| Path | What it is |
| --- | --- |
| `Resources/plugins/libsvpflow1.dylib` | **Motion-vector search engine** |
| `Resources/plugins/libsvpflow2.dylib` | **Frame synthesis / smooth-FPS engine** |
| `Resources/plugins/libvapoursynth_plugin.dylib.30` | VapourSynth host plugin |
| `Resources/plugins/libsvpcontrol_plugin.dylib.30` | Player control plugin |
| `Resources/rife/libRIFE.dylib` | **RIFE neural interpolation (ncnn + Vulkan)** |
| `Resources/rife/libmiscfilters.dylib` | RIFE support filters |
| `Frameworks/Qt*.framework` (9 frameworks) | Qt 6.12, all universal |
| `Contents/PlugIns/**` (11 plugins) | Qt platform/style/TLS/image plugins |
| `Frameworks/libpython3.11.dylib` + `libssl`, `libcrypto`, `libmediainfo` | Runtime dependencies |
| `Resources/utils/vulkaninfo`, `extensions/tube/deno` | Utilities |

### 4.3 Two details worth noting

**SVP already builds an arm64 SVPflow.** The universal `libsvpflow2.dylib` carries *different
install names per slice*:

```
architecture x86_64 : libsvpflow2.1.dylib
architecture arm64  : libsvpflow2_arm.1.dylib
```

That is the signature of a build system with a genuine arm64 target — `_arm` is a distinct
artifact, not a re-lip of the Intel build. Combined with SVP's own wiki statement that "SVP 4 Mac
is an Intel application, it fully supports native ARM video players," the picture is clear:
**SVP ships an ARM64 engine behind an Intel GUI.**

**The LoginItem is arm64-only.** `Contents/Library/LoginItems/SVPManagerLauncher.app` is the single
`arm64`-only binary in the bundle. It launches an Intel-only main app, so the launcher itself runs
natively and immediately hands off to Rosetta.

### 4.4 Engine dependencies (why the Intel path exists)

```
libsvpflow2.dylib   -> /System/Library/Frameworks/OpenCL.framework   (both slices)
libRIFE.dylib       -> x86_64 : /usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib
                       arm64  : /opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib (weak)
strings(libRIFE)    -> 1,859 "NCNN", 188 "vulkan", 17 "moltenvk"
```

- **SVPflow is OpenCL-accelerated.** OpenCL still works on Apple Silicon but is deprecated by
  Apple and is not the modern path.
- **RIFE runs ncnn on Vulkan via MoltenVK**, resolved through Homebrew paths — an ARM slice already
  points at `/opt/homebrew`. This is a portability liability: the app depends on the user's
  Homebrew prefix being present.

### 4.5 Signing

```
Authority      Developer ID Application: Konstantin Dondoshanskii (HQTHE56P9J)
Flags          0x10000 (runtime)   <- hardened runtime
Gatekeeper     accepted
Notarization   stapled and valid
```

Properly signed, hardened, and notarized — so the Intel path is a deliberate product decision, not
a packaging oversight.

---

## 5. How SVP actually works (the architecture you would be replacing)

```
SVPManager (Qt 6.12 GUI, x86_64)
  |  JSON IPC over a unix socket  (--input-ipc-server=/tmp/mpvsocket)
  v
mpv  (user-installed via Homebrew, native arm64)
  |  VapourSynth filter injection  (@svp:vapoursynth=...)
  v
VapourSynth  (user-installed via Homebrew, native arm64)
  |  plugin load
  v
libsvpflow1 / libsvpflow2   ->  OpenCL
libRIFE                     ->  ncnn + Vulkan/MoltenVK
```

Supporting machinery found in the binary:

- Embedded **Python 3.11** plus **PythonQt** for extension scripting (`script/base.py` generates the
  VapourSynth graph; `script/override.js` exposes ~100 tunables such as `analyse.block.w`,
  `levels.pel`, `smooth.mask.area_sharp`).
- **libQtWebApp** embedded HTTP server for the web UI and streaming endpoints.
- A component manager (`Resources/components.xml`) that installs and versions packages:
  `core.flow` (SVPflow), `opt.rife`, `ext.light/code/cast/tube`, `ext.tube.ydl` (yt-dlp).

**The key insight:** SVP Manager is a *configuration panel and process orchestrator*. The actual
signal processing happens inside VapourSynth, in a process SVP does not own. SVP's real intellectual
property is the SVPflow algorithm and the glue. Everything else is plumbing you would not want to
reproduce.

---

## 6. Legal position

| Component | Licence | Can you reuse it? |
| --- | --- | --- |
| SVP 4 Mac (Manager, SVPflow) | Proprietary — *"must not be decompiled, disassembled, reverse engineered or otherwise modified"* | **No.** Clean-room only. |
| RIFE (`hzwer`, `HolyWu`, `Asd-g`) | **MIT** | Yes — and it is already arm64 inside the bundle |
| `vapoursynth-mvtools` | **GPL-2.0** | Yes, but **not shippable on the Mac App Store**, and **not used by SVP 4 Mac** |
| VapourSynth | LGPL-2.1 | Yes, dynamic linking — but it is a whole scriptable framework, and SVP does not bundle it |
| FFmpeg / mpv | LGPL/GPL | Yes, per component |
| Apple `VTFrameProcessor` | Public API | Yes — and it ships with the OS |

**Practical conclusion:** you can legally build everything you need from open components and Apple
APIs. What you must not do is decompile SVPflow and reimplement it from its disassembly.

**But licence is not the same as viable.** Measured on this machine, RIFE runs at **0.47×
real-time** at 1080p and peaks at 42 fps aggregate against `VTFrameProcessor`'s 247 fps — a 5.9×
deficit — and it needs VapourSynth plus Vulkan/MoltenVK to run at all. RIFE is a *quality* option,
not a performance one. Full measurements and the reasoning: [`WHY-NOT-RIFE.md`](WHY-NOT-RIFE.md).

---

## 7. Measured performance — does real-time actually work?

A Swift harness was written to drive `VTFrameRateConversionConfiguration` directly and measure
throughput on the target M2 Max. Full method and raw samples:
`analysis/benchmarks/vtframe_throughput.md`.

Correctness was verified at pixel level — the destination buffer is written and differs from both
reference frames, so these are real interpolated results, not no-ops.

| Configuration | p50 latency | source fps | output fps (2x) | Real-time 24→48? |
| --- | --- | --- | --- | --- |
| 640×360 normal | 17.72 ms | 53.9 | 107.8 | **yes** |
| 1280×720 normal | 27.89 ms | 33.8 | 67.7 | **yes** |
| 1920×1080 normal | 27.21 ms | 34.8 | 69.7 | **yes** (~45% headroom) |
| 1920×1080 quality | 35.91 ms | 26.5 | 52.9 | yes, marginal |
| 3840×2160 normal | 70.78 ms | 13.4 | 26.8 | no (offline only) |

**Conclusions**

- **1080p real-time 24→48 fps is achievable today on M2 Max**, with meaningful headroom.
- **1080p "quality" mode is borderline** — it clears the 24 fps bar with little margin.
- **4K is not real-time**, but is entirely fine for offline conversion.
- These numbers include harness overhead (synthetic frame generation, a semaphore round trip, CPU
  pixel reads). A production pipeline feeding `processWithCommandBuffer:parameters:` from an
  existing Metal pipeline should do better.
- Latency is tight from p50 to p95 (+17%), so the pipeline is steady-state.

### 7.1 Two API findings that must shape the implementation

Both reproduced in isolation and documented in the benchmark notes.

**(a) The Swift `async` overlay does not wait for completion.**

```swift
try await processor.process(parameters: p)   // returns in 0.079 ms
                                             // destination buffer NEVER written
```

Even after a 300 ms delay the output buffer still held its pre-fill pattern. The
completion-handler form on identical inputs wrote correct interpolated output:

```swift
processor.process(parameters: p) { _, err in ... }   // works
```

*Rule: use `process(parameters:completionHandler:)` or `processWithCommandBuffer:parameters:`,
never the Swift `async` form.*

**(b) Buffer strategy affects stability.**

Allocating a distinct `CVPixelBuffer` per frame (~65+ IOSurfaces) crashed consistently around 85–90
calls. A recycled 6-buffer ring completed every run. Crashes were also seen at process teardown
*after* `endSession()` had returned successfully, with a non-deterministic trigger point.

*Rule: recycle a small fixed pool of IOSurface-backed buffers via `CVPixelBufferPool`. Never
allocate per frame. Treat teardown as a risk area.*

**(c) Session start-up is not cheap.** First-time model load for the quality path measured
**11.53 s** at 1080p; the low-latency configuration starts in 1.07 s. Apple explicitly warns that
low-latency model loading "may take longer than a frame time" and that `startSession` must not block
the UI thread. Start sessions asynchronously at launch.

---

## 8. Recommended stack

### 8.1 The core recommendation

Build a **native Swift/SwiftUI application** that uses **`VTFrameProcessor`** as the interpolation
engine, **VideoToolbox** for decode, and **Metal** for render — all inside one process, with no
external VapourSynth, no Homebrew dependency, and no Python.

```
┌──────────────────────────────────────────────────────────────┐
│  SwiftUI app shell  (Swift 6, macOS 15.4+/26+)               │
│  menu bar · settings · media library · HUD · AirPlay         │
└───────────────┬──────────────────────────────────────────────┘
                │
   ┌────────────┴─────────────┐
   │  Playback pipeline       │  Conversion pipeline
   │  (real-time)             │  (offline / batch)
   └────────────┬─────────────┘
                │
   ┌────────────▼─────────────┐
   │  Decode: VideoToolbox    │  AVAssetReader · VTDecompressionSession
   │  hardware decode, 8/10-bit, HDR metadata preserved
   └────────────┬─────────────┘
                │  CVPixelBuffer (IOSurface, Metal-compatible)
   ┌────────────▼─────────────┐
   │  Interpolate:            │
   │  VTFrameProcessor        │
   │   • VTLowLatencyFrame…   │  real-time, macOS 26+
   │   • VTFrameRateConversion│  offline, macOS 15.4+, to 8192×4320
   │   • VTOpticalFlow…       │  pre-computed flow for quality tier
   └────────────┬─────────────┘
                │  MTLCommandBuffer integration
   ┌────────────▼─────────────┐
   │  Render: Metal (MTKView) │  tone mapping · HDR · colour management
   └──────────────────────────┘
```

### 8.2 Component choices, with reasons

| Layer | Choice | Why this and not the alternative |
| --- | --- | --- |
| App shell | **Swift 6 + SwiftUI** | `VTFrameProcessor` integrates with Metal command buffers — that is only reachable from a native process. Qt would reproduce exactly the problem SVP has. |
| Real-time interpolation | **`VTLowLatencyFrameInterpolationConfiguration`** | Purpose-built for playback. Supports 1, 3, 7… interpolation phases (2ⁿ−1) so you can target 48/72/96 fps from one source rate. |
| Offline / conversion | **`VTFrameRateConversionConfiguration`** | Handles up to 8192×4320 on macOS. Has a `qualityPrioritization` knob and accepts pre-computed optical flow. |
| Optical flow | **`VTOpticalFlowConfiguration`** | Available, but **measured 14% slower end-to-end** than the on-the-fly flow inside the FRC path. Leave `usePrecomputedFlow: false`. See [`PLAYBACK-AND-BATCH.md`](PLAYBACK-AND-BATCH.md) §4a. |
| Decode | **VideoToolbox / AVFoundation** | Hardware decode, 10-bit and HDR passthrough. Use `AVAssetReader` for conversion, `VTDecompressionSession` for playback. |
| Render | **Metal (`MTKView`)** | Zero-copy from IOSurface. Also the path to adding motion blur, tone mapping and super-resolution later via the same `VTFrameProcessor` session. |
| Container / IO | **FFmpeg (`libav*`)** for exotic formats; AVFoundation for the common path | FFmpeg covers MKV/AVI/WebM that AVFoundation will not. |
| Optional "neural" tier | **RIFE converted to CoreML** | The RIFE weights are MIT-licensed and already arm64 inside SVP. Converting to CoreML puts them on the ANE/GPU without Vulkan, MoltenVK, VapourSynth or Homebrew paths. **Do not ship the ncnn+Vulkan build** — measured at 0.47× real-time at 1080p. See [`WHY-NOT-RIFE.md`](WHY-NOT-RIFE.md). |

### 8.3 Why not port SVP instead

| Option | Assessment |
| --- | --- |
| Ask SVP for an arm64 build | They already ship an arm64 engine. The Intel GUI is their choice. Not something you control. |
| Port SVP Manager to arm64 | You would be porting a closed-source Qt 6 GUI you are licence-barred from modifying. No. |
| Rebuild on VapourSynth + SVPflow | SVPflow is closed source and licence-protected. Also inherits the Homebrew/Vulkan dependency chain. |
| **Rebuild on `VTFrameProcessor`** | **First-party, supported, fast, no external dependencies, and measurably real-time at 1080p.** |

### 8.4 Minimum deployment target

| Target | Requires | Trade-off |
| --- | --- | --- |
| macOS 15.4 | `VTFrameRateConversionConfiguration`, `VTOpticalFlowConfiguration` | Wider install base; offline conversion only, no low-latency real-time API |
| **macOS 26** | adds `VTLowLatencyFrameInterpolationConfiguration` | **Recommended.** Unlocks real-time playback. |

Ship a macOS 26 build with the low-latency path, and a macOS 15.4 build that falls back to
`VTFrameRateConversionConfiguration` at reduced rates.

---

## 9. Risks and open questions

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Swift `async` `process()` silently does nothing | **High** — silent wrong output | Use the completion-handler API. Add a pixel-level correctness assertion in tests. |
| Teardown crash after `endSession()` | **High** — user-visible crash | Recycle buffers from a `CVPixelBufferPool`; consider isolating the frame processor in an XPC service or child process so a teardown fault cannot take down the UI. |
| Crash with many distinct IOSurfaces | **High** | Fixed small ring. Never allocate per frame. |
| 4K not real-time on M2 Max | Medium | Offline conversion for 4K; real-time up to 1080p. Re-measure on M4/M5. |
| 11.5 s first-time model load | Medium | Start sessions asynchronously at launch; show progress; cache warm state. |
| `.quality` mode margin at 1080p | Medium | Use **two requests in flight** (pipelining) rather than pre-computed optical flow — measured +35%, and pre-computed flow is 14% *slower*. |
| `VTFrameProcessor` is a young API | Medium | Version-gate; keep an optional RIFE/CoreML quality tier behind an engine protocol as the fallback. |
| HDR / 10-bit correctness | Medium | `VTFrameProcessor` supports 420v; verify 10-bit and HDR metadata handling end to end early. |
| SVP licence | — | Do not decompile. Build clean-room on open components. |

**Not yet verified:** 10-bit / HDR paths, audio sync and A/V drift over long playback, subtitle and
chapter handling, and behaviour on M-series chips other than M2 Max.

---

## 10. Suggested roadmap

| Phase | Goal | Exit criterion |
| --- | --- | --- |
| **0 — Spike** | Prove the playback pipeline end to end | A file plays at 2× with `VTLowLatencyFrameInterpolation`, correct A/V sync, no crash over a 30-minute run |
| **1 — MVP player** | Real-time 1080p 24→48 fps, native UI | Menu bar app, drag-and-drop, quality toggle, hardware decode |
| **2 — Quality tiers** | Add pipelined submission, motion blur, HDR | `.quality` mode real-time at 1080p |
| **3 — Converter** | Batch offline conversion to 60/120 fps | 4K offline conversion with hardware encode |
| **4 — Quality tier** | RIFE converted to CoreML behind the engine protocol | Same output contract, switchable engine, no Vulkan/MoltenVK |
| **5 — Ship** | Notarize, harden, distribute | Developer ID, hardened runtime, notarization |

Start with Phase 0. The two API findings in Section 7.1 mean the pipeline has real sharp edges, and
proving it holds up for 30 minutes of continuous playback is the single most valuable thing to learn
before writing UI.

---

## Appendix — artefacts in this project

| Path | Contents |
| --- | --- |
| `analysis/arch-matrix.tsv` | All 87 Mach-O binaries with their architecture slices |
| `analysis/rea/inspect-artifact.evidence.json` | REA evidence: full bundle inventory, 3,387 nodes, SHA-256 per file |
| `analysis/rea/apple-application-graph.json` | REA Apple application graph projection |
| `analysis/rea/inspect-macho.error.json` | REA Mach-O provider failure record |
| `analysis/benchmarks/vtframe_throughput.md` | Benchmark method, results, stability findings |
| `analysis/benchmarks/lat_*.txt` | Raw per-call latency samples |
| `analysis/probes/vt_lat.swift` | Working benchmark / latency probe (build with `swiftc -O`) |

### Reproducing the key measurements

```bash
# architecture matrix
cd "/Applications/SVP 4 Mac.app"
find . -type f -print0 | while IFS= read -r -d '' f; do
  a=$(lipo -archs "$f" 2>/dev/null) && [ -n "$a" ] && printf "%s\t%s\n" "${f#./}" "$a"
done

# performance
cd analysis/probes
swiftc -O -o vtl vt_lat.swift
./vtl 1920 1080 normal 80      # one "LAT <ms>" line per completed call
```
