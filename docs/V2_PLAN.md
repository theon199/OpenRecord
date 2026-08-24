# OpenRecord v2 Plan

A roadmap to close the gap with Screen Studio while staying true to what makes OpenRecord different: **local-first, no accounts, transparent `.openrecord` bundles, and cursor-outside-video architecture**.

---

## Vision

**v1** proves the core bet: record display pixels without a baked-in cursor, capture telemetry separately, auto-generate zooms, edit non-destructively, export a polished MP4 — all without Xcode, ffmpeg, or cloud APIs.

**v2** makes OpenRecord a daily driver for product demos, tutorials, and changelog videos. Users should choose OpenRecord over Screen Studio when they want ownership of their files, offline editing, and sync via their own cloud folder — without sacrificing the polish that makes Screen Studio feel magical.

### Principles (non-negotiable)

1. **Projects remain plain folders** — every feature must be representable in `project.json` + sidecar media under `recording/`.
2. **No accounts or proprietary cloud** — sharing happens via exported files or the user's existing sync folder (Dropbox, iCloud, Drive).
3. **Preview ≈ export** — new visual effects must render through the same `ExportLayout` + compositor path preview uses.
4. **Timestamp-based, VFR-safe** — all new tracks (keyboard, webcam, captions) use `{ t, … }` JSONL or time-ranged document fields, never frame indexes.
5. **Incremental format migration** — bump `formatVersion` with forward-compatible readers; never break v1 projects.

---

## Competitive gap analysis

| Capability | Screen Studio | OpenRecord v1 | v2 target |
|---|---|---|---|
| Auto-zoom on activity | ✓ | ✓ | Refine + user presets |
| Smooth cursor + click effects | ✓ | ✓ (spring + ripple) | Motion blur, hide/show |
| Canvas styling | ✓ | ✓ (solid bg, padding, radius) | Presets, gradients, aspect ratios |
| Keyboard overlay | ✓ | ✗ | ✓ |
| Webcam overlay | ✓ | ✗ | ✓ |
| Captions / subtitles | ✓ (AI) | ✗ | ✓ (import + optional on-device STT) |
| Annotations (arrows, text) | ✓ | ✗ | ✓ (basic) |
| Motion blur | ✓ | ✗ | ✓ |
| Speed control | ✓ | ✗ | ✓ |
| Audio cleanup | ✓ | ✗ | ✓ (basic) |
| Undo / redo | ✓ | ✗ | ✓ |
| Library thumbnails | ✓ | ✗ | ✓ |
| Export presets (4K, GIF) | ✓ | 1080p MP4 only | MP4 presets + GIF |
| Share links | ✓ (cloud) | ✗ (intentional) | Stay out of scope |
| iPhone frame capture | ✓ | ✗ | Defer to v2.1+ |
| Device frames (MacBook, etc.) | ✓ | ✗ | v2.1 |

---

## Release structure

v2 ships as **three milestones** so each release is shippable and testable on its own.

```
v2.0 — Editor maturity + keyboard overlay + presets
v2.1 — Webcam, motion blur, speed, audio cleanup
v2.2 — Captions, annotations, export expansion
```

### Current implementation status (August 2026)

**v2.0 is in progress.** The repository now includes CI, document-level undo/redo
for trim, zoom, and canvas edits, auto-zoom regeneration, export cancellation,
library deletion, and direct zoom-anchor dragging in the preview. Gradient
backgrounds and 16:9, 9:16, 1:1, and 4:3 aspect presets are now exposed in the
editor and render through the shared model/compositor path. Default, Dark,
Light, and Minimal canvas style presets are also available without changing a
project's aspect ratio or cursor scale. Library projects can now be renamed
safely, and representative JPEG thumbnails are generated on capture completion
and backfilled for existing recordings. Privacy-filtered keyboard shortcut
telemetry, a configurable pill overlay, preview/export rendering, and the
backward-compatible format-version-2 migration are now implemented as well.
Auto-zoom generation now has Subtle, Normal, and Aggressive sensitivity
presets, while the shared preview/export camera supports Fast, Smooth, and
Cinematic easing. Normal + Smooth preserve the prior default behavior.

