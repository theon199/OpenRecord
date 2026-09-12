# OpenRecord Status

Last updated: 2026-09-11

This is the repository's single current-status entry point. Detailed product
scope remains in the version plans; this file records what is implemented, what
has been verified, what remains manual, and the next safe execution checkpoint.

## At a glance

| Area | Status |
|---|---|
| Current implemented product line | v4.4.0 Patch Takes + Multi-Source Timeline |
| Current project document format | v8 |
| v3 implementation checkpoints | Complete |
| v3 deterministic automated release gates | Recorded complete |
| Final v3 release/tag/push artifacts | Pending |
| Hardware and permission-flow evidence | Pending/recommended |
| v4 product and architecture plan | Complete (Phases 0–4 complete) |
| v4.0 / Phase 0 implementation | Complete (verified) |
| v4.1 / Phase 1 implementation | Complete (verified) |
| v4.2 / Phase 2 implementation | Complete (automated gates verified) |
| v4.3 / Phase 3 implementation | Complete (automated gates verified) |
| v4.4 / Phase 4 implementation | Complete (automated gates verified) |
| Next checkpoint | Full release package / tag / manual audit evidence |

## Current baseline

The repository currently describes OpenRecord v4.4.0 and Phase 4 (Patch Takes + Multi-Source Timeline) as implemented, with its automated gates verified. Real-world visual, playback, privacy, and hardware checks remain manual. Its main capabilities include:

- Native ScreenCaptureKit display/window capture with separate cursor telemetry.
- Optional microphone, system audio, webcam, and privacy-filtered shortcut tracks.
- Optional privacy-filtered semantic control capture and precise story-beat markers.
- Transparent `.openrecord` bundles with raw media, JSONL telemetry,
  `meta.json`, `project.json`, and optional rebuildable `analysis/` sidecars.
- Authoritative output-time to source-time mapping across trim, cuts, speed regions,
  and multi-source patch take spans.
- Explicit multi-source timeline with immutable replacement takes stored in
  `recording/takes/<source-id>/`, half-open source intervals, and clean revert capability.
- Seam engine supporting hard cuts and bounded cross-dissolve transitions
  with graceful fallback for damaged or missing optional take tracks.
- Source-aware audio multiplexing respecting `.sourceAudio`, `.crossfade`, and `.silence`.
- Replacement take recording guides with entry frame, target geometry, cursor cues,
  and deterministic `PatchTakeAligner` confidence scoring.
- Automatic pruning of unreferenced temporary takes during Save Copy.
- Shared pure `FrameScene` and `FrameRenderService` for video, GIF, and snapshot export.
- On-device transcription, transcript-assisted editing, pause suggestions, and
  cancellation-safe smart automatic zooms.
- Deterministic local ActionMap analysis with searchable, correctable actions
  and source-time synchronization across cuts and speed regions.
- Cancellable, suggestion-only First Cut planning with three intent presets,
  evidence/confidence previews, durable local review state, and coherent undo.
- Local Privacy Firewall detection with plaintext-free persisted evidence,
  accepted redaction tracking, pre-export review, and rendered-output scanning.
- Atomic Sanitized Share Copy packages with rendered-safe media, a strict
  metadata allowlist, and machine-verifiable privacy/portability reports.
- External versioned publish recipes that keep destinations out of `project.json`.
- Responsive `RenderPlan` variants for 16:9, 9:16, 1:1, story-beat GIF, and
  action-centered still outputs, all resolved through shared `FrameScene` timing.
- Headless `openrecord-cli analyze`, `publish`, and `verify-output` commands
  with deterministic release manifests and actionable nonzero exit behavior.
- Structured Markdown and HTML documentation with approved ActionMap steps,
  transcript ranges, screenshots, alt text, captions, and portable relative paths.
- Self-contained Open Tutorial Packages with local player assets, baked
  redactions, no raw telemetry/private OCR, and no network requirement.
- Non-destructive captions, annotations, drawings, redactions, cursor effects,
  webcam treatments, device frames, and audio cleanup.
- Project templates, selected-project batch export, imported movie projects,
  decoupled permissions, and local CLI inspection/validation/export.

The canonical v3 status and release evidence live in:

