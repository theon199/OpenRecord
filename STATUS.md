# OpenRecord Status

Last updated: 2026-09-10

This is the repository's single current-status entry point. Detailed product
scope remains in the version plans; this file records what is implemented, what
has been verified, what remains manual, and the next safe execution checkpoint.

## At a glance

| Area | Status |
|---|---|
| Current implemented product line | v3.2.1 |
| Current project document format | v7 |
| v3 implementation checkpoints | Complete |
| v3 deterministic automated release gates | Recorded complete |
| Final v3 release/tag/push artifacts | Pending |
| Hardware and permission-flow evidence | Pending/recommended |
| v4 product and architecture plan | Complete |
| v4 implementation | Not started as a coordinated phase |
| Next v4 checkpoint | Phase 0 — interaction foundation |

## Current baseline

The repository currently describes OpenRecord v3.2.1 as implemented. Its main
capabilities include:

- Native ScreenCaptureKit display/window capture with separate cursor telemetry.
- Optional microphone, system audio, webcam, and privacy-filtered shortcut tracks.
- Transparent `.openrecord` bundles with raw media, JSONL telemetry,
  `meta.json`, and `project.json`.
- One authoritative output-time to source-time mapping across trim, cuts, and
  speed regions.
- On-device transcription, transcript-assisted editing, pause suggestions, and
  smart automatic zooms.
- Non-destructive captions, annotations, drawings, redactions, cursor effects,
  webcam treatments, device frames, and audio cleanup.
- Project templates, selected-project batch export, imported movie projects,
  and local CLI inspection/validation/export.
- Video, GIF, mixed-audio, snapshot, and source-footage export paths.

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

The working tree is under active development and currently contains uncommitted
changes across capture, export, automation, editor, contracts, and tests, plus
the new v4 plan and this status file.

Treat all pre-existing modifications as user work:

- Do not reset, discard, or overwrite unrelated changes.
- Inspect `git status --short` and the relevant diffs before implementation.
- Do not assume the uncommitted code has passed the recorded v3 release gates.
- Re-establish a fresh verification snapshot before declaring another release
  or v4 checkpoint complete.

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

No coordinated v4 phase should be considered started merely because an
individual supporting change exists in the working tree. A phase starts when
its contract packet, acceptance criteria, and focused tests are explicitly
adopted.

## Next execution checkpoint

### Phase 0 — Interaction foundation

Before ActionMap, First Cut, or Patch Takes, establish these foundations:

1. Define the optional, rebuildable `analysis/` sidecar contract.
2. Harden JSONL recovery and bounded-memory telemetry access.
3. Introduce the shared value-based `FrameScene` incrementally.
4. Consolidate alternate frame-export paths around the same scene resolver.
5. Decouple library/imported-project access from capture-only permissions.
6. Add explicit microphone and system-audio recording choices.

The first recommended work packet is the **analysis-sidecar contract packet**:

- Add `ProjectLayout` paths for `analysis/`.
- Define `AnalysisManifest` and stable evidence identifiers.
- Specify fingerprints, schema versions, completion state, and invalidation.
- Add malformed/future/stale sidecar fixtures.
- Confirm that missing analysis never blocks project open, save, or export.
- Keep `project.json` at format v7 during this packet.

Do not begin semantic capture or bump to format v8 until this contract is tested
and the current working tree has a known verification baseline.

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
