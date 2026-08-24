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
        let border = min(
            CGFloat(settings.normalized.borderWidth),
            min(outerRect.width, outerRect.height) / 4
        )
        let contentRect = outerRect.insetBy(dx: border, dy: border)
        guard contentRect.width > 1, contentRect.height > 1 else { return nil }

        let source: CIImage
        if mirror {
            source = webcam.transformed(
                by: CGAffineTransform(
                    a: -1,
                    b: 0,
                    c: 0,
                    d: 1,
                    tx: extent.minX + extent.maxX,
                    ty: 0
                )
            )
        } else {
            source = webcam
        }

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
