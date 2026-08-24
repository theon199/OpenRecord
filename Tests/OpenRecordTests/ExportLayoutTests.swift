import CoreGraphics
import CoreImage
import Darwin
import Foundation
import Testing
@testable import OpenRecord

enum ExportLayoutSuite {
    static func run() throws {
        try outputSizePreservesAspectInside1080p()
        try aspectPresetsMapToExpectedOutputSizes()
        try evenDimensions()
        try frameRateSelection()
        try uvCropToPixelAndCIRects()
        try paddingBoxAndAspectFit()
        try cursorMapsThroughCrop()
        try canvasPointMapsBackToSourceUV()
        try trimClamping()
        try clickAgeAndRipple()
        try cursorMotionBlurMapping()
        try keyboardTimelineAndGeometry()
        try keyboardRendererProducesBoundedImage()
        try jsonlMissingIsEmpty()
        try jsonlRoundTrip()
        try missingDisplayThrows()
    }

    static func outputSizePreservesAspectInside1080p() throws {
        let sixteenNine = ExportLayout.outputPixelSize(aspectWidth: 16, aspectHeight: 9)
        try expectEqual(sixteenNine.width, 1920, "16:9 width")
        try expectEqual(sixteenNine.height, 1080, "16:9 height")

        let nineSixteen = ExportLayout.outputPixelSize(aspectWidth: 9, aspectHeight: 16)
        try expectEqual(nineSixteen.width, 1080, "9:16 width")
        try expectEqual(nineSixteen.height, 1920, "9:16 height")

        let square = ExportLayout.outputPixelSize(aspectWidth: 1, aspectHeight: 1)
        try expectEqual(square.width, 1080, "1:1 width")
        try expectEqual(square.height, 1080, "1:1 height")

        let fourThree = ExportLayout.outputPixelSize(aspectWidth: 4, aspectHeight: 3)
        try expectEqual(fourThree.width, 1440, "4:3 width")
        try expectEqual(fourThree.height, 1080, "4:3 height")
    }

    static func aspectPresetsMapToExpectedOutputSizes() throws {
        let expected: [(CanvasAspectPreset, Int, Int)] = [
            (.widescreen, 1920, 1080),
            (.portrait, 1080, 1920),
            (.square, 1080, 1080),
            (.standard, 1440, 1080),
        ]
        for (preset, width, height) in expected {
            var canvas = CanvasSettings.default
            preset.apply(to: &canvas)
            let output = ExportLayout.outputPixelSize(
                aspectWidth: canvas.aspectWidth,
                aspectHeight: canvas.aspectHeight
            )
            try expectEqual(output.width, width, "\(preset.rawValue) preset width")
            try expectEqual(output.height, height, "\(preset.rawValue) preset height")
            guard CanvasAspectPreset.matching(
                aspectWidth: canvas.aspectWidth,
                aspectHeight: canvas.aspectHeight
            ) == preset else {
                throw OpenRecordError.io("Could not match the \(preset.rawValue) aspect preset")
            }
        }
    }

    static func evenDimensions() throws {
        try expectEqual(ExportLayout.evenDimension(0), 2, "even 0")
        try expectEqual(ExportLayout.evenDimension(1), 2, "even 1")
        try expectEqual(ExportLayout.evenDimension(1080), 1080, "even 1080")
        try expectEqual(ExportLayout.evenDimension(1081), 1080, "even 1081")
        let oddAspect = ExportLayout.outputPixelSize(aspectWidth: 1.37, aspectHeight: 1)
        guard oddAspect.width.isMultiple(of: 2), oddAspect.height.isMultiple(of: 2) else {
            throw OpenRecordError.io("output size \(oddAspect) is not even")
        }
    }

