# OpenRecord v2.5 Plan

A hardening and production-readiness release between the completed v2 roadmap and the larger v3 feature expansion.

v2.5 is intentionally not a feature grab bag. The goal is to make the existing capture, editor, webcam, timeline, and export systems dependable enough for daily use on long and messy real-world recordings before v3 adds another layer of capability.

---

## Goal

**v2.5 makes OpenRecord trustworthy.**

A user should be able to record for a long time, move and resize windows, use a webcam, edit aggressively, cancel/retry exports, reopen old projects, and export without wondering whether timing, preview parity, or project integrity will break.

The release should improve four things above all else:

1. **Capture reliability** — long recordings, device changes, interruptions, low disk, and recovery.
2. **Preview/export parity** — what the editor shows should closely match the rendered file.
3. **Direct manipulation** — especially webcam placement/shape/size, with live feedback and reliable undo.
4. **Performance and regression coverage** — benchmark the hot path, speed up export, and add tests for the failure-prone systems added throughout v2.

---

## Principles

The existing product principles continue to apply:

- Projects remain transparent `.openrecord` folders.
- No accounts, proprietary cloud, or required API keys.
- Source media stays non-destructive.
- Timestamp-based/VFR-safe behavior remains mandatory.
- Old projects must continue to open safely.
- Preview and export should share geometry/timing logic rather than reimplementing effects independently.

v2.5 adds one more rule:

> **Reliability beats novelty.** A new feature should not enter v2.5 unless it removes friction or hardens an existing v2 workflow.

---

## Release scope

### 1. Capture reliability and recovery

#### Long-session soak testing

Add repeatable tests and manual release checks for:

- 30-minute, 1-hour, and 2-hour recordings.
- Display and window capture.
- Microphone + system audio together.
- Optional webcam capture.
- Keyboard shortcut telemetry enabled and disabled.
- Window movement and resizing during capture.
- Variable frame-rate sources and frame pacing changes.

Record capture-health data in `meta.json` where useful so failures can be diagnosed without opaque logs.

#### Graceful failure cases

Handle these explicitly:

- Disk space approaching exhaustion.
- Display disconnect or sleep.
- Captured window closing during recording.
- Camera disconnect or camera becoming unavailable.
- Microphone device changes.
- Permission loss/revocation while the app is running.
- Writer failure on one optional track while display video remains recoverable.

The display recording remains the primary recovery criterion: if usable display media exists, OpenRecord should prefer finalizing a degraded project with warnings over discarding the session.

#### A/V/webcam sync hardening

The v2 webcam track is host-time aligned. v2.5 should verify and correct long-session drift rather than assuming initial alignment remains sufficient.

Tasks:

- Measure microphone, system-audio, display, and webcam drift over long captures.
- Add timestamp-offset diagnostics to capture health metadata.
- Apply a post-capture correction only when drift crosses a defined tolerance.
- Add regression fixtures for non-zero webcam/audio offsets.
- Keep every correction non-destructive; original media files remain unchanged.

**Acceptance:** after a one-hour reference capture, webcam and audio should remain perceptually synchronized with display video through the end of the recording.

---

## 2. Webcam direct-manipulation pass

Webcam capture and basic overlay rendering already exist. v2.5 turns the webcam overlay into a first-class editor object with interaction quality comparable to the zoom-anchor workflow.

### Required interaction model

When webcam overlay is enabled and visible at the playhead:

- Click the webcam output in the preview to select it.
- Drag anywhere on the selected webcam output to reposition it.
- Show a visible resize handle while selected.
- Drag the resize handle to change webcam size.
- Clamp the result to valid canvas bounds without jumps.
- Changes render **continuously while the pointer is moving**; do not wait for mouse-up to update the preview.
- Inspector position/size controls update live during direct manipulation.
- Inspector changes update the preview immediately.
- A single drag/resize gesture becomes a single undo step, not dozens of slider-like snapshots.

### Shape controls

Expose webcam shape as a direct editor setting with live preview:

- **Circle**
- **Rounded rectangle**

Changing shape must immediately update the preview at the current position and size and produce the same geometry during export.

The shape model should remain extensible so future v3 shapes do not require redesigning the document contract.

### Size and placement

- Keep normalized canvas-relative position and size in the document.
- Add a clear size control in the inspector.
- Preserve placement as canvas aspect ratio changes where possible.
- Keep the webcam fully visible by default.
- Add optional edge/center snapping during drag if it can be implemented without making movement feel sticky.
- Provide a reset/default-position action.

