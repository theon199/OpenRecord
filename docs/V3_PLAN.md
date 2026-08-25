# OpenRecord v3 Plan

A roadmap for the next major product generation after v2.5 hardening.

v3 should expand what OpenRecord can create without abandoning the product's core identity: local-first files, offline editing, transparent project bundles, timestamp-safe tracks, and no required account or proprietary cloud.

---

## Vision

**v2 built a capable local screen-recording editor. v2.5 hardens it. v3 turns OpenRecord into a faster production tool.**

The goal is not to clone every Screen Studio or general-purpose NLE feature. v3 should focus on the highest-leverage workflows for product demos, tutorials, changelog videos, documentation, and lightweight marketing clips.

Users should spend less time manually cleaning recordings and more time making decisions about the story they want to tell.

---

## Product pillars

### 1. Smart editing, locally

Use on-device capabilities where they materially reduce repetitive work:

- Automatic transcription.
- Transcript-assisted editing.
- Silence/pause detection.
- Suggested cuts.
- Better automatic zoom decisions.
- Optional automatic caption generation.

No cloud API should be required for core workflows.

### 2. Better visual communication

Expand annotations and framing beyond the v2 basics:

- Blur/redaction regions.
- Freehand drawing.
- Device frames.
- Richer callouts.
- Additional webcam shapes and treatments.
- Cursor visibility and emphasis controls.

### 3. Faster assembly

Make repetitive editing operations dramatically faster:

- Multi-select.
- Copy/paste/duplicate.
- Alignment and snapping.
- Keyboard-driven editing.
- Reusable presets/templates.
- Better timeline navigation.

### 4. Preserve ownership

Projects remain normal portable bundles and must remain useful without OpenRecord cloud services.

---

## Proposed release structure

```text
v3.0 — Local transcription + smart cuts + editor productivity
v3.1 — Advanced visual annotations + device frames + webcam expansion
v3.2 — Templates, automation, capture expansion, and workflow polish
```

The exact grouping can shift based on implementation risk, but transcription and editing speed should land before lower-value decorative features.

---

# v3.0 — Smart editing and editor productivity

## 1. On-device transcription

Add automatic local speech-to-text for recorded audio.

### Sources

Allow transcription from:

- Microphone track.
- System audio track.
- Mixed microphone + system audio.

### Implementation direction

Prefer supported on-device Apple speech APIs on compatible macOS versions. Keep the architecture provider-neutral enough that an optional local Whisper-based path could be added later without changing the project model.

### Output

Store structured transcript segments with timestamps and optional confidence metadata.

Example:

```json
{
  "transcript": [
    {
      "start": 12.42,
      "end": 14.88,
      "text": "Let's open the settings panel.",
      "speaker": "mic"
    }
  ]
}
```

Transcript data belongs in `project.json` or a documented sidecar if scale makes that preferable. It must remain editable and non-destructive.

### Caption generation

Provide:

- Generate captions from transcript.
- Re-run generation without overwriting manually edited captions unless confirmed.
- Sensible phrase segmentation.
- Local-only processing by default.

---

## 2. Transcript-assisted editing

The transcript should be useful beyond captions.

### Transcript panel

- Search spoken text.
- Click a phrase to move the playhead.
- Select a phrase to select the corresponding timeline range.
- Show deleted/trimmed text distinctly.

### Text-based cuts

Support removing a transcript selection from the active edit while keeping source media untouched.

This should map to explicit non-destructive cut ranges rather than destructive media rewriting.

### Constraints

- Editing must stay timestamp-based.
- Transcript edits must not silently rewrite the transcript into inaccurate text.
- Users must be able to manually correct recognition mistakes independently of cut decisions.

---

## 3. Smart silence and pause removal

Promote the deferred v2 pause-removal idea into a proper workflow.

### Detection

Analyze audio locally for candidate pauses based on:

- Duration threshold.
- Signal level.
- Optional speech transcript gaps.

### Workflow

Do not instantly delete pauses.

Instead:

