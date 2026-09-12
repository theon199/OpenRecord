import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The result of one file in a release.  Paths are always relative to the
/// publish directory; an absolute path is intentionally not representable in
/// the manifest.
public struct PublishedFile: Codable, Sendable, Hashable {
    public let relativePath: String
    public let byteCount: Int64
    public let checksum: String
    public let mediaType: String?

    public init(
        relativePath: String,
        byteCount: Int64,
        checksum: String,
        mediaType: String? = nil
    ) {
        self.relativePath = relativePath
        self.byteCount = max(0, byteCount)
        self.checksum = checksum.lowercased()
        self.mediaType = mediaType
    }

    public var filename: String { relativePath }
    public var path: String { relativePath }
    public var sha256: String { checksum }
}

/// One recipe output and the deterministic files it generated.
public struct PublishedOutput: Codable, Sendable, Hashable {
    public let name: String
    public let kind: PublishOutputKind
    public let aspect: String
    public let sourceDuration: TimeInterval
    public let outputDuration: TimeInterval
    public let settings: [String: String]
    public let files: [PublishedFile]

    public init(
        name: String,
        kind: PublishOutputKind,
        aspect: String,
        sourceDuration: TimeInterval,
        outputDuration: TimeInterval,
        settings: [String: String] = [:],
        files: [PublishedFile]
    ) {
        self.name = name
        self.kind = kind
        self.aspect = aspect
        self.sourceDuration = Self.normalizedDuration(sourceDuration)
        self.outputDuration = Self.normalizedDuration(outputDuration)
        self.settings = settings
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }

    public var filename: String? { files.first?.relativePath }

    private static func normalizedDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}

/// Privacy review state copied into a release manifest.  This value describes
/// review of the sidecar findings only; it never claims that the source bundle
/// is sanitized.
public enum PublishPrivacyReviewState: String, Codable, CaseIterable, Sendable, Hashable {
    case notReviewed = "not-reviewed"
    case incomplete
    case complete

    public static var notReviewedState: Self { .notReviewed }
}

/// A byte-stable, portable release manifest.
public struct PublishManifest: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectFormatVersion: Int
    public let recipeFormatVersion: Int
    public let sourceFingerprints: [AnalysisSourceFingerprint]
    public let analyzerVersion: String
    public let renderVersion: String
    public let outputs: [PublishedOutput]
    public let warnings: [String]
    public let privacyReview: PublishPrivacyReviewState
    public let reproducibilityLimitations: [String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectFormatVersion: Int,
        recipeFormatVersion: Int,
        sourceFingerprints: [AnalysisSourceFingerprint] = [],
        analyzerVersion: String = ActionMapAnalysisService.analyzerVersion,
        renderVersion: String = String(RenderPlan.renderVersion),
        outputs: [PublishedOutput],
        warnings: [String] = [],
        privacyReview: PublishPrivacyReviewState = .notReviewed,
        reproducibilityLimitations: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.projectFormatVersion = projectFormatVersion
        self.recipeFormatVersion = recipeFormatVersion
        self.sourceFingerprints = sourceFingerprints.sorted {
            if $0.bundleRelativePath != $1.bundleRelativePath {
                return $0.bundleRelativePath < $1.bundleRelativePath
            }
            return $0.digest < $1.digest
        }
        self.analyzerVersion = analyzerVersion
        self.renderVersion = renderVersion
        self.outputs = outputs.sorted { $0.name < $1.name }
        self.warnings = Self.stableUnique(warnings).sorted()
        self.privacyReview = privacyReview
        self.reproducibilityLimitations = Self.stableUnique(reproducibilityLimitations).sorted()
    }

    public var formatVersion: Int { schemaVersion }
    public var privacyReviewState: PublishPrivacyReviewState { privacyReview }
    public var limitations: [String] { reproducibilityLimitations }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Verification is deliberately value based so callers can display all
/// actionable problems instead of stopping at the first damaged file.
public struct PublishVerification: Codable, Sendable, Hashable {
    public let valid: Bool
    public let issues: [String]
    public let manifest: PublishManifest?

    public init(valid: Bool, issues: [String] = [], manifest: PublishManifest? = nil) {
        self.valid = valid
        self.issues = issues
        self.manifest = manifest
    }

    public var isValid: Bool { valid }
    public var errors: [String] { issues }
}

