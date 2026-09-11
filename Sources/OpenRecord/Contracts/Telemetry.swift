import Foundation

/// A raw telemetry record that can be assigned a per-stream sequence number.
///
/// Sequence numbers are deliberately optional in the contract.  Older bundles
/// do not contain them, and decoding those bundles must remain lossless.  New
/// capture writers assign a value while holding their write lock so a stream
/// has one contiguous, monotonic sequence even when callbacks race.
public protocol TelemetryRecord: Codable, Sendable, Hashable {
    var sequence: UInt64? { get set }
}

/// One cursor-path sample. Written as a single JSONL line in `recording/mouse.jsonl`.
/// Coordinates are in **points** (not pixels). `t` is seconds from recording start.
public struct CursorSample: TelemetryRecord {
    public var t: TimeInterval
    public var x: Double
    public var y: Double
    public var cursorId: String?
    /// `nil` is interpreted as visible for v1 projects.
    public var visible: Bool?
    /// Optional per-stream sequence. Missing means this is a legacy sample.
    public var sequence: UInt64?

    public init(
        t: TimeInterval,
        x: Double,
        y: Double,
        cursorId: String? = nil,
        visible: Bool? = nil,
        sequence: UInt64? = nil
    ) {
        self.t = t
        self.x = x
        self.y = y
        self.cursorId = cursorId
        self.visible = visible
        self.sequence = sequence
    }

    public var isVisible: Bool { visible ?? true }
}

/// Target bounds in global Quartz points at a recording timestamp.
public struct TargetGeometrySample: TelemetryRecord {
    public var t: TimeInterval
    public var bounds: Rect2D
    public var available: Bool
    public var sequence: UInt64?

    public init(
        t: TimeInterval,
        bounds: Rect2D,
        available: Bool = true,
        sequence: UInt64? = nil
    ) {
        self.t = t
        self.bounds = bounds
        self.available = available
        self.sequence = sequence
    }
}

public enum MouseButton: String, Codable, Sendable, Hashable {
    case left
    case right
    case middle
    case other
}

/// One mouse-button event. Written as a single JSONL line in `recording/clicks.jsonl`.
public struct ClickSample: TelemetryRecord {
    public var t: TimeInterval
    public var button: MouseButton
    public var down: Bool
    /// Quartz-point position captured with the click. Optional for legacy
    /// click streams, which only recorded button edges.
    public var x: Double?
    public var y: Double?
    public var sequence: UInt64?

    public init(
        t: TimeInterval,
        button: MouseButton,
        down: Bool,
        x: Double? = nil,
        y: Double? = nil,
        sequence: UInt64? = nil
    ) {
        self.t = t
        self.button = button
        self.down = down
        self.x = x
        self.y = y
        self.sequence = sequence
    }
}

public enum KeyModifier: String, Codable, CaseIterable, Sendable, Hashable {
    case control
    case option
    case shift
    case command
    case function

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }
}

/// One privacy-filtered keyboard event. Written as a single JSONL line in
/// `recording/keys.jsonl`; `t` shares the display video's time origin.
public struct KeySample: TelemetryRecord {
    public var t: TimeInterval
    public var key: String
    public var modifiers: [KeyModifier]
    public var down: Bool
    public var sequence: UInt64?

    public init(
        t: TimeInterval,
        key: String,
        modifiers: [KeyModifier] = [],
        down: Bool,
        sequence: UInt64? = nil
    ) {
        self.t = t
        self.key = key
        self.modifiers = modifiers
        self.down = down
        self.sequence = sequence
    }

    public var displayLabel: String {
        let prefix = KeyModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        return prefix.isEmpty ? key : "\(prefix) \(key)"
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

/// One typing / text-focus event. Written as a single JSONL line in `recording/typing.jsonl`.
/// Coordinates are in Quartz points. Contains no key characters or text content (100% private).
public struct TypingSample: TelemetryRecord {
    public var t: TimeInterval
    public var x: Double
    public var y: Double
    public var width: Double?
    public var height: Double?
    public var sequence: UInt64?

    public init(
        t: TimeInterval,
        x: Double,
        y: Double,
        width: Double? = nil,
        height: Double? = nil,
        sequence: UInt64? = nil
    ) {
        self.t = t
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.sequence = sequence
    }
}
