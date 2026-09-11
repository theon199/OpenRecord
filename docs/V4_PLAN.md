# OpenRecord v4 Plan

A roadmap for evolving OpenRecord from a capable local screen-recording editor
into an **interaction-native publishing system** for product demos, technical
tutorials, changelogs, and software documentation.

v4 builds on the format-v7/v3 foundation that already exists: non-destructive
multi-cut editing, a single source/output time mapper, local transcription,
smart zooms, manual redaction, annotations, templates, batch export, and local
CLI automation.

The goal is not another round of feature parity with conventional video
editors. The goal is to turn OpenRecord's private capture evidence—pixels,
speech, cursor motion, clicks, shortcut events, typing focus, and window
geometry—into useful structure that flattened video cannot retain.

---

## Vision

**Record a real software workflow once. OpenRecord privately understands it,
helps the user perfect it, and publishes every useful form of it without taking
ownership of the source, the evidence, or the format.**

v4 should make three changes to the product's center of gravity:

1. Move from a timestamp-first editor to an **action-aware editor**.
2. Move from isolated manual tools to a **reviewable local first-polish pass**.
3. Move from MP4-centric delivery to **open, reproducible publishing outputs**.

---

## Non-negotiable constraints

Every v4 feature must preserve the existing product constraints.

1. **Apple Silicon macOS only** — arm64, macOS 15+, Apple Command Line Tools,
   SwiftPM, `swift build`, and `swift test`. Do not introduce a full-Xcode
   requirement.
2. **No third-party dependencies** — use native Apple frameworks only,
   including SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, Core Image, Metal,
   Vision, Speech, NaturalLanguage, Accelerate, and CoreML where appropriate.
3. **Local-first** — no accounts, proprietary servers, telemetry uploads,
   cloud-required inference, hosted-link dependency, or API keys.
4. **Transparent projects** — `.openrecord` remains an ordinary directory with
   documented JSON/JSONL and media files.
5. **Raw capture remains immutable** — automatic analysis and editing never
   destructively rewrite the original recording.
6. **One authoritative time model** — all authored and derived events use source
   timestamps; preview, export, audio, telemetry, and alternate outputs resolve
   through `ProjectTimeMapper`.
7. **Preview/export parity is a contract** — new visual behavior must have one
   shared resolved scene description and deterministic regression coverage.
8. **Automation is advisory until approved** — local intelligence may suggest
   edits or privacy regions, but it must not silently remove content or declare
   an export safe.

---

## Product pillars

### 1. Interaction-native editing

The user should navigate and edit a recording through meaningful actions such
as “opened Settings,” “typed into Search,” and “clicked Save,” not only through
seconds on a timeline.

### 2. Local intelligence with visible evidence

Speech, Vision, Accessibility, and deterministic telemetry heuristics should
eliminate repetitive work while showing why each suggestion was made.

### 3. Safe technical publishing

OpenRecord should become the trusted recorder for source code, terminals,
internal tools, customer data, and product environments by providing local,
reviewable privacy protection.

### 4. Open deliverables

Projects and outputs should remain useful without an OpenRecord account or
service. Static hosting, Finder folders, git repositories, and local automation
are first-class destinations.

### 5. Focused scope

v4 should reduce the work between recording and publishing. It should not grow
into a generic NLE, DAW, stock-media catalog, collaboration suite, or generative
video product.

---

## Architecture direction

### Evidence, analysis, authored state, and rendering

Keep four layers distinct:

```text
immutable capture evidence
  recording/display.mp4
  recording/mic.m4a
  recording/system.m4a
  recording/mouse.jsonl
  recording/clicks.jsonl
  recording/keys.jsonl
  recording/typing.jsonl
  recording/target.jsonl
            |
            v
rebuildable local analysis
  analysis/manifest.json
  analysis/actions.jsonl
  analysis/ocr.jsonl
  analysis/privacy.jsonl
  analysis/suggestions.jsonl
            |
            v
user-authored project decisions
  project.json
  edit decisions, zooms, captions, redactions,
  annotations, locked story beats, export defaults
            |
            v
one resolved scene and time model
  ProjectTimeMapper + FrameScene
            |
            v
MP4 / GIF / PNG / audio / tutorial package / documentation
```

