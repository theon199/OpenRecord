# OpenRecord

OpenRecord is a native Apple Silicon macOS app for **screen capture plus a non-destructive editor**. It records a display or window at full resolution (cursor **not** baked into the pixels), plus microphone, system audio, cursor telemetry, and optional keyboard shortcuts. After you stop, it generates Screen Studio–style auto-zooms from clicks and cursor activity, lets you trim and restyle the canvas, adds velocity-based cursor motion blur, and exports an H.264 MP4.

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

Sidebar context menu → **Reveal in Finder**. Export can optionally copy the MP4 into the same library folder.

## Editor and export

Open a project from the sidebar.

- **Preview** follows the playhead zoom/crop using the same `ExportLayout` padding and crop mapping as export (not a full compositor).
- **Timeline**: playhead, trim in/out handles, zoom blocks (drag to move/resize). Space play/pause, Delete removes the selected zoom.
- **Inspector**: zoom amount, auto-zoom sensitivity (Subtle / Normal / Aggressive), camera easing (Fast / Smooth / Cinematic), background, padding, corner radius, cursor scale and motion blur, keyboard overlay controls, export.

**Export…** (⌘E) renders the **in-memory** document (current trims, zoom ranges, canvas) — not a stale re-read from disk. Output is H.264 High, Rec.709, **1080p-capped** (long edge ≤ 1920, short ≤ 1080), 60 fps if the source averages ≥ 45 fps else 30. Mic + system AAC are mixed to one stereo 48 kHz track when those files exist.

## Project format

Each recording is a folder package:

```
<name>.openrecord/
  meta.json                 # createdAt, app version, display bounds, scale, capture target
  project.json              # v2: trims, zooms, auto-zoom/easing presets, canvas + cursor effects, sprites, keyboard overlay
  recording/
    display.mp4             # H.264, cursor hidden in the pixels
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

`meta.json` may also contain capture timing offsets and health warnings. Video is the timing origin; microphone and system-audio offsets keep separately recorded tracks synchronized. If capture stops unexpectedly but the display video is usable, OpenRecord finalizes and opens the recovered project with a warning instead of discarding it.

## Out of scope

No webcam, captions, motion blur, annotations, GIF, iPhone, shareable links, noise reduction, or in-app OAuth.
