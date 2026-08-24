import CoreGraphics
import Darwin
import Foundation
import Testing
import OpenRecord

enum ExportLayoutSuite {
    static func run() throws {
        try outputSizePreservesAspectInside1080p()
        try evenDimensions()
        try frameRateSelection()
        try uvCropToPixelAndCIRects()
        try paddingBoxAndAspectFit()
        try cursorMapsThroughCrop()
        try canvasPointMapsBackToSourceUV()
        try trimClamping()
        try clickAgeAndRipple()
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
