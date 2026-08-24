import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Draws the keyboard overlay into the same top-left canvas coordinate system
/// used by the preview. The returned image uses Core Image's bottom-left
/// coordinate system, so it can be composited directly into an export frame.
enum KeyboardOverlayRenderer {
    static func image(
        state: KeyboardOverlayState,
        settings rawSettings: KeyboardOverlaySettings,
        canvasSize: CGSize,
        canvasPadding: Double
    ) -> CIImage? {
        guard let geometry = KeyboardOverlayLayout.geometry(
            for: state,
            settings: rawSettings,
            canvasSize: canvasSize,
            canvasPadding: canvasPadding
        ) else { return nil }

        // Rasterize only the overlay bounds rather than allocating a full
        // 1080p bitmap for every export frame.
        let width = max(Int(geometry.bounds.width.rounded(.up)), 1)
        let height = max(Int(geometry.bounds.height.rounded(.up)), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        for (key, rect) in zip(state.keys, geometry.keyRects) {
            let drawRect = CGRect(
                x: rect.minX - geometry.bounds.minX,
                y: CGFloat(height) - (rect.maxY - geometry.bounds.minY),
                width: rect.width,
                height: rect.height
            )
            let radius = min(CGFloat(geometry.cornerRadius), min(drawRect.width, drawRect.height) / 2)
            let path = CGPath(roundedRect: drawRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            context.saveGState()
            context.setAlpha(CGFloat(min(max(key.opacity, 0), 1)))
            context.setFillColor(CGColor(gray: 0.05, alpha: 0.88))
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.24))
            context.setLineWidth(max(1, geometry.fontSize * 0.055))
            context.addPath(path)
            context.strokePath()

            drawLabel(
                key.label,
                in: drawRect,
                fontSize: CGFloat(geometry.fontSize),
                context: context
            )
            context.restoreGState()
        }

        guard let cgImage = context.makeImage() else { return nil }
        let ciOrigin = CGPoint(
            x: geometry.bounds.midX - CGFloat(width) / 2,
            y: canvasSize.height - geometry.bounds.midY - CGFloat(height) / 2
        )
        return CIImage(cgImage: cgImage).transformed(
            by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y)
        )
    }

    private static func drawLabel(
        _ label: String,
        in rect: CGRect,
        fontSize: CGFloat,
        context: CGContext
    ) {
        let font = CTFontCreateWithName("SF Pro Rounded" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor.white,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: label, attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = rect.midX - width / 2
        let y = rect.midY - (ascent - descent) / 2 + descent
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
