import Darwin
import Foundation
import Testing
import OpenRecord

enum ProjectDocumentJSONRoundTrip {
    static func run() throws {
        guard CanvasSettings.default.cursorScale == 0.5,
              CanvasSettings.cursorScaleRange.lowerBound == 0.1
        else {
            throw OpenRecordError.io("Cursor scale should default to 0.5× and allow adjustment down to 0.1×")
        }

        let sprite = CursorSprite(
            id: "arrow",
            hotspot: Point2D(x: 4, y: 2),
            pngRelativePath: "recording/cursors/arrow.png",
            standardSize: Size2D(width: 32, height: 32)
        )
        let zoom = ZoomRange(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            start: 1.25,
            end: 3.5,
            amount: 2,
            anchor: Point2D(x: 0.5, y: 0.25)
        )
        let original = ProjectDocument(
            formatVersion: ProjectDocument.currentFormatVersion,
            trimIn: 0.5,
            trimOut: 12,
            zoomRanges: [zoom],
            canvas: CanvasSettings(
                background: .linearGradient(
                    start: RGBAColor(r: 0.25, g: 0.5, b: 0.75, a: 1),
                    end: RGBAColor(r: 0.75, g: 0.25, b: 0.5, a: 1),
                    startPoint: Point2D(x: 0, y: 0),
                    endPoint: Point2D(x: 1, y: 1)
                ),
                padding: 40,
                cornerRadius: 12,
                cursorScale: 1.5,
                aspectWidth: 16,
                aspectHeight: 9
            ),
            cursorSprites: [sprite]
        )

        let data = try ProjectJSON.encoder.encode(original)
        let decoded = try ProjectJSON.decoder.decode(ProjectDocument.self, from: data)
        guard decoded == original else {
            throw OpenRecordError.io("ProjectDocument JSON round-trip produced a different value")
        }

        try assertUndoHistoryCoalescesContinuousEdits()
    }

    private static func assertUndoHistoryCoalescesContinuousEdits() throws {
        let original = ProjectDocument(trimIn: 0, trimOut: 12)
        var intermediate = original
        intermediate.trimIn = 1
        var edited = original
        edited.trimIn = 2

        var history = ProjectDocumentHistory()
        history.begin(document: original, actionName: "Adjust Trim")
        history.record(before: original, after: intermediate, actionName: "Adjust Trim")
        history.record(before: intermediate, after: edited, actionName: "Adjust Trim")
        history.commit(currentDocument: edited)

        guard history.canUndo,
              !history.canRedo,
              history.undoActionName == "Adjust Trim",
              history.undo(currentDocument: edited) == original,
              !history.canUndo,
              history.canRedo,
              history.redo(currentDocument: original) == edited
        else {
            throw OpenRecordError.io("Continuous document edits did not coalesce into one undo step")
        }

        guard history.undo(currentDocument: edited) == original else {
            throw OpenRecordError.io("Undo history could not restore the original document")
        }
        var divergent = original
        divergent.canvas.padding = 8
        history.record(before: original, after: divergent, actionName: "Change Padding")
        guard !history.canRedo, history.undoActionName == "Change Padding" else {
            throw OpenRecordError.io("A divergent edit did not clear the redo stack")
        }
    }
}

@Test
func projectDocumentJSONRoundTrip() throws {
    try ProjectDocumentJSONRoundTrip.run()
}

/// Mach-O constructor: CLT `swift test` dlopens the bundle without reliably
/// running Swift Testing's `@main`, so the round-trip must run at load.
#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunProjectDocumentJSONRoundTrip()
}

/// Invoked from the Mach-O constructor on test-bundle `dlopen`.
@_cdecl("OpenRecordRunProjectDocumentJSONRoundTrip")
func OpenRecordRunProjectDocumentJSONRoundTrip() {
    do {
        try ProjectDocumentJSONRoundTrip.run()
        fputs("OpenRecordTests: ProjectDocument JSON round-trip passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: ProjectDocument JSON round-trip failed\n", stderr)
        abort()
    }
}
#endif