**v2.1 is now in progress.** Velocity-based cursor motion blur is implemented
with a non-destructive canvas setting, a SwiftUI preview approximation, and a
directional Core Image export effect. New captures enable it by default while
legacy projects decode with it disabled, preserving their existing look.
Optional default-camera capture now writes a host-time-aligned
`recording/webcam.mp4`; the editor and exporter share circle/rounded-rectangle
placement, border, shadow, and mirroring behavior. The preview supports direct
dragging and handle-based resizing, and projects with a manually supplied
webcam track are detected on reopen.

Next: speed control and audio cleanup. v2.2 has not started.

---

## v2.0 — Foundation & polish

*Goal: Fix v1 rough edges and add the highest-impact Screen Studio feature (keyboard overlay) without touching capture hardware.*

### 0. Housekeeping (pre-v2)

- Remove or `#if DEBUG`-gate `AgentDebugLog` instrumentation.
- Add GitHub Actions CI: `swift build`, `swift test`, `./scripts/package-app.sh`.
- Remove hardcoded developer paths; audit TCC/signing docs.

### 1. Editor maturity

These are table stakes before adding flashy effects.

| Feature | Description | Implementation notes |
|---|---|---|
| **Undo / redo** | ⌘Z / ⇧⌘Z for trim, zoom, canvas, and (later) overlay edits | Snapshot history on `EditorSession`; coalesce debounced saves so undo snapshots don't fire every slider tick |
| **Regenerate auto-zooms** | Inspector button: "Regenerate from cursor activity" | Re-run `ZoomEngine.generateAutoZooms`; confirm dialog if existing zooms would be replaced |
| **Zoom anchor drag** | Click/drag focal point in preview when a zoom is selected | Writes to `ZoomRange.anchor`; reuse existing UV mapping |
| **Aspect ratio presets** | 16:9, 9:16, 1:1, 4:3 in inspector | Expose existing `CanvasSettings.aspectWidth/Height` |
| **Gradient backgrounds** | Inspector toggle: solid vs gradient | `CanvasBackground.linearGradient` already exists in model; wire inspector + preview/export |
| **Style presets** | Named presets: "Default", "Dark", "Light", "Minimal" | New `CanvasPreset` struct; stored in app, applied to `document.canvas` |
| **Export cancel** | Cancel button during export overlay | Wire `Task.cancel()` to export task; `Exporter` already calls `Task.checkCancellation()` |
| **Library: delete / rename** | Context menu + ⌫ delete with confirmation | FileManager ops via `ProjectLibrary`; refresh sidebar |
| **Library thumbnails** | First-frame or mid-recording JPEG in bundle | Generate on capture stop; store `recording/thumb.jpg`; cache in sidebar |

### 2. Keyboard overlay

Screen Studio's keyboard overlay is the single most requested feature for tutorial-style recordings.

**Capture**

- Extend `CursorMonitor` (Accessibility event tap) to log key events:
  - New file: `recording/keys.jsonl`
  - Schema: `{ "t": 1.234, "key": "⌘", "modifiers": ["command"], "down": true }`
  - Coalesce modifier chords; debounce repeats; respect Secure Input (skip or mark gaps)
- Optional: capture key *labels* not keycodes (map via `UCKeyTranslate` / Carbon)

**Document model** (`formatVersion: 2`)

```json
{
  "keyboardOverlay": {
    "enabled": true,
    "style": "pill",
    "position": "bottom-center",
    "fadeDelay": 0.8,
    "maxVisibleKeys": 3
  }
}
```

**Render**

- New `KeyboardOverlayRenderer` in compositor stack (after cursor, before export):
  - At time `t`, collect keys with `down: true` or within `fadeDelay` of last activity
  - Render styled key caps (SF Symbols + text) into CIImage
  - Positions: bottom-center (default), bottom-left, custom UV anchor
