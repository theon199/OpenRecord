import Foundation

/// The broad phase currently being reported by an export operation.
public enum ExportPhase: String, Sendable, Equatable {
    case preparing
    case rendering
    case finalizing
    case completed
}

/// A cancellation-safe, UI-friendly snapshot of export progress.
///
/// All values are normalized at the boundary so callers can safely pass values
/// calculated from media metadata without first checking for NaN, infinity, or
/// a negative duration.
public struct ExportProgress: Sendable, Equatable {
    public let phase: ExportPhase
    public let fraction: Double
    public let framesCompleted: Int
    public let totalFrames: Int
    public let elapsedSeconds: Double
    public let framesPerSecond: Double?
    public let estimatedRemainingSeconds: Double?

    public init(
        phase: ExportPhase,
        fraction: Double,
        framesCompleted: Int = 0,
        totalFrames: Int = 0,
        elapsedSeconds: Double = 0,
        framesPerSecond: Double? = nil,
        estimatedRemainingSeconds: Double? = nil
    ) {
        let normalizedTotal = max(0, totalFrames)
        let normalizedCompleted = normalizedTotal == 0
            ? 0
            : min(normalizedTotal, max(0, framesCompleted))
        let normalizedElapsed = Self.nonnegativeFinite(elapsedSeconds)
        let normalizedFraction = min(1, max(0, Self.finiteOrZero(fraction)))
        let normalizedFPS = Self.optionalNonnegativeFinite(framesPerSecond)
        let normalizedETA = Self.optionalNonnegativeFinite(estimatedRemainingSeconds)

        self.phase = phase
        self.fraction = phase == .completed ? 1 : normalizedFraction
        self.framesCompleted = normalizedCompleted
        self.totalFrames = normalizedTotal
        self.elapsedSeconds = normalizedElapsed
        self.framesPerSecond = normalizedFPS
        self.estimatedRemainingSeconds = phase == .completed ? 0 : normalizedETA
    }

    /// Creates a progress value for exports that do not have video frames (for
    /// example audio-only or GIF preparation). Frame counts remain zero.
    public init(fraction: Double, phase: ExportPhase = .rendering) {
        self.init(phase: phase, fraction: fraction)
    }

    /// Named form useful at call sites that report only a fractional milestone.
    public static func fractionOnly(
        _ fraction: Double,
        phase: ExportPhase = .rendering
    ) -> ExportProgress {
        ExportProgress(fraction: fraction, phase: phase)
    }

