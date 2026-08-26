import CoreGraphics
import Darwin
import Foundation
import OpenRecord
import Testing

/// Deterministic contracts for the v3.1 visual content model. These tests use
/// the value types and shared layout/evaluation helpers directly so preview
/// and export are covered by the same assertions.
enum V31ContentSuite {
    static func run() throws {
        try normalizedRegionsAndVectorStrokes()
        try sourceTimedActivityUsesHalfOpenBoundaries()
        try visualContentRoundTripsThroughProjectJSON()
        try deviceFrameGeometryIsDeterministic()
        try annotationAnimationIsDeterministic()
        try webcamStyleRoundTrips()
        try loadTimeTimelineNormalizationRepairsV31Items()
        try visualItemsUseSharedTimelineOperationsAndMapper()
    }

    private static func normalizedRegionsAndVectorStrokes() throws {
        let redaction = RedactionRegion(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            start: -.infinity,
            end: .nan,
            rect: Rect2D(x: -2, y: 4, width: 2, height: -1),
            mode: .pixelate,
            strength: 4
        ).normalized
        guard redaction.start == 0,
              redaction.end == TimelineRangeEditing.minimumOverlayDuration,
              redaction.rect == Rect2D(x: 0, y: 0.98, width: 1, height: 0.02),
              redaction.mode == .pixelate,
              redaction.strength == RedactionRegion.strengthRange.upperBound
        else {
            throw failure("redaction normalization did not clamp its timeline, geometry, and strength")
        }

        let stroke = DrawingStroke(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            start: -2,
            end: -1,
            tool: .highlighter,
            points: [
                Point2D(x: -1, y: 2),
                Point2D(x: .nan, y: .infinity),
                Point2D(x: 0.25, y: 0.75),
            ],
            color: RGBAColor(r: -1, g: 2, b: .nan, a: 2),
            width: 999
        ).normalized
        guard stroke.start == 0,
              stroke.end == TimelineRangeEditing.minimumOverlayDuration,
              stroke.tool == .highlighter,
              stroke.points == [
                  Point2D(x: 0, y: 1),
                  Point2D(x: 0.5, y: 0.5),
                  Point2D(x: 0.25, y: 0.75),
              ],
              stroke.color == RGBAColor(r: 0, g: 1, b: 0, a: 1),
              stroke.width == DrawingStroke.widthRange.upperBound
        else {
            throw failure("drawing stroke normalization did not produce canonical vector values")
        }
    }

    private static func sourceTimedActivityUsesHalfOpenBoundaries() throws {
        let redaction = RedactionRegion(start: 1, end: 2)
        let stroke = DrawingStroke(start: 1, end: 2, points: [Point2D(x: 0.2, y: 0.3)])
        let annotation = Annotation(start: 1, end: 2, kind: .box)

        guard !redaction.isActive(at: 0.999),
              redaction.isActive(at: 1),
              redaction.isActive(at: 1.999),
              !redaction.isActive(at: 2),
              !stroke.isActive(at: 0.999),
              stroke.isActive(at: 1),
              !stroke.isActive(at: 2),
              !annotation.isActive(at: 0.999),
              annotation.isActive(at: 1),
              !annotation.isActive(at: 2)
        else {
            throw failure("source-timed visual activity was not half-open [start, end)")
        }
    }

    private static func visualContentRoundTripsThroughProjectJSON() throws {
        let redaction = RedactionRegion(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            start: 1.25,
            end: 3.5,
            rect: Rect2D(x: 0.1, y: 0.2, width: 0.4, height: 0.3),
            mode: .blur,
            strength: 0.72
        )
        let drawing = DrawingStroke(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            start: 2,
            end: 4,
            tool: .pen,
            points: [Point2D(x: 0.1, y: 0.2), Point2D(x: 0.8, y: 0.75)],
            color: RGBAColor(r: 0.9, g: 0.2, b: 0.1, a: 0.8),
            width: 12
        )
        let document = ProjectDocument(
            formatVersion: ProjectDocument.currentFormatVersion,
            redactions: [redaction],
            drawings: [drawing],
            deviceFrame: DeviceFrameSettings(id: .genericPhoneDark, scale: 0.8, shadow: false)
        )

        let data = try ProjectJSON.encoder.encode(document)
        let decoded = try ProjectJSON.decoder.decode(ProjectDocument.self, from: data)
        guard decoded == document,
              decoded.formatVersion == 6,
              decoded.redactions == [redaction],
              decoded.drawings == [drawing]
        else {
            throw failure("v3.1 vector content did not survive ProjectDocument JSON round-trip")
        }
    }

