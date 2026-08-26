import Foundation

/// A portable, media-free starting point for a project.
///
/// A template intentionally contains presentation settings only. It never
/// serializes a project document, capture URL, or source-timed item, so it is
/// safe to copy between machines and apply to recordings with different
/// durations and edit histories.
public struct ProjectTemplate: Codable, Sendable, Hashable, Identifiable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "openrecordtemplate"
    public static let templateExtension = fileExtension

    public var formatVersion: Int
    public var id: String
    public var name: String
    public var createdAt: Date
    public var canvas: CanvasSettings
    public var aspect: CanvasAspectPreset
    public var cursor: CursorStylePreset
    public var webcam: WebcamOverlaySettings
    public var caption: CaptionStyle
    public var export: VideoExportSettings
    public var annotation: AnnotationStylePreset?
    public var deviceFrame: DeviceFrameSettings
    public var keyboardOverlay: KeyboardOverlaySettings

    // Descriptive aliases keep the wire model concise while making the API
    // discoverable alongside the corresponding ProjectDocument properties.
    public var captionStyle: CaptionStyle {
        get { caption }
        set { caption = newValue }
    }

    public var annotationStyle: AnnotationStylePreset? {
        get { annotation }
        set { annotation = newValue }
    }

    public var videoExportSettings: VideoExportSettings {
        get { export }
        set { export = newValue }
    }

    public var webcamOverlay: WebcamOverlaySettings {
        get { webcam }
        set { webcam = newValue }
    }

    public var deviceFrameSettings: DeviceFrameSettings {
        get { deviceFrame }
        set { deviceFrame = newValue }
    }

    public var keyboardOverlaySettings: KeyboardOverlaySettings {
        get { keyboardOverlay }
        set { keyboardOverlay = newValue }
    }

    public static let tutorial = ProjectTemplate(
        id: "built-in-tutorial",
        name: "Tutorial",
        createdAt: Date(timeIntervalSince1970: 0),
        canvas: CanvasSettings(
            background: CanvasPreset.dark.background,
            padding: 64,
            cornerRadius: 20,
            cursorScale: 0.7,
            cursorClickEmphasis: true,
            cursorHalo: true
        ),
        cursor: CursorStylePreset(scale: 0.7, clickEmphasis: true, halo: true),
        caption: CaptionStyle(fontSize: 46),
        export: VideoExportSettings(codec: .h264, resolution: .p1080),
        annotation: AnnotationStylePreset(fontSize: 44)
    )

    public static let portraitDemo = ProjectTemplate(
        id: "built-in-portrait-demo",
        name: "Portrait Demo",
        createdAt: Date(timeIntervalSince1970: 0),
        canvas: CanvasSettings(
            background: CanvasPreset.light.background,
            padding: 52,
            cornerRadius: 18,
            cursorScale: 0.65,
            aspectWidth: 9,
            aspectHeight: 16,
            cursorClickEmphasis: true,
            cursorHalo: false
        ),
        aspect: .portrait,
        cursor: CursorStylePreset(scale: 0.65, clickEmphasis: true, halo: false),
        caption: CaptionStyle(fontSize: 52, maxWidth: 0.82),
        export: VideoExportSettings(codec: .hevc, resolution: .p1080),
        annotation: AnnotationStylePreset(fontSize: 48)
    )

    public static let builtIns: [ProjectTemplate] = [tutorial, portraitDemo]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        id: String,
        name: String,
        createdAt: Date = Date(),
        canvas: CanvasSettings = .default,
        aspect: CanvasAspectPreset? = nil,
        cursor: CursorStylePreset? = nil,
        webcam: WebcamOverlaySettings = .disabled,
        caption: CaptionStyle = .default,
        export: VideoExportSettings = .default,
        annotation: AnnotationStylePreset? = nil,
        deviceFrame: DeviceFrameSettings = .none,
        keyboardOverlay: KeyboardOverlaySettings = .disabled
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.canvas = canvas
        self.aspect = aspect
            ?? CanvasAspectPreset.matching(
                aspectWidth: canvas.aspectWidth,
                aspectHeight: canvas.aspectHeight
            )
            ?? .widescreen
        self.cursor = cursor ?? CursorStylePreset(
            scale: canvas.cursorScale,
            clickEmphasis: canvas.cursorClickEmphasis,
            halo: canvas.cursorHalo,
            motionBlur: canvas.cursorMotionBlur
        )
        self.webcam = webcam
        self.caption = caption
        self.export = export
        self.annotation = annotation
        self.deviceFrame = deviceFrame
        self.keyboardOverlay = keyboardOverlay
    }

    /// Label-rich initializer for callers using the names from
    /// `ProjectDocument`. The required caption label avoids ambiguity with
    /// the compact initializer when no optional settings are supplied.
    public init(
        id: String,
        name: String,
        createdAt: Date = Date(),
        canvas: CanvasSettings = .default,
        aspect: CanvasAspectPreset? = nil,
        cursor: CursorStylePreset? = nil,
        webcamOverlay: WebcamOverlaySettings = .disabled,
        captionStyle: CaptionStyle,
        videoExportSettings: VideoExportSettings = .default,
        annotationStyle: AnnotationStylePreset? = nil,
        deviceFrameSettings: DeviceFrameSettings = .none,
        keyboardOverlaySettings: KeyboardOverlaySettings = .disabled
    ) {
        self.init(
            id: id,
            name: name,
            createdAt: createdAt,
            canvas: canvas,
            aspect: aspect,
            cursor: cursor,
            webcam: webcamOverlay,
            caption: captionStyle,
            export: videoExportSettings,
            annotation: annotationStyle,
            deviceFrame: deviceFrameSettings,
            keyboardOverlay: keyboardOverlaySettings
        )
    }

    /// Creates a template from the document's presentation settings. Only
    /// concrete style values are copied; media and all timed/content arrays
    /// are deliberately omitted.
    public init(
        id: String,
        name: String,
        createdAt: Date = Date(),
        document: ProjectDocument
    ) {
        self.init(
            id: id,
            name: name,
            createdAt: createdAt,
            canvas: document.canvas,
            aspect: CanvasAspectPreset.matching(
                aspectWidth: document.canvas.aspectWidth,
                aspectHeight: document.canvas.aspectHeight
            ),
            cursor: CursorStylePreset(
                scale: document.canvas.cursorScale,
                clickEmphasis: document.canvas.cursorClickEmphasis,
                halo: document.canvas.cursorHalo,
                motionBlur: document.canvas.cursorMotionBlur
            ),
            webcam: document.webcamOverlay,
            caption: document.defaultCaptionStyle,
            export: document.videoExportSettings,
            annotation: document.defaultAnnotationStyle
                ?? document.annotations.first.map(AnnotationStylePreset.init),
            deviceFrame: document.deviceFrame,
            keyboardOverlay: document.keyboardOverlay
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case id
        case name
        case createdAt
        case canvas
        case aspect
        case cursor
        case webcam
        case caption
        case export
        case annotation
        case deviceFrame
        case keyboardOverlay
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard formatVersion <= Self.currentFormatVersion else {
            throw OpenRecordError.io(
                "This template uses format version \(formatVersion), but this version of OpenRecord supports up to version \(Self.currentFormatVersion). Update OpenRecord before importing it."
            )
        }
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let supportedFields = Set(CodingKeys.allCases.map(\.rawValue))
        let unknownFields = allFields.allKeys
            .map(\.stringValue)
            .filter { !supportedFields.contains($0) }
            .sorted()
        guard unknownFields.isEmpty else {
            throw OpenRecordError.io(
                "This template contains unsupported fields: "
                    + unknownFields.joined(separator: ", ")
                    + ". Update OpenRecord before importing it."
            )
        }
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        canvas = try container.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? .default
        if let rawAspect = try container.decodeIfPresent(String.self, forKey: .aspect),
           let decodedAspect = CanvasAspectPreset(rawValue: rawAspect) {
            aspect = decodedAspect
        } else {
            aspect = CanvasAspectPreset.matching(
                aspectWidth: canvas.aspectWidth,
                aspectHeight: canvas.aspectHeight
            ) ?? .widescreen
        }
        cursor = try container.decodeIfPresent(CursorStylePreset.self, forKey: .cursor)
            ?? CursorStylePreset(
                scale: canvas.cursorScale,
                clickEmphasis: canvas.cursorClickEmphasis,
                halo: canvas.cursorHalo,
                motionBlur: canvas.cursorMotionBlur
            )
        webcam = try container.decodeIfPresent(WebcamOverlaySettings.self, forKey: .webcam)
            ?? .disabled
        caption = try container.decodeIfPresent(CaptionStyle.self, forKey: .caption)
            ?? .default
        export = try container.decodeIfPresent(VideoExportSettings.self, forKey: .export)
            ?? .default
        annotation = try container.decodeIfPresent(
            AnnotationStylePreset.self,
            forKey: .annotation
        )
        deviceFrame = try container.decodeIfPresent(DeviceFrameSettings.self, forKey: .deviceFrame)
            ?? .none
        keyboardOverlay = try container.decodeIfPresent(
            KeyboardOverlaySettings.self,
            forKey: .keyboardOverlay
        ) ?? .disabled
    }

    /// Applies presentation values while leaving source media, timing,
    /// transcript, edit decisions, and other authored content untouched.
    public func applying(to document: ProjectDocument) -> ProjectDocument {
        var value = document
        value.canvas = canvas
        aspect.apply(to: &value.canvas)

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

        value.webcamOverlay = webcam.normalized
        let caption = caption.normalized
        value.captions = value.captions.map {
            var cue = $0
            cue.style = caption
            return cue
        }
        value.videoExportSettings = export
        value.deviceFrame = deviceFrame.normalized
        value.keyboardOverlay = keyboardOverlay.normalized
        value.projectTemplateID = id
        value.defaultCaptionStyle = caption
        value.defaultAnnotationStyle = annotation

        if let annotation {
            value.annotations = value.annotations.map {
                var item = $0
                annotation.apply(to: &item)
                return item
            }
        }

        // Keep the same provenance convention as editor style presets while
        // retaining all content and edit decisions in the document.
        value.appliedPresetIDs.removeAll { $0 == id }
        value.appliedPresetIDs.append(id)
        return value
    }

    /// Alias useful to callers that treat templates as transformations.
    public func apply(to document: ProjectDocument) -> ProjectDocument {
        applying(to: document)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(aspect.rawValue, forKey: .aspect)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(webcam, forKey: .webcam)
        try container.encode(caption, forKey: .caption)
        try container.encode(export, forKey: .export)
        try container.encodeIfPresent(annotation, forKey: .annotation)
        try container.encode(deviceFrame, forKey: .deviceFrame)
        try container.encode(keyboardOverlay, forKey: .keyboardOverlay)
    }
}

