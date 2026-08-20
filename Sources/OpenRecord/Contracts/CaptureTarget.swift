import Foundation

/// What to record. Identifiers match CoreGraphics / ScreenCaptureKit IDs.
public enum CaptureTarget: Codable, Sendable, Hashable {
    case display(id: UInt32)
    case window(id: UInt32)
}