- [`docs/V3_EXECUTION_CHECKPOINTS.md`](docs/V3_EXECUTION_CHECKPOINTS.md)
- [`docs/V3_RELEASE_CHECKLIST.md`](docs/V3_RELEASE_CHECKLIST.md)
- [`docs/V3_RELEASE_NOTES.md`](docs/V3_RELEASE_NOTES.md)
- [`docs/PROJECT_FORMAT_V8.md`](docs/PROJECT_FORMAT_V8.md)

## Release verification status

The v3 release checklist records these automated gates as complete:

- Full Swift test suite, including v1–v7 migration coverage.
- Debug build for the app, benchmark, and CLI products.
- Apple Silicon release build and deterministic benchmark smoke.
- Packaged app metadata, architecture, and signature verification.
- CLI help and inspect/validate smoke coverage.

Still pending before a formal release/tag:

- Final git diff and status review.
- Tagged commit and GitHub push.
- Final release artifacts.

Recommended manual evidence still outstanding or not recorded as complete:

- Clean-account Screen Recording, Microphone, Accessibility, and Camera flows.
- Real display/window, camera, microphone, and interruption testing.
- 30-minute, 1-hour, and 2-hour capture soaks.
- Real iPhone movie import and editing.
- Final visual review of templates, editing, and batch export.
- Developer ID signing, notarization, and Gatekeeper checks if required for the
  intended distribution channel.

The automated gates above are historical evidence from the checked-in release
checklist. They were not rerun when this status document was created.

## Active working tree

The working tree contains the implemented v4.0 foundation, v4.1 ActionMap, and
v4.2 First Cut/Privacy Firewall changes across capture, analysis, contracts,
editor, export workflow, and tests. All automated gates pass cleanly.

Treat all pre-existing modifications as user work:

- Do not reset, discard, or overwrite unrelated changes.
- Inspect `git status --short` and the relevant diffs before implementation.
- Preserve all v1–v7 migration behavior and format-v8 authored story beats.

## v4 status

The v4 strategy is documented in [`docs/V4_PLAN.md`](docs/V4_PLAN.md).

Its planned release sequence is:

```text
v4.0  Analysis sidecars + telemetry hardening + FrameScene + workflow fixes
v4.1  ActionMap + format-v8 authored story beats
v4.2  First Cut + Privacy Firewall + Sanitized Share Copy
v4.3  Release Factory + documentation outputs + Open Tutorial Package
v4.4  Patch Takes + explicit multi-source timeline
```

Phases 0–2 (v4.0 Interaction Foundation, v4.1 ActionMap, and v4.2 First Cut /
Privacy Firewall) implementation and deterministic verification are complete.
Phase 3 (v4.3 Release Factory + Open Tutorial Package) implementation and
automated verification are complete. Manual release evidence remains pending.
Project document format remains v8.

## Phase 0 (v4.0) execution checkpoint: Interaction foundation

Verified on 2026-09-10. All automated Phase 0 acceptance gates are satisfied.

### Completed work packets

1. **0.1 Analysis sidecars (`Sources/OpenRecord/Contracts/Analysis.swift`, `Sources/OpenRecord/Library/AnalysisStore.swift`, `Sources/OpenRecord/Contracts/ProjectLayout.swift`)**:
   - Optional, rebuildable `.openrecord/analysis/` bundle directory layout (`manifest.json`, `actions.jsonl`, `ocr.jsonl`, `privacy.jsonl`, `suggestions.jsonl`, `index.json`).
   - Strong schema versioning (`AnalysisManifest`), stable evidence IDs (`ev-uuid`), analyzer provenance, per-sidecar record/byte/chunk count consistency.
   - Cache status classification (`.fresh`, `.stale`, `.partial`, `.malformed`, `.incompatible`). Missing source fingerprints correctly classified as `.partial` rather than `.fresh`.
   - Security and containment hardening: symlink rejection for both files and parent directories (`isAnalysisDirectorySafe`, `isAnalysisFileSafe`, atomic `install`), preventing bundle breakout or symlink escapes.
   - Privacy-safe inspection: manifest warnings sanitized into fixed diagnostic codes (`"Analysis contains recoverable warnings"`), strictly preventing raw OCR or PII tokens from leaking into CLI or logs.
   - Preserved across `saveCopy` and project library operations; missing or malformed cache never blocks project load, save, or export.

