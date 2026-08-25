import CoreGraphics
import CoreImage
import Darwin
import Testing
@testable import OpenRecord

/// Focused coverage for the v2.5 webcam direct-manipulation contract.
///
/// These checks intentionally exercise the shared layout helpers rather than
/// SwiftUI views.  That keeps the interaction math deterministic and also
/// verifies that preview and export continue to use the same geometry.
enum WebcamOverlaySuite {
    private static let canvas = CGSize(width: 1920, height: 1080)

    static func run() throws {
        try defaultsAndShapes()
        try normalizationAndCornerClamping()
        try aspectRatioPreservesPlacement()
        try movingAndResizingUseLiveStateMath()
        try borderWidthIsRendered()
        try mirroringSourceTransformAndExtent()
        try previewAndExportGeometryAgree()
        try resetDefaults()
        try gestureHistoryCoalescesUndoRedo()
    }

    private static func defaultsAndShapes() throws {
        let circleSettings = WebcamOverlaySettings(
            enabled: true,
            shape: .circle,
            position: Point2D(x: 0.5, y: 0.5),
            size: 0.2,
            borderWidth: 4,
            shadow: false
        )
        guard let circle = WebcamOverlayLayout.geometry(
            settings: circleSettings,
            canvasSize: canvas,
            sourceAspect: 4.0 / 3.0
        ) else {
            throw failure("circle geometry was not produced")
        }
        try expectClose(circle.frame.width, circle.frame.height, "circle dimensions")
        try expectClose(circle.cornerRadius, Double(circle.frame.width / 2), "circle radius")

        let roundedSettings = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.5, y: 0.5),
            size: 0.2,
            borderWidth: 4,
            shadow: false
        )
        guard let rounded = WebcamOverlayLayout.geometry(
            settings: roundedSettings,
            canvasSize: canvas,
            sourceAspect: 16.0 / 9.0
        ), rounded.frame.width > rounded.frame.height,
              rounded.cornerRadius > 0,
              rounded.cornerRadius < Double(rounded.frame.height / 2)
        else {
            throw failure("rounded-rectangle geometry was not produced")
        }
    }

    private static func normalizationAndCornerClamping() throws {
        let unbounded = WebcamOverlaySettings(
            enabled: true,
            position: Point2D(x: -4, y: 7),
            size: 99,
            borderWidth: -2
        )
        let normalized = unbounded.normalized
        guard normalized.position == Point2D(x: 0, y: 1),
              normalized.size == WebcamOverlaySettings.sizeRange.upperBound,
              normalized.borderWidth == WebcamOverlaySettings.borderWidthRange.lowerBound
        else {
            throw failure("webcam settings normalization did not enforce min/max bounds")
        }

        for (label, position) in [
            ("top-left", Point2D(x: 0, y: 0)),
            ("top-right", Point2D(x: 1, y: 0)),
            ("bottom-left", Point2D(x: 0, y: 1)),
            ("bottom-right", Point2D(x: 1, y: 1)),
        ] {
            let requested = WebcamOverlaySettings(
                enabled: true,
                shape: .roundedRectangle,
                position: position,
                size: 0.24,
                borderWidth: 12,
                shadow: false
            )
            let clamped = WebcamOverlayLayout.clampedSettings(
                requested,
                canvasSize: canvas,
                sourceAspect: 16.0 / 9.0
            )
            guard let geometry = WebcamOverlayLayout.geometry(
                settings: clamped,
                canvasSize: canvas,
                sourceAspect: 16.0 / 9.0
            ) else {
                throw failure("\(label): clamped webcam geometry was not produced")
            }
            let margin = max(CGFloat(clamped.normalized.borderWidth), min(canvas.width, canvas.height) * 0.012)
            let bounds = CGRect(origin: .zero, size: canvas).insetBy(dx: margin, dy: margin)
            guard bounds.contains(geometry.frame) else {
                throw failure("\(label): clamped webcam frame escaped canvas bounds: \(geometry.frame)")
            }
        }
    }

    private static func aspectRatioPreservesPlacement() throws {
        let requested = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.37, y: 0.61),
            size: 0.16,
            borderWidth: 3,
            shadow: false
        )
        let wide = WebcamOverlayLayout.clampedSettings(
            requested,
            canvasSize: CGSize(width: 1920, height: 1080),
            sourceAspect: 16.0 / 9.0
        )
        let portrait = WebcamOverlayLayout.clampedSettings(
            requested,
            canvasSize: CGSize(width: 1080, height: 1920),
            sourceAspect: 16.0 / 9.0
        )
        try expectClose(wide.position.x, requested.position.x, "wide placement x")
        try expectClose(wide.position.y, requested.position.y, "wide placement y")
        try expectClose(portrait.position.x, requested.position.x, "portrait placement x")
        try expectClose(portrait.position.y, requested.position.y, "portrait placement y")
    }

    private static func movingAndResizingUseLiveStateMath() throws {
        let original = WebcamOverlaySettings(
            enabled: true,
            shape: .circle,
            position: Point2D(x: 0.5, y: 0.5),
            size: 0.2,
            borderWidth: 3,
            shadow: false
        )
        let moved = WebcamOverlayLayout.moving(
            original,
            translation: CGSize(width: 192, height: -108),
            canvasSize: canvas,
            sourceAspect: 1
        )
        try expectClose(moved.position.x, 0.6, "live move x")
        try expectClose(moved.position.y, 0.4, "live move y")

        let resized = WebcamOverlayLayout.resizing(
            original,
            translation: CGSize(width: 54, height: 54),
            canvasSize: canvas,
            sourceAspect: 1
        )
        try expectClose(resized.size, 0.3, "live resize size")
        guard let beforeGeometry = WebcamOverlayLayout.geometry(settings: original, canvasSize: canvas),
              let afterGeometry = WebcamOverlayLayout.geometry(settings: resized, canvasSize: canvas),
              afterGeometry.frame.width > beforeGeometry.frame.width
        else {
            throw failure("live resize did not update geometry")
        }

        var roundedOriginal = original
        roundedOriginal.shape = .roundedRectangle
        let roundedResized = WebcamOverlayLayout.resizing(
            roundedOriginal,
            translation: CGSize(width: 48, height: 27),
            canvasSize: canvas,
            sourceAspect: 16.0 / 9.0
        )
        try expectClose(roundedResized.size, 0.25, "rounded live resize size")
    }

    private static func borderWidthIsRendered() throws {
        let source = solidImage(width: 4, height: 3, rgba: (0.9, 0.1, 0.05, 1))
        let settings = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.5, y: 0.5),
            size: 0.24,
            borderWidth: 8,
            shadow: false
        )
        guard let geometry = WebcamOverlayLayout.geometry(
            settings: settings,
            canvasSize: canvas,
            sourceAspect: 4.0 / 3.0
        ) else {
            throw failure("border geometry was not produced")
        }
        let outerRect = ExportLayout.ciRect(
            fromTopLeft: geometry.frame,
            canvasHeight: canvas.height
        )
        let resolvedBorder = WebcamOverlayLayout.borderWidth(
            settings: settings,
            frame: outerRect
        )
        try expectClose(resolvedBorder, CGFloat(settings.borderWidth), "authored border width")

        let tinyRect = CGRect(x: 20, y: 30, width: 10, height: 20)
        let tinyBorder = WebcamOverlayLayout.borderWidth(
            settings: settings,
            frame: tinyRect
        )
        try expectClose(tinyBorder, 2.5, "tiny-rect border clamp")

        guard let rendered = WebcamOverlayRenderer.image(
            source,
            settings: settings,
            canvasSize: canvas,
            mirror: false
        ) else {
            throw failure("border renderer did not produce an image")
        }
        try expectClose(rendered.extent.minX, outerRect.minX, "border output x", tolerance: 1)
        try expectClose(rendered.extent.minY, outerRect.minY, "border output y", tolerance: 1)
        try expectClose(rendered.extent.width, outerRect.width, "border output width", tolerance: 1)
        try expectClose(rendered.extent.height, outerRect.height, "border output height", tolerance: 1)
    }

    private static func mirroringSourceTransformAndExtent() throws {
        let sourceExtent = CGRect(x: 10, y: 20, width: 320, height: 180)
        let identity = WebcamOverlayRenderer.sourceTransform(
            extent: sourceExtent,
            mirror: false
        )
        try expectIdentity(identity, "non-mirrored source transform")

        let mirroredTransform = WebcamOverlayRenderer.sourceTransform(
            extent: sourceExtent,
            mirror: true
        )
        let minPoint = CGPoint(x: sourceExtent.minX, y: sourceExtent.minY).applying(mirroredTransform)
        let maxPoint = CGPoint(x: sourceExtent.maxX, y: sourceExtent.maxY).applying(mirroredTransform)
        try expectClose(minPoint.x, sourceExtent.maxX, "mirrored minX")
        try expectClose(maxPoint.x, sourceExtent.minX, "mirrored maxX")
        try expectClose(minPoint.y, sourceExtent.minY, "mirrored minY")
        try expectClose(maxPoint.y, sourceExtent.maxY, "mirrored maxY")

        let source = solidImage(width: 4, height: 3, rgba: (0.2, 0.4, 0.8, 1))
        let settings = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.5, y: 0.5),
            size: 0.24,
            borderWidth: 0,
            shadow: false
        )
        guard let normal = WebcamOverlayRenderer.image(
            source,
            settings: settings,
            canvasSize: canvas,
            mirror: false
        ), let mirrored = WebcamOverlayRenderer.image(
            source,
            settings: settings,
            canvasSize: canvas,
            mirror: true
        ), let geometry = WebcamOverlayLayout.geometry(
            settings: settings,
            canvasSize: canvas,
            sourceAspect: 4.0 / 3.0
        ) else {
            throw failure("mirroring renderer did not produce both images")
        }
        let expected = ExportLayout.ciRect(fromTopLeft: geometry.frame, canvasHeight: canvas.height)
        try expectClose(normal.extent.minX, expected.minX, "normal output x", tolerance: 1)
        try expectClose(normal.extent.minY, expected.minY, "normal output y", tolerance: 1)
        try expectClose(normal.extent.width, expected.width, "normal output width", tolerance: 1)
        try expectClose(normal.extent.height, expected.height, "normal output height", tolerance: 1)
        try expectClose(mirrored.extent.minX, normal.extent.minX, "mirrored output x", tolerance: 1)
        try expectClose(mirrored.extent.minY, normal.extent.minY, "mirrored output y", tolerance: 1)
        try expectClose(mirrored.extent.width, normal.extent.width, "mirrored output width", tolerance: 1)
        try expectClose(mirrored.extent.height, normal.extent.height, "mirrored output height", tolerance: 1)
    }

    private static func previewAndExportGeometryAgree() throws {
        let settings = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.29, y: 0.68),
            size: 0.2,
            borderWidth: 5,
            shadow: false
        )
        let sourceAspect = 4.0 / 3.0
        guard let geometry = WebcamOverlayLayout.geometry(
            settings: settings,
            canvasSize: canvas,
            sourceAspect: sourceAspect
        ), let image = WebcamOverlayRenderer.image(
            solidImage(width: 4, height: 3, rgba: (0.2, 0.7, 0.3, 1)),
            settings: settings,
            canvasSize: canvas,
            mirror: false
        ) else {
            throw failure("preview/export reference geometry was not produced")
        }
        let expected = ExportLayout.ciRect(fromTopLeft: geometry.frame, canvasHeight: canvas.height)
        try expectClose(image.extent.minX, expected.minX, "export reference x", tolerance: 1)
        try expectClose(image.extent.minY, expected.minY, "export reference y", tolerance: 1)
        try expectClose(image.extent.width, expected.width, "export reference width", tolerance: 1)
        try expectClose(image.extent.height, expected.height, "export reference height", tolerance: 1)
    }

    private static func resetDefaults() throws {
        let settings = WebcamOverlaySettings(
            enabled: true,
            shape: .roundedRectangle,
            position: Point2D(x: 0.1, y: 0.2),
            size: 0.33,
            borderWidth: 11,
            shadow: false
        )
        let reset = WebcamOverlaySettings(
            enabled: settings.enabled,
            shape: settings.shape,
            position: WebcamOverlaySettings.defaultPosition,
            size: WebcamOverlaySettings.defaultSize,
            borderWidth: settings.borderWidth,
            shadow: settings.shadow
        )
        guard reset.position == Point2D(x: 0.85, y: 0.82),
              reset.position == WebcamOverlaySettings.defaultPosition,
              reset.size == 0.18,
              reset.size == WebcamOverlaySettings.defaultSize
        else {
            throw failure("webcam reset did not restore default position and size")
        }
    }

    private static func gestureHistoryCoalescesUndoRedo() throws {
        let original = ProjectDocument(
            webcamOverlay: WebcamOverlaySettings(
                enabled: true,
                position: Point2D(x: 0.5, y: 0.5),
                size: 0.2,
                shadow: false
            )
        )
        let intermediateSettings = WebcamOverlayLayout.moving(
            original.webcamOverlay,
            translation: CGSize(width: 64, height: 32),
            canvasSize: canvas,
            sourceAspect: 16.0 / 9.0
        )
        let finalSettings = WebcamOverlayLayout.resizing(
            intermediateSettings,
            translation: CGSize(width: 24, height: 24),
            canvasSize: canvas,
            sourceAspect: 16.0 / 9.0
        )
        var intermediate = original
        intermediate.webcamOverlay = intermediateSettings
        var edited = original
        edited.webcamOverlay = finalSettings

        var history = ProjectDocumentHistory()
        history.begin(document: original, actionName: "Move and Resize Webcam Overlay")
        history.record(before: original, after: intermediate, actionName: "Move and Resize Webcam Overlay")
        history.record(before: intermediate, after: edited, actionName: "Move and Resize Webcam Overlay")
        history.commit(currentDocument: edited)

        guard history.canUndo,
              !history.canRedo,
              history.undoActionName == "Move and Resize Webcam Overlay",
              history.undo(currentDocument: edited) == original,
              !history.canUndo,
              history.canRedo,
              history.redo(currentDocument: original) == edited
        else {
            throw failure("one webcam gesture did not coalesce into one undo/redo step")
        }
    }

    private static func solidImage(
        width: Int,
        height: Int,
        rgba: (Double, Double, Double, Double)
    ) -> CIImage {
        CIImage(color: CIColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func expectClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        tolerance: Double = 0.000_001
    ) throws {
        guard abs(actual - expected) <= tolerance else {
            throw failure("\(label): got \(actual), expected \(expected)")
        }
    }

    private static func expectClose(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ label: String,
        tolerance: CGFloat = 0.000_001
    ) throws {
        guard abs(actual - expected) <= tolerance else {
            throw failure("\(label): got \(actual), expected \(expected)")
        }
    }

    private static func expectIdentity(_ transform: CGAffineTransform, _ label: String) throws {
        try expectClose(transform.a, 1, "\(label) a")
        try expectClose(transform.b, 0, "\(label) b")
        try expectClose(transform.c, 0, "\(label) c")
        try expectClose(transform.d, 1, "\(label) d")
        try expectClose(transform.tx, 0, "\(label) tx")
        try expectClose(transform.ty, 0, "\(label) ty")
    }

    private static func failure(_ message: String) -> OpenRecordError {
        .io("Webcam overlay regression: \(message)")
    }
}

@Test
func webcamOverlayPhase2() throws {
    try WebcamOverlaySuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordWebcamOverlayTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunWebcamOverlayTests()
}

@_cdecl("OpenRecordRunWebcamOverlayTests")
func OpenRecordRunWebcamOverlayTests() {
    do {
        try WebcamOverlaySuite.run()
        fputs("OpenRecordTests: webcam overlay phase 2 tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: webcam overlay phase 2 tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
