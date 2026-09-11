import Foundation
import OpenRecord
import Testing

private func firstCutMeta(
    health: CaptureHealth? = nil,
    diagnostics: CaptureDiagnostics? = nil
) -> ProjectMeta {
    ProjectMeta(
        appVersion: "test",
        displayBounds: Rect2D(x: 0, y: 0, width: 1920, height: 1080),
        scale: 1,
        captureTarget: .display(id: 1),
        captureHealth: health,
        captureDiagnostics: diagnostics
    )
}

private func firstCutInput(document: ProjectDocument = ProjectDocument()) -> FirstCutAnalysisInput {
    FirstCutAnalysisInput(
        document: document,
        meta: firstCutMeta(),
        sourceDuration: 8,
        transcript: [
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, start: 0.2, end: 1.0, recognizedText: "Open the app", confidence: 0.9),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, start: 3.2, end: 4.0, recognizedText: "Choose the menu", confidence: 0.8)
        ],
        actions: [ActionCandidate(
            id: try! AnalysisEvidenceID("action-1"),
            start: 1.5,
            end: 1.7,
            kind: .navigation,
            label: "Menu",
            bounds: Rect2D(x: 0.4, y: 0.4, width: 0.2, height: 0.1),
            confidence: 0.9,
            evidenceSources: [.semantic],
            evidenceIDs: [try! AnalysisEvidenceID("action-1")]
        )],
        cursorSamples: [
            CursorSample(t: 0.1, x: 100, y: 100, sequence: 1),
            CursorSample(t: 1.5, x: 500, y: 500, sequence: 2),
            CursorSample(t: 7.5, x: 500, y: 500, sequence: 3)
        ],
        clicks: [ClickSample(t: 1.5, button: .left, down: true, x: 500, y: 500, sequence: 1)],
        typingSamples: [TypingSample(t: 1.0, x: 100, y: 100, sequence: 1)]
    )
}

@Test("First Cut planning is deterministic and does not mutate the document")
func firstCutPlanningIsDeterministicAndNonMutating() async throws {
    let input = firstCutInput()
    let original = input.document
    let first = try await FirstCutPlanner(preset: .tightTutorial).plan(input)
    let second = try await FirstCutPlanner(preset: .tightTutorial).plan(input)

    #expect(first == second)
    #expect(input.document == original)
    #expect(first.proposals.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
    #expect(first.proposals.map(\.id).count == Set(first.proposals.map(\.id)).count)
}

@Test("First Cut is cancellation aware")
func firstCutCancellationIsObservable() async throws {
    let task = Task { () throws -> FirstCutPlan in
        try await FirstCutPlanner().plan(firstCutInput())
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    }
}

@Test("First Cut preserves accepted and rejected lifecycle state while staling obsolete proposals")
func firstCutLifecycleRegeneration() async throws {
    let initial = try await FirstCutPlanner().plan(firstCutInput())
    let firstID = try #require(initial.proposals.first?.id)
    let oldRejected = initial.proposals.first!.rejecting()
    let obsolete = FirstCutProposal(
        id: "obsolete",
        confidence: 0.4,
        payload: .cut(EditDecision(start: 6, end: 7))
    )
    let regenerated = try await FirstCutPlanner().plan(
        firstCutInput(),
        existing: [oldRejected, obsolete]
    )
    #expect(regenerated.proposals.first(where: { $0.id == firstID })?.state == .rejected)
    #expect(regenerated.proposals.first(where: { $0.id == obsolete.id })?.state == .stale)
}

@Test("First Cut materializes none, a subset, or all without mutating the input")
func firstCutMaterializationSelection() async throws {
    let plan = try await FirstCutPlanner().plan(firstCutInput())
    let actionable = plan.proposals.filter(\.isActionable)
    let original = ProjectDocument()
    let none = FirstCutMaterializer.apply(plan, to: original, selectedIDs: [])
    #expect(none == original)

    let one = try #require(actionable.first)
    let subset = FirstCutMaterializer.apply(plan, to: original, selectedIDs: [one.id])
    #expect(subset != original)
    let all = FirstCutMaterializer.applyAll(plan, to: original)
    #expect(all != original)
    #expect(original == ProjectDocument())
}

@Test("First Cut preserves manual cuts and locked zooms")
func firstCutPreservesManualAndLockedEdits() async throws {
    let manualCut = EditDecision(start: 1.8, end: 3.0)
    let lockedZoom = ZoomRange(
        start: 1.2,
        end: 2.5,
        amount: 2,
        anchor: Point2D(x: 0.5, y: 0.5),
        isLocked: true,
        source: .manual
    )
    let document = ProjectDocument(zoomRanges: [lockedZoom], editDecisions: [manualCut])
    let input = firstCutInput(document: document)
    let plan = try await FirstCutPlanner().plan(input)
    let output = FirstCutMaterializer.applyAll(plan, to: document)

    #expect(output.editDecisions.contains(manualCut))
    #expect(output.zoomRanges.contains(lockedZoom))
    #expect(output.zoomRanges.filter { $0.isLocked }.count == 1)
}

@Test("First Cut sidecar persistence preserves unrelated analysis streams")
func firstCutSidecarLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FirstCut-\(UUID().uuidString).openrecord", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ProjectLayout.analysisDirectory(in: root), withIntermediateDirectories: true)

    let store = AnalysisStore(projectURL: root)
    try store.updateSidecars(
        [.actions: Data("{\"kind\":\"click\"}\n".utf8)],
        analyzerVersion: "action-map-1",
        appVersion: "test"
    )
    let service = FirstCutAnalysisService(projectURL: root, meta: firstCutMeta(), document: ProjectDocument(), preset: .naturalDemo)
    let plan = try await service.analyze(input: firstCutInput())
    #expect(!plan.proposals.isEmpty)
    #expect(try store.readSidecar(kind: .actions) == Data("{\"kind\":\"click\"}\n".utf8))
    let loaded = try service.loadSuggestions()
    #expect(!loaded.isEmpty)
}

@Test("First Cut rejects unusable display capture health")
func firstCutValidatesCaptureHealth() async throws {
    let input = FirstCutAnalysisInput(
        document: ProjectDocument(),
        meta: firstCutMeta(health: CaptureHealth(state: .recovered, warnings: [.missingDisplayVideo])),
        sourceDuration: 2
    )
    await #expect(throws: FirstCutPlannerError.self) {
        try await FirstCutPlanner().plan(input)
    }
}
