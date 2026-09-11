@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

public enum PrivacyAnalysisServiceError: Error, LocalizedError, Sendable, Equatable {
    case renderedVideoUnavailable
    case invalidRenderedVideo

    public var errorDescription: String? {
        switch self {
        case .renderedVideoUnavailable: "Rendered output video is unavailable."
        case .invalidRenderedVideo: "Rendered output video could not be scanned."
        }
    }
}

public typealias PrivacyServiceError = PrivacyAnalysisServiceError

/// Rebuilds and reads the Privacy Firewall sidecar.  Inputs supplied to the
/// service are transient; persistence is limited to `PrivacyFinding`, which
/// contains no recognized plaintext.
public struct PrivacyAnalysisService: Sendable {
    public static let analyzerVersion = PrivacyFirewallAnalyzer.analyzerVersion

    public let projectURL: URL
    public let meta: ProjectMeta?
    public let document: ProjectDocument?
    public let appVersion: String
    public let configuration: PrivacyAnalyzerConfiguration
    public let textObservations: [PrivacyTextObservation]
    public let semanticSignals: [PrivacySemanticSignal]
    public let windowSignals: [PrivacyWindowSignal]
    public let notificationSignals: [PrivacyNotificationSignal]
    public let accountSignals: [PrivacyAccountSignal]
    public let sensitiveTerms: [String]

    public var sourceFingerprints: [AnalysisSourceFingerprint] {
        currentSourceFingerprints()
    }

    public init(
        projectURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        textObservations: [PrivacyTextObservation] = [],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notificationSignals: [PrivacyNotificationSignal] = [],
        accountSignals: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        configuration: PrivacyAnalyzerConfiguration = .default
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.meta = meta
        self.document = document
        self.appVersion = meta.appVersion
        self.configuration = configuration
        self.textObservations = textObservations
        self.semanticSignals = semanticSignals
        self.windowSignals = windowSignals
        self.notificationSignals = notificationSignals
        self.accountSignals = accountSignals
        self.sensitiveTerms = sensitiveTerms
    }

    public init(
        projectURL: URL,
        appVersion: String = OpenRecordInfo.appVersion,
        textObservations: [PrivacyTextObservation] = [],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notificationSignals: [PrivacyNotificationSignal] = [],
        accountSignals: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        configuration: PrivacyAnalyzerConfiguration = .default
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.meta = nil
        self.document = nil
        self.appVersion = appVersion
        self.configuration = configuration
        self.textObservations = textObservations
        self.semanticSignals = semanticSignals
        self.windowSignals = windowSignals
        self.notificationSignals = notificationSignals
        self.accountSignals = accountSignals
        self.sensitiveTerms = sensitiveTerms
    }

    /// Compatibility label for callers that pass OCR observations directly.
    public init(
        projectURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        ocrObservations: [PrivacyTextObservation],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notifications: [PrivacyNotificationSignal] = [],
        accounts: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        configuration: PrivacyAnalyzerConfiguration = .default
    ) {
        self.init(
            projectURL: projectURL,
            meta: meta,
            document: document,
            textObservations: ocrObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notifications,
            accountSignals: accounts,
            sensitiveTerms: sensitiveTerms,
            configuration: configuration
        )
    }

    @discardableResult
    public func analyze() throws -> [PrivacyFinding] {
        try analyze(
            textObservations: textObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notificationSignals,
            accountSignals: accountSignals,
            sensitiveTerms: sensitiveTerms
        )
    }

    /// Runs analysis and installs only privacy.jsonl. `AnalysisStore` merges
    /// this update with valid ActionMap/suggestion sidecars already present.
    @discardableResult
    public func analyze(
        textObservations: [PrivacyTextObservation],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notificationSignals: [PrivacyNotificationSignal] = [],
        accountSignals: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        warnings: [String] = []
    ) throws -> [PrivacyFinding] {
        try Task.checkCancellation()
        let analyzer = PrivacyFirewallAnalyzer(
            textObservations: textObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notificationSignals,
            accountSignals: accountSignals,
            sensitiveTerms: sensitiveTerms,
            configuration: configuration
        )
        let findings = analyzer.analyze()
        try Task.checkCancellation()
        let prior = loadStoredFindings()
        let reconciled = Self.reconcile(regenerated: findings, previous: prior)
        try persist(findings: reconciled, warnings: warnings)
        return reconciled
    }