/// A local collection of `.openrecordtemplate` files.
public struct LocalProjectTemplateStore {
    public let directoryURL: URL
    public let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.init(directoryURL: rootURL, fileManager: fileManager)
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> LocalProjectTemplateStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return LocalProjectTemplateStore(
            directoryURL: root
                .appendingPathComponent("OpenRecord", isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Loads valid current-or-older templates. A malformed or future file is
    /// ignored so one stray synced file cannot hide the usable collection.
    public func load() throws -> [ProjectTemplate] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == ProjectTemplate.fileExtension }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let template = try? ProjectJSON.decoder.decode(ProjectTemplate.self, from: data),
                  template.formatVersion <= ProjectTemplate.currentFormatVersion
            else { return nil }
            return template
        }
        .sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }

    @discardableResult
    public func save(_ template: ProjectTemplate) throws -> URL {
        guard template.formatVersion <= ProjectTemplate.currentFormatVersion else {
            throw OpenRecordError.io(
                "This template uses format version \(template.formatVersion), but this version of OpenRecord supports up to version \(ProjectTemplate.currentFormatVersion). Update OpenRecord before saving it."
            )
        }
        let safeID = Self.safeFilename(template.id)
        guard !safeID.isEmpty else {
            throw OpenRecordError.io("Template ID must contain at least one letter or number.")
        }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw OpenRecordError.io(
                "Could not create template folder: \(error.localizedDescription)"
            )
        }
        let url = directoryURL.appendingPathComponent(
            "\(safeID).\(ProjectTemplate.fileExtension)",
            isDirectory: false
        )
        do {
            let data = try ProjectJSON.encoder.encode(template)
            try AtomicFileWrite.write(data, to: url)
        } catch let error as OpenRecordError {
            throw error
        } catch {
            throw OpenRecordError.io(
                "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        return url
    }

    /// Imports a standalone template and installs it in this store.
    @discardableResult
    public func `import`(from sourceURL: URL) throws -> ProjectTemplate {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw OpenRecordError.io("Missing or unreadable template file.")
        }
        let template: ProjectTemplate
        do {
            template = try ProjectJSON.decoder.decode(ProjectTemplate.self, from: data)
        } catch let error as OpenRecordError {
            throw error
        } catch {
            throw OpenRecordError.io(
                "Invalid \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
        _ = try save(template)
        return template
    }

    /// Exports a template to a standalone file or into an existing directory.
    @discardableResult
    public func export(_ template: ProjectTemplate, to destinationURL: URL) throws -> URL {
        let destination: URL
        var isDirectory: ObjCBool = false
        let existsAsDirectory = fileManager.fileExists(
            atPath: destinationURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        if existsAsDirectory || destinationURL.hasDirectoryPath {
            let safeID = Self.safeFilename(template.id)
            guard !safeID.isEmpty else {
                throw OpenRecordError.io("Template ID must contain at least one letter or number.")
            }
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true
            )
            destination = destinationURL.appendingPathComponent(
                "\(safeID).\(ProjectTemplate.fileExtension)",
                isDirectory: false
            )
        } else {
            destination = destinationURL
        }
        do {
            let data = try ProjectJSON.encoder.encode(template)
            try AtomicFileWrite.write(data, to: destination)
        } catch let error as OpenRecordError {
            throw error
        } catch {
            throw OpenRecordError.io(
                "Could not export \(destination.lastPathComponent): \(error.localizedDescription)"
            )
        }
        return destination
    }

    @discardableResult
    public func importTemplate(from sourceURL: URL) throws -> ProjectTemplate {
        try `import`(from: sourceURL)
    }

    @discardableResult
    public func exportTemplate(_ template: ProjectTemplate, to destinationURL: URL) throws -> URL {
        try export(template, to: destinationURL)
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