/// Local, deterministic orchestration for v4.3 release outputs.
public struct ReleaseFactory: Sendable {
    public static let renderVersion = String(RenderPlan.renderVersion)
    public static let reproducibilityLimitations = [
        "Media encoder output can vary with the supported Apple OS media stack.",
        "The manifest is byte-stable when the source bundle and toolchain are unchanged."
    ]

    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL.standardizedFileURL
    }

    /// Publishes a recipe into an atomically installed sibling directory.
    /// Project and analysis files are read only; no analysis cache is rebuilt.
    public func publish(recipeURL: URL, outputDirectory: URL) async throws -> PublishManifest {
        let source = try validateProjectURL(projectURL)
        let recipe = try PublishRecipe.load(from: recipeURL)
        let destination = try validateDestination(outputDirectory, source: source)
        guard !recipe.outputs.contains(where: { $0.effectiveFilename == "manifest.json" }) else {
            throw OpenRecordError.io("Publish output filename manifest.json is reserved for the release manifest.")
        }
        try rejectExistingOutputs(recipe: recipe, destination: destination)

        let opened = try ProjectLibrary().open(url: source)
        let sourceDuration = try await readSourceDuration(in: source)
        let actions: [ActionCandidate]
        var warnings: [String] = []
        let fresh = try? ActionMapAnalysisService(
            projectURL: source,
            meta: opened.meta,
            document: opened.document
        ).loadFresh()
        if let fresh {
            actions = fresh
        } else {
            actions = []
            warnings.append("action-map-unavailable")
        }

        let privacy = privacyReview(in: source)
        warnings.append(contentsOf: privacy.warnings)
        let plan = try RenderPlan(
            project: opened.document,
            recipe: recipe,
            actions: actions,
            sourceDuration: sourceDuration
        )
        try plan.validateProtectedRegions()

        let staging = try makeStagingDirectory(nextTo: destination)
        var installed = false
        defer {
            if !installed { try? FileManager.default.removeItem(at: staging) }
        }

        let fingerprints = sourceFingerprints(in: source)
        warnings.append(contentsOf: fingerprints.warnings)

        let existingManifest: PublishManifest? = {
            let manifestURL = destination.appendingPathComponent("manifest.json", isDirectory: false)
            guard !Self.hasSymlink(at: manifestURL),
                  let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                  let m = try? ProjectJSON.decoder.decode(PublishManifest.self, from: data),
                  m.schemaVersion == PublishManifest.currentSchemaVersion,
                  Set(m.sourceFingerprints) == Set(fingerprints.values)
            else { return nil }
            return m
        }()

        var published: [PublishedOutput] = []
        let tutorialFilename = recipe.outputs.first(where: { $0.kind == .tutorial })?.effectiveFilename
        for variant in plan.variants {
            let existing = destination.appendingPathComponent(
                variant.output.effectiveFilename,
                isDirectory: variant.output.kind == .tutorial
            )
            let variantSettings = settings(for: variant.output, document: variant.derivedDocument)
            if let matchingOutput = existingManifest?.outputs.first(where: {
                $0.name == variant.output.name &&
                $0.kind == variant.output.kind &&
                $0.aspect == variant.output.aspect.rawValue &&
                abs($0.sourceDuration - sourceDuration) < 0.001 &&
                abs($0.outputDuration - variant.outputDuration) < 0.001 &&
                $0.settings == variantSettings
            }),
            matchingOutput.files.allSatisfy({ file in
                guard let rel = Self.safeRelativePath(file.relativePath) else { return false }
                let cand = destination.appendingPathComponent(rel, isDirectory: false)
                guard Self.isContained(cand, in: destination), !Self.hasSymlink(at: cand) else { return false }
                var isDir = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: cand.path, isDirectory: &isDir), !isDir.boolValue else { return false }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: cand.path),
                      (attrs[.size] as? NSNumber)?.int64Value == file.byteCount,
                      let digest = try? Self.sha256(file: cand), digest == file.checksum.lowercased()
                else { return false }
                return true
            }) {
                for file in matchingOutput.files {
                    if let rel = Self.safeRelativePath(file.relativePath) {
                        let src = destination.appendingPathComponent(rel, isDirectory: false)
                        let dst = staging.appendingPathComponent(rel, isDirectory: false)
                        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: src, to: dst)
                    }
                }
                published.append(matchingOutput)
                continue
            }
            if variant.output.overwrite == .skip,
               FileManager.default.fileExists(atPath: existing.path)
            {
                guard !Self.hasSymlink(at: existing) else {
                    throw OpenRecordError.io("Cannot skip a symbolic-link output: " + variant.output.effectiveFilename)
                }
                let copied = staging.appendingPathComponent(
                    variant.output.effectiveFilename,
                    isDirectory: variant.output.kind == .tutorial
                )
                try FileManager.default.copyItem(at: existing, to: copied)
                let copiedFiles = try PublishedFile.files(under: copied, root: staging)
                published.append(PublishedOutput(
                    name: variant.output.name,
                    kind: variant.output.kind,
                    aspect: variant.output.aspect.rawValue,
                    sourceDuration: sourceDuration,
                    outputDuration: variant.outputDuration,
                    settings: variantSettings,
                    files: copiedFiles
                ))
                continue
            }
            let result = try await generate(
                variant: variant,
                document: opened.document,
                meta: opened.meta,
                actions: actions,
                sourceDuration: sourceDuration,
                source: source,
                staging: staging,
                tutorialFilename: tutorialFilename
            )
            published.append(result)
        }
        let manifest = PublishManifest(
            projectFormatVersion: opened.document.formatVersion,
            recipeFormatVersion: recipe.formatVersion,
            sourceFingerprints: fingerprints.values,
            analyzerVersion: ActionMapAnalysisService.analyzerVersion,
            renderVersion: Self.renderVersion,
            outputs: published,
            warnings: warnings,
            privacyReview: privacy.state,
            reproducibilityLimitations: Self.reproducibilityLimitations
        )
        let manifestData = try ProjectJSON.encoder.encode(manifest)
        try AtomicFileWrite.write(
            manifestData,
            to: staging.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try install(staging: staging, destination: destination)
        installed = true
        return manifest
    }

    /// Validates a previously installed release without modifying it.
    public static func verifyOutput(manifestURL: URL) throws -> PublishVerification {
        var issues: [String] = []
        guard manifestURL.isFileURL, !Self.hasSymlink(at: manifestURL) else {
            throw OpenRecordError.io("Manifest URL must be a local, non-symlink file.")
        }
        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        } catch {
            throw OpenRecordError.io("Could not read release manifest: " + error.localizedDescription)
        }
        let manifest: PublishManifest
        do {
            manifest = try ProjectJSON.decoder.decode(PublishManifest.self, from: data)
        } catch {
            throw OpenRecordError.io("Invalid release manifest: " + error.localizedDescription)
        }
        guard manifest.schemaVersion == PublishManifest.currentSchemaVersion else {
            return PublishVerification(
                valid: false,
                issues: ["Unsupported release manifest schema version " + String(manifest.schemaVersion) + "."],
                manifest: manifest
            )
        }

        for output in manifest.outputs {
            for file in output.files {
                guard let relative = Self.safeRelativePath(file.relativePath) else {
                    issues.append("Output \(output.name) has an unsafe relative path \(file.relativePath).")
                    continue
                }
                let candidate = root.appendingPathComponent(relative, isDirectory: false)
                guard Self.isContained(candidate, in: root) else {
                    issues.append("Output \(output.name) escapes its publish directory: \(file.relativePath).")
                    continue
                }
                if Self.hasSymlink(at: candidate, relativeTo: root) {
                    issues.append("Output \(output.name) references a symbolic link: \(file.relativePath).")
                    continue
                }
                var directory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue else {
                    issues.append("Missing published file \(file.relativePath).")
                    continue
                }
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: candidate.path)
                    let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                    guard byteCount == file.byteCount else {
                        issues.append("Byte count mismatch for \(file.relativePath): expected \(file.byteCount), found \(byteCount).")
                        continue
                    }
                    let digest = try Self.sha256(file: candidate)
                    guard digest == file.checksum.lowercased() else {
                    issues.append("Checksum mismatch for \(file.relativePath).")
                        continue
                    }
                } catch {
                    issues.append("Could not verify \(file.relativePath): \(error.localizedDescription)")
                }
            }
            if output.kind == .tutorial {
                issues.append(contentsOf: Self.verifyTutorialAllowlist(output: output, root: root))
            }
        }
        let expectedPaths = Set(manifest.outputs.flatMap { $0.files.map(\.relativePath) } + ["manifest.json"])
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let relative = Self.relativeSubpath(of: url, relativeTo: root)
                if Self.hasSymlink(at: url) {
                    issues.append("Release output contains a symbolic link: \(relative).")
                    continue
                }
                var directory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                      !directory.boolValue
                else { continue }
                if !expectedPaths.contains(relative) {
                    issues.append("Unexpected published file \(relative).")
                }
            }
        }
        return PublishVerification(valid: issues.isEmpty, issues: issues.sorted(), manifest: manifest)
    }
}

// MARK: - Generation

private extension ReleaseFactory {
    func readSourceDuration(in source: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(
            url: ProjectLayout.displayVideoURL(in: source),
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw OpenRecordError.io("The source display video has no usable duration.")
        }
        return duration.seconds
    }

    struct PrivacyReview {
        var state: PublishPrivacyReviewState
        var warnings: [String]
    }

    struct Fingerprints {
        var values: [AnalysisSourceFingerprint]
        var warnings: [String]
    }

