import Foundation
import AVFoundation

#if canImport(Speech)
import Speech
#endif

/// A request for a local transcription operation.  The request deliberately
/// contains a local file URL only; no provider is given credentials or a
/// network client.
public struct TranscriptionRequest: Sendable, Hashable {
    public var audioURL: URL?
    public var source: TranscriptSource
    /// Offset from the audio file's clock to the project's source clock.
    public var trackOffset: TimeInterval
    public var localeIdentifier: String?
    public var minimumSegmentDuration: TimeInterval

    public init(
        audioURL: URL? = nil,
        source: TranscriptSource,
        trackOffset: TimeInterval = 0,
        localeIdentifier: String? = nil,
        minimumSegmentDuration: TimeInterval = 0.05
    ) {
        self.audioURL = audioURL
        self.source = source
        self.trackOffset = trackOffset.isFinite ? trackOffset : 0
        self.localeIdentifier = localeIdentifier
        self.minimumSegmentDuration = minimumSegmentDuration.isFinite
            ? max(minimumSegmentDuration, 0)
            : 0.05
    }
}

public enum TranscriptionError: Error, LocalizedError, Sendable, Equatable {
    case missingAudioURL
    case invalidAudioURL
    case onDeviceRecognitionUnavailable(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudioURL: "A local audio file is required for transcription."
        case .invalidAudioURL: "The transcription audio URL is not a local file."
        case .onDeviceRecognitionUnavailable(let reason):
            "On-device speech recognition is unavailable: \(reason)"
        case .recognitionFailed(let reason): "Speech recognition failed: \(reason)"
        }
    }
}

/// Provider-neutral transcription boundary.  Implementations may use Apple
/// Speech or a future bundled local model, but the core workflow remains
/// asynchronous, Sendable, and account-free.
public protocol TranscriptionProvider: Sendable {
    func transcribe(request: TranscriptionRequest) async throws -> [TranscriptSegment]
}

/// The provider-neutral representation used by deterministic tests and by
/// adapters around recognition SDKs.
public struct RecognizedTranscriptFragment: Sendable, Hashable {
    public var start: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var confidence: Double?
    public var source: TranscriptSource

    public init(
        start: TimeInterval,
        duration: TimeInterval,
        text: String,
        confidence: Double? = nil,
        source: TranscriptSource
    ) {
        self.start = start
        self.duration = duration
        self.text = text
        self.confidence = confidence
        self.source = source
    }

    public init(
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double? = nil,
        source: TranscriptSource
    ) {
        self.init(
            start: start,
            duration: end - start,
            text: text,
            confidence: confidence,
            source: source
        )
    }
}

/// Stable phrase segmentation and clock normalization for recognition output.
public enum TranscriptionNormalizer {
    public static func normalize(
        fragments: [RecognizedTranscriptFragment],
        trackOffset: TimeInterval = 0,
        minimumSegmentDuration: TimeInterval = 0.05
    ) -> [TranscriptSegment] {
        normalize(
            fragments,
            trackOffset: trackOffset,
            minimumSegmentDuration: minimumSegmentDuration
        )
    }

