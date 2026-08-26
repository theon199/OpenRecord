import Foundation
import AVFoundation

/// One deterministic level measurement.  At least one of rms, peak, or
/// decibels should be supplied; missing values are treated as non-silent.
public struct AudioLevelSample: Sendable, Hashable {
    public var timestamp: TimeInterval
    public var rms: Double?
    public var peak: Double?
    public var decibels: Double?

    public init(
        timestamp: TimeInterval,
        rms: Double? = nil,
        peak: Double? = nil,
        decibels: Double? = nil
    ) {
        self.timestamp = timestamp
        self.rms = rms
        self.peak = peak
        self.decibels = decibels
    }

    public init(timestamp: TimeInterval, db: Double) {
        self.init(timestamp: timestamp, decibels: db)
    }

    public var levelDecibels: Double? {
        if let decibels, decibels.isFinite { return decibels }
        let values = [rms, peak].compactMap { value -> Double? in
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        guard let amplitude = values.max() else { return nil }
        if amplitude <= 0 { return -120 }
        return max(20 * log10(amplitude), -120)
    }

    public var db: Double? { levelDecibels }
}

public enum SilencePreset: String, Codable, CaseIterable, Sendable, Hashable {
    case natural
    case tight
    case fast

    public var minimumPause: TimeInterval {
        switch self {
        case .natural: 1.2
        case .tight: 0.7
        case .fast: 0.4
        }
    }

    public var thresholdDB: Double {
        switch self {
        case .natural: -42
        case .tight: -38
        case .fast: -34
        }
    }

    public var breathingRoom: TimeInterval {
        switch self {
        case .natural: 0.18
        case .tight: 0.10
        case .fast: 0.05
        }
    }

    public var minimumSilenceDuration: TimeInterval { minimumPause }
    public var retainedBreathingRoom: TimeInterval { breathingRoom }
}

public struct SilenceAnalysisOptions: Sendable, Hashable {
    public var preset: SilencePreset
    public var thresholdDB: Double
    public var minimumPause: TimeInterval
    public var retainedBreathingRoom: TimeInterval
    public var includeTranscriptGaps: Bool
    public var gapTolerance: TimeInterval

    public init(
        preset: SilencePreset = .natural,
        thresholdDB: Double? = nil,
        minimumPause: TimeInterval? = nil,
        retainedBreathingRoom: TimeInterval? = nil,
        includeTranscriptGaps: Bool = true,
        gapTolerance: TimeInterval = 0.08
    ) {
        self.preset = preset
        self.thresholdDB = thresholdDB?.isFinite == true ? thresholdDB! : preset.thresholdDB
        self.minimumPause = max(
            minimumPause?.isFinite == true ? minimumPause! : preset.minimumPause,
            0.01
        )
        self.retainedBreathingRoom = max(
            retainedBreathingRoom?.isFinite == true ? retainedBreathingRoom! : preset.breathingRoom,
            0
        )
        self.includeTranscriptGaps = includeTranscriptGaps
        self.gapTolerance = max(gapTolerance.isFinite ? gapTolerance : 0.08, 0)
    }
}

public enum PauseSuggestionSource: String, Codable, Sendable, Hashable {
    case audio
    case transcriptGap
    case audioAndTranscript
}

/// A preview-only pause candidate. `start`/`end` describe the detected pause;
/// `cutStart`/`cutEnd` describe the interior that can safely be excluded while
/// retaining breathing room on both sides.
public struct PauseSuggestion: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var cutStart: TimeInterval
    public var cutEnd: TimeInterval
    public var source: PauseSuggestionSource

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        cutStart: TimeInterval? = nil,
        cutEnd: TimeInterval? = nil,
        source: PauseSuggestionSource = .audio
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.cutStart = cutStart ?? start
        self.cutEnd = cutEnd ?? end
        self.source = source
    }

    public var duration: TimeInterval { max(end - start, 0) }
    public var excludedRange: TimelineEditRange {
        TimelineEditRange(start: cutStart, end: cutEnd)
    }

    public var range: TimelineEditRange { excludedRange }
}