    func generate(
        variant: RenderPlanVariant,
        document authoredDocument: ProjectDocument,
        meta: ProjectMeta,
        actions: [ActionCandidate],
        sourceDuration: TimeInterval,
        source: URL,
        staging: URL,
        tutorialFilename: String?
    ) async throws -> PublishedOutput {
        let output = variant.output
        let document = variant.derivedDocument
        let mapper = ProjectTimeMapper(project: document, sourceDuration: sourceDuration)
        let base = output.effectiveFilename
        let target = staging.appendingPathComponent(base, isDirectory: output.kind == .tutorial)
        let exporter = Exporter(projectBundleURL: source)
        var additionalFiles: [URL] = []
        switch output.kind {
        case .video:
            try await exporter.export(project: document, url: target, progress: nil)
            Self.normalizeMP4Timestamps(at: target)
            if output.captionDelivery == .sidecar || output.captionDelivery == .both {
                let captions = target.deletingPathExtension().appendingPathExtension("vtt")
                try AtomicFileWrite.write(
                    makeVTT(
                        captions: authoredDocument.captions,
                        transcript: authoredDocument.transcript,
                        mapper: mapper,
                        includeTranscript: output.includeTranscript == true
                    ),
                    to: captions
                )
                additionalFiles.append(captions)
            }
        case .gif:
            try await exporter.exportGIF(project: document, url: target, progress: nil)
        case .markdown:
            additionalFiles = try await generateDocumentation(
                kind: .markdown,
                output: output,
                document: document,
                authoredDocument: authoredDocument,
                actions: actions,
                mapper: mapper,
                exporter: exporter,
                staging: staging,
                target: target,
                tutorialFilename: tutorialFilename
            )
            try appendCaptionSidecar(
                for: output,
                target: target,
                authoredDocument: authoredDocument,
                mapper: mapper,
                files: &additionalFiles
            )
        case .html:
            additionalFiles = try await generateDocumentation(
                kind: .html,
                output: output,
                document: document,
                authoredDocument: authoredDocument,
                actions: actions,
                mapper: mapper,
                exporter: exporter,
                staging: staging,
                target: target,
                tutorialFilename: tutorialFilename
            )
            try appendCaptionSidecar(
                for: output,
                target: target,
                authoredDocument: authoredDocument,
                mapper: mapper,
                files: &additionalFiles
            )
        case .tutorial:
            try await generateTutorial(
                output: output,
                document: document,
                authoredDocument: authoredDocument,
                actions: actions,
                mapper: mapper,
                exporter: exporter,
                source: source,
                meta: meta,
                package: target
            )
        }

        let files = try (PublishedFile.files(under: target, root: staging)
            + additionalFiles.map { try PublishedFile.file(at: $0, root: staging) })
            .sorted { $0.relativePath < $1.relativePath }
        return PublishedOutput(
            name: output.name,
            kind: output.kind,
            aspect: output.aspect.rawValue,
            sourceDuration: sourceDuration,
            outputDuration: variant.outputDuration,
            settings: settings(for: output, document: document),
            files: files
        )
    }

    func generateDocumentation(
        kind: PublishOutputKind,
        output: PublishOutput,
        document: ProjectDocument,
        authoredDocument: ProjectDocument,
        actions: [ActionCandidate],
        mapper: ProjectTimeMapper,
        exporter: Exporter,
        staging: URL,
        target: URL,
        tutorialFilename: String?
    ) async throws -> [URL] {
        let beats = authoredDocument.storyBeats
            .filter { !$0.isSuppressed }
            .map(\.normalized)
            .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
        let safeActions = actions.map(\.normalized).sorted { ($0.start, $0.end, $0.id.rawValue) < ($1.start, $1.end, $1.id.rawValue) }
        var steps: [DocumentationStep] = []
        var generatedAssets: [String] = []
        let shouldCapture = output.screenshots != .none
        for beat in beats {
            let matching = safeActions.first { $0.end > beat.start && $0.start < beat.end }
            let sourceStart = matching?.start ?? beat.start
            let sourceEnd = matching?.end ?? beat.end
            let ranges = outputRanges(sourceStart: sourceStart, sourceEnd: sourceEnd, mapper: mapper)
            guard let first = ranges.first, let last = ranges.last else { continue }
            let outputTime = max(first.start, last.end - 0.001)
            var asset: String?
            if shouldCapture {
                let filename = "\(output.name)-step-\(String(format: "%03d", steps.count + 1)).png"
                let url = staging.appendingPathComponent(filename, isDirectory: false)
                try await exporter.exportSnapshot(project: document, atOutputTime: outputTime, url: url)
                asset = filename
                generatedAssets.append(filename)
            }
            let label = safeLabel(matching?.label ?? beat.title)
            let shortcut = matching.flatMap { $0.kind == .shortcut ? safeLabel($0.label) : nil }
            steps.append(DocumentationStep(
                title: safeLabel(beat.title),
                label: label,
                start: first.start,
                end: max(first.start, last.end),
                screenshot: asset,
                shortcut: shortcut,
                clickNote: matching?.kind == .click ? "Click " + label : nil
            ))
        }
        let transcript = output.includeTranscript == true
            ? transcriptValues(authoredDocument.transcript, mapper: mapper)
            : []
        let payload = DocumentationPayload(
            steps: steps,
            transcript: transcript,
            tutorialPath: tutorialFilename.map { $0 + "/index.html" }
        )
        let data: Data
        if kind == .markdown {
            data = Data(makeMarkdown(output: output, payload: payload).utf8)
        } else {
            data = Data(makeHTML(output: output, payload: payload).utf8)
        }
        try AtomicFileWrite.write(data, to: target)
        return generatedAssets.map { staging.appendingPathComponent($0, isDirectory: false) }
    }