    static func frameRateSelection() throws {
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 60)), 60, "60fps source")
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 50)), 60, "50fps source")
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 45)), 60, "45fps source")
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 44)), 30, "44fps source")
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 30)), 30, "30fps source")
        try expectEqual(Int(ExportLayout.outputFrameRate(sourceAverageFPS: 0)), 30, "unknown fps")
    }

    static func uvCropToPixelAndCIRects() throws {
        let uv = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let pixel = ExportLayout.pixelRect(fromUV: uv, sourceWidth: 1920, sourceHeight: 1080)
        try expectRect(pixel, CGRect(x: 480, y: 270, width: 960, height: 540), "top-left crop")

        let ci = ExportLayout.ciRect(fromUV: uv, sourceWidth: 1920, sourceHeight: 1080)
        try expectRect(ci, CGRect(x: 480, y: 270, width: 960, height: 540), "CI crop (symmetric)")

        let topStrip = CGRect(x: 0, y: 0, width: 1, height: 0.25)
        let ciTop = ExportLayout.ciRect(fromUV: topStrip, sourceWidth: 100, sourceHeight: 100)
        try expectRect(ciTop, CGRect(x: 0, y: 75, width: 100, height: 25), "CI y-flip of top strip")
    }

    static func paddingBoxAndAspectFit() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let content = ExportLayout.paddedContentRect(canvas: canvas, padding: 48)
        try expectRect(content, CGRect(x: 48, y: 48, width: 1824, height: 984), "padding inset")

        let video = ExportLayout.videoRect(
            canvasSize: canvas,
            padding: 48,
            sourceWidth: 1920,
            sourceHeight: 1080,
            cropUV: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let expectedWidth = 984 * 16.0 / 9.0
        let expectedX = 48 + (1824 - expectedWidth) / 2
        try expectRect(
            video,
            CGRect(x: expectedX, y: 48, width: expectedWidth, height: 984),
            "16:9 fitted into padded 16:9 canvas"
        )

        let layout = ExportLayout.canvasLayout(
            canvas: CanvasSettings(padding: 48, cornerRadius: 16, aspectWidth: 16, aspectHeight: 9),
            sourceWidth: 1920,
            sourceHeight: 1080
        )
        try expectEqual(layout.width, 1920, "layout width")
        try expectEqual(layout.height, 1080, "layout height")
        try expectRectsClose(layout.videoRect, video, "layout videoRect")
    }

    static func cursorMapsThroughCrop() throws {
        let crop = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let video = CGRect(x: 10, y: 20, width: 60, height: 60)
        let mapped = ExportLayout.mapSourceUVToCanvas(
            Point2D(x: 0.5, y: 0.5),
            cropUV: crop,
            videoRect: video
        )
        try expectPoint(mapped, CGPoint(x: 40, y: 50), "center of crop")

        let corner = ExportLayout.mapSourceUVToCanvas(
            Point2D(x: 0.2, y: 0.2),
            cropUV: crop,
            videoRect: video
        )
        try expectPoint(corner, CGPoint(x: 10, y: 20), "crop origin")
    }

    static func canvasPointMapsBackToSourceUV() throws {
        let crop = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        let video = CGRect(x: 10, y: 20, width: 300, height: 200)
        let source = Point2D(x: 0.65, y: 0.42)
        let canvas = ExportLayout.mapSourceUVToCanvas(
            source,
            cropUV: crop,
            videoRect: video
        )
        let roundTrip = ExportLayout.mapCanvasPointToSourceUV(
            canvas,
            cropUV: crop,
            videoRect: video
        )
        try expectClose(roundTrip.x, source.x, "inverse UV x")
        try expectClose(roundTrip.y, source.y, "inverse UV y")

        let clamped = ExportLayout.mapCanvasPointToSourceUV(
            CGPoint(x: -1_000, y: 1_000),
            cropUV: crop,
            videoRect: video
        )
        try expectClose(clamped.x, 0, "inverse UV clamps left edge")
        try expectClose(clamped.y, 1, "inverse UV clamps bottom edge")
    }

    static func trimClamping() throws {
        let mid = try ExportLayout.clampedTrim(trimIn: 2, trimOut: 5, duration: 10)
        try expectClose(mid.start, 2, "trim start")
        try expectClose(mid.end, 5, "trim end")

        let full = try ExportLayout.clampedTrim(trimIn: -1, trimOut: nil, duration: 10)
        try expectClose(full.start, 0, "clamped negative trimIn")
        try expectClose(full.end, 10, "nil trimOut uses duration")

        do {
            _ = try ExportLayout.clampedTrim(trimIn: 8, trimOut: 3, duration: 10)
            throw OpenRecordError.io("inverted trim should throw")
        } catch let error as OpenRecordError {
            if case .io(let message) = error, message.contains("inverted trim should throw") {
                throw error
            }
        }
    }

    static func clickAgeAndRipple() throws {
        let clicks = [
            ClickSample(t: 1, button: .left, down: true),
            ClickSample(t: 1.4, button: .left, down: false),
        ]
        guard let age = ExportLayout.primaryClickAge(at: 1.2, clicks: clicks) else {
            throw OpenRecordError.io("expected click age while button is down")
        }
        try expectClose(age, 0.2, "click age")
        if ExportLayout.primaryClickAge(at: 1.5, clicks: clicks) != nil {
            throw OpenRecordError.io("click age should be nil after mouse up")
        }

        let start = ExportLayout.clickRipple(age: 0, canvasPixelsPerPoint: 2, cursorScale: 1)
        let later = ExportLayout.clickRipple(age: 0.35, canvasPixelsPerPoint: 2, cursorScale: 1)
        guard later.radius > start.radius else {
            throw OpenRecordError.io("ripple should grow with age")
        }
        guard later.opacity < start.opacity else {
            throw OpenRecordError.io("ripple should fade with age")
        }
    }

    static func cursorMotionBlurMapping() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let disabled = CursorMotionBlurEffect.state(
            velocity: Point2D(x: 1, y: 0),
            canvasSize: canvas,
            settings: .disabled
        )
        guard disabled == .none else {
            throw OpenRecordError.io("disabled cursor motion blur produced an effect")
        }

        let slow = CursorMotionBlurEffect.state(
            velocity: Point2D(x: 0.05, y: 0),
            canvasSize: canvas,
            settings: .default
        )
        guard slow.radius == 0, slow.speed < CursorMotionBlurEffect.speedThreshold else {
            throw OpenRecordError.io("slow cursor motion should stay sharp")
        }

        let weak = CursorMotionBlurEffect.state(
            velocity: Point2D(x: 0.5, y: 0),
            canvasSize: canvas,
            settings: CursorMotionBlurSettings(enabled: true, amount: 0.25)
        )
        let strong = CursorMotionBlurEffect.state(
            velocity: Point2D(x: 0.5, y: 0),
            canvasSize: canvas,
            settings: CursorMotionBlurSettings(enabled: true, amount: 1)
        )
        guard weak.radius > 0,
              strong.radius > weak.radius,
              strong.radius <= CursorMotionBlurEffect.maximumRadius,
              abs(strong.angle) < 1e-12,
              strong.previewRadius <= 8
        else {
            throw OpenRecordError.io("horizontal cursor motion blur mapping was incorrect")
        }

        let vertical = CursorMotionBlurEffect.state(
            velocity: Point2D(x: 0, y: 1),
            canvasSize: canvas,
            settings: .default
        )
        guard abs(vertical.angle + .pi / 2) < 1e-9 else {
            throw OpenRecordError.io("top-left velocity was not converted to Core Image angle")
        }

        let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 24, height: 32)
        )
        let rendered = CursorMotionBlurRenderer.image(source, state: strong)
        guard rendered.extent.width > source.extent.width,
              rendered.extent.height > source.extent.height,
              rendered.extent.width.isFinite,
              rendered.extent.height.isFinite
        else {
            throw OpenRecordError.io("Core Image cursor motion blur did not produce bounded padding")
        }
    }

    static func keyboardTimelineAndGeometry() throws {
        let samples = [
            KeySample(t: 1.0, key: "K", modifiers: [.command], down: true),
            KeySample(t: 1.1, key: "K", modifiers: [.command], down: false),
            KeySample(t: 1.4, key: "Enter", down: true),
        ]
        let timeline = KeyboardOverlayTimeline(samples: samples)
        var settings = KeyboardOverlaySettings(
            enabled: true,
            position: .bottomCenter,
            fadeDelay: 0.8,
            maxVisibleKeys: 3
        )
        let early = timeline.state(at: 1.2, settings: settings)
        guard early.keys.map(\.label) == ["⌘ K"] else {
            throw OpenRecordError.io("keyboard timeline returned an unexpected early state")
        }
        guard timeline.state(at: 0.99, settings: settings).keys.isEmpty else {
            throw OpenRecordError.io("keyboard timeline displayed a shortcut before its timestamp")
        }
        let later = timeline.state(at: 1.45, settings: settings)
        guard later.keys.map(\.label) == ["⌘ K", "Enter"] else {
            throw OpenRecordError.io("keyboard timeline ordering did not match capture order")
        }
        settings.maxVisibleKeys = 1
        guard timeline.state(at: 1.45, settings: settings).keys.map(\.label) == ["Enter"] else {
            throw OpenRecordError.io("keyboard timeline did not retain the most recent shortcut")
        }
        settings.maxVisibleKeys = 3
        let fading = timeline.state(at: 2.30, settings: settings)
        guard fading.keys.count == 1,
              fading.keys[0].label == "Enter",
              fading.keys[0].opacity > 0,
              fading.keys[0].opacity < 1,
              timeline.state(at: 2.5, settings: settings).keys.isEmpty
        else {
            throw OpenRecordError.io("keyboard timeline fade boundaries were incorrect")
        }

        let canvas = CGSize(width: 1920, height: 1080)
        guard let previewGeometry = KeyboardOverlayLayout.geometry(
            for: later,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ) else {
            throw OpenRecordError.io("keyboard geometry should be visible")
        }
        // Export and preview both consume this shared geometry in canvas
        // pixels; verify its rects are contiguous and remain inside the canvas.
        guard previewGeometry.keyRects.count == later.keys.count else {
            throw OpenRecordError.io("keyboard geometry key count mismatch")
        }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        for rect in previewGeometry.keyRects {
            guard canvasRect.contains(rect) else {
                throw OpenRecordError.io("keyboard key escaped the canvas bounds")
            }
        }
        try expectClose(
            previewGeometry.bounds.midX,
            canvas.width / 2,
            "bottom-center keyboard geometry"
        )
        settings.position = .bottomLeft
        guard let leftGeometry = KeyboardOverlayLayout.geometry(
            for: later,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ) else {
            throw OpenRecordError.io("bottom-left keyboard geometry should be visible")
        }
        try expectClose(leftGeometry.bounds.minX, 48, "bottom-left keyboard inset")
    }

    static func keyboardRendererProducesBoundedImage() throws {
        let settings = KeyboardOverlaySettings(enabled: true)
        let state = KeyboardOverlayState(
            keys: [KeyboardOverlayKey(id: 1, label: "⌘ K", opacity: 1)]
        )
        let canvas = CGSize(width: 1920, height: 1080)
        guard let geometry = KeyboardOverlayLayout.geometry(
            for: state,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ), let image = KeyboardOverlayRenderer.image(
            state: state,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ) else {
            throw OpenRecordError.io("keyboard renderer did not produce an image")
        }
        guard image.extent.width < canvas.width / 2,
              image.extent.height < canvas.height / 2
        else {
            throw OpenRecordError.io("keyboard renderer allocated a full-canvas image")
        }
        try expectClose(image.extent.midX, geometry.bounds.midX, "keyboard image horizontal placement")
        try expectClose(
            image.extent.midY,
            canvas.height - geometry.bounds.midY,
            "keyboard image vertical placement"
        )
    }

    static func jsonlMissingIsEmpty() throws {
        let missing = URL(fileURLWithPath: "/tmp/openrecord-missing-\(UUID().uuidString).jsonl")
        let items = try ExportJSONL.decode(CursorSample.self, from: missing)
        guard items.isEmpty else {
            throw OpenRecordError.io("missing JSONL should decode as []")
        }
    }

    static func jsonlRoundTrip() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent(
            "openrecord-jsonl-\(UUID().uuidString).jsonl"
        )
        defer { try? fm.removeItem(at: url) }

        let samples = [
            CursorSample(t: 0.5, x: 10, y: 20, cursorId: "arrow"),
            CursorSample(t: 1.0, x: 11, y: 21),
        ]
        var body = Data()
        for sample in samples {
            body.append(try ProjectJSON.jsonlEncoder.encode(sample))
            body.append(0x0A)
        }
        try body.write(to: url)
        let decoded = try ExportJSONL.decode(CursorSample.self, from: url)
        guard decoded == samples else {
            throw OpenRecordError.io("JSONL round-trip produced \(decoded)")
        }
    }

    static func missingDisplayThrows() throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent(
            "MissingDisplay-\(UUID().uuidString).openrecord",
            isDirectory: true
        )
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }

        let output = fm.temporaryDirectory.appendingPathComponent(
            "export-missing-\(UUID().uuidString).mp4"
        )
        defer { try? fm.removeItem(at: output) }

        let exporter = Exporter(projectBundleURL: bundle)
        do {
            try runAsync {
                try await exporter.export(project: ProjectDocument(), url: output, progress: nil)
            }
            throw OpenRecordError.io("export succeeded without display.mp4")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error else { throw error }
            if message.contains("export succeeded") { throw error }
            guard message.contains("display.mp4") else {
                throw OpenRecordError.io("missing-video error was: \(message)")
            }
        }
    }

    private static func runAsync(_ body: @Sendable @escaping () async throws -> Void) throws {
        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await body()
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error {
            throw error
        }
    }

    private static func expectEqual<T: Equatable>(_ got: T, _ expected: T, _ label: String) throws {
        guard got == expected else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }

    private static func expectClose(_ got: Double, _ expected: Double, _ label: String) throws {
        guard abs(got - expected) < 1e-9 else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }

    private static func expectRect(_ got: CGRect, _ expected: CGRect, _ label: String) throws {
        try expectRectsClose(got, expected, label)
    }

    private static func expectRectsClose(_ got: CGRect, _ expected: CGRect, _ label: String) throws {
        let eps: CGFloat = 1e-6
        let dx = abs(got.origin.x - expected.origin.x)
        let dy = abs(got.origin.y - expected.origin.y)
        let dw = abs(got.width - expected.width)
        let dh = abs(got.height - expected.height)
        guard dx <= eps, dy <= eps, dw <= eps, dh <= eps else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }

    private static func expectPoint(_ got: CGPoint, _ expected: CGPoint, _ label: String) throws {
        let eps: CGFloat = 1e-9
        guard abs(got.x - expected.x) <= eps, abs(got.y - expected.y) <= eps else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }
}

