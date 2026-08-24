import Foundation

public struct RGBAColor: Codable, Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let canvasDefault = RGBAColor(r: 0.12, g: 0.12, b: 0.14, a: 1)
}

public enum CanvasBackground: Codable, Sendable, Hashable {
    case solid(RGBAColor)
    case linearGradient(start: RGBAColor, end: RGBAColor, startPoint: Point2D, endPoint: Point2D)
}

public enum CanvasAspectPreset: String, CaseIterable, Sendable, Hashable {
    case widescreen = "16:9"
    case portrait = "9:16"
    case square = "1:1"
    case standard = "4:3"

    public var width: Double {
        switch self {
        case .widescreen: 16
        case .portrait: 9
        case .square: 1
        case .standard: 4
        }
    }

    public var height: Double {
        switch self {
        case .widescreen: 9
        case .portrait: 16
        case .square: 1
        case .standard: 3
        }
    }

    public func apply(to canvas: inout CanvasSettings) {
        canvas.aspectWidth = width
        canvas.aspectHeight = height
    }

    public static func matching(
        aspectWidth: Double,
        aspectHeight: Double,
        tolerance: Double = 0.000_001
    ) -> CanvasAspectPreset? {
        let ratio = aspectWidth / max(aspectHeight, 1e-12)
        return allCases.first {
            abs(ratio - ($0.width / $0.height)) <= tolerance
        }
    }
}

public struct CanvasSettings: Codable, Sendable, Hashable {
    public static let cursorScaleRange = 0.1...3.0

    public var background: CanvasBackground
    public var padding: Double
    public var cornerRadius: Double
    public var cursorScale: Double
    public var aspectWidth: Double
    public var aspectHeight: Double

    public init(
        background: CanvasBackground = .solid(.canvasDefault),
        padding: Double = 48,
        cornerRadius: Double = 16,
        cursorScale: Double = 0.5,
        aspectWidth: Double = 16,
        aspectHeight: Double = 9
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.cursorScale = cursorScale
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
    }

    public static let `default` = CanvasSettings()
}

/// A reusable visual treatment for the canvas framing around a recording.
/// Applying a preset intentionally preserves output aspect ratio and cursor
/// scale because those are independent format and accessibility choices.
public struct CanvasPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var background: CanvasBackground
    public var padding: Double
    public var cornerRadius: Double

    public init(
        id: String,
        name: String,
        background: CanvasBackground,
        padding: Double,
        cornerRadius: Double
    ) {
        self.id = id
        self.name = name
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    public func apply(to canvas: inout CanvasSettings) {
        canvas.background = background
        canvas.padding = padding
        canvas.cornerRadius = cornerRadius
    }

    public func matches(_ canvas: CanvasSettings, tolerance: Double = 0.000_001) -> Bool {
        background == canvas.background
            && abs(padding - canvas.padding) <= tolerance
            && abs(cornerRadius - canvas.cornerRadius) <= tolerance
    }

    public static func matching(_ canvas: CanvasSettings) -> CanvasPreset? {
        builtIns.first { $0.matches(canvas) }
    }

    public static let defaultStyle = CanvasPreset(
        id: "default",
        name: "Default",
        background: .solid(.canvasDefault),
        padding: 48,
        cornerRadius: 16
    )

    public static let dark = CanvasPreset(
        id: "dark",
        name: "Dark",
        background: .linearGradient(
            start: RGBAColor(r: 0.055, g: 0.065, b: 0.095),
            end: RGBAColor(r: 0.16, g: 0.20, b: 0.31),
            startPoint: Point2D(x: 0, y: 0),
            endPoint: Point2D(x: 1, y: 1)
        ),
        padding: 64,
        cornerRadius: 20
    )

    public static let light = CanvasPreset(
        id: "light",
        name: "Light",
        background: .linearGradient(
            start: RGBAColor(r: 0.96, g: 0.97, b: 0.99),
            end: RGBAColor(r: 0.78, g: 0.84, b: 0.94),
            startPoint: Point2D(x: 0, y: 0),
            endPoint: Point2D(x: 1, y: 1)
        ),
        padding: 64,
        cornerRadius: 18
    )

    public static let minimal = CanvasPreset(
        id: "minimal",
        name: "Minimal",
        background: .solid(RGBAColor(r: 0.04, g: 0.04, b: 0.045)),
        padding: 16,
        cornerRadius: 6
    )

    public static let builtIns: [CanvasPreset] = [defaultStyle, dark, light, minimal]
}

