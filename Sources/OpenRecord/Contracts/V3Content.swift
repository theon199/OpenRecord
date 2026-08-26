import Foundation

/// The recording track from which a transcript was recognized.
public enum TranscriptSource: String, Codable, Sendable, Hashable, CaseIterable {
    case microphone
    case systemAudio
    case mixed
}

/// A source-timed piece of recognized speech.  Recognition and correction are
/// deliberately separate: changing `editedText` never changes the source
/// timestamps used by the editor and exporter.
public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var recognizedText: String
    public var editedText: String?
    public var confidence: Double?
    public var source: TranscriptSource

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        recognizedText: String,
        editedText: String? = nil,
        confidence: Double? = nil,
        source: TranscriptSource = .microphone
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.recognizedText = recognizedText
        self.editedText = editedText
        self.confidence = confidence
        self.source = source
    }

    public var displayText: String {
        editedText ?? recognizedText
    }

    public var normalized: TranscriptSegment {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start) : value.start
        value.recognizedText = value.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        value.editedText = value.editedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.editedText?.isEmpty == true { value.editedText = nil }
        if let confidence = value.confidence {
            value.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : nil
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, recognizedText, editedText, confidence, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        editedText = try container.decodeIfPresent(String.self, forKey: .editedText)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        // Unknown values are retained on disk and rejected by the atomic
        // persistence scanner; decoding remains safe for read-only inspection.
        source = (try? container.decode(TranscriptSource.self, forKey: .source)) ?? .microphone
    }
}

/// A time-ranged, non-destructive cursor treatment.
public struct CursorEffectRange: Codable, Sendable, Hashable, Identifiable {
    public static let scaleRange = 0.1...3.0

    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var visible: Bool
    public var scale: Double
    public var clickEmphasis: Bool
    public var halo: Bool

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        visible: Bool = true,
        scale: Double = 1,
        clickEmphasis: Bool = false,
        halo: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.visible = visible
        self.scale = scale
        self.clickEmphasis = clickEmphasis
        self.halo = halo
    }

    public var normalized: CursorEffectRange {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        if value.end == .infinity {
            value.end = TimeInterval.greatestFiniteMagnitude
        } else {
            value.end = value.end.isFinite ? max(value.end, value.start) : value.start
        }
        value.scale = value.scale.isFinite
            ? min(max(value.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            : 1
        return value
    }
}
