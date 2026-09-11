import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Shared visual frame preparation for video, GIF, and snapshot output.
///
/// This service owns sequential decoders and the Core Image compositor. It
/// accepts only output-clock timestamps, resolves one `FrameScene`, and uses
/// that scene for both media reads and compositing. `FrameScene` itself stays
/// value-only and can therefore also be used by SwiftUI preview.
final class FrameRenderService: @unchecked Sendable {
    let reader: ExportVideoReader
    let webcamReader: ExportVideoReader?
    let webcamDuration: TimeInterval
    let webcamOffset: TimeInterval
    let captureDiagnostics: CaptureDiagnostics?
    let webcamMirror: Bool
    let webcamSourceAspect: Double?
    let timeMapper: ProjectTimeMapper
    let project: ProjectDocument
    let engine: ZoomEngine
    let keyboardTimeline: KeyboardOverlayTimeline
    let cursor: FrameSceneCursorMetadata
    let compositor: ExportCompositor
    let context: CIContext
    let width: Int
    let height: Int
    let displayScale: Double

    init(
        project: ProjectDocument,
        reader: ExportVideoReader,
        webcamReader: ExportVideoReader? = nil,
        webcamDuration: TimeInterval = 0,
        webcamOffset: TimeInterval = 0,
        captureDiagnostics: CaptureDiagnostics? = nil,
        webcamMirror: Bool = false,
        webcamSourceAspect: Double? = nil,
        timeMapper: ProjectTimeMapper,
        engine: ZoomEngine,
        keyboardTimeline: KeyboardOverlayTimeline,
        cursor: FrameSceneCursorMetadata,
        compositor: ExportCompositor,
        context: CIContext,
        width: Int,
        height: Int,
        displayScale: Double = 1
    ) {
        self.project = project
        self.reader = reader
        self.webcamReader = webcamReader
        self.webcamDuration = webcamDuration
        self.webcamOffset = webcamOffset
        self.captureDiagnostics = captureDiagnostics
        self.webcamMirror = webcamMirror
        self.webcamSourceAspect = webcamSourceAspect
        self.timeMapper = timeMapper
        self.engine = engine
        self.keyboardTimeline = keyboardTimeline
        self.cursor = cursor
        self.compositor = compositor
        self.context = context
        self.width = width
        self.height = height
        self.displayScale = displayScale
    }

    func scene(atOutputTime outputTime: TimeInterval) -> FrameScene {
        FrameSceneResolver.resolve(
            document: project,
            timeMapper: timeMapper,
            zoomEngine: engine,
            sourceWidth: reader.sourceWidth,
            sourceHeight: reader.sourceHeight,
            displayScale: displayScale,
            requestedOutputTime: outputTime,
            webcamSourceDuration: webcamDuration,
            webcamOffset: webcamOffset,
            captureDiagnostics: captureDiagnostics,
            webcamMirror: webcamMirror,
            webcamSourceAspect: webcamSourceAspect,
            cursorSprite: cursor.sprite,
            cursorImagePixelSize: cursor.imagePixelSize,
            keyboardTimeline: keyboardTimeline
        )
    }

    /// Renders one output timestamp into a caller-owned pixel buffer and
    /// returns the exact scene used for that render.
    @discardableResult
    func render(
        atOutputTime outputTime: TimeInterval,
        into pixelBuffer: CVPixelBuffer
    ) throws -> FrameScene {
        try Task.checkCancellation()
        let scene = scene(atOutputTime: outputTime)
        let source = try reader.image(at: scene.sourceTime)
        let webcam = try webcamImage(for: scene)
        compositor.render(
            source: source,
            webcam: webcam,
            scene: scene,
            into: pixelBuffer
        )
        try Task.checkCancellation()
        return scene
    }

    func image(atOutputTime outputTime: TimeInterval) throws -> CGImage? {
        let buffer = try ExportMediaIO.makePixelBuffer(width: width, height: height)
        _ = try render(atOutputTime: outputTime, into: buffer)
        return context.createCGImage(
            CIImage(cvPixelBuffer: buffer),
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private func webcamImage(for scene: FrameScene) throws -> CIImage? {
        guard let webcamReader, let webcamTime = scene.webcamSourceTime,
              webcamTime >= 0, webcamTime <= webcamDuration
        else { return nil }
        do {
            return try webcamReader.image(at: webcamTime)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Webcam is optional. A damaged webcam track must not prevent the
            // display frame from rendering, matching the existing export path.
            return nil
        }
    }
}
