# OpenRecord

OpenRecord is a native Apple Silicon macOS app for **screen capture plus a non-destructive editor**. It records a display or window at full resolution (cursor **not** baked into the pixels), plus microphone, system audio, cursor telemetry, optional keyboard shortcuts, and an optional webcam track. It can also import MP4/MOV/M4V recordings from an iPhone or other device without changing the original. After capture or import, it can transcribe recorded audio on device, suggest pause cuts and smart auto-zooms, edit through multiple non-destructive cuts, apply portable project templates, and export polished video, GIF, audio, or still-image deliverables.

Projects live as folders on disk. Point the library at Dropbox, Google Drive, or iCloud Drive and the desktop client syncs them. There is **no account, no API keys, no ffmpeg, and no Xcode**.

MIT licensed.

## Requirements

- **macOS 15 or later**
- **Apple Silicon** (`arm64`)
- **Command Line Tools only** (`xcode-select --install`). Full Xcode and `xcodebuild` are not used.

## Build and launch

From the repo root:

```bash
./scripts/run.sh
```

That debug-builds with SwiftPM, assembles **`dist/OpenRecord.app`**, codesigns it, and opens the bundle.

Do **not** run the raw SwiftPM binary (`.build/.../OpenRecord`). Screen Recording, Microphone, and Accessibility attach to the launching executable. Terminal would own those grants; the signed `.app` must be what you open.

Other useful commands:

```bash
swift build          # debug
swift test           # unit tests (CLT Testing.framework, not XCTest)
./scripts/package-app.sh   # release .app at dist/OpenRecord.app (does not open it)
swift run openrecord-cli --help   # local inspect/validate/export/batch automation
```

First package may create a local self-signed **OpenRecord Dev** identity in your login keychain so TCC grants survive rebuilds. Allow Keychain if macOS prompts. If cert import fails, the script falls back to ad-hoc signing (`codesign -s -`), which often **resets permissions on every rebuild**.

## Permissions (grant them to OpenRecord.app)

macOS will prompt; an agent cannot click these for you. Enable **OpenRecord** (the `.app`), **not Terminal**, in System Settings → Privacy & Security:

1. **Screen Recording** (system audio rides along with ScreenCaptureKit on recent macOS)
2. **Microphone**
3. **Accessibility** — required. Cursor path and clicks come from an event tap. Without this, recording will not start (auto-zoom would have nothing to work with).

The first-run screen has **Open Settings** / **Request Remaining**. After flipping a switch, return to the app (or click Recheck). If you rebuilt with ad-hoc signing, you may need to toggle the permissions off and on again.

## Record

- **⌃⌥⌘R** starts and stops from anywhere (also in the Recording menu and the menu-bar extra).
- **New Recording** from the library toolbar, File → New Recording…, or the menu-bar extra. Pick a **display** or **window**, then Record (3–2–1 countdown).
- **Import Movie** adds an MP4, MOV, or M4V—including a recording copied from an iPhone or external capture device—as an ordinary portable project. Desktop capture remains on its independent, hardened ScreenCaptureKit path.
- Pick **None**, **Tutorial**, **Portrait Demo**, or a local project template before recording. Template files contain presentation defaults only, never recorded media.
- **Record keyboard shortcuts** adds shortcut chords and navigation keys to a separate overlay track. Ordinary unmodified typing and all input while macOS Secure Input is active are omitted.
- Stop with **⌃⌥⌘R** or the Stop button. OpenRecord then writes the project and generates auto-zooms from cursor activity.

## Library folder

Default: **`~/Movies/OpenRecord/Projects`**.

Settings (folder button in the library) → **Choose Folder…** to use a Dropbox, Google Drive, or iCloud Drive directory. The app writes `.openrecord` bundles **directly in that folder** (no extra `Projects` subdirectory is added). The cloud client uploads them; OpenRecord never talks to those APIs.

Sidebar context menu → **Reveal in Finder**. An editor export can optionally be copied into the same library folder.

## Editor and export

Open a project from the sidebar.

