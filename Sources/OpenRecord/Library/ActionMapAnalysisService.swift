import Foundation

/// Builds and reads the rebuildable ActionMap sidecars for one project.
/// Analysis is local and best-effort: a damaged optional telemetry stream is
/// reported as a warning while the other streams still contribute actions.
public struct ActionMapAnalysisService: Sendable {
    public static let analyzerVersion = ActionMapAnalyzer.analyzerVersion
    /// Keeps peak ActionMap memory independent of the raw 90–120 Hz mouse
    /// stream size while retaining uniformly spaced evidence across the full
    /// recording. Other action-bearing streams are naturally much sparser.
    public static let maximumRetainedCursorSamples = 120_000

    public let projectURL: URL
    public let meta: ProjectMeta
    public let document: ProjectDocument

    private let suppliedOCREvidence: [ActionOCREvidence]
    private let visionFallback: VisionActionFallback

    /// Preferred public service interface for project analysis.
    public init(projectURL: URL, meta: ProjectMeta, document: ProjectDocument) {
        self.init(
            projectURL: projectURL,
            meta: meta,
            document: document,
            ocrEvidence: [],
            visionFallback: VisionActionFallback()
        )
    }

    /// Adapter-facing initializer. A local Vision adapter can provide raw OCR
    /// observations here; the service filters them before either recognition
    /// or persistence. The preferred initializer remains source compatible.
    public init(
        projectURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        ocrEvidence: [ActionOCREvidence],
        visionFallback: VisionActionFallback = VisionActionFallback()
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.meta = meta
        self.document = document
        self.suppliedOCREvidence = ocrEvidence
        self.visionFallback = visionFallback
    }

    /// Rebuilds and persists all owned ActionMap sidecars. Missing or
    /// malformed source streams do not abort recognition; an I/O failure while
    /// installing the cache is surfaced to the caller.
    @discardableResult
    public func analyze(includeVisionFallback: Bool = true) async throws -> [ActionCandidate] {
        var loaded = loadStreams()
        let safeOCR: [ActionOCREvidence]
        if includeVisionFallback {
            if suppliedOCREvidence.isEmpty {
                do {
                    let fallbackTimes = loaded.clicks
                        .filter(\.down)
                        .map(\.t)
                        + loaded.semanticEvents
                            .filter { $0.kind == .genericClick }
                            .map(\.t)
                    safeOCR = try await visionFallback.analyze(
                        videoURL: ProjectLayout.displayVideoURL(in: projectURL),
                        timestamps: fallbackTimes
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    safeOCR = []
                    loaded.warnings.append("vision-fallback-unavailable")
                }
            } else {
                safeOCR = visionFallback.filter(suppliedOCREvidence)
            }
        } else {
            safeOCR = []
        }
        let analyzer = ActionMapAnalyzer(
            semanticEvents: loaded.semanticEvents,
            clicks: loaded.clicks,
            cursorSamples: loaded.cursorSamples,
            keySamples: loaded.keySamples,
            typingSamples: loaded.typingSamples,
            targetGeometry: loaded.targetGeometry,
            ocrEvidence: safeOCR,
            transcript: document.transcript,
            displayBounds: meta.displayBounds
        )
        let actions = analyzer.analyze()
        try persist(
            actions: actions,
            ocr: safeOCR,
            fingerprints: sourceFingerprints(),
            warnings: loaded.warnings
        )
        return actions
    }

    /// Returns actions only when the cache is complete, well formed, and all
    /// influencing source fingerprints still match. Any missing, malformed,
    /// stale, or future cache is a normal rebuildable miss (`nil`).
    public func loadFresh() throws -> [ActionCandidate]? {
        let store = AnalysisStore(projectURL: projectURL)
        guard store.inspect().status == .fresh else { return nil }
        let url = ProjectLayout.analysisActionsURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var actions: [ActionCandidate] = []
        do {
            try ProjectJSON.streamJSONL(ActionCandidate.self, from: url) { action in
                actions.append(action.normalized)
            }
        } catch {
            // A cache is optional and never a reason to make opening a project
            // fail. `inspect()` normally catches this before reaching here;
            // this guard handles a race with a partial external write.
            return nil
        }
        return actions.sorted(by: Self.actionSort)
    }

    // MARK: - Source loading

    private struct LoadedStreams {
        var semanticEvents: [SemanticEventSample] = []
        var clicks: [ClickSample] = []
        var cursorSamples: [CursorSample] = []
        var keySamples: [KeySample] = []
        var typingSamples: [TypingSample] = []
        var targetGeometry: [TargetGeometrySample] = []
        var warnings: [String] = []
    }

    private func loadStreams() -> LoadedStreams {
        var streams = LoadedStreams()

        streams.cursorSamples = loadBounded(
            CursorSample.self,
            path: ProjectLayout.mouseURL(in: projectURL),
            maximumCount: Self.maximumRetainedCursorSamples,
            unreadableWarning: "mouse-stream-unreadable",
            decimatedWarning: "mouse-stream-decimated",
            warnings: &streams.warnings
        )
        load(
            ClickSample.self,
            path: ProjectLayout.clicksURL(in: projectURL),
            warning: "click-stream-unreadable"
        ) { streams.clicks.append($0) } onError: { streams.warnings.append($0) }
        load(
            KeySample.self,
            path: ProjectLayout.keysURL(in: projectURL),
            warning: "key-stream-unreadable"
        ) { streams.keySamples.append($0) } onError: { streams.warnings.append($0) }
        load(
            TypingSample.self,
            path: ProjectLayout.typingURL(in: projectURL),
            warning: "typing-stream-unreadable"
        ) { streams.typingSamples.append($0) } onError: { streams.warnings.append($0) }
        load(
            TargetGeometrySample.self,
            path: ProjectLayout.targetGeometryURL(in: projectURL),
            warning: "geometry-stream-unreadable"
        ) { streams.targetGeometry.append($0) } onError: { streams.warnings.append($0) }
        load(
            SemanticEventSample.self,
            path: ProjectLayout.semanticTargetsURL(in: projectURL),
            warning: "semantic-stream-unreadable"
        ) { streams.semanticEvents.append($0) } onError: { streams.warnings.append($0) }

        streams.warnings = stableUnique(streams.warnings)
        return streams
    }

    private func load<Value: Decodable>(
        _ type: Value.Type,
        path: URL,
        warning: String,
        receive: (Value) -> Void,
        onError: (String) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            _ = try ProjectJSON.streamJSONL(type, from: path) { value in receive(value) }
        } catch {
            // streamJSONL delivers all valid records before a malformed
            // interior line. Keep those records and mark only the stream.
            onError(warning)
        }
    }

