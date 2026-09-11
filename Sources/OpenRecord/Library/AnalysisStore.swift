import CryptoKit
import Foundation

/// Failures while writing or explicitly reading an analysis cache.  Inspection
/// intentionally catches these failures and returns a rebuildable status.
public enum AnalysisStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidBundleRelativePath(String)
    case invalidManifest(String)
    case invalidSidecar(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleRelativePath(let path):
            "Analysis path must be a bundle-relative path: " + path
        case .invalidManifest(let message), .invalidSidecar(let message), .io(let message):
            message
        }
    }
}

/// Persistence and inspection for the optional, rebuildable analysis cache.
///
/// The store has no dependency on an analyzer implementation.  It accepts
/// already-encoded sidecar bytes, writes each file atomically as one cache
/// transaction, and only exposes metadata during inspection.
public struct AnalysisStore: Sendable {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL.standardizedFileURL
    }

    public var analysisDirectoryURL: URL {
        ProjectLayout.analysisDirectory(in: projectURL)
    }

    public var manifestURL: URL {
        ProjectLayout.analysisManifestURL(in: projectURL)
    }

    /// Atomically installs a complete manifest and the supplied sidecars.
    /// Existing analysis is replaced only after every new file has been
    /// written successfully to a sibling staging directory.
    public func write(
        manifest: AnalysisManifest,
        sidecars: [AnalysisSidecarKind: Data] = [:],
        index: Data? = nil
    ) throws {
        try validateAnalysisDirectory()
        try validateManifestForWrite(manifest)

        let fileManager = FileManager.default
        let stagingURL = projectURL.appendingPathComponent(
            "." + ProjectLayout.analysisDirectoryName + "." + UUID().uuidString + ".staging",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            let encodedManifest: Data
            do {
                encodedManifest = try ProjectJSON.encoder.encode(manifest)
            } catch {
                throw AnalysisStoreError.invalidManifest(
                    "Could not encode analysis manifest: " + error.localizedDescription
                )
            }
            try AtomicFileWrite.write(
                encodedManifest,
                to: stagingURL.appendingPathComponent(
                    ProjectLayout.analysisManifestFileName,
                    isDirectory: false
                )
            )

            for kind in sidecars.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                try AtomicFileWrite.write(
                    sidecars[kind] ?? Data(),
                    to: stagingURL.appendingPathComponent(kind.fileName, isDirectory: false)
                )
            }
            if let index {
                try AtomicFileWrite.write(
                    index,
                    to: stagingURL.appendingPathComponent(
                        ProjectLayout.analysisIndexFileName,
                        isDirectory: false
                    )
                )
            }
            try install(stagingURL: stagingURL, fileManager: fileManager)
        } catch let error as AnalysisStoreError {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw AnalysisStoreError.io(
                "Could not write analysis cache: " + error.localizedDescription
            )
        }
    }

    /// Convenience for callers that have no sidecars yet (for example, an
    /// analyzer that records progress before producing its first stream).
    public func writeManifest(_ manifest: AnalysisManifest) throws {
        try write(manifest: manifest)
    }

    /// Atomically replaces one known sidecar while preserving the other
    /// streams.  A manifest should generally be written last by an analyzer;
    /// this API exists for incremental stream production and recovery.
    public func writeSidecar(_ data: Data, kind: AnalysisSidecarKind) throws {
        try validateAnalysisDirectory()
        let destination = ProjectLayout.analysisURL(for: kind, in: projectURL)
        try validateAnalysisFile(destination)
        try AtomicFileWrite.write(data, to: destination)
    }

    public func writeIndex(_ data: Data) throws {
        try validateAnalysisDirectory()
        try validateAnalysisFile(ProjectLayout.analysisIndexURL(in: projectURL))
        try AtomicFileWrite.write(data, to: ProjectLayout.analysisIndexURL(in: projectURL))
    }

    public func readManifest() throws -> AnalysisManifest {
        try validateAnalysisDirectory()
        try validateAnalysisFile(manifestURL)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw AnalysisStoreError.io("Missing or unreadable analysis manifest")
        }
        do {
            return try ProjectJSON.decoder.decode(AnalysisManifest.self, from: data)
        } catch {
            throw AnalysisStoreError.invalidManifest("Invalid analysis manifest")
        }
    }

    public func readSidecar(kind: AnalysisSidecarKind) throws -> Data {
        let url = ProjectLayout.analysisURL(for: kind, in: projectURL)
        try validateAnalysisDirectory()
        try validateAnalysisFile(url)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AnalysisStoreError.io("Missing or unreadable " + kind.fileName)
        }
    }

    /// Inspects the cache against the fingerprints in its manifest.  This
    /// operation is best-effort: malformed, future, stale, and truncated
    /// caches are represented by a status and never thrown to the caller.
    public func inspect() -> AnalysisInspectionSummary {
        inspect(currentFingerprints: nil)
    }

    /// Inspects the cache against a caller-provided current fingerprint set.
    /// This is useful when a capture pipeline has already streamed its hashes.
    public func inspect(
        currentFingerprints: [AnalysisSourceFingerprint]
    ) -> AnalysisInspectionSummary {
        inspect(currentFingerprints: Optional(currentFingerprints))
    }

    public func inspect(
        sourceFingerprints: [AnalysisSourceFingerprint]
    ) -> AnalysisInspectionSummary {
        inspect(currentFingerprints: sourceFingerprints)
    }

    public static func inspect(projectURL: URL) -> AnalysisInspectionSummary {
        AnalysisStore(projectURL: projectURL).inspect()
    }

    public static func write(
        manifest: AnalysisManifest,
        sidecars: [AnalysisSidecarKind: Data] = [:],
        index: Data? = nil,
        to projectURL: URL
    ) throws {
        try AnalysisStore(projectURL: projectURL).write(
            manifest: manifest,
            sidecars: sidecars,
            index: index
        )
    }

    private func inspect(
        currentFingerprints suppliedFingerprints: [AnalysisSourceFingerprint]?
    ) -> AnalysisInspectionSummary {
        guard isAnalysisDirectorySafe() else {
            return AnalysisInspectionSummary(
                status: .malformed,
                warnings: ["Analysis cache path is outside the project bundle"]
            )
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: analysisDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return AnalysisInspectionSummary(status: .missing)
        }

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return AnalysisInspectionSummary(
                status: .missing,
                warnings: ["Analysis manifest is missing"]
            )
        }

        guard isAnalysisFileSafe(manifestURL) else {
            return AnalysisInspectionSummary(
                status: .malformed,
                warnings: ["Analysis manifest path is outside the project bundle"]
            )
        }

        let rawManifest: Data
        do {
            rawManifest = try Data(contentsOf: manifestURL)
        } catch {
            return AnalysisInspectionSummary(
                status: .malformed,
                warnings: ["Analysis manifest is unreadable"]
            )
        }

        let rawSchemaVersion = Self.schemaVersion(in: rawManifest)
        if let rawSchemaVersion, rawSchemaVersion > AnalysisManifest.currentSchemaVersion {
            return AnalysisInspectionSummary(
                status: .future,
                warnings: ["Analysis schema version " + String(rawSchemaVersion) + " is newer than supported"],
                schemaVersion: rawSchemaVersion
            )
        }

        let manifest: AnalysisManifest
        do {
            manifest = try ProjectJSON.decoder.decode(AnalysisManifest.self, from: rawManifest)
        } catch {
            return AnalysisInspectionSummary(
                status: .malformed,
                warnings: ["Analysis manifest is malformed"],
                schemaVersion: rawSchemaVersion
            )
        }

        guard manifest.schemaVersion >= 1,
              manifest.schemaVersion <= AnalysisManifest.currentSchemaVersion,
              !manifest.analyzerVersion.isEmpty,
              !manifest.appVersion.isEmpty
        else {
            return AnalysisInspectionSummary(
                status: .malformed,
                warnings: ["Analysis manifest has invalid metadata"],
                schemaVersion: manifest.schemaVersion
            )
        }

        var warnings: [String] = manifest.warnings.isEmpty
            ? []
            : ["Analysis contains recoverable warnings"]
        var recordCounts: [AnalysisSidecarKind: Int] = [:]
        var malformedReason: String?

        for fingerprint in manifest.fingerprints {
            guard fingerprint.isWellFormed,
                  (try? Self.validateBundleRelativePath(fingerprint.bundleRelativePath)) != nil
            else {
                malformedReason = "Analysis manifest has an invalid source fingerprint"
                break
            }
        }

        if malformedReason == nil {
            for kind in AnalysisSidecarKind.allCases {
                let summary = manifest.sidecars[kind]
                let url = ProjectLayout.analysisURL(for: kind, in: projectURL)
                guard isAnalysisFileSafe(url) else {
                    malformedReason = "Analysis " + kind.fileName + " path is outside the project bundle"
                    break
                }
                let exists = fileManager.fileExists(atPath: url.path)
                if let summary {
                    guard summary.recordCount >= 0,
                          summary.byteCount == nil || summary.byteCount! >= 0,
                          summary.chunkCount == nil || summary.chunkCount! >= 0
                    else {
                        malformedReason = "Analysis manifest has an invalid sidecar count"
                        break
                    }
                    if summary.recordCount == 0 {
                        if let byteCount = summary.byteCount, byteCount > 0 {
                            malformedReason = "Analysis manifest has an invalid sidecar count"
                            break
                        }
                        if let chunkCount = summary.chunkCount, chunkCount > 0 {
                            malformedReason = "Analysis manifest has an invalid sidecar count"
                            break
                        }
                    } else {
                        if let byteCount = summary.byteCount, byteCount == 0 {
                            malformedReason = "Analysis manifest has an invalid sidecar count"
                            break
                        }
                        if let chunkCount = summary.chunkCount, chunkCount == 0 {
                            malformedReason = "Analysis manifest has an invalid sidecar count"
                            break
                        }
                    }
                }
                guard exists else {
                    // Empty optional streams do not need an on-disk file, but
                    // all declared metadata must still describe that absence.
                    if let summary,
                       summary.recordCount > 0 || summary.byteCount.map({ $0 != 0 }) == true
                    {
                        malformedReason = "Analysis " + kind.fileName + " is missing"
                        break
                    }
                    if summary != nil { recordCounts[kind] = 0 }
                    continue
                }

                let result = inspectSidecar(at: url, kind: kind)
                guard result.valid else {
                    malformedReason = "Analysis " + kind.fileName + " is malformed"
                    break
                }
                guard let summary else {
                    malformedReason = "Analysis " + kind.fileName + " has no manifest summary"
                    break
                }
                recordCounts[kind] = result.recordCount
                if result.recordCount != summary.recordCount {
                    malformedReason = "Analysis " + kind.fileName + " count does not match its manifest"
                    break
                }
                if let expectedByteCount = summary.byteCount,
                   expectedByteCount != result.byteCount
                {
                    malformedReason = "Analysis " + kind.fileName + " size does not match its manifest"
                    break
                }
            }
        }

        let indexURL = ProjectLayout.analysisIndexURL(in: projectURL)
        if malformedReason == nil,
           fileManager.fileExists(atPath: indexURL.path),
           !isAnalysisFileSafe(indexURL)
        {
            malformedReason = "Analysis index.json path is outside the project bundle"
        }
        if malformedReason == nil,
           fileManager.fileExists(atPath: indexURL.path),
           !inspectIndex(at: indexURL)
        {
            malformedReason = "Analysis index.json is malformed"
        }
        if malformedReason == nil {
            for summary in manifest.sidecars.values {
                guard let indexPath = summary.indexPath else { continue }
                guard let declaredIndexURL = declaredIndexURL(for: indexPath),
                      fileManager.fileExists(atPath: declaredIndexURL.path),
                      inspectIndex(at: declaredIndexURL)
                else {
                    malformedReason = "Analysis declared index is missing or malformed"
                    break
                }
            }
        }

        if let malformedReason {
            warnings.append(malformedReason)
            return AnalysisInspectionSummary(
                status: .malformed,
                recordCounts: recordCounts,
                warnings: Self.stableUnique(warnings),
                schemaVersion: manifest.schemaVersion
            )
        }

        if manifest.fingerprints.isEmpty {
            warnings.append("Analysis source provenance is unavailable")
            return AnalysisInspectionSummary(
                status: .partial,
                recordCounts: recordCounts,
                warnings: Self.stableUnique(warnings),
                schemaVersion: manifest.schemaVersion
            )
        }

        if !manifest.fingerprints.isEmpty {
            let current: [AnalysisSourceFingerprint]
            if let suppliedFingerprints {
                current = suppliedFingerprints
            } else {
                current = currentFingerprints(for: manifest)
            }
            guard Self.fingerprintsMatch(expected: manifest.fingerprints, current: current) else {
                warnings.append("Analysis source fingerprints are stale")
                return AnalysisInspectionSummary(
                    status: .stale,
                    recordCounts: recordCounts,
                    warnings: Self.stableUnique(warnings),
                    schemaVersion: manifest.schemaVersion
                )
            }
        }

        let completionStatus: AnalysisAvailability
        switch manifest.completionState {
        case .complete:
            completionStatus = .fresh
        case .inProgress, .partial, .failed:
            completionStatus = .partial
            if manifest.completionState == .failed {
                warnings.append("Analysis did not complete")
            }
        }
        return AnalysisInspectionSummary(
            status: completionStatus,
            recordCounts: recordCounts,
            warnings: Self.stableUnique(warnings),
            schemaVersion: manifest.schemaVersion
        )
    }

    /// Validates and normalizes a path relative to a `.openrecord` bundle.
    /// Absolute paths, dot traversal, empty components, and symlink escapes
    /// are rejected before any source file is opened.
    public static func validateBundleRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\0"),
              !path.contains("\\")
        else {
            throw AnalysisStoreError.invalidBundleRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw AnalysisStoreError.invalidBundleRelativePath(path)
        }
        return components.joined(separator: "/")
    }

    private func validateAnalysisDirectory() throws {
        guard isAnalysisDirectorySafe() else {
            throw AnalysisStoreError.invalidBundleRelativePath(
                "analysis directory escapes its project bundle"
            )
        }
    }

    private func isAnalysisDirectorySafe() -> Bool {
        let resolvedRoot = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedAnalysisURL = resolvedRoot.appendingPathComponent(
            ProjectLayout.analysisDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        let resolvedAnalysis = analysisDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedAnalysis.path == expectedAnalysisURL.path else {
            return false
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: analysisDirectoryURL.path),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return false
        }
        return true
    }

    private func validateAnalysisFile(_ url: URL) throws {
        guard isAnalysisFileSafe(url) else {
            throw AnalysisStoreError.invalidBundleRelativePath(
                "analysis file escapes its project bundle"
            )
        }
    }

    private func isAnalysisFileSafe(_ url: URL) -> Bool {
        guard isAnalysisDirectorySafe() else { return false }
        let resolvedRoot = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedAnalysisURL = resolvedRoot.appendingPathComponent(
            ProjectLayout.analysisDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path == expectedAnalysisURL.path
            || resolvedURL.path.hasPrefix(expectedAnalysisURL.path + "/")
        else {
            return false
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return false
        }
        return true
    }

    private func declaredIndexURL(for rawPath: String) -> URL? {
        guard let relativePath = try? Self.validateBundleRelativePath(rawPath) else { return nil }
        let candidate: URL
        if relativePath == ProjectLayout.analysisIndexFileName {
            candidate = ProjectLayout.analysisIndexURL(in: projectURL)
        } else if relativePath == ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName {
            candidate = ProjectLayout.analysisIndexURL(in: projectURL)
        } else if relativePath.hasPrefix(ProjectLayout.analysisDirectoryName + "/") {
            candidate = projectURL.appendingPathComponent(relativePath, isDirectory: false)
        } else {
            return nil
        }
        return isAnalysisFileSafe(candidate) ? candidate : nil
    }

    /// Streams a native CryptoKit SHA-256 digest without loading a media file
    /// into memory.  The returned path is always bundle-relative.
    public static func fingerprint(
        projectURL: URL,
        bundleRelativePath: String
    ) throws -> AnalysisSourceFingerprint {
        let relativePath = try validateBundleRelativePath(bundleRelativePath)
        let root = projectURL.standardizedFileURL
        let sourceURL = root.appendingPathComponent(relativePath, isDirectory: false)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedSource.path == resolvedRoot.path
                || resolvedSource.path.hasPrefix(resolvedRoot.path + "/")
        else {
            throw AnalysisStoreError.invalidBundleRelativePath(bundleRelativePath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw AnalysisStoreError.io("Missing source evidence " + relativePath)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw AnalysisStoreError.io("Could not read source evidence " + relativePath)
        }
        var hasher = SHA256()
        var count: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                if Int64.max - count < Int64(chunk.count) {
                    throw AnalysisStoreError.io("Source evidence is too large to fingerprint")
                }
                count += Int64(chunk.count)
                hasher.update(data: chunk)
            }
            try handle.close()
        } catch let error as AnalysisStoreError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw AnalysisStoreError.io("Could not fingerprint source evidence " + relativePath)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return AnalysisSourceFingerprint(
            bundleRelativePath: relativePath,
            byteCount: count,
            algorithm: "SHA-256",
            digest: digest
        )
    }

    public func fingerprint(bundleRelativePath: String) throws -> AnalysisSourceFingerprint {
        try Self.fingerprint(projectURL: projectURL, bundleRelativePath: bundleRelativePath)
    }

    public func fingerprint(for bundleRelativePath: String) throws -> AnalysisSourceFingerprint {
        try fingerprint(bundleRelativePath: bundleRelativePath)
    }

    public static func fingerprint(
        for bundleRelativePath: String,
        in projectURL: URL
    ) throws -> AnalysisSourceFingerprint {
        try fingerprint(projectURL: projectURL, bundleRelativePath: bundleRelativePath)
    }

    public func sourceFingerprint(for bundleRelativePath: String) throws -> AnalysisSourceFingerprint {
        try fingerprint(bundleRelativePath: bundleRelativePath)
    }

    /// Recomputes every source digest named by a manifest. Missing sources are
    /// omitted so callers can treat a count mismatch as stale without having
    /// to catch an I/O error for each optional track.
    public func currentFingerprints(
        for manifest: AnalysisManifest
    ) -> [AnalysisSourceFingerprint] {
        manifest.fingerprints.compactMap { fingerprint in
            try? self.fingerprint(bundleRelativePath: fingerprint.bundleRelativePath)
        }
    }

    private func validateManifestForWrite(_ manifest: AnalysisManifest) throws {
        guard manifest.schemaVersion >= 1,
              manifest.schemaVersion <= AnalysisManifest.currentSchemaVersion
        else {
            throw AnalysisStoreError.invalidManifest("Unsupported analysis schema version")
        }
        guard !manifest.analyzerVersion.isEmpty, !manifest.appVersion.isEmpty else {
            throw AnalysisStoreError.invalidManifest("Analysis manifest requires analyzer and app versions")
        }
        for fingerprint in manifest.fingerprints {
            guard fingerprint.isWellFormed else {
                throw AnalysisStoreError.invalidManifest("Analysis manifest has an invalid source fingerprint")
            }
            _ = try Self.validateBundleRelativePath(fingerprint.bundleRelativePath)
        }
        for summary in manifest.sidecars.values {
            guard summary.recordCount >= 0,
                  summary.byteCount == nil || summary.byteCount! >= 0,
                  summary.chunkCount == nil || summary.chunkCount! >= 0
            else {
                throw AnalysisStoreError.invalidManifest("Analysis manifest has an invalid sidecar count")
            }
            if summary.recordCount == 0 {
                if let byteCount = summary.byteCount, byteCount > 0 {
                    throw AnalysisStoreError.invalidManifest("Analysis manifest has non-zero bytes for zero records")
                }
                if let chunkCount = summary.chunkCount, chunkCount > 0 {
                    throw AnalysisStoreError.invalidManifest("Analysis manifest has non-zero chunks for zero records")
                }
            } else {
                if let byteCount = summary.byteCount, byteCount == 0 {
                    throw AnalysisStoreError.invalidManifest("Analysis manifest has zero bytes for non-zero records")
                }
                if let chunkCount = summary.chunkCount, chunkCount == 0 {
                    throw AnalysisStoreError.invalidManifest("Analysis manifest has zero chunks for non-zero records")
                }
            }
            if let indexPath = summary.indexPath {
                let validated = try Self.validateBundleRelativePath(indexPath)
                guard validated == ProjectLayout.analysisIndexFileName
                        || validated == ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName
                        || (validated.hasPrefix(ProjectLayout.analysisDirectoryName + "/") && !validated.contains(".."))
                else {
                    throw AnalysisStoreError.invalidManifest("Analysis sidecar index path must be within the analysis directory")
                }
            }
        }
    }

    private func install(stagingURL: URL, fileManager: FileManager) throws {
        try validateAnalysisDirectory()
        do {
            if fileManager.fileExists(atPath: analysisDirectoryURL.path) {
                if let attrs = try? fileManager.attributesOfItem(atPath: analysisDirectoryURL.path),
                   let type = attrs[.type] as? FileAttributeType,
                   type == .typeSymbolicLink {
                    throw AnalysisStoreError.invalidBundleRelativePath("analysis directory must not be a symbolic link")
                }
                _ = try fileManager.replaceItemAt(
                    analysisDirectoryURL,
                    withItemAt: stagingURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: analysisDirectoryURL)
            }
        } catch let error as AnalysisStoreError {
            throw error
        } catch {
            throw AnalysisStoreError.io("Could not install analysis cache")
        }
    }

    private struct SidecarInspection {
        let valid: Bool
        let recordCount: Int
        let byteCount: Int64
    }

    private func inspectSidecar(at url: URL, kind: AnalysisSidecarKind) -> SidecarInspection {
        guard let data = try? Data(contentsOf: url), data.count <= Int64.max else {
            return SidecarInspection(valid: false, recordCount: 0, byteCount: 0)
        }
        let byteCount = Int64(data.count)
        guard !data.isEmpty else {
            return SidecarInspection(valid: true, recordCount: 0, byteCount: byteCount)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return SidecarInspection(valid: false, recordCount: 0, byteCount: byteCount)
        }
        var count = 0
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: lineData,
                    options: [.fragmentsAllowed]
                  ),
                  JSONSerialization.isValidJSONObject(object) || object is NSNull
            else {
                return SidecarInspection(valid: false, recordCount: count, byteCount: byteCount)
            }
            count += 1
        }
        return SidecarInspection(valid: true, recordCount: count, byteCount: byteCount)
    }

    private func inspectIndex(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else { return false }
        return true
    }

    private static func schemaVersion(in data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["schemaVersion"] as? NSNumber
        else { return nil }
        return value.intValue
    }

    private static func fingerprintsMatch(
        expected: [AnalysisSourceFingerprint],
        current: [AnalysisSourceFingerprint]
    ) -> Bool {
        guard expected.count == current.count else { return false }
        var currentByPath: [String: AnalysisSourceFingerprint] = [:]
        for fingerprint in current {
            // Assignment rather than Dictionary(uniqueKeysWithValues:) keeps
            // malformed duplicate-path input a normal stale result instead
            // of allowing inspection to trap.
            currentByPath[fingerprint.bundleRelativePath] = fingerprint
        }
        return expected.allSatisfy { expectedFingerprint in
            guard let currentFingerprint = currentByPath[expectedFingerprint.bundleRelativePath] else {
                return false
            }
            return expectedFingerprint.byteCount == currentFingerprint.byteCount
                && expectedFingerprint.digest.caseInsensitiveCompare(currentFingerprint.digest) == .orderedSame
                && normalizedAlgorithm(expectedFingerprint.algorithm) == normalizedAlgorithm(currentFingerprint.algorithm)
        }
    }

    private static func normalizedAlgorithm(_ algorithm: String) -> String {
        algorithm.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