    /// Atomically saves the current review decisions. This is intentionally a
    /// sidecar operation: authored project state is never changed here.
    public func save(
        findings: [PrivacyFinding],
        warnings: [String] = []
    ) throws {
        try persist(findings: findings, warnings: warnings)
    }

    /// Updates one finding's review state and atomically rewrites privacy.jsonl.
    @discardableResult
    public func updateState(
        _ state: PrivacyFindingState,
        for id: AnalysisEvidenceID
    ) throws -> [PrivacyFinding] {
        var findings = loadStoredFindings()
        guard let index = findings.firstIndex(where: { $0.id == id }) else {
            return findings
        }
        findings[index] = findings[index].withState(state)
        try persist(findings: findings, warnings: [])
        return findings
    }

    public func setState(
        _ state: PrivacyFindingState,
        for id: AnalysisEvidenceID
    ) throws -> [PrivacyFinding] {
        try updateState(state, for: id)
    }

    @discardableResult
    public func updateState(
        _ state: PrivacyFindingState,
        for findingIDs: Set<AnalysisEvidenceID>
    ) throws -> [PrivacyFinding] {
        var findings = loadStoredFindings()
        for index in findings.indices where findingIDs.contains(findings[index].id) {
            findings[index] = findings[index].withState(state)
        }
        try persist(findings: findings, warnings: [])
        return findings
    }

    public func accept(_ findingIDs: Set<AnalysisEvidenceID>) throws -> [PrivacyFinding] {
        try updateState(.accepted, for: findingIDs)
    }

    public func reject(_ findingIDs: Set<AnalysisEvidenceID>) throws -> [PrivacyFinding] {
        try updateState(.rejected, for: findingIDs)
    }

    /// Loads a valid privacy sidecar. Partial caches without source
    /// fingerprints are accepted as local data; stale, malformed, or future
    /// caches are rebuildable misses and return nil.
    public func loadFresh() throws -> [PrivacyFinding]? {
        let store = AnalysisStore(projectURL: projectURL)
        let status = store.inspect(currentFingerprints: sourceFingerprints).status
        guard status == .fresh || status == .partial else { return nil }
        guard FileManager.default.fileExists(atPath: ProjectLayout.analysisPrivacyURL(in: projectURL).path) else {
            return []
        }
        var findings: [PrivacyFinding] = []
        do {
            try ProjectJSON.streamJSONL(PrivacyFinding.self, from: ProjectLayout.analysisPrivacyURL(in: projectURL)) {
                findings.append($0.normalized)
            }
        } catch {
            return nil
        }
        return findings.sorted(by: Self.findingOrder)
    }

    public func load() throws -> [PrivacyFinding]? { try loadFresh() }

    public func loadFindings() throws -> [PrivacyFinding]? { try loadFresh() }

    /// Reconciles regenerated candidates with an older cache. Accepted and
    /// rejected decisions are matched by category/fingerprint; old rows that
    /// disappeared from the new scan remain as stale evidence for review.
    public static func reconcile(
        regenerated: [PrivacyFinding],
        previous: [PrivacyFinding]
    ) -> [PrivacyFinding] {
        var consumed = Set<AnalysisEvidenceID>()
        var result: [PrivacyFinding] = []
        for candidate in regenerated {
            let match = previous.first { old in
                !consumed.contains(old.id)
                    && old.category == candidate.category
                    && old.fingerprint == candidate.fingerprint
                    && (old.state == .accepted || old.state == .rejected || old.state == .verified)
            }
            if let match {
                consumed.insert(match.id)
                result.append(PrivacyFinding(
                    id: match.id,
                    category: candidate.category,
                    confidence: candidate.confidence,
                    confidenceScore: candidate.confidenceScore,
                    state: match.state,
                    fingerprint: candidate.fingerprint,
                    tracks: candidate.tracks,
                    detectorCoverage: candidate.detectorCoverage
                ))
            } else {
                result.append(candidate)
            }
        }
        for old in previous where !consumed.contains(old.id) {
            if old.state != .stale {
                result.append(old.stale())
            }
        }
        return result.sorted(by: Self.findingOrder)
    }