Raw evidence is durable and portable. Analysis is versioned, disposable, and
rebuildable. Only user-approved decisions become authoritative project state.

### `analysis/` sidecar contract

Introduce an optional `analysis/` directory without changing format v7:

```text
analysis/
  manifest.json
  actions.jsonl
  ocr.jsonl
  privacy.jsonl
  suggestions.jsonl
  index.json
```

`manifest.json` should include:

- Analysis schema version.
- Analyzer/app version.
- Source media and telemetry fingerprints.
- Locale and native model/API revision where relevant.
- Completion state and recoverable warnings.
- Per-sidecar record counts and optional chunk indexes.

Analysis must be invalidated when its relevant source fingerprint changes.
Unknown or malformed analysis must never prevent the underlying project from
opening or exporting.

Do not place extensible analysis state in `meta.json`; its current persistence
path does not preserve unknown fields. Do not add unknown top-level fields to a
format-v7 `project.json`; current readers correctly reject them.

### Format v8 policy

Keep v4.0 foundation work format-v7-compatible. Introduce project format v8
only when authored ActionMap/story-beat state requires new top-level contracts.

Likely v8 additions:

- `storyBeats`: user-confirmed names, ranges, kinds, and stable evidence IDs.
- Optional suggestion provenance on authored items.
- Later, `mediaSources` and `timelineSpans` for Patch Takes.

Do not add a `replace` enum value to the v7 `EditDecisionKind`. Patch Takes is a
multi-source timeline concept and requires an explicit schema/version change.

Migration rules remain:

1. v1–v7 projects open with behavior-preserving defaults.
2. Opening alone does not rewrite a project.
3. The first real save upgrades only when the document can be preserved fully.
4. Newer versions and unsupported current top-level fields are rejected.
5. Nested forward-compatible fields are preserved by stable ID.
6. CLI inspection, validation, and export remain non-mutating.

### Shared `FrameScene`

Introduce a value-based render description resolved from:

```text
(document, bundle assets, output time, ProjectTimeMapper)
  -> source identity and source timestamp
  -> crop and canvas geometry
  -> media placements
  -> cursor/click/keyboard state
  -> captions, annotations, drawings, redactions
  -> immutable FrameScene
```

SwiftUI remains responsible for editor interaction and hit-testing. A low-cost
preview renderer and the final Core Image/Metal compositor consume the same
`FrameScene`. This removes duplicated geometry decisions without requiring the
interactive editor to encode final-quality frames continuously.

### Telemetry scale and recovery

Before adding more derived intelligence:

- Tolerate and report a crash-truncated final JSONL line.
- Add record sequence numbers or chunk metadata for new streams.
- Avoid loading multi-hour telemetry entirely into memory when sequential or
  indexed access is sufficient.
- Persist click position directly in new captures while retaining inference for
  older bundles.
- Record detailed loss intervals rather than only coarse degraded booleans.
- Add a dedicated warning for truncated typing/focus telemetry.
- Keep Secure Input behavior privacy-preserving and visible in diagnostics.

---

# Phase 0 — v4.0: Interaction foundation

**Goal:** Make the capture, analysis, timing, and render contracts strong enough
for semantic editing without changing visible project behavior unexpectedly.

This phase is intentionally infrastructure-heavy but must ship user-visible
reliability and workflow improvements of its own.

## 0.1 Analysis sidecars

- Add `ProjectLayout` paths for the optional `analysis/` directory.
- Define versioned `AnalysisManifest` and stable evidence identifiers.
- Add atomic sidecar writes and stale-analysis invalidation.
- Preserve all analysis files through Save Copy and library operations.
- Treat missing, malformed, partial, or future analysis as rebuildable cache.
- Extend CLI inspection with analysis availability and freshness, without
  exposing recognized private content.

## 0.2 Telemetry hardening

- Add tolerant streaming/chunked JSONL readers.
- Persist click coordinates for new captures.
- Add monotonic sequence information to new semantic streams.
- Retain precise telemetry/media loss intervals in capture diagnostics.
- Index long cursor/action streams for bounded-memory seek and export.
- Keep legacy JSONL streams fully readable.

