# OpenRecord v3 Autonomous Execution Checkpoints

This file is the execution companion to [`V3_PLAN.md`](V3_PLAN.md). The detailed feature scope stays in the main plan; this file defines the few points where an autonomous implementation agent should stop and verify that the foundation is sound before continuing.

> **Implementation status (v3.2.0):** Checkpoints 1–4 are implemented. The
> deterministic release gates and the remaining hardware-only evidence are
> tracked in [`V3_RELEASE_CHECKLIST.md`](V3_RELEASE_CHECKLIST.md).

The goal is to minimize interruptions. Do not stop between individual features just to request approval.

## Agent execution rule

When instructed to run to a checkpoint:

1. Work through all applicable items in `V3_PLAN.md` up to that checkpoint without asking for confirmation between tasks.
2. Make reasonable implementation decisions that are already constrained by the plan and existing architecture.
3. Add or update tests with the implementation rather than deferring hardening.
4. Fix failures found by automated tests before declaring the checkpoint complete.
5. Stop early only when progress genuinely requires user interaction or hardware that the agent cannot provide, such as macOS permission prompts, physical camera/device testing, signing credentials, or an unresolved product decision not answered by the plan.
6. At the checkpoint, report what shipped, tests run, remaining known issues, and any manual checks that still need a person.

A checkpoint is a verification boundary, not a request-for-approval boundary. If all automated conditions pass, the implementation is considered ready for the next autonomous run.

---

# Checkpoint 1 — Timing foundation

Complete before transcript-based deletion, silence removal, or other features begin depending on multi-cut behavior.

## Scope

- Design and implement the unified output-time → edit-decision → speed → source-time mapping.
- Add the non-destructive multi-cut/edit-decision model.
- Route display, audio, webcam, cursor, keyboard, captions, zooms, annotations, and export through the authoritative mapping where applicable.
- Add document migration/round-trip support required by the new model.
- Do not reuse an already-current project format number. The existing app already describes its current project document as format v3; if the document contract changes incompatibly, use the next appropriate format version.

## Pass conditions

- Multi-cut mapping tests cover start/end boundaries, adjacent cuts, multiple cuts, trim interaction, and speed regions.
- Existing tracks remain synchronized across cuts and speed changes.
- Preview-facing and export-facing timestamp mapping agree on deterministic fixtures.
- Old supported project fixtures still open according to migration policy and new-format projects round-trip safely.
- Full automated test suite passes.

If these conditions pass, no user review is required before beginning the rest of v3.0.

---

# Checkpoint 2 — v3.0 smart editing

Complete the v3.0 scope from `V3_PLAN.md` after Checkpoint 1 passes.

## Scope

- On-device transcription storage and generation.
- Transcript panel and transcript-assisted navigation/editing.
- Non-destructive transcript cuts.
- Silence/pause suggestions and accepted-cut workflow.
- Improved auto-zoom intelligence.
- Cursor visibility/emphasis ranges.
- Multi-select, copy/paste/duplicate, snapping, and keyboard editing.
- Reusable local presets that belong in v3.0.

## Pass conditions

- Core transcription works without a required account, network service, or cloud API.
- Transcript timestamps survive save/reopen and remain independent from manual text corrections.
- Transcript and silence-based cuts use the unified mapping rather than introducing separate timing logic.
- Undo/redo behaves intentionally for generated cuts and editor productivity operations.
- Existing preview/export synchronization tests remain green.
- New transcription, silence, auto-zoom, cursor-timing, and editor-operation tests pass.
- Full automated test suite passes.

Manual speech-quality judgment can be recorded as follow-up evidence; it should not block autonomous implementation when deterministic behavior is correct.

---

# Checkpoint 3 — v3.1 visual stack

Complete the v3.1 scope after Checkpoint 2 passes.

## Scope

- Blur/redaction regions.
- Freehand drawing.
- Richer annotations.
- Device frames.
- Webcam expansion and keyframes if justified by the main plan.
- Advanced local audio polish selected for v3.1.

## Pass conditions

- New timed visual items use the shared timeline/time-mapping infrastructure.
- Direct manipulation is undo-safe and does not create separate preview-only geometry logic.
- Preview/export golden coverage exists for blur/redaction, drawing, device frames, and any new webcam behavior.
- Serialization/round-trip tests cover new project fields.
- Audio changes remain non-destructive and do not desynchronize output timing.
- Full automated test suite passes.

Subjective styling tweaks do not require a stop unless the plan leaves a product choice genuinely unresolved.

---

# Checkpoint 4 — v3.2 and v3 completion

Complete the remaining v3.2 workflow scope and bring the repository to release-candidate condition.

## Scope

- Project templates.
- Improved batch queue/workflow.
- Capture expansion that is practical without weakening normal desktop capture.
- Local CLI/automation features.
- Optional extension work only if justified by the main plan and real implementation need.
- Documentation, migration notes, release notes, and final regression coverage.

## Automated pass conditions

- Template and project portability/migration tests pass.
- Batch jobs handle failure/retry without corrupting other jobs.
- CLI/automation paths preserve normal `.openrecord` ownership and project semantics.
- Build, test, package, and deterministic regression suites are green.
- No known data-loss or track-desynchronization bug remains in supported automated scenarios.
- Documentation matches the implemented behavior.

## Manual stop conditions

At this checkpoint, stop for a person only for checks that cannot be honestly automated, such as:

- Real screen/window capture soak tests.
- Camera, microphone, external-device, or iPhone hardware verification.
- macOS permission-prompt flows.
- Final signing/notarization/release credentials.
- Final subjective UX review if desired.

The agent should leave a concrete checklist of only those remaining manual items rather than asking for broad approval.

---

# Autonomous run sequence

Use these as the default handoff boundaries:

```text
Run 1 → Checkpoint 1: timing foundation
Run 2 → Checkpoint 2: complete v3.0
Run 3 → Checkpoint 3: complete v3.1
Run 4 → Checkpoint 4: complete v3.2 + release-candidate automation
```

This intentionally avoids a checkpoint for every feature. The only early checkpoint is the timing architecture because errors there would propagate through almost every later v3 feature. The other checkpoints align with the existing v3.0, v3.1, and v3.2 release boundaries.
