import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

/// Core Image compositor: background + padded rounded source + cursor + click ripple.
final class ExportCompositor {
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let canvas: CanvasSettings
    private let layout: ExportCanvasLayout
    private let canvasExtent: CGRect
    private let background: CIImage
    private let cursorImage: CIImage?
    private let cursorSprite: CursorSprite?
    private let displayScale: Double
    private let sourceWidth: Int
    private let sourceHeight: Int

    init(
        context: CIContext,
        colorSpace: CGColorSpace,
        canvas: CanvasSettings,
        layout: ExportCanvasLayout,
        sourceWidth: Int,
        sourceHeight: Int,
        displayScale: Double,
        cursorImage: CIImage?,
        cursorSprite: CursorSprite?
    ) {
        self.context = context
        self.colorSpace = colorSpace
        self.canvas = canvas
        self.layout = layout
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.displayScale = displayScale
        self.cursorImage = cursorImage
        self.cursorSprite = cursorSprite
        self.canvasExtent = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        self.background = Self.makeBackground(canvas: canvas, extent: canvasExtent)
    }

    func render(
        source: CIImage,
        cropUV: CGRect,
        cursorUV: Point2D?,
        clicking: Bool,
        clickAge: TimeInterval?,
        into pixelBuffer: CVPixelBuffer
    ) {
        let videoRect = ExportLayout.videoRect(
            canvasSize: layout.size,
            padding: canvas.padding,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropUV: cropUV
        )
        let radius = min(
            layout.cornerRadius,
            Double(videoRect.width) / 2,
            Double(videoRect.height) / 2
        )

        let placed = placeSource(source, cropUV: cropUV, videoRect: videoRect)
        let masked = roundCorners(placed, videoRect: videoRect, radius: radius)
        var output = masked.composited(over: background)

        if let cursorUV {
            let hotspot = ExportLayout.mapSourceUVToCanvas(
                cursorUV,
                cropUV: cropUV,
                videoRect: videoRect
            )
            let pxPerPoint = ExportLayout.canvasPixelsPerPoint(
                displayScale: displayScale,
                sourceWidth: sourceWidth,
                cropUV: cropUV,
                videoRect: videoRect
            )
            if clicking, let clickAge {
                let ripple = ExportLayout.clickRipple(
                    age: clickAge,
                    canvasPixelsPerPoint: pxPerPoint,
                    cursorScale: canvas.cursorScale
                )
                output = makeRipple(at: hotspot, ripple: ripple).composited(over: output)
            }
            if let cursor = makeCursor(hotspot: hotspot, pixelsPerPoint: pxPerPoint) {
                output = cursor.composited(over: output)
            }
        }

        context.render(
            output.cropped(to: canvasExtent),
            to: pixelBuffer,
            bounds: canvasExtent,
            colorSpace: colorSpace
        )
    }

    private func placeSource(_ source: CIImage, cropUV: CGRect, videoRect: CGRect) -> CIImage {
        let srcCrop = ExportLayout.ciRect(
            fromUV: cropUV,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let dest = ExportLayout.ciRect(fromTopLeft: videoRect, canvasHeight: canvasExtent.height)
        guard srcCrop.width >= 1, srcCrop.height >= 1, dest.width >= 1, dest.height >= 1 else {
            return source.cropped(to: source.extent)
        }

        var transform = CGAffineTransform(translationX: -srcCrop.minX, y: -srcCrop.minY)
        transform = transform.concatenating(
            CGAffineTransform(scaleX: dest.width / srcCrop.width, y: dest.height / srcCrop.height)
        )
        transform = transform.concatenating(
            CGAffineTransform(translationX: dest.minX, y: dest.minY)
        )
        return source.cropped(to: srcCrop).transformed(by: transform)
    }

    private func roundCorners(_ video: CIImage, videoRect: CGRect, radius: Double) -> CIImage {
        let dest = ExportLayout.ciRect(fromTopLeft: videoRect, canvasHeight: canvasExtent.height)
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return video.cropped(to: dest)
        }
        filter.setValue(CIVector(cgRect: dest), forKey: "inputExtent")
        filter.setValue(max(0, radius), forKey: "inputRadius")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
        guard let mask = filter.outputImage else { return video }
        return video.applyingFilter(
            "CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: mask]
        )
    }