    public func makeReport(
        findings: [PrivacyFinding],
        renderedOutput: PrivacyRenderedOutputVerificationInput? = nil,
        warnings: [String] = []
    ) -> PrivacyReport {
        analyzer().makeReport(
            findings: findings,
            renderedOutput: renderedOutput,
            warnings: warnings
        )
    }

    /// Scans the actual rendered movie at deterministic fixed timestamps plus
    /// every source timestamp represented by accepted findings. OCR results
    /// remain in memory only long enough to make the report.
    public func verifyRenderedOutput(
        findings: [PrivacyFinding],
        videoURL: URL? = nil,
        duration: TimeInterval? = nil,
        sampleInterval: TimeInterval = 1,
        scanner: PrivacyRenderedOutputScanner = PrivacyRenderedOutputScanner()
    ) async throws -> PrivacyReport {
        try Task.checkCancellation()
        let outputURL = videoURL ?? ProjectLayout.displayVideoURL(in: projectURL)
        let timestamps = Self.verificationTimestamps(
            for: findings,
            duration: duration,
            sampleInterval: sampleInterval,
            frameDuration: configuration.frameDuration
        )
        let input = try await scanner.scan(videoURL: outputURL, timestamps: timestamps)
        try Task.checkCancellation()
        return makeReport(findings: findings, renderedOutput: input)
    }

    public func scanRenderedOutput(
        videoURL: URL? = nil,
        timestamps: [TimeInterval]
    ) async throws -> PrivacyRenderedOutputVerificationInput {
        try await PrivacyRenderedOutputScanner().scan(
            videoURL: videoURL ?? ProjectLayout.displayVideoURL(in: projectURL),
            timestamps: timestamps
        )
    }

    // MARK: Persistence

    private func persist(findings: [PrivacyFinding], warnings: [String]) throws {
        // AnalysisStore's shared manifest points every declared stream at the
        // optional index. Ensure a minimal valid index exists for a brand-new
        // project; an existing index is retained byte-for-byte.
        let fileManager = FileManager.default
        let analysisDirectory = ProjectLayout.analysisDirectory(in: projectURL)
        try fileManager.createDirectory(at: analysisDirectory, withIntermediateDirectories: true)
        let indexURL = ProjectLayout.analysisIndexURL(in: projectURL)
        if !fileManager.fileExists(atPath: indexURL.path) {
            try AnalysisStore(projectURL: projectURL).writeIndex(Data("{}".utf8))
        }
        var data = Data()
        for finding in findings.sorted(by: Self.findingOrder) {
            data.append(try ProjectJSON.jsonlEncoder.encode(finding.normalized))
            data.append(0x0A)
        }
        var allWarnings = warnings
        allWarnings.append("Privacy analysis is local and best effort; no perfect detection claim is made.")
        try AnalysisStore(projectURL: projectURL).updateSidecars(
            [.privacy: data],
            analyzerVersion: Self.analyzerVersion,
            appVersion: appVersion,
            fingerprints: sourceFingerprints,
            warnings: Self.stableUnique(allWarnings)
        )
    }

    private func loadStoredFindings() -> [PrivacyFinding] {
        let url = ProjectLayout.analysisPrivacyURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var findings: [PrivacyFinding] = []
        guard (try? ProjectJSON.streamJSONL(PrivacyFinding.self, from: url) { value in
            findings.append(value.normalized)
        }) != nil else {
            return []
        }
        return findings.sorted(by: Self.findingOrder)
    }