    /// Deterministic streaming compaction. Whenever the retained set reaches
    /// the bound, the stride doubles and previously retained rows are thinned
    /// by original line index. This preserves full-duration coverage without
    /// allocating in proportion to the raw stream's event count.
    private func loadBounded<Value: Decodable>(
        _ type: Value.Type,
        path: URL,
        maximumCount: Int,
        unreadableWarning: String,
        decimatedWarning: String,
        warnings: inout [String]
    ) -> [Value] {
        guard maximumCount > 0,
              FileManager.default.fileExists(atPath: path.path)
        else { return [] }

        var retained: [(line: Int, value: Value)] = []
        retained.reserveCapacity(maximumCount + 1)
        var line = 0
        var stride = 1
        var didDecimate = false
        do {
            _ = try ProjectJSON.streamJSONL(type, from: path) { value in
                let currentLine = line
                line += 1
                if currentLine % stride == 0 {
                    retained.append((currentLine, value))
                }
                if retained.count > maximumCount {
                    stride *= 2
                    retained.removeAll { $0.line % stride != 0 }
                    didDecimate = true
                }
            }
        } catch {
            warnings.append(unreadableWarning)
        }
        if didDecimate { warnings.append(decimatedWarning) }
        return retained.map(\.value)
    }

    // MARK: - Fingerprinting and persistence

    private func sourceFingerprints() -> [AnalysisSourceFingerprint] {
        let paths = [
            ProjectLayout.metaFileName,
            ProjectLayout.documentFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.displayVideoFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.mouseFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.clicksFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.keysFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.typingFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.targetGeometryFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.semanticTargetsFileName,
        ]
        return paths.compactMap { relativePath in
            let url = projectURL.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AnalysisStore.fingerprint(
                projectURL: projectURL,
                bundleRelativePath: relativePath
            )
        }
    }

    private func persist(
        actions: [ActionCandidate],
        ocr: [ActionOCREvidence],
        fingerprints: [AnalysisSourceFingerprint],
        warnings: [String]
    ) throws {
        let actionData = try encodeJSONL(actions.map(\.normalized))
        let ocrData = try encodeJSONL(ocr)
        var sidecars: [AnalysisSidecarKind: Data] = [
            .actions: actionData,
            .ocr: ocrData,
        ]
        let preserved = capturePreservedSidecars()
        defer { cleanupPreservedFiles(preserved) }
        for (kind, value) in preserved.sidecars {
            sidecars[kind] = value.data
        }

        let indexData = try encodeIndex(actions: actions, ocr: ocr)
        var summaries: [AnalysisSidecarKind: AnalysisSidecarSummary] = [
            .actions: summary(for: actionData),
            .ocr: summary(for: ocrData),
        ]
        for (kind, value) in preserved.sidecars {
            summaries[kind] = AnalysisSidecarSummary(
                recordCount: value.recordCount,
                byteCount: Int64(value.data.count),
                chunkCount: value.recordCount == 0 ? 0 : 1,
                indexPath: ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName
            )
        }

        let manifest = AnalysisManifest(
            analyzerVersion: Self.analyzerVersion,
            appVersion: meta.appVersion,
            fingerprints: fingerprints,
            completionState: .complete,
            warnings: warnings,
            sidecars: summaries.mapValues {
                AnalysisSidecarSummary(
                    recordCount: $0.recordCount,
                    byteCount: $0.byteCount,
                    chunkCount: $0.chunkCount,
                    indexPath: ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName
                )
            }
        )

        let store = AnalysisStore(projectURL: projectURL)
        try store.write(
            manifest: manifest,
            sidecars: sidecars,
            index: indexData
        )
        restorePreservedFiles(preserved.files)
    }

