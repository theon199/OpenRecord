import CoreGraphics
import Foundation

public struct DeviceFrameGeometry: Sendable, Equatable {
    public var frameRect: CGRect
    public var screenRect: CGRect
    public var cornerRadius: CGFloat
    public var chromeHeight: CGFloat

    public init(
        frameRect: CGRect,
        screenRect: CGRect,
        cornerRadius: CGFloat,
        chromeHeight: CGFloat = 0
    ) {
        self.frameRect = frameRect
        self.screenRect = screenRect
        self.cornerRadius = cornerRadius
        self.chromeHeight = chromeHeight
    }
}

/// Shared device-frame geometry consumed verbatim by preview and export.
public enum DeviceFrameLayout: Sendable {
    public static func geometry(
        settings rawSettings: DeviceFrameSettings,
        contentRect: CGRect
    ) -> DeviceFrameGeometry {
        let settings = rawSettings.normalized
        guard settings.enabled, contentRect.width > 1, contentRect.height > 1 else {
            return DeviceFrameGeometry(
                frameRect: contentRect,
                screenRect: contentRect,
                cornerRadius: 0
            )
        }

        let frame = scaled(contentRect, by: CGFloat(settings.scale))
        let short = min(frame.width, frame.height)
        switch settings.id {
        case .none:
            return DeviceFrameGeometry(frameRect: frame, screenRect: frame, cornerRadius: 0)
        case .genericBrowserLight:
            let bezel = max(short * 0.018, 2)
            let chrome = max(frame.height * 0.085, bezel * 3)
            return DeviceFrameGeometry(
                frameRect: frame,
                screenRect: CGRect(
                    x: frame.minX + bezel,
                    y: frame.minY + chrome,
                    width: max(frame.width - bezel * 2, 1),
                    height: max(frame.height - chrome - bezel, 1)
                ),
                cornerRadius: short * 0.035,
                chromeHeight: chrome
            )
        case .genericLaptopDark:
            let side = max(short * 0.035, 3)
            let top = max(short * 0.035, 3)
            let base = max(frame.height * 0.09, side * 2)
            return DeviceFrameGeometry(
                frameRect: frame,
                screenRect: CGRect(
                    x: frame.minX + side,
                    y: frame.minY + top,
                    width: max(frame.width - side * 2, 1),
                    height: max(frame.height - top - base, 1)
                ),
                cornerRadius: short * 0.045,
                chromeHeight: base
            )
        case .genericPhoneDark:
            let side = max(short * 0.055, 4)
            let vertical = max(short * 0.04, 3)
            return DeviceFrameGeometry(
                frameRect: frame,
                screenRect: frame.insetBy(dx: side, dy: vertical),
                cornerRadius: short * 0.12,
                chromeHeight: 0
            )
        }
    }

    private static func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        let width = rect.width * scale
        let height = rect.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}

public enum AuthoredVisualLayout: Sendable {
    public static func point(_ point: Point2D, in canvasSize: CGSize) -> CGPoint {
        let value = NormalizedCanvasGeometry.point(point)
        return CGPoint(x: value.x * canvasSize.width, y: value.y * canvasSize.height)
    }

    public static func rect(_ rect: Rect2D, in canvasSize: CGSize) -> CGRect {
        let value = NormalizedCanvasGeometry.rect(rect)
        return CGRect(
            x: value.x * canvasSize.width,
            y: value.y * canvasSize.height,
            width: value.width * canvasSize.width,
            height: value.height * canvasSize.height
        )
    }
}

public struct AnnotationPresentation: Sendable, Equatable, Hashable {
    public var opacity: Double
    public var scale: Double

    public init(opacity: Double = 1, scale: Double = 1) {
        self.opacity = opacity
        self.scale = scale
    }
}

public enum AnnotationAnimationEvaluator: Sendable {
    public static func presentation(
        for annotation: Annotation,
        at time: TimeInterval
    ) -> AnnotationPresentation {
        guard annotation.isActive(at: time) else {
            return AnnotationPresentation(opacity: 0, scale: 1)
        }
        let animation = annotation.animation.normalized
        let duration = min(animation.duration, max((annotation.end - annotation.start) / 2, 0.001))
        let entranceProgress = min(max((time - annotation.start) / duration, 0), 1)
        let exitProgress = min(max((annotation.end - time) / duration, 0), 1)
        var opacity = 1.0
        var scale = 1.0
        apply(animation.entrance, progress: entranceProgress, opacity: &opacity, scale: &scale)
        apply(animation.exit, progress: exitProgress, opacity: &opacity, scale: &scale)
        return AnnotationPresentation(opacity: opacity, scale: scale)
    }

    private static func apply(
        _ style: AnnotationAnimationStyle,
        progress: Double,
        opacity: inout Double,
        scale: inout Double
    ) {
        let eased = progress * progress * (3 - 2 * progress)
        switch style {
        case .none:
            break
        case .fade:
            opacity = min(opacity, eased)
        case .pop:
            opacity = min(opacity, eased)
            scale = min(scale, 0.82 + 0.18 * eased)
        }
    }
}