2. **0.2 Telemetry hardening (`Sources/OpenRecord/Contracts/TelemetryIndex.swift`, `Sources/OpenRecord/Contracts/ProjectJSON.swift`, `Sources/OpenRecord/Capture/JSONLWriter.swift`)**:
   - Resilient streaming JSONL readers (`scanJSONLLines`, `streamingJSONLSequence`) with `startOffset` byte-seeking support and tolerant handling of unterminated crash tails.
   - Monotonic, thread-safe sequence numbers assigned by `JSONLWriter` under concurrent callbacks.
   - Explicit click coordinates recorded directly in `recording/clicks.jsonl` while preserving backward-compatible cursor fallback.
   - `TelemetryIndex` sparse chunk metadata indexing with bounded-memory range queries (`readRange` locating chunk offsets and exiting early via file-scoped `TelemetryScanEarlyExit`), strictly limiting allocations to $O(\text{range.count} + 1)$ for long recordings.
   - Structured capture diagnostics recording granular telemetry/audio loss intervals.

3. **0.3 Shared render scene (`Sources/OpenRecord/Export/FrameScene.swift`, `Sources/OpenRecord/Export/FrameRenderService.swift`, `Sources/OpenRecord/Export/Exporter.swift`, `Sources/OpenRecord/Export/ExportExtras.swift`)**:
   - Pure, value-based `FrameScene` representation resolving source time, display crop, canvas geometry, cursor/clicks/typing, webcam overlays, device frames, authored overlays, and redactions from `(document, assets, outputTime, ProjectTimeMapper)`.
   - `FrameRenderService` consolidating video (`Exporter`), animated GIF, and still snapshot (`ExportExtras`) rendering into a single shared pipeline.
   - Preserves pixel-exact parity with existing Core Image/Metal compositor golden tests.

4. **0.4 Baseline workflow fixes (`Sources/OpenRecordApp/ContentView.swift`, `Sources/OpenRecordApp/EditorSession.swift`, `Sources/OpenRecordApp/PermissionsView.swift`, `Sources/OpenRecordApp/OpenRecordApp.swift`)**:
   - Decoupled capture permissions: library browsing, project open, template management, and imported movie editing are fully accessible without granting capture-only (Screen Recording / Camera / Mic / Accessibility) permissions.
   - Permissions requested granularly based only on configured recording tracks.
   - Added explicit microphone and system-audio track toggles.
   - Auto-zoom and analysis cancellation safety: offloaded expensive `SmartAutoZoom` operations to background detached tasks with cooperative cancellation checks (`Task.checkCancellation()`), transactional rollback on cancellation, clean state restoration, and elimination of partial edits.
   - Document-driven Open Project / Finder `.openrecord` bundle mounting.
   - Fixed localized error string interpolation typo in `EditorSession`.

### Automated verification results

- **Test Suite**: 159 tests passing (`swift test`, 1 suite, 0 failures).
  - Includes all historical v1–v7 migration fixtures.
  - Includes 12 `AnalysisSidecarTests`, 7 `TelemetryHardeningTests`, 4 `FrameSceneTests`, and 4 `Phase4WorkflowTests`.
- **Release Build**: `swift build -c release --arch arm64` passed cleanly (compiled openrecord-cli, OpenRecordExportBenchmark, and OpenRecord application target in 35.99s).
- **Format Integrity**: Project format remains strictly `v7`. No unversioned top-level field additions or irreversible schema migrations introduced.
- **Diff Hygiene**: `git diff --check` passed with 0 whitespace or formatting errors.

### Outstanding manual gates

- Real-device TCC permission flows (Screen Recording, Camera, Mic, Accessibility) on clean macOS accounts.
- Multi-hour capture soak tests (30m, 1h, 2h) with live hardware capture.
- Real-world iPhone movie imports with variable frame rates.

## Phase 1 (v4.1) execution checkpoint: ActionMap

Verified on 2026-09-11. All automated Phase 1 acceptance gates are satisfied.

### Completed work packets

