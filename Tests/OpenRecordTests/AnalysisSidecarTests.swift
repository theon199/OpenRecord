import Foundation
import OpenRecord
import Testing

@Test("analysis layout exposes the v4 sidecar files")
func analysisLayoutExposesSidecars() {
    let project = URL(fileURLWithPath: "/tmp/example.openrecord", isDirectory: true)
    #expect(ProjectLayout.analysisDirectory(in: project).lastPathComponent == "analysis")
    #expect(ProjectLayout.analysisManifestURL(in: project).lastPathComponent == "manifest.json")
    #expect(ProjectLayout.analysisActionsURL(in: project).lastPathComponent == "actions.jsonl")
    #expect(ProjectLayout.analysisOCRURL(in: project).lastPathComponent == "ocr.jsonl")
    #expect(ProjectLayout.analysisPrivacyURL(in: project).lastPathComponent == "privacy.jsonl")
    #expect(ProjectLayout.analysisSuggestionsURL(in: project).lastPathComponent == "suggestions.jsonl")
    #expect(ProjectLayout.analysisIndexURL(in: project).lastPathComponent == "index.json")
}

@Test("analysis contract validates opaque evidence IDs and bundle paths")
func analysisContractValidation() throws {
    let id = try AnalysisEvidenceID("mouse-0001")
    #expect(id.rawValue == "mouse-0001")
    #expect(AnalysisEvidenceID.isValid("ocr:0001"))
    #expect(!AnalysisEvidenceID.isValid("../private"))
    #expect(!AnalysisEvidenceID.isValid(""))
    #expect(throws: AnalysisContractError.self) {
        try AnalysisEvidenceID("not a stable id")
    }

    #expect(try AnalysisStore.validateBundleRelativePath("recording/display.mp4") == "recording/display.mp4")
    #expect(throws: AnalysisStoreError.self) {
        try AnalysisStore.validateBundleRelativePath("../outside")
    }
    #expect(throws: AnalysisStoreError.self) {
        try AnalysisStore.validateBundleRelativePath("/tmp/outside")
    }
    #expect(throws: AnalysisStoreError.self) {
        try AnalysisStore.validateBundleRelativePath("recording/../outside")
    }
}

@Test("analysis fingerprints stream SHA-256 source bytes")
func analysisFingerprintStreamsSHA256() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let source = fixture.project.appendingPathComponent("recording/display.mp4")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: source)

    let fingerprint = try AnalysisStore(projectURL: fixture.project).fingerprint(
        bundleRelativePath: "recording/display.mp4"
    )
    #expect(fingerprint.bundleRelativePath == "recording/display.mp4")
    #expect(fingerprint.byteCount == 5)
    #expect(fingerprint.algorithm == "SHA-256")
    #expect(fingerprint.digest == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test("analysis write and inspection report a fresh cache without payload")
func analysisWriteAndInspectFreshCache() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = try fixture.makeSourceAndStore()
    let actionData = Data("{\"kind\":\"click\",\"privateText\":\"do not report\"}\n".utf8)
    let fingerprint = try store.fingerprint(bundleRelativePath: "recording/display.mp4")
    let manifest = AnalysisManifest(
        analyzerVersion: "test-analyzer",
        appVersion: "test-app",
        fingerprints: [fingerprint],
        completionState: .complete,
        warnings: ["one recoverable warning"],
        sidecars: [
            .actions: AnalysisSidecarSummary(
                recordCount: 1,
                byteCount: Int64(actionData.count)
            )
        ]
    )
    try store.write(manifest: manifest, sidecars: [.actions: actionData])

    let summary = store.inspect()
    #expect(summary.status == .fresh)
    #expect(summary.recordCounts[.actions] == 1)
    #expect(summary.warnings == ["Analysis contains recoverable warnings"])
    #expect(!String(describing: summary).contains("do not report"))
    #expect(!summary.warnings.contains("one recoverable warning"))
    #expect(try store.readSidecar(kind: .actions) == actionData)
    #expect(try store.readManifest() == manifest)
}