1. Analyze recording.
2. Present suggested cut regions.
3. Let the user preview the result.
4. Allow adjusting minimum pause length and retained breathing room.
5. Apply accepted cuts non-destructively.

### Modes

Suggested presets:

- **Natural** — remove only long dead air.
- **Tight** — tutorial pacing.
- **Fast** — aggressive changelog/demo pacing.

---

## 4. Improved auto-zoom intelligence

Move beyond sensitivity-only generation.

Possible signals:

- Clicks.
- Cursor dwell.
- Pointer velocity.
- Target-window movement.
- Repeated interactions in the same region.
- UI activity clusters.
- Transcript/speech timing where useful.

### Improvements

- Better suppression of useless micro-zooms.
- Prevent repeated zoom oscillation between nearby targets.
- Optional minimum hold time.
- Manual per-zoom `Follow cursor` vs `Fixed anchor` control.
- Cursor-aware framing that avoids placing the pointer directly on canvas edges.
- Regeneration should preserve explicitly locked/manual zooms when requested.

---

## 5. Cursor visibility and emphasis controls

Complete the cursor-control gap left from the original v2 competitive target.

Add timeline-capable controls for:

- Hide cursor.
- Show cursor.
- Cursor scale.
- Click emphasis.
- Optional temporary highlight/halo.

A user should be able to hide the cursor during sections where it distracts from the content without modifying the underlying display video.

---

## 6. Multi-cut editing model

Trim-only editing is not enough once transcript cuts and silence removal exist.

Introduce a non-destructive edit-decision model representing included/excluded source ranges.

Requirements:

- Multiple cuts.
- Ripple-like output timing while preserving source timestamps internally.
- Speed segments continue to work with cuts.
- Cursor, zoom, webcam, keyboard, captions, transcript, and annotations remain synchronized.
- Export uses one authoritative output-time → source-time mapping.

This is a major architectural change and should be designed before transcript-based deletion ships.

---

## 7. Editor productivity

### Multi-select

Support selecting multiple compatible timeline items for:

- Move.
- Delete.
- Duplicate.
- Common property edits where safe.

### Copy/paste and duplicate

Support annotations, captions, zooms, and selected ranges where semantically valid.

### Snapping

Snap editing operations to:

- Playhead.
- Trim/cut edges.
- Caption boundaries.
- Annotation boundaries.
- Other selected item edges.

Provide a modifier to temporarily disable snapping.

### Keyboard editing

Add discoverable shortcuts for frequent operations:

- Split/cut at playhead.
- Delete range.
- Duplicate.
- Nudge item left/right.
- Jump between edit points.
- Zoom timeline in/out.
- Select next/previous timeline item.

---

## 8. Presets and reusable styles

Expand beyond canvas presets.

Add reusable local presets for:

- Caption styling.
- Webcam treatment.
- Annotation styling.
- Cursor treatment.
- Export settings.
- Full visual theme where appropriate.

Presets should be stored locally in a documented format and remain optional project metadata when portability matters.

---

# v3.1 — Advanced visual communication

## 9. Blur and redaction regions

Add timed rectangular blur/pixelation overlays.

Use cases:

- Email addresses.
- API keys.
- Personal information.
- Internal URLs.
- Notifications.

### Required behavior

- Add at playhead.
- Drag/resize directly in preview.
- Set start/end on timeline.
- Blur or pixelate mode.
- Adjustable strength.
- Matching preview/export rendering.

Do not attempt automatic sensitive-content detection in the initial implementation.

---

## 10. Freehand drawing

Add basic timed drawing annotations for tutorial emphasis.

Initial scope:

- Pen/highlighter.
- Color.
- Width.
- Start/end timing.
- Erase whole stroke or selected stroke.

Store vector points rather than baked raster media so drawings remain scalable and editable.

---

## 11. Richer annotations

Expand the current text/arrow/spotlight system with a small coherent set rather than dozens of gimmicks.

Candidates:

- Box/outline.
- Underline.
- Numbered step marker.
- Label with leader line.
- Simple animated entrance/exit.