1. **Privacy-filtered semantic capture**:
   - Independent opt-in capture setting and dedicated `recording/semantic-targets.jsonl` stream; legacy `target.jsonl` remains target geometry.
   - Accessibility control roles, normalized bounds, application bundle IDs, allowlisted static labels, safe shortcuts, and explicit fixed degradation reasons.
   - No Accessibility value/selection queries, ordinary typed characters, secure-field contents, or window titles.
   - Precise `⌃⌥⌘M` story-beat marker recorded on the capture clock.

2. **Deterministic local ActionMap analysis**:
   - Stable action/evidence IDs and correlation across semantic events, click edges, cursor context/dwell, shortcut chords, privacy-safe typing bursts, target geometry, bounded sanitized Vision evidence, and transcript timing.
   - Atomic `actions.jsonl` / `ocr.jsonl` / index / manifest replacement with source fingerprints, recoverable stream warnings, stale-cache rejection, and preservation of unrelated analysis sidecars.
   - Accessibility-unavailable recordings degrade to generic telemetry actions; derived rows never copy transcript or ordinary keyboard text.

3. **Action-aware editor**:
   - Searchable ActionMap popover with confidence, evidence signals, included/partial/cut state, and mapper-aware source seek/selection.
   - Undoable rename, merge, split, suppress, lock, chapter/step conversion, zoom creation, and annotation creation.
   - Best-effort cache loading and cancellable local rebuild; missing or malformed analysis leaves authored edits and story beats intact.

4. **Format v8 authored story beats**:
   - Compact `storyBeats` contract with stable evidence references, source ranges, kinds, user titles, lock/suppression state, and provenance.
   - v1–v8 fixture migration and round-trip coverage, strict future-schema handling, timeline normalization, and case-insensitive UUID matching for nested-field preservation.

### Automated verification results

- **Test Suite**: `swift test` passed with 0 failures, including 16 new ActionMap, semantic-capture, privacy, persistence, and format-v8 test cases plus an explicit Command Line Tools acceptance harness and all historical v1–v7 migration/render coverage.
- **Release Build**: `swift build -c release --arch arm64` passed cleanly in 40.50s for the app, CLI, and export benchmark products.
- **Format Integrity**: Project format v8 fixtures pass; opening legacy fixtures remains read-only until save; analysis deletion does not mutate authored state.
- **Diff Hygiene**: `git diff --check` passed with 0 whitespace errors.

### Outstanding manual gates

- Real-app Accessibility behavior across representative native, Electron, browser, and AX-limited targets.
- Visual review of the ActionMap popover and conversion workflows with long recordings.
- Hardware capture verification of semantic opt-in, secure-input transitions, and the story-beat hotkey.

## Phase 2 (v4.2) execution checkpoint: First Cut + Privacy Firewall

Verified on 2026-09-11. All automated Phase 2 acceptance gates are satisfied.

### Completed work packets

1. **First Cut planning and lifecycle**:
   - Pure deterministic planning for Natural Demo, Tight Tutorial, and Changelog intents across capture health, optional transient on-device transcription, ActionMap, pauses, inactivity, repeated attempts, and likely abandoned navigation.
   - Stable proposals for existing authoritative cut, speed, zoom, caption, annotation, cursor-effect, and story-beat lanes with evidence, confidence, and before/after review metadata.
   - Pending/accepted/rejected/stale state in `analysis/suggestions.jsonl`; regeneration preserves decisions and manual/locked authored work.
   - New captures open into review instead of receiving immediate authored auto-zooms. Cancel/Skip never mutates `ProjectDocument`; applying a subset or all proposals is one history entry.

2. **Privacy Firewall and verified output**:
   - Deterministic local detectors for token/API-key shapes, email, internal URLs, notifications, accounts, custom terms, and opt-in face/name signals.
   - Privacy findings persist only category, normalized tracked geometry, confidence, detector coverage, and non-reversible SHA-256 fingerprints; recognized plaintext remains ephemeral.
   - Review UI distinguishes possible, accepted, rejected, stale, and verified findings. Accepted findings materialize as normal `RedactionRegion` values and remain editable in the existing inspector/timeline.
   - Every rendered video export is preceded by privacy review and followed by a second local Vision scan plus an adjacent privacy report with sampled/finding timestamps. Accepted content that remains detectable is flagged as unresolved rather than counted as a verified mask. Copy explicitly warns that detection is best effort and the source bundle is not sanitized.