@Test("analysis inspection detects stale sources and partial completion")
func analysisInspectionDetectsStaleAndPartial() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = try fixture.makeSourceAndStore()
    let fingerprint = try store.fingerprint(bundleRelativePath: "recording/display.mp4")
    let manifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        fingerprints: [fingerprint],
        completionState: .complete
    )
    try store.write(manifest: manifest)
    try Data("changed".utf8).write(to: fixture.project.appendingPathComponent("recording/display.mp4"))
    #expect(store.inspect().status == .stale)

    let partial = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .inProgress
    )
    try store.write(manifest: partial)
    #expect(store.inspect().status == .partial)
}

@Test("analysis inspection treats malformed and future caches as rebuildable")
func analysisInspectionTreatsMalformedAndFutureAsRebuildable() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = AnalysisStore(projectURL: fixture.project)
    try FileManager.default.createDirectory(at: ProjectLayout.analysisDirectory(in: fixture.project), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: ProjectLayout.analysisManifestURL(in: fixture.project))
    #expect(store.inspect().status == .malformed)

    let future = "{\"schemaVersion\":999,\"analyzerVersion\":\"future\",\"appVersion\":\"future\",\"completionState\":\"complete\"}"
    try Data(future.utf8).write(to: ProjectLayout.analysisManifestURL(in: fixture.project))
    #expect(store.inspect().status == .future)

    let malformedSidecarManifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.ocr: AnalysisSidecarSummary(recordCount: 1)]
    )
    try store.write(manifest: malformedSidecarManifest, sidecars: [.ocr: Data("not json\n".utf8)])
    #expect(store.inspect().status == .malformed)
}

@Test("analysis cache does not make project validation invalid")
func malformedAnalysisDoesNotInvalidateProject() async throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let meta = ProjectMeta(
        displayBounds: Rect2D(x: 0, y: 0, width: 1_920, height: 1_080),
        scale: 2,
        captureTarget: .display(id: 1)
    )
    let project = try ProjectLibrary(rootURL: fixture.root).create(name: "Analysis", meta: meta)
    try writeOpenRecordTestVideo(to: ProjectLayout.displayVideoURL(in: project))
    let analysisURL = ProjectLayout.analysisDirectory(in: project)
    try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
    try Data("truncated".utf8).write(to: ProjectLayout.analysisManifestURL(in: project))

    let validation = await OpenRecordAutomation().validate(project: project)
    #expect(validation.valid)
    #expect(validation.inspection.analysis.status == .malformed)
}

@Test("save copy and rename preserve analysis files")
func saveCopyAndRenamePreserveAnalysisFiles() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let meta = ProjectMeta(
        displayBounds: Rect2D(x: 0, y: 0, width: 1_920, height: 1_080),
        scale: 2,
        captureTarget: .display(id: 1)
    )
    let library = ProjectLibrary(rootURL: fixture.root)
    let project = try library.create(name: "Original", meta: meta)
    let store = AnalysisStore(projectURL: project)
    let payload = Data("{\"safe\":true}\n".utf8)
    let manifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 1, byteCount: Int64(payload.count))]
    )
    try store.write(manifest: manifest, sidecars: [.actions: payload])
    let unknownURL = ProjectLayout.analysisDirectory(in: project)
        .appendingPathComponent("future-extra.bin", isDirectory: false)
    try Data("future payload".utf8).write(to: unknownURL)

    let copy = try library.saveCopy(
        of: project,
        document: ProjectDocument(),
        to: fixture.root.appendingPathComponent("Copied.openrecord", isDirectory: true)
    )
    #expect(try Data(contentsOf: ProjectLayout.analysisActionsURL(in: copy)) == payload)
    #expect(try Data(contentsOf: ProjectLayout.analysisDirectory(in: copy).appendingPathComponent("future-extra.bin")) == Data("future payload".utf8))
    let renamed = try library.rename(copy, to: "Renamed")
    #expect(try Data(contentsOf: ProjectLayout.analysisActionsURL(in: renamed)) == payload)
    #expect(try Data(contentsOf: ProjectLayout.analysisDirectory(in: renamed).appendingPathComponent("future-extra.bin")) == Data("future payload".utf8))
}