- **Preview** follows the playhead zoom/crop using the same `ExportLayout` padding and crop mapping as export (not a full compositor).
- **Timeline**: playhead, trim/cut decisions, zoom and speed blocks, captions, annotations, cursor treatments, privacy regions, and vector drawings. Compatible items support multi-select, copy/paste, duplicate, snapping, split, nudge, and grouped undo.
- **Transcript**: on-device mic/system transcription, search, phrase navigation/range selection, caption generation, non-destructive text cuts, and locally analyzed pause suggestions.
- **Inspector**: smart zoom/cursor styling, captions and richer annotations, blur/pixelate privacy regions, pen/highlighter drawing, generic laptop/phone/browser frames, expanded webcam styling, keyboard overlays, and local audio normalization/compression/limiting/fades.

**Export Video…** (⌘E) renders the **in-memory** document — not a stale re-read from disk. Choose H.264 or HEVC in MP4, or ProRes 422 in MOV, at 720p, 1080p, 4K, or source-sized resolution. Output is Rec.709 and 60 fps if the source averages ≥ 45 fps, otherwise 30 fps. Speed regions remap every visual and telemetry track from output time to source time. Mic + system AAC are synchronized, retimed with pitch preservation, cleaned according to the non-destructive audio settings, and mixed to stereo 48 kHz when present.

The Export inspector also creates animated GIFs (up to 30 seconds), mixed-audio M4A files, and a PNG of the current playhead frame (⌘⇧E). In the library, check the projects you want, then use **Batch Export Selected**. Each queued job keeps its own codec/resolution preset, exposes progress and failure state, continues past failures, and can be retried without rerunning successful jobs.

### Project templates

Project templates capture canvas/aspect, cursor treatment, webcam treatment, caption and annotation defaults, device frame, keyboard overlay, and video export settings. Use **Project Templates → Save Current** in the editor to create a local `.openrecordtemplate`, then import/export that JSON file for portability. Applying a template copies concrete values into `project.json`; the project does not depend on the template file afterward, and source media, transcript, cuts, and timed content are preserved.

### Local automation CLI

The dependency-free SwiftPM executable operates directly on normal project bundles and never rewrites `meta.json` or `project.json` during inspection or export:

```bash
swift run openrecord-cli inspect Demo.openrecord --json
swift run openrecord-cli validate Demo.openrecord
swift run openrecord-cli export Demo.openrecord --output Demo.mp4 --codec h264 --resolution 1080p
swift run openrecord-cli batch ./Projects --output ./Exports --codec hevc
```

Batch discovery is deterministic and top-level only. It continues after a failed project and exits nonzero when any job fails.

The versioned schema overview is documented in [`docs/PROJECT_FORMAT_V7.md`](docs/PROJECT_FORMAT_V7.md), with migration policy in [`docs/V3_MIGRATION.md`](docs/V3_MIGRATION.md).

### Direct manipulation, parity, and recovery

When a webcam overlay is enabled, visible at the playhead, and selected in the preview, click-drag it to move it and use its resize handle to change its size. The inspector position and size controls update live as the pointer moves. Choose **Circle**, **Rounded rectangle**, or **Squircle**, then customize border color, corner radius, and shadow treatment. The preview updates immediately, keeps the overlay within the canvas, and preserves normalized placement as the canvas aspect ratio changes. A continuous move or resize gesture is one undo step.

Preview and export use the same normalized `WebcamOverlayLayout` geometry and timestamp mapping, and export renders the current in-memory document. Webcam position, size, shape, mirroring, and timing therefore carry through to the exported frame within the documented small pixel tolerance. The preview remains an interactive approximation rather than the full export compositor: codec/color conversion, frame rounding, antialiasing, and other final-encoding details can produce small pixel-level differences. Inspect the rendered file when exact final pixels matter.

The timeline clamps the playhead and trim handles to the recording duration. Trim keeps at least 0.1 seconds; zoom and speed ranges keep at least 0.12 seconds and cannot cross neighboring ranges; caption and annotation cues keep at least 0.05 seconds. Moving a range preserves its duration and clamps it at the start/end or against its neighbors. These rules also apply when dragging across a trim boundary or when the playhead is exactly at the first or last timestamp. Timeline moves/resizes, webcam gestures, and other continuous edits coalesce into meaningful history entries; use **Undo** (⌘Z) and **Redo** (⇧⌘Z) to reverse a complete gesture.

