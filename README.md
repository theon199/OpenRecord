# OpenRecord

OpenRecord is a native Apple Silicon macOS app for **screen capture plus a non-destructive editor**. It records a display or window at full resolution (cursor **not** baked into the pixels), plus microphone, system audio, cursor telemetry, optional keyboard shortcuts, and an optional webcam track. After you stop, it generates Screen Studio–style auto-zooms from clicks and cursor activity, lets you trim, restyle, and retime the recording, adds captions, callouts, cursor motion blur, and a movable picture-in-picture overlay, cleans up audio locally, and exports polished video, GIF, audio, or still-image deliverables.

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
- **Record keyboard shortcuts** adds shortcut chords and navigation keys to a separate overlay track. Ordinary unmodified typing and all input while macOS Secure Input is active are omitted.
- Stop with **⌃⌥⌘R** or the Stop button. OpenRecord then writes the project and generates auto-zooms from cursor activity.

## Library folder

Default: **`~/Movies/OpenRecord/Projects`**.

Settings (folder button in the library) → **Choose Folder…** to use a Dropbox, Google Drive, or iCloud Drive directory. The app writes `.openrecord` bundles **directly in that folder** (no extra `Projects` subdirectory is added). The cloud client uploads them; OpenRecord never talks to those APIs.

Sidebar context menu → **Reveal in Finder**. An editor export can optionally be copied into the same library folder.

## Editor and export

Open a project from the sidebar.

- **Preview** follows the playhead zoom/crop using the same `ExportLayout` padding and crop mapping as export (not a full compositor).
- **Timeline**: playhead, trim handles, zoom blocks, color-coded 0.25×–4× speed regions, caption cues, and annotation ranges. Drag a block or either edge to move or resize it. Space plays/pauses; Delete removes the selected timeline item.
- **Inspector**: zoom amount, auto-zoom sensitivity, camera easing, canvas/cursor styling, webcam and keyboard overlays, speed controls, captions, text/arrow/spotlight annotations, microphone normalization/noise gate/de-click, microphone/system balance, and export.

**Export Video…** (⌘E) renders the **in-memory** document — not a stale re-read from disk. Choose H.264 or HEVC in MP4, or ProRes 422 in MOV, at 720p, 1080p, 4K, or source-sized resolution. Output is Rec.709 and 60 fps if the source averages ≥ 45 fps, otherwise 30 fps. Speed regions remap every visual and telemetry track from output time to source time. Mic + system AAC are synchronized, retimed with pitch preservation, cleaned according to the non-destructive audio settings, and mixed to stereo 48 kHz when present.

The Export inspector also creates animated GIFs (up to 30 seconds), mixed-audio M4A files, and a PNG of the current playhead frame (⌘⇧E). **Batch Export** in the library exports every project in the current library as H.264 MP4.

## Project format

Each recording is a folder package:

```
<name>.openrecord/
  meta.json                 # capture target/timing/health and optional webcam device metadata
  project.json              # v3: edits, captions, annotations, overlays, and export settings
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

Opening a v1 or v2 project is read-only until the first save, which migrates a
copy of every supported field to the current v3 schema. Projects with a newer
format version, or unknown top-level fields in the current format, are rejected
with an update-required error instead of risking silent data loss. Legacy v1/v2
files with unknown top-level fields may open read-only, but cannot be migrated
until those fields are supported. Unknown nested fields in an otherwise valid
current document are preserved across library saves; unknown enum values may
open with safe preview defaults but remain read-only so their raw values cannot
be overwritten. Project JSON saves use a same-directory temporary file and
atomic replacement.

`meta.json` may also contain capture timing offsets and health warnings. Display video is the timing origin; microphone, system-audio, and webcam offsets keep separately recorded tracks synchronized. If capture stops unexpectedly but the display video is usable, OpenRecord finalizes and opens the recovered project with a warning instead of discarding it. A manually supplied `recording/webcam.mp4` is also detected when the project is reopened.

## Out of scope

No automatic speech-to-text, freehand drawing, blur regions, animated stickers, device frames, iPhone capture, shareable links, advanced voice isolation, or in-app OAuth yet.