public typealias SilenceSuggestion = PauseSuggestion
public typealias PauseCandidate = PauseSuggestion
public typealias SilenceDetector = SilenceAnalyzer

/// Pure analysis over precomputed samples.  It can therefore be tested with
/// fixtures and used by a background task without touching AVAudioEngine.
public enum SilenceAnalyzer {
    public static func detect(
        samples: [AudioLevelSample],
        options: SilenceAnalysisOptions = .init(),
        duration: TimeInterval? = nil,
        transcript: [TranscriptSegment] = []
    ) -> [PauseSuggestion] {
        let ordered = samples.filter { $0.timestamp.isFinite }.sorted { $0.timestamp < $1.timestamp }
        var ranges: [(start: TimeInterval, end: TimeInterval, source: PauseSuggestionSource)] = []
        guard !ordered.isEmpty else {
            guard options.includeTranscriptGaps else { return [] }
            return transcriptGaps(transcript, options: options).map { gap in
                let breathing = min(options.retainedBreathingRoom, max(gap.duration / 2, 0))
                return PauseSuggestion(
                    id: gap.id,
                    start: gap.start,
                    end: gap.end,
                    cutStart: gap.start + breathing,
                    cutEnd: gap.end - breathing,
                    source: gap.source
                )
            }
        }

        let cadence = inferredCadence(ordered)
        let explicitEnd = duration?.isFinite == true ? max(duration!, 0) : nil
        var lowStart: TimeInterval?
        for index in ordered.indices {
            let sample = ordered[index]
            let nextTimestamp: TimeInterval = {
                if index + 1 < ordered.count { return max(sample.timestamp, ordered[index + 1].timestamp) }
                return explicitEnd ?? sample.timestamp + cadence
            }()
            let isSilent = (sample.levelDecibels ?? 0) <= options.thresholdDB
            if isSilent {
                if lowStart == nil { lowStart = sample.timestamp }
            } else if let start = lowStart {
                appendIfLong(
                    start: start,
                    end: sample.timestamp,
                    source: .audio,
                    minimumPause: options.minimumPause,
                    into: &ranges
                )
                lowStart = nil
            }
            // A low sample's interval is represented by the following sample
            // timestamp.  The final sample uses an explicit duration or the
            // median cadence, making fixtures deterministic at the tail.
            if isSilent, index == ordered.index(before: ordered.endIndex), let start = lowStart {
                appendIfLong(
                    start: start,
                    end: nextTimestamp,
                    source: .audio,
                    minimumPause: options.minimumPause,
                    into: &ranges
                )
                lowStart = nil
            }
        }

        if options.includeTranscriptGaps {
            for gap in transcriptGaps(transcript, options: options) {
                ranges.append((gap.start, gap.end, .transcriptGap))
            }
        }
        let merged = merge(ranges, tolerance: options.gapTolerance)
        return merged.map { raw in
            let breathing = min(options.retainedBreathingRoom, max((raw.end - raw.start) / 2, 0))
            let cutStart = raw.start + breathing
            let cutEnd = raw.end - breathing
            guard cutEnd - cutStart >= options.minimumPause / 3 else {
                return PauseSuggestion(
                    start: raw.start,
                    end: raw.end,
                    cutStart: raw.start,
                    cutEnd: raw.end,
                    source: raw.source
                )
            }
            return PauseSuggestion(
                start: raw.start,
                end: raw.end,
                cutStart: cutStart,
                cutEnd: cutEnd,
                source: raw.source
            )
        }
    }

    private static func transcriptGaps(
        _ transcript: [TranscriptSegment],
        options: SilenceAnalysisOptions
    ) -> [PauseSuggestion] {
        let segments = transcript.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard segments.count > 1 else { return [] }
        return zip(segments, segments.dropFirst()).compactMap { lhs, rhs in
            let start = max(lhs.end, 0)
            let end = max(rhs.start, start)
            guard end - start >= options.minimumPause else { return nil }
            return PauseSuggestion(start: start, end: end, source: .transcriptGap)
        }
    }

