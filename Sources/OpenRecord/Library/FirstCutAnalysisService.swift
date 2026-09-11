import Foundation

/// Persistence boundary for First Cut. Planning remains pure; this service
/// only loads captured evidence, reconciles review state, and writes the owned
/// `analysis/suggestions.jsonl` stream through the shared sidecar transaction.
public struct FirstCutAnalysisService: Sendable {
    public static let analyzerVersion = FirstCutPlanner.analyzerVersion

    public let projectURL: URL
    public let meta: ProjectMeta
    public let document: ProjectDocument
    public let preset: FirstCutPreset
    public var sourceFingerprints: [AnalysisSourceFingerprint]

    public init(
        projectURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        preset: FirstCutPreset = .naturalDemo,
        sourceFingerprints: [AnalysisSourceFingerprint] = []
    ) {
        self.projectURL = projectURL.standardizedFileURL
        self.meta = meta
        self.document = document
        self.preset = preset
        self.sourceFingerprints = sourceFingerprints
    }

    /// Runs deterministic First Cut, preserving accepted/rejected decisions
    /// already written in the suggestions sidecar.
    @discardableResult
    public func analyze(
        input: FirstCutAnalysisInput? = nil,
        existing: [FirstCutProposal]? = nil
    ) async throws -> FirstCutPlan {
        try Task.checkCancellation()
        let prior = try existing ?? loadSuggestions()
        let resolvedInput = input ?? loadInput()
        try Task.checkCancellation()
        let plan = try await FirstCutPlanner(preset: preset).plan(resolvedInput, existing: prior)
        try persist(plan)
        return plan
    }

    public func regenerate(
        input: FirstCutAnalysisInput? = nil
    ) async throws -> FirstCutPlan {
        try await analyze(input: input)
    }

    /// Loads the current proposal stream. Missing analysis is an empty review;
    /// malformed records are surfaced so callers can present a rebuild action.
    public func loadSuggestions() throws -> [FirstCutProposal] {
        let url = ProjectLayout.analysisSuggestionsURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var values: [FirstCutProposal] = []
        do {
            try ProjectJSON.streamJSONL(FirstCutProposal.self, from: url) { value in
                values.append(value)
            }
        } catch {
            throw FirstCutAnalysisServiceError.malformedSuggestions(error.localizedDescription)
        }
        return values.sorted(by: Self.proposalOrder)
    }

    public func loadPlan() throws -> FirstCutPlan? {
        let values = try loadSuggestions()
        guard let first = values.first else { return nil }
        return FirstCutPlan(
            analysisRevision: first.analysisRevision,
            preset: first.preset,
            sourceDuration: values.map { $0.range.end }.max() ?? 0,
            proposals: values
        )
    }

    public func load() throws -> FirstCutPlan? { try loadPlan() }

    /// Updates review lifecycle state without changing ordinary project data.
    @discardableResult
    public func updateState(
        _ state: FirstCutProposalState,
        for proposalIDs: Set<FirstCutProposalID>
    ) throws -> [FirstCutProposal] {
        var proposals = try loadSuggestions()
        for index in proposals.indices where proposalIDs.contains(proposals[index].id) {
            proposals[index].state = state
        }
        try persist(proposals: proposals)
        return proposals
    }

    public func accept(_ proposalIDs: Set<FirstCutProposalID>) throws -> [FirstCutProposal] {
        try updateState(.accepted, for: proposalIDs)
    }

    public func reject(_ proposalIDs: Set<FirstCutProposalID>) throws -> [FirstCutProposal] {
        try updateState(.rejected, for: proposalIDs)
    }

    /// Pure, one-call document transformation for the app's undo grouping.
    public func materialize(
        _ plan: FirstCutPlan,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        FirstCutMaterializer.apply(plan, to: document, selectedIDs: selectedIDs)
    }

    public func apply(
        _ plan: FirstCutPlan,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        materialize(plan, selectedIDs: selectedIDs)
    }

    // MARK: - Sidecar persistence

    private func persist(_ plan: FirstCutPlan) throws {
        try persist(proposals: plan.proposals)
    }

    private func persist(proposals: [FirstCutProposal]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: ProjectLayout.analysisDirectory(in: projectURL),
            withIntermediateDirectories: true
        )
        var data = Data()
        for proposal in proposals.sorted(by: Self.proposalOrder) {
            data.append(try ProjectJSON.jsonlEncoder.encode(proposal))
            data.append(0x0A)
        }
        try AnalysisStore(projectURL: projectURL).updateSidecars(
            [.suggestions: data],
            analyzerVersion: Self.analyzerVersion,
            appVersion: meta.appVersion,
            fingerprints: sourceFingerprints.isEmpty ? nil : sourceFingerprints
        )
    }

    // MARK: - Capture evidence loading

    private func loadInput() -> FirstCutAnalysisInput {
        var actions: [ActionCandidate] = []
        var cursors: [CursorSample] = []
        var clicks: [ClickSample] = []
        var typing: [TypingSample] = []
        loadJSONL(ActionCandidate.self, url: ProjectLayout.analysisActionsURL(in: projectURL)) { actions.append($0) }
        loadJSONL(CursorSample.self, url: ProjectLayout.mouseURL(in: projectURL)) { cursors.append($0) }
        loadJSONL(ClickSample.self, url: ProjectLayout.clicksURL(in: projectURL)) { clicks.append($0) }
        loadJSONL(TypingSample.self, url: ProjectLayout.typingURL(in: projectURL)) { typing.append($0) }
        let audioSamples = loadAudioSamples()
        return FirstCutAnalysisInput(
            document: document,
            meta: meta,
            sourceDuration: meta.captureDiagnostics?.referenceDuration,
            audioSamples: audioSamples,
            transcript: document.transcript,
            actions: actions,
            cursorSamples: cursors,
            clicks: clicks,
            typingSamples: typing
        )
    }

    private func loadJSONL<Value: Decodable>(_ type: Value.Type, url: URL, receive: (Value) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = try? ProjectJSON.streamJSONL(type, from: url) { value in receive(value) }
    }

    private func loadAudioSamples() -> [AudioLevelSample] {
        let fileManager = FileManager.default
        let microphone = ProjectLayout.microphoneAudioURL(in: projectURL)
        let system = ProjectLayout.systemAudioURL(in: projectURL)
        let url: URL?
        if fileManager.fileExists(atPath: microphone.path) {
            url = microphone
        } else if fileManager.fileExists(atPath: system.path) {
            url = system
        } else {
            url = nil
        }
        guard let url else { return [] }
        return (try? LocalAudioLevelReader().read(from: url)) ?? []
    }

    private static func proposalOrder(_ lhs: FirstCutProposal, _ rhs: FirstCutProposal) -> Bool {
        if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

public enum FirstCutAnalysisServiceError: Error, LocalizedError, Sendable, Equatable {
    case malformedSuggestions(String)

    public var errorDescription: String? {
        switch self {
        case .malformedSuggestions(let reason): "Malformed First Cut suggestions: " + reason
        }
    }
}
