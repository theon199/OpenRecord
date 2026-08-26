import Foundation

public enum CaptionPosition: String, Codable, CaseIterable, Sendable, Hashable {
    case top
    case center
    case bottom

    public var defaultAnchor: Point2D {
        switch self {
        case .top: Point2D(x: 0.5, y: 0.12)
        case .center: Point2D(x: 0.5, y: 0.5)
        case .bottom: Point2D(x: 0.5, y: 0.88)
        }
    }
}

public struct CaptionStyle: Codable, Sendable, Hashable {
    public static let fontSizeRange = 18.0...96.0
    public static let maxWidthRange = 0.25...0.95

    public var fontSize: Double
    public var foreground: RGBAColor
    public var background: RGBAColor
    public var position: CaptionPosition
    /// Maximum width relative to the canvas width.
    public var maxWidth: Double

    public init(
        fontSize: Double = 44,
        foreground: RGBAColor = RGBAColor(r: 1, g: 1, b: 1),
        background: RGBAColor = RGBAColor(r: 0.03, g: 0.03, b: 0.04, a: 0.88),
        position: CaptionPosition = .bottom,
        maxWidth: Double = 0.78
    ) {
        self.fontSize = fontSize
        self.foreground = foreground
        self.background = background
        self.position = position
        self.maxWidth = maxWidth
    }

    public static let `default` = CaptionStyle()

    public var normalized: CaptionStyle {
        var value = self
        value.fontSize = Self.clamp(
            value.fontSize,
            to: Self.fontSizeRange,
            fallback: Self.default.fontSize
        )
        value.maxWidth = Self.clamp(
            value.maxWidth,
            to: Self.maxWidthRange,
            fallback: Self.default.maxWidth
        )
        value.foreground = value.foreground.normalized
        value.background = value.background.normalized
        return value
    }

    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

public struct CaptionCue: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var style: CaptionStyle

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        style: CaptionStyle = .default
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.style = style
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    public var normalized: CaptionCue {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start + 0.05) : value.start + 0.05
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        value.style = value.style.normalized
        return value
    }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable, Hashable {
    case text
    case arrow
    case spotlight
    case box
    case underline
    case stepMarker = "step-marker"
    case label
}

