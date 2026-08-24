import Foundation

public struct SpeedSlice: Equatable, Sendable {
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval
    public var outputStart: TimeInterval
    public var outputEnd: TimeInterval
    public var rate: Double
    public var segmentID: UUID?

    public var sourceDuration: TimeInterval { sourceEnd - sourceStart }
    public var outputDuration: TimeInterval { outputEnd - outputStart }
}

/// Piecewise-linear mapping between the recording's source timeline and the
/// final playback/export timeline. Gaps between explicit segments run at 1×.
public struct SpeedTimeline: Sendable {
    public static let minimumSegmentDuration: TimeInterval = 0.12

    public let segments: [SpeedSegment]

    public init(segments: [SpeedSegment]) {
        self.segments = Self.normalizedSegments(segments)
    }

    public static func normalizedSegments(
        _ segments: [SpeedSegment],
        sourceDuration: TimeInterval? = nil
    ) -> [SpeedSegment] {
        let limit = sourceDuration.flatMap { $0.isFinite ? max($0, 0) : nil }
        var seen = Set<UUID>()
        var previousEnd: TimeInterval = 0
        var result: [SpeedSegment] = []

        for raw in segments.sorted(by: {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }) {
            guard seen.insert(raw.id).inserted else { continue }
            var segment = raw.normalized
            if let limit {
                segment.start = min(segment.start, limit)
                segment.end = min(segment.end, limit)
            }
            segment.start = max(segment.start, previousEnd)
            guard segment.end - segment.start >= minimumSegmentDuration else { continue }
            previousEnd = segment.end
            result.append(segment)
        }
        return result
    }

    public func rate(at sourceTime: TimeInterval) -> Double {
        guard sourceTime.isFinite else { return 1 }
        return segments.first {
            sourceTime >= $0.start && sourceTime < $0.end
        }?.rate ?? 1
    }

    public func slices(
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) -> [SpeedSlice] {
        let lower = sourceStart.isFinite ? max(sourceStart, 0) : 0
        let upper = sourceEnd.isFinite ? max(sourceEnd, lower) : lower
        guard upper > lower else { return [] }

        var cursor = lower
        var outputCursor: TimeInterval = 0
        var result: [SpeedSlice] = []

        func append(sourceEnd end: TimeInterval, rate: Double, id: UUID?) {
            guard end > cursor else { return }
            let duration = (end - cursor) / rate
            result.append(
                SpeedSlice(
                    sourceStart: cursor,
                    sourceEnd: end,
                    outputStart: outputCursor,
                    outputEnd: outputCursor + duration,
                    rate: rate,
                    segmentID: id
                )
            )
            cursor = end
            outputCursor += duration
        }

        for segment in segments where segment.end > lower && segment.start < upper {
            let segmentStart = max(segment.start, lower)
            let segmentEnd = min(segment.end, upper)
            append(sourceEnd: segmentStart, rate: 1, id: nil)
            if cursor < segmentEnd {
                append(sourceEnd: segmentEnd, rate: segment.rate, id: segment.id)
            }
        }
        append(sourceEnd: upper, rate: 1, id: nil)
        return result
    }

    public func outputDuration(
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) -> TimeInterval {
        slices(sourceStart: sourceStart, sourceEnd: sourceEnd).last?.outputEnd ?? 0
    }

    public func sourceTime(
        atOutputTime outputTime: TimeInterval,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) -> TimeInterval {
        let spans = slices(sourceStart: sourceStart, sourceEnd: sourceEnd)
        guard let last = spans.last else { return max(sourceStart, 0) }
        let time = outputTime.isFinite ? min(max(outputTime, 0), last.outputEnd) : 0
        guard let span = spans.first(where: { time <= $0.outputEnd }) else {
            return last.sourceEnd
        }
        return min(
            span.sourceStart + max(time - span.outputStart, 0) * span.rate,
            span.sourceEnd
        )
    }

    public func outputTime(
        forSourceTime sourceTime: TimeInterval,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) -> TimeInterval {
        let spans = slices(sourceStart: sourceStart, sourceEnd: sourceEnd)
        guard let last = spans.last else { return 0 }
        let time = sourceTime.isFinite
            ? min(max(sourceTime, sourceStart), sourceEnd)
            : sourceStart
        guard let span = spans.first(where: { time <= $0.sourceEnd }) else {
            return last.outputEnd
        }
        return min(
            span.outputStart + max(time - span.sourceStart, 0) / span.rate,
            span.outputEnd
        )
    }
}