Animation should be deterministic and shared between preview/export.

---

## 12. Device frames

Add device-frame presentation for product/marketing clips.

### Initial frames

- MacBook-style laptop frame.
- iPhone-style phone frame.
- Generic browser/window frame.

Avoid trademark-heavy pixel-perfect replicas where licensing or branding becomes a problem; use tasteful generic built-in assets when needed.

### Model

```json
{
  "deviceFrame": {
    "id": "generic-laptop-dark",
    "scale": 1.0,
    "shadow": true
  }
}
```

### Requirements

- Preview/export parity.
- Aspect-aware screen inset.
- Works with existing canvas backgrounds and aspect presets.
- User can turn it off without changing source media.

---

## 13. Webcam expansion

v2.5 should already make webcam placement/resize/shape interaction solid. v3 can add expressive options on top of that reliable foundation.

Potential additions:

- Additional rounded/squircle shapes.
- Adjustable corner radius for rectangular webcam.
- Custom border color/width.
- Shadow controls.
- Background removal where a reliable on-device API is available.
- Simple webcam entrance/exit timing.
- Optional keyframed position/size for moving the webcam during a clip.

### Keyframed webcam motion

If implemented, keep it small and understandable:

- Add a webcam keyframe at playhead.
- Store position + size + shape-related properties at timestamp.
- Interpolate position/size between keyframes.
- Preview continuously while dragging a keyed state.
- Export must use the same interpolation function.

Do not ship arbitrary animation curves until the basic keyframe UX is proven.

---

## 14. Advanced audio polish

Improve local audio processing without pretending to be a full DAW.

Potential scope:

- Better loudness normalization targeting LUFS.
- Compressor/limiter preset for spoken voice.
- Stronger de-noise if available through dependable local APIs.
- Optional ducking of system audio under microphone speech.
- Fade-in/fade-out handles.

All effects remain non-destructive and render-time or cached-derivative operations.

---

# v3.2 — Workflow expansion

## 15. Project templates

Allow users to start from reusable local templates containing:

- Canvas style.
- Aspect ratio.
- Cursor settings.
- Webcam style.
- Caption style.
- Export preset.
- Optional default annotation styling.

Templates should not contain recorded media.

---

## 16. Batch workflow improvements

Expand the existing library batch export:

- Queue selected projects instead of only the whole library.
- Reorder queue.
- Per-job status.
- Continue after a failed job.
- Retry failed export.
- Different export preset per job where practical.

Background export belongs here if v2.5 does not safely land it.

---

## 17. Capture expansion

### iPhone capture

Investigate iPhone/iOS-device capture only after the core desktop workflow is stable.

Potential directions:

- Connected-device capture through supported macOS frameworks.
- Import-oriented workflow if live capture is too brittle.

Do not compromise normal screen recording reliability to support it.

### Multi-source capture

Longer-term investigation:

- Display/window + webcam + external device.
- Clearly defined timebase ownership.
- Recovery when a secondary source disappears.

---

## 18. Lightweight automation

Support local automation without turning OpenRecord into a cloud platform.

Candidates:

- CLI export command for `.openrecord` bundles.
- CLI project inspection/validation.
- Folder-based batch export.
- Documented JSON schema/version information.

This would make OpenRecord useful in changelog/release pipelines while preserving file ownership.

---

## 19. Optional plugin/export extension architecture

Only pursue this if repeated real-world needs justify it.

A narrowly scoped extension system could eventually support:

- Custom exporters.
- Local processing steps.
- Custom annotation renderers.

Constraints:

- Must not make ordinary project opening dependent on third-party plugins.
- Unknown plugin data must fail safely.
- Core projects should remain inspectable without executing arbitrary plugin code.

This is exploratory, not a v3.0 requirement.

---

# Architecture direction

## Unified time mapping

v3's most important architectural requirement is a single source of truth for output-time mapping once multi-cut editing exists.

Conceptually:

