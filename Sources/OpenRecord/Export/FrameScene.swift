import CoreGraphics
import Foundation

/// The complete, renderer-independent description of one output frame.
///
/// A scene is resolved in output-clock space. `outputTime` is clamped to the
/// mapper's output interval and `sourceTime` is the one canonical source-clock
/// lookup used by every source-timed effect. The scene intentionally contains
/// values only; decoders, Core Image images, and other media objects remain in
/// the renderer that consumes it.
public struct FrameScene: Sendable, Equatable {
    /// Stable compositing order. Later layers are composited over earlier
    /// layers; selection handles and draft strokes are preview-only and are
    /// deliberately not part of this render order.
    public enum Layer: String, CaseIterable, Sendable, Hashable {
        case background
        case source
        case deviceFrame
        case webcam
        case cursor
        case keyboard
        case authoredOverlays
        case redactions
    }

    public static let layerOrder: [Layer] = [
        .background,
        .source,
        .deviceFrame,
        .webcam,
        .cursor,
        .keyboard,
        .authoredOverlays,
        .redactions,
    ]

    public let outputTime: TimeInterval
    public let sourceTime: TimeInterval
    public let cropUV: CGRect
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let layout: ExportCanvasLayout
    public let canvas: CanvasSettings

    public let deviceFrame: DeviceFrameSettings
    public let deviceFrameGeometry: DeviceFrameGeometry

    public let webcamOverlay: WebcamOverlaySettings
    public let webcamSourceTime: TimeInterval?
    public let webcamGeometry: WebcamOverlayGeometry?
    public let webcamMirror: Bool
    public let webcamSourceAspect: Double?

    public let cursorUV: Point2D?
    public let cursorVelocity: Point2D?
    public let cursorTreatment: CursorTreatmentState
    public let clicking: Bool
    public let clickAge: TimeInterval?
    public let cursorMotionBlur: CursorMotionBlurState
    public let cursorSpritePlacement: CursorSpritePlacement?
    public let cursorPixelsPerPoint: Double

    public let keyboardOverlay: KeyboardOverlaySettings
    public let keyboardState: KeyboardOverlayState
    public let keyboardGeometry: KeyboardOverlayGeometry?

    public let activeCaptions: [CaptionCue]
    public let activeAnnotations: [Annotation]
    public let activeDrawings: [DrawingStroke]
    public let activeRedactions: [RedactionRegion]

    public init(
        outputTime: TimeInterval,
        sourceTime: TimeInterval,
        cropUV: CGRect,
        sourceWidth: Int = 1,
        sourceHeight: Int = 1,
        layout: ExportCanvasLayout,
        canvas: CanvasSettings = .default,
        deviceFrame: DeviceFrameSettings = .none,
        deviceFrameGeometry: DeviceFrameGeometry? = nil,
        webcamOverlay: WebcamOverlaySettings = .disabled,
        webcamSourceTime: TimeInterval? = nil,
        webcamGeometry: WebcamOverlayGeometry? = nil,
        webcamMirror: Bool = false,
        webcamSourceAspect: Double? = nil,
        cursorUV: Point2D? = nil,
        cursorVelocity: Point2D? = nil,
        cursorTreatment: CursorTreatmentState = CursorTreatmentState(),
        clicking: Bool = false,
        clickAge: TimeInterval? = nil,
        cursorMotionBlur: CursorMotionBlurState = .none,
        cursorSpritePlacement: CursorSpritePlacement? = nil,
        cursorPixelsPerPoint: Double = 1,
        keyboardOverlay: KeyboardOverlaySettings = .disabled,
        keyboardState: KeyboardOverlayState = KeyboardOverlayState(),
        keyboardGeometry: KeyboardOverlayGeometry? = nil,
        activeCaptions: [CaptionCue] = [],
        activeAnnotations: [Annotation] = [],
        activeDrawings: [DrawingStroke] = [],
        activeRedactions: [RedactionRegion] = []
    ) {
        self.outputTime = outputTime
        self.sourceTime = sourceTime
        self.cropUV = cropUV
        self.sourceWidth = max(sourceWidth, 1)
        self.sourceHeight = max(sourceHeight, 1)
        self.layout = layout
        self.canvas = canvas
        let normalizedDeviceFrame = deviceFrame.normalized
        self.deviceFrame = normalizedDeviceFrame
        self.deviceFrameGeometry = deviceFrameGeometry
            ?? DeviceFrameLayout.geometry(
                settings: normalizedDeviceFrame,
                contentRect: layout.videoRect
            )
        self.webcamOverlay = webcamOverlay.normalized
        self.webcamSourceTime = webcamSourceTime
        self.webcamGeometry = webcamGeometry
        self.webcamMirror = webcamMirror
        self.webcamSourceAspect = webcamSourceAspect
        self.cursorUV = cursorUV
        self.cursorVelocity = cursorVelocity
        self.cursorTreatment = cursorTreatment
        self.clicking = clicking
        self.clickAge = clickAge
        self.cursorMotionBlur = cursorMotionBlur
        self.cursorSpritePlacement = cursorSpritePlacement
        self.cursorPixelsPerPoint = cursorPixelsPerPoint
        self.keyboardOverlay = keyboardOverlay.normalized
        self.keyboardState = keyboardState
        self.keyboardGeometry = keyboardGeometry
        self.activeCaptions = activeCaptions
        self.activeAnnotations = activeAnnotations
        self.activeDrawings = activeDrawings
        self.activeRedactions = activeRedactions
    }
}

