import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreText
import Foundation

/// Core Image compositor: background, media, cursor/keyboard, captions, and annotations.
final class ExportCompositor {
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let canvas: CanvasSettings
    private let keyboardOverlay: KeyboardOverlaySettings
    private let webcamOverlay: WebcamOverlaySettings
    private let webcamMirror: Bool
    private let layout: ExportCanvasLayout
    private let canvasExtent: CGRect
    private let background: CIImage
    private let cursorImage: CIImage?
    private let cursorSprite: CursorSprite?
    private let cursorTreatmentEvaluator: CursorTreatmentEvaluator
    private let displayScale: Double
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let captions: [CaptionCue]
    private let annotations: [Annotation]
    /// Authored overlays are unchanged between their timeline boundaries.
    /// Reusing their raster avoids allocating and drawing a full-canvas
    /// CGContext for every output frame in a caption or annotation range.
    private var authoredOverlayCacheKey: AuthoredOverlayCacheKey?
    private var authoredOverlayCache: CIImage?
    /// Keyboard pills are also static during their hold interval. Fade frames
    /// naturally miss this cache because opacity is part of the state key.
    private var keyboardOverlayCacheKey: KeyboardOverlayState?
    private var keyboardOverlayCache: CIImage?

    private struct AuthoredOverlayCacheKey: Hashable {
        var captions: [CaptionCue]
        var annotations: [Annotation]
    }

    init(
        context: CIContext,
        colorSpace: CGColorSpace,
        canvas: CanvasSettings,
        keyboardOverlay: KeyboardOverlaySettings,
        webcamOverlay: WebcamOverlaySettings,
        webcamMirror: Bool,
        layout: ExportCanvasLayout,
        sourceWidth: Int,
        sourceHeight: Int,
        displayScale: Double,
        cursorImage: CIImage?,
        cursorSprite: CursorSprite?,
        cursorEffects: [CursorEffectRange] = [],
        captions: [CaptionCue] = [],
        annotations: [Annotation] = []
    ) {
        self.context = context
        self.colorSpace = colorSpace
        self.canvas = canvas
        self.keyboardOverlay = keyboardOverlay
        self.webcamOverlay = webcamOverlay
        self.webcamMirror = webcamMirror
        self.layout = layout
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.displayScale = displayScale
        self.cursorImage = cursorImage
        self.cursorSprite = cursorSprite
        self.cursorTreatmentEvaluator = CursorTreatmentEvaluator(ranges: cursorEffects)
        self.captions = captions.map(\.normalized)
        self.annotations = annotations.map(\.normalized)
        self.canvasExtent = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        self.background = Self.makeBackground(canvas: canvas, extent: canvasExtent)
    }

    func render(
        source: CIImage,
        webcam: CIImage?,
        cropUV: CGRect,
        cursorUV: Point2D?,
        cursorVelocity: Point2D?,
        clicking: Bool,
        clickAge: TimeInterval?,
        keyboardState: KeyboardOverlayState,
        sourceTime: TimeInterval = 0,
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

        if let webcam,
           let overlay = WebcamOverlayRenderer.image(
            webcam,
            settings: webcamOverlay,
            canvasSize: layout.size,
            mirror: webcamMirror
           )
        {
            output = overlay.composited(over: output)
        }

        let cursorTreatment = cursorTreatmentEvaluator.state(
            at: sourceTime,
            baseScale: canvas.cursorScale,
            baseClickEmphasis: canvas.cursorClickEmphasis,
            baseHalo: canvas.cursorHalo
        )
        if cursorTreatment.visible, let cursorUV {
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
            let motionBlur = CursorMotionBlurEffect.state(
                velocity: cursorVelocity,
                canvasSize: layout.size,
                settings: canvas.cursorMotionBlur
            )
            if clicking, cursorTreatment.clickEmphasis, let clickAge {
                let ripple = ExportLayout.clickRipple(
                    age: clickAge,
                    canvasPixelsPerPoint: pxPerPoint,
                    cursorScale: cursorTreatment.scale
                )
                output = makeRipple(at: hotspot, ripple: ripple).composited(over: output)
            }
            if cursorTreatment.halo {
                output = makeHalo(
                    at: hotspot,
                    pixelsPerPoint: pxPerPoint,
                    cursorScale: cursorTreatment.scale
                ).composited(over: output)
            }
            if let cursor = makeCursor(
                hotspot: hotspot,
                pixelsPerPoint: pxPerPoint,
                motionBlur: motionBlur,
                cursorScale: cursorTreatment.scale
            ) {
                output = cursor.composited(over: output)
            }
        }

        if let keyboard = cachedKeyboardOverlay(for: keyboardState) {
            output = keyboard.composited(over: output)
        }

        // Captions and annotations intentionally sit above keyboard overlays so
        // authored content is legible in both preview and every export format.
        if let authored = authoredOverlay(at: sourceTime, canvasSize: layout.size) {
            output = authored.composited(over: output)
        }

        context.render(
            output.cropped(to: canvasExtent),
            to: pixelBuffer,
            bounds: canvasExtent,
            colorSpace: colorSpace
        )
    }