    func generateTutorial(
        output: PublishOutput,
        document: ProjectDocument,
        authoredDocument: ProjectDocument,
        actions: [ActionCandidate],
        mapper: ProjectTimeMapper,
        exporter: Exporter,
        source: URL,
        meta: ProjectMeta,
        package: URL
    ) async throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let video = package.appendingPathComponent("video.mp4", isDirectory: false)
        try await exporter.export(project: document, url: video, progress: nil)
        Self.normalizeMP4Timestamps(at: video)
        let posterPNG = package.appendingPathComponent(".poster.png", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: posterPNG) }
        try await exporter.exportSnapshot(project: document, atOutputTime: 0, url: posterPNG)
        try writeJPEG(from: posterPNG, to: package.appendingPathComponent("poster.jpg", isDirectory: false))
        try writeDefaultCursor(to: package.appendingPathComponent("cursor.png", isDirectory: false))
        try AtomicFileWrite.write(
            makeVTT(
                captions: authoredDocument.captions,
                transcript: authoredDocument.transcript,
                mapper: mapper,
                includeTranscript: output.includeTranscript == true
            ),
            to: package.appendingPathComponent("captions.vtt", isDirectory: false)
        )
        let beats = authoredDocument.storyBeats
            .filter { !$0.isSuppressed }
            .map(\.normalized)
            .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
        let safeActions = actions.map(\.normalized).sorted { ($0.start, $0.end, $0.id.rawValue) < ($1.start, $1.end, $1.id.rawValue) }
        let steps: [TutorialStep] = beats.compactMap { beat in
            let action = safeActions.first { $0.end > beat.start && $0.start < beat.end }
            let ranges = outputRanges(
                sourceStart: action?.start ?? beat.start,
                sourceEnd: action?.end ?? beat.end,
                mapper: mapper
            )
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return TutorialStep(
                title: safeLabel(beat.title),
                start: first.start,
                end: max(first.start, last.end),
                kind: action?.kind.rawValue ?? beat.kind.rawValue,
                label: safeLabel(action?.label ?? beat.title)
            )
        }
        let transcript = output.includeTranscript == true
            ? transcriptValues(authoredDocument.transcript, mapper: mapper)
            : []
        let telemetry = tutorialTelemetry(source: source, meta: meta, mapper: mapper)
        let tutorialManifest = TutorialManifest(
            duration: mapper.outputDuration,
            steps: steps,
            transcript: transcript,
            cursor: telemetry.cursor,
            clicks: telemetry.clicks,
            shortcuts: telemetry.shortcuts
        )
        let tutorialManifestData = try ProjectJSON.encoder.encode(tutorialManifest)
        try AtomicFileWrite.write(
            tutorialManifestData,
            to: package.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try AtomicFileWrite.write(
            Data(makeTutorialIndex(manifestData: tutorialManifestData).utf8),
            to: package.appendingPathComponent("index.html", isDirectory: false)
        )
        try AtomicFileWrite.write(Data(Self.tutorialJS.utf8), to: package.appendingPathComponent("player.js", isDirectory: false))
        try AtomicFileWrite.write(Data(Self.tutorialCSS.utf8), to: package.appendingPathComponent("player.css", isDirectory: false))
    }

    struct DocumentationStep: Codable, Sendable, Hashable {
        var title: String
        var label: String
        var start: TimeInterval
        var end: TimeInterval
        var screenshot: String?
        var shortcut: String?
        var clickNote: String?
    }

    struct TranscriptValue: Codable, Sendable, Hashable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    struct DocumentationPayload: Codable, Sendable, Hashable {
        var steps: [DocumentationStep]
        var transcript: [TranscriptValue]
        var tutorialPath: String?
    }

    struct TutorialStep: Codable, Sendable, Hashable {
        var title: String
        var start: TimeInterval
        var end: TimeInterval
        var kind: String
        var label: String
    }

    struct TutorialCursorSample: Codable, Sendable, Hashable {
        var time: TimeInterval
        var x: Double
        var y: Double
        var visible: Bool
    }

    struct TutorialClick: Codable, Sendable, Hashable {
        var time: TimeInterval
        var x: Double
        var y: Double
    }

    struct TutorialShortcut: Codable, Sendable, Hashable {
        var time: TimeInterval
        var label: String
    }

    struct TutorialTelemetry: Sendable {
        var cursor: [TutorialCursorSample]
        var clicks: [TutorialClick]
        var shortcuts: [TutorialShortcut]
    }

    struct TutorialManifest: Codable, Sendable, Hashable {
        var formatVersion = 1
        var duration: TimeInterval
        var steps: [TutorialStep]
        var transcript: [TranscriptValue]
        var cursor: [TutorialCursorSample]
        var clicks: [TutorialClick]
        var shortcuts: [TutorialShortcut]
    }

    func appendCaptionSidecar(
        for output: PublishOutput,
        target: URL,
        authoredDocument: ProjectDocument,
        mapper: ProjectTimeMapper,
        files: inout [URL]
    ) throws {
        guard output.captionDelivery == .sidecar || output.captionDelivery == .both else { return }
        let captions = target.deletingPathExtension().appendingPathExtension("vtt")
        try AtomicFileWrite.write(
            makeVTT(
                captions: authoredDocument.captions,
                transcript: authoredDocument.transcript,
                mapper: mapper,
                includeTranscript: output.includeTranscript == true
            ),
            to: captions
        )
        files.append(captions)
    }

    func settings(for output: PublishOutput, document: ProjectDocument) -> [String: String] {
        var values = [
            "aspect": output.aspect.rawValue,
            "codec": (output.codec ?? document.videoExportSettings.codec).rawValue,
            "resolution": (output.resolution ?? document.videoExportSettings.resolution).rawValue,
            "quality": (output.quality ?? document.videoExportSettings.quality).rawValue,
            "frameRate": (output.frameRate ?? document.videoExportSettings.frameRate).rawValue,
            "captionDelivery": output.captionDelivery.rawValue
        ]
        if let maxDuration = output.maxDuration {
            values["maxDuration"] = String(format: "%.6f", maxDuration)
        }
        if let storyBeat = output.storyBeat { values["storyBeat"] = storyBeat }
        if let templateID = output.templateID { values["templateID"] = templateID }
        if let safeArea = output.safeArea {
            values["safeArea"] = [safeArea.x, safeArea.y, safeArea.width, safeArea.height]
                .map { String(format: "%.6f", $0) }
                .joined(separator: ",")
        }
        values["screenshots"] = output.screenshots.rawValue
        values["includeTranscript"] = output.includeTranscript == true ? "true" : "false"
        return values
    }

    func makeTutorialIndex(manifestData: Data) -> String {
        let json = String(decoding: manifestData, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        let inline = "<script>window.__OPENRECORD_MANIFEST=" + json + ";</script>"
        return Self.tutorialHTML.replacingOccurrences(
            of: "<script src=\"player.js\"></script>",
            with: inline + "<script src=\"player.js\"></script>"
        )
    }
}

// MARK: - Source and path validation

