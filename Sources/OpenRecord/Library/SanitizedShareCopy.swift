import CryptoKit
import Foundation

/// A small, privacy-safe fallback report that can be passed to
/// ``SanitizedShareCopyService`` before the Privacy Firewall's richer report
/// contract is available.
///
/// Finding text is intentionally not represented by this type.  A future
/// firewall report may be passed directly to the service through its generic
/// `Encodable & Sendable` API, but it should retain the same rule: persist
/// categories, counts, confidence, and fingerprints rather than recognized
/// plaintext.
public struct SanitizedSharePrivacySummary: Codable, Sendable, Hashable {
    public var generatedAt: Date
    public var detectorCoverage: [String]
    public var detectedCategories: [String]
    public var findingCount: Int
    public var notes: [String]

    public init(
        generatedAt: Date = Date(),
        detectorCoverage: [String] = [],
        detectedCategories: [String] = [],
        findingCount: Int = 0,
        notes: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.detectorCoverage = Self.stableUnique(detectorCoverage)
        self.detectedCategories = Self.stableUnique(detectedCategories)
        self.findingCount = max(findingCount, 0)
        self.notes = Self.stableUnique(notes)
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// The result of installing a sanitized derivative bundle.
///
/// The editable source bundle is not sanitized by this operation.  Detection
/// is not guaranteed to be perfect; callers should present that limitation
/// next to any share action and should run the Privacy Firewall's output scan.
public struct SanitizedShareCopyResult: Codable, Sendable, Hashable {
    public let destinationURL: URL
    public let includedPaths: [String]
    public let excludedPaths: [String]
    /// SHA-256 fingerprints keyed by bundle-relative path.  The privacy report
    /// itself is included here in the returned installation result, while the
    /// report's embedded map excludes itself to avoid a circular hash.
    public let fingerprints: [String: String]
    public let reportURL: URL
    public let sourceBundleSanitized: Bool
    public let detectionGuaranteedPerfect: Bool

    public var privacyReportURL: URL { reportURL }
    public var sha256: [String: String] { fingerprints }

    public init(
        destinationURL: URL,
        includedPaths: [String],
        excludedPaths: [String],
        fingerprints: [String: String],
        reportURL: URL,
        sourceBundleSanitized: Bool = false,
        detectionGuaranteedPerfect: Bool = false
    ) {
        self.destinationURL = destinationURL
        self.includedPaths = includedPaths
        self.excludedPaths = excludedPaths
        self.fingerprints = fingerprints
        self.reportURL = reportURL
        self.sourceBundleSanitized = sourceBundleSanitized
        self.detectionGuaranteedPerfect = detectionGuaranteedPerfect
    }
}

/// Builds and atomically installs a portable `.openrecord` derivative.
///
/// Only the already-rendered safe display movie is copied.  The source bundle
/// is never copied, and therefore its original display movie, audio, thumbnail,
/// cursors, analysis, and raw telemetry cannot leak into the derivative.  The
/// resulting bundle contains exactly `meta.json`, `project.json`,
/// `recording/display.mp4`, and `privacy-report.json`.
public struct SanitizedShareCopyService: Sendable {
    public static let includedPaths: [String] = [
        ProjectLayout.metaFileName,
        ProjectLayout.documentFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.displayVideoFileName,
        "privacy-report.json",
    ]

    /// Paths/categories intentionally absent from every derivative.  The
    /// source may contain additional files; those are excluded by the exact
    /// allowlist rather than copied by name.
    public static let excludedPaths: [String] = [
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.webcamVideoFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.microphoneAudioFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.systemAudioFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.thumbnailFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.mouseFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.clicksFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.keysFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.typingFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.targetGeometryFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.semanticTargetsFileName,
        ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.cursorsDirectoryName + "/**",
        ProjectLayout.analysisDirectoryName + "/**",
    ]

    public static let disclaimer =
        "The editable source bundle is not sanitized. Detection is not guaranteed perfect."

    public init() {}

    /// Creates a derivative using a report supplied by the Privacy Firewall.
    /// Any `Encodable & Sendable` report is accepted so the service can ship
    /// before that contract is frozen and can adopt it without an adapter.
    @discardableResult
    public func create<PrivacyReport: Encodable & Sendable>(
        sourceProjectURL: URL,
        renderedDisplayURL: URL,
        sourceMeta: ProjectMeta,
        sourceDocument: ProjectDocument,
        privacyReport: PrivacyReport,
        destinationURL: URL
    ) throws -> SanitizedShareCopyResult {
        try install(
            sourceProjectURL: sourceProjectURL,
            renderedDisplayURL: renderedDisplayURL,
            sourceMeta: sourceMeta,
            sourceDocument: sourceDocument,
            privacyReport: privacyReport,
            destinationURL: destinationURL
        )
    }

    /// Alias for callers that describe the safe input as a display movie.
    @discardableResult
    public func create<PrivacyReport: Encodable & Sendable>(
        sourceProjectURL: URL,
        safeDisplayURL: URL,
        sourceMeta: ProjectMeta,
        sourceDocument: ProjectDocument,
        privacyReport: PrivacyReport,
        destinationURL: URL
    ) throws -> SanitizedShareCopyResult {
        try install(
            sourceProjectURL: sourceProjectURL,
            renderedDisplayURL: safeDisplayURL,
            sourceMeta: sourceMeta,
            sourceDocument: sourceDocument,
            privacyReport: privacyReport,
            destinationURL: destinationURL
        )
    }

    /// Installs the derivative in one same-parent operation after every file
    /// is staged and verified.  If installation fails, the old destination is
    /// left untouched and the sibling staging directory is removed.
    @discardableResult
    public func install<PrivacyReport: Encodable & Sendable>(
        sourceProjectURL: URL,
        renderedDisplayURL: URL,
        sourceMeta: ProjectMeta,
        sourceDocument: ProjectDocument,
        privacyReport: PrivacyReport,
        destinationURL: URL
    ) throws -> SanitizedShareCopyResult {
        let fm = FileManager.default
        let sourceURL = try validatedSourceProjectURL(sourceProjectURL)
        let renderedURL = try validatedRenderedDisplayURL(renderedDisplayURL)
        let originalDisplayURL = ProjectLayout.displayVideoURL(in: sourceURL).standardizedFileURL
        guard renderedURL.standardizedFileURL != originalDisplayURL else {
            throw OpenRecordError.io(
                "Rendered display must be separate from the source display media"
            )
        }
        let destination = try validatedDestinationURL(
            destinationURL,
            sourceURL: sourceURL,
            renderedURL: renderedURL
        )

        // The source document is intentionally not copied.  The derivative
        // always uses a fresh timeline, so source-only edit fields cannot leak
        // into the independently openable package.
        _ = sourceDocument

        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent, named: "destination parent")

        // Capture metadata that is useful for opening the rendered movie, but
        // remove capture recovery, device, timing, and webcam details.
        let sanitizedMeta = privacyMinimizedMeta(sourceMeta)
        let renderedDocument = ProjectDocument()
        let metaData = try encodeJSON(sanitizedMeta, named: ProjectLayout.metaFileName)
        let documentData = try encodeJSON(renderedDocument, named: ProjectLayout.documentFileName)

        let staging = parent.appendingPathComponent(
            "." + destination.lastPathComponent + ".staging-" + UUID().uuidString,
            isDirectory: true
        )
        var installed = false
        defer {
            if !installed {
                try? fm.removeItem(at: staging)
            }
        }

        do {
            try fm.createDirectory(
                at: ProjectLayout.recordingDirectory(in: staging),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try write(metaData, to: ProjectLayout.metaURL(in: staging))
            try write(documentData, to: ProjectLayout.documentURL(in: staging))
            try fm.copyItem(
                at: renderedURL,
                to: ProjectLayout.displayVideoURL(in: staging)
            )

            let fingerprints = try fingerprintsForAssets(in: staging)
            let reportData = try encodeReport(
                privacyReport,
                fingerprints: fingerprints
            )
            try write(
                reportData,
                to: staging.appendingPathComponent("privacy-report.json", isDirectory: false)
            )
            try verifyAllowlist(staging)
            var resultFingerprints = fingerprints
            resultFingerprints["privacy-report.json"] = try sha256(
                fileAt: staging.appendingPathComponent("privacy-report.json", isDirectory: false)
            )

            if fm.fileExists(atPath: destination.path) {
                // replaceItemAt performs a same-directory replacement.  The
                // old bundle is not removed before the complete staged bundle
                // exists, so a failed copy cannot expose a partial derivative.
                _ = try fm.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            installed = true

            return SanitizedShareCopyResult(
                destinationURL: destination,
                includedPaths: Self.includedPaths,
                excludedPaths: Self.excludedPaths,
                fingerprints: resultFingerprints,
                reportURL: destination.appendingPathComponent("privacy-report.json", isDirectory: false)
            )
        } catch let error as OpenRecordError {
            throw error
        } catch {
            throw OpenRecordError.io(
                "Could not install sanitized share copy: " + error.localizedDescription
            )
        }
    }

    private func privacyMinimizedMeta(_ source: ProjectMeta) -> ProjectMeta {
        let bounds = Rect2D(
            x: source.displayBounds.x.isFinite ? source.displayBounds.x : 0,
            y: source.displayBounds.y.isFinite ? source.displayBounds.y : 0,
            width: source.displayBounds.width.isFinite ? max(source.displayBounds.width, 1) : 1,
            height: source.displayBounds.height.isFinite ? max(source.displayBounds.height, 1) : 1
        )
        let scale = source.scale.isFinite && source.scale > 0 ? source.scale : 1
        return ProjectMeta(
            createdAt: source.createdAt,
            appVersion: source.appVersion,
            displayBounds: bounds,
            scale: scale,
            // A derivative is not tied to the source display/window identity.
            captureTarget: .display(id: 0),
            captureTiming: nil,
            captureHealth: nil,
            captureDiagnostics: nil,
            webcam: nil
        )
    }

    private func validatedSourceProjectURL(_ url: URL) throws -> URL {
        try validateFileURL(url, named: "source project")
        guard !isSymbolicLink(url) else {
            throw OpenRecordError.io("Source project must not be a symbolic link")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw OpenRecordError.io("Source project is not a directory")
        }
        return url.standardizedFileURL
    }

    private func validatedRenderedDisplayURL(_ url: URL) throws -> URL {
        try validateFileURL(url, named: "rendered display")
        guard !isSymbolicLink(url) else {
            throw OpenRecordError.io("Rendered display must not be a symbolic link")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              isRegularFile(url)
        else {
            throw OpenRecordError.io("Rendered display is not a regular file")
        }
        return url.standardizedFileURL
    }

    private func validatedDestinationURL(
        _ url: URL,
        sourceURL: URL,
        renderedURL: URL
    ) throws -> URL {
        try validateFileURL(url, named: "destination")
        let destination = url.standardizedFileURL
        guard destination.pathExtension == ProjectLayout.bundleExtension else {
            throw OpenRecordError.io(
                "Destination must be a ." + ProjectLayout.bundleExtension + " bundle"
            )
        }
        if isSymbolicLink(destination) {
            throw OpenRecordError.io("Destination must not be a symbolic link")
        }
        let source = sourceURL.standardizedFileURL.path
        let rendered = renderedURL.standardizedFileURL.path
        let target = destination.path
        guard target != source, !target.hasPrefix(source + "/") else {
            throw OpenRecordError.io("Destination cannot be inside the source project")
        }
        guard target != rendered else {
            throw OpenRecordError.io("Destination cannot replace the rendered display")
        }
        if target.hasPrefix(rendered + "/") {
            throw OpenRecordError.io("Destination cannot contain the rendered display")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw OpenRecordError.io("Destination must be a project directory")
            }
        }
        return destination
    }

    private func validateFileURL(_ url: URL, named: String) throws {
        guard url.isFileURL, !url.path.isEmpty, url.path == url.standardizedFileURL.path else {
            throw OpenRecordError.io("Invalid " + named + " path")
        }
    }

    private func ensureDirectory(_ url: URL, named: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url) else {
                throw OpenRecordError.io(named.capitalized + " must not be a symbolic link")
            }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OpenRecordError.io(named.capitalized + " is not a directory")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OpenRecordError.io(
                "Could not create " + named + ": " + error.localizedDescription
            )
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T, named: String) throws -> Data {
        do {
            return try ProjectJSON.encoder.encode(value)
        } catch {
            throw OpenRecordError.io("Could not encode " + named + ": " + error.localizedDescription)
        }
    }

    private func encodeReport<PrivacyReport: Encodable>(
        _ privacyReport: PrivacyReport,
        fingerprints: [String: String]
    ) throws -> Data {
        let envelope = SharePrivacyReportEnvelope(
            privacyReport: privacyReport,
            includedPaths: Self.includedPaths,
            excludedPaths: Self.excludedPaths,
            sha256: fingerprints,
            sourceBundleSanitized: false,
            detectionGuaranteedPerfect: false,
            disclaimer: Self.disclaimer
        )
        do {
            return try ProjectJSON.encoder.encode(envelope)
        } catch {
            throw OpenRecordError.io(
                "Could not encode privacy-report.json: " + error.localizedDescription
            )
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw OpenRecordError.io(
                "Could not write " + url.lastPathComponent + ": " + error.localizedDescription
            )
        }
    }

    private func verifyAllowlist(_ staging: URL) throws {
        let allowed = Set(Self.includedPaths)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw OpenRecordError.io("Could not inspect staged sanitized share copy")
        }
        var files = Set<String>()
        for case let item as URL in enumerator {
            if isSymbolicLink(item) {
                throw OpenRecordError.io("Sanitized share copy contains a symbolic link")
            }
            var isDirectory = ObjCBool(false)
            guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                throw OpenRecordError.io("Staged sanitized share copy contains an unreadable path")
            }
            if !isDirectory.boolValue {
                let relative = relativePath(of: item, from: staging)
                files.insert(relative)
                guard allowed.contains(relative), isRegularFile(item) else {
                    throw OpenRecordError.io("Sanitized share copy contains excluded path " + relative)
                }
            }
        }
        guard files == allowed else {
            throw OpenRecordError.io("Sanitized share copy did not satisfy its exact allowlist")
        }
    }

    private func fingerprintsForAssets(in staging: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in Self.includedPaths where path != "privacy-report.json" {
            let url = staging.appendingPathComponent(path, isDirectory: false)
            result[path] = try sha256(fileAt: url)
        }
        return result
    }

    private func sha256(fileAt url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw OpenRecordError.io("Could not fingerprint " + url.lastPathComponent)
        }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw OpenRecordError.io("Could not fingerprint " + url.lastPathComponent)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let prefix = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return path
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}

private struct SharePrivacyReportEnvelope<PrivacyReport: Encodable>: Encodable {
    let formatVersion = 1
    let privacyReport: PrivacyReport
    let includedPaths: [String]
    let excludedPaths: [String]
    let sha256: [String: String]
    let sourceBundleSanitized: Bool
    let detectionGuaranteedPerfect: Bool
    let disclaimer: String
}
