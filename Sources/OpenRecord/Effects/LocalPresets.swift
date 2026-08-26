import Foundation

public struct AnnotationStylePreset: Codable, Sendable, Hashable {
    public var color: RGBAColor
    public var background: RGBAColor
    public var fontSize: Double
    public var dimAmount: Double

    public init(
        color: RGBAColor = RGBAColor(r: 1, g: 0.25, b: 0.16),
        background: RGBAColor = RGBAColor(r: 0.03, g: 0.03, b: 0.04, a: 0.88),
        fontSize: Double = 42,
        dimAmount: Double = 0.58
    ) {
        self.color = color
        self.background = background
        self.fontSize = fontSize
        self.dimAmount = dimAmount
    }

    public init(annotation: Annotation) {
        self.init(
            color: annotation.color,
            background: annotation.background,
            fontSize: annotation.fontSize,
            dimAmount: annotation.dimAmount
        )
    }

    public func apply(to annotation: inout Annotation) {
        annotation.color = color
        annotation.background = background
        annotation.fontSize = fontSize
        annotation.dimAmount = dimAmount
        annotation = annotation.normalized
    }
}

public struct CursorStylePreset: Codable, Sendable, Hashable {
    public var scale: Double
    public var clickEmphasis: Bool
    public var halo: Bool
    public var motionBlur: CursorMotionBlurSettings

    public init(
        scale: Double = CanvasSettings.default.cursorScale,
        clickEmphasis: Bool = true,
        halo: Bool = false,
        motionBlur: CursorMotionBlurSettings = .default
    ) {
        self.scale = scale
        self.clickEmphasis = clickEmphasis
        self.halo = halo
        self.motionBlur = motionBlur
    }

    public var normalized: CursorStylePreset {
        var value = self
        value.scale = value.scale.isFinite
            ? min(max(value.scale, CanvasSettings.cursorScaleRange.lowerBound),
                  CanvasSettings.cursorScaleRange.upperBound)
            : CanvasSettings.default.cursorScale
        value.motionBlur = value.motionBlur.normalized
        return value
    }
}

/// A documented, portable JSON style preset. Every payload is optional so a
/// preset may address one family without unexpectedly changing the rest of a
/// project. `ProjectDocument.appliedPresetIDs` records provenance only; the
/// concrete values are copied into the project for portability.
public struct EditorStylePreset: Codable, Sendable, Hashable, Identifiable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    public var name: String
    public var caption: CaptionStyle?
    public var webcam: WebcamOverlaySettings?
    public var annotation: AnnotationStylePreset?
    public var cursor: CursorStylePreset?
    public var export: VideoExportSettings?

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        id: String,
        name: String,
        caption: CaptionStyle? = nil,
        webcam: WebcamOverlaySettings? = nil,
        annotation: AnnotationStylePreset? = nil,
        cursor: CursorStylePreset? = nil,
        export: VideoExportSettings? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.caption = caption
        self.webcam = webcam
        self.annotation = annotation
        self.cursor = cursor
        self.export = export
    }

    public static let tutorial = EditorStylePreset(
        id: "tutorial",
        name: "Tutorial",
        caption: .default,
        annotation: AnnotationStylePreset(),
        cursor: CursorStylePreset(scale: 0.65, clickEmphasis: true, halo: true),
        export: .default
    )

    public static let cleanDemo = EditorStylePreset(
        id: "clean-demo",
        name: "Clean Demo",
        caption: CaptionStyle(
            fontSize: 40,
            foreground: RGBAColor(r: 1, g: 1, b: 1),
            background: RGBAColor(r: 0.02, g: 0.02, b: 0.03, a: 0.76),
            position: .bottom,
            maxWidth: 0.72
        ),
        cursor: CursorStylePreset(scale: 0.5, clickEmphasis: true, halo: false),
        export: VideoExportSettings(codec: .hevc, resolution: .p1080)
    )

    public static let builtIns = [tutorial, cleanDemo]

    public func applying(to document: ProjectDocument) -> ProjectDocument {
        var value = document
        if let caption {
            value.captions = value.captions.map {
                var cue = $0
                cue.style = caption.normalized
                return cue
            }
        }
        if let webcam {
            value.webcamOverlay = webcam.normalized
        }
        if let annotation {
            value.annotations = value.annotations.map {
                var item = $0
                annotation.apply(to: &item)
                return item
            }
        }
        if let cursor {
            let cursor = cursor.normalized
            value.canvas.cursorScale = cursor.scale
            value.canvas.cursorMotionBlur = cursor.motionBlur
            value.canvas.cursorClickEmphasis = cursor.clickEmphasis
            value.canvas.cursorHalo = cursor.halo
            value.cursorEffects = value.cursorEffects.map {
                var effect = $0
                effect.scale = cursor.scale
                effect.clickEmphasis = cursor.clickEmphasis
                effect.halo = cursor.halo
                return effect.normalized
            }
        }
        if let export {
            value.videoExportSettings = export
        }
        value.appliedPresetIDs.removeAll { $0 == id }
        value.appliedPresetIDs.append(id)
        return value
    }
}

public struct LocalPresetStore {
    public let directoryURL: URL
    public let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> LocalPresetStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return LocalPresetStore(
            directoryURL: root
                .appendingPathComponent("OpenRecord", isDirectory: true)
                .appendingPathComponent("Presets", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func load() throws -> [EditorStylePreset] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let preset = try? ProjectJSON.decoder.decode(EditorStylePreset.self, from: data),
                  preset.formatVersion <= EditorStylePreset.currentFormatVersion
            else { return nil }
            return preset
        }
        .sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) != .orderedSame {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.id < $1.id
        }
    }

    @discardableResult
    public func save(_ preset: EditorStylePreset) throws -> URL {
        let safeID = Self.safeFilename(preset.id)
        guard !safeID.isEmpty else {
            throw OpenRecordError.io("Preset ID must contain at least one letter or number.")
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("\(safeID).json", isDirectory: false)
        let data = try ProjectJSON.encoder.encode(preset)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