private extension ReleaseFactory {
    func validateProjectURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !Self.hasSymlink(at: url) else {
            throw OpenRecordError.io("Project URL must be a local, non-symlink bundle.")
        }
        let value = url.standardizedFileURL
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: value.path, isDirectory: &directory), directory.boolValue,
              value.pathExtension == ProjectLayout.bundleExtension
        else { throw OpenRecordError.io("Project URL is not an .openrecord bundle.") }
        return value
    }

    func validateDestination(_ url: URL, source: URL) throws -> URL {
        guard url.isFileURL else { throw OpenRecordError.io("Publish destination must be a local directory.") }
        guard !Self.containsDotDot(url.path) else { throw OpenRecordError.io("Publish destination contains path traversal.") }
        let value = url.standardizedFileURL
        let sourceResolved = source.resolvingSymlinksInPath().standardizedFileURL
        let destinationResolved = value.resolvingSymlinksInPath().standardizedFileURL
        guard destinationResolved.path != sourceResolved.path,
              !destinationResolved.path.hasPrefix(sourceResolved.path + "/")
        else { throw OpenRecordError.io("Publish destination cannot be inside the source bundle.") }
        if Self.hasSymlink(at: value) {
            throw OpenRecordError.io("Publish destination may not be a symbolic link.")
        }
        try validateExistingDestinationIsManaged(value)
        return value
    }

    func validateExistingDestinationIsManaged(_ destination: URL) throws {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            throw OpenRecordError.io("Publish destination exists and is not a directory.")
        }
        let contents = try fm.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard !contents.isEmpty else { return }

        let manifestURL = destination.appendingPathComponent("manifest.json", isDirectory: false)
        guard !Self.hasSymlink(at: manifestURL),
              let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
              let manifest = try? ProjectJSON.decoder.decode(PublishManifest.self, from: data),
              manifest.schemaVersion == PublishManifest.currentSchemaVersion
        else {
            throw OpenRecordError.io(
                "Publish destination is not empty and is not a supported OpenRecord release directory."
            )
        }
        let expected = Set(manifest.outputs.flatMap { $0.files.map(\.relativePath) } + ["manifest.json"])
        guard expected.allSatisfy({ Self.safeRelativePath($0) != nil }) else {
            throw OpenRecordError.io("Existing release manifest contains an unsafe path.")
        }
        if let enumerator = fm.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let relative = Self.relativeSubpath(of: url, relativeTo: destination)
                guard !Self.hasSymlink(at: url) else {
                    throw OpenRecordError.io("Existing release contains a symbolic link: \(relative).")
                }
                var directory = ObjCBool(false)
                guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
                let isManaged = directory.boolValue
                    ? expected.contains(where: { $0.hasPrefix(relative + "/") })
                    : expected.contains(relative)
                guard isManaged else {
                    throw OpenRecordError.io(
                        "Publish destination contains an unrelated item: \(relative). Choose an empty folder or remove it explicitly."
                    )
                }
            }
        }
    }

    func rejectExistingOutputs(recipe: PublishRecipe, destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return }
        for output in recipe.outputs where output.overwrite == .fail {
            guard output.effectiveFilename != "manifest.json" else {
                throw OpenRecordError.io("Publish output filename manifest.json is reserved for the release manifest.")
            }
            let target = destination.appendingPathComponent(output.effectiveFilename, isDirectory: output.kind == .tutorial)
            if fm.fileExists(atPath: target.path) {
            throw OpenRecordError.io("Publish output already exists: \(output.effectiveFilename). Set overwrite to replace or skip.")
            }
        }
    }

    func makeStagingDirectory(nextTo destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            "." + destination.lastPathComponent + ".staging-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    func install(staging: URL, destination: URL) throws {
        try AtomicFileWrite.installDirectory(staging: staging, destination: destination)
    }

    static func containsDotDot(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    static func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains("."), !components.contains(".."), !components.contains("") else { return nil }
        return path
    }

    static func relativeSubpath(of url: URL, relativeTo root: URL) -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedURL == resolvedRoot {
            return ""
        }
        if resolvedURL.hasPrefix(resolvedRoot + "/") {
            return String(resolvedURL.dropFirst(resolvedRoot.count + 1))
        }
        let stdRoot = root.standardizedFileURL.path
        let stdURL = url.standardizedFileURL.path
        if stdURL == stdRoot {
            return ""
        }
        if stdURL.hasPrefix(stdRoot + "/") {
            return String(stdURL.dropFirst(stdRoot.count + 1))
        }
        let rawRoot = root.path
        let rawURL = url.path
        if rawURL == rawRoot {
            return ""
        }
        if rawURL.hasPrefix(rawRoot + "/") {
            return String(rawURL.dropFirst(rawRoot.count + 1))
        }
        return url.lastPathComponent
    }

    static func isContained(_ path: URL, in root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let pathValue = path.resolvingSymlinksInPath().standardizedFileURL.path
        return pathValue == rootPath || pathValue.hasPrefix(rootPath + "/")
    }

    static func hasSymlink(at url: URL) -> Bool {
        let fm = FileManager.default
        let path = url.standardizedFileURL.path
        if let attrs = try? fm.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return true
        }
        return false
    }

    static func hasSymlink(at url: URL, relativeTo root: URL) -> Bool {
        if hasSymlink(at: url) { return true }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot.path) else { return true }
        let relative = relativeSubpath(of: url, relativeTo: root)
        guard !relative.isEmpty else { return false }
        var current = root.standardizedFileURL
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            if hasSymlink(at: current) { return true }
        }
        return false
    }

    static func normalizeMP4Timestamps(at url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return }
        var bytes = [UInt8](data)
        let count = bytes.count

        func readUInt32(_ offset: Int) -> UInt32 {
            guard offset + 4 <= count else { return 0 }
            return (UInt32(bytes[offset]) << 24) |
                   (UInt32(bytes[offset + 1]) << 16) |
                   (UInt32(bytes[offset + 2]) << 8) |
                   UInt32(bytes[offset + 3])
        }

        func processBox(start: Int, end: Int) {
            var offset = start
            while offset + 8 <= end {
                let boxSize = Int(readUInt32(offset))
                let nextOffset: Int
                if boxSize == 1 {
                    guard offset + 16 <= end else { break }
                    let size64 = (UInt64(readUInt32(offset + 8)) << 32) | UInt64(readUInt32(offset + 12))
                    nextOffset = offset + Int(size64)
                } else if boxSize == 0 {
                    nextOffset = end
                } else if boxSize >= 8 {
                    nextOffset = offset + boxSize
                } else {
                    break
                }
                guard nextOffset <= end else { break }

                let typeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
                let typeStr = String(bytes: typeBytes, encoding: .isoLatin1) ?? ""
                let headerSize = (boxSize == 1) ? 16 : 8
                let payloadStart = offset + headerSize

                if typeStr == "moov" || typeStr == "trak" || typeStr == "mdia" || typeStr == "minf" {
                    processBox(start: payloadStart, end: nextOffset)
                } else if typeStr == "mvhd" || typeStr == "tkhd" || typeStr == "mdhd" {
                    guard payloadStart + 4 <= nextOffset else { break }
                    let version = bytes[payloadStart]
                    let timeOffset = payloadStart + 4
                    if version == 0 {
                        if timeOffset + 8 <= nextOffset {
                            for i in 0..<8 {
                                bytes[timeOffset + i] = 0
                            }
                        }
                    } else if version == 1 {
                        if timeOffset + 16 <= nextOffset {
                            for i in 0..<16 {
                                bytes[timeOffset + i] = 0
                            }
                        }
                    }
                }
                offset = nextOffset
            }
        }

        processBox(start: 0, end: count)
        try? Data(bytes).write(to: url, options: .atomic)
    }
}

// MARK: - Findings, fingerprints, structured outputs

