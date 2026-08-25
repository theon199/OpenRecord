# Phase 3 capture soak matrix

These are hardware-dependent release checks. The unit-test counterpart in
`CaptureSoakTests.swift` accelerates the same 30-minute, 1-hour, and 2-hour
timing profiles without sleeping or requesting capture permissions.

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

For each successful bundle, verify:

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
