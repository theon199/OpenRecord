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

public struct CursorMotionBlurSettings: Codable, Sendable, Hashable {
    public static let amountRange = 0.0...1.0

    public var enabled: Bool
    public var amount: Double

    public init(enabled: Bool = true, amount: Double = 0.6) {
        self.enabled = enabled
        self.amount = amount
    }

    public static let `default` = CursorMotionBlurSettings()
    public static let disabled = CursorMotionBlurSettings(enabled: false)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case amount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        amount = (try? container.decode(Double.self, forKey: .amount)) ?? 0.6
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(amount, forKey: .amount)
    }

    public var normalized: CursorMotionBlurSettings {
        var value = self
        value.amount = min(max(value.amount, Self.amountRange.lowerBound), Self.amountRange.upperBound)
        return value
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
    public var cursorMotionBlur: CursorMotionBlurSettings

    public init(
        background: CanvasBackground = .solid(.canvasDefault),
        padding: Double = 48,
        cornerRadius: Double = 16,
        cursorScale: Double = 0.5,
        aspectWidth: Double = 16,
        aspectHeight: Double = 9,
        cursorMotionBlur: CursorMotionBlurSettings = .default
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.cursorScale = cursorScale
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.cursorMotionBlur = cursorMotionBlur
    }

    public static let `default` = CanvasSettings()
    public static let legacyDefault = CanvasSettings(cursorMotionBlur: .disabled)

    private enum CodingKeys: String, CodingKey {
        case background
        case padding
        case cornerRadius
        case cursorScale
        case aspectWidth
        case aspectHeight
        case cursorMotionBlur
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = try container.decodeIfPresent(CanvasBackground.self, forKey: .background)
            ?? .solid(.canvasDefault)
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 48
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 16
        cursorScale = try container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? 0.5
        aspectWidth = try container.decodeIfPresent(Double.self, forKey: .aspectWidth) ?? 16
        aspectHeight = try container.decodeIfPresent(Double.self, forKey: .aspectHeight) ?? 9
        cursorMotionBlur = (try? container.decode(
            CursorMotionBlurSettings.self,
            forKey: .cursorMotionBlur
        )) ?? .disabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(background, forKey: .background)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(cursorScale, forKey: .cursorScale)
        try container.encode(aspectWidth, forKey: .aspectWidth)
        try container.encode(aspectHeight, forKey: .aspectHeight)
        try container.encode(cursorMotionBlur, forKey: .cursorMotionBlur)
    }
}

/// A reusable visual treatment for the canvas framing around a recording.
/// Applying a preset intentionally preserves output aspect ratio and cursor
/// scale/effects because those are independent format and accessibility choices.
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
    /// Camera selected for the optional picture-in-picture track.
    public var webcam: WebcamCaptureInfo?

    public init(
        createdAt: Date = Date(),
        appVersion: String = OpenRecordInfo.appVersion,
        displayBounds: Rect2D,
        scale: Double,
        captureTarget: CaptureTarget,
        captureTiming: CaptureTiming? = nil,
        captureHealth: CaptureHealth? = nil,
        webcam: WebcamCaptureInfo? = nil
    ) {
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.displayBounds = displayBounds
        self.scale = scale
        self.captureTarget = captureTarget
        self.captureTiming = captureTiming
        self.captureHealth = captureHealth
        self.webcam = webcam
    }
}

public struct WebcamCaptureInfo: Codable, Sendable, Hashable {
    public var deviceID: String
    public var mirror: Bool

    public init(deviceID: String, mirror: Bool = true) {
        self.deviceID = deviceID
        self.mirror = mirror
    }
}

public struct CaptureTiming: Codable, Sendable, Hashable {
    public var systemAudioOffset: TimeInterval?
    public var microphoneOffset: TimeInterval?
    public var webcamOffset: TimeInterval?

