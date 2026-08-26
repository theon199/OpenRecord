import Darwin
import Foundation
import OpenRecord
import Testing

enum StabilizationContractSuite {
    static func run() throws {
        try legacyOptionalFieldsDecode()
        try captureMetadataRoundTripsAtCurrentFormat()
        try cursorSpritePlacementUsesBitmapPixels()
        try cursorAssetResolverRejectsEscapes()
        try targetVisibilityDoesNotBridgeActivity()
        try exportAudioOffsetsArePlacedAgainstVideo()
        try zoomInsertionRespectsTimelineGaps()
        try captureSessionStartsIdle()
        try captureTimeoutRecoveryIsAtomic()
    }

    static func legacyOptionalFieldsDecode() throws {
        let meta = ProjectMeta(
            displayBounds: Rect2D(x: 0, y: 0, width: 100, height: 50),
            scale: 2,
            captureTarget: .display(id: 1)
        )
        let encodedMeta = try ProjectJSON.encoder.encode(meta)
        let decodedMeta = try ProjectJSON.decoder.decode(ProjectMeta.self, from: encodedMeta)
        guard decodedMeta.captureTiming == nil, decodedMeta.captureHealth == nil else {
            throw OpenRecordError.io("legacy capture metadata defaults were not preserved")
        }

        let legacyCursor = Data(#"{"t":1,"x":2,"y":3,"cursorId":"arrow"}"#.utf8)
        let cursor = try ProjectJSON.decoder.decode(CursorSample.self, from: legacyCursor)
        guard cursor.visible == nil, cursor.isVisible else {
            throw OpenRecordError.io("legacy cursor visibility should default to visible")
        }
    }

    static func captureMetadataRoundTripsAtCurrentFormat() throws {
        let meta = ProjectMeta(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            displayBounds: Rect2D(x: 10, y: 20, width: 300, height: 200),
            scale: 2,
            captureTarget: .window(id: 42),
            captureTiming: CaptureTiming(
                systemAudioOffset: 0.05,
                microphoneOffset: -0.2,
                webcamOffset: 0.08
            ),
            captureHealth: CaptureHealth(
                state: .recovered,
                warnings: [.screenStoppedUnexpectedly, .truncatedMicrophone, .truncatedWebcam]
            ),
            webcam: WebcamCaptureInfo(deviceID: "camera-1", mirror: true)
        )
        let decoded = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: ProjectJSON.encoder.encode(meta)
        )
        guard decoded == meta, ProjectDocument.currentFormatVersion == 5 else {
            throw OpenRecordError.io("capture metadata did not round-trip at project format v5")
        }
    }

    static func cursorSpritePlacementUsesBitmapPixels() throws {
        let sprite = CursorSprite(
            id: "arrow",
            hotspot: Point2D(x: 4, y: 6),
            pngRelativePath: "recording/cursors/arrow.png",
            standardSize: Size2D(width: 16, height: 16)
        )
        for scale in [0.1, 0.5, 1.0] {
            let placement = CursorSpriteLayout.placement(
                sprite: sprite,
                imagePixelSize: Size2D(width: 32, height: 32),
                cursorScale: scale,
                pixelsPerPoint: 2
            )
            let expectedSize = 32 * scale
            let expectedHotspot = Point2D(x: 4 * scale, y: 6 * scale)
            guard abs(placement.drawSize.width - expectedSize) < 0.000_001,
                  abs(placement.drawSize.height - expectedSize) < 0.000_001,
                  abs(placement.hotspot.x - expectedHotspot.x) < 0.000_001,
                  abs(placement.hotspot.y - expectedHotspot.y) < 0.000_001
            else {
                throw OpenRecordError.io(
                    "Cursor placement did not preserve the \(scale)× scale in preview/export layout"
                )
            }
        }
    }

