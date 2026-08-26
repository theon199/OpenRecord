# Phase 7 release-candidate capture soak protocol

These are hardware-dependent Phase 7 release-candidate checks. The unit-test
counterpart in `CaptureSoakTests.swift` accelerates the same 30-minute,
1-hour, and 2-hour timing profiles without sleeping or requesting capture
permissions; passing it is not a substitute for the actual wall-clock
captures below.

Record every run in the evidence fields and manual matrix in
[`docs/V2_5_RELEASE_CHECKLIST.md`](../../../../docs/V2_5_RELEASE_CHECKLIST.md).
Do not mark a row passed until the `.openrecord` bundle, diagnostics, and
reference exports have been retained.

For each duration, retain the `.openrecord` bundle and record whether capture
stopped normally or recovered:

| Duration | Target | Mic + system audio | Webcam | Keyboard telemetry | During capture |
|---|---|---|---|---|---|
| 30 min | Display | Both | Off | On | Change frame pacing; move the pointer continuously |
| 30 min | Window | Both | On | Off | Move and resize the window |
| 1 hour | Display | Both | On | On | Exercise long quiet and active intervals |
| 1 hour | Window | Both | On | On | Move/resize; briefly cover and uncover the window |
| 2 hours | Display | Both | On | Off | Include VFR-like idle periods and sustained motion |
| 2 hours | Window | Both | Off | On | Move/resize throughout the session |

For each bundle, verify:

- `recording/display.mp4` is playable through its end.
- `meta.json.captureDiagnostics.referenceDuration` matches the display track.
- Requested tracks report `complete`, `missing`, or `truncated`; disabled webcam reports `notRequested`.
- Initial offsets and end drift are finite.
- A correction exists only when absolute end drift is greater than 100 ms.
- Preview and export remain aligned at the start, midpoint, and final minute.

Run separate interruption checks for low disk, sleep/display detach, captured
window closure, camera disconnect, microphone device change, and permission
revocation. A usable display track must leave a recovered project with a
specific warning; optional-track failures must not discard it. Originals must
remain unchanged after any synchronization correction.