private extension ReleaseFactory {
    func privacyReview(in source: URL) -> PrivacyReview {
        let url = ProjectLayout.analysisPrivacyURL(in: source)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PrivacyReview(state: .notReviewed, warnings: ["privacy-review-not-reviewed"])
        }
        var findings: [PrivacyFinding] = []
        do {
            try ProjectJSON.streamJSONL(PrivacyFinding.self, from: url) { findings.append($0.normalized) }
        } catch {
            return PrivacyReview(state: .incomplete, warnings: ["privacy-review-incomplete", "privacy-findings-unreadable"])
        }
        let complete = !findings.isEmpty && findings.allSatisfy { finding in
            finding.state == .accepted || finding.state == .rejected || finding.state == .verified
        }
        if complete { return PrivacyReview(state: .complete, warnings: []) }
        return PrivacyReview(state: .incomplete, warnings: ["privacy-review-incomplete"])
    }

    func sourceFingerprints(in source: URL) -> Fingerprints {
        let paths = [
            ProjectLayout.metaFileName,
            ProjectLayout.documentFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.displayVideoFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.webcamVideoFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.microphoneAudioFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.systemAudioFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.mouseFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.clicksFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.keysFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.typingFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.targetGeometryFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.semanticTargetsFileName
        ]
        var values: [AnalysisSourceFingerprint] = []
        var warnings: [String] = []
        for path in paths {
            let url = source.appendingPathComponent(path, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { values.append(try AnalysisStore.fingerprint(projectURL: source, bundleRelativePath: path)) }
            catch { warnings.append("source-fingerprint-unavailable:" + path) }
        }
        return Fingerprints(values: values, warnings: warnings)
    }

    func safeLabel(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Action" : trimmed).prefix(160))
    }

    func outputRanges(
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        mapper: ProjectTimeMapper
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard sourceStart.isFinite, sourceEnd.isFinite else { return [] }
        let lower = max(0, sourceStart)
        let upper = max(sourceEnd, lower + 0.001)
        return mapper.slices.compactMap { slice in
            let start = max(lower, slice.sourceStart)
            let end = min(upper, slice.sourceEnd)
            guard end > start else { return nil }
            return (
                slice.outputStart + (start - slice.sourceStart) / slice.rate,
                slice.outputStart + (end - slice.sourceStart) / slice.rate
            )
        }
    }

    func transcriptValues(
        _ transcript: [TranscriptSegment],
        mapper: ProjectTimeMapper
    ) -> [TranscriptValue] {
        transcript.map(\.normalized)
            .sorted { ($0.start, $0.end, $0.displayText) < ($1.start, $1.end, $1.displayText) }
            .flatMap { segment in
                outputRanges(sourceStart: segment.start, sourceEnd: segment.end, mapper: mapper).map {
                    TranscriptValue(start: $0.start, end: $0.end, text: safeLabel(segment.displayText))
                }
            }
    }

    func makeVTT(
        captions: [CaptionCue],
        transcript: [TranscriptSegment],
        mapper: ProjectTimeMapper,
        includeTranscript: Bool
    ) -> Data {
        let timedText: [(start: TimeInterval, end: TimeInterval, text: String)]
        if !captions.isEmpty {
            timedText = captions.map(\.normalized)
                .sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
                .map { ($0.start, $0.end, $0.text) }
        } else if includeTranscript {
            timedText = transcript.map(\.normalized)
                .sorted { ($0.start, $0.end, $0.displayText) < ($1.start, $1.end, $1.displayText) }
                .map { ($0.start, $0.end, $0.displayText) }
        } else {
            timedText = []
        }
        var lines = ["WEBVTT", ""]
        var cueNumber = 0
        for value in timedText {
            for range in outputRanges(sourceStart: value.start, sourceEnd: value.end, mapper: mapper) {
                cueNumber += 1
                lines.append(String(cueNumber))
                lines.append("\(vttTime(range.start)) --> \(vttTime(max(range.start + 0.001, range.end)))")
                lines.append(safeLabel(value.text))
                lines.append("")
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func tutorialTelemetry(
        source: URL,
        meta: ProjectMeta,
        mapper: ProjectTimeMapper
    ) -> TutorialTelemetry {
        var rawCursor: [CursorSample] = []
        var rawClicks: [ClickSample] = []
        var rawKeys: [KeySample] = []
        _ = try? ProjectJSON.streamJSONL(CursorSample.self, from: ProjectLayout.mouseURL(in: source)) { rawCursor.append($0) }
        _ = try? ProjectJSON.streamJSONL(ClickSample.self, from: ProjectLayout.clicksURL(in: source)) { rawClicks.append($0) }
        _ = try? ProjectJSON.streamJSONL(KeySample.self, from: ProjectLayout.keysURL(in: source)) { rawKeys.append($0) }

        let bounds = meta.displayBounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return TutorialTelemetry(cursor: [], clicks: [], shortcuts: tutorialShortcuts(rawKeys, mapper: mapper))
        }
        func position(x: Double, y: Double) -> (Double, Double)? {
            guard x.isFinite, y.isFinite else { return nil }
            let normalizedX = min(max((x - bounds.x) / bounds.width, 0), 1)
            let normalizedY = min(max((y - bounds.y) / bounds.height, 0), 1)
            return (normalizedX, normalizedY)
        }

        let orderedCursor = rawCursor.sorted {
            if $0.t != $1.t { return $0.t < $1.t }
            return ($0.sequence ?? 0) < ($1.sequence ?? 0)
        }
        var cursor: [TutorialCursorSample] = []
        var lastTime = -TimeInterval.infinity
        var lastVisibility: Bool?
        for sample in orderedCursor {
            guard let time = mapper.outputTime(forSourceTime: sample.t),
                  let point = position(x: sample.x, y: sample.y)
            else { continue }
            let visible = sample.isVisible
            guard time - lastTime >= (1.0 / 30.0) || visible != lastVisibility else { continue }
            cursor.append(TutorialCursorSample(time: time, x: point.0, y: point.1, visible: visible))
            lastTime = time
            lastVisibility = visible
        }

        let clicks = rawClicks
            .filter { $0.down && $0.button == .left }
            .sorted { ($0.t, $0.sequence ?? 0) < ($1.t, $1.sequence ?? 0) }
            .compactMap { click -> TutorialClick? in
                guard let time = mapper.outputTime(forSourceTime: click.t) else { return nil }
                let explicit = click.x.flatMap { x in click.y.flatMap { y in position(x: x, y: y) } }
                let nearest = orderedCursor.min { abs($0.t - click.t) < abs($1.t - click.t) }
                    .flatMap { position(x: $0.x, y: $0.y) }
                guard let point = explicit ?? nearest else { return nil }
                return TutorialClick(time: time, x: point.0, y: point.1)
            }
        return TutorialTelemetry(
            cursor: cursor,
            clicks: clicks,
            shortcuts: tutorialShortcuts(rawKeys, mapper: mapper)
        )
    }

    func tutorialShortcuts(_ samples: [KeySample], mapper: ProjectTimeMapper) -> [TutorialShortcut] {
        samples
            .filter { sample in
                sample.down && sample.modifiers.contains { modifier in
                    modifier == .command || modifier == .control || modifier == .option || modifier == .function
                }
            }
            .sorted { ($0.t, $0.sequence ?? 0) < ($1.t, $1.sequence ?? 0) }
            .compactMap { sample in
                mapper.outputTime(forSourceTime: sample.t).map {
                    TutorialShortcut(time: $0, label: safeLabel(sample.displayLabel))
                }
            }
    }

    func vttTime(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((seconds.isFinite ? seconds : 0) * 1000 + 0.5))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(format: "%02d:%02d:%02d.%03d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, milliseconds)
    }

    func makeMarkdown(output: PublishOutput, payload: DocumentationPayload) -> String {
        var text = "# " + safeLabel(output.name) + "\n\n"
        for (index, step) in payload.steps.enumerated() {
            text += "## " + String(index + 1) + ". " + markdownEscape(step.title) + "\n\n"
            text += markdownEscape(step.label) + "\n\n"
            if let shortcut = step.shortcut { text += "Shortcut: " + markdownEscape(shortcut) + "\n\n" }
            if let clickNote = step.clickNote { text += markdownEscape(clickNote) + "\n\n" }
            if let screenshot = step.screenshot { text += "![" + markdownEscape(step.title) + "](" + screenshot + ")\n\n" }
            if let tutorialPath = payload.tutorialPath {
                text += "[Play at " + String(format: "%.3f", step.start) + "s](" + tutorialPath + "#t=" + String(format: "%.3f", step.start) + ")\n\n"
            } else {
                text += "Timestamp: " + String(format: "%.3f", step.start) + "s\n\n"
            }
        }
        if !payload.transcript.isEmpty {
            text += "## Transcript\n\n"
            for line in payload.transcript { text += "- " + String(format: "%.3f", line.start) + "s — " + markdownEscape(line.text) + "\n" }
            text += "\n"
        }
        return text
    }

    func makeHTML(output: PublishOutput, payload: DocumentationPayload) -> String {
        let title = htmlEscape(safeLabel(output.name))
        var body = "<main><h1>\(title)</h1><ol>"
        for step in payload.steps {
            body += "<li><h2>\(htmlEscape(step.title))</h2><p>\(htmlEscape(step.label))</p>"
            if let shortcut = step.shortcut { body += "<p>Shortcut: <kbd>\(htmlEscape(shortcut))</kbd></p>" }
            if let clickNote = step.clickNote { body += "<p>\(htmlEscape(clickNote))</p>" }
            if let screenshot = step.screenshot { body += "<img src=\"\(htmlEscape(screenshot))\" alt=\"\(htmlEscape(step.title))\">" }
            if let tutorialPath = payload.tutorialPath {
                let time = String(format: "%.3f", step.start)
                body += "<a href=\"\(htmlEscape(tutorialPath))#t=\(time)\">Play at \(time)s</a>"
            } else {
                body += "<p>Timestamp: \(String(format: "%.3f", step.start))s</p>"
            }
            body += "</li>"
        }
        body += "</ol>"
        if !payload.transcript.isEmpty {
            body += "<section><h2>Transcript</h2><ul>"
            for line in payload.transcript { body += "<li>\(String(format: "%.3f", line.start))s — \(htmlEscape(line.text))</li>" }
            body += "</ul></section>"
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title><style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:56rem;margin:2rem auto;padding:0 1rem}img{max-width:100%;height:auto}</style></head><body>\(body)</main></body></html>"
    }

    func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func markdownEscape(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        for token in ["`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|", ">"] {
            escaped = escaped.replacingOccurrences(of: token, with: "\\" + token)
        }
        return escaped
    }

    func writeJPEG(from png: URL, to jpeg: URL) throws {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw OpenRecordError.io("Could not create tutorial poster image.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OpenRecordError.io("Could not finalize tutorial poster image.") }
    }

    func writeDefaultCursor(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 128,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OpenRecordError.io("Could not create tutorial cursor image.") }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 29))
        path.addLine(to: CGPoint(x: 4, y: 4))
        path.addLine(to: CGPoint(x: 22, y: 21))
        path.addLine(to: CGPoint(x: 13, y: 22))
        path.addLine(to: CGPoint(x: 18, y: 30))
        path.addLine(to: CGPoint(x: 13, y: 32))
        path.addLine(to: CGPoint(x: 8, y: 23))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.92))
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw OpenRecordError.io("Could not create tutorial cursor image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OpenRecordError.io("Could not finalize tutorial cursor image.") }
    }
}