3. **Sanitized Share Copy**:
   - Fresh H.264 render followed by atomic same-parent installation of a derivative `.openrecord` bundle.
   - Exact allowlist: privacy-minimized `meta.json`, reset `project.json`, rendered `recording/display.mp4`, and `privacy-report.json` with included/excluded paths and SHA-256 fingerprints.
   - Original display media, separate audio, thumbnails, analysis, cursors, semantic events, and all raw telemetry are excluded; symlink/path validation and failure cleanup preserve an existing destination.

### Automated verification results

- **Full Test Suite**: `swift test` passed with 0 failures, including 7 new First Cut tests, 6 Privacy Firewall tests, and 4 Sanitized Share Copy tests plus all migration, time-mapping, compositor-golden, and historical release coverage.
- **Debug Build**: `swift build` passed cleanly for the app, CLI, and export benchmark products.
- **Release Build**: `swift build -c release --arch arm64` passed cleanly in 47.53s.
- **Format Integrity**: Project format remains v8; all new derived review data is optional/removable analysis, and accepted values render through existing authored lanes.

### Outstanding manual gates

- Visual review of both review sheets with long real-world recordings and dense findings.
- Hardware capture validation of transient First Cut transcription and privacy scanning against native, Electron, and browser content.
- Manual inspection of rendered privacy reports and Sanitized Share Copy playback across representative codecs/content.

## Phase 3 (v4.3) execution checkpoint: Release Factory + Open Tutorial Package

The v4.3 implementation scope from [`docs/V4_PLAN.md`](docs/V4_PLAN.md) is
complete in the working tree. Automated verification passed on 2026-09-11;
manual release evidence remains listed separately below.

### Completed implementation scope

1. **External versioned publish recipes**:
   - `.openrecordrecipe` and `publish.json` are standalone JSON recipes with
     `formatVersion: 1` and an ordered `outputs` array.
   - Recipes select output kind, aspect, story-beat scope, codec, resolution,
     duration cap, captions, safe areas, filenames, templates, and overwrite
     policy without storing machine-specific destinations in `project.json`.
   - Secrets, account identifiers, callbacks, arbitrary commands, and remote
     service requirements are outside the recipe contract.

2. **Responsive `RenderPlan` variants**:
   - 16:9 tutorial/video, 9:16 social/changelog, 1:1 preview, story-beat GIF,
     and action-centered still images derive from the same project,
     `ProjectTimeMapper`, and shared `FrameScene`.
   - Responsive framing may reflow semantic focus and protect caption, webcam,
     annotation, and redaction safe areas, but does not select new source
     content unless the recipe explicitly chooses a story beat.

3. **Repository-native publishing CLI**:
   - `openrecord-cli analyze <project.openrecord>` may refresh only
     rebuildable analysis sidecars.
   - `openrecord-cli publish <project.openrecord> --recipe <file> --output
     <directory>` is deterministic and headless once configured.
   - `openrecord-cli verify-output <manifest.json>` checks generated files,
     checksums, relative paths, supported versions, and package privacy/network
     invariants.
   - Exit contract: `0` on complete success, `1` on project/recipe/render/
     output/checksum/package failure, and `64` on invalid usage or unsupported
     options. A failed publish cannot leave a manifest claiming success.

4. **Deterministic manifest and documentation outputs**:
   - `manifest.json` records project/recipe versions, source and telemetry
     fingerprints, analyzer/render versions, stable output entries,
     relative filenames, settings, durations, byte sizes, SHA-256 checksums,
     warnings, privacy-review state, and reproducibility limitations.
   - Markdown and HTML use approved ActionMap labels and transcript ranges,
     action-centered screenshots, shortcut/click notes, tutorial timestamps,
     alt text, captions, and validated portable relative asset references.

