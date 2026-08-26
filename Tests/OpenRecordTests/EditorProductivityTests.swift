import Foundation
import OpenRecord
import Testing

@Test
func timelineSelectionStaysLaneCompatibleAndReconciles() {
    let captionA = CaptionCue(start: 1, end: 2, text: "A")
    let captionB = CaptionCue(start: 3, end: 4, text: "B")
    let annotation = Annotation.textCallout(start: 2, end: 3)
    let document = ProjectDocument(captions: [captionA, captionB], annotations: [annotation])

    var selection = TimelineSelection()
    selection.select(.caption(captionA.id), extending: false)
    selection.select(.caption(captionB.id), extending: true)
    #expect(selection.items.count == 2)
    selection.select(.annotation(annotation.id), extending: true)
    #expect(selection.items == [.annotation(annotation.id)])

    selection = TimelineSelection(items: [.caption(captionA.id), .caption(captionB.id)])
    var changed = document
    changed.captions.removeFirst()
    #expect(selection.reconciled(with: changed).items == [.caption(captionB.id)])
}

@Test
func timelineCopyPasteDuplicateAndDeleteAreDeterministic() {
    let first = CaptionCue(start: 1, end: 2, text: "First")
    let second = CaptionCue(start: 3, end: 5, text: "Second")
    let document = ProjectDocument(captions: [first, second])
    let selection = TimelineSelection(items: [.caption(first.id), .caption(second.id)])
    let clipboard = ProjectTimelineOperations.copy(from: document, selection: selection)
    let pasted = ProjectTimelineOperations.paste(
        clipboard,
        into: document,
        at: 6,
        sourceDuration: 12
    )

    #expect(pasted.document.captions.count == 4)
    #expect(pasted.selection.items.count == 2)
    let inserted = pasted.document.captions.filter { pasted.selection.items.contains(.caption($0.id)) }
    #expect(inserted.map(\.start) == [6, 8])
    #expect(inserted.map(\.end) == [7, 10])
    #expect(Set(inserted.map(\.id)).isDisjoint(with: [first.id, second.id]))

    let deleted = ProjectTimelineOperations.deleting(
        from: pasted.document,
        selection: pasted.selection
    )
    #expect(deleted == document)

    let duplicated = ProjectTimelineOperations.duplicate(
        selection: selection,
        in: document,
        offset: 0.5,
        sourceDuration: 12
    )
    let duplicateItems = duplicated.document.captions.filter {
        duplicated.selection.items.contains(.caption($0.id))
    }
    #expect(duplicateItems.map(\.start) == [1.5, 3.5])
}

@Test
func timelineMoveClampsAndSnapsAsOneGroup() {
    let a = Annotation.textCallout(start: 2, end: 3)
    let b = Annotation.textCallout(start: 4, end: 6)
    let document = ProjectDocument(annotations: [a, b])
    let selection = TimelineSelection(items: [.annotation(a.id), .annotation(b.id)])
    let moved = ProjectTimelineOperations.moving(
        selection: selection,
        in: document,
        by: 2.92,
        sourceDuration: 10,
        snapTargets: [TimelineSnapTarget(time: 5, kind: .playhead)],
        snapThreshold: 0.1
    )
    #expect(moved.document.annotations.map(\.start) == [5, 7])
    #expect(moved.document.annotations.map(\.end) == [6, 9])

    let clamped = ProjectTimelineOperations.moving(
        selection: selection,
        in: document,
        by: -100,
        sourceDuration: 10
    )
    #expect(clamped.document.annotations.map(\.start) == [0, 2])
    #expect(clamped.document.annotations.map(\.end) == [1, 4])
}

@Test
func timelineSnappingUsesStableNearestTargetAndCanBeDisabled() {
    let targets = [
        TimelineSnapTarget(time: 4, kind: .annotation),
        TimelineSnapTarget(time: 4.1, kind: .playhead),
    ]
    #expect(TimelineSnapping.snap(4.08, targets: targets, threshold: 0.1).time == 4.1)
    #expect(TimelineSnapping.snap(4.08, targets: targets, threshold: 0.1, disabled: true).time == 4.08)
    #expect(TimelineSnapping.snap(7, targets: targets, threshold: 0.1).target == nil)
}