- Preview: SwiftUI overlay mirroring the same logic (shared `KeyboardOverlayState` computed from JSONL)

**Privacy**

- Keys typed in password fields / Secure Input windows: don't log content; optionally show `"••••"` or omit
- Document in README; user toggle: "Record keyboard shortcuts"

### 3. Auto-zoom improvements

| Improvement | Detail |
|---|---|
| **Sensitivity presets** | Subtle / Normal / Aggressive maps to `AutoZoomConfig` |
| **Manual override per zoom** | Inspector: "Follow cursor" vs "Fixed anchor" |
| **Zoom easing presets** | Fast / Smooth / Cinematic → `SpringConfig` variants |
| **Silence trimming suggestion** | Post-capture: "Remove pauses longer than 2s?" with preview of cuts |

Sensitivity and easing presets are persisted in `project.json`. Changing
sensitivity affects the next auto-zoom regeneration; changing easing updates
preview and export immediately through the same `ZoomEngine` path.

### 4. Project format v2 (minimal)

```json
{
  "formatVersion": 2,
  "keyboardOverlay": { ... },
  "stylePresetID": "default",
  "autoZoomSensitivity": "normal",
  "zoomEasing": "smooth"
}
```

- v1 reader: ignore unknown fields; default overlay disabled
- Migration: opening v1 project leaves `formatVersion: 1` until first save

---

## v2.1 — Motion, webcam, and audio

*Goal: Match Screen Studio's "cinematic feel" — motion blur, picture-in-picture, pacing control.*

### 5. Motion blur

Screen Studio blurs the cursor during fast movement.

**Approach**

- In `CursorSmoother`, velocity is already computed per sample
- Compositor: when `|velocity| > threshold`, apply directional `CIMotionBlur` to cursor sprite (or pre-blur N variants)
- Document: `canvas.cursorMotionBlur: { enabled: true, amount: 0.6 }`

**Preview parity**

- Approximate with SwiftUI `.blur(radius:)` scaled by velocity — good enough for scrubbing; export uses CI

Implemented: `CursorSmoother` exposes its spring-smoothed velocity, both render
paths use the same threshold/amount mapping, and the Canvas inspector provides
an enable toggle plus a 0–100% amount control.

### 6. Webcam overlay

**Capture**

- Optional second stream via `AVCaptureSession` (face camera) during recording
- Write `recording/webcam.mp4` (H.264, same timebase as display via `CACurrentMediaTime()` alignment)
- Store camera bounds preference in `meta.json`: `{ "webcam": { "deviceID": "...", "mirror": true } }`

**Document**

```json
{
  "webcamOverlay": {
    "enabled": true,
    "shape": "circle",
    "position": { "x": 0.85, "y": 0.85 },
    "size": 0.18,
    "borderWidth": 3,
    "shadow": true
  }
}
```

**Render**

- Composite webcam frame (time-aligned) into canvas UV space
- Shapes: circle, rounded rect; optional border ring
- Editor: drag to reposition in preview; resize handle

**Fallback**

- Allow importing a webcam video after the fact (`recording/webcam.mp4` dropped into bundle) for users who didn't enable it during capture

Implemented: webcam recording is opt-in and requests camera permission only
when selected. Camera samples buffer until the first complete display frame
sets the shared host-time origin; metadata stores the device ID, mirror flag,
and first-frame offset. Preview and export consume the same normalized overlay
settings, while missing webcam media remains a clean, disabled legacy case.

### 7. Speed control

**Document**

```json
{
  "speedSegments": [
    { "start": 0, "end": 5.0, "rate": 1.0 },
    { "start": 5.0, "end": 12.0, "rate": 2.0 }
  ]
}
```

**Behavior**

- Timeline shows speed regions (color-coded)
- Export: map output time → source time via piecewise rate integral
- Audio: `AVAudioTimePitchAlgorithm` or resample; optional "mute audio when sped up"
- Auto-zoom / keyboard / cursor telemetry: evaluate at **source** timestamps (pre-speed), then apply speed mapping for display

### 8. Audio cleanup