5. **Open Tutorial Package**:
   - Stable package contents are `index.html`, `player.js`, `player.css`,
     `video.mp4`, `manifest.json`, `captions.vtt`, `cursor.png`, and
     `poster.jpg` under `Tutorial.openrecordweb/`.
   - The rendered video has accepted redactions baked in. Raw display media,
     rejected actions, private OCR evidence, and unrestricted keyboard
     telemetry are excluded; explicitly authored commands/links are the only
     copyable commands/links.
   - The local player supplies transcript/ActionMap search and navigation,
     optional pause-after-step, cursor visibility/scale, click and approved
     shortcut overlays, captions, and standard MP4 fallback.
   - The package makes no external requests: no analytics, remote fonts, CDN
     assets, accounts, callbacks, or OpenRecord server. Relative assets work
     from a local folder and a generic static host.

### Format and verification status

Project format remains v8. Recipes, RenderPlans, release manifests,
documentation, and tutorial packages are derived artifacts and do not alter
authored project JSON. Legacy v1–v7 projects retain the existing read-only
open/first-save migration behavior, current-format unknown top-level fields
remain rejected, and optional/malformed analysis remains rebuildable.

Automated Phase 3 gates were verified on 2026-09-11:

- [x] repeated publishing produces a byte-identical manifest on the supported
  toolchain, and RenderPlan variants are deterministic;
- [x] protected-region coverage is validated across RenderPlan variants;
- [x] headless CLI parsing, mutation boundaries, and exit-code fixtures pass;
- [x] Markdown tutorial links resolve through portable relative paths;
- [x] the exact tutorial-package allowlist and static-host-compatible relative
  asset graph pass end-to-end package validation;
- [x] cursor, click, shortcut, caption, and step times use the same cut-aware
  `ProjectTimeMapper` as native export, with exact fixture assertions;
- [x] generated player assets contain no external request URLs or fetch path;
- [x] the full `swift test` suite passed, including compositor goldens and the
  end-to-end Release Factory fixture;
- [x] `swift build -c release --arch arm64` passed for the app, CLI, and export
  benchmark products;
- [x] `git diff --check` passed with no whitespace errors.

Manual Phase 3 gates remain:

- [ ] visual review of every aspect variant with long recordings and dense
  captions, webcam, annotations, and redactions;
- [ ] review generated Markdown/HTML in a clean folder and on a generic static
  host;
- [ ] open the tutorial package from `file://` with network access disabled;
- [ ] inspect privacy boundaries and playback for representative codecs,
  approved/rejected actions, shortcuts, and captions;
- [ ] confirm the external recipe never leaks source paths, secrets, private
  OCR, or unrestricted keyboard content.

## Phase 4 (v4.4) execution checkpoint: Patch Takes and explicit multi-source timeline

The v4.4 implementation scope from [`docs/V4_PLAN.md`](docs/V4_PLAN.md) is
complete in the working tree. Automated verification passed on 2026-09-11;
manual release evidence remains listed separately below.

### Completed implementation scope

1. **Contracts and multi-source models**:
   - `MediaSource` specifies `primaryID`, relative storage under `recording/takes/<source-id>`,
     timing origins, track offsets, capture health, and dimensions.
   - `TimelineSpan` specifies `sourceID`, half-open source interval (`sourceStart` ..< `sourceEnd`),
     `seamTransition` (`.cut`, `.crossDissolve`), `transitionDuration`, and `audioMode`
     (`.sourceAudio`, `.crossfade`, `.silence`).
   - `PatchTakeProposal`, `PatchProposalState`, `PatchTakeGuide`, and `PatchTakeAligner`
     provide guided take replacement, geometric/cursor similarity alignment, and confidence scoring.
   - `PatchTakeOperations` implements immutable replacement span construction (`buildSpans`),
     applying patch takes, and lossless reversion to single-source or earlier take states.

2. **Multi-source bundle layout and per-source streams**:
   - `ProjectLayout` supports `takes/` directory structure: `recording/takes/<source-id>/`
     housing independent `display.mp4`, `mic.m4a`, `system.m4a`, `mouse.jsonl`, `clicks.jsonl`,
     `keys.jsonl`, `typing.jsonl`, and `target.jsonl`.
   - Legacy and primary sources remain rooted at `recording/` for zero regression and 100% backward compatibility.

