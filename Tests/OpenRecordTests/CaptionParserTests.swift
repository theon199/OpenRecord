import Darwin
import Foundation
import OpenRecord
import Testing

enum CaptionParserTests {
    static func run() throws {
        try parsesSRTWithCRLFIdentifiersMillisecondsAndUnicode()
        try parsesWebVTTWithSettingsAndMultilineText()
        try skipsMalformedCuesAndReportsEmptyInput()
        try parsesUTF8FileAndInfersFormat()
    }

    static func parsesSRTWithCRLFIdentifiersMillisecondsAndUnicode() throws {
        let source = """
        7\r
        00:00:01,250 --> 00:00:03.500\r
        Hello, 世界\r
        second line\r
        \r
        00:00:04.000 --> 00:00:05.125\r
        café\r
        """
        let cues = try CaptionParser.parse(source, format: .srt)
        guard cues.count == 2,
              cues[0].start == 1.25,
              cues[0].end == 3.5,
              cues[0].text == "Hello, 世界\nsecond line",
              cues[1].start == 4,
              cues[1].end == 5.125,
              cues[1].text == "café"
        else {
            throw OpenRecordError.io("SRT parser did not preserve timestamps, line breaks, or Unicode")
        }
    }

    static func parsesWebVTTWithSettingsAndMultilineText() throws {
        let source = """
        WEBVTT - OpenRecord demo

        NOTE
        Ignored author note

        cue-1
        01:02.100 --> 01:04.900 align:center position:50%
        <b>Welcome</b> 👋
        to the demo

        """
        let cues = try CaptionParser.parse(source, format: .webVTT)
        guard cues.count == 1,
              cues[0].start == 62.1,
              cues[0].end == 64.9,
              cues[0].text == "<b>Welcome</b> 👋\nto the demo"
        else {
            throw OpenRecordError.io("WebVTT parser did not support cue settings or multiline text")
        }
    }

    static func skipsMalformedCuesAndReportsEmptyInput() throws {
        let source = """
        this cue has no timing
        and is ignored

        00:00:02,000 --> 00:00:01,000
        reversed timestamps

        00:00:03,000 --> 00:00:04,000
        valid cue
        """
        let cues = try CaptionParser.parse(source, format: .srt)
        guard cues.count == 1, cues[0].text == "valid cue" else {
            throw OpenRecordError.io("Malformed caption cues were not skipped")
        }

        do {
            _ = try CaptionParser.parse("WEBVTT\n\nnot a cue", format: .webVTT)
            throw OpenRecordError.io("An input with no valid cues did not fail")
        } catch CaptionParser.Error.noValidCues(format: .webVTT) {
            // Expected: callers can distinguish an empty/malformed track.
        }
    }

    static func parsesUTF8FileAndInfersFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRecord-caption-\(UUID().uuidString).vtt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nfile cue\n".utf8).write(to: url)
        let cues = try CaptionParser.parse(url: url)
        guard cues.count == 1, cues[0].text == "file cue" else {
            throw OpenRecordError.io("Caption URL parsing did not infer WebVTT")
        }
    }
}

@Test
func captionParserContracts() throws {
    try CaptionParserTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCaptionParserTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCaptionParserTests()
}

@_cdecl("OpenRecordRunCaptionParserTests")
func OpenRecordRunCaptionParserTests() {
    do {
        try CaptionParserTests.run()
        fputs("OpenRecordTests: caption parser tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: caption parser tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
