import AVFoundation
import Foundation

/// Media and telemetry tracks whose capture health is persisted in `meta.json`.
public enum CaptureTrackKind: String, Codable, CaseIterable, Sendable, Hashable {
    case displayVideo
    case systemAudio
    case microphone
    case webcam
}

public enum CaptureTrackStatus: String, Codable, Sendable, Hashable {
    case notRequested
    case complete
    case missing
    case truncated
}

/// A non-destructive clock correction. `sourceDuration` is the duration of the
/// original track and `timelineDuration` is how long it should occupy beside
/// the display recording. Export and preview time-scale reads; media is never
/// rewritten.
public struct CaptureTrackCorrection: Codable, Sendable, Hashable {
    public var sourceDuration: TimeInterval
    public var timelineDuration: TimeInterval

    public init(sourceDuration: TimeInterval, timelineDuration: TimeInterval) {
        self.sourceDuration = Self.positiveFinite(sourceDuration)
        self.timelineDuration = Self.positiveFinite(timelineDuration)
    }

    /// Source seconds consumed for each second on the display timeline.
    public var sourceRate: Double {
        guard sourceDuration > 0, timelineDuration > 0 else { return 1 }
        return sourceDuration / timelineDuration
    }

    public func sourceTime(forTimelineOffset offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite else { return 0 }
        return min(max(offset, 0), timelineDuration) * sourceRate
    }

    public func timelineTime(forSourceOffset offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite, sourceRate > 0 else { return 0 }
        return min(max(offset, 0), sourceDuration) / sourceRate
    }

    private static func positiveFinite(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }
}

/// Persisted health and synchronization data for one captured media track.
public struct CaptureTrackDiagnostic: Codable, Sendable, Hashable {
    public var track: CaptureTrackKind
    public var status: CaptureTrackStatus
    /// First sample relative to the first complete display frame.
    public var initialOffset: TimeInterval?
    /// Duration of samples in the original, unmodified track.
    public var duration: TimeInterval?
    /// Track end relative to the display end. Positive means the track ends late.
    public var endDrift: TimeInterval?
    /// Present only when `abs(endDrift)` exceeds the configured tolerance.
    public var correction: CaptureTrackCorrection?

    public init(
        track: CaptureTrackKind,
        status: CaptureTrackStatus,
        initialOffset: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        endDrift: TimeInterval? = nil,
        correction: CaptureTrackCorrection? = nil
    ) {
        self.track = track
        self.status = status
        self.initialOffset = initialOffset
        self.duration = duration
        self.endDrift = endDrift
        self.correction = correction
    }

    /// Duration occupied on the display timeline after any correction.
    public var timelineDuration: TimeInterval? {
        correction?.timelineDuration ?? duration
    }
}

/// Capture-health data that is safe to persist locally: track presence,
/// durations, timestamp offsets, drift, applied corrections, and the lowest
/// observed free disk capacity. It contains no recorded content or paths.
public struct CaptureDiagnostics: Codable, Sendable, Hashable {
    public var referenceDuration: TimeInterval
    public var driftTolerance: TimeInterval
    public var minimumAvailableDiskBytes: Int64?
    public var tracks: [CaptureTrackDiagnostic]

    public init(
        referenceDuration: TimeInterval,
        driftTolerance: TimeInterval,
        minimumAvailableDiskBytes: Int64? = nil,
        tracks: [CaptureTrackDiagnostic]
    ) {
        self.referenceDuration = referenceDuration.isFinite ? max(0, referenceDuration) : 0
        self.driftTolerance = driftTolerance.isFinite ? max(0, driftTolerance) : 0
        self.minimumAvailableDiskBytes = minimumAvailableDiskBytes
        self.tracks = tracks
    }

    public func diagnostic(for track: CaptureTrackKind) -> CaptureTrackDiagnostic? {
        tracks.first { $0.track == track }
    }

    public func correction(for track: CaptureTrackKind) -> CaptureTrackCorrection? {
        diagnostic(for: track)?.correction
    }

    /// Maps a display-timeline timestamp into a track-local source timestamp.
    /// Returns `nil` when the track is not available at that display time.
    public func sourceTime(
        for track: CaptureTrackKind,
        atTimelineTime timelineTime: TimeInterval
    ) -> TimeInterval? {
        guard timelineTime.isFinite,
              let diagnostic = diagnostic(for: track),
              diagnostic.status == .complete || diagnostic.status == .truncated,
              let availableDuration = diagnostic.timelineDuration,
              availableDuration > 0
        else {
            return nil
        }
        let offset = diagnostic.initialOffset ?? 0
        let localTime = timelineTime - offset
        guard localTime >= 0, localTime <= availableDuration else { return nil }
        return diagnostic.correction?.sourceTime(forTimelineOffset: localTime) ?? localTime
    }