## 0.3 Shared render scene

- Define `FrameScene` and pure scene-resolution functions.
- Move crop, normalized placement, active-item selection, and resolved overlay
  states out of SwiftUI and the compositor into the shared scene layer.
- Migrate one feature family at a time: cursor, webcam, device frame, authored
  overlays, then redaction.
- Consolidate video, GIF, and snapshot frame preparation around one render
  service.
- Retain Core Image as the reference implementation while using Metal through
  the existing `CIContext` backend.

## 0.4 Baseline workflow fixes

- Allow library browsing, project opening, and imported-movie editing before
  capture permissions are granted.
- Require permissions only when the requested capture feature needs them.
- Add explicit microphone/system-audio choices to recording setup.
- Add visible analysis/autosave status and cancellation.
- Add Open Project/Finder document handling for `.openrecord` bundles while
  keeping library mutations scoped to the configured root.

## Phase 0 acceptance gate

- Existing v1–v7 migration fixtures pass unchanged.
- A malformed analysis cache cannot block project open, save, or export.
- Long telemetry fixtures use bounded memory and preserve timestamp order.
- Preview/export golden cases remain within documented geometry/pixel
  tolerances.
- Video, GIF, and snapshot render through the shared scene resolver.
- Imported movies can be edited without granting capture-only permissions.
- `swift test` and `swift build -c release --arch arm64` pass.

---

# Phase 1 — v4.1: ActionMap

**Goal:** Turn raw telemetry into a private, searchable map of what the user did.

## 1.1 Privacy-filtered semantic capture

Add an optional timestamped semantic event stream using Accessibility where it
is reliable and Vision only as a local fallback.

Candidate fields:

```json
{
  "id": "stable-uuid",
  "t": 12.42,
  "duration": 0.31,
  "kind": "activate",
  "applicationBundleID": "com.example.Product",
  "role": "button",
  "label": "Save",
  "bounds": { "x": 0.71, "y": 0.86, "width": 0.09, "height": 0.05 },
  "confidence": 0.94,
  "source": "accessibility"
}
```

Privacy requirements:

- Never persist secure-field values.
- Do not persist ordinary typed text by default.
- Sanitize window titles and labels through a documented policy.
- Allow semantic capture to be disabled independently of basic cursor capture.
- Record why an event is absent or degraded without recording the missing data.

## 1.2 Local ActionMap analysis

Correlate:

- Click edges and positions.
- Cursor approach, dwell, departure, and repeated targets.
- Shortcut events.
- Privacy-safe typing-focus bursts.
- Window movement and availability.
- AX element role/label/bounds.
- Vision OCR or scene-change evidence.
- Transcript phrases where available.

Produce stable action candidates with confidence and evidence references.
Deterministic heuristics should establish the baseline; CoreML may rank or
classify candidates but must not be required for project readability.

## 1.3 Action-aware editor

- Add an ActionMap rail beside or integrated with the transcript.
- Search by approved action label, application, chapter, or spoken phrase.
- Click an action to seek and select its source range.
- Rename, merge, split, suppress, and lock actions.
- Convert an action to a chapter, numbered step, zoom, or annotation.
- Add an explicit story-beat marker hotkey during recording.
- Show confidence and supporting signals for inferred actions.

## 1.4 Format v8 authored story beats

Introduce format v8 for compact, user-authored story beats. Derived raw action
evidence remains in `analysis/actions.jsonl`; `project.json` stores only stable
references and user corrections required for portable editing.

## Phase 1 acceptance gate

- ActionMap works without network access.
- Secure fields and ordinary typed text never appear in analysis fixtures.
- AX-unavailable applications degrade to telemetry/Vision or generic actions.
- Renaming or locking an action survives round-trip and migration.
- Searching and seeking stay synchronized across cuts and speed changes.
- Disabling/removing analysis leaves the underlying edit unchanged.
- Format-v8 migration fixtures preserve the v1–v7 rendered result.
- `swift test` and the release build pass.

---

