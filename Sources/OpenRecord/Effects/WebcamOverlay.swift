import CoreGraphics
import CoreImage
import Foundation

public struct WebcamOverlayGeometry: Sendable, Hashable {
    public var frame: CGRect
    public var cornerRadius: Double

    public init(frame: CGRect, cornerRadius: Double) {
        self.frame = frame
        self.cornerRadius = cornerRadius
    }
}

/// Shared canvas-pixel geometry for the editor and export compositor.
public enum WebcamOverlayLayout: Sendable {
    /// Returns document settings whose stored center matches the fully-visible
    /// center used by both preview and export. Keeping that canonical position
    /// in the document prevents the overlay from jumping when a drag begins
    /// after a canvas-aspect or overlay-size change.
    public static func clampedSettings(
        _ rawSettings: WebcamOverlaySettings,
        canvasSize: CGSize,
        sourceAspect: Double = 16.0 / 9.0
    ) -> WebcamOverlaySettings {
        var settings = rawSettings.normalized
        guard canvasSize.width > 1, canvasSize.height > 1 else { return settings }

        var layoutSettings = settings
        layoutSettings.enabled = true
        guard let geometry = geometry(
            settings: layoutSettings,
            canvasSize: canvasSize,
            sourceAspect: sourceAspect
        ) else { return settings }

        settings.position = Point2D(
            x: Double(geometry.frame.midX / canvasSize.width),
            y: Double(geometry.frame.midY / canvasSize.height)
        )
        return settings
    }

    /// Applies a canvas-pixel drag to a stable starting snapshot. Callers keep
    /// that snapshot for the duration of a gesture so each pointer update is
    /// deterministic and the document can coalesce the gesture into one edit.
    public static func moving(
        _ originalSettings: WebcamOverlaySettings,
        translation: CGSize,
        canvasSize: CGSize,
        sourceAspect: Double = 16.0 / 9.0
    ) -> WebcamOverlaySettings {
        var settings = clampedSettings(
            originalSettings,
            canvasSize: canvasSize,
            sourceAspect: sourceAspect
        )
        guard canvasSize.width > 1, canvasSize.height > 1 else { return settings }
        settings.position = Point2D(
            x: settings.position.x + Double(translation.width / canvasSize.width),
            y: settings.position.y + Double(translation.height / canvasSize.height)
        )
        return clampedSettings(
            settings,
            canvasSize: canvasSize,
            sourceAspect: sourceAspect
        )
    }

    /// Applies a lower-right handle drag in canvas pixels. Projecting both
    /// pointer axes onto the handle's diagonal keeps the handle under the
    /// pointer while preserving the shape's authored aspect ratio.
    public static func resizing(
        _ originalSettings: WebcamOverlaySettings,
        translation: CGSize,
        canvasSize: CGSize,
        sourceAspect: Double = 16.0 / 9.0
    ) -> WebcamOverlaySettings {
        var settings = clampedSettings(
            originalSettings,
            canvasSize: canvasSize,
            sourceAspect: sourceAspect
        )
        let shortEdge = min(canvasSize.width, canvasSize.height)
        guard shortEdge > 1 else { return settings }
        let widthFactor: CGFloat
        switch settings.shape {
        case .circle:
            widthFactor = 1
        case .roundedRectangle:
            widthFactor = CGFloat(
                min(max(sourceAspect.isFinite ? sourceAspect : 16.0 / 9.0, 1.2), 1.9)
            )
        }
        settings.size += Double(
            2 * (widthFactor * translation.width + translation.height)
                / (shortEdge * (widthFactor * widthFactor + 1))
        )
        return clampedSettings(
            settings,
            canvasSize: canvasSize,
            sourceAspect: sourceAspect
        )
    }

