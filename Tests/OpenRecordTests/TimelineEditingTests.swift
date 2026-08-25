import Darwin
import Foundation
import OpenRecord
import Testing

enum TimelineEditingSuite {
    static let testCount = 8

    static func run() throws {
        try nearZeroRangesStayInsideBounds()
        try malformedDocumentRangesAreRepairedForEditing()
        try narrowAndOverlappingBlocksHitDeterministically()
        try deletedSpeedSelectionRestoresThroughUndoRedo()
        try trimHandlesCannotCross()
        try exactZoomEndUsesHalfOpenBoundary()
        try movingAcrossTimelineEdgesPreservesDuration()
        try nonFiniteValuesAreDeterministic()
    }

    static func nearZeroRangesStayInsideBounds() throws {
        guard let repaired = TimelineRangeEditing.normalized(
            TimelineEditRange(start: 0, end: 0.05),
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: SpeedTimeline.minimumSegmentDuration
        ), repaired == TimelineEditRange(start: 0, end: 0.12),
        let resized = TimelineRangeEditing.resizingStart(
            TimelineEditRange(start: 0, end: 0.05),
            to: 2,
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: SpeedTimeline.minimumSegmentDuration
        ), resized.start >= 0,
        resized.end <= 10,
        close(resized.duration, SpeedTimeline.minimumSegmentDuration)
        else {
            throw OpenRecordError.io("near-zero timeline range escaped its bounds")
        }
    }

    static func malformedDocumentRangesAreRepairedForEditing() throws {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let document = ProjectDocument(
            trimIn: 12,
            trimOut: 2,
            zoomRanges: [
                ZoomRange(id: firstID, start: 1, end: 4, amount: 2, anchor: Point2D(x: 0.5, y: 0.5)),
                ZoomRange(id: secondID, start: 2, end: 2.01, amount: .nan, anchor: Point2D(x: -1, y: 2)),
            ],
            speedSegments: [
                SpeedSegment(start: 0, end: 0.05, rate: 2),
                SpeedSegment(start: 4, end: 5, rate: 2),
                SpeedSegment(start: 5, end: 6, rate: 0.5),
            ],
            captions: [CaptionCue(start: 9.99, end: 12, text: "edge")],
            annotations: [.arrow(start: -2, end: -1)]
        )
        let repaired = document.normalizedForTimelineEditing(sourceDuration: 10)

        guard document.normalizedForTimelineEditing(sourceDuration: 0) == document,
              close(repaired.trimIn, 9.9), close(repaired.trimOut ?? -1, 10),
              repaired.zoomRanges.count == 2,
              repaired.zoomRanges[0].end <= repaired.zoomRanges[1].start,
              repaired.zoomRanges.allSatisfy({ $0.start >= 0 && $0.end <= 10 && $0.end - $0.start >= 0.12 }),
              repaired.zoomRanges[1].amount == 1.8,
              repaired.zoomRanges[1].anchor == Point2D(x: 0, y: 1),
              repaired.speedSegments.count == 2,
              repaired.speedSegments[0].end == repaired.speedSegments[1].start,
              close(repaired.captions[0].start, 9.95),
              close(repaired.captions[0].end, 10),
              repaired.annotations[0].start == 0,
              close(repaired.annotations[0].end, 0.05)
        else {
            throw OpenRecordError.io("malformed project ranges were not repaired deterministically")
        }
    }

    static func narrowAndOverlappingBlocksHitDeterministically() throws {
        let backID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let frontID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let ranges = [
            TimelineHitRange(id: backID, start: 1, end: 3),
            TimelineHitRange(id: frontID, start: 1, end: 1),
        ]

        guard TimelineHitTesting.hit(
            at: 1.4,
            ranges: ranges,
            handleTolerance: 0.1,
            minimumVisibleDuration: 0.8
        ) == .body(frontID, grabOffset: 0),
        TimelineHitTesting.hit(
            at: 1.75,
            ranges: ranges,
            handleTolerance: 0.1,
            minimumVisibleDuration: 0.8
        ) == .end(frontID),
        TimelineHitTesting.hit(
            at: 2,
            ranges: ranges,
            handleTolerance: 0.1,
            minimumVisibleDuration: 0.8
        ) == .body(backID, grabOffset: 1)
        else {
            throw OpenRecordError.io("narrow or overlapping block hit testing was ambiguous")
        }
    }

