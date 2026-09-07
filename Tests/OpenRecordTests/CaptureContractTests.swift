import CoreMedia
import Darwin
import Foundation
import Testing
@testable import OpenRecord

enum CaptureContractTests {
    static func runJSONLEncoding() throws {
        let cursor = CursorSample(t: 1.25, x: 640.5, y: 12, cursorId: CaptureMediaFormat.defaultCursorSpriteID)
        let click = ClickSample(t: 1.25, button: .left, down: true)
        let key = KeySample(t: 1.25, key: "c", modifiers: [.command], down: true)

        let cursorLine = try ProjectJSON.jsonlEncoder.encode(cursor)
        let clickLine = try ProjectJSON.jsonlEncoder.encode(click)
        let keyLine = try ProjectJSON.jsonlEncoder.encode(key)

        guard !cursorLine.contains(UInt8(ascii: "\n")), !clickLine.contains(UInt8(ascii: "\n")), !keyLine.contains(UInt8(ascii: "\n")) else {
            throw OpenRecordError.io("JSONL encoder emitted a newline inside a sample")
        }

        let decodedCursor = try ProjectJSON.decoder.decode(CursorSample.self, from: cursorLine)
        let decodedClick = try ProjectJSON.decoder.decode(ClickSample.self, from: clickLine)
        let decodedKey = try ProjectJSON.decoder.decode(KeySample.self, from: keyLine)
        guard decodedCursor == cursor, decodedClick == click, decodedKey == key else {
            throw OpenRecordError.io("JSONL sample round-trip produced a different value")
        }

        var fileBody = cursorLine
        fileBody.append(0x0A)
        fileBody.append(clickLine)
        fileBody.append(0x0A)
        let lines = String(data: fileBody, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? []
        guard lines.count == 2 else {
            throw OpenRecordError.io("JSONL file body did not split into two records")
        }

        guard KeyboardCapturePolicy.shouldCapture(keyCode: 8, modifiers: [.command], label: "c"),
              !KeyboardCapturePolicy.shouldCapture(keyCode: 8, modifiers: [], label: "c"),
              !KeyboardCapturePolicy.shouldCapture(keyCode: 8, modifiers: [.shift], label: "C"),
              KeyboardCapturePolicy.shouldCapture(keyCode: 36, modifiers: [], label: "Return"),
              KeyboardCapturePolicy.shouldCapture(keyCode: 122, modifiers: [], label: "F1"),
              !KeyboardCapturePolicy.shouldCapture(keyCode: 55, modifiers: [.command], label: "")
        else {
            throw OpenRecordError.io("Keyboard capture privacy policy did not match its contract")
        }
    }

    static func runPermissionSettingsURLs() throws {
        let expected: [(CapturePermissionKind, String)] = [
            (.screenRecording, "Privacy_ScreenCapture"),
            (.microphone, "Privacy_Microphone"),
            (.accessibility, "Privacy_Accessibility"),
            (.camera, "Privacy_Camera"),
        ]
        for (kind, anchor) in expected {
            guard CapturePermissions.settingsAnchor(for: kind) == anchor else {
                throw OpenRecordError.io("Unexpected System Settings anchor for \(kind.rawValue)")
            }
            let url = CapturePermissions.settingsURL(for: kind)
            guard url.scheme == "x-apple.systempreferences",
                  url.absoluteString.contains(anchor)
            else {
                throw OpenRecordError.io("Unexpected System Settings URL for \(kind.rawValue): \(url.absoluteString)")
            }
        }
        guard !CapturePermissionKind.requiredForScreenCapture.contains(.camera),
              ProjectLayout.webcamVideoURL(
                in: URL(fileURLWithPath: "/tmp/Test.openrecord")
              ).lastPathComponent == "webcam.mp4"
        else {
            throw OpenRecordError.io("optional webcam capture contract was incorrect")
        }
    }

    static func runHostTimestampAlignment() throws {
        let hostClock = CMClockGetHostTimeClock()
        let timescale: CMTimeScale = 1_000_000_000
        let hostNow = CMTime(value: 10_000_000_000, timescale: timescale)

        let onTime = CaptureHostTimestamp.alignedPresentationTime(
            sampleTime: hostNow,
            captureClock: nil,
            hostClock: hostClock,
            hostNow: hostNow
        )
        guard onTime == hostNow else {
            throw OpenRecordError.io("on-time camera PTS should keep its host timestamp")
        }

        let pipelineDelay = CMTime(value: 9_900_000_000, timescale: timescale)
        let delayed = CaptureHostTimestamp.alignedPresentationTime(
            sampleTime: pipelineDelay,
            captureClock: nil,
            hostClock: hostClock,
            hostNow: hostNow
        )
        guard delayed == pipelineDelay else {
            throw OpenRecordError.io("capture-time PTS behind the host clock should be preserved")
        }

        let jitterLead = CMTime(
            seconds: CMTimeGetSeconds(hostNow) + 0.05,
            preferredTimescale: timescale
        )
        let withinSlop = CaptureHostTimestamp.alignedPresentationTime(
            sampleTime: jitterLead,
            captureClock: nil,
            hostClock: hostClock,
            hostNow: hostNow
        )
        guard withinSlop == jitterLead else {
            throw OpenRecordError.io("small future jitter should not restamp onto host now")
        }

        let skewed = CMTime(
            seconds: CMTimeGetSeconds(hostNow) + 1.5,
            preferredTimescale: timescale
        )
        let restamped = CaptureHostTimestamp.alignedPresentationTime(
            sampleTime: skewed,
            captureClock: nil,
            hostClock: hostClock,
            hostNow: hostNow
        )
        guard restamped == hostNow else {
            throw OpenRecordError.io(
                "a camera clock that leads the host by more than \(CaptureHostTimestamp.futureSlop)s should restamp onto host now"
            )
        }

        let invalid = CaptureHostTimestamp.alignedPresentationTime(
            sampleTime: .invalid,
            captureClock: nil,
            hostClock: hostClock,
            hostNow: hostNow
        )
        guard invalid == hostNow else {
            throw OpenRecordError.io("invalid camera PTS should fall back to host now")
        }
    }

    static func runOpeningFrameSelection() throws {
        guard let beforeOrigin = CaptureHostTimestamp.openingFrameSelection(
            times: [9.0, 9.5, 10.0, 10.4],
            origin: 10
        ),
              beforeOrigin.opener == 2,
              beforeOrigin.followUp == [3]
        else {
            throw OpenRecordError.io("latest pre-origin camera frame should open the file")
        }

        guard let afterOrigin = CaptureHostTimestamp.openingFrameSelection(
            times: [10.2, 10.4, 10.6],
            origin: 10
        ),
              afterOrigin.opener == 0,
              afterOrigin.followUp == [1, 2]
        else {
            throw OpenRecordError.io("earliest post-origin camera frame should open the file")
        }

        guard let onlyBefore = CaptureHostTimestamp.openingFrameSelection(
            times: [8.0, 8.5],
            origin: 10
        ),
              onlyBefore.opener == 1,
              onlyBefore.followUp.isEmpty
        else {
            throw OpenRecordError.io("latest buffered camera frame should still open the file")
        }

        guard CaptureHostTimestamp.openingFrameSelection(times: [], origin: 10) == nil else {
            throw OpenRecordError.io("empty camera buffer should not select an opening frame")
        }
    }
}

@Test
func captureJSONLEncoding() throws {
    try CaptureContractTests.runJSONLEncoding()
}

@Test
func capturePermissionSettingsURLs() throws {
    try CaptureContractTests.runPermissionSettingsURLs()
}

@Test
func captureHostTimestampAlignment() throws {
    try CaptureContractTests.runHostTimestampAlignment()
}

@Test
func captureWebcamOpeningFrameSelection() throws {
    try CaptureContractTests.runOpeningFrameSelection()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCaptureTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCaptureContractTests()
}

@_cdecl("OpenRecordRunCaptureContractTests")
func OpenRecordRunCaptureContractTests() {
    do {
        try CaptureContractTests.runJSONLEncoding()
        try CaptureContractTests.runPermissionSettingsURLs()
        try CaptureContractTests.runHostTimestampAlignment()
        try CaptureContractTests.runOpeningFrameSelection()
        fputs("OpenRecordTests: capture JSONL + permission URL tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: capture contract tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
