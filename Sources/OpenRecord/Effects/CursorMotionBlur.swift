import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public struct CursorMotionBlurState: Sendable, Hashable {
    public var speed: Double
    public var radius: Double
    public var angle: Double
    public var previewRadius: Double

    public init(speed: Double, radius: Double, angle: Double, previewRadius: Double) {
        self.speed = speed
        self.radius = radius
        self.angle = angle
        self.previewRadius = previewRadius
    }

    public static let none = CursorMotionBlurState(
        speed: 0,
        radius: 0,
        angle: 0,
        previewRadius: 0
    )
}

/// Shared velocity-to-effect mapping. Velocity arrives in top-left UV space;
/// Core Image uses bottom-left coordinates, so the exported angle flips Y.
public enum CursorMotionBlurEffect: Sendable {
    public static let speedThreshold: Double = 180
    public static let fullSpeed: Double = 1_800
    public static let maximumRadius: Double = 28

    public static func state(
        velocity: Point2D?,
        canvasSize: CGSize,
        settings rawSettings: CursorMotionBlurSettings
    ) -> CursorMotionBlurState {
        let settings = rawSettings.normalized
        guard settings.enabled,
              settings.amount > 0,
              let velocity,
              canvasSize.width > 0,
              canvasSize.height > 0
        else { return .none }

        let vx = velocity.x * canvasSize.width
        let vyTopLeft = velocity.y * canvasSize.height
        let speed = hypot(vx, vyTopLeft)
        guard speed > speedThreshold else {
            return CursorMotionBlurState(speed: speed, radius: 0, angle: 0, previewRadius: 0)
        }

        let progress = min(
            max((speed - speedThreshold) / (fullSpeed - speedThreshold), 0),
            1
        )
        let radius = maximumRadius * pow(progress, 0.72) * settings.amount
        return CursorMotionBlurState(
            speed: speed,
            radius: radius,
            angle: atan2(-vyTopLeft, vx),
            previewRadius: min(radius * 0.32, 8)
        )
    }
}

enum CursorMotionBlurRenderer {
    static func image(_ image: CIImage, state: CursorMotionBlurState) -> CIImage {
        guard state.radius > 0.01 else { return image }
        let pad = CGFloat(ceil(state.radius) + 2)
        let paddedExtent = image.extent.insetBy(dx: -pad, dy: -pad)
        let transparent = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ).cropped(to: paddedExtent)
        let filter = CIFilter.motionBlur()
        filter.inputImage = image.composited(over: transparent)
        filter.radius = Float(state.radius)
        filter.angle = Float(state.angle)
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: paddedExtent)
    }
}
