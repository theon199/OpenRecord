import AppKit
import CoreGraphics
import Foundation

/// Resolution, padding, UV crop, and cursor mapping used by export (and preview).
///
/// Coordinates:
/// - **Top-left** pixel space matches capture (`displayBounds` origin, y down).
/// - **Core Image** space is bottom-left (y up); use `ciRect` / `ciPoint` at render time.
///
/// Canvas `padding` and `cornerRadius` are **output pixels** at the selected resolution.
/// Gradient `startPoint` / `endPoint` are canvas UV (0...1, origin top-left).
public enum ExportLayout: Sendable {
    public static let maxLongEdge = 1920
    public static let maxShortEdge = 1080
    public static let highFrameRateThreshold = 45.0

    /// Fit `aspectWidth:aspectHeight` inside the supplied edge limits using even codec-safe dimensions.
    public static func outputPixelSize(
        aspectWidth: Double,
        aspectHeight: Double,
        maxLongEdge: Int = maxLongEdge,
        maxShortEdge: Int = maxShortEdge
    ) -> (width: Int, height: Int) {
        let aw = max(aspectWidth, 1e-9)
        let ah = max(aspectHeight, 1e-9)
        let aspect = aw / ah
        let maxLong = Double(max(maxLongEdge, 2))
        let maxShort = Double(max(maxShortEdge, 2))

        var width: Double
        var height: Double
        if aspect >= 1 {
            width = maxLong
            height = width / aspect
            if height > maxShort {
                height = maxShort
                width = height * aspect
            }
        } else {
            height = maxLong
            width = height * aspect
            if width > maxShort {
                width = maxShort
                height = width / aspect
            }
        }

        return (
            evenDimension(Int(width.rounded())),
            evenDimension(Int(height.rounded()))
        )
    }

    /// Resolves a document export preset into output pixels. The source preset
    /// preserves the captured frame dimensions (rounded down to even values
    /// for codec compatibility); other presets constrain the canvas aspect.
    public static func outputPixelSize(
        aspectWidth: Double,
        aspectHeight: Double,
        resolution: ExportResolutionPreset,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (width: Int, height: Int) {
        let edges: (long: Int, short: Int)
        if resolution == .source {
            // Preserve the project's canvas aspect while keeping the captured
            // video's long/short-edge resolution. Returning the raw source
            // dimensions here would silently change portrait/square canvases
            // back to the source aspect ratio.
            edges = (
                max(max(sourceWidth, sourceHeight), 2),
                max(min(sourceWidth, sourceHeight), 2)
            )
        } else {
            edges = resolution.maxEdges ?? (maxLongEdge, maxShortEdge)
        }
        return outputPixelSize(
            aspectWidth: aspectWidth,
            aspectHeight: aspectHeight,
            maxLongEdge: edges.long,
            maxShortEdge: edges.short
        )
    }

    public static func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    /// 60 fps when the source average is high, otherwise 30.
    public static func outputFrameRate(sourceAverageFPS: Double) -> Int32 {
        sourceAverageFPS >= highFrameRateThreshold ? 60 : 30
    }

    /// Scales authored overlay measurements from their 1080p design size to
    /// the selected output canvas. Preview multiplies this by its view scale,
    /// keeping typography and annotation geometry aligned with export.
    public static func authoredContentScale(for canvasSize: CGSize) -> CGFloat {
        max(min(canvasSize.width, canvasSize.height) / 1080, 0.25)
    }

    public static func captionPadding(for canvasSize: CGSize) -> CGSize {
        let scale = authoredContentScale(for: canvasSize)
        return CGSize(width: 18 * scale, height: 12 * scale)
    }

    public static func clampedTrim(
        trimIn: TimeInterval,
        trimOut: TimeInterval?,
        duration: TimeInterval
    ) throws -> (start: TimeInterval, end: TimeInterval) {
        let duration = max(duration, 0)
        let start = min(max(trimIn, 0), duration)
        let end = min(max(trimOut ?? duration, start), duration)
        if end - start < 1e-4 {
            throw OpenRecordError.io("Nothing to export: the trim range is empty.")
        }
        return (start, end)
    }

    /// Map a source audio track onto an exported video interval. The track's
    /// offset is relative to the first display frame; a positive offset creates
    /// leading silence and a negative offset trims early audio.
    public static func audioPlacement(
        trackOffset: TimeInterval,
        trimStart: TimeInterval,
        exportDuration: TimeInterval,
        sourceDuration: TimeInterval
    ) -> ExportAudioPlacement? {
        guard trackOffset.isFinite, trimStart.isFinite, exportDuration > 0,
              sourceDuration > 0
        else { return nil }
        let sourceStart = max(0, trimStart - trackOffset)
        let sourceEnd = min(
            sourceDuration,
            max(0, trimStart + exportDuration - trackOffset)
        )
        guard sourceStart < sourceDuration, sourceEnd > sourceStart else { return nil }
        return ExportAudioPlacement(
            sourceStart: sourceStart,
            duration: sourceEnd - sourceStart,
            destinationStart: max(0, trackOffset - trimStart)
        )
    }

    /// UV crop (origin top-left) → source pixel rect (origin top-left).
    public static func pixelRect(
        fromUV uv: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let w = CGFloat(max(sourceWidth, 1))
        let h = CGFloat(max(sourceHeight, 1))
        return CGRect(
            x: uv.origin.x * w,
            y: uv.origin.y * h,
            width: max(uv.size.width * w, 0),
            height: max(uv.size.height * h, 0)
        )
    }

    /// UV crop (origin top-left) → Core Image pixel rect (origin bottom-left).
    public static func ciRect(
        fromUV uv: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        ciRect(
            fromTopLeft: pixelRect(fromUV: uv, sourceWidth: sourceWidth, sourceHeight: sourceHeight),
            canvasHeight: CGFloat(max(sourceHeight, 1))
        )
    }

    public static func ciRect(fromTopLeft rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: canvasHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func ciPoint(fromTopLeft point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: canvasHeight - point.y)
    }

    public static func paddedContentRect(canvas: CGSize, padding: Double) -> CGRect {
        let maxPad = max(0, min(canvas.width, canvas.height) / 2 - 1)
        let pad = CGFloat(min(max(0, padding), maxPad))
        return CGRect(
            x: pad,
            y: pad,
            width: max(canvas.width - 2 * pad, 1),
            height: max(canvas.height - 2 * pad, 1)
        )
    }

    public static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(
            x: rect.midX - w / 2,
            y: rect.midY - h / 2,
            width: w,
            height: h
        )
    }