# Phase 2 — v4.2: First Cut and Privacy Firewall

**Goal:** Convert capture into a safe, reviewable first draft instead of a raw
timeline plus isolated manual tools.

## 2.1 Cancellable First Cut pipeline

Replace the single blocking post-capture auto-zoom pass with staged local work:

1. Validate capture health.
2. Transcribe selected audio locally when enabled.
3. Build or refresh the ActionMap.
4. Analyze speech pauses and visual inactivity.
5. Rank repeated attempts and likely abandoned navigation.
6. Suggest cuts, speed regions, zooms, captions, and chapters.
7. Present a review before materializing authored edits.

Suggested intent presets:

- **Natural Demo** — preserve personality and deliberate pauses.
- **Tight Tutorial** — remove dead air and retain reading time after actions.
- **Changelog** — prioritize successful interactions and concise pacing.

Every suggestion includes evidence, confidence, and before/after preview.
Manual or locked items are never overwritten during regeneration.

## 2.2 Suggestion lifecycle

Store derived proposals in `analysis/suggestions.jsonl` with states such as
pending, accepted, rejected, and stale. Applying a suggestion creates ordinary
source-timed project values:

- `EditDecision`
- `ZoomRange`
- `SpeedSegment`
- `CaptionCue`
- `Annotation`
- `CursorEffectRange`
- `storyBeat`

Rejected suggestions remain local evidence for the current analysis revision;
they are not global training telemetry and are never uploaded.

## 2.3 Privacy Firewall analysis

Use local Vision, Accessibility signals, and deterministic detectors to suggest
regions for:

- API keys and common token shapes.
- Email addresses and internal URLs.
- Notifications and account identifiers.
- User-configured sensitive terms.
- Faces or names when explicitly enabled.

Store category, geometry, confidence, and non-reversible fingerprints. Avoid
persisting recognized plaintext in privacy analysis.

Track accepted regions through scrolling, window movement, and modest visual
changes. Accepted results become normal `RedactionRegion` values.

## 2.4 Privacy review and verified output

- Add a pre-export privacy review with accept/reject/edit controls.
- Distinguish possible findings from verified accepted masks.
- Run a second scan over the actual rendered output.
- Produce a local privacy report with timestamps and detector coverage.
- Never claim that the editable source bundle is sanitized; it still contains
  original media.
- Add **Sanitized Share Copy**, which creates a new derivative package with
  rendered-safe media and an allowlisted subset of metadata/telemetry.

## Phase 2 acceptance gate

- First Cut can be cancelled or skipped without project mutation.
- Applying all, some, or none of the suggestions is one coherent undo group.
- Suggestion regeneration preserves manual/locked edits.
- Accepted edits render through existing authoritative project lanes.
- Privacy fixtures test secrets at edges, under zoom, during movement, and for
  only a few frames.
- Sanitized Share Copy contains no original display video or excluded raw
  telemetry and is installed atomically.
- UI copy does not promise perfect detection.
- Full migration, time-mapping, compositor-golden, and release tests pass.

---

# Phase 3 — v4.3: Release Factory and Open Tutorial Package

**Goal:** Publish every useful form of one recording through transparent,
deterministic recipes.

## 3.1 Versioned publish recipes

Add a documented `.openrecordrecipe` or `publish.json` format that describes
outputs without storing machine-specific destination paths in `project.json`.

Example:

```json
{
  "formatVersion": 1,
  "outputs": [
    { "name": "release-demo", "kind": "video", "aspect": "16:9" },
    { "name": "social", "kind": "video", "aspect": "9:16", "maxDuration": 60 },
    { "name": "feature-loop", "kind": "gif", "storyBeat": "save-theme" },
    { "name": "guide", "kind": "markdown", "screenshots": "actions" }
  ]
}
```

Recipes may specify templates, safe areas, story-beat selections, codecs,
resolutions, caption delivery, filenames, and overwrite policy. They must not
contain secrets, accounts, callbacks, arbitrary executable commands, or remote
service requirements.

## 3.2 Responsive RenderPlan

Build a `RenderPlan` layer that derives one or more `FrameScene` configurations
from the same project:

- 16:9 tutorial/video.
- 9:16 social/changelog clip.
- 1:1 preview.
- Story-beat GIF.
- Action-centered still images.

Semantic focus points should reflow zooms and protect caption, webcam,
annotation, and redaction safe areas. A variant is allowed to choose different
framing, but must not choose different source content unless the recipe says so.

## 3.3 Repository-native CLI publishing

Extend the existing CLI with deterministic commands such as:

```text
openrecord-cli analyze Demo.openrecord
openrecord-cli publish Demo.openrecord --recipe release.json --output ./Artifacts
openrecord-cli verify-output ./Artifacts/manifest.json
```

The export manifest should contain:

- Project and recipe format versions.
- Source/telemetry fingerprints.
- Analyzer and render versions.
- Output settings and source/output durations.
- Generated filenames and checksums.
- Warnings, privacy-review state, and reproducibility limitations.

The CLI remains local, dependency-free, non-interactive when fully configured,
and non-mutating unless an explicit analysis command writes rebuildable cache.

## 3.4 Documentation outputs

Generate reviewable Markdown/HTML using ActionMap steps, approved labels,
transcript ranges, and exact action-centered screenshots. Prefer structured
templates over unconstrained generative prose.

Outputs may include:

- Step title and short approved transcript explanation.
- Screenshot at the successful action state.
- Keyboard shortcut or click note.
- Link to the corresponding tutorial-player timestamp.
- Alt text and caption files.

## 3.5 Open Tutorial Package

Export a self-contained static artifact:

```text
Tutorial.openrecordweb/
  index.html
  player.js
  player.css
  video.mp4
  manifest.json
  captions.vtt
  cursor.png
  poster.jpg
```

Capabilities:

- Searchable transcript and ActionMap.
- Step navigation and optional pause-after-step mode.
- Adjustable cursor visibility/scale.
- Click and approved keyboard-shortcut overlays.
- Copyable commands or links only when the author explicitly includes them.
- Standard MP4 fallback.
- No analytics, remote fonts, CDN assets, accounts, or OpenRecord server.

Redactions must be baked into the player video. The package must never include
raw display media, rejected actions, private OCR evidence, or unrestricted
keyboard telemetry.

## Phase 3 acceptance gate

- A recipe produces byte-stable manifests and semantically equivalent outputs
  from the same supported machine/toolchain configuration.
- Variant framing keeps all protected regions covered.
- CLI publish can run headlessly with actionable nonzero exit codes.
- Markdown references existing generated assets with portable relative paths.
- The tutorial package works from a local folder and a generic static host.
- Player cursor/click timing matches native export within documented tolerance.
- Network inspection confirms no external request is required.
- Full build, tests, CLI fixtures, and package validation pass.

---

# Phase 4 — v4.4: Patch Takes

**Goal:** Let users repair or update one interaction without re-recording the
entire tutorial.

Patch Takes is last because it changes the project from one primary display
source into a multi-source composition. It must not destabilize the earlier v4
releases.

## 4.1 Patch workflow

- Select an ActionMap step or source interval.
- Choose **Replace with Patch Take**.
- Show the original entry frame, target geometry, cursor entry point, and nearby
  transcript as a recording guide.
- Capture only the replacement interaction and selected audio tracks.
- Suggest entry/exit seams using ActionMap identity, window geometry, cursor
  position, visual similarity, and optional audio correlation.
- Preview original and patch variants before applying.
- Keep every take immutable and allow reverting at any time.

## 4.2 Multi-source project model

Extend format v8 with explicit source ownership:

```text
recording/takes/<source-id>/
  display.mp4
  mic.m4a
  system.m4a
  mouse.jsonl
  clicks.jsonl
  keys.jsonl
  typing.jsonl
  target.jsonl
```

`project.json` adds:

- `mediaSources`: stable source IDs, relative paths, timing origins, track
  offsets, capture health, and dimensions.
- `timelineSpans`: ordered output spans referencing a source ID and half-open
  source-local time range.

The authoritative mapper becomes:

```text
output time
  -> timeline span
  -> source ID + source-local timestamp
  -> per-source media and telemetry
  -> FrameScene
  -> preview/export
```