    private func encodeJSONL<Value: Encodable>(_ values: [Value]) throws -> Data {
        var data = Data()
        for value in values {
            data.append(try ProjectJSON.jsonlEncoder.encode(value))
            data.append(0x0A)
        }
        return data
    }

    private func summary(for data: Data) -> AnalysisSidecarSummary {
        let count = countJSONLLines(data)
        return AnalysisSidecarSummary(
            recordCount: count,
            byteCount: Int64(data.count),
            chunkCount: count == 0 ? 0 : 1,
            indexPath: ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName
        )
    }

    private struct IndexPayload: Codable {
        let schemaVersion: Int
        let actionCount: Int
        let actions: [IndexAction]
        let ocrCount: Int
        let ocrIDs: [AnalysisEvidenceID]
    }

    private struct IndexAction: Codable {
        let id: AnalysisEvidenceID
        let start: TimeInterval
        let end: TimeInterval
    }

    private func encodeIndex(actions: [ActionCandidate], ocr: [ActionOCREvidence]) throws -> Data {
        try ProjectJSON.encoder.encode(IndexPayload(
            schemaVersion: 1,
            actionCount: actions.count,
            actions: actions.sorted(by: Self.actionSort).map {
                IndexAction(id: $0.id, start: $0.start, end: $0.end)
            },
            ocrCount: ocr.count,
            ocrIDs: ocr.map(\.id)
        ))
    }

    private static func actionSort(_ lhs: ActionCandidate, _ rhs: ActionCandidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func countJSONLLines(_ data: Data) -> Int {
        guard let text = String(data: data, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData)
            else { return false }
            return object is [String: Any]
        }.count
    }

    // MARK: - Preservation of unrelated sidecars

    private struct PreservedSidecars {
        struct Sidecar {
            let data: Data
            let recordCount: Int
        }
        var sidecars: [AnalysisSidecarKind: Sidecar] = [:]
        var files: [(name: String, source: URL)] = []
        var temporaryDirectory: URL?
    }

    private func capturePreservedSidecars() -> PreservedSidecars {
        let analysisURL = ProjectLayout.analysisDirectory(in: projectURL)
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: analysisURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return PreservedSidecars() }

        var result = PreservedSidecars()
        let rewrittenNames = Set([
            ProjectLayout.analysisManifestFileName,
            ProjectLayout.analysisActionsFileName,
            ProjectLayout.analysisOCRFileName,
            ProjectLayout.analysisIndexFileName,
        ])
        let knownPreserved: [String: AnalysisSidecarKind] = [
            ProjectLayout.analysisPrivacyFileName: .privacy,
            ProjectLayout.analysisSuggestionsFileName: .suggestions,
        ]
        let fm = FileManager.default
        var backup: URL?
        for url in names {
            let name = url.lastPathComponent
            guard !rewrittenNames.contains(name) else { continue }
            if let kind = knownPreserved[name],
               let data = try? Data(contentsOf: url),
               isValidJSONL(data)
            {
                result.sidecars[kind] = PreservedSidecars.Sidecar(
                    data: data,
                    recordCount: countJSONLLines(data)
                )
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isDirectory != true
            else { continue }
            if backup == nil {
                let backupURL = projectURL.appendingPathComponent(
                    ".action-map-preserve-" + UUID().uuidString,
                    isDirectory: true
                )
                try? fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
                backup = backupURL
            }
            guard let backup else { continue }
            let destination = backup.appendingPathComponent(name, isDirectory: false)
            if (try? fm.copyItem(at: url, to: destination)) != nil {
                result.files.append((name: name, source: destination))
            }
        }
        result.temporaryDirectory = backup
        return result
    }

    private func restorePreservedFiles(_ files: [(name: String, source: URL)]) {
        let fm = FileManager.default
        let analysisURL = ProjectLayout.analysisDirectory(in: projectURL)
        for file in files {
            let destination = analysisURL.appendingPathComponent(file.name, isDirectory: false)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: file.source, to: destination)
        }
    }

    private func cleanupPreservedFiles(_ preserved: PreservedSidecars) {
        guard let temporaryDirectory = preserved.temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func isValidJSONL(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  object is [String: Any]
            else { return false }
        }
        return true
    }
}