    /// Where the cropped source is drawn on the output canvas (top-left origin).
    public static func videoRect(
        canvasSize: CGSize,
        padding: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        cropUV: CGRect
    ) -> CGRect {
        let content = paddedContentRect(canvas: canvasSize, padding: padding)
        let crop = pixelRect(fromUV: cropUV, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let fitted = aspectFit(
            CGSize(width: max(crop.width, 1), height: max(crop.height, 1)),
            in: content
        )
        return fitted
    }

    public static func canvasLayout(
        canvas: CanvasSettings,
        sourceWidth: Int,
        sourceHeight: Int,
        cropUV: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        resolution: ExportResolutionPreset = .p1080
    ) -> ExportCanvasLayout {
        let size = outputPixelSize(
            aspectWidth: canvas.aspectWidth,
            aspectHeight: canvas.aspectHeight,
            resolution: resolution,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let canvasSize = CGSize(width: size.width, height: size.height)
        let video = videoRect(
            canvasSize: canvasSize,
            padding: canvas.padding,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cropUV: cropUV
        )
        let radius = min(
            max(0, canvas.cornerRadius),
            Double(video.width) / 2,
            Double(video.height) / 2
        )
        return ExportCanvasLayout(
            width: size.width,
            height: size.height,
            videoRect: video,
            cornerRadius: radius,
            padding: canvas.padding
        )
    }

    /// Map a source UV point through the crop onto the canvas video rect (top-left).
    public static func mapSourceUVToCanvas(
        _ uv: Point2D,
        cropUV: CGRect,
        videoRect: CGRect
    ) -> CGPoint {
        let w = max(cropUV.width, 1e-12)
        let h = max(cropUV.height, 1e-12)
        let lx = (uv.x - cropUV.origin.x) / w
        let ly = (uv.y - cropUV.origin.y) / h
        return CGPoint(
            x: videoRect.origin.x + lx * videoRect.width,
            y: videoRect.origin.y + ly * videoRect.height
        )
    }

    /// Map a point in the canvas video rect back into source UV space.
    ///
    /// This is the inverse of `mapSourceUVToCanvas` and is shared by preview
    /// editing gestures so their coordinates match export exactly.
    public static func mapCanvasPointToSourceUV(
        _ point: CGPoint,
        cropUV: CGRect,
        videoRect: CGRect,
        clampToSource: Bool = true
    ) -> Point2D {
        let width = max(abs(videoRect.width), 1e-12)
        let height = max(abs(videoRect.height), 1e-12)
        let localX = (point.x - videoRect.origin.x) / width
        let localY = (point.y - videoRect.origin.y) / height
        var x = cropUV.origin.x + localX * cropUV.width
        var y = cropUV.origin.y + localY * cropUV.height
        if clampToSource {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        return Point2D(x: x, y: y)
    }

    /// Primary-button down flag and, when down, seconds since that press.
    ///
    /// `clicks` may be the full telemetry list or a primary-button-only index;
    /// non-primary events are skipped. Lookup is a binary search plus a short
    /// reverse walk, so preview/export do not rescan the whole array.
    public static func primaryClickState(
        at time: TimeInterval,
        clicks: [ClickSample]
    ) -> (isDown: Bool, age: TimeInterval?) {
        guard let click = lastPrimaryClick(at: time, clicks: clicks) else {
            return (false, nil)
        }
        if click.down {
            return (true, max(0, time - click.t))
        }
        return (false, nil)
    }

    /// Seconds since the primary button went down, if it is still down at `time`.
    public static func primaryClickAge(
        at time: TimeInterval,
        clicks: [ClickSample]
    ) -> TimeInterval? {
        primaryClickState(at: time, clicks: clicks).age
    }

    /// Bitmap pixel size used to place a captured cursor sprite. Walks
    /// `NSImage.representations` once; callers should cache the result.
    public static func cursorPixelSize(for image: NSImage) -> Size2D {
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh }
        return Size2D(
            width: Double(max(bitmap?.pixelsWide ?? Int(image.size.width), 1)),
            height: Double(max(bitmap?.pixelsHigh ?? Int(image.size.height), 1))
        )
    }

    private static func lastPrimaryClick(
        at time: TimeInterval,
        clicks: [ClickSample]
    ) -> ClickSample? {
        guard !clicks.isEmpty else { return nil }
        var lo = 0
        var hi = clicks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clicks[mid].t <= time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var index = lo - 1
        while index >= 0 {
            let click = clicks[index]
            if click.button == .left || click.button == .other {
                return click
            }
            index -= 1
        }
        return nil
    }

    public static func clickRipple(
        age: TimeInterval,
        canvasPixelsPerPoint: Double,
        cursorScale: Double
    ) -> ExportClickRipple {
        let t = min(1, max(0, age / 0.35))
        let eased = 1 - (1 - t) * (1 - t)
        let base = 16 * max(cursorScale, 0.1) * max(canvasPixelsPerPoint, 0.25)
        return ExportClickRipple(
            radius: base * (1.15 + 1.7 * eased),
            opacity: 0.42 * (1 - 0.6 * eased)
        )
    }

    public static func canvasPixelsPerPoint(
        displayScale: Double,
        sourceWidth: Int,
        cropUV: CGRect,
        videoRect: CGRect
    ) -> Double {
        let cropWidth = max(cropUV.width * Double(max(sourceWidth, 1)), 1e-9)
        return max(displayScale, 0.25) * Double(videoRect.width) / cropWidth
    }
}

public struct ExportCanvasLayout: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var videoRect: CGRect
    public var cornerRadius: Double
    public var padding: Double

    public init(
        width: Int,
        height: Int,
        videoRect: CGRect,
        cornerRadius: Double,
        padding: Double
    ) {
        self.width = width
        self.height = height
        self.videoRect = videoRect
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public var size: CGSize {
        CGSize(width: width, height: height)
    }
}

public struct ExportClickRipple: Equatable, Sendable {
    public var radius: Double
    public var opacity: Double

    public init(radius: Double, opacity: Double) {
        self.radius = radius
        self.opacity = opacity
    }
}

public struct ExportAudioPlacement: Equatable, Sendable {
    public var sourceStart: TimeInterval
    public var duration: TimeInterval
    public var destinationStart: TimeInterval

    public init(
        sourceStart: TimeInterval,
        duration: TimeInterval,
        destinationStart: TimeInterval
    ) {
        self.sourceStart = sourceStart
        self.duration = duration
        self.destinationStart = destinationStart
    }
}