    static func deletedSpeedSelectionRestoresThroughUndoRedo() throws {
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let original = ProjectDocument(speedSegments: [SpeedSegment(id: id, start: 1, end: 2)])
        let deleted = ProjectDocument()
        var history = ProjectDocumentHistory()
        history.record(before: original, after: deleted, actionName: "Delete Speed Region")

        guard let restored = history.undo(currentDocument: deleted), restored == original,
              EditorDocumentSelection.reconciled(
                current: nil,
                previousDocument: deleted,
                restoredDocument: restored
              ) == .speed(id),
              let redone = history.redo(currentDocument: restored), redone == deleted,
              EditorDocumentSelection.reconciled(
                current: .speed(id),
                previousDocument: restored,
                restoredDocument: redone
              ) == nil,
              EditorDocumentSelection.reconciled(
                current: .speed(id),
                previousDocument: deleted,
                restoredDocument: original.normalizedForTimelineEditing(sourceDuration: 0.05)
              ) == nil
        else {
            throw OpenRecordError.io("speed deletion undo/redo did not reconcile selection")
        }
    }

    static func trimHandlesCannotCross() throws {
        let original = TimelineEditRange(start: 2, end: 4)
        guard let crossingIn = TimelineRangeEditing.resizingStart(
            original,
            to: 9,
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: TimelineRangeEditing.minimumTrimDuration
        ),
        let crossingOut = TimelineRangeEditing.resizingEnd(
            original,
            to: 1,
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: TimelineRangeEditing.minimumTrimDuration
        ),
        close(crossingIn.end, original.end),
              crossingIn.start >= 0,
              crossingIn.duration + 0.000_000_1 >= TimelineRangeEditing.minimumTrimDuration,
              close(crossingOut.start, original.start),
              crossingOut.duration + 0.000_000_1 >= TimelineRangeEditing.minimumTrimDuration
        else {
            throw OpenRecordError.io("crossed trim handles produced an invalid range")
        }
    }

    static func exactZoomEndUsesHalfOpenBoundary() throws {
        let firstID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let secondID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let first = ZoomRange(id: firstID, start: 1, end: 3, amount: 2, anchor: Point2D(x: 0.5, y: 0.5))
        let second = ZoomRange(id: secondID, start: 3, end: 5, amount: 2, anchor: Point2D(x: 0.5, y: 0.5))

        guard ZoomInsertion.proposal(at: 1, timelineDuration: 10, ranges: [first]) == .select(firstID),
              ZoomInsertion.proposal(at: 3, timelineDuration: 10, ranges: [first]) == .create(start: 3, end: 5),
              ZoomInsertion.proposal(at: 3, timelineDuration: 10, ranges: [first, second]) == .select(secondID)
        else {
            throw OpenRecordError.io("zoom insertion disagreed with half-open timeline boundaries")
        }
    }

    static func movingAcrossTimelineEdgesPreservesDuration() throws {
        let original = TimelineEditRange(start: 2, end: 4)
        guard let beforeStart = TimelineRangeEditing.moving(
            original,
            toStart: -100,
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: 0.12
        ), beforeStart == TimelineEditRange(start: 0, end: 2),
        let afterEnd = TimelineRangeEditing.moving(
            original,
            toStart: 100,
            lowerBound: 0,
            upperBound: 10,
            minimumDuration: 0.12
        ), afterEnd == TimelineEditRange(start: 8, end: 10)
        else {
            throw OpenRecordError.io("moving across a timeline edge changed range duration")
        }
    }

    static func nonFiniteValuesAreDeterministic() throws {
        let original = TimelineEditRange(start: 2, end: 4)
        guard let resized = TimelineRangeEditing.resizingStart(
            original,
            to: .infinity,
            lowerBound: .nan,
            upperBound: 10,
            minimumDuration: .nan
        ), resized.start.isFinite, resized.end.isFinite
        else {
            throw OpenRecordError.io("non-finite editing bounds escaped sanitization")
        }

        let laterID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let document = ProjectDocument(zoomRanges: [
            ZoomRange(
                id: laterID,
                start: .nan,
                end: 1,
                amount: 2,
                anchor: Point2D(x: 0.5, y: 0.5)
            ),
            ZoomRange(
                id: earlierID,
                start: .nan,
                end: 1,
                amount: 2,
                anchor: Point2D(x: 0.5, y: 0.5)
            ),
        ])
        let first = document.normalizedForTimelineEditing(sourceDuration: 10)
        let second = document.normalizedForTimelineEditing(sourceDuration: 10)
        guard first.zoomRanges == second.zoomRanges,
              first.zoomRanges.first?.id == earlierID
        else {
            throw OpenRecordError.io("non-finite range sorting was not deterministic")
        }
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 0.000_000_1
    }
}

@Test
func timelineEditingPhase6Contracts() throws {
    try TimelineEditingSuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordTimelineEditingTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunTimelineEditingTests()
}

@_cdecl("OpenRecordRunTimelineEditingTests")
func OpenRecordRunTimelineEditingTests() {
    do {
        try TimelineEditingSuite.run()
        fputs(
            "OpenRecordTests: TimelineEditingTests files=1 tests=\(TimelineEditingSuite.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: TimelineEditingTests files=1 tests=\(TimelineEditingSuite.testCount) failures=1 error=\(error)\n",
            stderr
        )
        abort()
    }
}
#endif
