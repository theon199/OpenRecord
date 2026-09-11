import CoreGraphics
import Foundation
import Testing
@testable import OpenRecord

enum FrameSceneTests {
    static func run() {
        resolverUsesOutputClockAndHalfOpenBoundaries()
        sceneCarriesCropSpecificGeometryAndStableLayerOrder()
        outputFormatsResolveTheSameSceneAtOnePlayhead()
    }

    static func resolverUsesOutputClockAndHalfOpenBoundaries() {
        let captionBeforeCut = CaptionCue(
            start: 1.5,
            end: 2,
            text: "before"
        )
        let captionAtCut = CaptionCue(
            start: 4,
            end: 5,
            text: "after"
        )
        let document = ProjectDocument(
            trimOut: 8,
            speedSegments: [SpeedSegment(start: 4, end: 6, rate: 2)],
            captions: [captionBeforeCut, captionAtCut],
            editDecisions: [EditDecision(start: 2, end: 4)]
        )
        let mapper = ProjectTimeMapper(project: document, sourceDuration: 8)
        let engine = ZoomEngine(document: document)

        // Retained source [0, 2) occupies output [0, 2). At the half-open
        // cut boundary, output t=2 is source t=4, never the cut's end.
        let scene = FrameSceneResolver.resolve(
            document: document,
            timeMapper: mapper,
            zoomEngine: engine,
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedOutputTime: 2,
            keyboardTimeline: KeyboardOverlayTimeline(samples: [])
        )
        #expect(scene.outputTime == 2)
        #expect(scene.sourceTime == 4)
        #expect(scene.activeCaptions.map(\.text) == ["after"])

        // The speed boundary is also half-open: output t=3 resolves to the
        // source endpoint of the 2× span, while output t just before it stays
        // inside that span.
        let beforeSpeedBoundary = FrameSceneResolver.resolve(
            document: document,
            timeMapper: mapper,
            zoomEngine: engine,
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedOutputTime: 3 - 1e-6
        )
        let atSpeedBoundary = FrameSceneResolver.resolve(
            document: document,
            timeMapper: mapper,
            zoomEngine: engine,
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedOutputTime: 3
        )
        #expect(beforeSpeedBoundary.sourceTime < 6)
        #expect(atSpeedBoundary.sourceTime == 6)
    }

    static func sceneCarriesCropSpecificGeometryAndStableLayerOrder() {
        let document = ProjectDocument(
            trimOut: 4,
            zoomRanges: [
                ZoomRange(
                    start: 0,
                    end: 4,
                    amount: 2,
                    anchor: Point2D(x: 0.75, y: 0.4)
                )
            ],
            canvas: CanvasSettings(
                padding: 20,
                cornerRadius: 18,
                aspectWidth: 16,
                aspectHeight: 9
            )
        )
        let mapper = ProjectTimeMapper(project: document, sourceDuration: 4)
        let engine = ZoomEngine(document: document)
        let scene = FrameSceneResolver.resolve(
            document: document,
            timeMapper: mapper,
            zoomEngine: engine,
            sourceWidth: 1920,
            sourceHeight: 1080,
            requestedOutputTime: 2
        )

        #expect(scene.cropUV.width < 1)
        #expect(scene.cropUV.height < 1)
        #expect(scene.layout.width > 0)
        #expect(scene.layout.height > 0)
        #expect(scene.layout.videoRect.width > 0)
        #expect(scene.deviceFrameGeometry.screenRect == scene.layout.videoRect)
        #expect(FrameScene.layerOrder == [
            .background,
            .source,
            .deviceFrame,
            .webcam,
            .cursor,
            .keyboard,
            .authoredOverlays,
            .redactions,
        ])
    }

    static func outputFormatsResolveTheSameSceneAtOnePlayhead() {
        let document = ProjectDocument(
            trimOut: 6,
            speedSegments: [SpeedSegment(start: 2, end: 4, rate: 2)],
            captions: [CaptionCue(start: 2, end: 4, text: "shared")],
            editDecisions: [EditDecision(start: 1, end: 2)]
        )
        let mapper = ProjectTimeMapper(project: document, sourceDuration: 6)
        let engine = ZoomEngine(document: document)
        let outputTime = 1.25
        let scenes = (0..<3).map { _ in
            FrameSceneResolver.resolve(
                document: document,
                timeMapper: mapper,
                zoomEngine: engine,
                sourceWidth: 1280,
                sourceHeight: 720,
                requestedOutputTime: outputTime
            )
        }
        #expect(scenes.dropFirst().allSatisfy { $0 == scenes[0] })
        #expect(scenes[0].outputTime == outputTime)
        #expect(scenes[0].activeCaptions.map(\.text) == ["shared"])
    }
}

@Test
func frameSceneResolution() {
    FrameSceneTests.run()
}