Speed mapping, captions, ActionMap items, and authored overlays require an
explicit policy for whether they are output-timed, source-timed, or attached to
a stable semantic action. Avoid implicit retiming.

## 4.3 Seam and audio behavior

Initial scope:

- Hard visual cuts and a short cross-dissolve only.
- Original audio, patch audio, or a bounded crossfade.
- No arbitrary transition library.
- No general multi-track composition UI.
- No voice cloning, generated speech, or cloud repair.

## 4.4 Reusable demo blocks — stretch

Once patch sources are stable, allow a confirmed ActionMap step to be copied
between compatible OpenRecord projects. This remains a focused reuse workflow,
not a general media bin or NLE clip system.

## Phase 4 acceptance gate

- Original source media is never modified or deleted when a patch is applied.
- Projects with one source render identically to pre-Patch-Take behavior.
- Multi-source cut boundaries remain synchronized for screen, cursor, webcam,
  keyboard, transcript, and audio.
- Preview and export use the same source-selection mapper.
- Missing or damaged optional patch tracks degrade without losing healthy
  primary display media.
- Save Copy includes all referenced sources and no unreferenced temporary take.
- Format-v8 migration and forward-version rejection remain lossless.
- Full mapping, recovery, golden-frame, audio-sync, and release gates pass.

---

## Agentic execution and usage-limit strategy

v4 is intentionally divided so every checkpoint leaves the repository buildable
and can be resumed after an agent usage reset or context compaction.

### Work-packet rule

Each implementation run should own one bounded packet from the following
sequence:

1. **Contract packet** — schema/types, migration behavior, and fixtures.
2. **Pure engine packet** — deterministic non-UI implementation and focused
   tests.
3. **Persistence packet** — atomic IO, invalidation, recovery, and round-trip
   tests.
4. **UI packet** — one coherent user workflow using already-established APIs.
5. **Parity packet** — preview/export integration and golden fixtures.
6. **Release packet** — full tests, release build, documentation, and manual
   verification checklist.

Do not combine a new schema, capture path, editor surface, and renderer rewrite
in one agent run. If the remaining usage budget is low, stop after the current
packet passes its focused tests and record the next exact checkpoint.

### Parent-only default

Follow the repository's parent-only execution policy by default. Use subagents
only when the user explicitly requests them. When subagents are enabled:

- Freeze shared contracts in the parent before parallel work begins.
- Give each worker non-overlapping file ownership.
- Keep migration files and shared render/time contracts parent-owned or assign
  them sequentially.
- Parallelize only independent work such as fixtures, CLI surfaces, and UI built
  against an already-merged protocol.
- Review all diffs and run integration tests in the parent session.

### Test-budget discipline

- Run the smallest relevant `swift test --filter ...` set during a packet.
- Run `swift test` at every phase acceptance gate.
- Run `swift build -c release --arch arm64` at phase gates, not after every
  isolated model/test edit.
- Run expensive compositor, benchmark, and packaging verification only when the
  affected render/export phase is integrated.
- Never trade migration, privacy, time-mapping, or recovery tests for shorter
  agent runs; reduce feature scope instead.

### Checkpoint record

Maintain a short v4 execution checkpoint document during implementation with:

- Completed packet and commit/diff summary.
- Files and contracts changed.
- Focused tests run and results.
- Known failures or manual gates.
- Exact next packet.
- Whether a format or analysis-cache migration is now irreversible.

This prevents repeated repository rediscovery and lets a new agent session
continue from verified state rather than re-planning the whole phase.

---

## Cross-phase testing strategy

### Project and analysis formats

- v1–v8 migration fixtures.
- Unknown top-level and unknown-enum refusal.
- Nested-field preservation by stable ID.
- Stale analysis invalidation.
- Malformed/truncated sidecar recovery.
- Atomic write and Save Copy preservation.

### Timing

- Output/source/action mapping across trim, cuts, and speed segments.
- Exact half-open boundary behavior.
- Action and transcript selection at cut boundaries.
- Multi-source patch boundaries when Phase 4 begins.
- VFR fixtures; never use frame indexes as authored time.

