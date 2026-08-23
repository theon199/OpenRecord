import Foundation

/// One cursor-path sample. Written as a single JSONL line in `recording/mouse.jsonl`.
/// Coordinates are in **points** (not pixels). `t` is seconds from recording start.
public struct CursorSample: Codable, Sendable, Hashable {
    public var t: TimeInterval
    public var x: Double
    public var y: Double
    public var cursorId: String?
    /// `nil` is interpreted as visible for v1 projects.
    public var visible: Bool?

    public init(
        t: TimeInterval,
        x: Double,
        y: Double,
        cursorId: String? = nil,
        visible: Bool? = nil
    ) {
        self.t = t
        self.x = x
        self.y = y
        self.cursorId = cursorId
        self.visible = visible
    }

    public var isVisible: Bool { visible ?? true }
}

/// Target bounds in global Quartz points at a recording timestamp.
public struct TargetGeometrySample: Codable, Sendable, Hashable {
    public var t: TimeInterval
    public var bounds: Rect2D
    public var available: Bool

    public init(t: TimeInterval, bounds: Rect2D, available: Bool = true) {
        self.t = t
        self.bounds = bounds
        self.available = available
    }
}

public enum MouseButton: String, Codable, Sendable, Hashable {
    case left
    case right
    case middle
    case other
}

/// One mouse-button event. Written as a single JSONL line in `recording/clicks.jsonl`.
public struct ClickSample: Codable, Sendable, Hashable {
    public var t: TimeInterval
    public var button: MouseButton
    public var down: Bool

    public init(t: TimeInterval, button: MouseButton, down: Bool) {
        self.t = t
        self.button = button
        self.down = down
    }
}

/// Cursor glyph captured during recording. PNG lives under `recording/cursors/`.
public struct CursorSprite: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Hotspot in sprite image pixels.
    public var hotspot: Point2D
    /// Path relative to the `.openrecord` bundle root.
    public var pngRelativePath: String
    /// Native cursor size in points.
    public var standardSize: Size2D

    public init(
        id: String,
        hotspot: Point2D,
        pngRelativePath: String,
        standardSize: Size2D
    ) {
        self.id = id
        self.hotspot = hotspot
        self.pngRelativePath = pngRelativePath
        self.standardSize = standardSize
    }
}

public struct CursorSpritePlacement: Sendable, Hashable {
    public var drawSize: Size2D
    public var hotspot: Point2D

    public init(drawSize: Size2D, hotspot: Point2D) {
        self.drawSize = drawSize
        self.hotspot = hotspot
    }
}

public enum CursorSpriteLayout: Sendable {
    public static func placement(
        sprite: CursorSprite,
        imagePixelSize: Size2D,
        cursorScale: Double,
        pixelsPerPoint: Double
    ) -> CursorSpritePlacement {
        let pixelWidth = max(imagePixelSize.width, 1)
        let pixelHeight = max(imagePixelSize.height, 1)
        let drawWidth = max(sprite.standardSize.width * cursorScale * pixelsPerPoint, 1)
        let drawHeight = max(sprite.standardSize.height * cursorScale * pixelsPerPoint, 1)
        return CursorSpritePlacement(
            drawSize: Size2D(width: drawWidth, height: drawHeight),
            hotspot: Point2D(
                x: sprite.hotspot.x / pixelWidth * drawWidth,
                y: sprite.hotspot.y / pixelHeight * drawHeight
            )
        )
    }
}
