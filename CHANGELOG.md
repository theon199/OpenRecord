# Changelog

## Unreleased — v2.5 hardening (Phases 1–8)

Implementation Phases 1–8 are complete. v2.5 remains unreleased until the
hardware and manual release gates in
[`docs/V2_5_RELEASE_CHECKLIST.md`](docs/V2_5_RELEASE_CHECKLIST.md) have been
run and their evidence recorded.

### Improved

- Expanded regression and CI coverage for webcam geometry, speed mapping, keyboard privacy, compositor golden frames, capture recovery, project migration, and document round trips.
- Webcam direct manipulation now supports live move/resize/shape editing with coalesced undo, while shared geometry and timing paths keep preview and export aligned within the defined pixel tolerance.
- Capture interruption and low-disk paths preserve usable display media, recover degraded projects with warnings, and retain local track-health and synchronization diagnostics.
- Export hot-path work adds bounded frame preparation, progress/ETA and cancellation behavior, with performance measurements for long and high-resolution recordings.
- Timeline edge cases are clamped to valid durations and neighboring ranges; move/resize gestures and other continuous edits form intentional undo/redo entries.
- Local **Copy Diagnostics** is privacy-safe by default: it contains technical metadata only and excludes recorded media, keyboard content, captions, annotation text, and project content.

## 2.2.0 — 2026-08-24

OpenRecord v2.2 completes the v2 roadmap for tutorial and marketing workflows.

### Added

- Import and edit SRT or WebVTT captions with per-cue timing and styling.
- Timed text callouts, arrows, and spotlight annotations with preview and export parity.
- 720p, 1080p, 4K, and source-sized video export presets.
- H.264, HEVC, and ProRes 422 video export.
- Animated GIF, mixed-audio M4A, and playhead PNG snapshot export.
- Project format version 3 for caption, annotation, and export settings, with read-compatible defaults for older projects.

### Existing v2 highlights

- Canvas presets, gradients, aspect ratios, undo/redo, thumbnails, keyboard overlays, and refined auto-zoom controls.
- Webcam capture and picture-in-picture editing, cursor motion blur, speed regions, and local non-destructive audio cleanup.