```text
output time
  → edit decision / included source range
  → speed mapping
  → source timestamp
  → display/webcam/audio/telemetry lookup
  → compositing
```

All overlays and tracks must resolve against the same mapping.

---

## Track model

The timeline should evolve toward reusable track/item infrastructure rather than separate custom code for every feature.

Likely timed item families:

- Cuts/edit decisions.
- Zooms.
- Speed regions.
- Webcam keyframes or visibility ranges.
- Cursor visibility ranges.
- Captions.
- Transcript segments.
- Annotations.
- Blur/redaction.
- Drawings.

Shared operations should include selection, move, resize, snapping, delete, copy, duplicate, and undo grouping.

---

## Rendering model

Maintain the v2 principle that each visual stage is deterministic from project state and timestamp.

Possible pipeline:

```text
source display @ t_source
  → crop/zoom
  → canvas/device frame
  → webcam
  → cursor/click effects
  → keyboard overlay
  → captions
  → annotations/drawing/redaction
  → output pixel buffer
```

Smart editing determines **which source timestamp** is rendered; it should not create a parallel rendering architecture.

---

# Testing strategy

v3 features should not repeat the pattern of adding broad functionality first and hardening later.

Every major v3 feature should ship with its regression contract.

Required categories:

- Transcript parser/storage round-trip.
- Speech-result timestamp normalization.
- Multi-cut source/output time mapping.
- Silence detection fixtures.
- Auto-zoom decision fixtures.
- Cursor visibility timing.
- Blur/redaction golden frames.
- Drawing vector serialization/rendering.
- Device-frame layout fixtures.
- Webcam keyframe interpolation if implemented.
- Template migration/portability.

Golden compositor coverage established in v2.5 should be extended, not replaced.

---

# Migration strategy

v3 will likely require another project format bump because multi-cut editing and transcript data change the document significantly.

Rules:

1. Older projects open with behavior matching their previous output.
2. New fields receive safe defaults.
3. Opening an old project should not eagerly rewrite it unless necessary.
4. Newer unsupported project versions are rejected clearly rather than partially decoded and re-saved.
5. Migration tests use real fixture bundles from v1, v2, v2.5, and v3.

---

# Explicitly not a v3 priority

Even in v3, OpenRecord should avoid diluting its advantage with infrastructure-heavy features that do not improve local creation.

Low priority/out of scope unless strategy changes:

- Proprietary hosted share links.
- Required accounts.
- Collaborative cloud timeline editing.
- Cloud-only AI generation.
- Real-time streaming.
- Full professional NLE feature parity.
- Windows port before the macOS product is mature.

---

# Suggested build order

```text
1. Design unified multi-cut/output-time mapping
2. On-device transcription storage + transcript panel
3. Silence suggestions + transcript-assisted cuts
4. Editor multi-select/copy/paste/snapping/shortcuts
5. Auto-zoom intelligence + cursor visibility ranges
6. Blur/redaction regions
7. Freehand/richer annotations
8. Device frames
9. Webcam expansion/keyframes if justified
10. Advanced local audio polish
11. Templates + improved batch queue
12. Capture/CLI/automation expansion
```

Do not begin complex v3 visual features until the multi-cut timing model is correct and covered by tests.

---

# Success criteria

v3 succeeds if:

- A typical tutorial can be turned into a polished edit substantially faster than in v2.
- Automatic transcription and pause suggestions work without requiring an account or network service.
- Users can perform multiple cuts without track desynchronization.
- Direct-manipulation editing remains responsive and undo-safe.
- Preview and export continue to match despite the larger overlay stack.
- Existing project files remain portable and understandable.
- New visual features improve communication rather than merely increasing feature count.

---

## Summary

v3 should make OpenRecord **faster to edit, smarter locally, and more expressive visually**.

The critical sequence is deliberate: harden in v2.5, establish multi-cut timing, add local transcription and smart editing, then expand visual tooling and workflow automation. That keeps OpenRecord differentiated by ownership and simplicity while moving it from a polished recorder toward a genuinely fast production environment for screen-based video.