    private static func appendIfLong(
        start: TimeInterval,
        end: TimeInterval,
        source: PauseSuggestionSource,
        minimumPause: TimeInterval,
        into ranges: inout [(start: TimeInterval, end: TimeInterval, source: PauseSuggestionSource)]
    ) {
        guard start.isFinite, end.isFinite, end - start >= minimumPause else { return }
        ranges.append((max(start, 0), max(end, start), source))
    }

    private static func inferredCadence(_ samples: [AudioLevelSample]) -> TimeInterval {
        let deltas = zip(samples, samples.dropFirst()).map { $1.timestamp - $0.timestamp }
            .filter { $0.isFinite && $0 > 0 }
        guard !deltas.isEmpty else { return 0.05 }
        let ordered = deltas.sorted()
        return ordered[ordered.count / 2]
    }

    private static func merge(
        _ ranges: [(start: TimeInterval, end: TimeInterval, source: PauseSuggestionSource)],
        tolerance: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval, source: PauseSuggestionSource)] {
        var result: [(start: TimeInterval, end: TimeInterval, source: PauseSuggestionSource)] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            guard range.end > range.start else { continue }
            guard var last = result.popLast() else {
                result.append(range)
                continue
            }
            if range.start <= last.end + tolerance {
                last.end = max(last.end, range.end)
                if last.source != range.source { last.source = .audioAndTranscript }
                result.append(last)
            } else {
                result.append(last)
                result.append(range)
            }
        }
        return result
    }
}

public enum SilenceAnalysis {
    public static func analyze(
        samples: [AudioLevelSample],
        options: SilenceAnalysisOptions = .init(),
        duration: TimeInterval? = nil,
        transcript: [TranscriptSegment] = []
    ) -> [PauseSuggestion] {
        SilenceAnalyzer.detect(samples: samples, options: options, duration: duration, transcript: transcript)
    }
}

/// Converts accepted preview suggestions to the project's authoritative
/// source-timed edit-decision lane.  It intentionally returns values only;
/// callers can construct one ProjectTimeMapper for both preview and export.
public enum PauseSuggestionApplier {
    public static func acceptedEditDecisions(
        suggestions: [PauseSuggestion],
        mapper: ProjectTimeMapper
    ) -> [EditDecision] {
        acceptedEditDecisions(suggestions, mapper: mapper)
    }

    public static func acceptedEditDecisions(
        _ suggestions: [PauseSuggestion],
        mapper: ProjectTimeMapper
    ) -> [EditDecision] {
        let raw = suggestions.map {
            EditDecision(id: $0.id, start: $0.cutStart, end: $0.cutEnd)
        }
        return ProjectTimeMapper.normalizedDecisions(raw, sourceDuration: mapper.sourceEnd)
            .filter { $0.end > mapper.sourceStart && $0.start < mapper.sourceEnd }
            .map { decision in
                var bounded = decision
                bounded.start = max(bounded.start, mapper.sourceStart)
                bounded.end = min(bounded.end, mapper.sourceEnd)
                return bounded
            }
            .filter { $0.end - $0.start >= ProjectTimeMapper.minimumDecisionDuration }
    }

    public static func apply(
        _ suggestions: [PauseSuggestion],
        to mapper: ProjectTimeMapper
    ) -> [EditDecision] {
        acceptedEditDecisions(suggestions, mapper: mapper)
    }
}

/// Reads local AVFoundation audio files into deterministic level samples.
public struct LocalAudioLevelReader: Sendable {
    public var windowDuration: TimeInterval

    public init(windowDuration: TimeInterval = 0.05) {
        self.windowDuration = max(windowDuration.isFinite ? windowDuration : 0.05, 0.005)
    }

