# samples/ — drop your test clip here

Anything you put in this folder can be run through the A/B with one command. The
self-test clip (`test24.mp4`, 3 s of `testsrc2`) is here only to prove the harness
works; it is synthetic and tells you nothing about real quality.

## What to drop

A short clip from footage you would actually convert. Any container ffmpeg reads
(`.mp4`, `.mov`, `.mkv`, `.m4v`) is fine.

**Good test material**

| Property | Why it matters |
| --- | --- |
| **5–30 seconds** | Long enough to judge, short enough to iterate. A 30 s clip takes ~1 min per engine. |
| **The original file, not a re-encode** | Re-encoding destroys the fine detail that makes interpolation hard. A re-encoded clip flatters both engines and hides the difference. |
| **Real motion** — pans, camera movement, people or objects crossing frame | This is where interpolation artefacts live. |
| **Film rate** (23.976 / 24 fps) | Your actual use case, and the hardest case for RIFE (needs 59.8 calls/s, has 25.9). |
| **Mixed detail** — fine texture plus clean edges | Film grain and hard edges fail differently. |

**Poor test material**

- A static shot or a talking head against a wall — nothing moves, so nothing is interpolated.
- Something already at 60 fps — there is nothing to synthesise.
- A clip you have already run through SVP or another interpolator — the A/B would be measuring
  the previous tool's artefacts, not either engine's.

## How to run it

```bash
VENV=/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml
cd "/Users/Wasim/Documents/Projects/60FPSVideo"
$VENV/bin/python analysis/ab_test.py samples/YOURCLIP.mp4 --name yourclip
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--seconds 15` | Only use the first 15 s of the source. |
| `--stills 6` | Extract 6 matched still pairs at 1:1 instead of 4. |
| `--rife-scale 0.5` | Run RIFE at half resolution — the "preview mode" from `BUILD-DECISIONS.md` §14.2. Much faster, softer. |
| `--no-rife` | VTFrameProcessor only. |

## What comes out, in `out/`

| File | What it is |
| --- | --- |
| `<name>_VT.mp4` | 59.94 fps from Apple's engine |
| `<name>_RIFE.mp4` | 59.94 fps from CoreML RIFE 4.25 |
| `<name>_COMPARE.mp4` | **Stacked, labelled, same frames side by side. Start here.** |
| `<name>_SLOW.mp4` | The same stack at 1/4 speed, so motion artefacts are visible without frame-stepping. |
| `<name>_frames/` | Matched still pairs at 1:1 — the honest way to inspect pixel detail. |
| `<name>_report.txt` | Frame counts, timings, and the verification checks. |

## What the harness guarantees

Both engines receive **the same decoded frames** and **the same phase plan**, so any difference in
the output is the engines, not the harness. Three checks run automatically and are recorded in the
report:

1. Both engines produce the same number of output frames.
2. Passthrough frames are byte-identical to their source frame.
3. No zeroed chroma anywhere (a bug that bit once — see the NV12 note in
   `../analysis/probes/vt_render.swift`).

**Known limitation, stated plainly:** VTFrameProcessor interpolates in YUV; RIFE requires RGB
float32, so it pays a YUV→RGB→YUV round trip that ffmpeg measures at ~0.21 mean luma error. That
cost is inherent to RIFE's design and any real deployment pays it — but it means the RIFE side
starts with a small handicap that is not its own fault.