### Preview while moving

This is a release requirement, not a stretch item.

The selected webcam must use the in-memory edit state during drag and resize so users see the final composition as they move it. The preview should include the active shape, border, shadow, mirroring, crop/aspect-fill behavior, and current size.

### Preview/export parity

`WebcamOverlayLayout` remains the shared geometry authority. Do not create separate independent placement math for SwiftUI preview and export.

Add tests covering:

- Circle geometry.
- Rounded-rectangle geometry.
- Min/max size normalization.
- Bounds clamping.
- Aspect-ratio changes.
- Mirroring.
- Border width.
- Preview/export reference positions.
- Undo/redo after drag and resize.

**Acceptance:** a webcam overlay positioned, resized, and reshaped in preview should land in the same location and dimensions in an exported reference frame within a small pixel tolerance.

---

## 3. Preview/export parity hardening

The editor currently shares several layout and timing paths with export, but v2.5 should make parity measurable.

### Golden-frame regression suite

Create deterministic fixture projects and compare rendered reference frames for:

- Canvas background and gradients.
- Crop/zoom.
- Cursor + motion blur + click ripple.
- Keyboard overlay.
- Webcam overlay.
- Captions.
- Text annotations.
- Arrow annotations.
- Spotlight annotations.
- Speed-remapped timestamps.
- Representative combinations of multiple overlays.

Golden tests should tolerate only intentionally defined pixel differences.

### Timing parity

Add tests that evaluate the same source timestamp through preview-facing state and export mapping for:

- Trim boundaries.
- Speed-segment boundaries.
- Caption start/end.
- Annotation start/end.
- Keyboard fade timing.
- Webcam first-frame offset.
- Cursor interpolation.

---

## 4. Export performance

v2 shipped the needed export formats; v2.5 makes exporting faster and more predictable.

### Baseline first

Add a repeatable benchmark project and report:

- Source duration.
- Resolution and frame rate.
- Export codec/resolution.
- Total export time.
- Average frames/second.
- Peak memory where practical.

Reference target from the v2 roadmap remains:

> A 5-minute 1080p recording should export in under 3 minutes on an M2-class machine.

### Metal-backed compositor

Move the proven compositor hot path toward Metal-backed processing where profiling shows meaningful benefit.

Requirements:

- Preserve existing Core Image/output behavior where possible.
- Keep a safe fallback path until the Metal implementation is validated.
- Avoid loading an entire long recording into memory.
- Verify all current overlays and effects through golden tests before making Metal the default.

### Frame preparation

Investigate bounded parallelism for frame decode/preparation/composition.

- Use a small bounded pipeline instead of unbounded task fan-out.
- Keep frame ordering deterministic.
- Watch memory growth on 4K and long recordings.
- Cancellation must stop queued work promptly.

### Export UX

Add:

- Rolling frames/sec.
- Estimated time remaining once enough samples exist for a stable estimate.
- Clear cancellation state.
- Actionable errors rather than a generic export failure.

Background multi-project export remains optional for v2.5; do not let it delay compositor stability.

---

## 5. Editor and document hardening

### Undo/redo audit

Every non-destructive edit introduced in v2 should have intentional undo behavior:

- Trim.
- Zoom ranges and anchors.
- Canvas settings.
- Webcam move/resize/shape.
- Keyboard overlay settings.
- Speed segments.
- Captions.
- Annotations.
- Audio cleanup settings.
- Export settings where appropriate.

Continuous gestures and sliders should coalesce into meaningful history entries.

### Save integrity

- Write project JSON atomically.
- Never replace a valid project document with a partial write.
- Preserve unknown/newer fields when policy allows, otherwise reject newer unsupported schemas clearly.
- Add malformed/partial JSON recovery tests.
- Add round-trip fixtures for v1, v2, and v3-format projects.

### Timeline edge cases

Test and harden:

- Overlapping selections.
- Zero/near-zero duration ranges.
- Dragging across trim boundaries.
- Speed segments adjacent to one another.
- Deleting the selected item.
- Undo after move/resize.
- Playhead at exact start/end boundaries.

---

## 6. Test and CI expansion

The current suite is useful but v2.5 should add dedicated regression coverage for the systems most likely to break silently.