/// A source-timed canvas annotation. Coordinates are normalized canvas UV,
/// origin top-left. Fields that are not used by the selected `kind` remain in
/// the document so switching annotation types is non-destructive.
public struct Annotation: Codable, Sendable, Hashable, Identifiable {
    public static let fontSizeRange = 18.0...120.0
    public static let dimAmountRange = 0.0...0.9

    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var kind: AnnotationKind
    public var text: String
    public var position: Point2D
    public var endPosition: Point2D
    public var rect: Rect2D
    public var color: RGBAColor
    public var background: RGBAColor
    public var fontSize: Double
    public var dimAmount: Double
    public var animation: AnnotationAnimation

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        kind: AnnotationKind,
        text: String = "",
        position: Point2D = Point2D(x: 0.5, y: 0.5),
        endPosition: Point2D = Point2D(x: 0.7, y: 0.5),
        rect: Rect2D = Rect2D(x: 0.3, y: 0.3, width: 0.4, height: 0.3),
        color: RGBAColor = RGBAColor(r: 1, g: 0.25, b: 0.16),
        background: RGBAColor = RGBAColor(r: 0.03, g: 0.03, b: 0.04, a: 0.88),
        fontSize: Double = 42,
        dimAmount: Double = 0.58,
        animation: AnnotationAnimation = .none
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.text = text
        self.position = position
        self.endPosition = endPosition
        self.rect = rect
        self.color = color
        self.background = background
        self.fontSize = fontSize
        self.dimAmount = dimAmount
        self.animation = animation
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, kind, text, position, endPosition, rect
        case color, background, fontSize, dimAmount, animation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start + 2
        kind = try container.decodeIfPresent(AnnotationKind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try container.decodeIfPresent(Point2D.self, forKey: .position)
            ?? Point2D(x: 0.5, y: 0.5)
        endPosition = try container.decodeIfPresent(Point2D.self, forKey: .endPosition)
            ?? Point2D(x: 0.7, y: 0.5)
        rect = try container.decodeIfPresent(Rect2D.self, forKey: .rect)
            ?? Rect2D(x: 0.3, y: 0.3, width: 0.4, height: 0.3)
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color)
            ?? RGBAColor(r: 1, g: 0.25, b: 0.16)
        background = try container.decodeIfPresent(RGBAColor.self, forKey: .background)
            ?? RGBAColor(r: 0.03, g: 0.03, b: 0.04, a: 0.88)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 42
        dimAmount = try container.decodeIfPresent(Double.self, forKey: .dimAmount) ?? 0.58
        animation = try container.decodeIfPresent(
            AnnotationAnimation.self,
            forKey: .animation
        ) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(position, forKey: .position)
        try container.encode(endPosition, forKey: .endPosition)
        try container.encode(rect, forKey: .rect)
        try container.encode(color, forKey: .color)
        try container.encode(background, forKey: .background)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(dimAmount, forKey: .dimAmount)
        if animation != .none {
            try container.encode(animation, forKey: .animation)
        }
    }

    public static func textCallout(
        start: TimeInterval,
        end: TimeInterval,
        text: String = "Callout",
        position: Point2D = Point2D(x: 0.5, y: 0.25)
    ) -> Annotation {
        Annotation(start: start, end: end, kind: .text, text: text, position: position)
    }

    public static func arrow(
        start: TimeInterval,
        end: TimeInterval,
        from: Point2D = Point2D(x: 0.3, y: 0.5),
        to: Point2D = Point2D(x: 0.65, y: 0.5)
    ) -> Annotation {
        Annotation(
            start: start,
            end: end,
            kind: .arrow,
            position: from,
            endPosition: to
        )
    }

    public static func spotlight(
        start: TimeInterval,
        end: TimeInterval,
        rect: Rect2D = Rect2D(x: 0.3, y: 0.3, width: 0.4, height: 0.3)
    ) -> Annotation {
        Annotation(start: start, end: end, kind: .spotlight, rect: rect)
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    public var normalized: Annotation {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start + 0.05) : value.start + 0.05
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        value.position = Self.normalizedPoint(value.position)
        value.endPosition = Self.normalizedPoint(value.endPosition)
        value.rect = Self.normalizedRect(value.rect)
        value.color = value.color.normalized
        value.background = value.background.normalized
        value.fontSize = value.fontSize.isFinite
            ? min(max(value.fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            : 42
        value.dimAmount = value.dimAmount.isFinite
            ? min(max(value.dimAmount, Self.dimAmountRange.lowerBound), Self.dimAmountRange.upperBound)
            : 0.58
        value.animation = value.animation.normalized
        return value
    }

    private static func normalizedPoint(_ point: Point2D) -> Point2D {
        Point2D(
            x: point.x.isFinite ? min(max(point.x, 0), 1) : 0.5,
            y: point.y.isFinite ? min(max(point.y, 0), 1) : 0.5
        )
    }

    private static func normalizedRect(_ rect: Rect2D) -> Rect2D {
        let x = rect.x.isFinite ? min(max(rect.x, 0), 0.98) : 0.3
        let y = rect.y.isFinite ? min(max(rect.y, 0), 0.98) : 0.3
        let width = rect.width.isFinite ? min(max(rect.width, 0.02), 1 - x) : 0.4
        let height = rect.height.isFinite ? min(max(rect.height, 0.02), 1 - y) : 0.3
        return Rect2D(x: x, y: y, width: width, height: height)
    }
}

public enum VideoExportCodec: String, Codable, CaseIterable, Sendable, Hashable {
    case h264
    case hevc
    case proRes422 = "prores-422"
}

public enum ExportResolutionPreset: String, Codable, CaseIterable, Sendable, Hashable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p2160 = "4k"
    case source

    public var maxEdges: (long: Int, short: Int)? {
        switch self {
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        case .p2160: (3840, 2160)
        case .source: nil
        }
    }
}

public struct VideoExportSettings: Codable, Sendable, Hashable {
    public var codec: VideoExportCodec
    public var resolution: ExportResolutionPreset

    public init(
        codec: VideoExportCodec = .h264,
        resolution: ExportResolutionPreset = .p1080
    ) {
        self.codec = codec
        self.resolution = resolution
    }

    public static let `default` = VideoExportSettings()
}

public extension RGBAColor {
    var normalized: RGBAColor {
        RGBAColor(
            r: Self.normalizedComponent(r),
            g: Self.normalizedComponent(g),
            b: Self.normalizedComponent(b),
            a: Self.normalizedComponent(a)
        )
    }

    private static func normalizedComponent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
