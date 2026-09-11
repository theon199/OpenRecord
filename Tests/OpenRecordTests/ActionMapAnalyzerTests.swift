import Foundation
import OpenRecord
import Testing

@Suite("ActionMap analysis")
struct ActionMapAnalyzerTests {
    @Test("analysis IDs and ordering are deterministic")
    func deterministicIDsAndOutput() throws {
        let semanticID = try AnalysisEvidenceID("caller-provided-uuid-like-ref")
        let input = ActionMapAnalysisInput(
            semanticEvents: [SemanticEventSample(
                id: semanticID,
                t: 1,
                kind: .activate,
                applicationBundleID: "com.example.Editor",
                role: "AXButton",
                label: "Save",
                bounds: Rect2D(x: 0.7, y: 0.8, width: 0.1, height: 0.05),
                confidence: 0.9,
                source: .accessibility,
                sequence: 3
            )],
            clicks: [
                ClickSample(t: 1.1, button: .left, down: true, x: 150, y: 90, sequence: 8),
                ClickSample(t: 1.16, button: .left, down: false, x: 150, y: 90, sequence: 9),
            ],
            cursorSamples: [
                CursorSample(t: 0.7, x: 80, y: 80, sequence: 0),
                CursorSample(t: 0.9, x: 140, y: 88, sequence: 1),
                CursorSample(t: 1.1, x: 150, y: 90, sequence: 2),
                CursorSample(t: 1.25, x: 150, y: 90, sequence: 3),
            ]
        )
        let first = ActionMapAnalyzer(input: input).analyze()
        let second = ActionMapAnalyzer(input: input).analyze()
        #expect(first == second)
        let save = first.first { $0.label == "Save" }
        #expect(save != nil)
        #expect(save?.id.rawValue.contains("caller-provided") == false)
        #expect(save?.id.rawValue.contains("semantic-seq-3") == true)
        #expect(save?.supportingSignals.contains("semantic-click-fusion") == true)
    }

    @Test("AX unavailable applications still produce generic click actions")
    func genericClickFallback() {
        let actions = ActionMapAnalyzer.analyze(
            semanticEvents: [SemanticEventSample(
                t: 5,
                kind: .genericClick,
                source: .telemetry,
                degradationReason: .accessibilityUnavailable
            )],
            clicks: [ClickSample(t: 2, button: .left, down: true)]
        )
        #expect(actions.contains { $0.kind == .click && $0.supportingSignals.contains("click-fallback") })
        #expect(actions.contains { $0.kind == .click && $0.evidenceSources.contains(.semantic) })
    }

    @Test("semantic activation fuses a nearby click and geometry")
    func semanticClickAndGeometryCorrelation() {
        let actions = ActionMapAnalyzer.analyze(
            semanticEvents: [SemanticEventSample(
                t: 4,
                kind: .activate,
                role: "AXButton",
                label: "Export",
                confidence: 0.8,
                source: .accessibility,
                sequence: 1
            )],
            clicks: [ClickSample(t: 4.2, button: .left, down: true, x: 20, y: 20, sequence: 2)],
            targetGeometry: [TargetGeometrySample(
                t: 4.1,
                bounds: Rect2D(x: 0, y: 0, width: 1, height: 1),
                available: true,
                sequence: 0
            )]
        )
        let action = actions.first { $0.label == "Export" }
        #expect(action?.evidenceSources.contains(.semantic) == true)
        #expect(action?.evidenceSources.contains(.click) == true)
        #expect(action?.evidenceSources.contains(.targetGeometry) == true)
        #expect(action?.supportingSignals.contains("window-geometry") == true)
        #expect(action?.start == 4)
        #expect(action?.end == 4.2)
    }

    @Test("typing bursts remain private and shortcuts are safely grouped")
    func typingPrivacyAndShortcuts() throws {
        let actions = ActionMapAnalyzer.analyze(
            keySamples: [
                KeySample(t: 1, key: "command", down: true, sequence: 0),
                KeySample(t: 1.1, key: "c", modifiers: [.command], down: true, sequence: 1),
                KeySample(t: 1.2, key: "ordinary", down: true, sequence: 2),
            ],
            typingSamples: [
                TypingSample(t: 2, x: 10, y: 10, sequence: 0),
                TypingSample(t: 2.4, x: 10, y: 10, sequence: 1),
                TypingSample(t: 2.8, x: 10, y: 10, sequence: 2),
            ]
        )
        let shortcut = actions.first { $0.kind == .shortcut }
        let textInput = actions.first { $0.kind == .textInput }
        #expect(shortcut?.label == "Shortcut ⌘C")
        #expect(shortcut?.evidenceIDs.count == 1)
        #expect(textInput?.label == "Text input")
        #expect(textInput?.supportingSignals.contains("privacy-safe") == true)

        let encoded = try ProjectJSON.encoder.encode(actions)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ordinary"))
    }