@Test
func exportOutputSizePreservesAspectInside1080p() throws {
    try ExportLayoutSuite.outputSizePreservesAspectInside1080p()
}

@Test
func exportAspectPresetsMapToExpectedOutputSizes() throws {
    try ExportLayoutSuite.aspectPresetsMapToExpectedOutputSizes()
}

@Test
func exportUVCropToPixelAndCIRects() throws {
    try ExportLayoutSuite.uvCropToPixelAndCIRects()
}

@Test
func exportPaddingBoxAndAspectFit() throws {
    try ExportLayoutSuite.paddingBoxAndAspectFit()
}

@Test
func exportCanvasPointMapsBackToSourceUV() throws {
    try ExportLayoutSuite.canvasPointMapsBackToSourceUV()
}

@Test
func exportCursorMotionBlurMapping() throws {
    try ExportLayoutSuite.cursorMotionBlurMapping()
}

@Test
func exportMissingDisplayThrows() throws {
    try ExportLayoutSuite.missingDisplayThrows()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordExportTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunExportLayoutTests()
}

@_cdecl("OpenRecordRunExportLayoutTests")
func OpenRecordRunExportLayoutTests() {
    do {
        try ExportLayoutSuite.run()
        fputs("OpenRecordTests: Export layout tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: Export layout tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
