import Darwin
import Foundation
import Testing
import OpenRecord

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
        fputs("OpenRecordTests: capture JSONL + permission URL tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: capture contract tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