    @Test("transcript overlap is a signal and never transcript payload")
    func transcriptSignalWithoutLeakage() throws {
        let transcript = TranscriptSegment(
            start: 3,
            end: 4,
            recognizedText: "PRIVATE TRANSCRIPT SHOULD NOT BE COPIED",
            confidence: 0.9
        )
        let actions = ActionMapAnalyzer.analyze(
            clicks: [ClickSample(t: 3.5, button: .left, down: true, sequence: 0)],
            transcript: [transcript]
        )
        let action = try #require(actions.first)
        #expect(action.supportingSignals.contains("transcript-signal"))
        #expect(action.evidenceSources.contains(.transcript))
        #expect(action.evidenceIDs.contains(try AnalysisEvidenceID("transcript-line-0")))
        let encoded = try ProjectJSON.encoder.encode(action)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE TRANSCRIPT"))
    }

    @Test("Vision fallback never persists unclassified OCR text")
    func visionPrivacyBoundary() throws {
        let safe = VisionActionFallback.makeEvidence(
            id: try AnalysisEvidenceID("ocr-line-0"),
            t: 1,
            bounds: Rect2D(x: 0, y: 0, width: 1, height: 1),
            label: "Save",
            confidence: 0.7
        )
        let privateEvidence = VisionActionFallback.makeEvidence(
            id: try AnalysisEvidenceID("ocr-line-1"),
            t: 2,
            bounds: .unit,
            label: "person@example.com",
            confidence: 0.7
        )
        #expect(safe.label == nil)
        #expect(safe.degradationReason == .labelFiltered)
        #expect(privateEvidence.label == nil)
        #expect(privateEvidence.degradationReason == .labelFiltered)
        #expect(!String(decoding: try ProjectJSON.encoder.encode(privateEvidence), as: UTF8.self).contains("person@example.com"))
    }

    @Test("service persists, reloads, and rejects stale or malformed caches")
    func persistenceAndFreshness() async throws {
        let fixture = try ActionMapFixture()
        defer { fixture.destroy() }
        let meta = ProjectMeta(displayBounds: Rect2D(x: 0, y: 0, width: 100, height: 100), scale: 1, captureTarget: .display(id: 1))
        let document = ProjectDocument(transcript: [TranscriptSegment(start: 1, end: 2, recognizedText: "do not copy")])
        try fixture.write(meta: meta, document: document)
        try fixture.writeJSONL(
            [ClickSample(t: 1.1, button: .left, down: true, sequence: 0)],
            to: ProjectLayout.clicksURL(in: fixture.project)
        )

        let service = ActionMapAnalysisService(projectURL: fixture.project, meta: meta, document: document)
        let actions = try await service.analyze(includeVisionFallback: false)
        #expect(!actions.isEmpty)
        #expect(try service.loadFresh() == actions)
        #expect(AnalysisStore(projectURL: fixture.project).inspect().status == .fresh)

        try Data("changed".utf8).write(to: ProjectLayout.clicksURL(in: fixture.project))
        #expect(try service.loadFresh() == nil)

        try Data("{malformed".utf8).write(to: ProjectLayout.analysisManifestURL(in: fixture.project))
        #expect(try service.loadFresh() == nil)
    }
}

private struct ActionMapFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordActionMap-" + UUID().uuidString,
            isDirectory: true
        )
        project = root.appendingPathComponent("Fixture.openrecord", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(ProjectLayout.recordingDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    func write(meta: ProjectMeta, document: ProjectDocument) throws {
        try ProjectJSON.encoder.encode(meta).write(to: ProjectLayout.metaURL(in: project))
        try ProjectJSON.encoder.encode(document).write(to: ProjectLayout.documentURL(in: project))
    }

    func writeJSONL<Value: Encodable>(_ values: [Value], to url: URL) throws {
        var data = Data()
        for value in values {
            data.append(try ProjectJSON.jsonlEncoder.encode(value))
            data.append(0x0A)
        }
        try data.write(to: url)
    }
}
