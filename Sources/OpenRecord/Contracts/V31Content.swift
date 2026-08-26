import Foundation

public enum RedactionMode: String, Codable, CaseIterable, Sendable, Hashable {
    case blur
    case pixelate
}

/// A source-timed privacy overlay in normalized canvas coordinates.
public struct RedactionRegion: Codable, Sendable, Hashable, Identifiable {
    public static let strengthRange = 0.05...1.0

    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var rect: Rect2D
    public var mode: RedactionMode
    public var strength: Double

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        rect: Rect2D = Rect2D(x: 0.3, y: 0.3, width: 0.4, height: 0.2),
        mode: RedactionMode = .blur,
        strength: Double = 0.55
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.mode = mode
        self.strength = strength
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    public var normalized: RedactionRegion {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite
            ? max(value.end, value.start + TimelineRangeEditing.minimumOverlayDuration)
            : value.start + TimelineRangeEditing.minimumOverlayDuration
        value.rect = NormalizedCanvasGeometry.rect(value.rect)
        value.strength = value.strength.isFinite
            ? min(max(value.strength, Self.strengthRange.lowerBound), Self.strengthRange.upperBound)
            : 0.55
        return value
    }
}

public enum DrawingTool: String, Codable, CaseIterable, Sendable, Hashable {
    case pen
    case highlighter
}

/// A freehand vector stroke. Points stay normalized so preview and export can
/// render the same project at any canvas resolution.
public struct DrawingStroke: Codable, Sendable, Hashable, Identifiable {
    public static let widthRange = 1.0...80.0

    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var tool: DrawingTool
    public var points: [Point2D]
    public var color: RGBAColor
    public var width: Double

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        tool: DrawingTool = .pen,
        points: [Point2D] = [],
        color: RGBAColor = RGBAColor(r: 1, g: 0.28, b: 0.12),
        width: Double = 8
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    public var normalized: DrawingStroke {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite
            ? max(value.end, value.start + TimelineRangeEditing.minimumOverlayDuration)
            : value.start + TimelineRangeEditing.minimumOverlayDuration
        value.points = value.points.map(NormalizedCanvasGeometry.point)
        value.color = value.color.normalized
        value.width = value.width.isFinite
            ? min(max(value.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            : 8
        return value
    }
}

public enum AnnotationAnimationStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case fade
    case pop
}

/// Deterministic entrance/exit treatment shared by preview and export.
public struct AnnotationAnimation: Codable, Sendable, Hashable {
    public static let durationRange = 0.05...1.0

    public var entrance: AnnotationAnimationStyle
    public var exit: AnnotationAnimationStyle
    public var duration: TimeInterval

    public init(
        entrance: AnnotationAnimationStyle = .none,
        exit: AnnotationAnimationStyle = .none,
        duration: TimeInterval = 0.2
    ) {
        self.entrance = entrance
        self.exit = exit
        self.duration = duration
    }

    public static let none = AnnotationAnimation()

    public var normalized: AnnotationAnimation {
        var value = self
        value.duration = value.duration.isFinite
            ? min(max(value.duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
            : 0.2
        return value
    }
}

public enum DeviceFrameID: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case genericLaptopDark = "generic-laptop-dark"
    case genericPhoneDark = "generic-phone-dark"
    case genericBrowserLight = "generic-browser-light"

    public var displayName: String {
        switch self {
        case .none: "None"
        case .genericLaptopDark: "Laptop"
        case .genericPhoneDark: "Phone"
        case .genericBrowserLight: "Browser"
        }
    }
}

/// A deterministic, asset-free presentation frame around the display track.
public struct DeviceFrameSettings: Codable, Sendable, Hashable {
    public static let scaleRange = 0.6...1.0

    public var id: DeviceFrameID
    public var scale: Double
    public var shadow: Bool

    public init(
        id: DeviceFrameID = .none,
        scale: Double = 1,
        shadow: Bool = true
    ) {
        self.id = id
        self.scale = scale
        self.shadow = shadow
    }

    public static let none = DeviceFrameSettings()
    public var enabled: Bool { id != .none }

    public var normalized: DeviceFrameSettings {
        var value = self
        value.scale = value.scale.isFinite
            ? min(max(value.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            : 1
        return value
    }
}

/// Canvas normalization used by every v3.1 model before persistence.
public enum NormalizedCanvasGeometry: Sendable {
    public static func point(_ point: Point2D) -> Point2D {
        Point2D(
            x: point.x.isFinite ? min(max(point.x, 0), 1) : 0.5,
            y: point.y.isFinite ? min(max(point.y, 0), 1) : 0.5
        )
    }

    public static func rect(_ rect: Rect2D) -> Rect2D {
        let x = rect.x.isFinite ? min(max(rect.x, 0), 0.98) : 0.3
        let y = rect.y.isFinite ? min(max(rect.y, 0), 0.98) : 0.3
        let width = rect.width.isFinite ? min(max(rect.width, 0.02), 1 - x) : 0.4
        let height = rect.height.isFinite ? min(max(rect.height, 0.02), 1 - y) : 0.2
        return Rect2D(x: x, y: y, width: width, height: height)
    }
}
