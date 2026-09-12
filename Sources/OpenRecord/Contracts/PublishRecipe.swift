import Foundation

/// The output formats understood by the v4.3 release factory.
public enum PublishOutputKind: String, Codable, CaseIterable, Sendable, Hashable {
    case video
    case gif
    case markdown
    case html
    case tutorial
}

/// The four portable canvas ratios supported by a publish recipe. This is a
/// separate wire type because the authored canvas stores ratio components,
/// rather than a persisted preset enum.
public enum PublishAspect: String, Codable, CaseIterable, Sendable, Hashable {
    case widescreen = "16:9"
    case portrait = "9:16"
    case square = "1:1"
    case standard = "4:3"

    public static var landscape: Self { .widescreen }

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
}

/// How captions are delivered for a published output.
public enum PublishCaptionDelivery: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case burnedIn = "burned-in"
    case sidecar
    case both

    /// Compatibility spelling for callers that use the product language.
    public static var burnIn: Self { .burnedIn }
    public static var embedded: Self { .burnedIn }
    public static var external: Self { .sidecar }
}

/// What to do when a generated output already exists.
public enum PublishOverwritePolicy: String, Codable, CaseIterable, Sendable, Hashable {
    case fail
    case replace
    case skip

    /// Compatibility spellings retained as source-level aliases.
    public static var overwrite: Self { .replace }
    public static var error: Self { .fail }
}

/// Controls screenshot assets generated for documentation and tutorial outputs.
public enum PublishScreenshotMode: String, Codable, CaseIterable, Sendable, Hashable {
    case none
    case poster
    case actions

    /// Singular spelling is useful to clients that have one action screenshot.
    public static var action: Self { .actions }
}

/// One output in a `PublishRecipe`.
///
/// Values are deliberately limited to portable identifiers and allowlisted
/// export settings. There is no path, command, account, callback, or service
/// field in this contract.
public struct PublishOutput: Codable, Sendable, Hashable, Identifiable {
    public static let maximumNameLength = 80
    public static let maximumFilenameLength = 120
    public static let maximumSelectorLength = 120
    public static let maximumTemplateIDLength = 120
    public static let maximumDuration: TimeInterval = 3_600

    public var name: String
    public var kind: PublishOutputKind
    public var aspect: PublishAspect
    public var storyBeat: String?
    public var maxDuration: TimeInterval?
    public var templateID: String?
    public var codec: VideoExportCodec?
    public var resolution: ExportResolutionPreset?
    public var quality: VideoExportQualityPreset?
    public var frameRate: VideoExportFrameRate?
    public var captionDelivery: PublishCaptionDelivery
    public var filename: String?
    public var overwrite: PublishOverwritePolicy
    public var screenshots: PublishScreenshotMode
    public var includeTranscript: Bool?
    /// Optional normalized canvas area that responsive overlays must remain in.
    public var safeArea: Rect2D?

    /// Stable identity is the safe output name, not a generated UUID.
    public var id: String { name }

    public init(
        name: String,
        kind: PublishOutputKind,
        aspect: PublishAspect = .widescreen,
        storyBeat: String? = nil,
        maxDuration: TimeInterval? = nil,
        templateID: String? = nil,
        codec: VideoExportCodec? = nil,
        resolution: ExportResolutionPreset? = nil,
        quality: VideoExportQualityPreset? = nil,
        frameRate: VideoExportFrameRate? = nil,
        captionDelivery: PublishCaptionDelivery = .burnedIn,
        filename: String? = nil,
        overwrite: PublishOverwritePolicy = .fail,
        screenshots: PublishScreenshotMode = .none,
        includeTranscript: Bool? = nil,
        safeArea: Rect2D? = nil
    ) {
        self.name = name
        self.kind = kind
        self.aspect = aspect
        self.storyBeat = storyBeat
        self.maxDuration = maxDuration
        self.templateID = templateID
        self.codec = codec
        self.resolution = resolution
        self.quality = quality
        self.frameRate = frameRate
        self.captionDelivery = captionDelivery
        self.filename = filename
        self.overwrite = overwrite
        self.screenshots = screenshots
        self.includeTranscript = includeTranscript
        self.safeArea = safeArea
    }

