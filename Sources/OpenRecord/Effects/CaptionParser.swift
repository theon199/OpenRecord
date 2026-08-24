import Foundation

/// The text formats understood by ``CaptionParser``.
public enum CaptionFileFormat: String, Sendable, Hashable {
    case srt
    case webVTT
    case auto
}

/// Parses UTF-8 SubRip (SRT) and WebVTT caption files.
///
/// Caption files in the wild are often only partly valid. The parser therefore
/// ignores malformed cues and returns every valid cue it can recover. A file
/// with no valid cues is reported as an error instead of silently producing an
/// empty caption track.
public enum CaptionParser {
    public enum Error: Swift.Error, Sendable, Equatable {
        case invalidUTF8
        case unsupportedFormat(String)
        case noValidCues(format: CaptionFileFormat)
    }

    public typealias Format = CaptionFileFormat

    /// Parses a caption file, inferring the format from its extension or
    /// (when the extension is unknown) from its first line.
    public static func parse(url: URL) throws -> [CaptionCue] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OpenRecordError.io("Could not read captions at \(url.path): \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }

        let extensionName = url.pathExtension.lowercased()
        let format: CaptionFileFormat
        switch extensionName {
        case "srt": format = .srt
        case "vtt", "webvtt": format = .webVTT
        case "": format = .auto
        default: format = .auto
        }
        return try parse(text, format: format)
    }

    /// Parses caption text using the supplied format. ``.auto`` accepts a
    /// WebVTT header and otherwise treats the input as SRT.
    public static func parse(
        _ text: String,
        format: CaptionFileFormat = .auto
    ) throws -> [CaptionCue] {
        let normalizedText = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lines = normalizedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        let resolvedFormat: CaptionFileFormat
        switch format {
        case .auto:
            resolvedFormat = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .trimmingCharacters(in: .whitespaces)
                .hasPrefix("WEBVTT") == true ? .webVTT : .srt
        case .srt, .webVTT:
            resolvedFormat = format
        }

        let cues = resolvedFormat == .webVTT
            ? parseWebVTT(lines)
            : parseSRT(lines)
        guard !cues.isEmpty else {
            throw Error.noValidCues(format: resolvedFormat)
        }
        return cues
    }

    private static func parseSRT(_ lines: [String]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var index = 0
        while index < lines.count {
            skipBlankLines(lines, index: &index)
            guard index < lines.count else { break }

            // A SubRip identifier is optional and occupies the line before
            // the timing line. It is intentionally not retained by CaptionCue.
            var timingIndex = index
            if parseTimingLine(lines[index]) == nil {
                timingIndex += 1
            }
            guard timingIndex < lines.count,
                  let timing = parseTimingLine(lines[timingIndex]) else {
                skipBlock(lines, index: &index)
                continue
            }

            index = timingIndex + 1
            let textStart = index
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            let cueText = joinedCueText(lines[textStart..<index])
            if let cue = makeCue(timing: timing, text: cueText) {
                cues.append(cue)
            }
        }
        return cues
    }

    private static func parseWebVTT(_ lines: [String]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var index = 0
        skipBlankLines(lines, index: &index)
        guard index < lines.count,
              lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") else {
            return []
        }
        index += 1

        while index < lines.count {
            skipBlankLines(lines, index: &index)
            guard index < lines.count else { break }

            // Header metadata, NOTE, STYLE, and REGION blocks end at a blank
            // line and must not be mistaken for cue identifiers.
            let marker = lines[index].trimmingCharacters(in: .whitespaces)
            if marker == "NOTE" || marker.hasPrefix("NOTE ")
                || marker == "STYLE" || marker == "REGION" {
                skipBlock(lines, index: &index)
                continue
            }

            var timingIndex = index
            if parseTimingLine(lines[index]) == nil {
                timingIndex += 1
            }
            guard timingIndex < lines.count,
                  let timing = parseTimingLine(lines[timingIndex]) else {
                skipBlock(lines, index: &index)
                continue
            }

            index = timingIndex + 1
            let textStart = index
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            let cueText = joinedCueText(lines[textStart..<index])
            if let cue = makeCue(timing: timing, text: cueText) {
                cues.append(cue)
            }
        }
        return cues
    }

    private static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let pieces = line.components(separatedBy: "-->")
        guard pieces.count == 2 else { return nil }
        let start = parseTimestamp(pieces[0].trimmingCharacters(in: .whitespaces))
        let endToken = pieces[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let start, let end = parseTimestamp(endToken), end > start else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let hours: Double
        let minutes: Double
        let seconds: Double
        if fields.count == 3 {
            let secondsField = String(fields[2]).replacingOccurrences(of: ",", with: ".")
            guard let h = Double(fields[0]), let m = Double(fields[1]), let s = Double(secondsField) else {
                return nil
            }
            hours = h
            minutes = m
            seconds = s
        } else {
            let secondsField = String(fields[1]).replacingOccurrences(of: ",", with: ".")
            guard let m = Double(fields[0]), let s = Double(secondsField) else { return nil }
            hours = 0
            minutes = m
            seconds = s
        }
        guard hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60,
              hours.isFinite, minutes.isFinite, seconds.isFinite else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func makeCue(
        timing: (start: TimeInterval, end: TimeInterval),
        text: String
    ) -> CaptionCue? {
        guard !text.isEmpty else { return nil }
        return CaptionCue(start: timing.start, end: timing.end, text: text)
    }

    private static func joinedCueText<S: Sequence>(_ lines: S) -> String where S.Element == String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipBlankLines(_ lines: [String], index: inout Int) {
        while index < lines.count,
              lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
    }

    private static func skipBlock(_ lines: [String], index: inout Int) {
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index += 1
        }
    }
}

extension CaptionParser.Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Caption file is not valid UTF-8"
        case .unsupportedFormat(let value):
            return "Unsupported caption format: \(value)"
        case .noValidCues(let format):
            return "Caption file contains no valid \(format == .webVTT ? "WebVTT" : "SRT") cues"
        }
    }
}
