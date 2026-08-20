import Foundation

/// One cursor-path sample. Written as a single JSONL line in `recording/mouse.jsonl`.
/// Coordinates are in **points** (not pixels). `t` is seconds from recording start.
public struct CursorSample: Codable, Sendable, Hashable {
    public var t: TimeInterval
    public var x: Double
    public var y: Double
    public var cursorId: String?

    public init(t: TimeInterval, x: Double, y: Double, cursorId: String? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.cursorId = cursorId
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