    /// Source-compatible initializer using the longer product-facing labels.
    public init(
        name: String,
        kind: PublishOutputKind,
        aspect: PublishAspect = .widescreen,
        storyBeatSelector: String? = nil,
        maxDuration: TimeInterval? = nil,
        templateID: String? = nil,
        codec: VideoExportCodec? = nil,
        resolution: ExportResolutionPreset? = nil,
        quality: VideoExportQualityPreset? = nil,
        frameRate: VideoExportFrameRate? = nil,
        captionDelivery: PublishCaptionDelivery = .burnedIn,
        outputFilename: String? = nil,
        overwritePolicy: PublishOverwritePolicy = .fail,
        screenshotMode: PublishScreenshotMode,
        includeTranscript: Bool? = nil,
        safeArea: Rect2D? = nil
    ) {
        self.init(
            name: name,
            kind: kind,
            aspect: aspect,
            storyBeat: storyBeatSelector,
            maxDuration: maxDuration,
            templateID: templateID,
            codec: codec,
            resolution: resolution,
            quality: quality,
            frameRate: frameRate,
            captionDelivery: captionDelivery,
            filename: outputFilename,
            overwrite: overwritePolicy,
            screenshots: screenshotMode,
            includeTranscript: includeTranscript,
            safeArea: safeArea
        )
    }

    /// Product-facing aliases that keep the wire format intentionally small.
    public var storyBeatSelector: String? {
        get { storyBeat }
        set { storyBeat = newValue }
    }

    public var canvasAspect: PublishAspect {
        get { aspect }
        set { aspect = newValue }
    }

    public var overwritePolicy: PublishOverwritePolicy {
        get { overwrite }
        set { overwrite = newValue }
    }

    public var screenshotMode: PublishScreenshotMode {
        get { screenshots }
        set { screenshots = newValue }
    }