    public func sourceRate(for track: CaptureTrackKind) -> Double {
        correction(for: track)?.sourceRate ?? 1
    }
}

/// Hardware-free observation used by the analyzer and accelerated soak tests.
public struct CaptureTrackObservation: Sendable, Hashable {
    public var track: CaptureTrackKind
    public var requested: Bool
    public var duration: TimeInterval?
    public var initialOffset: TimeInterval?
    public var truncated: Bool

    public init(
        track: CaptureTrackKind,
        requested: Bool = true,
        duration: TimeInterval? = nil,
        initialOffset: TimeInterval? = nil,
        truncated: Bool = false
    ) {
        self.track = track
        self.requested = requested
        self.duration = duration
        self.initialOffset = initialOffset
        self.truncated = truncated
    }
}

public enum CaptureDiagnosticsAnalyzer: Sendable {
    /// 100 ms is perceptible at the end of a long recording and is large
    /// enough to avoid correcting ordinary container timestamp rounding.
    public static let defaultDriftTolerance: TimeInterval = 0.100

    public static func analyze(
        referenceDuration: TimeInterval,
        observations: [CaptureTrackObservation],
        driftTolerance: TimeInterval = defaultDriftTolerance,
        minimumAvailableDiskBytes: Int64? = nil
    ) -> CaptureDiagnostics {
        let reference = finiteNonnegative(referenceDuration) ?? 0
        let tolerance = finiteNonnegative(driftTolerance) ?? defaultDriftTolerance
        let byTrack = Dictionary(observations.map { ($0.track, $0) }, uniquingKeysWith: { _, last in last })
        let diagnostics = CaptureTrackKind.allCases.map { track -> CaptureTrackDiagnostic in
            let observation = byTrack[track] ?? CaptureTrackObservation(
                track: track,
                requested: track == .displayVideo
            )
            guard observation.requested else {
                return CaptureTrackDiagnostic(track: track, status: .notRequested)
            }
            guard let duration = finitePositive(observation.duration) else {
                return CaptureTrackDiagnostic(
                    track: track,
                    status: .missing,
                    initialOffset: finite(observation.initialOffset)
                )
            }

            let offset: TimeInterval?
            if track == .displayVideo {
                offset = 0
            } else {
                offset = finite(observation.initialOffset)
            }
            var drift: TimeInterval?
            var correction: CaptureTrackCorrection?
            if track != .displayVideo, let offset {
                // A track that legitimately begins late should occupy less of
                // the display timeline; startup latency is not clock drift.
                let expectedDuration = max(0, reference - offset)
                let endDrift = offset + duration - reference
                drift = endDrift
                if !observation.truncated,
                   expectedDuration > 0,
                   abs(endDrift) - tolerance > 0.000_000_001
                {
                    correction = CaptureTrackCorrection(
                        sourceDuration: duration,
                        timelineDuration: expectedDuration
                    )
                }
            }
            return CaptureTrackDiagnostic(
                track: track,
                status: observation.truncated ? .truncated : .complete,
                initialOffset: offset,
                duration: duration,
                endDrift: drift,
                correction: correction
            )
        }
        return CaptureDiagnostics(
            referenceDuration: reference,
            driftTolerance: tolerance,
            minimumAvailableDiskBytes: minimumAvailableDiskBytes,
            tracks: diagnostics
        )
    }

    private static func finite(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func finiteNonnegative(_ value: TimeInterval?) -> TimeInterval? {
        guard let value = finite(value), value >= 0 else { return nil }
        return value
    }

    private static func finitePositive(_ value: TimeInterval?) -> TimeInterval? {
        guard let value = finite(value), value > 0 else { return nil }
        return value
    }
}

public enum CaptureDiskSpaceLevel: String, Sendable, Equatable {
    case sufficient
    case low
    case critical
}

/// Conservative thresholds leave enough room to finalize an already-open
/// display writer before the volume is exhausted.
public enum CaptureDiskSpacePolicy: Sendable {
    public static let lowBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let criticalBytes: Int64 = 512 * 1_024 * 1_024

    public static func level(availableBytes: Int64) -> CaptureDiskSpaceLevel {
        if availableBytes <= criticalBytes { return .critical }
        if availableBytes <= lowBytes { return .low }
        return .sufficient
    }
}

enum CaptureMediaProbe {
    static func duration(
        at url: URL,
        track: CaptureTrackKind
    ) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mediaType: AVMediaType
        switch track {
        case .displayVideo, .webcam:
            mediaType = .video
        case .systemAudio, .microphone:
            mediaType = .audio
        }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let assetTrack = try? await asset.loadTracks(withMediaType: mediaType).first else {
            return nil
        }
        if let range = try? await assetTrack.load(.timeRange),
           range.duration.isNumeric,
           range.duration.seconds > 0
        {
            return range.duration.seconds
        }
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0
        else {
            return nil
        }
        return duration.seconds
    }
}
