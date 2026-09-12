import CoreGraphics
import Foundation

/// Screen-point geometry for the live recording webcam bubble.
///
/// AppKit window frames use a bottom-left origin. `WebcamOverlaySettings`
/// stores a top-left normalized canvas center, so Y is flipped when mapping
/// a HUD camera frame onto a captured display.
public enum RecordingHUDLayout: Sendable {
    public static let pillWidth: CGFloat = 228
    public static let pillHeight: CGFloat = 40
    public static let controlSpacing: CGFloat = 8
    public static let windowPadding: CGFloat = 14
    public static let resizeHandleSize: CGFloat = 14
    public static let minimumCameraDiameter: CGFloat = 72

    public static func cameraFrame(center: CGPoint, diameter: CGFloat) -> CGRect {
        let size = max(diameter, 1)
        return CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
    }

    public static func allowedDiameterRange(displayBounds: CGRect) -> ClosedRange<CGFloat> {
        let w = displayBounds.width.isFinite ? max(displayBounds.width, 1) : 1
        let h = displayBounds.height.isFinite ? max(displayBounds.height, 1) : 1
        let shortEdge = min(w, h)
        let minimum = max(
            minimumCameraDiameter,
            shortEdge * CGFloat(WebcamOverlaySettings.sizeRange.lowerBound)
        )
        let maximum = max(
            minimum,
            shortEdge * CGFloat(WebcamOverlaySettings.sizeRange.upperBound)
        )
        return minimum...maximum
    }

    public static func defaultCameraFrame(displayBounds: CGRect) -> CGRect {
        cameraFrame(
            settings: WebcamOverlaySettings(
                enabled: true,
                position: WebcamOverlaySettings.defaultPosition,
                size: WebcamOverlaySettings.defaultSize
            ),
            displayBounds: displayBounds
        )
    }

    /// Circle in AppKit global points from document overlay settings.
    public static func cameraFrame(
        settings: WebcamOverlaySettings,
        displayBounds: CGRect
    ) -> CGRect {
        let bounds = displayBounds
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let shortEdge = min(width, height)
        let normalized = settings.normalized
        let diameter = CGFloat(normalized.size) * shortEdge
        let center = CGPoint(
            x: bounds.minX + CGFloat(normalized.position.x) * width,
            y: bounds.maxY - CGFloat(normalized.position.y) * height
        )
        return cameraFrame(center: center, diameter: diameter)
    }

    /// Maps a live camera circle onto `WebcamOverlaySettings` for the captured
    /// display so editor PiP matches what the presenter framed.
    public static func overlaySettings(
        cameraFrame: CGRect,
        displayBounds: CGRect,
        existing: WebcamOverlaySettings
    ) -> WebcamOverlaySettings {
        let bounds = displayBounds
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let shortEdge = min(width, height)
        var settings = existing
        settings.enabled = true
        settings.shape = .circle
        settings.position = Point2D(
            x: Double((cameraFrame.midX - bounds.minX) / width),
            y: Double((bounds.maxY - cameraFrame.midY) / height)
        )
        settings.size = Double(cameraFrame.width / shortEdge)
        return settings.normalized
    }

    public static func clampCameraFrame(_ frame: CGRect, to displayBounds: CGRect) -> CGRect {
        let range = allowedDiameterRange(displayBounds: displayBounds)
        let diameter = min(max(frame.width, range.lowerBound), range.upperBound)
        let half = diameter / 2
        let shortEdge = min(displayBounds.width, displayBounds.height)
        let margin = max(4, shortEdge * 0.012)
        let minX = displayBounds.minX + half + margin
        let maxX = displayBounds.maxX - half - margin
        let minY = displayBounds.minY + half + margin
        let maxY = displayBounds.maxY - half - margin
        let clampedMinX = min(minX, maxX)
        let clampedMaxX = max(minX, maxX)
        let clampedMinY = min(minY, maxY)
        let clampedMaxY = max(minY, maxY)
        let centerX = min(max(frame.midX, clampedMinX), clampedMaxX)
        let centerY = min(max(frame.midY, clampedMinY), clampedMaxY)
        return cameraFrame(
            center: CGPoint(x: centerX, y: centerY),
            diameter: diameter
        )
    }

    public static func windowFrame(
        cameraFrame: CGRect,
        showsCamera: Bool,
        collapsed: Bool
    ) -> CGRect {
        let padding = windowPadding
        let pill = CGSize(width: pillWidth, height: pillHeight)
        if !showsCamera || collapsed {
            let width = pill.width + 2 * padding
            let height = pill.height + 2 * padding
            return CGRect(
                x: cameraFrame.midX - width / 2,
                y: cameraFrame.midY - height / 2,
                width: width,
                height: height
            )
        }

        let diameter = cameraFrame.width
        let contentWidth = max(diameter, pill.width)
        let width = contentWidth + 2 * padding
        let height = diameter + controlSpacing + pill.height + 2 * padding
        return CGRect(
            x: cameraFrame.midX - width / 2,
            y: cameraFrame.minY - controlSpacing - pill.height - padding,
            width: width,
            height: height
        )
    }
}
