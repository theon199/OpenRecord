import CoreGraphics
import Foundation

public struct KeyboardOverlayKey: Sendable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var opacity: Double

    public init(id: Int, label: String, opacity: Double) {
        self.id = id
        self.label = label
        self.opacity = opacity
    }
}

public struct KeyboardOverlayState: Sendable, Hashable {
    public var keys: [KeyboardOverlayKey]

    public init(keys: [KeyboardOverlayKey] = []) {
        self.keys = keys
    }

    public var isVisible: Bool {
        keys.contains { $0.opacity > 0 }
    }
}

/// Indexed keyboard presses shared by preview and export. Key-up records are
/// retained in the sidecar for future effects, while the v2 pill shows each
/// shortcut for a fixed hold plus fade period after key-down.
public struct KeyboardOverlayTimeline: Sendable {
    public static let fadeDuration: TimeInterval = 0.22

    private struct Press: Sendable {
        var id: Int
        var sample: KeySample
    }

    private var presses: [Press]

    public init(samples: [KeySample]) {
        presses = samples.enumerated()
            .filter { $0.element.down }
            .map { Press(id: $0.offset, sample: $0.element) }
            .sorted {
                if $0.sample.t == $1.sample.t { return $0.id < $1.id }
                return $0.sample.t < $1.sample.t
            }
    }

    public func state(
        at time: TimeInterval,
        settings rawSettings: KeyboardOverlaySettings
    ) -> KeyboardOverlayState {
        let settings = rawSettings.normalized
        guard settings.enabled, !presses.isEmpty else { return KeyboardOverlayState() }
        let lifetime = settings.fadeDelay + Self.fadeDuration
        var visible: [KeyboardOverlayKey] = []
        visible.reserveCapacity(settings.maxVisibleKeys)

        var index = upperBound(for: time) - 1
        while index >= 0, visible.count < settings.maxVisibleKeys {
            let press = presses[index]
            let age = time - press.sample.t
            if age > lifetime { break }
            if age >= 0 {
                let opacity = age <= settings.fadeDelay
                    ? 1
                    : 1 - (age - settings.fadeDelay) / Self.fadeDuration
                visible.append(
                    KeyboardOverlayKey(
                        id: press.id,
                        label: press.sample.displayLabel,
                        opacity: min(max(opacity, 0), 1)
                    )
                )
            }
            index -= 1
        }
        return KeyboardOverlayState(keys: visible.reversed())
    }

    private func upperBound(for time: TimeInterval) -> Int {
        var lower = 0
        var upper = presses.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if presses[middle].sample.t <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

public struct KeyboardOverlayGeometry: Sendable, Hashable {
    public var bounds: CGRect
    public var keyRects: [CGRect]
    public var fontSize: Double
    public var cornerRadius: Double

    public init(
        bounds: CGRect,
        keyRects: [CGRect],
        fontSize: Double,
        cornerRadius: Double
    ) {
        self.bounds = bounds
        self.keyRects = keyRects
        self.fontSize = fontSize
        self.cornerRadius = cornerRadius
    }
}

public enum KeyboardOverlayLayout: Sendable {
    public static func geometry(
        for state: KeyboardOverlayState,
        settings rawSettings: KeyboardOverlaySettings,
        canvasSize: CGSize,
        canvasPadding: Double
    ) -> KeyboardOverlayGeometry? {
        let settings = rawSettings.normalized
        guard state.isVisible, !state.keys.isEmpty,
              canvasSize.width > 1, canvasSize.height > 1
        else { return nil }

        let scale = min(max(canvasSize.height / 1080, 0.6), 1)
        let height = 56 * scale
        let fontSize = 27 * scale
        let gap = 8 * scale
        let horizontalPadding = 16 * scale
        let maxKeyWidth = max(height, canvasSize.width * 0.55)
        let widths = state.keys.map { key in
            min(
                max(height, CGFloat(key.label.count) * fontSize * 0.64 + horizontalPadding * 2),
                maxKeyWidth
            )
        }
        let totalWidth = widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
        let inset = max(32 * scale, CGFloat(max(canvasPadding, 0)))
        let x: CGFloat
        switch settings.position {
        case .bottomCenter:
            x = (canvasSize.width - totalWidth) / 2
        case .bottomLeft:
            x = inset
        }
        let clampedX = min(max(x, 0), max(canvasSize.width - totalWidth, 0))
        let y = max(canvasSize.height - inset - height, 0)
        let bounds = CGRect(x: clampedX, y: y, width: totalWidth, height: height)
        var keyRects: [CGRect] = []
        keyRects.reserveCapacity(widths.count)
        var keyX = bounds.minX
        for width in widths {
            keyRects.append(CGRect(x: keyX, y: y, width: width, height: height))
            keyX += width + gap
        }
        return KeyboardOverlayGeometry(
            bounds: bounds,
            keyRects: keyRects,
            fontSize: fontSize,
            cornerRadius: 12 * scale
        )
    }
}