    public var outputFilename: String? {
        get { filename }
        set { filename = newValue }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case kind
        case aspect
        case storyBeat
        case storyBeatSelector
        case maxDuration
        case templateID
        case codec
        case resolution
        case quality
        case frameRate
        case captionDelivery
        case filename
        case outputFilename
        case overwrite
        case overwritePolicy
        case screenshots
        case screenshotMode
        case includeTranscript
        case safeArea
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unsupported = allFields.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unsupported.isEmpty else {
            throw OpenRecordError.io(
                "Publish output contains unsupported fields: " + unsupported.joined(separator: ", ")
            )
        }

        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(PublishOutputKind.self, forKey: .kind)
        aspect = try container.decodeIfPresent(PublishAspect.self, forKey: .aspect) ?? .widescreen
        let canonicalStoryBeat = try container.decodeIfPresent(String.self, forKey: .storyBeat)
        let aliasStoryBeat = try container.decodeIfPresent(String.self, forKey: .storyBeatSelector)
        if let canonicalStoryBeat, let aliasStoryBeat, canonicalStoryBeat != aliasStoryBeat {
            throw OpenRecordError.io("Publish output specifies conflicting storyBeat selectors.")
        }
        storyBeat = canonicalStoryBeat ?? aliasStoryBeat
        maxDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .maxDuration)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        codec = try container.decodeIfPresent(VideoExportCodec.self, forKey: .codec)
        resolution = try container.decodeIfPresent(ExportResolutionPreset.self, forKey: .resolution)
        quality = try container.decodeIfPresent(VideoExportQualityPreset.self, forKey: .quality)
        frameRate = try container.decodeIfPresent(VideoExportFrameRate.self, forKey: .frameRate)
        captionDelivery = try container.decodeIfPresent(
            PublishCaptionDelivery.self,
            forKey: .captionDelivery
        ) ?? .burnedIn
        let canonicalFilename = try container.decodeIfPresent(String.self, forKey: .filename)
        let aliasFilename = try container.decodeIfPresent(String.self, forKey: .outputFilename)
        if let canonicalFilename, let aliasFilename, canonicalFilename != aliasFilename {
            throw OpenRecordError.io("Publish output specifies conflicting filenames.")
        }
        filename = canonicalFilename ?? aliasFilename
        let canonicalOverwrite = try container.decodeIfPresent(
            PublishOverwritePolicy.self,
            forKey: .overwrite
        )
        let aliasOverwrite = try container.decodeIfPresent(
            PublishOverwritePolicy.self,
            forKey: .overwritePolicy
        )
        if let canonicalOverwrite, let aliasOverwrite, canonicalOverwrite != aliasOverwrite {
            throw OpenRecordError.io("Publish output specifies conflicting overwrite policies.")
        }
        overwrite = canonicalOverwrite ?? aliasOverwrite ?? .fail
        let canonicalScreenshots = try container.decodeIfPresent(
            PublishScreenshotMode.self,
            forKey: .screenshots
        )
        let aliasScreenshots = try container.decodeIfPresent(
            PublishScreenshotMode.self,
            forKey: .screenshotMode
        )
        if let canonicalScreenshots, let aliasScreenshots, canonicalScreenshots != aliasScreenshots {
            throw OpenRecordError.io("Publish output specifies conflicting screenshot modes.")
        }
        screenshots = canonicalScreenshots ?? aliasScreenshots ?? .none
        includeTranscript = try container.decodeIfPresent(Bool.self, forKey: .includeTranscript)
        safeArea = try container.decodeIfPresent(Rect2D.self, forKey: .safeArea)
        _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        _ = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(aspect, forKey: .aspect)
        try container.encodeIfPresent(storyBeat, forKey: .storyBeat)
        try container.encodeIfPresent(maxDuration, forKey: .maxDuration)
        try container.encodeIfPresent(templateID, forKey: .templateID)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encodeIfPresent(quality, forKey: .quality)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encode(captionDelivery, forKey: .captionDelivery)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encode(overwrite, forKey: .overwrite)
        try container.encode(screenshots, forKey: .screenshots)
        try container.encodeIfPresent(includeTranscript, forKey: .includeTranscript)
        try container.encodeIfPresent(safeArea, forKey: .safeArea)
    }

    /// A safe filename when the recipe did not provide one. The extension is
    /// deterministic and is not persisted into the recipe itself.
    public var effectiveFilename: String {
        if let filename, !filename.isEmpty { return filename }
        let fileExtension = kind == .video && codec == .proRes422
            ? "mov"
            : kind.defaultExtension
        return name + "." + fileExtension
    }

    public func validated() throws -> PublishOutput {
        guard Self.isSafeComponent(name, maximumLength: Self.maximumNameLength) else {
            throw OpenRecordError.io("Publish output name must be one safe path component.")
        }
        if let filename,
           !Self.isSafeComponent(filename, maximumLength: Self.maximumFilenameLength)
        {
            throw OpenRecordError.io("Publish output filename must be one safe path component.")
        }
        if let storyBeat,
           !Self.isSafeIdentifier(storyBeat, maximumLength: Self.maximumSelectorLength)
        {
            throw OpenRecordError.io("Publish output storyBeat selector is unsafe or too long.")
        }
        if let templateID,
           !Self.isSafeComponent(templateID, maximumLength: Self.maximumTemplateIDLength)
        {
            throw OpenRecordError.io("Publish output templateID is unsafe or too long.")
        }
        if let maxDuration {
            guard maxDuration.isFinite, maxDuration > 0, maxDuration <= Self.maximumDuration else {
                throw OpenRecordError.io("Publish output maxDuration must be between 0 and 3600 seconds.")
            }
        }
        if let safeArea {
            guard safeArea.x.isFinite, safeArea.y.isFinite,
                  safeArea.width.isFinite, safeArea.height.isFinite,
                  safeArea.x >= 0, safeArea.y >= 0,
                  safeArea.width > 0, safeArea.height > 0,
                  safeArea.x + safeArea.width <= 1,
                  safeArea.y + safeArea.height <= 1
            else {
                throw OpenRecordError.io("Publish output safeArea must be a positive normalized canvas rectangle.")
            }
        }
        if kind == .tutorial, let codec, codec != .h264 {
            throw OpenRecordError.io("Tutorial outputs use H.264 for their standard MP4 fallback.")
        }
        if kind == .tutorial, let filename, !filename.hasSuffix(".openrecordweb") {
            throw OpenRecordError.io("Tutorial output filename must end in .openrecordweb.")
        }
        return self
    }

    fileprivate static func isSafeComponent(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength,
              value != ".", value != "..",
              !value.hasPrefix("."), !value.hasSuffix("."),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar.value == 45 // -
                      || scalar.value == 95 // _
                      || scalar.value == 46 // .
              })
        else { return false }
        return true
    }

    fileprivate static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength,
              !value.contains("/"), !value.contains("\\"),
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r"),
              !value.contains("://"), !value.contains("@"),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return true
    }
}