    private func makeCursor(hotspot: CGPoint, pixelsPerPoint: Double) -> CIImage? {
        guard let cursorImage, let sprite = cursorSprite else { return nil }
        let extent = cursorImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let placement = CursorSpriteLayout.placement(
            sprite: sprite,
            imagePixelSize: Size2D(width: extent.width, height: extent.height),
            cursorScale: canvas.cursorScale,
            pixelsPerPoint: pixelsPerPoint
        )
        let drawWidth = placement.drawSize.width
        let drawHeight = placement.drawSize.height
        let topLeft = CGPoint(
            x: hotspot.x - placement.hotspot.x,
            y: hotspot.y - placement.hotspot.y
        )

        var transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        transform = transform.concatenating(
            CGAffineTransform(scaleX: drawWidth / extent.width, y: drawHeight / extent.height)
        )
        let ciOrigin = ExportLayout.ciRect(
            fromTopLeft: CGRect(origin: topLeft, size: CGSize(width: drawWidth, height: drawHeight)),
            canvasHeight: canvasExtent.height
        ).origin
        transform = transform.concatenating(
            CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y)
        )
        return cursorImage.transformed(by: transform)
    }

    private func makeRipple(at hotspot: CGPoint, ripple: ExportClickRipple) -> CIImage {
        let center = ExportLayout.ciPoint(fromTopLeft: hotspot, canvasHeight: canvasExtent.height)
        let radius = CGFloat(max(ripple.radius, 1))
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(radius * 0.72)
        filter.radius1 = Float(radius)
        filter.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(ripple.opacity))
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let pad = radius + 2
        return (filter.outputImage ?? CIImage.empty()).cropped(
            to: CGRect(x: center.x - pad, y: center.y - pad, width: pad * 2, height: pad * 2)
        )
    }

    private static func makeBackground(canvas: CanvasSettings, extent: CGRect) -> CIImage {
        switch canvas.background {
        case .solid(let color):
            return CIImage(color: ciColor(color)).cropped(to: extent)
        case .linearGradient(let start, let end, let startPoint, let endPoint):
            var p0 = startPoint
            var p1 = endPoint
            if abs(p0.x - p1.x) < 1e-9, abs(p0.y - p1.y) < 1e-9 {
                p0 = Point2D(x: 0.5, y: 0)
                p1 = Point2D(x: 0.5, y: 1)
            }
            let filter = CIFilter.linearGradient()
            filter.point0 = ExportLayout.ciPoint(
                fromTopLeft: CGPoint(x: p0.x * extent.width, y: p0.y * extent.height),
                canvasHeight: extent.height
            )
            filter.point1 = ExportLayout.ciPoint(
                fromTopLeft: CGPoint(x: p1.x * extent.width, y: p1.y * extent.height),
                canvasHeight: extent.height
            )
            filter.color0 = ciColor(start)
            filter.color1 = ciColor(end)
            return (filter.outputImage ?? CIImage(color: ciColor(start))).cropped(to: extent)
        }
    }

    private static func ciColor(_ color: RGBAColor) -> CIColor {
        CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
    }
}

enum ExportCursorImage {
    static func load(
        document: ProjectDocument,
        bundleURL: URL
    ) -> (sprite: CursorSprite, image: CIImage)? {
        var candidates = document.cursorSprites
        if candidates.isEmpty {
            candidates = [
                CursorSprite(
                    id: CaptureMediaFormat.defaultCursorSpriteID,
                    hotspot: Point2D(x: 1.5, y: 1.5),
                    pngRelativePath:
                        "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(CaptureMediaFormat.defaultCursorSpriteID).png",
                    standardSize: Size2D(width: 32, height: 32)
                )
            ]
        }

        let ordered = candidates.sorted { lhs, rhs in
            if lhs.id == CaptureMediaFormat.defaultCursorSpriteID { return true }
            if rhs.id == CaptureMediaFormat.defaultCursorSpriteID { return false }
            return lhs.id < rhs.id
        }

        for sprite in ordered {
            guard let url = ProjectAssetResolver.cursorPNG(
                relativePath: sprite.pngRelativePath,
                in: bundleURL
            ) else { continue }
            if let image = CIImage(contentsOf: url) {
                return (sprite, image)
            }
        }
        return nil
    }
}
