import Foundation

/// A stable reference to an editable, source-timed timeline item.
///
/// Selection is deliberately editor state rather than project state: undo
/// restores document snapshots, while `reconciled(with:)` keeps only items
/// that still exist after the snapshot changes.
public enum TimelineItemID: Sendable, Hashable {
    case zoom(UUID)
    case speed(UUID)
    case caption(UUID)
    case annotation(UUID)
    case cursorEffect(UUID)

    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case zoom
        case speed
        case caption
        case annotation
        case cursorEffect
    }

    public var id: UUID {
        switch self {
        case .zoom(let id), .speed(let id), .caption(let id),
             .annotation(let id), .cursorEffect(let id):
            id
        }
    }

    public var kind: Kind {
        switch self {
        case .zoom: .zoom
        case .speed: .speed
        case .caption: .caption
        case .annotation: .annotation
        case .cursorEffect: .cursorEffect
        }
    }
}

/// Multi-selection stays within a compatible lane. This avoids ambiguous
/// common-property edits while still allowing move/delete/duplicate across a
/// useful group of captions, annotations, zooms, speed regions, or cursor
/// treatments.
public struct TimelineSelection: Sendable, Equatable {
    public private(set) var items: Set<TimelineItemID>
    public private(set) var primary: TimelineItemID?

    public init(items: Set<TimelineItemID> = [], primary: TimelineItemID? = nil) {
        let preferredKind = primary?.kind
            ?? items.sorted(by: Self.stableOrder).first?.kind
        self.items = preferredKind.map { kind in
            Set(items.filter { $0.kind == kind })
        } ?? []
        self.primary = primary.flatMap { self.items.contains($0) ? $0 : nil }
            ?? self.items.sorted(by: Self.stableOrder).first
    }

    public var isEmpty: Bool { items.isEmpty }
    public var kind: TimelineItemID.Kind? {
        primary?.kind ?? items.sorted(by: Self.stableOrder).first?.kind
    }

    public mutating func select(_ item: TimelineItemID, extending: Bool) {
        if !extending || kind != item.kind {
            items = [item]
            primary = item
            return
        }
        if items.contains(item) {
            items.remove(item)
            if primary == item {
                primary = items.sorted(by: Self.stableOrder).first
            }
        } else {
            items.insert(item)
            primary = item
        }
    }

    public mutating func clear() {
        items.removeAll()
        primary = nil
    }

    public func reconciled(with document: ProjectDocument) -> TimelineSelection {
        TimelineSelection(
            items: Set(items.filter { document.containsTimelineItem($0) }),
            primary: primary
        )
    }

    private static func stableOrder(_ lhs: TimelineItemID, _ rhs: TimelineItemID) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct TimelineClipboard: Sendable, Hashable {
    public var zooms: [ZoomRange]
    public var speeds: [SpeedSegment]
    public var captions: [CaptionCue]
    public var annotations: [Annotation]
    public var cursorEffects: [CursorEffectRange]

    public init(
        zooms: [ZoomRange] = [],
        speeds: [SpeedSegment] = [],
        captions: [CaptionCue] = [],
        annotations: [Annotation] = [],
        cursorEffects: [CursorEffectRange] = []
    ) {
        self.zooms = zooms
        self.speeds = speeds
        self.captions = captions
        self.annotations = annotations
        self.cursorEffects = cursorEffects
    }

    public var isEmpty: Bool {
        zooms.isEmpty && speeds.isEmpty && captions.isEmpty
            && annotations.isEmpty && cursorEffects.isEmpty
    }

    public var earliestStart: TimeInterval? {
        let starts = zooms.map(\.start) + speeds.map(\.start)
            + captions.map(\.start) + annotations.map(\.start)
            + cursorEffects.map(\.start)
        return starts.min()
    }
}

public struct TimelinePasteResult: Sendable, Equatable {
    public var document: ProjectDocument
    public var selection: TimelineSelection