    public static func geometry(
        settings rawSettings: WebcamOverlaySettings,
        canvasSize: CGSize,
        sourceAspect: Double = 16.0 / 9.0
    ) -> WebcamOverlayGeometry? {
        let settings = rawSettings.normalized
        guard settings.enabled, canvasSize.width > 1, canvasSize.height > 1 else {
            return nil
        }

        let shortEdge = min(canvasSize.width, canvasSize.height)
        let baseSize = max(shortEdge * settings.size, 2)
        let size: CGSize
        let cornerRadius: Double
        switch settings.shape {
        case .circle:
            size = CGSize(width: baseSize, height: baseSize)
            cornerRadius = Double(baseSize / 2)
        case .roundedRectangle:
            let aspect = min(max(sourceAspect.isFinite ? sourceAspect : 16.0 / 9.0, 1.2), 1.9)
            size = CGSize(width: baseSize * aspect, height: baseSize)
            cornerRadius = Double(baseSize * 0.16)
        }

        let margin = max(CGFloat(settings.borderWidth), shortEdge * 0.012)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let centerX = min(
            max(CGFloat(settings.position.x) * canvasSize.width, halfWidth + margin),
            canvasSize.width - halfWidth - margin
        )
        let centerY = min(
            max(CGFloat(settings.position.y) * canvasSize.height, halfHeight + margin),
            canvasSize.height - halfHeight - margin
        )
        return WebcamOverlayGeometry(
            frame: CGRect(
                x: centerX - halfWidth,
                y: centerY - halfHeight,
                width: size.width,
                height: size.height
            ),
            cornerRadius: cornerRadius
        )
    }

    public static func borderWidth(
        settings: WebcamOverlaySettings,
        frame: CGRect
    ) -> CGFloat {
        min(
            CGFloat(settings.normalized.borderWidth),
            min(frame.width, frame.height) / 4
        )
    }
}

enum WebcamOverlayRenderer {
    static func image(
        _ webcam: CIImage,
        settings: WebcamOverlaySettings,
        canvasSize: CGSize,
        mirror: Bool
    ) -> CIImage? {
        let extent = webcam.extent
        guard extent.width > 1, extent.height > 1,
              let geometry = WebcamOverlayLayout.geometry(
                settings: settings,
                canvasSize: canvasSize,
                sourceAspect: Double(extent.width / extent.height)
              )
        else { return nil }

        let outerRect = ExportLayout.ciRect(
            fromTopLeft: geometry.frame,
            canvasHeight: canvasSize.height
        )
        let border = WebcamOverlayLayout.borderWidth(settings: settings, frame: outerRect)
        let contentRect = outerRect.insetBy(dx: border, dy: border)
        guard contentRect.width > 1, contentRect.height > 1 else { return nil }

        let source = webcam.transformed(by: sourceTransform(extent: extent, mirror: mirror))

        let placed = aspectFill(source, into: contentRect)
        let innerRadius = max(0, CGFloat(geometry.cornerRadius) - border)
        let contentMask = roundedMask(rect: contentRect, radius: innerRadius)
        let clipped = placed.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: contentMask]
        )

        let outerMask = roundedMask(
            rect: outerRect,
            radius: CGFloat(geometry.cornerRadius)
        )
        let borderColor = CIImage(color: CIColor.white).cropped(to: outerRect)
        let borderImage = borderColor.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: outerMask]
        )
        let bubble = clipped.composited(over: borderImage)
        guard settings.shadow else { return bubble }

        let shadowColor = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.42))
            .cropped(to: outerRect)
        let shadowShape = shadowColor.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: outerMask]
        )
        let shadowExtent = outerRect.insetBy(dx: -30, dy: -30).offsetBy(dx: 0, dy: -8)
        let transparent = CIImage(color: .clear).cropped(to: shadowExtent)
        let shadow = shadowShape
            .transformed(by: CGAffineTransform(translationX: 0, y: -8))
            .composited(over: transparent)
            .applyingGaussianBlur(sigma: 12)
            .cropped(to: shadowExtent)
        return bubble.composited(over: shadow)
    }

    static func sourceTransform(extent: CGRect, mirror: Bool) -> CGAffineTransform {
        guard mirror else { return .identity }
        return CGAffineTransform(
            a: -1,
            b: 0,
            c: 0,
            d: 1,
            tx: extent.minX + extent.maxX,
            ty: 0
        )
    }

    private static func aspectFill(_ image: CIImage, into destination: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(destination.width / extent.width, destination.height / extent.height)
        let width = extent.width * scale
        let height = extent.height * scale
        var transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(
            CGAffineTransform(
                translationX: destination.midX - width / 2,
                y: destination.midY - height / 2
            )
        )
        return image.transformed(by: transform).cropped(to: destination)
    }

    private static func roundedMask(rect: CGRect, radius: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: .white).cropped(to: rect)
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return (filter.outputImage ?? CIImage(color: .white)).cropped(to: rect)
    }
}