/// Metadata needed to resolve a webcam lane without retaining media objects
/// in a scene. `sourceDuration` is the local webcam-track duration; its
/// timeline offset and optional diagnostics use the same rules as preview.
public struct FrameSceneWebcamMetadata: Sendable, Equatable {
    public var sourceDuration: TimeInterval
    public var legacyOffset: TimeInterval
    public var diagnostics: CaptureDiagnostics?
    public var mirror: Bool
    public var sourceAspect: Double?

    public init(
        sourceDuration: TimeInterval,
        legacyOffset: TimeInterval = 0,
        diagnostics: CaptureDiagnostics? = nil,
        mirror: Bool = false,
        sourceAspect: Double? = nil
    ) {
        self.sourceDuration = sourceDuration
        self.legacyOffset = legacyOffset
        self.diagnostics = diagnostics
        self.mirror = mirror
        self.sourceAspect = sourceAspect
    }
}

/// Cursor image metadata used only to calculate the immutable sprite
/// placement. The image itself stays owned by the Core Image/SwiftUI renderer.
public struct FrameSceneCursorMetadata: Sendable, Equatable {
    public var sprite: CursorSprite?
    public var imagePixelSize: Size2D?

    public init(sprite: CursorSprite? = nil, imagePixelSize: Size2D? = nil) {
        self.sprite = sprite
        self.imagePixelSize = imagePixelSize
    }
}

/// Pure output-time scene resolution shared by editor preview and export.
public enum FrameSceneResolver: Sendable {
    /// Resolves all source-timed state at `requestedOutputTime`.
    ///
    /// The mapper is consulted exactly once. In particular, callers must pass
    /// the editor/output playhead here rather than first converting it to a
    /// source timestamp. Crop layout, frame geometry, and every active lane
    /// then derive from that one canonical source time.
    public static func resolve(
        document: ProjectDocument,
        timeMapper: ProjectTimeMapper,
        zoomEngine: ZoomEngine,
        sourceWidth: Int,
        sourceHeight: Int,
        displayScale: Double = 1,
        requestedOutputTime: TimeInterval,
        webcam: FrameSceneWebcamMetadata?,
        cursor: FrameSceneCursorMetadata? = nil,
        keyboardTimeline: KeyboardOverlayTimeline? = nil,
        cropOverride: CGRect? = nil
    ) -> FrameScene {
        let outputTime = canonicalOutputTime(
            requestedOutputTime,
            duration: timeMapper.outputDuration
        )
        let sourceTime = timeMapper.sourceTime(atOutputTime: outputTime)
        let crop = normalizedCrop(cropOverride ?? zoomEngine.crop(at: sourceTime))
        let layout = ExportLayout.canvasLayout(
            canvas: document.canvas,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropUV: crop,
            resolution: document.videoExportSettings.resolution
        )
        let deviceFrame = document.deviceFrame.normalized
        let deviceGeometry = DeviceFrameLayout.geometry(
            settings: deviceFrame,
            contentRect: layout.videoRect
        )

        let webcamSettings = document.webcamOverlay.normalized
        let webcamAspect = webcam?.sourceAspect
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let webcamTime: TimeInterval?
        if webcamSettings.enabled, let webcam {
            webcamTime = WebcamTimeline.sourceTime(
                atTimelineTime: sourceTime,
                sourceDuration: webcam.sourceDuration,
                legacyOffset: webcam.legacyOffset,
                diagnostics: webcam.diagnostics
            )
        } else {
            webcamTime = nil
        }
        let webcamGeometry = webcamSettings.enabled
            ? WebcamOverlayLayout.geometry(
                settings: webcamSettings,
                canvasSize: layout.size,
                sourceAspect: webcamAspect ?? (16.0 / 9.0)
            )
            : nil

        let cursorUV = zoomEngine.interpolateCursor(at: sourceTime)
        let cursorVelocity = zoomEngine.cursorVelocity(at: sourceTime)
        let clickState = zoomEngine.smoother.clickState(at: sourceTime)
        let clicking = zoomEngine.isClicking(at: sourceTime)
        let cursorTreatment = CursorTreatmentEvaluator(
            ranges: document.cursorEffects
        ).state(
            at: sourceTime,
            baseScale: document.canvas.cursorScale,
            baseClickEmphasis: document.canvas.cursorClickEmphasis,
            baseHalo: document.canvas.cursorHalo
        )
        let cursorMotionBlur = CursorMotionBlurEffect.state(
            velocity: cursorVelocity,
            canvasSize: layout.size,
            settings: document.canvas.cursorMotionBlur
        )
        let pixelsPerPoint = ExportLayout.canvasPixelsPerPoint(
            displayScale: displayScale,
            sourceWidth: sourceWidth,
            cropUV: crop,
            videoRect: deviceGeometry.screenRect
        )
        let spritePlacement: CursorSpritePlacement?
        if let sprite = cursor?.sprite,
           let imagePixelSize = cursor?.imagePixelSize {
            spritePlacement = CursorSpriteLayout.placement(
                sprite: sprite,
                imagePixelSize: imagePixelSize,
                cursorScale: cursorTreatment.scale,
                pixelsPerPoint: pixelsPerPoint
            )
        } else {
            spritePlacement = nil
        }

        let keyboardSettings = document.keyboardOverlay.normalized
        let keyboardState = (keyboardTimeline ?? KeyboardOverlayTimeline(samples: []))
            .state(at: sourceTime, settings: keyboardSettings)
        let keyboardGeometry = KeyboardOverlayLayout.geometry(
            for: keyboardState,
            settings: keyboardSettings,
            canvasSize: layout.size,
            canvasPadding: document.canvas.padding
        )

        return FrameScene(
            outputTime: outputTime,
            sourceTime: sourceTime,
            cropUV: crop,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            layout: layout,
            canvas: document.canvas,
            deviceFrame: deviceFrame,
            deviceFrameGeometry: deviceGeometry,
            webcamOverlay: webcamSettings,
            webcamSourceTime: webcamTime,
            webcamGeometry: webcamGeometry,
            webcamMirror: webcam?.mirror ?? false,
            webcamSourceAspect: webcamAspect,
            cursorUV: cursorUV,
            cursorVelocity: cursorVelocity,
            cursorTreatment: cursorTreatment,
            clicking: clicking,
            clickAge: clicking ? clickState.age : nil,
            cursorMotionBlur: cursorMotionBlur,
            cursorSpritePlacement: spritePlacement,
            cursorPixelsPerPoint: pixelsPerPoint,
            keyboardOverlay: keyboardSettings,
            keyboardState: keyboardState,
            keyboardGeometry: keyboardGeometry,
            activeCaptions: document.captions
                .filter { $0.isActive(at: sourceTime) }
                .map(\.normalized),
            activeAnnotations: document.annotations
                .filter { $0.isActive(at: sourceTime) }
                .map(\.normalized),
            activeDrawings: document.drawings
                .filter { $0.isActive(at: sourceTime) }
                .map(\.normalized),
            activeRedactions: document.redactions
                .filter { $0.isActive(at: sourceTime) }
                .map(\.normalized)
        )
    }

