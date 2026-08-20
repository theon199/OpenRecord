import CoreGraphics
import Foundation

/// Keyed 2D point for JSON (avoids CGPoint's unkeyed Codable).
public struct Point2D: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// Keyed 2D size for JSON (avoids CGSize's unkeyed Codable).
public struct Size2D: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.width = Double(size.width)
        self.height = Double(size.height)
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

/// Keyed rect for JSON (avoids CGRect's unkeyed Codable).
public struct Rect2D: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let unit = Rect2D(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