    private func authoredOverlay(at time: TimeInterval, canvasSize: CGSize) -> CIImage? {
        let activeCaptions = captions.filter { $0.isActive(at: time) }
        let activeAnnotations = annotations.filter { $0.isActive(at: time) }
        let cacheKey = AuthoredOverlayCacheKey(
            captions: activeCaptions,
            annotations: activeAnnotations
        )
        if cacheKey == authoredOverlayCacheKey {
            return authoredOverlayCache
        }
        authoredOverlayCacheKey = cacheKey
        guard !activeCaptions.isEmpty || !activeAnnotations.isEmpty else {
            authoredOverlayCache = nil
            return nil
        }

        let width = max(Int(canvasSize.width.rounded()), 2)
        let height = max(Int(canvasSize.height.rounded()), 2)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext uses a bottom-left origin. The authored model remains
        // top-left, so draw helpers convert coordinates at the edge.
        for caption in activeCaptions {
            draw(caption, in: context, canvasSize: canvasSize)
        }
        for annotation in activeAnnotations {
            draw(annotation, in: context, canvasSize: canvasSize)
        }
        guard let image = context.makeImage() else {
            authoredOverlayCache = nil
            return nil
        }
        let rendered = CIImage(cgImage: image)
        authoredOverlayCache = rendered
        return rendered
    }

    private func cachedKeyboardOverlay(for state: KeyboardOverlayState) -> CIImage? {
        if state == keyboardOverlayCacheKey {
            return keyboardOverlayCache
        }
        keyboardOverlayCacheKey = state
        let image = KeyboardOverlayRenderer.image(
            state: state,
            settings: keyboardOverlay,
            canvasSize: layout.size,
            canvasPadding: canvas.padding
        )
        keyboardOverlayCache = image
        return image
    }

