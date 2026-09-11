import Foundation
import OpenRecord
import Testing

@Suite("ActionMap contracts")
struct ActionMapContractTests {
    @Test("semantic persistence policy excludes secure and ordinary text")
    func semanticPrivacyPolicy() throws {
        #expect(SemanticPrivacyFilter.persistsOrdinaryTypedText == false)
        #expect(SemanticPrivacyFilter.sanitizeCapturedLabel(
            "Save",
            role: "AXButton"
        ) == "Save")
        #expect(SemanticPrivacyFilter.sanitizeCapturedLabel(
            "hunter2",
            role: "AXSecureTextField"
        ) == nil)
        #expect(SemanticPrivacyFilter.sanitizeCapturedLabel(
            "ordinary typed text",
            role: "AXTextField"
        ) == nil)
        #expect(SemanticPrivacyFilter.sanitizeCapturedLabel(
            "person@example.com",
            role: "AXButton"
        ) == nil)
        #expect(SemanticPrivacyFilter.sanitizeCapturedLabel(
            "sk-abcdefghijklmnopqrstuvwxyz012345",
            role: "AXButton"
        ) == nil)
    }

    @Test("semantic samples round-trip with fixed degradation reasons")
    func semanticSampleRoundTrip() throws {
        let sample = SemanticEventSample(
            id: try AnalysisEvidenceID("semantic-42"),
            t: 12.42,
            kind: .genericClick,
            bounds: Rect2D(x: 0.7, y: 0.8, width: 0.1, height: 0.05),
            confidence: 0.4,
            source: .telemetry,
            degradationReason: .accessibilityUnavailable,
            sequence: 7
        )
        let decoded = try ProjectJSON.decoder.decode(
            SemanticEventSample.self,
            from: ProjectJSON.encoder.encode(sample)
        )
        #expect(decoded == sample)
        #expect(decoded.label == nil)
    }

    @Test("story beats remain source-timed across cuts and speed changes")
    func storyBeatMapping() throws {
        let beat = StoryBeat(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            start: 8,
            end: 9,
            kind: .chapter,
            title: "Save",
            evidenceIDs: [try AnalysisEvidenceID("semantic-save")],
            isLocked: true
        )
        let document = ProjectDocument(
            trimOut: 20,
            speedSegments: [SpeedSegment(start: 10, end: 14, rate: 2)],
            editDecisions: [EditDecision(start: 4, end: 7)],
            storyBeats: [beat]
        )
        let mapper = ProjectTimeMapper(project: document, sourceDuration: 20)
        #expect(mapper.outputTime(forSourceTime: beat.start) == 5)
        #expect(mapper.clampedOutputTime(forSourceTime: 5) == 4)
        #expect(mapper.outputTime(forSourceTime: 12) == 8)
        #expect(document.storyBeats[0].start == 8)
        #expect(document.storyBeats[0].end == 9)
    }

    @Test("removing rebuildable analysis never changes authored story beats")
    func removingAnalysisPreservesAuthoredState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordActionAnalysis-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ProjectLibrary(rootURL: root)
        let projectURL = try library.create(
            name: "Action fixture",
            meta: ProjectMeta(displayBounds: .unit, scale: 1, captureTarget: .display(id: 1))
        )
        let beat = StoryBeat(
            start: 1,
            end: 2,
            title: "Renamed action",
            evidenceIDs: [try AnalysisEvidenceID("action-1")],
            isLocked: true
        )
        try library.save(document: ProjectDocument(storyBeats: [beat]), to: projectURL)
        let action = ActionCandidate(
            id: try AnalysisEvidenceID("action-1"),
            start: 1,
            end: 2,
            kind: .click,
            label: "Save",
            confidence: 0.8,
            evidenceSources: [.click],
            evidenceIDs: []
        )
        let payload = try ProjectJSON.jsonlEncoder.encode(action) + Data([0x0A])
        try AnalysisStore(projectURL: projectURL).write(
            manifest: AnalysisManifest(
                analyzerVersion: "test",
                appVersion: "test",
                completionState: .partial,
                sidecars: [.actions: AnalysisSidecarSummary(
                    recordCount: 1,
                    byteCount: Int64(payload.count)
                )]
            ),
            sidecars: [.actions: payload]
        )
        let before = try library.open(url: projectURL).document
        try FileManager.default.removeItem(at: ProjectLayout.analysisDirectory(in: projectURL))
        let after = try library.open(url: projectURL).document
        #expect(before == after)
        #expect(after.storyBeats == [beat])
    }
}
