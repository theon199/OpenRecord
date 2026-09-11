import CoreGraphics
import Foundation

/// One on-screen window in front-to-back z-order, used to decide whether the
/// pointer is actually over the captured window or a different window that
/// happens to overlap its bounds.
public struct CaptureWindowSnapshot: Sendable, Hashable {
    public var id: UInt32
    public var bounds: Rect2D
    public var alpha: Double
    public var layer: Int
    public var onScreen: Bool

    public init(
        id: UInt32,
        bounds: Rect2D,
        alpha: Double = 1,
        layer: Int = 0,
        onScreen: Bool = true
    ) {
        self.id = id
        self.bounds = bounds
        self.alpha = alpha
        self.layer = layer
        self.onScreen = onScreen
    }
}

public enum CaptureWindowList: Sendable {
    /// Parses `CGWindowListCopyWindowInfo` dictionaries. The array is already
    /// front-to-back in CoreGraphics' on-screen listing order.
    public static func snapshots(from info: [[CFString: Any]]?) -> [CaptureWindowSnapshot] {
        guard let info else { return [] }
        var snapshots: [CaptureWindowSnapshot] = []
        snapshots.reserveCapacity(info.count)
        for entry in info {
            guard let id = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value else { continue }
            let onScreen = (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            let alpha = (entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1
            let layer = (entry[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            var bounds = CGRect.zero
            if let rawBounds = entry[kCGWindowBounds] {
                _ = CGRectMakeWithDictionaryRepresentation(rawBounds as! CFDictionary, &bounds)
            }
            snapshots.append(
                CaptureWindowSnapshot(
                    id: id,
                    bounds: Rect2D(bounds),
                    alpha: alpha,
                    layer: layer,
                    onScreen: onScreen
                )
            )
        }
        return snapshots
    }
}

/// Capture-time rule for whether cursor telemetry (and therefore auto-zoom)
/// should treat the pointer as on the selected target.
public enum CapturePointerPolicy: Sendable {
    public static func isVisible(
        location: CGPoint,
        target: CaptureTarget?,
        bounds: CGRect?,
        available: Bool,
        windowsFrontToBack: [CaptureWindowSnapshot]
    ) -> Bool {
        guard let target else { return true }
        switch target {
        case .display:
            return available && contains(location, in: bounds)
        case .window(let windowID):
            guard available, contains(location, in: bounds) else { return false }
            guard let hit = hitWindow(at: location, windowsFrontToBack: windowsFrontToBack) else {
                return true
            }
            return hit.id == windowID
        }
    }

    public static func hitWindow(
        at location: CGPoint,
        windowsFrontToBack: [CaptureWindowSnapshot]
    ) -> CaptureWindowSnapshot? {
        windowsFrontToBack.first { window in
            window.onScreen
                && window.layer >= 0
                && window.alpha > 0.05
                && window.bounds.width > 1
                && window.bounds.height > 1
                && contains(location, in: window.bounds.cgRect)
        }
    }

    public static func contains(_ location: CGPoint, in bounds: CGRect?) -> Bool {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return false }
        return location.x >= bounds.minX
            && location.x <= bounds.maxX
            && location.y >= bounds.minY
            && location.y <= bounds.maxY
    }
}