    private static func deviceFrameGeometryIsDeterministic() throws {
        let content = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let none = DeviceFrameLayout.geometry(
            settings: .none,
            contentRect: content
        )
        guard none.frameRect == content,
              none.screenRect == content,
              none.cornerRadius == 0,
              none.chromeHeight == 0
        else {
            throw failure("disabled device frame changed content geometry")
        }

        let settings = DeviceFrameSettings(id: .genericLaptopDark, scale: 0.8, shadow: true)
        let geometry = DeviceFrameLayout.geometry(settings: settings, contentRect: content)
        guard close(geometry.frameRect.midX, content.midX),
              close(geometry.frameRect.midY, content.midY),
              close(geometry.frameRect.width, 960),
              close(geometry.frameRect.height, 640),
              geometry.screenRect.minX > geometry.frameRect.minX,
              geometry.screenRect.minY > geometry.frameRect.minY,
              geometry.screenRect.maxX < geometry.frameRect.maxX,
              geometry.screenRect.maxY < geometry.frameRect.maxY,
              geometry.chromeHeight > 0,
              geometry.cornerRadius > 0
        else {
            throw failure("laptop device-frame geometry was not centered and inset deterministically")
        }

        let repeated = DeviceFrameLayout.geometry(settings: settings, contentRect: content)
        guard repeated == geometry else {
            throw failure("device-frame geometry changed between identical evaluations")
        }
    }

    private static func annotationAnimationIsDeterministic() throws {
        let annotation = Annotation(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            start: 2,
            end: 6,
            kind: .text,
            animation: AnnotationAnimation(
                entrance: .pop,
                exit: .fade,
                duration: 0.5
            )
        )
        let expected: [(TimeInterval, Double, Double)] = [
            (2, 0, 0.82),
            (2.25, 0.5, 0.91),
            (5.75, 0.5, 1),
            (6, 0, 1),
        ]
        for (time, opacity, scale) in expected {
            let first = AnnotationAnimationEvaluator.presentation(for: annotation, at: time)
            let second = AnnotationAnimationEvaluator.presentation(for: annotation, at: time)
            guard first == second,
                  close(first.opacity, opacity),
                  close(first.scale, scale)
            else {
                throw failure("annotation animation was not deterministic at t=\(time)")
            }
        }
    }

    private static func webcamStyleRoundTrips() throws {
        let settings = WebcamOverlaySettings(
            enabled: true,
            shape: .squircle,
            position: Point2D(x: 0.22, y: 0.78),
            size: 0.24,
            borderWidth: 7,
            borderColor: RGBAColor(r: 0.2, g: 0.7, b: 0.95, a: 0.85),
            cornerRadius: 0.31,
            shadow: true,
            shadowOpacity: 0.6,
            shadowRadius: 18
        )
        let data = try ProjectJSON.encoder.encode(settings)
        let decoded = try ProjectJSON.decoder.decode(WebcamOverlaySettings.self, from: data)
        guard decoded == settings,
              decoded.shape == .squircle,
              decoded.borderColor == settings.borderColor,
              decoded.shadowOpacity == settings.shadowOpacity,
              decoded.shadowRadius == settings.shadowRadius
        else {
            throw failure("expanded webcam style did not survive JSON round-trip")
        }
    }