### Privacy

- Secure Input and secure-field fixtures.
- No ordinary typed text in semantic analysis.
- OCR plaintext omission from persisted privacy evidence.
- Redaction tracking across window motion, crop, and speed changes.
- Sanitized-package allowlist tests.

### Rendering

- Shared `FrameScene` unit fixtures.
- Golden frames for every visual stage.
- Preview/export geometry tolerance.
- Variant safe-area and redaction coverage.
- Native/player cursor and click-timing parity.

### Performance and recovery

- Multi-hour indexed telemetry fixtures.
- Bounded-memory analysis and export.
- Cancellation at every analysis stage.
- Partial analysis rebuild after interruption.
- Primary-display preservation when optional tracks fail.

---

## Success criteria

v4 succeeds if:

- A typical changelog recording opens with a useful ActionMap and reviewable
  First Cut instead of a raw timeline.
- Users can find a visual moment by action or speech without manual scrubbing.
- Suggested edits save time while remaining explainable, reversible, and local.
- Technical creators can review likely sensitive content and make a genuinely
  sanitized derivative without uploading source material.
- One recipe can reproducibly create video, social, GIF, screenshot, caption,
  and documentation outputs.
- A tutorial can be distributed as an owned, serverless interactive package.
- A late mistake or changed UI step can eventually be repaired through a Patch
  Take without re-recording the whole project.
- Existing projects retain their previous visual and timing behavior.
- Preview/export parity improves rather than regresses as intelligence grows.
- The product remains understandable without accounts, plugins, or proprietary
  services.

Suggested measurable targets:

| Metric | v4 target |
|---|---:|
| Time from stop to reviewable First Cut for a 5-minute 1080p recording | < 90 seconds on a representative M2-class Mac |
| Manual timeline operations before first acceptable changelog export | 50% fewer than v3 baseline |
| ActionMap seek accuracy for supported AX controls | within 250 ms of the causal interaction |
| Peak telemetry-analysis memory for a 2-hour recording | bounded independently of raw mouse-event count after indexing |
| Variant export setup after a recipe exists | one command or one editor action |
| Network requests required for analysis, editing, or tutorial playback | 0 |
| Existing migration/render fixtures preserved | 100% |

---

## Explicitly out of scope for v4

- Accounts, team workspaces, or proprietary hosted sharing.
- Viewer analytics or telemetry collection.
- Cloud AI, API keys, remote model inference, or cloud-required translation.
- General multitrack NLE/DAW workflows.
- Arbitrary transitions, animation curves, or effect plugins.
- Stock media, avatars, voice cloning, or generated presenters.
- Automatic execution/replay of recorded UI actions.
- Claiming perfect secret detection.
- Windows or Intel Mac support.
- Live streaming.

---

## Recommended release order

```text
v4.0  Analysis sidecars + telemetry hardening + FrameScene + baseline workflow fixes
v4.1  ActionMap + format-v8 authored story beats
v4.2  First Cut + Privacy Firewall + Sanitized Share Copy
v4.3  Release Factory + documentation outputs + Open Tutorial Package
v4.4  Patch Takes + explicit multi-source timeline
```

Each release must be useful without the next one. In particular:

- v4.0 improves reliability and parity even if semantic editing is delayed.
- v4.1 makes recordings searchable even before automatic editing ships.
- v4.2 saves editing time and establishes the strongest privacy moat.
- v4.3 makes OpenRecord a publishing tool for technical teams without adding a
  cloud platform.
- v4.4 tackles the highest-value, highest-risk re-recording problem only after
  the timing and rendering foundation can support it safely.

---

## Summary

v4 should not attempt to beat Screen Studio, Loom, or Descript by copying their
visible feature lists. It should compound the architectural asset OpenRecord
already owns: timestamped, private, inspectable interaction evidence.

The critical sequence is:

```text
harden evidence
  -> resolve one scene
  -> understand actions
  -> propose and verify edits
  -> publish open deliverables
  -> support surgical re-recording
```

That sequence produces a focused product moat while keeping OpenRecord local,
portable, deterministic, and intentionally smaller than a generic video editor.
