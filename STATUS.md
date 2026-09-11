# OpenRecord Status

Last updated: 2026-09-10

This is the repository's single current-status entry point. Detailed product
scope remains in the version plans; this file records what is implemented, what
has been verified, what remains manual, and the next safe execution checkpoint.

## At a glance

| Area | Status |
|---|---|
| Current implemented product line | v3.2.1 / v4.0 foundation |
| Current project document format | v7 |
| v3 implementation checkpoints | Complete |
| v3 deterministic automated release gates | Recorded complete |
| Final v3 release/tag/push artifacts | Pending |
| Hardware and permission-flow evidence | Pending/recommended |
| v4 product and architecture plan | Complete |
| v4.0 / Phase 0 implementation | Complete (verified) |
| Next v4 checkpoint | Phase 1 (v4.1) — ActionMap |

## Current baseline

The repository currently describes OpenRecord v3.2.1 as implemented and Phase 0 (v4.0 Interaction Foundation) as verified. Its main capabilities include:

- Native ScreenCaptureKit display/window capture with separate cursor telemetry.
- Optional microphone, system audio, webcam, and privacy-filtered shortcut tracks.
- Transparent `.openrecord` bundles with raw media, JSONL telemetry,
  `meta.json`, `project.json`, and optional rebuildable `analysis/` sidecars.
- One authoritative output-time to source-time mapping across trim, cuts, and
  speed regions.
- Shared pure `FrameScene` and `FrameRenderService` for video, GIF, and snapshot export.
- On-device transcription, transcript-assisted editing, pause suggestions, and
  cancellation-safe smart automatic zooms.
- Non-destructive captions, annotations, drawings, redactions, cursor effects,
  webcam treatments, device frames, and audio cleanup.
- Project templates, selected-project batch export, imported movie projects,
  decoupled permissions, and local CLI inspection/validation/export.

The canonical v3 status and release evidence live in:

- [`docs/V3_EXECUTION_CHECKPOINTS.md`](docs/V3_EXECUTION_CHECKPOINTS.md)
- [`docs/V3_RELEASE_CHECKLIST.md`](docs/V3_RELEASE_CHECKLIST.md)
- [`docs/V3_RELEASE_NOTES.md`](docs/V3_RELEASE_NOTES.md)
- [`docs/PROJECT_FORMAT_V7.md`](docs/PROJECT_FORMAT_V7.md)

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

The working tree contains the implemented Phase 4.0 / Phase 0 foundation changes
across capture, export, contracts, editor, and tests. All automated gates pass cleanly.

Treat all pre-existing modifications as user work:

- Do not reset, discard, or overwrite unrelated changes.
- Inspect `git status --short` and the relevant diffs before implementation.
- Preserve project format v7 compatibility until Phase 1.3 explicitly adopts format v8.

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

Phase 0 (v4.0 Interaction Foundation) implementation and deterministic verification
are complete. Project document format remains v7.

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

## Next execution checkpoint

### Phase 1 — v4.1: ActionMap

With the interaction foundation (Phase 0) complete and verified, the next checkpoint begins Phase 1 from `docs/V4_PLAN.md`:

1. **1.1 Privacy-filtered semantic capture**:
   - Introduce `recording/target.jsonl` semantic event streams using Accessibility where reliable.
   - Vision-based local fallback for focus and element recognition.
   - Strict privacy redaction filtering on captured text and inputs.
2. **1.2 Action recognition and OCR sidecars**:
   - Implement background analyzers outputting `analysis/actions.jsonl` and `analysis/ocr.jsonl`.
   - Index actions by stable evidence IDs and correlate with timeline timestamps.
3. **1.3 Format v8 adoption for authored story beats**:
   - Define format v8 schema for `storyBeats`, user-confirmed action ranges, and suggestion provenance.
   - Implement v7 -> v8 upgrade path with full migration fixture coverage.

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