    public init(document: ProjectDocument, selection: TimelineSelection) {
        self.document = document
        self.selection = selection
    }
}

public struct TimelineSnapTarget: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case playhead
        case trim
        case editDecision
        case caption
        case annotation
        case timelineItem
    }

    public var time: TimeInterval
    public var kind: Kind

    public init(time: TimeInterval, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

public struct TimelineSnapResult: Sendable, Equatable {
    public var time: TimeInterval
    public var target: TimelineSnapTarget?

    public init(time: TimeInterval, target: TimelineSnapTarget?) {
        self.time = time
        self.target = target
    }
}

public enum TimelineSnapping: Sendable {
    public static func snap(
        _ proposed: TimeInterval,
        targets: [TimelineSnapTarget],
        threshold: TimeInterval,
        disabled: Bool = false
    ) -> TimelineSnapResult {
        guard proposed.isFinite, !disabled else {
            return TimelineSnapResult(time: proposed.isFinite ? proposed : 0, target: nil)
        }
        let distance = max(threshold.isFinite ? threshold : 0, 0)
        let candidates = targets
            .filter { $0.time.isFinite && abs($0.time - proposed) <= distance }
            .sorted {
                let lhs = abs($0.time - proposed)
                let rhs = abs($1.time - proposed)
                if lhs != rhs { return lhs < rhs }
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.time < $1.time
            }
        guard let target = candidates.first else {
            return TimelineSnapResult(time: proposed, target: nil)
        }
        return TimelineSnapResult(time: target.time, target: target)
    }

    public static func targets(
        in document: ProjectDocument,
        playhead: TimeInterval,
        sourceDuration: TimeInterval,
        excluding selection: TimelineSelection = TimelineSelection()
    ) -> [TimelineSnapTarget] {
        let excluded = selection.items
        var values = [TimelineSnapTarget(time: playhead, kind: .playhead)]
        values.append(TimelineSnapTarget(time: document.trimIn, kind: .trim))
        values.append(TimelineSnapTarget(
            time: min(document.trimOut ?? sourceDuration, sourceDuration),
            kind: .trim
        ))
        for value in document.editDecisions {
            values.append(TimelineSnapTarget(time: value.start, kind: .editDecision))
            values.append(TimelineSnapTarget(time: value.end, kind: .editDecision))
        }
        for value in document.captions where !excluded.contains(.caption(value.id)) {
            values.append(TimelineSnapTarget(time: value.start, kind: .caption))
            values.append(TimelineSnapTarget(time: value.end, kind: .caption))
        }
        for value in document.annotations where !excluded.contains(.annotation(value.id)) {
            values.append(TimelineSnapTarget(time: value.start, kind: .annotation))
            values.append(TimelineSnapTarget(time: value.end, kind: .annotation))
        }
        for value in document.zoomRanges where !excluded.contains(.zoom(value.id)) {
            values.append(TimelineSnapTarget(time: value.start, kind: .timelineItem))
            values.append(TimelineSnapTarget(time: value.end, kind: .timelineItem))
        }
        for value in document.speedSegments where !excluded.contains(.speed(value.id)) {
            values.append(TimelineSnapTarget(time: value.start, kind: .timelineItem))
            values.append(TimelineSnapTarget(time: value.end, kind: .timelineItem))
        }
        for value in document.cursorEffects where !excluded.contains(.cursorEffect(value.id)) {
            values.append(TimelineSnapTarget(time: value.start, kind: .timelineItem))
            values.append(TimelineSnapTarget(time: value.end, kind: .timelineItem))
        }
        return values
    }
}

public enum ProjectTimelineOperations: Sendable {
    public static func copy(
        from document: ProjectDocument,
        selection: TimelineSelection
    ) -> TimelineClipboard {
        let items = selection.items
        return TimelineClipboard(
            zooms: document.zoomRanges.filter { items.contains(.zoom($0.id)) },
            speeds: document.speedSegments.filter { items.contains(.speed($0.id)) },
            captions: document.captions.filter { items.contains(.caption($0.id)) },
            annotations: document.annotations.filter { items.contains(.annotation($0.id)) },
            cursorEffects: document.cursorEffects.filter { items.contains(.cursorEffect($0.id)) }
        )
    }

    public static func deleting(
        from document: ProjectDocument,
        selection: TimelineSelection
    ) -> ProjectDocument {
        var value = document
        let items = selection.items
        value.zoomRanges.removeAll { items.contains(.zoom($0.id)) }
        value.speedSegments.removeAll { items.contains(.speed($0.id)) }
        value.captions.removeAll { items.contains(.caption($0.id)) }
        value.annotations.removeAll { items.contains(.annotation($0.id)) }
        value.cursorEffects.removeAll { items.contains(.cursorEffect($0.id)) }
        return value
    }

    public static func paste(
        _ clipboard: TimelineClipboard,
        into document: ProjectDocument,
        at start: TimeInterval,
        sourceDuration: TimeInterval
    ) -> TimelinePasteResult {
        guard let earliest = clipboard.earliestStart else {
            return TimelinePasteResult(document: document, selection: TimelineSelection())
        }
        let delta = (start.isFinite ? start : 0) - earliest
        var value = document
        var inserted: [TimelineItemID] = []

        for raw in clipboard.zooms {
            var item = raw
            item.id = UUID()
            shift(&item.start, &item.end, delta: delta, sourceDuration: sourceDuration)
            value.zoomRanges.append(item)
            inserted.append(.zoom(item.id))
        }
        for raw in clipboard.speeds {
            var item = raw
            item.id = UUID()
            shift(&item.start, &item.end, delta: delta, sourceDuration: sourceDuration)
            value.speedSegments.append(item)
            inserted.append(.speed(item.id))
        }
        for raw in clipboard.captions {
            var item = raw
            item.id = UUID()
            shift(&item.start, &item.end, delta: delta, sourceDuration: sourceDuration)
            value.captions.append(item)
            inserted.append(.caption(item.id))
        }
        for raw in clipboard.annotations {
            var item = raw
            item.id = UUID()
            shift(&item.start, &item.end, delta: delta, sourceDuration: sourceDuration)
            value.annotations.append(item)
            inserted.append(.annotation(item.id))
        }
        for raw in clipboard.cursorEffects {
            var item = raw
            item.id = UUID()
            shift(&item.start, &item.end, delta: delta, sourceDuration: sourceDuration)
            value.cursorEffects.append(item)
            inserted.append(.cursorEffect(item.id))
        }

        value = sorted(value).normalizedForTimelineEditing(sourceDuration: sourceDuration)
        let selection = TimelineSelection(items: Set(inserted), primary: inserted.first)
            .reconciled(with: value)
        return TimelinePasteResult(
            document: value,
            selection: selection
        )
    }

    public static func moving(
        selection: TimelineSelection,
        in document: ProjectDocument,
        by proposedDelta: TimeInterval,
        sourceDuration: TimeInterval,
        snapTargets: [TimelineSnapTarget] = [],
        snapThreshold: TimeInterval = 0,
        snappingDisabled: Bool = false
    ) -> TimelinePasteResult {
        let clipboard = copy(from: document, selection: selection)
        guard let earliest = clipboard.earliestStart else {
            return TimelinePasteResult(document: document, selection: selection)
        }
        let latest = latestEnd(in: clipboard) ?? earliest
        let lowerDelta = -earliest
        let upperDelta = max(sourceDuration - latest, lowerDelta)
        var delta = min(max(proposedDelta.isFinite ? proposedDelta : 0, lowerDelta), upperDelta)
        if !snapTargets.isEmpty {
            let result = TimelineSnapping.snap(
                earliest + delta,
                targets: snapTargets,
                threshold: snapThreshold,
                disabled: snappingDisabled
            )
            delta = min(max(result.time - earliest, lowerDelta), upperDelta)
        }

        var value = document
        let items = selection.items
        for index in value.zoomRanges.indices where items.contains(.zoom(value.zoomRanges[index].id)) {
            value.zoomRanges[index].start += delta
            value.zoomRanges[index].end += delta
        }
        for index in value.speedSegments.indices where items.contains(.speed(value.speedSegments[index].id)) {
            value.speedSegments[index].start += delta
            value.speedSegments[index].end += delta
        }
        for index in value.captions.indices where items.contains(.caption(value.captions[index].id)) {
            value.captions[index].start += delta
            value.captions[index].end += delta
        }
        for index in value.annotations.indices where items.contains(.annotation(value.annotations[index].id)) {
            value.annotations[index].start += delta
            value.annotations[index].end += delta
        }
        for index in value.cursorEffects.indices where items.contains(.cursorEffect(value.cursorEffects[index].id)) {
            value.cursorEffects[index].start += delta
            value.cursorEffects[index].end += delta
        }
        value = sorted(value).normalizedForTimelineEditing(sourceDuration: sourceDuration)
        return TimelinePasteResult(
            document: value,
            selection: selection.reconciled(with: value)
        )
    }

    public static func duplicate(
        selection: TimelineSelection,
        in document: ProjectDocument,
        offset: TimeInterval = 0.25,
        sourceDuration: TimeInterval
    ) -> TimelinePasteResult {
        let clipboard = copy(from: document, selection: selection)
        let start = (clipboard.earliestStart ?? 0) + max(offset, 0)
        return paste(clipboard, into: document, at: start, sourceDuration: sourceDuration)
    }

    private static func shift(
        _ start: inout TimeInterval,
        _ end: inout TimeInterval,
        delta: TimeInterval,
        sourceDuration: TimeInterval
    ) {
        let originalDuration = max(end - start, TimelineRangeEditing.minimumOverlayDuration)
        let upper = max(sourceDuration, 0)
        start = min(max(start + delta, 0), max(upper - originalDuration, 0))
        end = min(start + originalDuration, upper)
    }

    private static func latestEnd(in clipboard: TimelineClipboard) -> TimeInterval? {
        let ends = clipboard.zooms.map(\.end) + clipboard.speeds.map(\.end)
            + clipboard.captions.map(\.end) + clipboard.annotations.map(\.end)
            + clipboard.cursorEffects.map(\.end)
        return ends.max()
    }

    private static func sorted(_ document: ProjectDocument) -> ProjectDocument {
        var value = document
        value.zoomRanges.sort(by: rangeOrder)
        value.speedSegments.sort(by: rangeOrder)
        value.captions.sort(by: rangeOrder)
        value.annotations.sort(by: rangeOrder)
        value.cursorEffects.sort(by: rangeOrder)
        return value
    }

    private static func rangeOrder<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool
    where T.ID == UUID {
        func bounds(_ value: T) -> (TimeInterval, TimeInterval) {
            switch value {
            case let value as ZoomRange: (value.start, value.end)
            case let value as SpeedSegment: (value.start, value.end)
            case let value as CaptionCue: (value.start, value.end)
            case let value as Annotation: (value.start, value.end)
            case let value as CursorEffectRange: (value.start, value.end)
            default: (0, 0)
            }
        }
        let left = bounds(lhs)
        let right = bounds(rhs)
        if left.0 != right.0 { return left.0 < right.0 }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public extension ProjectDocument {
    func containsTimelineItem(_ item: TimelineItemID) -> Bool {
        switch item {
        case .zoom(let id): zoomRanges.contains { $0.id == id }
        case .speed(let id): speedSegments.contains { $0.id == id }
        case .caption(let id): captions.contains { $0.id == id }
        case .annotation(let id): annotations.contains { $0.id == id }
        case .cursorEffect(let id): cursorEffects.contains { $0.id == id }
        }
    }
}