@Test("analysis inspection never exposes secret manifest warning text")
func analysisInspectionNeverExposesSecretWarningText() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = try fixture.makeSourceAndStore()
    let secretString = "SUPER_SECRET_PII_TOKEN_DO_NOT_LEAK_42"
    let fingerprint = try store.fingerprint(bundleRelativePath: "recording/display.mp4")
    let manifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        fingerprints: [fingerprint],
        completionState: .complete,
        warnings: [secretString]
    )
    try store.write(manifest: manifest)
    let summary = store.inspect()
    #expect(summary.status == .fresh)
    #expect(!summary.warnings.contains(secretString))
    #expect(!summary.warnings.joined().contains("SECRET"))
    #expect(summary.warnings == ["Analysis contains recoverable warnings"])
    let stringified = String(describing: summary)
    #expect(!stringified.contains(secretString))
}

@Test("complete analysis manifest without source fingerprints is not fresh")
func completeManifestWithoutFingerprintsIsNotFresh() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = AnalysisStore(projectURL: fixture.project)
    let manifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        fingerprints: [],
        completionState: .complete
    )
    try store.write(manifest: manifest)
    let summary = store.inspect()
    #expect(summary.status != .fresh)
    #expect(summary.status == .partial)
}

@Test("analysis store rejects symlink escapes")
func analysisStoreRejectsSymlinkEscapes() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = try fixture.makeSourceAndStore()
    let escapedTarget = fixture.root.appendingPathComponent("outside_target.jsonl")
    let actionData = Data("{\"kind\":\"test\"}\n".utf8)
    try actionData.write(to: escapedTarget)
    let symlinkURL = ProjectLayout.analysisURL(for: .actions, in: fixture.project)
    try FileManager.default.createDirectory(at: ProjectLayout.analysisDirectory(in: fixture.project), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: escapedTarget)

    let fingerprint = try store.fingerprint(bundleRelativePath: "recording/display.mp4")
    let manifest = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        fingerprints: [fingerprint],
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 1, byteCount: Int64(actionData.count))]
    )
    let manifestData = try ProjectJSON.encoder.encode(manifest)
    try manifestData.write(to: ProjectLayout.analysisManifestURL(in: fixture.project))

    let summary = store.inspect()
    #expect(summary.status == .malformed)
    #expect(throws: AnalysisStoreError.self) {
        try store.readSidecar(kind: .actions)
    }

    // Also test symlink directory escape
    let dirFixture = try AnalysisFixture()
    defer { dirFixture.destroy() }
    let dirStore = try dirFixture.makeSourceAndStore()
    let outsideDir = dirFixture.root.appendingPathComponent("outside_dir", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: ProjectLayout.analysisDirectory(in: dirFixture.project),
        withDestinationURL: outsideDir
    )
    #expect(dirStore.inspect().status == .malformed)
}

@Test("analysis manifest rejects inconsistent sidecar byte and chunk counts")
func analysisManifestRejectsInconsistentCounts() throws {
    let fixture = try AnalysisFixture()
    defer { fixture.destroy() }
    let store = try fixture.makeSourceAndStore()

    // 0 records with >0 bytes
    let zeroRecordsWithBytes = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 0, byteCount: 100)]
    )
    #expect(throws: AnalysisStoreError.self) {
        try store.write(manifest: zeroRecordsWithBytes)
    }

    // >0 records with 0 bytes
    let positiveRecordsWithZeroBytes = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 5, byteCount: 0)]
    )
    #expect(throws: AnalysisStoreError.self) {
        try store.write(manifest: positiveRecordsWithZeroBytes)
    }

    // 0 records with >0 chunks
    let zeroRecordsWithChunks = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 0, chunkCount: 2)]
    )
    #expect(throws: AnalysisStoreError.self) {
        try store.write(manifest: zeroRecordsWithChunks)
    }

    // >0 records with 0 chunks
    let positiveRecordsWithZeroChunks = AnalysisManifest(
        analyzerVersion: "test",
        appVersion: "test",
        completionState: .complete,
        sidecars: [.actions: AnalysisSidecarSummary(recordCount: 5, chunkCount: 0)]
    )
    #expect(throws: AnalysisStoreError.self) {
        try store.write(manifest: positiveRecordsWithZeroChunks)
    }
}

private struct AnalysisFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRecordAnalysis-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Fixture.openrecord", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSourceAndStore() throws -> AnalysisStore {
        let source = project.appendingPathComponent("recording/display.mp4")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        return AnalysisStore(projectURL: project)
    }
}
