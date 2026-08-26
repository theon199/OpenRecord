import Darwin
import Foundation
import OpenRecord
import Testing

/// CLT Swift Testing discovery is not reliable on every supported host. This
/// constructor-backed suite keeps the Checkpoint-2 contracts active alongside
/// the ordinary `@Test` cases above.
enum V3CheckpointSmokeSuite {
    static let testCount = 12

    static func run() throws {
        try transcriptionNormalizationAndDisplay()
        try captionRegenerationPreservesEdits()
        try transcriptSourceFilteringAndRangeSelection()
        try silencePresetsAndBreathingRoom()
        try transcriptGapsAndAcceptedDecisions()
        try audioLevelTimelineMappingUsesCaptureRate()
        try smartZoomContracts()
        try productivityContracts()
        try presetContracts()
        try zoomTrackingContract()
        try undoGeneratedCutsContract()
        try schemaRoundTripContract()
    }

    private static func smartZoomContracts() throws {
        let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
        let dwellSamples = (0...60).map { index -> CursorSample in
            let time = Double(index) / 30
            return CursorSample(
                t: time,
                x: time < 1 ? 100 + time * 700 : 800,
                y: 400
            )
        }
        let dwell = SmartAutoZoom.generateRanges(
            samples: dwellSamples,
            duration: 2,
            displayBounds: bounds,
            config: SmartAutoZoomConfig(minDwell: 0.6)
        )
        guard dwell.contains(where: {
            $0.source == .automatic && $0.tracking == .fixed && $0.end - $0.start >= 0.6
        }) else {
            throw OpenRecordError.io("Smart zoom did not produce a fixed dwell range")
        }

        let transit = SmartAutoZoom.generateRanges(
            samples: [
                CursorSample(t: 0, x: 0, y: 400),
                CursorSample(t: 0.04, x: 960, y: 400),
                CursorSample(t: 0.08, x: 1_920, y: 400),
            ],
            duration: 1,
            displayBounds: bounds
        )
        guard transit.isEmpty else {
            throw OpenRecordError.io("Smart zoom treated fast transit as an interaction")
        }

        let locked = ZoomRange(
            start: 1.5,
            end: 2.5,
            amount: 2,
            anchor: Point2D(x: 0.5, y: 0.5),
            tracking: .fixed,
            isLocked: true,
            source: .manual
        )
        let regenerated = SmartAutoZoom.regenerateRanges(
            existing: [locked],
            samples: stride(from: 0.0, through: 4.0, by: 0.05).map {
                CursorSample(t: $0, x: $0 < 2 ? 200 : 1_700, y: 500)
            },
            duration: 4,
            displayBounds: bounds
        )
        guard regenerated.contains(where: { $0.id == locked.id }),
              regenerated.filter({ $0.source == .automatic }).allSatisfy({
                  $0.end <= locked.start || $0.start >= locked.end
              })
        else {
            throw OpenRecordError.io("Smart zoom regeneration changed a locked/manual range")
        }
    }

    private static func productivityContracts() throws {
        let first = CaptionCue(start: 1, end: 2, text: "First")
        let second = CaptionCue(start: 3, end: 5, text: "Second")
        let document = ProjectDocument(captions: [first, second])
        let selection = TimelineSelection(items: [.caption(first.id), .caption(second.id)])
        let pasted = ProjectTimelineOperations.paste(
            ProjectTimelineOperations.copy(from: document, selection: selection),
            into: document,
            at: 6,
            sourceDuration: 12
        )
        let inserted = pasted.document.captions.filter {
            pasted.selection.items.contains(.caption($0.id))
        }
        guard inserted.map(\.start) == [6, 8],
              inserted.map(\.end) == [7, 10],
              pasted.selection.primary == .caption(inserted[0].id),
              ProjectTimelineOperations.deleting(
                  from: pasted.document,
                  selection: pasted.selection
              ) == document
        else {
            throw OpenRecordError.io("Timeline copy/paste/delete did not preserve relative timing")
        }

        var history = ProjectDocumentHistory()
        history.record(
            before: document,
            after: pasted.document,
            actionName: "Paste Timeline Items"
        )
        guard history.undo(currentDocument: pasted.document) == document,
              history.redo(currentDocument: document) == pasted.document
        else {
            throw OpenRecordError.io("Timeline paste was not an intentional undo/redo step")
        }

        let snapped = TimelineSnapping.snap(
            4.08,
            targets: [TimelineSnapTarget(time: 4.1, kind: .playhead)],
            threshold: 0.1
        )
        guard snapped.time == 4.1 else {
            throw OpenRecordError.io("Timeline edit did not snap to the playhead")
        }
    }

