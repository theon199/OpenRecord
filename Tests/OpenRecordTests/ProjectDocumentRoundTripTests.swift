import Darwin
import Foundation
import Testing
import OpenRecord

enum ProjectDocumentJSONRoundTrip {
    static func run() throws {
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
                background: .solid(RGBAColor(r: 0.25, g: 0.5, b: 0.75, a: 1)),
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
    }
}

@Test
func projectDocumentJSONRoundTrip() throws {
    try ProjectDocumentJSONRoundTrip.run()
}

/// Mach-O constructor: CLT `swift test` dlopens the bundle without reliably
/// running Swift Testing's `@main`, so the round-trip must run at load.
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