    static func cursorAssetResolverRejectsEscapes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "OpenRecordAssetResolver-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundle = root.appendingPathComponent("Demo.openrecord", isDirectory: true)
        let cursors = ProjectLayout.cursorsDirectory(in: bundle)
        try fm.createDirectory(at: cursors, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let arrow = cursors.appendingPathComponent("arrow.png")
        try Data([0]).write(to: arrow)
        guard ProjectAssetResolver.cursorPNG(
            relativePath: "recording/cursors/arrow.png",
            in: bundle
        ) == arrow.standardizedFileURL.resolvingSymlinksInPath() else {
            throw OpenRecordError.io("valid cursor asset was rejected")
        }

        let outside = root.appendingPathComponent("outside.png")
        try Data([1]).write(to: outside)
        let link = cursors.appendingPathComponent("escape.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        for relative in ["../outside.png", "recording/cursors/escape.png", "/tmp/outside.png"] {
            guard ProjectAssetResolver.cursorPNG(relativePath: relative, in: bundle) == nil else {
                throw OpenRecordError.io("cursor asset escape was accepted: \(relative)")
            }
        }
    }

    static func targetVisibilityDoesNotBridgeActivity() throws {
        let bounds = Rect2D(x: 0, y: 0, width: 100, height: 100)
        let geometry = [
            TargetGeometrySample(t: 0, bounds: bounds),
            TargetGeometrySample(
                t: 1,
                bounds: Rect2D(x: 0, y: 0, width: 0, height: 0),
                available: false
            ),
            TargetGeometrySample(t: 2, bounds: bounds),
        ]
        let samples = [
            CursorSample(t: 0.2, x: 10, y: 10, visible: true),
            CursorSample(t: 1.1, x: 500, y: 500, visible: false),
            CursorSample(t: 2.1, x: 90, y: 90, visible: true),
        ]
        let smoother = CursorSmoother(
            samples: samples,
            displayBounds: bounds,
            targetGeometry: geometry
        )
        guard smoother.interpolateIfVisible(at: 0.1) == nil,
              smoother.interpolateIfVisible(at: 1.5) == nil,
              smoother.interpolateIfVisible(at: 2.1) != nil
        else {
            throw OpenRecordError.io("cursor visibility did not follow delayed/missing target intervals")
        }
        let ranges = ZoomEngine.generateAutoZooms(
            samples: samples,
            duration: 3,
            displayBounds: bounds,
            config: AutoZoomConfig(minActiveDuration: 0.01, minZoomHold: 0),
            targetGeometry: geometry
        )
        guard ranges.isEmpty else {
            throw OpenRecordError.io("off-target movement was bridged into an auto-zoom")
        }

        let legacy = CursorSmoother(
            samples: [CursorSample(t: 0, x: 500, y: 500)],
            displayBounds: bounds
        )
        guard legacy.interpolateIfVisible(at: 0) != nil else {
            throw OpenRecordError.io("legacy cursor sample did not default to visible")
        }
    }

    static func exportAudioOffsetsArePlacedAgainstVideo() throws {
        guard ExportLayout.audioPlacement(
            trackOffset: 1,
            trimStart: 0,
            exportDuration: 5,
            sourceDuration: 10
        ) == ExportAudioPlacement(sourceStart: 0, duration: 4, destinationStart: 1) else {
            throw OpenRecordError.io("delayed audio did not insert leading silence")
        }
        guard ExportLayout.audioPlacement(
            trackOffset: -1,
            trimStart: 0,
            exportDuration: 5,
            sourceDuration: 10
        ) == ExportAudioPlacement(sourceStart: 1, duration: 5, destinationStart: 0) else {
            throw OpenRecordError.io("early audio was not trimmed at the video origin")
        }
        guard ExportLayout.audioPlacement(
            trackOffset: 3,
            trimStart: 2,
            exportDuration: 5,
            sourceDuration: 10
        ) == ExportAudioPlacement(sourceStart: 0, duration: 4, destinationStart: 1) else {
            throw OpenRecordError.io("audio placement did not account for the export trim")
        }
    }