    private func currentSourceFingerprints() -> [AnalysisSourceFingerprint] {
        let relativePaths = [
            ProjectLayout.metaFileName,
            ProjectLayout.documentFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.displayVideoFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.targetGeometryFileName,
            ProjectLayout.recordingDirectoryName + "/" + ProjectLayout.semanticTargetsFileName,
        ]
        return relativePaths.compactMap { relativePath in
            guard FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent(relativePath).path
            ) else { return nil }
            return try? AnalysisStore.fingerprint(
                projectURL: projectURL,
                bundleRelativePath: relativePath
            )
        }
    }

    private func analyzer() -> PrivacyFirewallAnalyzer {
        PrivacyFirewallAnalyzer(
            textObservations: textObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notificationSignals,
            accountSignals: accountSignals,
            sensitiveTerms: sensitiveTerms,
            configuration: configuration
        )
    }

    private static func findingOrder(_ lhs: PrivacyFinding, _ rhs: PrivacyFinding) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.category.rawValue != rhs.category.rawValue {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        return lhs.fingerprint.digest < rhs.fingerprint.digest
    }

    private static func verificationTimestamps(
        for findings: [PrivacyFinding],
        duration: TimeInterval?,
        sampleInterval: TimeInterval,
        frameDuration: TimeInterval
    ) -> [TimeInterval] {
        var values = Set<Double>()
        let interval = sampleInterval.isFinite && sampleInterval > 0 ? sampleInterval : 1
        if let duration, duration.isFinite, duration >= 0 {
            var t = 0.0
            while t <= duration {
                values.insert(t)
                t += interval
            }
            values.insert(max(duration, 0))
        }
        for finding in findings where finding.isAccepted {
            for observation in finding.observations {
                values.insert(max(observation.t, 0))
                if observation.duration > 0 {
                    values.insert(max(observation.t + observation.duration - frameDuration, 0))
                }
            }
        }
        if values.isEmpty { values.insert(0) }
        return values.sorted()
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Local Vision/AVFoundation adapter for a rendered-output privacy pass.
/// Recognized strings are returned only as transient observations and are not
/// persisted by this type.
public struct PrivacyRenderedOutputScanner: Sendable {
    public init() {}

    public func scan(
        videoURL: URL,
        timestamps: [TimeInterval]
    ) async throws -> PrivacyRenderedOutputVerificationInput {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: videoURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PrivacyAnalysisServiceError.renderedVideoUnavailable
        }

        let asset = AVURLAsset(url: videoURL)
        let duration: TimeInterval
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw PrivacyAnalysisServiceError.invalidRenderedVideo
        }
        guard duration.isFinite, duration >= 0 else {
            throw PrivacyAnalysisServiceError.invalidRenderedVideo
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = timestamps
            .filter { $0.isFinite && $0 >= 0 && $0 <= duration }
            .map { max($0, 0) }
            .reduce(into: Set<Double>()) { $0.insert($1) }
            .sorted()
        var observations: [PrivacyTextObservation] = []
        for timestamp in times {
            try Task.checkCancellation()
            guard let image = try await generateImage(
                with: generator,
                at: CMTime(seconds: timestamp, preferredTimescale: 600)
            ) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.005
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            guard let recognized = request.results else { continue }
            for (index, result) in recognized.enumerated() {
                guard let candidate = result.topCandidates(1).first,
                      !candidate.string.isEmpty
                else { continue }
                // Vision uses a bottom-left origin; OpenRecord geometry uses
                // normalized top-left coordinates.
                let box = result.boundingBox
                let rect = Rect2D(
                    x: Double(box.origin.x),
                    y: Double(1 - box.origin.y - box.height),
                    width: Double(box.width),
                    height: Double(box.height)
                )
                let id = try! AnalysisEvidenceID(
                    "rendered-ocr-" + String(Int((timestamp * 1_000).rounded())) + "-" + String(index)
                )
                observations.append(PrivacyTextObservation(
                    id: id,
                    t: timestamp,
                    duration: 0,
                    text: candidate.string,
                    rect: rect,
                    confidence: Double(candidate.confidence),
                    source: .renderedOutput,
                    coordinateSpace: .renderedOutput
                ))
            }
        }
        return PrivacyRenderedOutputVerificationInput(
            observations: observations,
            sampledTimestamps: times,
            frameCount: times.count
        )
    }

    private func generateImage(
        with generator: AVAssetImageGenerator,
        at time: CMTime
    ) async throws -> CGImage? {
        try Task.checkCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        }, onCancel: {
            generator.cancelAllCGImageGeneration()
        })
    }

    public func verify(
        videoURL: URL,
        timestamps: [TimeInterval],
        analyzer: PrivacyFirewallAnalyzer,
        findings: [PrivacyFinding]
    ) async throws -> PrivacyReport {
        let input = try await scan(videoURL: videoURL, timestamps: timestamps)
        return analyzer.makeReport(findings: findings, renderedOutput: input)
    }
}