    private static func finiteOrZero(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func nonnegativeFinite(_ value: Double) -> Double {
        max(0, finiteOrZero(value))
    }

    private static func optionalNonnegativeFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

public typealias ExportStatusHandler = @Sendable (ExportProgress) -> Void

/// A deterministic progress estimator. The caller supplies elapsed time so
/// exports and tests do not need to consult a clock from a worker task.
///
/// The estimator retains only a small rolling sample window. FPS and ETA are
/// intentionally withheld until there are enough distinct samples spanning a
/// minimum duration; this avoids displaying an unstable estimate at startup.
struct ExportProgressEstimator: Sendable {
    private struct Sample: Sendable {
        let frames: Int
        let elapsed: Double
    }

    private let totalFrames: Int
    private let sampleWindowSize: Int
    private let minimumSampleCount: Int
    private let minimumElapsedSeconds: Double
    private var samples: [Sample] = []
    private var lastFrameCount = 0
    private var lastElapsedSeconds = 0.0
    private var didComplete = false

    init(
        totalFrames: Int,
        sampleWindowSize: Int = 8,
        minimumSampleCount: Int = 3,
        minimumElapsedSeconds: Double = 0.25
    ) {
        self.totalFrames = max(0, totalFrames)
        self.sampleWindowSize = max(2, sampleWindowSize)
        self.minimumSampleCount = max(2, minimumSampleCount)
        self.minimumElapsedSeconds = max(0, minimumElapsedSeconds.isFinite ? minimumElapsedSeconds : 0)
    }

    /// Adds a sample and returns the normalized current status.
    mutating func update(
        framesCompleted: Int,
        elapsedSeconds: Double,
        phase: ExportPhase = .rendering
    ) -> ExportProgress {
        if phase == .completed {
            return complete(elapsedSeconds: elapsedSeconds)
        }

        let frames = min(totalFrames, max(0, framesCompleted))
        let elapsed = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        lastFrameCount = max(lastFrameCount, frames)
        lastElapsedSeconds = max(lastElapsedSeconds, elapsed)

        if phase == .rendering {
            appendSample(Sample(frames: lastFrameCount, elapsed: lastElapsedSeconds))
        }

        let estimate = rollingEstimate()
        let fraction = totalFrames == 0
            ? 0
            : Double(lastFrameCount) / Double(totalFrames)
        return ExportProgress(
            phase: phase,
            fraction: fraction,
            framesCompleted: lastFrameCount,
            totalFrames: totalFrames,
            elapsedSeconds: lastElapsedSeconds,
            framesPerSecond: estimate.fps,
            estimatedRemainingSeconds: estimate.eta
        )
    }

    /// Marks the operation complete, regardless of the last rendered frame.
    mutating func complete(elapsedSeconds: Double) -> ExportProgress {
        didComplete = true
        lastElapsedSeconds = max(lastElapsedSeconds, elapsedSeconds.isFinite ? elapsedSeconds : 0)
        return ExportProgress(
            phase: .completed,
            fraction: 1,
            framesCompleted: totalFrames,
            totalFrames: totalFrames,
            elapsedSeconds: lastElapsedSeconds,
            framesPerSecond: rollingEstimate().fps,
            estimatedRemainingSeconds: 0
        )
    }

    private mutating func appendSample(_ sample: Sample) {
        guard !didComplete else { return }
        if let last = samples.last, last.elapsed == sample.elapsed {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        if samples.count > sampleWindowSize {
            samples.removeFirst(samples.count - sampleWindowSize)
        }
    }

    private func rollingEstimate() -> (fps: Double?, eta: Double?) {
        guard samples.count >= minimumSampleCount,
              let first = samples.first,
              let last = samples.last
        else { return (nil, nil) }

        let elapsed = last.elapsed - first.elapsed
        let frames = last.frames - first.frames
        guard elapsed >= minimumElapsedSeconds, elapsed > 0, frames > 0 else {
            return (nil, nil)
        }

        let fps = Double(frames) / elapsed
        guard fps.isFinite, fps > 0, totalFrames > last.frames else {
            return (fps.isFinite && fps > 0 ? fps : nil, nil)
        }
        let eta = Double(totalFrames - last.frames) / fps
        return (fps, eta.isFinite && eta >= 0 ? eta : nil)
    }
}

/// The stage at which an export failed. Keeping this separate from an
/// underlying framework error lets the UI provide useful recovery guidance.
public enum ExportFailureStage: String, Sendable, Equatable {
    case sourceReading
    case frameRendering
    case videoEncoding
    case audioMixing
    case finalization
    case installation

    fileprivate var displayName: String {
        switch self {
        case .sourceReading: return "source reading"
        case .frameRendering: return "frame rendering"
        case .videoEncoding: return "video encoding"
        case .audioMixing: return "audio mixing"
        case .finalization: return "finalization"
        case .installation: return "installation"
        }
    }

    fileprivate var defaultRecoverySuggestion: String {
        switch self {
        case .sourceReading:
            return "Check that the recording files are present and playable, then retry the export."
        case .frameRendering:
            return "Check the project overlays and source media, then retry; disabling the affected overlay may help identify the problem."
        case .videoEncoding:
            return "Free disk space, close other media applications, and retry the export."
        case .audioMixing:
            return "Check that audio files are readable; remove the affected audio track or retry without audio."
        case .finalization:
            return "Free disk space and ensure the destination is writable, then retry the export."
        case .installation:
            return "Choose a writable destination, make sure the target is not in use, and retry the export."
        }
    }
}

/// A user-facing export error with stage context and a concrete next action.
public struct ExportFailure: Error, LocalizedError, Sendable, Equatable {
    public let stage: ExportFailureStage
    public let message: String
    public let recoverySuggestion: String

    public init(
        stage: ExportFailureStage,
        message: String,
        recoverySuggestion: String? = nil
    ) {
        self.stage = stage
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? "The export could not continue." : trimmed
        self.recoverySuggestion = recoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? recoverySuggestion!.trimmingCharacters(in: .whitespacesAndNewlines)
            : stage.defaultRecoverySuggestion
    }

    public init(stage: ExportFailureStage, detail: String) {
        self.init(stage: stage, message: detail)
    }

    public var errorDescription: String? {
        "Export failed during \(stage.displayName): \(message) \(recoverySuggestion)"
    }

    public var failureReason: String? { message }
}