    /// Convenience overload for callers that have the individual capture
    /// metadata already available (the common export and preview path).
    public static func resolve(
        document: ProjectDocument,
        timeMapper: ProjectTimeMapper,
        zoomEngine: ZoomEngine,
        sourceWidth: Int,
        sourceHeight: Int,
        displayScale: Double = 1,
        requestedOutputTime: TimeInterval,
        webcamSourceDuration: TimeInterval = 0,
        webcamOffset: TimeInterval = 0,
        captureDiagnostics: CaptureDiagnostics? = nil,
        webcamMirror: Bool = false,
        webcamSourceAspect: Double? = nil,
        cursorSprite: CursorSprite? = nil,
        cursorImagePixelSize: Size2D? = nil,
        keyboardTimeline: KeyboardOverlayTimeline? = nil,
        cropOverride: CGRect? = nil
    ) -> FrameScene {
        let webcam: FrameSceneWebcamMetadata? = document.webcamOverlay.enabled
            ? FrameSceneWebcamMetadata(
                sourceDuration: webcamSourceDuration,
                legacyOffset: webcamOffset,
                diagnostics: captureDiagnostics,
                mirror: webcamMirror,
                sourceAspect: webcamSourceAspect
            )
            : nil
        return resolve(
            document: document,
            timeMapper: timeMapper,
            zoomEngine: zoomEngine,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            displayScale: displayScale,
            requestedOutputTime: requestedOutputTime,
            webcam: webcam,
            cursor: FrameSceneCursorMetadata(
                sprite: cursorSprite,
                imagePixelSize: cursorImagePixelSize
            ),
            keyboardTimeline: keyboardTimeline,
            cropOverride: cropOverride
        )
    }

    public static func canonicalOutputTime(
        _ requested: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let duration = duration.isFinite ? max(duration, 0) : 0
        if requested.isNaN || requested == -.infinity { return 0 }
        if requested == .infinity { return duration }
        return min(max(requested, 0), duration)
    }

    private static func normalizedCrop(_ raw: CGRect) -> CGRect {
        let width = raw.width.isFinite ? min(max(raw.width, 0), 1) : 1
        let height = raw.height.isFinite ? min(max(raw.height, 0), 1) : 1
        var x = raw.origin.x.isFinite ? raw.origin.x : 0
        var y = raw.origin.y.isFinite ? raw.origin.y : 0
        x = min(max(x, 0), 1 - width)
        y = min(max(y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