| Feature | Approach |
|---|---|
| **Mic noise gate** | `AVAudioEngine` offline pass or export-time `AVAudioMix` with simple gate |
| **Level normalization** | Peak or LUFS target on export |
| **Mic / system balance** | Inspector sliders: mic gain, system gain (stored in document) |
| **De-click** | Optional light click removal on mic track |

Keep processing **local and offline** — no cloud APIs. Document as export-time effects, not destructive rewrites of `mic.m4a`.

### 9. Export performance

Long recordings choke on the CPU frame loop today.

| Optimization | Priority |
|---|---|
| **Metal-backed compositor** | High — port `ExportCompositor` hot path to `MTLTexture` |
| **Parallel frame prep** | Medium — reader thread + compositor pool (watch memory) |
| **Export presets** | High — 720p / 1080p / 4K / source resolution |
| **Progress ETA** | Medium — frames/sec rolling average |
| **Background export** | Low — allow editing another project while exporting (queue) |

---

## v2.2 — Captions, annotations, and export expansion

*Goal: Tutorial and marketing workflows — text on screen, callouts, more output formats.*

### 10. Captions

**Phase A — Import**

- SRT / VTT import → `captions.jsonl` or structured array in `project.json`
- Render: styled subtitle bar (font, background pill, position)
- Editor: caption track on timeline; click to edit text and timing

**Phase B — On-device transcription (optional)**

- macOS 26+ `SpeechAnalyzer` / `SFSpeechRecognizer` on `mic.m4a` + `system.m4a` mix
- Run post-capture; write SRT into project bundle
- **No network, no API keys** — aligns with OpenRecord ethos
- Fallback: link to external tools (Whisper CLI) with import flow

### 11. Annotations

Start minimal — Screen Studio's full annotation suite is huge.

**v2.2 scope**

| Type | Timeline | Render |
|---|---|---|
| **Text callout** | `{ start, end, text, position, style }` | CI text + rounded bg |
| **Arrow / highlight** | `{ start, end, from, to, color }` | CI shape overlay |
| **Spotlight dim** | `{ start, end, rect, dimAmount }` | Dim outside rect |

**Editor**

- New "Annotations" track below zoom track
- Add at playhead; drag to move/resize in preview
- Undo/redo via same stack as v2.0

**Defer**: freehand drawing, blur regions, animated stickers

### 12. Export expansion

| Format | Notes |
|---|---|
| **GIF** | Short clips; palette optimization; max 30s warning |
| **ProRes / HEVC** | Power-user preset; larger files |
| **Separate audio** | Export `.m4a` sidecar |
| **Frame snapshot** | PNG at playhead (⌘⇧E) |
| **Batch export** | Select multiple projects in library → export queue |

### 13. Device frames (stretch)

- Static PNG frames: MacBook, iPhone 15 — screen content inset into bezel
- Document: `canvas.deviceFrame: { id: "macbook-14-2023", scale: 1.0 }`
- Low priority; nice for marketing clips

---

## Architecture changes

### Module layout (proposed)

```
Sources/OpenRecord/
  Capture/          # + WebcamCapture, KeyboardLogger
  Contracts/        # + KeyboardSample, Caption, Annotation, SpeedSegment
  Effects/          # + KeyboardOverlay, MotionBlur, SpeedMapper
  Export/           # + MetalCompositor (v2.1), GIFExporter (v2.2)
  Library/          # + ThumbnailGenerator, ProjectMigrator

Sources/OpenRecordApp/
  Editor/           # split EditorView, TimelineView, InspectorPanel
  Overlays/         # preview-only SwiftUI mirrors of compositor overlays
```

### Compositor pipeline (target)

```
source frame (display.mp4 @ t_source)
  → crop (ZoomEngine)
  → place on canvas (ExportLayout)
  → [speed remap already applied to t_source]
  → webcam layer
  → cursor + motion blur + click ripple
  → keyboard overlay
  → captions
  → annotations
  → pixel buffer
```

Each stage is a pure function of `(t, document, bundle assets)` for testability.