    public static func normalize(
        _ fragments: [RecognizedTranscriptFragment],
        trackOffset: TimeInterval = 0,
        minimumSegmentDuration: TimeInterval = 0.05
    ) -> [TranscriptSegment] {
        let offset = trackOffset.isFinite ? trackOffset : 0
        let minimum = minimumSegmentDuration.isFinite
            ? max(minimumSegmentDuration, 0)
            : 0.05

        return fragments.enumerated().compactMap { index, fragment in
            let rawStart = fragment.start.isFinite ? fragment.start + offset : 0
            let start = max(rawStart, 0)
            let rawDuration = fragment.duration.isFinite ? fragment.duration : 0
            let end = start + max(rawDuration, minimum)
            let text = normalizedText(fragment.text)
            guard !text.isEmpty, end > start else { return nil }
            return TranscriptSegment(
                id: stableID(index: index, start: start, end: end, text: text, source: fragment.source),
                start: start,
                end: end,
                recognizedText: text,
                editedText: nil,
                confidence: normalizedConfidence(fragment.confidence),
                source: fragment.source
            )
        }
        .sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Normalizes already-created segments while preserving their IDs and
    /// manual corrections.  This is useful when loading a sidecar or merging
    /// a provider's results into an existing document.
    public static func normalize(
        _ segments: [TranscriptSegment],
        trackOffset: TimeInterval = 0,
        minimumSegmentDuration: TimeInterval = 0.05
    ) -> [TranscriptSegment] {
        let offset = trackOffset.isFinite ? trackOffset : 0
        let minimum = minimumSegmentDuration.isFinite
            ? max(minimumSegmentDuration, 0)
            : 0.05
        return segments.compactMap { raw in
            let start = max(raw.start.isFinite ? raw.start + offset : 0, 0)
            let candidateEnd = raw.end.isFinite ? raw.end + offset : start + minimum
            let end = max(candidateEnd, start + minimum)
            guard end > start else { return nil }
            var segment = raw
            segment.start = max(start, 0)
            segment.end = max(end, segment.start)
            return segment
        }
        .sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.split { $0.isWhitespace || $0.isNewline }.joined(separator: " ")
    }

    private static func normalizedConfidence(_ confidence: Double?) -> Double? {
        guard let confidence, confidence.isFinite else { return nil }
        return min(max(confidence, 0), 1)
    }

    private static func stableID(
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        source: TranscriptSource
    ) -> UUID {
        // UUID v5 is unavailable in Foundation's public API.  A deterministic
        // UUID assembled from a SHA-free FNV-1a stream is sufficient here and
        // keeps project fixtures stable across launches.
        let key = "\(index)|\(start)|\(end)|\(source)|\(text)"
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((hash >> UInt64(i * 8)) & 0xff) }
        var second = hash ^ 0x9e3779b97f4a7c15
        for i in 0..<8 {
            second = (second &* 2862933555777941757) &+ 3037000493
            bytes[8 + i] = UInt8((second >> 56) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct CaptionGenerationOptions: Sendable, Hashable {
    public var maximumCharacters: Int
    public var maximumDuration: TimeInterval
    public var minimumDuration: TimeInterval
    public var punctuationBreaks: Bool

    public init(
        maximumCharacters: Int = 42,
        maximumDuration: TimeInterval = 4,
        minimumDuration: TimeInterval = 0.25,
        punctuationBreaks: Bool = true
    ) {
        self.maximumCharacters = max(maximumCharacters, 1)
        self.maximumDuration = max(maximumDuration.isFinite ? maximumDuration : 4, 0.05)
        self.minimumDuration = max(minimumDuration.isFinite ? minimumDuration : 0.25, 0.05)
        self.punctuationBreaks = punctuationBreaks
    }
}

/// Builds ordinary project caption cues without changing the transcript.
public enum CaptionGenerator {
    public static func generate(
        from transcript: [TranscriptSegment],
        options: CaptionGenerationOptions = .init()
    ) -> [CaptionCue] {
        var output: [CaptionCue] = []
        for segment in transcript.sorted(by: { $0.start < $1.start }) {
            let text = segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.end > segment.start else { continue }
            let phrases = split(text: text, options: options)
            let totalCharacters = max(phrases.reduce(0) { $0 + $1.count }, 1)
            var cursor = segment.start
            for (index, phrase) in phrases.enumerated() {
                let share = Double(phrase.count) / Double(totalCharacters)
                let desired = max(segment.end - segment.start, options.minimumDuration) * share
                let remaining = segment.end - cursor
                let duration = index == phrases.count - 1
                    ? remaining
                    : min(max(desired, options.minimumDuration), remaining)
                guard duration >= options.minimumDuration || index == phrases.count - 1 else { continue }
                output.append(CaptionCue(
                    id: stableCaptionID(segment: segment, index: index, text: phrase),
                    start: cursor,
                    end: min(segment.end, cursor + duration),
                    text: phrase
                ))
                cursor += duration
            }
        }
        return output
    }

    /// Existing captions are considered user-owned by default.  Passing
    /// `overwrite: true` explicitly opts into replacing them with generated
    /// cues.
    public static func regenerate(
        from transcript: [TranscriptSegment],
        existing: [CaptionCue],
        options: CaptionGenerationOptions = .init(),
        overwrite: Bool = false
    ) -> [CaptionCue] {
        guard overwrite || existing.isEmpty else { return existing }
        return generate(from: transcript, options: options)
    }

    public static func regenerate(
        from transcript: [TranscriptSegment],
        existingCaptions: [CaptionCue],
        options: CaptionGenerationOptions = .init(),
        overwrite: Bool = false
    ) -> [CaptionCue] {
        regenerate(
            from: transcript,
            existing: existingCaptions,
            options: options,
            overwrite: overwrite
        )
    }

    private static func split(text: String, options: CaptionGenerationOptions) -> [String] {
        var words: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            let punctuation = options.punctuationBreaks && current.count >= options.maximumCharacters / 2 &&
                (current.last == "." || current.last == "," || current.last == "?" || current.last == "!")
            if !current.isEmpty && (candidate.count > options.maximumCharacters || punctuation) {
                words.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.isEmpty ? [text] : words
    }

    private static func stableCaptionID(segment: TranscriptSegment, index: Int, text: String) -> UUID {
        let seed = "\(segment.id.uuidString)|\(index)|\(text)"
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in seed.utf8.enumerated() {
            let slot = index % 16
            bytes[slot] = bytes[slot] &* 31 &+ byte
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

#if canImport(Speech)
/// Apple Speech adapter configured for on-device recognition only.
public struct OnDeviceSpeechTranscriptionProvider: TranscriptionProvider {
    public init() {}

    public func transcribe(request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        guard let url = request.audioURL else { throw TranscriptionError.missingAudioURL }
        guard url.isFileURL else { throw TranscriptionError.invalidAudioURL }
        guard #available(macOS 10.15, *) else {
            throw TranscriptionError.onDeviceRecognitionUnavailable("macOS 10.15 or newer is required")
        }
        let locale = Locale(identifier: request.localeIdentifier ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.onDeviceRecognitionUnavailable("no recognizer for locale \(locale.identifier)")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.onDeviceRecognitionUnavailable("the local recognizer is unavailable")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable("this locale or system does not support on-device recognition")
        }

        let recognitionRequest = SFSpeechURLRecognitionRequest(url: url)
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = false
        let fragments = try await recognize(
            recognizer: recognizer,
            request: recognitionRequest,
            source: request.source
        )
        return TranscriptionNormalizer.normalize(
            fragments,
            trackOffset: request.trackOffset,
            minimumSegmentDuration: request.minimumSegmentDuration
        )
    }

    @available(macOS 10.15, *)
    private func recognize(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        source: TranscriptSource
    ) async throws -> [RecognizedTranscriptFragment] {
        try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                } else if let result, result.isFinal {
                    // Speech result objects are not Sendable. Convert them to
                    // our value-only provider boundary inside the callback so
                    // no framework reference crosses the continuation.
                    let fragments = result.bestTranscription.segments.map {
                        RecognizedTranscriptFragment(
                            start: $0.timestamp,
                            duration: $0.duration,
                            text: $0.substring,
                            confidence: Double($0.confidence),
                            source: source
                        )
                    }
                    continuation.resume(returning: fragments)
                }
            }
        }
    }
}

public typealias OnDeviceSpeechProvider = OnDeviceSpeechTranscriptionProvider
#endif
