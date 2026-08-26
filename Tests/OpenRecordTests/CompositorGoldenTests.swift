import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation
#if !GOLDEN_RECORDING
import Testing
#endif
@testable import OpenRecord

enum CompositorGoldenSuite {
    private static let width = 320
    private static let height = 180
    private static let columns = 10
    private static let rows = 6
    private static let caseIDs = [
        "solid-frame",
        "gradient-zoom",
        "cursor-keyboard",
        "webcam-circle",
        "webcam-rounded-mirrored",
        "authored-overlays",
        "combined-speed-time",
        "redactions-blur-pixelate",
        "drawings-rich-annotations",
        "device-frame-webcam-squircle",
    ]

    static func run() throws {
        let manifest = try loadManifest()
        guard manifest.schemaVersion == 1,
              manifest.width == width,
              manifest.height == height,
              manifest.columns == columns,
              manifest.rows == rows
        else {
            throw OpenRecordError.io("Compositor golden manifest dimensions or schema changed unexpectedly")
        }

        var actual: [String: GoldenReference] = [:]
        for id in caseIDs {
            let bytes = try render(caseID: id)
            actual[id] = GoldenReference(
                hash: fnv1a64(bytes),
                enforceExactHash: id == "solid-frame",
                fingerprint: blockFingerprint(bytes),
                maxChannelDelta: id == "authored-overlays" || id == "combined-speed-time" ? 18 : 6,
                meanChannelDelta: id == "authored-overlays" || id == "combined-speed-time" ? 2.5 : 0.75
            )
        }

        guard !manifest.frames.isEmpty else {
            let recorded = GoldenManifest(
                schemaVersion: 1,
                width: width,
                height: height,
                columns: columns,
                rows: rows,
                frames: actual
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(decoding: try encoder.encode(recorded), as: UTF8.self)
            throw OpenRecordError.io("Compositor golden manifest has no references. Record these values:\n\(json)")
        }

        guard Set(manifest.frames.keys) == Set(caseIDs) else {
            throw OpenRecordError.io(
                "Compositor golden cases differ: got \(manifest.frames.keys.sorted()), expected \(caseIDs)"
            )
        }
        for id in caseIDs {
            guard let expected = manifest.frames[id], let observed = actual[id] else {
                throw OpenRecordError.io("Missing compositor golden case \(id)")
            }
            try compare(observed, expected: expected, caseID: id)
        }
    }

    private static func render(caseID: String) throws -> [UInt8] {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
        var canvas = CanvasSettings(
            background: .solid(RGBAColor(r: 0.08, g: 0.10, b: 0.14)),
            padding: 12,
            cornerRadius: 9,
            cursorScale: 0.9,
            aspectWidth: 16,
            aspectHeight: 9,
            cursorMotionBlur: CursorMotionBlurSettings(enabled: true, amount: 0.75)
        )
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        var cursorUV: Point2D?
        var cursorVelocity: Point2D?
        var clicking = false
        var clickAge: TimeInterval?
        var keyboardSettings = KeyboardOverlaySettings.disabled
        var keyboardState = KeyboardOverlayState()
        var webcamSettings = WebcamOverlaySettings.disabled
        var webcam: CIImage?
        var webcamMirror = false
        var captions: [CaptionCue] = []
        var annotations: [Annotation] = []
        var redactions: [RedactionRegion] = []
        var drawings: [DrawingStroke] = []
        var deviceFrame = DeviceFrameSettings.none
        var sourceTime: TimeInterval = 0
        var cursorImage: CIImage?
        var cursorSprite: CursorSprite?

        switch caseID {
        case "solid-frame":
            canvas.padding = 0
            canvas.cornerRadius = 0
        case "gradient-zoom":
            canvas.background = .linearGradient(
                start: RGBAColor(r: 0.02, g: 0.08, b: 0.22),
                end: RGBAColor(r: 0.62, g: 0.14, b: 0.34),
                startPoint: Point2D(x: 0, y: 0),
                endPoint: Point2D(x: 1, y: 1)
            )
            let document = ProjectDocument(
                trimOut: 5,
                zoomRanges: [
                    ZoomRange(
                        start: 0.5,
                        end: 4.5,
                        amount: 1.8,
                        anchor: Point2D(x: 0.68, y: 0.38)
                    )
                ]
            )
            crop = ZoomEngine(document: document).crop(at: 2.5)
        case "cursor-keyboard":
            cursorUV = Point2D(x: 0.62, y: 0.42)
            cursorVelocity = Point2D(x: 4.5, y: 1.2)
            clicking = true
            clickAge = 0.16
            keyboardSettings = KeyboardOverlaySettings(
                enabled: true,
                position: .bottomLeft,
                fadeDelay: 0.8,
                maxVisibleKeys: 3
            )
            let timeline = KeyboardOverlayTimeline(samples: [
                KeySample(t: 0.1, key: "K", modifiers: [.command], down: true),
                KeySample(t: 0.4, key: "Return", down: true),
            ])
            keyboardState = timeline.state(at: 0.75, settings: keyboardSettings)
            cursorImage = makeCursorImage()
            cursorSprite = CursorSprite(
                id: "golden-cursor",
                hotspot: Point2D(x: 2, y: 2),
                pngRelativePath: "unused",
                standardSize: Size2D(width: 14, height: 20)
            )
        case "webcam-circle":
            webcamSettings = WebcamOverlaySettings(
                enabled: true,
                shape: .circle,
                position: Point2D(x: 0.78, y: 0.72),
                size: 0.28,
                borderWidth: 4,
                shadow: true
            )
            webcam = makeWebcamImage()
        case "webcam-rounded-mirrored":
            webcamSettings = WebcamOverlaySettings(
                enabled: true,
                shape: .roundedRectangle,
                position: Point2D(x: 0.25, y: 0.28),
                size: 0.25,
                borderWidth: 6,
                shadow: false
            )
            webcam = makeWebcamImage()
            webcamMirror = true
        case "authored-overlays":
            sourceTime = 2
            captions = [goldenCaption]
            annotations = goldenAnnotations
        case "combined-speed-time":
            canvas.background = .linearGradient(
                start: RGBAColor(r: 0.03, g: 0.04, b: 0.12),
                end: RGBAColor(r: 0.12, g: 0.38, b: 0.32),
                startPoint: Point2D(x: 0.1, y: 0),
                endPoint: Point2D(x: 0.9, y: 1)
            )
            let document = ProjectDocument(
                trimOut: 5,
                zoomRanges: [
                    ZoomRange(
                        start: 1,
                        end: 3,
                        amount: 1.55,
                        anchor: Point2D(x: 0.58, y: 0.46)
                    )
                ],
                speedSegments: [SpeedSegment(start: 1, end: 3, rate: 2)],
                editDecisions: [EditDecision(start: 3, end: 4)]
            )
            sourceTime = ProjectTimeMapper(project: document, sourceDuration: 5)
                .sourceTime(atOutputTime: 1.5)
            crop = ZoomEngine(document: document).crop(at: sourceTime)
            cursorUV = Point2D(x: 0.54, y: 0.45)
            cursorVelocity = Point2D(x: 3.6, y: -0.8)
            clicking = true
            clickAge = 0.11
            cursorImage = makeCursorImage()
            cursorSprite = CursorSprite(
                id: "golden-cursor",
                hotspot: Point2D(x: 2, y: 2),
                pngRelativePath: "unused",
                standardSize: Size2D(width: 14, height: 20)
            )
            keyboardSettings = KeyboardOverlaySettings(enabled: true, fadeDelay: 0.8, maxVisibleKeys: 2)
            keyboardState = KeyboardOverlayTimeline(samples: [
                KeySample(t: 1.7, key: "Z", modifiers: [.command, .shift], down: true)
            ]).state(at: sourceTime, settings: keyboardSettings)
            webcamSettings = WebcamOverlaySettings(
                enabled: true,
                shape: .roundedRectangle,
                position: Point2D(x: 0.8, y: 0.24),
                size: 0.21,
                borderWidth: 3,
                shadow: true
            )
            webcam = makeWebcamImage()
            webcamMirror = true
            captions = [goldenCaption]
            annotations = goldenAnnotations
        case "redactions-blur-pixelate":
            sourceTime = 1.25
            redactions = [
                RedactionRegion(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                    start: 1,
                    end: 2,
                    rect: Rect2D(x: 0.08, y: 0.12, width: 0.28, height: 0.28),
                    mode: .blur,
                    strength: 0.72
                ),
                RedactionRegion(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                    start: 1,
                    end: 2,
                    rect: Rect2D(x: 0.64, y: 0.58, width: 0.27, height: 0.25),
                    mode: .pixelate,
                    strength: 0.86
                ),
            ]
        case "drawings-rich-annotations":
            sourceTime = 1.7
            drawings = [
                DrawingStroke(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                    start: 1,
                    end: 2.5,
                    tool: .pen,
                    points: [
                        Point2D(x: 0.08, y: 0.78),
                        Point2D(x: 0.18, y: 0.67),
                        Point2D(x: 0.29, y: 0.73),
                        Point2D(x: 0.39, y: 0.6),
                    ],
                    color: RGBAColor(r: 0.98, g: 0.26, b: 0.12),
                    width: 7
                ),
                DrawingStroke(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    start: 1,
                    end: 2.5,
                    tool: .highlighter,
                    points: [
                        Point2D(x: 0.58, y: 0.76),
                        Point2D(x: 0.68, y: 0.7),
                        Point2D(x: 0.78, y: 0.76),
                        Point2D(x: 0.89, y: 0.69),
                    ],
                    color: RGBAColor(r: 0.24, g: 0.9, b: 1, a: 0.92),
                    width: 12
                ),
            ]
            annotations = [
                Annotation(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                    start: 1,
                    end: 2.5,
                    kind: .box,
                    rect: Rect2D(x: 0.06, y: 0.08, width: 0.34, height: 0.28),
                    color: RGBAColor(r: 1, g: 0.78, b: 0.16),
                    fontSize: 30,
                    animation: AnnotationAnimation(entrance: .pop, exit: .fade, duration: 0.4)
                ),
                Annotation(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
                    start: 1,
                    end: 2.5,
                    kind: .underline,
                    position: Point2D(x: 0.45, y: 0.32),
                    endPosition: Point2D(x: 0.73, y: 0.32),
                    color: RGBAColor(r: 0.68, g: 0.42, b: 1),
                    fontSize: 26,
                    animation: AnnotationAnimation(entrance: .fade, duration: 0.3)
                ),
                Annotation(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!,
                    start: 1,
                    end: 2.5,
                    kind: .stepMarker,
                    text: "2",
                    position: Point2D(x: 0.84, y: 0.28),
                    color: RGBAColor(r: 0.2, g: 0.72, b: 0.38),
                    background: RGBAColor(r: 1, g: 1, b: 1),
                    fontSize: 25,
                    animation: AnnotationAnimation(entrance: .pop, duration: 0.35)
                ),
                Annotation(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000004")!,
                    start: 1,
                    end: 2.5,
                    kind: .label,
                    text: "Important",
                    position: Point2D(x: 0.61, y: 0.48),
                    endPosition: Point2D(x: 0.72, y: 0.42),
                    color: RGBAColor(r: 1, g: 1, b: 1),
                    background: RGBAColor(r: 0.14, g: 0.16, b: 0.22, a: 0.94),
                    fontSize: 21,
                    animation: AnnotationAnimation(entrance: .fade, exit: .fade, duration: 0.25)
                ),
            ]
        case "device-frame-webcam-squircle":
            deviceFrame = DeviceFrameSettings(id: .genericLaptopDark, scale: 0.86, shadow: true)
            webcamSettings = WebcamOverlaySettings(
                enabled: true,
                shape: .squircle,
                position: Point2D(x: 0.79, y: 0.26),
                size: 0.22,
                borderWidth: 5,
                borderColor: RGBAColor(r: 0.94, g: 0.72, b: 0.22),
                shadow: true,
                shadowOpacity: 0.5,
                shadowRadius: 10
            )
            webcam = makeWebcamImage()
            webcamMirror = true
        default:
            throw OpenRecordError.io("Unknown compositor golden case \(caseID)")
        }

        let canvasSize = CGSize(width: width, height: height)
        let videoRect = ExportLayout.videoRect(
            canvasSize: canvasSize,
            padding: canvas.padding,
            sourceWidth: 160,
            sourceHeight: 90,
            cropUV: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let layout = ExportCanvasLayout(
            width: width,
            height: height,
            videoRect: videoRect,
            cornerRadius: canvas.cornerRadius,
            padding: canvas.padding
        )
        let compositor = ExportCompositor(
            context: context,
            colorSpace: colorSpace,
            canvas: canvas,
            keyboardOverlay: keyboardSettings,
            webcamOverlay: webcamSettings,
            webcamMirror: webcamMirror,
            layout: layout,
            sourceWidth: 160,
            sourceHeight: 90,
            displayScale: 1,
            cursorImage: cursorImage,
            cursorSprite: cursorSprite,
            captions: captions,
            annotations: annotations,
            redactions: redactions,
            drawings: drawings,
            deviceFrame: deviceFrame
        )
        let pixelBuffer = try makePixelBuffer()
        compositor.render(
            source: makeSourceImage(),
            webcam: webcam,
            cropUV: crop,
            cursorUV: cursorUV,
            cursorVelocity: cursorVelocity,
            clicking: clicking,
            clickAge: clickAge,
            keyboardState: keyboardState,
            sourceTime: sourceTime,
            into: pixelBuffer
        )
        return try renderBytes(pixelBuffer)
    }

    private static let goldenCaption = CaptionCue(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        start: 1.5,
        end: 2.5,
        text: "Golden caption",
        style: CaptionStyle(fontSize: 32, position: .bottom, maxWidth: 0.7)
    )

    private static let goldenAnnotations: [Annotation] = [
        Annotation(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            start: 1.5,
            end: 2.5,
            kind: .text,
            text: "Note",
            position: Point2D(x: 0.25, y: 0.22),
            color: RGBAColor(r: 1, g: 0.86, b: 0.2),
            fontSize: 28
        ),
        Annotation(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            start: 1.5,
            end: 2.5,
            kind: .arrow,
            position: Point2D(x: 0.2, y: 0.62),
            endPosition: Point2D(x: 0.55, y: 0.42),
            color: RGBAColor(r: 1, g: 0.24, b: 0.12),
            fontSize: 30
        ),
        Annotation(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            start: 1.5,
            end: 2.5,
            kind: .spotlight,
            rect: Rect2D(x: 0.58, y: 0.25, width: 0.28, height: 0.34),
            color: RGBAColor(r: 0.3, g: 0.8, b: 1),
            fontSize: 30,
            dimAmount: 0.32
        ),
    ]

    private static func makeSourceImage() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 160, height: 90)
        var image = CIImage(color: CIColor(red: 0.08, green: 0.12, blue: 0.18)).cropped(to: extent)
        let tiles: [(CGRect, CIColor)] = [
            (CGRect(x: 0, y: 45, width: 80, height: 45), CIColor(red: 0.9, green: 0.18, blue: 0.12)),
            (CGRect(x: 80, y: 45, width: 80, height: 45), CIColor(red: 0.12, green: 0.72, blue: 0.26)),
            (CGRect(x: 0, y: 0, width: 80, height: 45), CIColor(red: 0.12, green: 0.28, blue: 0.88)),
            (CGRect(x: 80, y: 0, width: 80, height: 45), CIColor(red: 0.92, green: 0.7, blue: 0.12)),
        ]
        for (rect, color) in tiles {
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        return image
    }

    private static func makeWebcamImage() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 54)
        var image = CIImage(color: CIColor(red: 0.15, green: 0.72, blue: 0.86)).cropped(to: extent)
        image = CIImage(color: CIColor(red: 0.94, green: 0.22, blue: 0.58))
            .cropped(to: CGRect(x: 0, y: 0, width: 30, height: 54))
            .composited(over: image)
        image = CIImage(color: CIColor(red: 0.98, green: 0.88, blue: 0.24))
            .cropped(to: CGRect(x: 66, y: 12, width: 30, height: 30))
            .composited(over: image)
        return image
    }

    private static func makeCursorImage() -> CIImage {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 14, height: 20))
        let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05))
            .cropped(to: CGRect(x: 2, y: 2, width: 4, height: 16))
        return dark.composited(over: white)
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw OpenRecordError.io("Could not allocate compositor golden pixel buffer (\(status))")
        }
        return pixelBuffer
    }

    private static func renderBytes(_ pixelBuffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw OpenRecordError.io("Compositor golden pixel buffer has no readable storage")
        }
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = y * bytesPerRow + x * 4
                let destinationOffset = (y * width + x) * 4
                bytes[destinationOffset] = source[sourceOffset + 2]
                bytes[destinationOffset + 1] = source[sourceOffset + 1]
                bytes[destinationOffset + 2] = source[sourceOffset]
                bytes[destinationOffset + 3] = source[sourceOffset + 3]
            }
        }
        return bytes
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func blockFingerprint(_ bytes: [UInt8]) -> String {
        var values: [UInt8] = []
        values.reserveCapacity(columns * rows * 3)
        for blockY in 0..<rows {
            let minY = blockY * height / rows
            let maxY = (blockY + 1) * height / rows
            for blockX in 0..<columns {
                let minX = blockX * width / columns
                let maxX = (blockX + 1) * width / columns
                var red = 0
                var green = 0
                var blue = 0
                var count = 0
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        let offset = (y * width + x) * 4
                        red += Int(bytes[offset])
                        green += Int(bytes[offset + 1])
                        blue += Int(bytes[offset + 2])
                        count += 1
                    }
                }
                values.append(UInt8(red / max(count, 1)))
                values.append(UInt8(green / max(count, 1)))
                values.append(UInt8(blue / max(count, 1)))
            }
        }
        return values.map { String(format: "%02x", $0) }.joined()
    }

    private static func compare(
        _ actual: GoldenReference,
        expected: GoldenReference,
        caseID: String
    ) throws {
        if expected.enforceExactHash, actual.hash != expected.hash {
            throw OpenRecordError.io(
                "\(caseID) exact pixels changed: got \(actual.hash), expected \(expected.hash)"
            )
        }
        let observed = try decodeHex(actual.fingerprint, caseID: caseID)
        let reference = try decodeHex(expected.fingerprint, caseID: caseID)
        guard observed.count == reference.count else {
            throw OpenRecordError.io("\(caseID) golden fingerprint length changed")
        }
        let deltas = zip(observed, reference).map { abs(Int($0) - Int($1)) }
        let maximum = Double(deltas.max() ?? 0)
        let mean = Double(deltas.reduce(0, +)) / Double(max(deltas.count, 1))
        guard maximum <= expected.maxChannelDelta,
              mean <= expected.meanChannelDelta
        else {
            throw OpenRecordError.io(
                "\(caseID) pixels exceeded tolerance: max \(maximum)/\(expected.maxChannelDelta), mean \(mean)/\(expected.meanChannelDelta); hash \(actual.hash)"
            )
        }
    }

    private static func decodeHex(_ string: String, caseID: String) throws -> [UInt8] {
        guard string.count.isMultiple(of: 2) else {
            throw OpenRecordError.io("\(caseID) golden fingerprint is not byte-aligned")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let end = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<end], radix: 16) else {
                throw OpenRecordError.io("\(caseID) golden fingerprint contains invalid hex")
            }
            bytes.append(byte)
            index = end
        }
        return bytes
    }

    private static func loadManifest() throws -> GoldenManifest {
#if GOLDEN_RECORDING
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/OpenRecordTests/Fixtures/CompositorGolden/manifest.json")
#else
        guard let resources = Bundle.module.resourceURL else {
            throw OpenRecordError.io("SwiftPM did not provide compositor golden resources")
        }
        let url = resources
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("CompositorGolden", isDirectory: true)
            .appendingPathComponent("manifest.json")
#endif
        var manifest = try ProjectJSON.decoder.decode(
            GoldenManifest.self,
            from: Data(contentsOf: url)
        )
#if GOLDEN_RECORDING
        manifest.frames = [:]
#endif
        return manifest
    }

    private struct GoldenManifest: Codable {
        var schemaVersion: Int
        var width: Int
        var height: Int
        var columns: Int
        var rows: Int
        var frames: [String: GoldenReference]
    }

    private struct GoldenReference: Codable {
        var hash: String
        var enforceExactHash: Bool
        var fingerprint: String
        var maxChannelDelta: Double
        var meanChannelDelta: Double
    }
}

#if GOLDEN_RECORDING
@main
struct CompositorGoldenRecorder {
    static func main() {
        do {
            try CompositorGoldenSuite.run()
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
        }
    }
}
#else
@Test
func compositorGoldenFramesCoverTheV3VisualStack() throws {
    try CompositorGoldenSuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCompositorGoldenTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCompositorGoldenTests()
}

@_cdecl("OpenRecordRunCompositorGoldenTests")
func OpenRecordRunCompositorGoldenTests() {
    do {
        try CompositorGoldenSuite.run()
        fputs("OpenRecordTests: compositor golden tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: compositor golden tests failed: \(error.localizedDescription)\n", stderr)
        abort()
    }
}
#endif
#endif