private extension PublishedFile {
    static func file(at url: URL, root: URL) throws -> PublishedFile {
        let fm = FileManager.default
        let relative = ReleaseFactory.relativeSubpath(of: url, relativeTo: root)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let media = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return PublishedFile(
            relativePath: relative,
            byteCount: bytes,
            checksum: try ReleaseFactory.sha256(file: url),
            mediaType: media
        )
    }

    static func files(under target: URL, root: URL) throws -> [PublishedFile] {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw OpenRecordError.io("Generated output is missing: " + target.lastPathComponent + ".")
        }
        let urls: [URL]
        if isDirectory.boolValue {
            var found: [URL] = []
            if let enumerator = fm.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    var directory = ObjCBool(false)
                    if fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                        found.append(url)
                    }
                }
            }
            urls = found
        } else {
            urls = [target]
        }
        return try urls.map { try file(at: $0, root: root) }
            .sorted { $0.relativePath < $1.relativePath }
    }
}

private extension ReleaseFactory {
    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifyTutorialAllowlist(output: PublishedOutput, root: URL) -> [String] {
        let allowed: Set<String> = ["index.html", "player.js", "player.css", "video.mp4", "manifest.json", "captions.vtt", "cursor.png", "poster.jpg"]
        let paths = output.files.map(\.relativePath)
        guard let prefix = paths.first?.split(separator: "/").first.map(String.init) else { return ["Tutorial output has no files."] }
        var issues: [String] = []
        if !prefix.hasSuffix(".openrecordweb") {
            issues.append("Tutorial output directory must have extension .openrecordweb.")
        }
        let package = root.appendingPathComponent(prefix, isDirectory: true)
        if Self.hasSymlink(at: package) {
            issues.append("Tutorial package may not be a symbolic link.")
        }
        let actual = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count == 2, parts[0] == prefix else { return nil }
            return String(parts[1])
        })
        if actual != allowed || paths.count != allowed.count { issues.append("Tutorial output must contain exactly the allowlisted package files.") }
        if let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let name = Self.relativeSubpath(of: url, relativeTo: package)
                if Self.hasSymlink(at: url) {
                    issues.append("Tutorial package contains a symbolic link: \(name).")
                    continue
                }
                var directory = ObjCBool(false)
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                    if !allowed.contains(name) {
                        issues.append("Tutorial package contains non-allowlisted file \(name).")
                    }
                    if ["index.html", "player.js", "player.css"].contains(name),
                       let text = try? String(contentsOf: url, encoding: .utf8),
                       text.contains("http://") || text.contains("https://") {
                        issues.append("Tutorial output contains a remote URL.")
                    }
                }
            }
        }
        return issues
    }

    static let tutorialHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tutorial</title><link rel="stylesheet" href="player.css"></head>
    <body><main><header><p class="eyebrow">Open Tutorial Package</p><h1>Walkthrough</h1><div class="controls"><label>Search <input id="search" type="search" placeholder="Find a step or transcript" autocomplete="off"></label><label><input id="pause-after" type="checkbox"> Pause after step</label><label><input id="show-cursor" type="checkbox" checked> Cursor</label><label>Cursor size <input id="cursor-scale" type="range" min="0.6" max="2.4" value="1" step="0.1"></label></div></header><section class="layout"><div><div class="stage"><video id="player" controls preload="metadata" poster="poster.jpg"><source src="video.mp4" type="video/mp4"><track kind="captions" src="captions.vtt" default></video><img id="cursor" src="cursor.png" alt="" aria-hidden="true"><span id="click" aria-hidden="true"></span><kbd id="shortcut" aria-live="polite"></kbd></div><p id="now" class="now" aria-live="polite"></p></div><aside><h2>Steps</h2><nav id="steps" aria-label="Tutorial steps"></nav></aside></section><section><h2>Search results</h2><div id="results" class="results"></div></section></main><script src="player.js"></script></body></html>
    """

    static let tutorialJS = """
    (() => {
      'use strict';
      const manifest = window.__OPENRECORD_MANIFEST || {};
      const steps = manifest.steps || [], transcript = manifest.transcript || [];
      const cursors = manifest.cursor || [], clicks = manifest.clicks || [], shortcuts = manifest.shortcuts || [];
      const player = document.getElementById('player'), stepNav = document.getElementById('steps');
      const search = document.getElementById('search'), results = document.getElementById('results');
      const pauseAfter = document.getElementById('pause-after'), showCursor = document.getElementById('show-cursor');
      const cursorScale = document.getElementById('cursor-scale'), cursor = document.getElementById('cursor');
      const click = document.getElementById('click'), shortcut = document.getElementById('shortcut'), now = document.getElementById('now');
      let selectedEnd = null;
      const seek = (time, end) => { player.currentTime = Number(time) || 0; selectedEnd = Number(end); player.play().catch(() => {}); };
      const button = (label, detail, time, end) => {
        const element = document.createElement('button'); element.type = 'button';
        const title = document.createElement('strong'); title.textContent = label;
        const copy = document.createElement('span'); copy.textContent = detail;
        element.append(title, copy); element.addEventListener('click', () => seek(time, end)); return element;
      };
      steps.forEach((step, index) => stepNav.appendChild(button(`${index + 1}. ${step.title}`, step.label || step.kind || '', step.start, step.end)));
      const renderResults = () => {
        const query = search.value.trim().toLocaleLowerCase(); results.replaceChildren();
        if (!query) { const hint = document.createElement('p'); hint.textContent = 'Search the approved ActionMap and transcript.'; results.appendChild(hint); return; }
        steps.filter(value => `${value.title} ${value.label} ${value.kind}`.toLocaleLowerCase().includes(query)).forEach(value => results.appendChild(button(value.title, value.label || value.kind || '', value.start, value.end)));
        transcript.filter(value => value.text.toLocaleLowerCase().includes(query)).forEach(value => results.appendChild(button(value.text, `Transcript · ${value.start.toFixed(1)}s`, value.start, value.end)));
        if (!results.children.length) { const empty = document.createElement('p'); empty.textContent = 'No matching steps or transcript.'; results.appendChild(empty); }
      };
      const latest = (values, time) => { let low = 0, high = values.length - 1, found = null; while (low <= high) { const mid = (low + high) >> 1; if (values[mid].time <= time) { found = values[mid]; low = mid + 1; } else high = mid - 1; } return found; };
      const position = (element, value) => { element.style.left = `${value.x * 100}%`; element.style.top = `${value.y * 100}%`; };
      const updateOverlays = () => {
        const time = player.currentTime || 0, point = latest(cursors, time);
        cursor.hidden = !showCursor.checked || !point || !point.visible; if (point) position(cursor, point);
        cursor.style.width = `${32 * Number(cursorScale.value)}px`;
        const activeClick = latest(clicks, time); const clickAge = activeClick ? time - activeClick.time : 99;
        click.hidden = clickAge < 0 || clickAge > 0.45; if (!click.hidden) { position(click, activeClick); click.style.setProperty('--age', Math.min(1, clickAge / 0.45)); }
        const activeShortcut = latest(shortcuts, time); const shortcutAge = activeShortcut ? time - activeShortcut.time : 99;
        shortcut.hidden = shortcutAge < 0 || shortcutAge > 1.5; shortcut.textContent = shortcut.hidden ? '' : activeShortcut.label;
        const activeStep = steps.find(value => time >= value.start && time < value.end);
        now.textContent = activeStep ? `${activeStep.title} — ${activeStep.label}` : '';
        if (pauseAfter.checked && selectedEnd !== null && Number.isFinite(selectedEnd) && time >= selectedEnd) { player.pause(); selectedEnd = null; }
      };
      search.addEventListener('input', renderResults); showCursor.addEventListener('change', updateOverlays); cursorScale.addEventListener('input', updateOverlays);
      player.addEventListener('timeupdate', updateOverlays); player.addEventListener('seeked', updateOverlays);
      const seekFromHash = () => { const match = location.hash.match(/^#t=([0-9]+(?:\\.[0-9]+)?)$/); if (match) player.currentTime = Math.min(Number(match[1]), Number(manifest.duration) || Number(match[1])); };
      player.addEventListener('loadedmetadata', seekFromHash, {once:true}); window.addEventListener('hashchange', seekFromHash);
      renderResults(); updateOverlays();
    })();
    """

    static let tutorialCSS = """
    :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0a0b0d;color:#f4f5f7}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 20% -10%,#26354a 0,transparent 36rem),#0a0b0d;color:#f4f5f7}main{width:min(1180px,calc(100% - 2rem));margin:0 auto;padding:2rem 0 4rem}.eyebrow{margin:0;color:#8da7cb;font-size:.75rem;font-weight:700;letter-spacing:.13em;text-transform:uppercase}h1{margin:.35rem 0 1.25rem;font-size:clamp(2rem,6vw,4.5rem);letter-spacing:-.05em}h2{font-size:.8rem;letter-spacing:.1em;text-transform:uppercase;color:#aeb9c8}.controls{display:flex;flex-wrap:wrap;gap:.75rem 1.25rem;align-items:center;margin-bottom:1.25rem;color:#c8d0db}.controls label{display:flex;gap:.5rem;align-items:center}input[type=search]{width:min(24rem,70vw);border:1px solid #394657;border-radius:.55rem;background:#12171e;color:inherit;padding:.65rem .8rem}.layout{display:grid;grid-template-columns:minmax(0,1fr) 18rem;gap:1rem}.stage{position:relative;overflow:hidden;border:1px solid #2b3441;border-radius:.8rem;background:#000;box-shadow:0 1.5rem 5rem #0008}.stage video{display:block;width:100%;background:#000}.stage #cursor,.stage #click{position:absolute;transform:translate(-12%,-8%);pointer-events:none}.stage #cursor{width:32px;height:auto;filter:drop-shadow(0 1px 2px #000)}.stage #click{width:3rem;height:3rem;border:3px solid #77b7ff;border-radius:50%;opacity:calc(1 - var(--age));transform:translate(-50%,-50%) scale(calc(.6 + var(--age)))}#shortcut{position:absolute;left:50%;bottom:12%;transform:translateX(-50%);border:1px solid #ffffff40;border-radius:.55rem;background:#10141de8;color:#fff;padding:.55rem .8rem;font-size:1.05rem;box-shadow:0 .5rem 2rem #0008}.now{min-height:1.5rem;color:#c8d0db}aside{border:1px solid #29313c;border-radius:.8rem;background:#11151bcc;padding:1rem}nav,.results{display:grid;gap:.5rem}button{display:grid;gap:.18rem;width:100%;border:1px solid #303b49;border-radius:.55rem;background:#171d25;color:inherit;padding:.7rem;text-align:left;cursor:pointer}button:hover,button:focus-visible{border-color:#75a9e8;background:#1c2734}button span{color:#9eabbc;font-size:.82rem}.results{grid-template-columns:repeat(auto-fit,minmax(14rem,1fr))}@media(max-width:780px){.layout{grid-template-columns:1fr}aside{order:2}}
    """
}