3. **Authoritative multi-source time and seam mapping**:
   - `ProjectTimeMapper` maps output time to `(sourceID, sourceTime)` across all cuts,
     speed changes, and multi-source take spans.
   - Cross-dissolve seam detection via `activeSeam(atOutputTime:)` calculating progress `[0, 1]`
     and outgoing/incoming source times.
   - Clamped and half-open source-to-output mapping (`outputTime(forSourceTime:sourceID:)`)
     preventing cross-source boundary confusion.

4. **FrameScene and compositor frame rendering parity**:
   - `FrameScene` carries `sourceID` alongside `sourceTime`.
   - `FrameRenderService` maintains multi-source take decoders (`takeReaders`),
     rendering primary or take frames seamlessly.
   - Cross-dissolve transitions are composited with `CIDissolveTransition` and fall back gracefully
     to the active or primary take if an optional track is damaged or missing.

5. **Multi-source audio multiplexing**:
   - `ExportAudioMux` accepts multi-source audio inputs tagged by `sourceID`.
   - `AudioPlacement` maps audio slices to their originating source track,
     respecting `.silence` and bounded `.crossfade` modes.

6. **Take lifecycle and bundle hygiene**:
   - `ProjectLibrary.saveCopy` inspects `recording/takes/` and prunes unreferenced temporary take
     directories, ensuring exported `.openrecord` bundles remain compact and private.

7. **EditorSession ActionMap integration**:
   - `patchGuideForSelection()` builds live replacement guide telemetry from selected ActionMap steps.
   - `replaceWithPatchTake(...)` and `revertPatchTake(sourceID:)` support end-to-end non-destructive
     take replacement and instant rollback.

### Format and verification status

Project format remains v8. Projects with only primary sources encode without `mediaSources` or
`timelineSpans` for total backward compatibility. Forward format versions remain strictly rejected.

Automated Phase 4 gates were verified on 2026-09-11:

- [x] original source media is never modified or deleted when a patch is applied;
- [x] projects with one source render and map identically to pre-Patch-Take behavior;
- [x] multi-source cut boundaries remain synchronized for screen, cursor, webcam, keyboard, transcript, and audio;
- [x] preview and export use the same source-selection mapper;
- [x] missing or damaged optional patch tracks degrade without losing healthy primary display media;
- [x] Save Copy includes all referenced sources and prunes unreferenced temporary takes;
- [x] format-v8 migration and forward-version rejection remain lossless;
- [x] full `swift test` suite passed (220 tests in 6 suites, 0 failures);
- [x] `swift build -c release --arch arm64` passed for app, CLI, and benchmarks;
- [x] `git diff --check` passed with zero whitespace or formatting errors.

Manual Phase 4 gates remain:

- [ ] visual review of cross-dissolve transitions across diverse window managers and motion densities;
- [ ] real-world take capture workflow testing with active microphone, webcam, and system audio hardware;
- [ ] recording guide HUD inspection during live capture on multi-display setups.

## Next execution checkpoint

### v4 Full Plan Complete — Release Packaging and Hardware Audit

With all phases of the v4 plan (Phases 0–4: v4.0–v4.4) implemented and verified against automated gates:

1. End-to-end user workflow validation in interactive UI mode.
2. Production app bundle packaging via `./scripts/package-app.sh`.
3. macOS TCC permission flow and ScreenCaptureKit hardware verification.

## Resume checklist for an agent session

1. Read `AGENTS.md`, this file, and the relevant section of `docs/V4_PLAN.md`.
2. Inspect `git status --short`; preserve all unrelated changes.
3. Identify the current work packet and its owned files before editing.
4. Run the smallest relevant focused tests during implementation.
5. At a phase gate, run:

   ```bash
   swift test
   swift build -c release --arch arm64
   ```

6. Update this file with:
   - Completed packet and files changed.
   - Tests run and their results.
   - Known failures or manual gates.
   - The exact next packet.
7. Do not mark a checkpoint complete unless its acceptance gate in
   `docs/V4_PLAN.md` is satisfied.

## Status update rules

- Keep this file concise and current; do not duplicate the full roadmap.
- Record evidence, not optimistic completion claims.
- Distinguish implemented, automatically verified, and manually verified.
- Include the date of the most recent full test/release run when known.
- If work stops because of usage limits, leave the repository buildable and
  identify the next exact work packet.
- If a schema version changes, record the new version and migration-fixture
  status here immediately.