    static func zoomInsertionRespectsTimelineGaps() throws {
        let selectedID = UUID()
        let ranges = [
            ZoomRange(
                id: selectedID,
                start: 1,
                end: 2,
                amount: 1.5,
                anchor: Point2D(x: 0.5, y: 0.5)
            ),
            ZoomRange(
                start: 5,
                end: 8,
                amount: 1.5,
                anchor: Point2D(x: 0.5, y: 0.5)
            ),
        ]
        guard ZoomInsertion.proposal(at: 1.5, timelineDuration: 10, ranges: ranges)
            == .select(selectedID)
        else {
            throw OpenRecordError.io("zoom insertion did not select the range under the playhead")
        }
        guard ZoomInsertion.proposal(at: 10, timelineDuration: 10, ranges: ranges)
            == .create(start: 8, end: 10)
        else {
            throw OpenRecordError.io("timeline-end zoom did not fit backward into the free gap")
        }
        guard ZoomInsertion.proposal(at: 4.8, timelineDuration: 10, ranges: ranges)
            == .create(start: 3, end: 5)
        else {
            throw OpenRecordError.io("zoom insertion overlapped its neighboring range")
        }
        let tight = [
            ZoomRange(start: 0, end: 1, amount: 1.5, anchor: Point2D(x: 0.5, y: 0.5)),
            ZoomRange(start: 1.1, end: 2, amount: 1.5, anchor: Point2D(x: 0.5, y: 0.5)),
        ]
        guard ZoomInsertion.proposal(at: 1.05, timelineDuration: 2, ranges: tight)
            == .unavailable
        else {
            throw OpenRecordError.io("zoom insertion accepted a gap below 0.12 seconds")
        }
    }

    static func captureSessionStartsIdle() throws {
        let session = CaptureSession()
        guard session.state == .idle, !session.isRunning else {
            throw OpenRecordError.io("capture session did not initialize in the idle state")
        }
    }

    static func captureTimeoutRecoveryIsAtomic() throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent(
            "OpenRecordTimeout-\(UUID().uuidString).openrecord",
            isDirectory: true
        )
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bundle) }
        let original = ProjectMeta(
            displayBounds: Rect2D(x: 12, y: 34, width: 640, height: 480),
            scale: 2,
            captureTarget: .window(id: 7),
            captureHealth: CaptureHealth(state: .recovered, warnings: [.truncatedMicrophone])
        )
        try ProjectJSON.encoder.encode(original).write(
            to: ProjectLayout.metaURL(in: bundle),
            options: .atomic
        )

        try CaptureRecovery.markFinalizationTimedOut(at: bundle)

        let recovered = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: Data(contentsOf: ProjectLayout.metaURL(in: bundle))
        )
        guard recovered.displayBounds == original.displayBounds,
              recovered.captureHealth?.state == .recovered,
              recovered.captureHealth?.warnings == [.finalizationTimedOut, .truncatedMicrophone]
        else {
            throw OpenRecordError.io("termination timeout did not preserve metadata and warnings")
        }
    }
}

@Test
func stabilizationLegacyContractsDecode() throws {
    try StabilizationContractSuite.legacyOptionalFieldsDecode()
}

@Test
func stabilizationCaptureMetadataRoundTrip() throws {
    try StabilizationContractSuite.captureMetadataRoundTripsAtCurrentFormat()
}

@Test
func stabilizationCursorPlacementUsesBitmapPixels() throws {
    try StabilizationContractSuite.cursorSpritePlacementUsesBitmapPixels()
}

@Test
func stabilizationCursorAssetsStayInsideBundle() throws {
    try StabilizationContractSuite.cursorAssetResolverRejectsEscapes()
}

@Test
func stabilizationTargetVisibilityAndAutoZoom() throws {
    try StabilizationContractSuite.targetVisibilityDoesNotBridgeActivity()
}

@Test
func stabilizationExportAudioOffsets() throws {
    try StabilizationContractSuite.exportAudioOffsetsArePlacedAgainstVideo()
}

@Test
func stabilizationZoomInsertion() throws {
    try StabilizationContractSuite.zoomInsertionRespectsTimelineGaps()
}

@Test
func stabilizationCaptureStateMachineStartsIdle() throws {
    try StabilizationContractSuite.captureSessionStartsIdle()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordStabilizationTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunStabilizationContractTests()
}

@_cdecl("OpenRecordRunStabilizationContractTests")
func OpenRecordRunStabilizationContractTests() {
    do {
        try StabilizationContractSuite.run()
        fputs("OpenRecordTests: stabilization contract tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: stabilization contract tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
