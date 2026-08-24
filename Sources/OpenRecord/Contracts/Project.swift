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
    case truncatedKeyboardTelemetry
    case truncatedTargetGeometry
    case keyboardSecureInputGap
}

public enum KeyboardOverlayStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case pill
}

public enum KeyboardOverlayPosition: String, Codable, CaseIterable, Sendable, Hashable {
    case bottomCenter = "bottom-center"
    case bottomLeft = "bottom-left"
}

public enum AutoZoomSensitivity: String, Codable, CaseIterable, Sendable, Hashable {
    case subtle
    case normal
    case aggressive
}

public enum ZoomEasingPreset: String, Codable, CaseIterable, Sendable, Hashable {
    case fast
    case smooth
    case cinematic
}

public struct KeyboardOverlaySettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var style: KeyboardOverlayStyle
    public var position: KeyboardOverlayPosition
    public var fadeDelay: TimeInterval
    public var maxVisibleKeys: Int

    public init(
        enabled: Bool = false,
        style: KeyboardOverlayStyle = .pill,
        position: KeyboardOverlayPosition = .bottomCenter,
        fadeDelay: TimeInterval = 0.8,
        maxVisibleKeys: Int = 3
    ) {
        self.enabled = enabled
        self.style = style
        self.position = position
        self.fadeDelay = fadeDelay
        self.maxVisibleKeys = maxVisibleKeys
    }

    public static let disabled = KeyboardOverlaySettings()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case style
        case position
        case fadeDelay
        case maxVisibleKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        style = (try? container.decode(KeyboardOverlayStyle.self, forKey: .style)) ?? .pill
        position = (try? container.decode(KeyboardOverlayPosition.self, forKey: .position))
            ?? .bottomCenter
        fadeDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .fadeDelay) ?? 0.8
        maxVisibleKeys = try container.decodeIfPresent(Int.self, forKey: .maxVisibleKeys) ?? 3
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(style, forKey: .style)
        try container.encode(position, forKey: .position)
        try container.encode(fadeDelay, forKey: .fadeDelay)
        try container.encode(maxVisibleKeys, forKey: .maxVisibleKeys)
    }

    public var normalized: KeyboardOverlaySettings {
        var value = self
        value.fadeDelay = min(max(value.fadeDelay, 0.2), 3)
        value.maxVisibleKeys = min(max(value.maxVisibleKeys, 1), 5)
        return value
    }
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
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var trimIn: TimeInterval
    public var trimOut: TimeInterval?
    public var zoomRanges: [ZoomRange]
    public var canvas: CanvasSettings
    public var cursorSprites: [CursorSprite]
    public var keyboardOverlay: KeyboardOverlaySettings
    public var stylePresetID: String?
    public var autoZoomSensitivity: AutoZoomSensitivity
    public var zoomEasing: ZoomEasingPreset

    public init(
        formatVersion: Int = ProjectDocument.currentFormatVersion,
        trimIn: TimeInterval = 0,
        trimOut: TimeInterval? = nil,
        zoomRanges: [ZoomRange] = [],
        canvas: CanvasSettings = .default,
        cursorSprites: [CursorSprite] = [],
        keyboardOverlay: KeyboardOverlaySettings = .disabled,
        stylePresetID: String? = nil,
        autoZoomSensitivity: AutoZoomSensitivity = .normal,
        zoomEasing: ZoomEasingPreset = .smooth
    ) {
        self.formatVersion = formatVersion
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.zoomRanges = zoomRanges
        self.canvas = canvas
        self.cursorSprites = cursorSprites
        self.keyboardOverlay = keyboardOverlay
        self.stylePresetID = stylePresetID ?? CanvasPreset.matching(canvas)?.id
        self.autoZoomSensitivity = autoZoomSensitivity
        self.zoomEasing = zoomEasing
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case trimIn
        case trimOut
        case zoomRanges
        case canvas
        case cursorSprites
        case keyboardOverlay
        case stylePresetID
        case autoZoomSensitivity
        case zoomEasing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        trimIn = try container.decodeIfPresent(TimeInterval.self, forKey: .trimIn) ?? 0
        trimOut = try container.decodeIfPresent(TimeInterval.self, forKey: .trimOut)
        zoomRanges = try container.decodeIfPresent([ZoomRange].self, forKey: .zoomRanges) ?? []
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? .default
        cursorSprites = try container.decodeIfPresent([CursorSprite].self, forKey: .cursorSprites) ?? []
        keyboardOverlay = try container.decodeIfPresent(
            KeyboardOverlaySettings.self,
            forKey: .keyboardOverlay
        ) ?? .disabled
        stylePresetID = try container.decodeIfPresent(String.self, forKey: .stylePresetID)
        autoZoomSensitivity = (try? container.decode(
            AutoZoomSensitivity.self,
            forKey: .autoZoomSensitivity
        )) ?? .normal
        zoomEasing = (try? container.decode(ZoomEasingPreset.self, forKey: .zoomEasing))
            ?? .smooth
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(trimIn, forKey: .trimIn)
        try container.encodeIfPresent(trimOut, forKey: .trimOut)
        try container.encode(zoomRanges, forKey: .zoomRanges)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(cursorSprites, forKey: .cursorSprites)
        try container.encode(keyboardOverlay, forKey: .keyboardOverlay)
        try container.encodeIfPresent(stylePresetID, forKey: .stylePresetID)
        try container.encode(autoZoomSensitivity, forKey: .autoZoomSensitivity)
        try container.encode(zoomEasing, forKey: .zoomEasing)
    }

    /// Opening a legacy project is read-only. Write paths call this helper so
    /// the first real save performs the v2 migration without downgrading a
    /// document created by a newer OpenRecord version.
    public func upgradedForSave() -> ProjectDocument {
        var value = self
        value.formatVersion = max(value.formatVersion, Self.currentFormatVersion)
        value.keyboardOverlay = value.keyboardOverlay.normalized
        if value.stylePresetID == nil {
            value.stylePresetID = CanvasPreset.matching(value.canvas)?.id
        }
        return value
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
