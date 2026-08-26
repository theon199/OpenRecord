# OpenRecord v2.5.0 release checklist

This checklist is the release record for v2.5.0. Implementation Phases 1–8
are complete, but the version remains unreleased until the deterministic gates
are green and the hardware/manual gates below have evidence. Empty checkboxes
are intentional: this document does not claim that a manual check has passed.

## Release identity

- Version: `2.5.0`
- Build: `250`
- Baseline: macOS 15 or later, Apple Silicon (`arm64`)
- Release commit: `______________________________`
- Release owner/date: `______________________________`

## Deterministic automated gates

These gates run without capture permissions or physical camera/display/audio
hardware. Run the default verifier from a clean release checkout:

```bash
./scripts/verify-v2_5-release.sh
```

The verifier checks metadata consistency, runs the complete Swift test suite,
builds release, packages an ad-hoc Apple Silicon app, verifies its signature,
executable architecture, and `Info.plist`, then runs the short deterministic
benchmark smoke. It retains benchmark reports and generated source/output
artifacts under `.build/openrecord-v2_5-release/`.

For the performance gate on a reference M2-class machine, opt in explicitly:

```bash
./scripts/verify-v2_5-release.sh --full-benchmark
```

The full synthetic 300-second 1080p benchmark is a release measurement and
passes only when `totalExportSeconds < 180`. Record the report and machine
details in the evidence log; do not infer hardware/manual capture coverage
from this benchmark.

CI runs the build, test, and package steps in separate workflow steps and then
invokes the verifier's `--static-only` mode. That mode validates the already
packaged app and metadata without repeating those expensive steps.

| Gate | Command/evidence | Result |
|---|---|---|
| Version source and bundle metadata agree | verifier output; `OpenRecordInfo.swift`, `Resources/Info.plist` | [ ] |
| Full Swift tests | `swift test` output | [ ] |
| Release build | `swift build -c release` output | [ ] |
| Ad-hoc package and signature | `dist/OpenRecord.app`; `codesign --verify` output | [ ] |
| Executable is Apple Silicon | `file`/`lipo -archs` output | [ ] |
| Short deterministic export smoke | `.build/openrecord-v2_5-release/smoke-report.json` | [ ] |
| 5-minute benchmark target | `.build/openrecord-v2_5-release/full-report.json`, `<180s` | [ ] |
| CI build/test/package/static verification | CI run URL and artifact | [ ] |

## Hardware and manual release matrix

Perform these checks on real supported hardware. “Short” means a normal
representative recording long enough to exercise the workflow; the soak rows
are actual wall-clock captures, not accelerated unit-test profiles.

| ID | Area | Minimum check | Duration | Result |
|---|---|---|---:|---|
| M01 | Display capture | 1080p display capture | Short | [ ] |
| M02 | Display capture | 4K display capture | Short | [ ] |
| M03 | Display capture | 1080p display + mic + system audio | 1 hour | [ ] |
| M04 | Display capture | 4K display + mic + system audio with representative motion | 1 hour | [ ] |
| M05 | Window capture | Move and resize the captured window during recording | Short | [ ] |
| M06 | Audio | Microphone only | Short | [ ] |
| M07 | Audio | System audio only | Short | [ ] |
| M08 | Audio | Microphone and system audio together | Short | [ ] |
| M09 | Webcam | On/off; circle and rounded rectangle; move and resize directly in preview | Short | [ ] |
| M10 | Webcam | Webcam + display + mic + system audio sync through the end | 1 hour | [ ] |
| M11 | Speed | Adjacent regions including 0.25× and 4× | Short | [ ] |
| M12 | Captions | Import and edit both SRT and WebVTT | Short | [ ] |
| M13 | Export | H.264 MP4 | Short | [ ] |
| M14 | Export | HEVC MP4 | Short | [ ] |
| M15 | Export | ProRes 422 MOV | Short | [ ] |
| M16 | Export | Animated GIF | Short | [ ] |
| M17 | Export | Mixed-audio M4A | Short | [ ] |
| M18 | Export | Playhead PNG | Short | [ ] |
| M19 | Recovery | Forced stop/interruption with usable display media leaves a recovered project and warning | Short | [ ] |
| M20 | Migration | Representative v1 project opens and follows migration policy | Short | [ ] |
| M21 | Migration | Representative v2 project opens and follows migration policy | Short | [ ] |
| M22 | Migration | Representative v3 project opens and round-trips | Short | [ ] |

### Actual capture-soak coverage

Run all six profiles. During the sessions exercise frame pacing, pointer
motion, window movement/resizing, idle intervals, sustained motion, and the
listed telemetry/webcam combinations. Keep the resulting `.openrecord` bundle,
diagnostics, and exported reference evidence.

| ID | Duration | Target | Mic + system | Webcam | Keyboard telemetry | During capture | Result |
|---|---:|---|---|---|---|---|---|
| S01 | 30 minutes | Display | Both | Off | On | Change frame pacing; move pointer continuously | [ ] |
| S02 | 30 minutes | Window | Both | On | Off | Move and resize the window | [ ] |
| S03 | 1 hour | Display | Both | On | On | Long quiet and active intervals | [ ] |
| S04 | 1 hour | Window | Both | On | On | Move/resize; briefly cover and uncover window | [ ] |
| S05 | 2 hours | Display | Both | On | Off | VFR-like idle periods and sustained motion | [ ] |
| S06 | 2 hours | Window | Both | Off | On | Move/resize throughout the session | [ ] |

For each soak bundle verify that display media plays through its end,
`meta.json.captureDiagnostics.referenceDuration` matches the display track,
track states are meaningful (`complete`, `missing`, `truncated`, or
`notRequested`), offsets and end drift are finite, corrections occur only
above the 100 ms tolerance, and preview/export align at the start, midpoint,
and final minute.

### Interruption and failure checks

Run each on a disposable project and preserve the original media. A usable
display track must recover as a project with a specific warning; optional-track
failure must not discard it.

| ID | Failure | Result |
|---|---|---|
| R01 | Low disk space approaching the guardrail | [ ] |
| R02 | Sleep or display detach during capture | [ ] |
| R03 | Captured window closes during capture | [ ] |
| R04 | Camera disconnects/becomes unavailable | [ ] |
| R05 | Microphone device changes | [ ] |
| R06 | Screen/microphone/camera permission is revoked while running | [ ] |

## Evidence record

Complete one record for every manual row and every soak/interruption row. Do
not mark a row complete without a durable artifact or an explicit, dated note.

```text
Evidence ID(s):
Machine/model (including chip and memory):
OS version:
App version/build:
Date/time and operator:
Project/bundle path or artifact ID:
Diagnostics path or pasted diagnostic ID:
Export/reference artifacts (paths or artifact IDs):
Result (pass/fail/blocked):
Notes, warnings, drift, and recovery details:
```

## Sign-off

- [ ] All deterministic automated gates pass on the release commit.
- [ ] All hardware/manual matrix rows have evidence and a recorded result.
- [ ] No unresolved data-loss or release-blocking regression remains.
- [ ] Release owner confirms the checklist is complete.
- [ ] Only after the preceding items: tag/publish `v2.5.0`.