### Required test groups

- `WebcamOverlayTests`
- `SpeedMappingTests`
- `KeyboardOverlayTests`
- `CompositorGoldenTests`
- `CaptureRecoveryTests`
- `ProjectMigrationTests` or equivalent expanded migration fixtures
- Additional `ProjectDocumentRoundTripTests`

### Keyboard/privacy tests

Verify that:

- Normal unmodified typing remains excluded according to product policy.
- Shortcut/navigation events are represented correctly.
- Secure Input gaps do not expose typed content.
- Repeated key events do not create unusable overlay spam.

### CI

CI remains responsible for build, unit tests, and packaging. Add fixture/golden tests where they are deterministic in CI; keep hardware-dependent camera/screen permission checks as documented manual release gates.

---

## 7. Release diagnostics

OpenRecord should make failures diagnosable without collecting user data remotely.

Add a local **Copy Diagnostics** or equivalent workflow containing only non-sensitive technical information such as:

- App version/build.
- macOS version and architecture.
- Project format version.
- Capture-health warnings.
- Track presence/durations/offsets.
- Export settings.
- Last local error category.

Do not include recorded pixels, audio, keyboard content, captions, annotation text, file-system paths beyond what is necessary, or other project content by default.

---

## 8. Documentation and release checklist

Update README/release notes to make these behaviors clear:

- Webcam can be selected, moved, resized, and reshaped directly in preview.
- Webcam changes preview live while dragging.
- Preview/export parity guarantees and known limits.
- Recovery behavior for interrupted recordings.
- Recommended disk space for long/4K captures.
- Supported macOS/Apple Silicon baseline.

### Manual release matrix

Before v2.5.0:

| Area | Minimum checks |
|---|---|
| Display capture | 1080p + 4K, short + 1-hour |
| Window capture | move/resize window during recording |
| Audio | mic only, system only, both |
| Webcam | on/off, circle/rounded rectangle, move/resize, long sync |
| Speed | multiple adjacent regions including 0.25× and 4× |
| Captions | SRT + WebVTT import and edits |
| Export | H.264, HEVC, ProRes, GIF, M4A, PNG |
| Recovery | forced stop/interruption with usable display media |
| Migration | representative v1, v2, v3 projects |

---

## Explicitly out of scope for v2.5

These belong in v3 or later:

- Automatic speech-to-text.
- Transcript-based editing.
- Freehand drawing.
- Blur/redaction regions.
- Animated stickers.
- Device frames.
- iPhone capture.
- Multi-user collaboration.
- Shareable hosted links.
- Accounts/OAuth.
- Cloud AI dependencies.
- Major new annotation families.

---

## Suggested implementation order

```text
Phase 1  Benchmark + regression fixtures + save/migration audit
Phase 2  Webcam direct manipulation and live preview hardening
Phase 3  Capture soak tests, recovery paths, A/V/webcam drift diagnostics
Phase 4  Golden compositor/timing tests
Phase 5  Export hot-path optimization + ETA/cancellation polish
Phase 6  Timeline/undo edge cases + diagnostics + docs
Phase 7  Release-candidate soak matrix
```

The webcam pass comes early because it is a contained user-facing improvement that also exercises the exact architectural qualities v2.5 is meant to harden: live in-memory editing, undo coalescing, normalized geometry, and preview/export parity.

---

## Release gates

v2.5 is ready when all of the following are true:

1. No known data-loss bug in supported capture/edit flows.
2. One-hour reference recordings complete reliably with display + mic + system audio + webcam.
3. Webcam drag, resize, and shape changes preview continuously and undo correctly.
4. Exported webcam geometry matches preview within defined tolerance.
5. Golden compositor fixtures cover the major v2 overlay stack.
6. Speed/timing boundary tests pass deterministically.
7. Interrupted recordings recover when usable primary display media exists.
8. Export benchmark meets the v2 target or the remaining bottleneck is measured and documented.
9. v1/v2/v3 project fixtures open and round-trip according to migration policy.
10. CI build/test/package is green for the release commit.

---

## Summary

v2 proved the full product workflow. **v2.5 makes that workflow dependable.**

The release should leave OpenRecord with a hardened capture pipeline, measurable preview/export parity, a polished direct-manipulation webcam experience, stronger project recovery, faster and more transparent export, and enough regression coverage that v3 can expand the editor without destabilizing its foundation.