public extension PublishOutputKind {
    var defaultExtension: String {
        switch self {
        case .video: "mp4"
        case .gif: "gif"
        case .markdown: "md"
        case .html: "html"
        case .tutorial: "openrecordweb"
        }
    }
}

/// A portable, deterministic set of publish outputs.
public struct PublishRecipe: Codable, Sendable, Hashable {
    public static let currentFormatVersion = 1
    public static let maximumOutputs = 128

    public var formatVersion: Int
    public var outputs: [PublishOutput]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        outputs: [PublishOutput]
    ) {
        self.formatVersion = formatVersion
        self.outputs = outputs
    }

    /// Compatibility spelling for callers that prefer a nested output type.
    public typealias Output = PublishOutput
    public typealias OutputKind = PublishOutputKind
    public typealias Aspect = PublishAspect

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case outputs
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unsupported = allFields.allKeys
            .map(\.stringValue)
            .filter { !allowed.contains($0) }
            .sorted()
        guard unsupported.isEmpty else {
            throw OpenRecordError.io(
                "Publish recipe contains unsupported fields: " + unsupported.joined(separator: ", ")
            )
        }
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        outputs = try container.decode([PublishOutput].self, forKey: .outputs)
        _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        _ = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(outputs, forKey: .outputs)
    }

    /// Decode and validate a recipe at a portable filesystem location.
    public static func load(from url: URL) throws -> PublishRecipe {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw OpenRecordError.io("Could not read publish recipe \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            return try ProjectJSON.decoder.decode(PublishRecipe.self, from: data).validated()
        } catch let error as OpenRecordError {
            throw error
        } catch {
            throw OpenRecordError.io("Invalid publish recipe \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func validated() throws -> PublishRecipe {
        guard formatVersion == Self.currentFormatVersion else {
            throw OpenRecordError.io(
                "Unsupported publish recipe format version \(formatVersion); expected \(Self.currentFormatVersion)."
            )
        }
        guard !outputs.isEmpty, outputs.count <= Self.maximumOutputs else {
            throw OpenRecordError.io("Publish recipe must contain between 1 and 128 outputs.")
        }
        var names = Set<String>()
        var filenames = Set<String>()
        for output in outputs {
            _ = try output.validated()
            guard output.effectiveFilename.lowercased() != "manifest.json" else {
                throw OpenRecordError.io("Publish output filename manifest.json is reserved for the release manifest.")
            }
            let nameKey = output.name.lowercased()
            guard names.insert(nameKey).inserted else {
                throw OpenRecordError.io("Publish recipe contains duplicate output name \(output.name).")
            }
            var generatedFilenames = [output.effectiveFilename]
            if (output.captionDelivery == .sidecar || output.captionDelivery == .both),
               output.kind == .video || output.kind == .markdown || output.kind == .html
            {
                generatedFilenames.append(
                    (output.effectiveFilename as NSString).deletingPathExtension + ".vtt"
                )
            }
            for filename in generatedFilenames {
                guard filenames.insert(filename.lowercased()).inserted else {
                    throw OpenRecordError.io("Publish recipe contains colliding generated filename \(filename).")
                }
            }
        }
        return self
    }
}

public typealias PublishRecipeOutput = PublishOutput
public typealias PublishOutputFormat = PublishOutputKind
public typealias CaptionDelivery = PublishCaptionDelivery
public typealias OverwritePolicy = PublishOverwritePolicy
public typealias ScreenshotMode = PublishScreenshotMode