    private static func presetContracts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordV3PresetSmoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let preset = EditorStylePreset(
            id: "smoke/preset",
            name: "Smoke",
            caption: CaptionStyle(fontSize: 58),
            cursor: CursorStylePreset(scale: 0.8, clickEmphasis: false, halo: true)
        )
        let store = LocalPresetStore(directoryURL: root)
        _ = try store.save(preset)
        guard try store.load() == [preset] else {
            throw OpenRecordError.io("Local JSON preset did not round-trip")
        }
        let applied = preset.applying(to: ProjectDocument(
            captions: [CaptionCue(start: 0, end: 1, text: "Caption")],
            cursorEffects: [CursorEffectRange(start: 0, end: 1)]
        ))
        guard applied.captions[0].style.fontSize == 58,
              applied.cursorEffects[0].halo,
              applied.canvas.cursorClickEmphasis == false,
              applied.canvas.cursorHalo,
              applied.appliedPresetIDs == [preset.id]
        else {
            throw OpenRecordError.io("Preset values were not copied into the project")
        }
    }

    private static func zoomTrackingContract() throws {
        let bounds = Rect2D(x: 0, y: 0, width: 100, height: 100)
        let samples = [
            CursorSample(t: 0, x: 10, y: 50),
            CursorSample(t: 3, x: 90, y: 50),
        ]
        let fixed = ZoomRange(
            start: 0,
            end: 4,
            amount: 2,
            anchor: Point2D(x: 0.5, y: 0.5),
            tracking: .fixed
        )
        var follow = fixed
        follow.id = UUID()
        follow.tracking = .followCursor
        let fixedCrop = ZoomEngine(
            document: ProjectDocument(zoomRanges: [fixed]),
            samples: samples,
            displayBounds: bounds
        ).crop(at: 2.5)
        let followCrop = ZoomEngine(
            document: ProjectDocument(zoomRanges: [follow]),
            samples: samples,
            displayBounds: bounds
        ).crop(at: 2.5)
        guard abs(fixedCrop.midX - 0.5) < 0.05,
              followCrop.midX > fixedCrop.midX + 0.08
        else {
            throw OpenRecordError.io("Fixed/follow-cursor zoom modes did not diverge")
        }
    }

    private static func undoGeneratedCutsContract() throws {
        let before = ProjectDocument(trimOut: 8)
        var after = before
        after.editDecisions = [EditDecision(start: 2, end: 3)]
        var history = ProjectDocumentHistory()
        history.record(before: before, after: after, actionName: "Remove Suggested Pauses")
        guard history.undoActionName == "Remove Suggested Pauses",
              history.undo(currentDocument: after) == before,
              history.redo(currentDocument: before) == after
        else {
            throw OpenRecordError.io("Generated smart cuts were not one intentional undo step")
        }
    }

    private static func schemaRoundTripContract() throws {
        let segment = TranscriptSegment(
            start: 1,
            end: 2,
            recognizedText: "recognized",
            editedText: "corrected",
            source: .microphone
        )
        let document = ProjectDocument(
            zoomRanges: [ZoomRange(
                start: 0,
                end: 2,
                amount: 2,
                anchor: Point2D(x: 0.5, y: 0.5),
                tracking: .fixed,
                isLocked: true,
                source: .automatic
            )],
            transcript: [segment],
            cursorEffects: [CursorEffectRange(start: 0, end: 2, halo: true)],
            appliedPresetIDs: ["tutorial"]
        )
        let decoded = try ProjectJSON.decoder.decode(
            ProjectDocument.self,
            from: ProjectJSON.encoder.encode(document)
        )
        guard decoded == document,
              decoded.transcript[0].recognizedText == "recognized",
              decoded.transcript[0].editedText == "corrected"
        else {
            throw OpenRecordError.io("Format-v7 smart-editing fields did not round-trip")
        }
    }
}

@Test
func v3CheckpointSmokeContracts() throws {
    try V3CheckpointSmokeSuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV3CheckpointSmokeTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunV3CheckpointSmokeTests()
}

@_cdecl("OpenRecordRunV3CheckpointSmokeTests")
func OpenRecordRunV3CheckpointSmokeTests() {
    do {
        try V3CheckpointSmokeSuite.run()
        fputs(
            "OpenRecordTests: V3CheckpointSmokeTests files=1 tests=\(V3CheckpointSmokeSuite.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: V3CheckpointSmokeTests files=1 tests=\(V3CheckpointSmokeSuite.testCount) failures=1 error=\(error)\n",
            stderr
        )
        abort()
    }
}
#endif