    public func read(from url: URL, startOffset: TimeInterval = 0) throws -> [AudioLevelSample] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        let framesPerWindow = AVAudioFrameCount(max(Int(sampleRate * windowDuration), 1))
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }
        var samples: [AudioLevelSample] = []
        var frameOffset: AVAudioFramePosition = 0
        while frameOffset < file.length {
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(framesPerWindow), file.length - frameOffset))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            try file.read(into: buffer, frameCount: frameCount)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            var sumSquares = 0.0
            var peak = 0.0
            for channel in 0..<channelCount {
                let values = channels[channel]
                for frame in 0..<frames {
                    let amplitude = abs(Double(values[frame]))
                    sumSquares += amplitude * amplitude
                    peak = max(peak, amplitude)
                }
            }
            let rms = sqrt(sumSquares / Double(frames * channelCount))
            samples.append(AudioLevelSample(
                timestamp: max(startOffset, 0) + Double(frameOffset) / sampleRate,
                rms: rms,
                peak: peak
            ))
            frameOffset += AVAudioFramePosition(frames)
        }
        return samples
    }
}

/// Composes microphone/system tracks locally by taking the RMS power sum and
/// the maximum peak for each level window.  Missing tracks are simply ignored.
public enum LocalAudioLevelAnalyzer {
    /// Converts samples from a captured track's source clock to the project
    /// timeline. Samples that occurred before the first display frame are
    /// discarded instead of being collapsed onto time zero.
    public static func mapToTimeline(
        _ samples: [AudioLevelSample],
        offset: TimeInterval,
        sourceRate: Double
    ) -> [AudioLevelSample] {
        let safeOffset = offset.isFinite ? offset : 0
        let safeRate = sourceRate.isFinite && sourceRate > 0 ? sourceRate : 1
        return samples.compactMap { sample in
            guard sample.timestamp.isFinite else { return nil }
            let timestamp = safeOffset + sample.timestamp / safeRate
            guard timestamp >= 0 else { return nil }
            var value = sample
            value.timestamp = timestamp
            return value
        }
    }

    public static func read(
        microphoneURL: URL?,
        systemAudioURL: URL?,
        source: TranscriptSource,
        windowDuration: TimeInterval = 0.05
    ) throws -> [AudioLevelSample] {
        let reader = LocalAudioLevelReader(windowDuration: windowDuration)
        var tracks: [[AudioLevelSample]] = []
        switch source {
        case .microphone:
            if let microphoneURL { tracks.append(try reader.read(from: microphoneURL)) }
        case .systemAudio:
            if let systemAudioURL { tracks.append(try reader.read(from: systemAudioURL)) }
        case .mixed:
            if let microphoneURL { tracks.append(try reader.read(from: microphoneURL)) }
            if let systemAudioURL { tracks.append(try reader.read(from: systemAudioURL)) }
        }
        return merge(tracks: tracks, windowDuration: windowDuration)
    }

    /// Mixes level envelopes on the project clock. Power is summed within a
    /// deterministic window, so a mixed track is silent only when every
    /// available source is silent; interleaved same-time samples cannot create
    /// artificial micro-pauses.
    public static func merge(
        tracks: [[AudioLevelSample]],
        windowDuration: TimeInterval = 0.05
    ) -> [AudioLevelSample] {
        guard let first = tracks.first else { return [] }
        guard tracks.count > 1 else { return first.sorted { $0.timestamp < $1.timestamp } }
        let window = max(windowDuration.isFinite ? windowDuration : 0.05, 0.005)
        var buckets: [Int64: [AudioLevelSample]] = [:]
        for sample in tracks.flatMap({ $0 }) where sample.timestamp.isFinite {
            let bucket = Int64((sample.timestamp / window).rounded())
            buckets[bucket, default: []].append(sample)
        }
        return buckets.keys.sorted().compactMap { key in
            guard let values = buckets[key], !values.isEmpty else { return nil }
            let power = values.reduce(0.0) { partial, sample in
                let rms = sample.rms
                    ?? sample.peak
                    ?? sample.levelDecibels.map { pow(10, $0 / 20) }
                    ?? 0
                return partial + rms * rms
            }
            return AudioLevelSample(
                timestamp: max(Double(key) * window, 0),
                rms: sqrt(power),
                peak: values.compactMap(\.peak).max()
            )
        }
    }
}