public struct ZoomRange: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var amount: Double
    /// Normalized anchor in UV space (0...1), origin top-left.
    public var anchor: Point2D

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        amount: Double,
        anchor: Point2D
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.amount = amount
        self.anchor = anchor
    }
}

public struct ProjectMeta: Codable, Sendable, Hashable {
    public var createdAt: Date
    public var appVersion: String
    public var displayBounds: Rect2D
    public var scale: Double
    public var captureTarget: CaptureTarget
    /// Offsets, in seconds, from the first complete display frame.
    public var captureTiming: CaptureTiming?
    /// Capture completion/recovery state. Missing on legacy projects means complete.
    public var captureHealth: CaptureHealth?

    public init(
        createdAt: Date = Date(),
        appVersion: String = OpenRecordInfo.appVersion,
        displayBounds: Rect2D,
        scale: Double,
        captureTarget: CaptureTarget,
        captureTiming: CaptureTiming? = nil,
        captureHealth: CaptureHealth? = nil
    ) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.displayBounds = displayBounds
        self.scale = scale
        self.captureTarget = captureTarget
        self.captureTiming = captureTiming
        self.captureHealth = captureHealth
    }
}

public struct CaptureTiming: Codable, Sendable, Hashable {
    public var systemAudioOffset: TimeInterval?
    public var microphoneOffset: TimeInterval?

    public init(
        systemAudioOffset: TimeInterval? = nil,
        microphoneOffset: TimeInterval? = nil
    ) {
        self.systemAudioOffset = systemAudioOffset
        self.microphoneOffset = microphoneOffset
    }
}

public enum CaptureHealthState: String, Codable, Sendable, Hashable {
    case complete
    case recovered
}

public enum CaptureWarningCode: String, Codable, Sendable, Hashable {
    case missingDisplayVideo
    case screenStoppedUnexpectedly
    case finalizationTimedOut
    case missingSystemAudio
    case missingMicrophone
    case truncatedVideo
    case truncatedSystemAudio
    case truncatedMicrophone
    case truncatedMouseTelemetry
    case truncatedClickTelemetry
    case truncatedTargetGeometry
}

public struct CaptureHealth: Codable, Sendable, Hashable {
    public var state: CaptureHealthState
    public var warnings: [CaptureWarningCode]

    public init(state: CaptureHealthState = .complete, warnings: [CaptureWarningCode] = []) {
        self.state = state
        self.warnings = warnings
    }

    public static let complete = CaptureHealth()
}

public struct ProjectDocument: Codable, Sendable, Hashable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var trimIn: TimeInterval
    public var trimOut: TimeInterval?
    public var zoomRanges: [ZoomRange]
    public var canvas: CanvasSettings
    public var cursorSprites: [CursorSprite]

    public init(
        formatVersion: Int = ProjectDocument.currentFormatVersion,
        trimIn: TimeInterval = 0,
        trimOut: TimeInterval? = nil,
        zoomRanges: [ZoomRange] = [],
        canvas: CanvasSettings = .default,
        cursorSprites: [CursorSprite] = []
    ) {
        self.formatVersion = formatVersion
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.zoomRanges = zoomRanges
        self.canvas = canvas
        self.cursorSprites = cursorSprites
    }
}

public struct OpenedProject: Sendable, Hashable {
    public var url: URL
    public var meta: ProjectMeta
    public var document: ProjectDocument

    public init(url: URL, meta: ProjectMeta, document: ProjectDocument) {
        self.url = url
        self.meta = meta
        self.document = document
    }
}