    private func draw(_ caption: CaptionCue, in context: CGContext, canvasSize: CGSize) {
        let style = caption.style.normalized
        let maxWidth = CGFloat(style.maxWidth) * canvasSize.width
        let scale = ExportLayout.authoredContentScale(for: canvasSize)
        let fontSize = CGFloat(style.fontSize) * scale
        let padding = ExportLayout.captionPadding(for: canvasSize)
        let textMaxWidth = max(maxWidth - padding.width * 2, 1)
        let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cgColor(style.foreground),
        ]
        let attributed = NSAttributedString(string: caption.text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: textMaxWidth, height: canvasSize.height),
            nil
        )
        let horizontalPadding = padding.width
        let verticalPadding = padding.height
        let width = min(maxWidth, max(size.width + horizontalPadding * 2, 40 * scale))
        let height = max(size.height + verticalPadding * 2, fontSize + verticalPadding * 2)
        let x = (canvasSize.width - width) / 2
        let anchorY = CGFloat(style.position.defaultAnchor.y) * canvasSize.height
        let top = min(max(anchorY - height / 2, 0), max(canvasSize.height - height, 0))
        let rect = CGRect(x: x, y: canvasSize.height - top - height, width: width, height: height)
        context.setFillColor(cgColor(style.background))
        let radius = min(16 * scale, height / 3)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let path = CGPath(
            rect: rect.insetBy(dx: horizontalPadding, dy: verticalPadding),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
    }

    private func draw(_ annotation: Annotation, in context: CGContext, canvasSize: CGSize) {
        let value = annotation.normalized
        let scale = ExportLayout.authoredContentScale(for: canvasSize)
        context.setStrokeColor(cgColor(value.color))
        context.setFillColor(cgColor(value.background))
        context.setLineWidth(max(2 * scale, CGFloat(value.fontSize) * scale / 18))
        switch value.kind {
        case .arrow:
            let start = CGPoint(x: value.position.x * canvasSize.width, y: (1 - value.position.y) * canvasSize.height)
            let end = CGPoint(x: value.endPosition.x * canvasSize.width, y: (1 - value.endPosition.y) * canvasSize.height)
            context.move(to: start); context.addLine(to: end); context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(12 * scale, CGFloat(value.fontSize) * scale * 0.55)
            let left = CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6))
            let right = CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6))
            context.move(to: end); context.addLine(to: left); context.move(to: end); context.addLine(to: right); context.strokePath()
        case .spotlight:
            let r = CGRect(x: value.rect.x * canvasSize.width, y: (1 - value.rect.y - value.rect.height) * canvasSize.height, width: value.rect.width * canvasSize.width, height: value.rect.height * canvasSize.height)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: value.dimAmount))
            let dimPath = CGMutablePath()
            dimPath.addRect(CGRect(origin: .zero, size: canvasSize))
            dimPath.addRoundedRect(
                in: r,
                cornerWidth: 12 * scale,
                cornerHeight: 12 * scale
            )
            context.addPath(dimPath)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(cgColor(value.color))
            context.addPath(
                CGPath(
                    roundedRect: r,
                    cornerWidth: 12 * scale,
                    cornerHeight: 12 * scale,
                    transform: nil
                )
            )
            context.strokePath()
        case .text:
            let fontSize = CGFloat(value.fontSize) * scale
            let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cgColor(value.color)]
            let text = NSAttributedString(string: value.text, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let maxWidth = canvasSize.width * 0.7
            let horizontalPadding = 16 * scale
            let verticalPadding = 12 * scale
            let textMaxWidth = max(maxWidth - horizontalPadding * 2, 1)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: text.length),
                nil,
                CGSize(width: textMaxWidth, height: canvasSize.height),
                nil
            )
            let width = min(maxWidth, size.width + horizontalPadding * 2)
            let height = size.height + verticalPadding * 2
            let centerX = value.position.x * canvasSize.width
            let centerY = value.position.y * canvasSize.height
            let top = min(max(centerY - height / 2, 0), max(canvasSize.height - height, 0))
            let left = min(max(centerX - width / 2, 0), max(canvasSize.width - width, 0))
            let rect = CGRect(
                x: left,
                y: canvasSize.height - top - height,
                width: width,
                height: height
            )
            let radius = 12 * scale
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            let path = CGPath(
                rect: rect.insetBy(dx: horizontalPadding, dy: verticalPadding),
                transform: nil
            )
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil), context)
        }
    }

    private func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
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

    private func makeCursor(
        hotspot: CGPoint,
        pixelsPerPoint: Double,
        motionBlur: CursorMotionBlurState,
        cursorScale: Double
    ) -> CIImage? {
        guard let cursorImage, let sprite = cursorSprite else { return nil }
        let extent = cursorImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let placement = CursorSpriteLayout.placement(
            sprite: sprite,
            imagePixelSize: Size2D(width: extent.width, height: extent.height),
            cursorScale: cursorScale,
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
        let placed = cursorImage.transformed(by: transform)
        return CursorMotionBlurRenderer.image(placed, state: motionBlur)
    }

    private func makeHalo(
        at hotspot: CGPoint,
        pixelsPerPoint: Double,
        cursorScale: Double
    ) -> CIImage {
        let center = ExportLayout.ciPoint(fromTopLeft: hotspot, canvasHeight: canvasExtent.height)
        let outerRadius = CGFloat(max(17 * cursorScale * pixelsPerPoint, 1))
        let innerRadius = outerRadius * 0.86
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = Float(innerRadius)
        filter.radius1 = Float(outerRadius)
        filter.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.42)
        let pad = outerRadius + 2
        return (filter.outputImage ?? CIImage.empty()).cropped(
            to: CGRect(
                x: center.x - pad,
                y: center.y - pad,
                width: pad * 2,
                height: pad * 2
            )
        )
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