    private static func loadTimeTimelineNormalizationRepairsV31Items() throws {
        let transcriptA = TranscriptSegment(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            start: -2,
            end: -1,
            recognizedText: "  alpha  ",
            editedText: "   ",
            confidence: -1,
            source: .microphone
        )
        let transcriptB = TranscriptSegment(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            start: 8,
            end: 12,
            recognizedText: " beta ",
            editedText: " corrected beta ",
            confidence: 2,
            source: .systemAudio
        )
        let cursor = CursorEffectRange(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            start: -3,
            end: 0,
            visible: false,
            scale: 99,
            clickEmphasis: true,
            halo: true
        )
        let redaction = RedactionRegion(
            id: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
            start: 9,
            end: 12,
            rect: Rect2D(x: -1, y: 2, width: 4, height: 4),
            strength: -1
        )
        let drawing = DrawingStroke(
            id: UUID(uuidString: "a0000000-0000-0000-0000-00000000000a")!,
            start: -4,
            end: -3,
            points: [Point2D(x: -1, y: 2)],
            color: RGBAColor(r: -1, g: 2, b: 0, a: 2),
            width: 0
        )
        let document = ProjectDocument(
            redactions: [redaction],
            drawings: [drawing],
            transcript: [transcriptB, transcriptA],
            cursorEffects: [cursor]
        )
        let normalized = document.normalizedForTimelineEditing(sourceDuration: 10)

        guard normalized.transcript.map(\.id) == [transcriptA.id, transcriptB.id],
              normalized.transcript[0].start == 0,
              normalized.transcript[0].end == 0.05,
              normalized.transcript[0].recognizedText == "alpha",
              normalized.transcript[0].editedText == nil,
              normalized.transcript[0].confidence == 0,
              normalized.transcript[0].source == .microphone,
              normalized.transcript[1].start == 8,
              normalized.transcript[1].end == 10,
              normalized.transcript[1].displayText == "corrected beta",
              normalized.transcript[1].confidence == 1,
              normalized.cursorEffects[0].start == 0,
              normalized.cursorEffects[0].end == 0.05,
              normalized.cursorEffects[0].scale == CursorEffectRange.scaleRange.upperBound,
              normalized.redactions[0].start == 9,
              normalized.redactions[0].end == 10,
              close(normalized.redactions[0].rect.x, 0),
              close(normalized.redactions[0].rect.y, 0.98),
              close(normalized.redactions[0].rect.width, 1),
              close(normalized.redactions[0].rect.height, 0.02),
              normalized.redactions[0].strength == RedactionRegion.strengthRange.lowerBound,
              normalized.drawings[0].start == 0,
              normalized.drawings[0].end == 0.05,
              normalized.drawings[0].points == [Point2D(x: 0, y: 1)],
              normalized.drawings[0].color == RGBAColor(r: 0, g: 1, b: 0, a: 1),
              normalized.drawings[0].width == DrawingStroke.widthRange.lowerBound
        else {
            throw failure("load-time timeline normalization did not repair transcript, cursor, redaction, and drawing fields")
        }
    }

    private static func visualItemsUseSharedTimelineOperationsAndMapper() throws {
        let first = RedactionRegion(start: 1, end: 2, mode: .blur)
        let second = RedactionRegion(start: 3, end: 4, mode: .pixelate)
        let document = ProjectDocument(
            trimOut: 10,
            redactions: [first, second],
            drawings: [DrawingStroke(
                start: 5,
                end: 6,
                points: [Point2D(x: 0.2, y: 0.2), Point2D(x: 0.8, y: 0.8)]
            )],
            editDecisions: [EditDecision(start: 2, end: 4)]
        )
        let selection = TimelineSelection(
            items: [.redaction(first.id), .redaction(second.id)],
            primary: .redaction(first.id)
        )
        let clipboard = ProjectTimelineOperations.copy(from: document, selection: selection)
        let pasted = ProjectTimelineOperations.paste(
            clipboard,
            into: document,
            at: 7,
            sourceDuration: 10
        )
        let inserted = pasted.document.redactions.filter {
            pasted.selection.items.contains(.redaction($0.id))
        }
        guard inserted.map(\.start) == [7, 9],
              ProjectTimelineOperations.deleting(
                from: pasted.document,
                selection: pasted.selection
              ) == document
        else {
            throw failure("redaction items did not use shared copy/paste/delete operations")
        }

        let mapper = ProjectTimeMapper(project: document, sourceDuration: 10)
        let sourceTime = mapper.sourceTime(atOutputTime: 3.5)
        guard close(sourceTime, 5.5),
              document.drawings[0].isActive(at: sourceTime)
        else {
            throw failure("v3.1 source-timed visuals did not follow the authoritative cut mapper")
        }
    }

    private static func close(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= 0.000_001
    }

    private static func close(_ actual: CGFloat, _ expected: CGFloat) -> Bool {
        abs(actual - expected) <= 0.000_001
    }

    private static func failure(_ message: String) -> OpenRecordError {
        .io("v3.1 content regression: \(message)")
    }
}

@Test("v3.1 visual content contracts")
func v31VisualContentContracts() throws {
    try V31ContentSuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV31ContentTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunV31ContentTests()
}

@_cdecl("OpenRecordRunV31ContentTests")
func OpenRecordRunV31ContentTests() {
    do {
        try V31ContentSuite.run()
        fputs("OpenRecordTests: v3.1 content contracts passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: v3.1 content contracts failed: \(error)\n", stderr)
        abort()
    }
}
#endif