### Timeline model (multi-track)

```
┌─────────────────────────────────────────────────────┐
│ Trim bar                                            │
├─────────────────────────────────────────────────────┤
│ Zoom blocks                                         │
├─────────────────────────────────────────────────────┤
│ Speed segments (v2.1)                               │
├─────────────────────────────────────────────────────┤
│ Annotations (v2.2)                                  │
├─────────────────────────────────────────────────────┤
│ Captions (v2.2)                                     │
├─────────────────────────────────────────────────────┤
│ Playhead ▼                                          │
└─────────────────────────────────────────────────────┘
```

Shared hit-testing and drag infrastructure from existing zoom block code.

### Testing strategy

| Area | Tests to add |
|---|---|
| Keyboard overlay | JSONL parse; visible keys at time t; secure-field redaction |
| Speed mapping | source↔output time bijection; trim boundary edge cases |
| Format migration | v1 bundle opens in v2; round-trip v2 fields |
| Compositor golden | 1–3 fixture frames: hash PNG output for regression |
| Auto-zoom presets | Config presets produce expected segment counts |
| Undo | Trim/zoom/canvas snapshot restore |

---

## Explicitly out of scope for v2

Stay differentiated; don't rebuild Screen Studio's cloud business.

| Feature | Reason |
|---|---|
| **Shareable links / hosting** | Requires account infra; conflicts with local-first |
| **In-app OAuth** | Same |
| **Collaborative editing** | Project format is single-user |
| **iPhone as capture source** | Hardware + continuity complexity; defer |
| **AI script generation / TTS** | Scope creep; not core to recording |
| **Windows / Intel Mac** | Apple Silicon + ScreenCaptureKit is the wedge |
| **Real-time streaming** | Different product |

---

## Success metrics

| Metric | v2 target |
|---|---|
| Time to first export (new user) | < 5 min after permissions |
| Export time (5 min 1080p recording) | < 3 min on M2 (with Metal compositor) |
| Preview vs export visual diff | Imperceptible on reference fixtures |
| Crash-free sessions | > 99.5% |
| Test count | 3× v1 (core effects + migration + golden frames) |

---

## Suggested build order (single-threaded)

```
Week 1–2   Housekeeping, CI, undo/redo, library delete/thumbnails
Week 3–4   Keyboard capture + overlay render + inspector
Week 5     Auto-zoom presets, regenerate, anchor drag, style presets
Week 6–7   formatVersion 2 migration, gradient/aspect inspector
Week 8–9   Motion blur + export presets + cancel + performance baseline
Week 10–11 Webcam capture + overlay + reposition
Week 12    Speed segments + audio gain/normalize
Week 13–14 Captions import + render
Week 15–16 Annotations (text + arrow) + GIF export
Week 17    Polish, golden tests, README update, release candidate
```

Parallel workstreams (if multiple contributors): **Capture** (keyboard, webcam), **Compositor** (overlays, Metal), **Editor UI** (timeline tracks, undo), **Export** (speed, formats).

---

## Open questions

1. **Keyboard logging without Accessibility?** CGEvent tap already requires Accessibility; key logging uses the same tap — no new permission, but UX copy must mention it.
2. **Webcam A/V sync** — drift between ScreenCaptureKit and AVCaptureSession over long recordings; may need post-hoc alignment pass using cross-correlation on audio.
3. **On-device STT quality** — good enough for captions, or import-only for v2.2?
4. **GIF length limits** — cap at 30s / 50 MB to avoid accidental 500 MB exports?
5. **Intel / macOS 14 support** — expand TAM or stay Apple Silicon + macOS 15+ for velocity?

---

## Summary

OpenRecord v1 nailed the **hard technical foundation**. v2 wins on **polish and tutorial features** — keyboard overlay, webcam, motion blur, speed, captions, and a mature editor — while keeping projects as portable folders you own.

The moat isn't feature parity with Screen Studio's cloud platform; it's **better files, offline workflow, and zero lock-in** — with 80% of the visual polish that makes screen recordings feel professional.