    public init(
        systemAudioOffset: TimeInterval? = nil,
        microphoneOffset: TimeInterval? = nil,
        webcamOffset: TimeInterval? = nil
    ) {
        self.systemAudioOffset = systemAudioOffset
        self.microphoneOffset = microphoneOffset
        self.webcamOffset = webcamOffset
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
    case missingWebcam
    case truncatedWebcam
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

public enum WebcamOverlayShape: String, Codable, CaseIterable, Sendable, Hashable {
    case circle
    case roundedRectangle = "rounded-rectangle"
}

public struct WebcamOverlaySettings: Codable, Sendable, Hashable {
    public static let sizeRange = 0.08...0.4
    public static let borderWidthRange = 0.0...12.0

    public var enabled: Bool
    public var shape: WebcamOverlayShape
    /// Normalized center position in canvas space, origin top-left.
    public var position: Point2D
    /// Diameter/height relative to the canvas's shorter edge.
    public var size: Double
    public var borderWidth: Double
    public var shadow: Bool

    public init(
        enabled: Bool = false,
        shape: WebcamOverlayShape = .circle,
        position: Point2D = Point2D(x: 0.85, y: 0.82),
        size: Double = 0.18,
        borderWidth: Double = 3,
        shadow: Bool = true
    ) {
        self.enabled = enabled
        self.shape = shape
        self.position = position
        self.size = size
        self.borderWidth = borderWidth
        self.shadow = shadow
    }

    public static let disabled = WebcamOverlaySettings()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case shape
        case position
        case size
        case borderWidth
        case shadow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        shape = (try? container.decode(WebcamOverlayShape.self, forKey: .shape)) ?? .circle
        position = try container.decodeIfPresent(Point2D.self, forKey: .position)
            ?? Point2D(x: 0.85, y: 0.82)
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? 0.18
        borderWidth = try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 3
        shadow = try container.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(shape, forKey: .shape)
        try container.encode(position, forKey: .position)
        try container.encode(size, forKey: .size)
        try container.encode(borderWidth, forKey: .borderWidth)
        try container.encode(shadow, forKey: .shadow)
    }

    public var normalized: WebcamOverlaySettings {
        var value = self
        value.position.x = min(max(value.position.x, 0), 1)
        value.position.y = min(max(value.position.y, 0), 1)
        value.size = min(max(value.size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        value.borderWidth = min(
            max(value.borderWidth, Self.borderWidthRange.lowerBound),
            Self.borderWidthRange.upperBound
        )
        return value
    }
}

public struct SpeedSegment: Codable, Sendable, Hashable, Identifiable {
    public static let rateRange = 0.25...4.0

    public var id: UUID
    /// Source-timeline seconds, before speed remapping.
    public var start: TimeInterval
    public var end: TimeInterval
    public var rate: Double

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        rate: Double = 2
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.rate = rate
    }

    public var normalized: SpeedSegment {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start) : value.start
        value.rate = value.rate.isFinite
            ? min(max(value.rate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
            : 1
        return value
    }
}

public struct AudioCleanupSettings: Codable, Sendable, Hashable {
    public static let gainRange = 0.0...2.0
    public static let noiseGateThresholdRange = -60.0 ... -20.0

    public var microphoneGain: Double
    public var systemGain: Double
    public var noiseGateEnabled: Bool
    public var noiseGateThresholdDB: Double
    public var normalizeEnabled: Bool
    public var deClickEnabled: Bool

    public init(
        microphoneGain: Double = 1,
        systemGain: Double = 1,
        noiseGateEnabled: Bool = false,
        noiseGateThresholdDB: Double = -42,
        normalizeEnabled: Bool = false,
        deClickEnabled: Bool = false
    ) {
        self.microphoneGain = microphoneGain
        self.systemGain = systemGain
        self.noiseGateEnabled = noiseGateEnabled
        self.noiseGateThresholdDB = noiseGateThresholdDB
        self.normalizeEnabled = normalizeEnabled
        self.deClickEnabled = deClickEnabled
    }

    public static let `default` = AudioCleanupSettings()

    private enum CodingKeys: String, CodingKey {
        case microphoneGain
        case systemGain
        case noiseGateEnabled
        case noiseGateThresholdDB
        case normalizeEnabled
        case deClickEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphoneGain = (try? container.decode(Double.self, forKey: .microphoneGain)) ?? 1
        systemGain = (try? container.decode(Double.self, forKey: .systemGain)) ?? 1
        noiseGateEnabled = (try? container.decode(Bool.self, forKey: .noiseGateEnabled)) ?? false
        noiseGateThresholdDB = (try? container.decode(
            Double.self,
            forKey: .noiseGateThresholdDB
        )) ?? -42
        normalizeEnabled = (try? container.decode(Bool.self, forKey: .normalizeEnabled)) ?? false
        deClickEnabled = (try? container.decode(Bool.self, forKey: .deClickEnabled)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(microphoneGain, forKey: .microphoneGain)
        try container.encode(systemGain, forKey: .systemGain)
        try container.encode(noiseGateEnabled, forKey: .noiseGateEnabled)
        try container.encode(noiseGateThresholdDB, forKey: .noiseGateThresholdDB)
        try container.encode(normalizeEnabled, forKey: .normalizeEnabled)
        try container.encode(deClickEnabled, forKey: .deClickEnabled)
    }

    public var normalized: AudioCleanupSettings {
        var value = self
        value.microphoneGain = Self.clampGain(value.microphoneGain)
        value.systemGain = Self.clampGain(value.systemGain)
        value.noiseGateThresholdDB = value.noiseGateThresholdDB.isFinite
            ? min(
                max(value.noiseGateThresholdDB, Self.noiseGateThresholdRange.lowerBound),
                Self.noiseGateThresholdRange.upperBound
            )
            : -42
        return value
    }

    private static func clampGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 1 }
        return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }
}

public struct ProjectDocument: Codable, Sendable, Hashable {
    public static let currentFormatVersion = 3

    public var formatVersion: Int
    public var trimIn: TimeInterval
    public var trimOut: TimeInterval?
    public var zoomRanges: [ZoomRange]
    public var canvas: CanvasSettings
    public var cursorSprites: [CursorSprite]
    public var keyboardOverlay: KeyboardOverlaySettings
    public var webcamOverlay: WebcamOverlaySettings
    public var stylePresetID: String?
    public var autoZoomSensitivity: AutoZoomSensitivity
    public var zoomEasing: ZoomEasingPreset
    public var speedSegments: [SpeedSegment]
    public var muteAudioWhenSpedUp: Bool
    public var audioCleanup: AudioCleanupSettings
    public var captions: [CaptionCue]
    public var annotations: [Annotation]
    public var videoExportSettings: VideoExportSettings

    public init(
        formatVersion: Int = ProjectDocument.currentFormatVersion,
        trimIn: TimeInterval = 0,
        trimOut: TimeInterval? = nil,
        zoomRanges: [ZoomRange] = [],
        canvas: CanvasSettings = .default,
        cursorSprites: [CursorSprite] = [],
        keyboardOverlay: KeyboardOverlaySettings = .disabled,
        webcamOverlay: WebcamOverlaySettings = .disabled,
        stylePresetID: String? = nil,
        autoZoomSensitivity: AutoZoomSensitivity = .normal,
        zoomEasing: ZoomEasingPreset = .smooth,
        speedSegments: [SpeedSegment] = [],
        muteAudioWhenSpedUp: Bool = false,
        audioCleanup: AudioCleanupSettings = .default,
        captions: [CaptionCue] = [],
        annotations: [Annotation] = [],
        videoExportSettings: VideoExportSettings = .default
    ) {
        self.formatVersion = formatVersion
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.zoomRanges = zoomRanges
        self.canvas = canvas
        self.cursorSprites = cursorSprites
        self.keyboardOverlay = keyboardOverlay
        self.webcamOverlay = webcamOverlay
        self.stylePresetID = stylePresetID ?? CanvasPreset.matching(canvas)?.id
        self.autoZoomSensitivity = autoZoomSensitivity
        self.zoomEasing = zoomEasing
        self.speedSegments = speedSegments
        self.muteAudioWhenSpedUp = muteAudioWhenSpedUp
        self.audioCleanup = audioCleanup
        self.captions = captions
        self.annotations = annotations
        self.videoExportSettings = videoExportSettings
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case trimIn
        case trimOut
        case zoomRanges
        case canvas
        case cursorSprites
        case keyboardOverlay
        case webcamOverlay
        case stylePresetID
        case autoZoomSensitivity
        case zoomEasing
        case speedSegments
        case muteAudioWhenSpedUp
        case audioCleanup
        case captions
        case annotations
        case videoExportSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard formatVersion <= Self.currentFormatVersion else {
            throw OpenRecordError.io(
                "This project uses format version \(formatVersion), but this version of OpenRecord supports up to version \(Self.currentFormatVersion). Update OpenRecord before opening it."
            )
        }
        trimIn = try container.decodeIfPresent(TimeInterval.self, forKey: .trimIn) ?? 0
        trimOut = try container.decodeIfPresent(TimeInterval.self, forKey: .trimOut)
        zoomRanges = try container.decodeIfPresent([ZoomRange].self, forKey: .zoomRanges) ?? []
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? .legacyDefault
        cursorSprites = try container.decodeIfPresent([CursorSprite].self, forKey: .cursorSprites) ?? []
        keyboardOverlay = try container.decodeIfPresent(
            KeyboardOverlaySettings.self,
            forKey: .keyboardOverlay
        ) ?? .disabled
        webcamOverlay = (try? container.decode(
            WebcamOverlaySettings.self,
            forKey: .webcamOverlay
        )) ?? .disabled
        stylePresetID = try container.decodeIfPresent(String.self, forKey: .stylePresetID)
        autoZoomSensitivity = (try? container.decode(
            AutoZoomSensitivity.self,
            forKey: .autoZoomSensitivity
        )) ?? .normal
        zoomEasing = (try? container.decode(ZoomEasingPreset.self, forKey: .zoomEasing))
            ?? .smooth
        speedSegments = (try? container.decode([SpeedSegment].self, forKey: .speedSegments)) ?? []
        muteAudioWhenSpedUp = (try? container.decode(
            Bool.self,
            forKey: .muteAudioWhenSpedUp
        )) ?? false
        audioCleanup = (try? container.decode(
            AudioCleanupSettings.self,
            forKey: .audioCleanup
        )) ?? .default
        captions = (try? container.decode([CaptionCue].self, forKey: .captions)) ?? []
        annotations = (try? container.decode([Annotation].self, forKey: .annotations)) ?? []
        videoExportSettings = (try? container.decode(
            VideoExportSettings.self,
            forKey: .videoExportSettings
        )) ?? .default
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
        try container.encode(webcamOverlay, forKey: .webcamOverlay)
        try container.encodeIfPresent(stylePresetID, forKey: .stylePresetID)
        try container.encode(autoZoomSensitivity, forKey: .autoZoomSensitivity)
        try container.encode(zoomEasing, forKey: .zoomEasing)
        try container.encode(speedSegments, forKey: .speedSegments)
        try container.encode(muteAudioWhenSpedUp, forKey: .muteAudioWhenSpedUp)
        try container.encode(audioCleanup, forKey: .audioCleanup)
        try container.encode(captions, forKey: .captions)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(videoExportSettings, forKey: .videoExportSettings)
    }

    /// Opening a legacy project is read-only. Supported write paths call this
    /// helper so the first real save performs the latest migration. They must
    /// call `validatedForSave()` before encoding to reject newer schemas.
    public func upgradedForSave() -> ProjectDocument {
        var value = self
        value.formatVersion = max(value.formatVersion, Self.currentFormatVersion)
        value.keyboardOverlay = value.keyboardOverlay.normalized
        value.webcamOverlay = value.webcamOverlay.normalized
        value.canvas.cursorMotionBlur = value.canvas.cursorMotionBlur.normalized
        value.speedSegments = SpeedTimeline.normalizedSegments(value.speedSegments)
        value.audioCleanup = value.audioCleanup.normalized
        value.captions = value.captions.map(\.normalized).sorted { $0.start < $1.start }
        value.annotations = value.annotations.map(\.normalized).sorted { $0.start < $1.start }
        if value.stylePresetID == nil {
            value.stylePresetID = CanvasPreset.matching(value.canvas)?.id
        }
        return value
    }

    /// Write paths reject documents created by newer OpenRecord versions so
    /// unknown future fields can never be silently discarded by this schema.
    public func validatedForSave() throws -> ProjectDocument {
        guard formatVersion <= Self.currentFormatVersion else {
            throw OpenRecordError.io(
                "Project format version \(formatVersion) is newer than the supported version \(Self.currentFormatVersion). Update OpenRecord before saving this project."
            )
        }
        return upgradedForSave()
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
