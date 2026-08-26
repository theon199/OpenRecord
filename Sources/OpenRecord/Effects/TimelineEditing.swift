import Foundation

/// A finite, half-open source-timeline range used by direct manipulation.
public struct TimelineEditRange: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}

/// Shared range constraints for timeline gestures and project-load repair.
///
/// Keeping these rules outside SwiftUI makes malformed and boundary inputs
/// deterministic in the editor, tests, and any future timeline UI.
public enum TimelineRangeEditing: Sendable {
    public static let minimumTrimDuration: TimeInterval = 0.1
    public static let minimumOverlayDuration: TimeInterval = 0.05

    public static func normalized(
        _ range: TimelineEditRange,
        lowerBound: TimeInterval,
        upperBound: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimelineEditRange? {
        let lower = finite(lowerBound) ?? 0
        let rawUpper = finite(upperBound) ?? lower
        let upper = max(rawUpper, lower)
        let capacity = upper - lower
        let requestedMinimum = max(finite(minimumDuration) ?? 0, 0)
        guard capacity > 0, requestedMinimum <= capacity else { return nil }

        var start = clamp(finite(range.start) ?? lower, lower, upper)
        var end = clamp(finite(range.end) ?? start, start, upper)
        if end - start < requestedMinimum {
            if start + requestedMinimum <= upper {
                end = start + requestedMinimum
            } else {
                end = upper
                start = upper - requestedMinimum
            }
        }
        return TimelineEditRange(start: start, end: end)
    }

    public static func resizingStart(
        _ range: TimelineEditRange,
        to proposedStart: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimelineEditRange? {
        guard let current = normalized(
            range,
            lowerBound: lowerBound,
            upperBound: upperBound,
            minimumDuration: minimumDuration
        ) else { return nil }
        let lower = finite(lowerBound) ?? 0
        let minimum = max(finite(minimumDuration) ?? 0, 0)
        let proposed = finite(proposedStart) ?? current.start
        return TimelineEditRange(
            start: clamp(proposed, lower, current.end - minimum),
            end: current.end
        )
    }

    public static func resizingEnd(
        _ range: TimelineEditRange,
        to proposedEnd: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimelineEditRange? {
        guard let current = normalized(
            range,
            lowerBound: lowerBound,
            upperBound: upperBound,
            minimumDuration: minimumDuration
        ) else { return nil }
        let lower = finite(lowerBound) ?? 0
        let upper = max(finite(upperBound) ?? lower, lower)
        let minimum = max(finite(minimumDuration) ?? 0, 0)
        let proposed = finite(proposedEnd) ?? current.end
        return TimelineEditRange(
            start: current.start,
            end: clamp(proposed, current.start + minimum, upper)
        )
    }

    public static func moving(
        _ range: TimelineEditRange,
        toStart proposedStart: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimelineEditRange? {
        guard let current = normalized(
            range,
            lowerBound: lowerBound,
            upperBound: upperBound,
            minimumDuration: minimumDuration
        ) else { return nil }
        let lower = finite(lowerBound) ?? 0
        let upper = max(finite(upperBound) ?? current.end, lower)
        let proposed = finite(proposedStart) ?? current.start
        let start = clamp(proposed, lower, upper - current.duration)
        return TimelineEditRange(start: start, end: start + current.duration)
    }

    public static func trimRange(
        trimIn: TimeInterval,
        trimOut: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelineEditRange {
        let duration = max(finite(sourceDuration) ?? 0, 0)
        guard duration > 0 else { return TimelineEditRange(start: 0, end: 0) }
        let minimum = min(minimumTrimDuration, duration)
        return normalized(
            TimelineEditRange(start: trimIn, end: trimOut),
            lowerBound: 0,
            upperBound: duration,
            minimumDuration: minimum
        ) ?? TimelineEditRange(start: 0, end: duration)
    }

    private static func finite(_ value: TimeInterval) -> TimeInterval? {
        value.isFinite ? value : nil
    }

    private static func clamp(_ value: TimeInterval, _ lower: TimeInterval, _ upper: TimeInterval) -> TimeInterval {
        min(max(value, min(lower, upper)), max(lower, upper))
    }
}

public struct TimelineHitRange: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval

    public init(id: UUID, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public enum TimelineRangeHit: Sendable, Equatable {
    case start(UUID)
    case end(UUID)
    case body(UUID, grabOffset: TimeInterval)

    public var id: UUID {
        switch self {
        case .start(let id), .end(let id), .body(let id, _): id
        }
    }
}

/// Deterministic hit testing that mirrors the minimum on-screen block width.
/// The last range is frontmost, matching SwiftUI's visual stacking order.
public enum TimelineHitTesting: Sendable {
    public static func hit(
        at time: TimeInterval,
        ranges: [TimelineHitRange],
        handleTolerance: TimeInterval,
        minimumVisibleDuration: TimeInterval
    ) -> TimelineRangeHit? {
        guard time.isFinite else { return nil }
        let tolerance = max(handleTolerance.isFinite ? handleTolerance : 0, 0)
        let minimumVisible = max(minimumVisibleDuration.isFinite ? minimumVisibleDuration : 0, 0)

        for range in ranges.reversed() {
            let start = range.start.isFinite ? range.start : 0
            let actualEnd = range.end.isFinite ? max(range.end, start) : start
            let visualEnd = max(actualEnd, start + minimumVisible)
            guard time >= start - tolerance, time <= visualEnd + tolerance else { continue }

            let visualSpan = visualEnd - start
            if visualSpan <= max(tolerance * 2, minimumVisible) {
                let third = visualSpan / 3
                if time <= start + third { return .start(range.id) }
                if time >= visualEnd - third { return .end(range.id) }
                return .body(
                    range.id,
                    grabOffset: min(max(time - start, 0), actualEnd - start)
                )
            }
            if abs(time - start) <= tolerance { return .start(range.id) }
            if abs(time - visualEnd) <= tolerance { return .end(range.id) }
            if time >= start, time <= visualEnd {
                return .body(
                    range.id,
                    grabOffset: min(max(time - start, 0), actualEnd - start)
                )
            }
        }
        return nil
    }
}

/// The editor's mutually exclusive document selection. Keeping restoration
/// typed prevents overlapping lanes from leaving multiple selected IDs set.
public enum EditorDocumentSelection: Sendable, Equatable {
    case zoom(UUID)
    case speed(UUID)
    case caption(UUID)
    case annotation(UUID)
    case webcam

    public static func reconciled(
        current: EditorDocumentSelection?,
        previousDocument: ProjectDocument,
        restoredDocument: ProjectDocument
    ) -> EditorDocumentSelection? {
        if let current, current.exists(in: restoredDocument) { return current }

        var added: [EditorDocumentSelection] = []
        added += restoredDocument.zoomRanges
            .filter { item in !previousDocument.zoomRanges.contains { $0.id == item.id } }
            .map { .zoom($0.id) }
        added += restoredDocument.speedSegments
            .filter { item in !previousDocument.speedSegments.contains { $0.id == item.id } }
            .map { .speed($0.id) }
        added += restoredDocument.captions
            .filter { item in !previousDocument.captions.contains { $0.id == item.id } }
            .map { .caption($0.id) }
        added += restoredDocument.annotations
            .filter { item in !previousDocument.annotations.contains { $0.id == item.id } }
            .map { .annotation($0.id) }
        return added.count == 1 ? added[0] : nil
    }

    private func exists(in document: ProjectDocument) -> Bool {
        switch self {
        case .zoom(let id): document.zoomRanges.contains { $0.id == id }
        case .speed(let id): document.speedSegments.contains { $0.id == id }
        case .caption(let id): document.captions.contains { $0.id == id }
        case .annotation(let id): document.annotations.contains { $0.id == id }
        case .webcam: document.webcamOverlay.enabled
        }
    }
}

public extension ProjectDocument {
    /// Repairs legacy/malformed ranges before the interactive editor consumes
    /// them. Source media and project bytes remain unchanged until a real edit
    /// is saved.
    func normalizedForTimelineEditing(sourceDuration: TimeInterval) -> ProjectDocument {
        var value = self
        let duration = max(sourceDuration.isFinite ? sourceDuration : 0, 0)
        // Without a trustworthy source duration there is no safe upper bound.
        // Preserve every edit rather than dropping ranges from a degraded
        // project that has temporarily unreadable or missing display media.
        guard duration > 0 else { return value }
        let effectiveOut = trimOut ?? duration
        let trim = TimelineRangeEditing.trimRange(
            trimIn: trimIn,
            trimOut: effectiveOut,
            sourceDuration: duration
        )
        value.trimIn = trim.start
        value.trimOut = trimOut == nil ? nil : trim.end

        var previousZoomEnd: TimeInterval = 0
        value.zoomRanges = zoomRanges.sorted(by: timelineRangeOrder).compactMap { raw in
            guard let range = TimelineRangeEditing.normalized(
                TimelineEditRange(start: raw.start, end: raw.end),
                lowerBound: previousZoomEnd,
                upperBound: duration,
                minimumDuration: ZoomInsertion.minimumDuration
            ) else { return nil }
            previousZoomEnd = range.end
            var zoom = raw
            zoom.start = range.start
            zoom.end = range.end
            zoom.amount = zoom.amount.isFinite ? min(max(zoom.amount, 1), 5) : 1.8
            zoom.anchor.x = zoom.anchor.x.isFinite ? min(max(zoom.anchor.x, 0), 1) : 0.5
            zoom.anchor.y = zoom.anchor.y.isFinite ? min(max(zoom.anchor.y, 0), 1) : 0.5
            return zoom
        }
        value.speedSegments = SpeedTimeline.normalizedSegments(
            speedSegments,
            sourceDuration: duration
        )
        value.captions = captions.sorted(by: timelineRangeOrder).compactMap {
            normalizedCaption($0, sourceDuration: duration)
        }
        value.annotations = annotations.sorted(by: timelineRangeOrder).compactMap {
            normalizedAnnotation($0, sourceDuration: duration)
        }
        value.editDecisions = ProjectTimeMapper.normalizedDecisions(
            editDecisions,
            sourceDuration: duration
        )
        return value
    }

    private func normalizedCaption(
        _ raw: CaptionCue,
        sourceDuration: TimeInterval
    ) -> CaptionCue? {
        guard let range = TimelineRangeEditing.normalized(
            TimelineEditRange(start: raw.start, end: raw.end),
            lowerBound: 0,
            upperBound: sourceDuration,
            minimumDuration: TimelineRangeEditing.minimumOverlayDuration
        ) else { return nil }
        var value = raw.normalized
        value.start = range.start
        value.end = range.end
        return value
    }

    private func normalizedAnnotation(
        _ raw: Annotation,
        sourceDuration: TimeInterval
    ) -> Annotation? {
        guard let range = TimelineRangeEditing.normalized(
            TimelineEditRange(start: raw.start, end: raw.end),
            lowerBound: 0,
            upperBound: sourceDuration,
            minimumDuration: TimelineRangeEditing.minimumOverlayDuration
        ) else { return nil }
        var value = raw.normalized
        value.start = range.start
        value.end = range.end
        return value
    }

    private func timelineRangeOrder(_ lhs: ZoomRange, _ rhs: ZoomRange) -> Bool {
        timelineRangeOrder(lhs.start, lhs.id, rhs.start, rhs.id)
    }

    private func timelineRangeOrder(_ lhs: CaptionCue, _ rhs: CaptionCue) -> Bool {
        timelineRangeOrder(lhs.start, lhs.id, rhs.start, rhs.id)
    }

    private func timelineRangeOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        timelineRangeOrder(lhs.start, lhs.id, rhs.start, rhs.id)
    }

    private func timelineRangeOrder(
        _ lhsStart: TimeInterval,
        _ lhsID: UUID,
        _ rhsStart: TimeInterval,
        _ rhsID: UUID
    ) -> Bool {
        let lhs = lhsStart.isFinite ? lhsStart : 0
        let rhs = rhsStart.isFinite ? rhsStart : 0
        return lhs == rhs ? lhsID.uuidString < rhsID.uuidString : lhs < rhs
    }
}