If capture is interrupted, OpenRecord keeps the usable display recording as the primary recovery criterion. When display media can be finalized, it opens a recovered `.openrecord` project with a warning and retains any healthy optional tracks; a missing or truncated webcam/audio track is reported rather than discarding the display session. Capture health and track timing are retained locally in `meta.json`. Free-space guardrails are conservative: OpenRecord warns at 2 GiB available, and at 512 MiB or below it stops early to preserve and recover the display recording. Those are safety floors, not recommended working space.

For long or 4K captures, the 2 GiB warning is only an emergency safety floor. As a conservative working-space recommendation (including headroom for the project and an export on the same volume), begin with at least:

| Capture | 30 minutes | 1 hour | 2 hours |
|---|---:|---:|---:|
| 1080p | 20 GiB | 40 GiB | 80 GiB |
| 4K | 50 GiB | 100 GiB | 200 GiB |

Actual use varies with frame rate, codec, audio, and scene complexity. Check free space before starting and leave additional room when recording to a nearly-full volume; OpenRecord warns at 2 GiB and stops early at 512 MiB or less to preserve a recoverable display recording.

### Copy Diagnostics and privacy

Use **Copy Diagnostics** in the editor toolbar, then paste the clipboard text into a support report. The report contains only local technical facts needed to troubleshoot: app version/build, macOS version and Apple Silicon architecture, project format version, capture-health warnings, track presence/durations/offsets, export settings, and the last local error category. It does not upload anything.

Diagnostics never include recorded pixels, audio, keyboard content, captions, annotation text, other project content, device identifiers, project names, or file-system paths. Review the copied text before sharing it.

## Project format

Each recording is a folder package:

```
<name>.openrecord/
  meta.json                 # capture target/timing/health and optional webcam device metadata
  project.json              # format v7: edits, transcript, visual stack, templates/defaults, and export settings
  recording/
    display.mp4             # H.264, cursor hidden in the pixels
    webcam.mp4              # optional H.264 face-camera track
    mic.m4a                 # microphone (may be absent)
    system.m4a              # system audio (may be absent)
    mouse.jsonl             # { t, x, y, cursorId, visible? } in points, ~90–120 Hz
    clicks.jsonl            # { t, button, down }
    keys.jsonl              # optional { t, key, modifiers, down } shortcut events
    target.jsonl            # optional timestamped target bounds for moving/resizing windows
    thumb.jpg               # representative library thumbnail
    cursors/                # sprite PNGs + hotspot in project.json
```

Coordinates are **points** (Quartz, origin top-left of the main display). Cursor samples may include `visible: false` while the pointer is outside the captured target. New window recordings use `target.jsonl` to map global cursor points through the window bounds at each timestamp; older projects fall back to `meta.json` bounds. Video pixels = points × backing `scale`. Export and preview use **timestamps**, not frame indexes (capture is often VFR).

Opening an older supported project is read-only until the first save, which migrates a
copy of every supported field to the current format-v7 schema. Projects with a newer
format version, or unknown top-level fields in the current format, are rejected
with an update-required error instead of risking silent data loss. Legacy pre-v7
files with unknown top-level fields may open read-only, but cannot be migrated
until those fields are supported. Unknown nested fields in an otherwise valid
current document are preserved across library saves; unknown enum values may
open with safe preview defaults but remain read-only so their raw values cannot
be overwritten. Project JSON saves use a same-directory temporary file and
atomic replacement.

`meta.json` may also contain capture timing offsets and health warnings. Display video is the timing origin; microphone, system-audio, and webcam offsets keep separately recorded tracks synchronized. If capture stops unexpectedly but the display video is usable, OpenRecord finalizes and opens the recovered project with a warning instead of discarding it. A manually supplied `recording/webcam.mp4` is also detected when the project is reopened.

## Out of scope

No cloud-required speech service, automatic sensitive-content detection, arbitrary animation curves, webcam background removal, live iPhone capture, hosted share links, collaboration accounts, advanced DAW/NLE tooling, or in-app OAuth yet. v3.2 supports the safer import-oriented iPhone/device workflow instead of coupling live device capture to desktop recording.
