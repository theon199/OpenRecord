import Foundation

public enum ZoomInsertionResult: Sendable, Equatable {
    case select(UUID)
    case create(start: TimeInterval, end: TimeInterval)
    case unavailable
}

public enum ZoomInsertion: Sendable {
    public static let minimumDuration: TimeInterval = 0.12
    public static let maximumDuration: TimeInterval = 2

    public static func proposal(
        at playhead: TimeInterval,
        timelineDuration: TimeInterval,
        ranges: [ZoomRange]
    ) -> ZoomInsertionResult {
        let duration = max(0, timelineDuration)
        let pivot = min(max(playhead, 0), duration)
        // Timeline ranges are half-open throughout preview and export. At an
        // exact end boundary the prior zoom is no longer active, so insertion
        // must consider the following gap/range instead of reselecting it.
        if let existing = ranges.first(where: { pivot >= $0.start && pivot < $0.end }) {
            return .select(existing.id)
        }

        let previousEnd = ranges.filter { $0.end <= pivot }.map(\.end).max() ?? 0
        let nextStart = ranges.filter { $0.start >= pivot }.map(\.start).min() ?? duration
        let lower = max(0, previousEnd)
        let upper = min(duration, nextStart)
        guard upper - lower >= minimumDuration else { return .unavailable }

        let span = min(maximumDuration, upper - lower)
        guard span >= minimumDuration else { return .unavailable }
        let start = min(max(pivot, lower), upper - span)
        return .create(start: start, end: start + span)
    }
}
