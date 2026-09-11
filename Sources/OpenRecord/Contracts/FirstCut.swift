import Foundation

/// The three deterministic intents supported by the First Cut planner.
public enum FirstCutPreset: String, Codable, CaseIterable, Sendable, Hashable {
    case naturalDemo = "natural-demo"
    case tightTutorial = "tight-tutorial"
    case changelog

    public var title: String {
        switch self {
        case .naturalDemo: "Natural Demo"
        case .tightTutorial: "Tight Tutorial"
        case .changelog: "Changelog"
        }
    }

    public var minimumPause: TimeInterval {
        switch self {
        case .naturalDemo: 1.2
        case .tightTutorial: 0.7
        case .changelog: 0.5
        }
    }

    public var minimumInactivity: TimeInterval {
        switch self {
        case .naturalDemo: 2.5
        case .tightTutorial: 1.35
        case .changelog: 1.0
        }
    }

    public var breathingRoom: TimeInterval {
        switch self {
        case .naturalDemo: 0.18
        case .tightTutorial: 0.10
        case .changelog: 0.05
        }
    }

    public var repeatedAttemptRate: Double {
        switch self {
        case .naturalDemo: 1.6
        case .tightTutorial: 2.0
        case .changelog: 2.6
        }
    }

    // Source-compatible spellings useful to callers that use the plan's
    // product language rather than its wire-format names.
    public static var natural: Self { .naturalDemo }
    public static var tight: Self { .tightTutorial }
}

public typealias FirstCutIntentPreset = FirstCutPreset
public typealias FirstCutPlanningPreset = FirstCutPreset

/// Lifecycle of a derived proposal. The state is local review state and is
/// never copied into the authored ProjectDocument.
public enum FirstCutProposalState: String, Codable, CaseIterable, Sendable, Hashable {
    case pending
    case accepted
    case rejected
    case stale
}

public typealias FirstCutProposalStatus = FirstCutProposalState

public enum FirstCutProposalKind: String, Codable, CaseIterable, Sendable, Hashable {
    case cut
    case speed
    case zoom
    case caption
    case annotation
    case cursorEffect = "cursor-effect"
    case chapter

    public static var editDecision: Self { .cut }
    public static var storyBeat: Self { .chapter }
}

/// A stable, portable identity for a derived proposal. Planner identities are
/// content-derived; they must not be UUIDs generated at planning time.
public struct FirstCutProposalID: Codable, Sendable, Hashable, Identifiable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = cleaned.isEmpty ? "first-cut-proposal" : cleaned
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
}

/// A reference to evidence in a recording or another analysis sidecar. The
/// reference never stores recognized plaintext or mutable project values.
public struct FirstCutEvidenceReference: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var source: String
    public var start: TimeInterval?
    public var end: TimeInterval?

    public init(
        id: AnalysisEvidenceID,
        source: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.id = id
        self.source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        self.start = start?.isFinite == true ? max(start!, 0) : nil
        self.end = end?.isFinite == true ? max(end!, 0) : nil
    }

    public var stringID: String { id.rawValue }
}

/// Optional preview metadata retained with a proposal for review UIs.
public struct FirstCutPreview: Codable, Sendable, Hashable {
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval
    public var outputDurationBefore: TimeInterval?
    public var outputDurationAfter: TimeInterval?
    public var summary: String

    public init(
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        outputDurationBefore: TimeInterval? = nil,
        outputDurationAfter: TimeInterval? = nil,
        summary: String = ""
    ) {
        self.sourceStart = sourceStart.isFinite ? max(sourceStart, 0) : 0
        self.sourceEnd = sourceEnd.isFinite ? max(sourceEnd, self.sourceStart) : self.sourceStart
        self.outputDurationBefore = outputDurationBefore?.isFinite == true
            ? max(outputDurationBefore!, 0) : nil
        self.outputDurationAfter = outputDurationAfter?.isFinite == true
            ? max(outputDurationAfter!, 0) : nil
        self.summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    }
}

/// The ordinary project value materialized by a proposal. Associated values
/// are encoded with a stable tagged representation for JSONL persistence.
public enum FirstCutProposalPayload: Codable, Sendable, Hashable {
    case cut(EditDecision)
    case speed(SpeedSegment)
    case zoom(ZoomRange)
    case caption(CaptionCue)
    case annotation(Annotation)
    case cursorEffect(CursorEffectRange)
    case chapter(StoryBeat)

    public var kind: FirstCutProposalKind {
        switch self {
        case .cut: .cut
        case .speed: .speed
        case .zoom: .zoom
        case .caption: .caption
        case .annotation: .annotation
        case .cursorEffect: .cursorEffect
        case .chapter: .chapter
        }
    }

    public static func editDecision(_ value: EditDecision) -> Self { .cut(value) }
    public static func storyBeat(_ value: StoryBeat) -> Self { .chapter(value) }

    public var timeRange: (start: TimeInterval, end: TimeInterval) {
        switch self {
        case .cut(let value): (value.start, value.end)
        case .speed(let value): (value.start, value.end)
        case .zoom(let value): (value.start, value.end)
        case .caption(let value): (value.start, value.end)
        case .annotation(let value): (value.start, value.end)
        case .cursorEffect(let value): (value.start, value.end)
        case .chapter(let value): (value.start, value.end)
        }
    }

    public var editDecision: EditDecision? { if case .cut(let value) = self { value } else { nil } }
    public var speedSegment: SpeedSegment? { if case .speed(let value) = self { value } else { nil } }
    public var zoomRange: ZoomRange? { if case .zoom(let value) = self { value } else { nil } }
    public var captionCue: CaptionCue? { if case .caption(let value) = self { value } else { nil } }
    public var annotationValue: Annotation? { if case .annotation(let value) = self { value } else { nil } }
    public var cursorEffectRange: CursorEffectRange? { if case .cursorEffect(let value) = self { value } else { nil } }
    public var storyBeat: StoryBeat? { if case .chapter(let value) = self { value } else { nil } }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .cut(let value): try container.encode(value, forKey: .value)
        case .speed(let value): try container.encode(value, forKey: .value)
        case .zoom(let value): try container.encode(value, forKey: .value)
        case .caption(let value): try container.encode(value, forKey: .value)
        case .annotation(let value): try container.encode(value, forKey: .value)
        case .cursorEffect(let value): try container.encode(value, forKey: .value)
        case .chapter(let value): try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(FirstCutProposalKind.self, forKey: .kind)
        switch kind {
        case .cut: self = .cut(try container.decode(EditDecision.self, forKey: .value))
        case .speed: self = .speed(try container.decode(SpeedSegment.self, forKey: .value))
        case .zoom: self = .zoom(try container.decode(ZoomRange.self, forKey: .value))
        case .caption: self = .caption(try container.decode(CaptionCue.self, forKey: .value))
        case .annotation: self = .annotation(try container.decode(Annotation.self, forKey: .value))
        case .cursorEffect:
            self = .cursorEffect(try container.decode(CursorEffectRange.self, forKey: .value))
        case .chapter: self = .chapter(try container.decode(StoryBeat.self, forKey: .value))
        }
    }
}

public typealias FirstCutEditPayload = FirstCutProposalPayload

/// One deterministic, reviewable First Cut suggestion.
public struct FirstCutProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: FirstCutProposalID
    public var analysisRevision: String
    public var preset: FirstCutPreset
    public var kind: FirstCutProposalKind
    public var state: FirstCutProposalState
    public var confidence: Double
    public var evidence: [FirstCutEvidenceReference]
    public var reasons: [String]
    public var payload: FirstCutProposalPayload
    public var preview: FirstCutPreview?

    public init(
        id: FirstCutProposalID,
        analysisRevision: String = "first-cut-1",
        preset: FirstCutPreset = .naturalDemo,
        kind: FirstCutProposalKind? = nil,
        state: FirstCutProposalState = .pending,
        confidence: Double,
        evidence: [FirstCutEvidenceReference] = [],
        reasons: [String] = [],
        payload: FirstCutProposalPayload,
        preview: FirstCutPreview? = nil
    ) {
        self.id = id
        self.analysisRevision = String(analysisRevision.prefix(128))
        self.preset = preset
        self.kind = kind ?? payload.kind
        self.state = state
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.evidence = Self.stableEvidence(evidence)
        self.reasons = Self.stableStrings(reasons)
        self.payload = payload
        self.preview = preview
    }

    public var status: FirstCutProposalState {
        get { state }
        set { state = newValue }
    }

    public var evidenceReferences: [FirstCutEvidenceReference] {
        get { evidence }
        set { evidence = Self.stableEvidence(newValue) }
    }

    public var explanation: [String] {
        get { reasons }
        set { reasons = Self.stableStrings(newValue) }
    }

    public var evidenceIDs: [AnalysisEvidenceID] {
        get { evidence.map(\.id) }
        set { evidence = newValue.map { FirstCutEvidenceReference(id: $0, source: "analysis") } }
    }

    public var range: (start: TimeInterval, end: TimeInterval) { payload.timeRange }
    public var start: TimeInterval { range.start }
    public var end: TimeInterval { range.end }
    public var isActionable: Bool { state == .pending || state == .accepted }
    public var isPossible: Bool { state == .pending || state == .stale }
    public var isAccepted: Bool { state == .accepted }

    public var normalized: Self {
        Self(
            id: id,
            analysisRevision: analysisRevision,
            preset: preset,
            kind: payload.kind,
            state: state,
            confidence: confidence,
            evidence: evidence,
            reasons: reasons,
            payload: payload,
            preview: preview
        )
    }

    public func withState(_ newState: FirstCutProposalState) -> Self {
        var copy = self
        copy.state = newState
        return copy
    }

    public func accepted() -> Self { withState(.accepted) }
    public func rejected() -> Self { withState(.rejected) }
    public func stale() -> Self { withState(.stale) }

    public func accepting() -> FirstCutProposal {
        var copy = self
        if copy.state == .pending { copy.state = .accepted }
        return copy
    }

    public func rejecting() -> FirstCutProposal {
        var copy = self
        if copy.state == .pending { copy.state = .rejected }
        return copy
    }

    public mutating func accept() {
        if state == .pending { state = .accepted }
    }

    public mutating func reject() {
        if state == .pending { state = .rejected }
    }

    public mutating func markStale() {
        state = .stale
    }

    private static func stableStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func stableEvidence(_ values: [FirstCutEvidenceReference]) -> [FirstCutEvidenceReference] {
        var seen = Set<FirstCutEvidenceReference>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct FirstCutPlan: Codable, Sendable, Hashable {
    public var analysisRevision: String
    public var preset: FirstCutPreset
    public var sourceDuration: TimeInterval
    public var proposals: [FirstCutProposal]
    public var warnings: [String]

    public init(
        analysisRevision: String,
        preset: FirstCutPreset,
        sourceDuration: TimeInterval,
        proposals: [FirstCutProposal] = [],
        warnings: [String] = []
    ) {
        self.analysisRevision = String(analysisRevision.prefix(128))
        self.preset = preset
        self.sourceDuration = sourceDuration.isFinite ? max(sourceDuration, 0) : 0
        self.proposals = proposals.sorted { lhs, rhs in
            if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        var seen = Set<String>()
        self.warnings = warnings.filter { seen.insert($0).inserted }
    }

    public var suggestions: [FirstCutProposal] {
        get { proposals }
        set { proposals = newValue }
    }

    public var pending: [FirstCutProposal] { proposals.filter { $0.state == .pending } }
    public var accepted: [FirstCutProposal] { proposals.filter { $0.state == .accepted } }
    public var rejected: [FirstCutProposal] { proposals.filter { $0.state == .rejected } }
    public var stale: [FirstCutProposal] { proposals.filter { $0.state == .stale } }
}

/// Captured value-only evidence consumed by the deterministic planner.
public struct FirstCutAnalysisInput: Sendable, Hashable {
    public var document: ProjectDocument
    public var meta: ProjectMeta
    public var sourceDuration: TimeInterval?
    public var audioSamples: [AudioLevelSample]
    public var transcript: [TranscriptSegment]
    public var actions: [ActionCandidate]
    public var cursorSamples: [CursorSample]
    public var clicks: [ClickSample]
    public var typingSamples: [TypingSample]

    public init(
        document: ProjectDocument = ProjectDocument(),
        meta: ProjectMeta,
        sourceDuration: TimeInterval? = nil,
        audioSamples: [AudioLevelSample] = [],
        transcript: [TranscriptSegment] = [],
        actions: [ActionCandidate] = [],
        cursorSamples: [CursorSample] = [],
        clicks: [ClickSample] = [],
        typingSamples: [TypingSample] = []
    ) {
        self.document = document
        self.meta = meta
        self.sourceDuration = sourceDuration
        self.audioSamples = audioSamples
        self.transcript = transcript
        self.actions = actions
        self.cursorSamples = cursorSamples
        self.clicks = clicks
        self.typingSamples = typingSamples
    }

    public var actionMap: [ActionCandidate] {
        get { actions }
        set { actions = newValue }
    }

    public var actionCandidates: [ActionCandidate] {
        get { actions }
        set { actions = newValue }
    }

    public var audioLevels: [AudioLevelSample] {
        get { audioSamples }
        set { audioSamples = newValue }
    }

    public var transcriptSegments: [TranscriptSegment] {
        get { transcript }
        set { transcript = newValue }
    }

    public var cursor: [CursorSample] {
        get { cursorSamples }
        set { cursorSamples = newValue }
    }

    public var clickEvents: [ClickSample] {
        get { clicks }
        set { clicks = newValue }
    }

    public var typingEvents: [TypingSample] {
        get { typingSamples }
        set { typingSamples = newValue }
    }
}

public typealias FirstCutInput = FirstCutAnalysisInput

public enum FirstCutPlannerError: Error, LocalizedError, Sendable, Equatable {
    case invalidCaptureHealth([CaptureWarningCode])

    public var errorDescription: String? {
        switch self {
        case .invalidCaptureHealth(let warnings):
            return "First Cut requires a usable display capture (" + warnings.map(\.rawValue).joined(separator: ", ") + ")."
        }
    }
}

/// Pure transformation used by the app as one undoable document operation.
public enum FirstCutMaterializer {
    public static func apply(
        _ plan: FirstCutPlan,
        to document: ProjectDocument,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        let selected = plan.proposals.filter { proposal in
            if let selectedIDs { return selectedIDs.contains(proposal.id) && proposal.isActionable }
            return proposal.state == .accepted
        }
        return apply(selected, to: document, selectedIDs: selectedIDs)
    }

    public static func apply(
        _ proposals: [FirstCutProposal],
        to document: ProjectDocument,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        var result = document
        let selected = proposals.filter { proposal in
            guard proposal.isActionable else { return false }
            if let selectedIDs { return selectedIDs.contains(proposal.id) }
            return proposal.state == .accepted
        }
        for proposal in selected.sorted(by: stableProposalOrder) {
            materialize(proposal.payload, into: &result)
        }
        return result
    }

    public static func applyAll(_ plan: FirstCutPlan, to document: ProjectDocument) -> ProjectDocument {
        var result = document
        for proposal in plan.proposals where proposal.isActionable {
            result = apply([proposal], to: result, selectedIDs: [proposal.id])
        }
        return result
    }

    private static func stableProposalOrder(_ lhs: FirstCutProposal, _ rhs: FirstCutProposal) -> Bool {
        if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private static func materialize(_ payload: FirstCutProposalPayload, into document: inout ProjectDocument) {
        switch payload {
        case .cut(let value):
            guard !document.editDecisions.contains(where: { $0.id == value.id }),
                  !document.editDecisions.contains(where: { overlaps($0.start, $0.end, value.start, value.end) })
            else { return }
            document.editDecisions.append(value)
        case .speed(let value):
            guard !document.speedSegments.contains(where: { $0.id == value.id }),
                  !document.speedSegments.contains(where: { overlaps($0.start, $0.end, value.start, value.end) })
            else { return }
            document.speedSegments.append(value)
        case .zoom(let value):
            guard !document.zoomRanges.contains(where: { $0.id == value.id }),
                  !document.zoomRanges.contains(where: { overlaps($0.start, $0.end, value.start, value.end) && ($0.isLocked || $0.source == .manual) })
            else { return }
            document.zoomRanges.append(value)
        case .caption(let value):
            guard !document.captions.contains(where: { $0.id == value.id }) else { return }
            document.captions.append(value)
        case .annotation(let value):
            guard !document.annotations.contains(where: { $0.id == value.id }) else { return }
            document.annotations.append(value)
        case .cursorEffect(let value):
            guard !document.cursorEffects.contains(where: { $0.id == value.id }) else { return }
            document.cursorEffects.append(value)
        case .chapter(let value):
            guard !document.storyBeats.contains(where: { $0.id == value.id }),
                  !document.storyBeats.contains(where: { $0.isLocked && overlaps($0.start, $0.end, value.start, value.end) })
            else { return }
            document.storyBeats.append(value)
        }
    }

    private static func overlaps(_ lhsStart: TimeInterval, _ lhsEnd: TimeInterval, _ rhsStart: TimeInterval, _ rhsEnd: TimeInterval) -> Bool {
        lhsStart < rhsEnd && rhsStart < lhsEnd
    }
}

public extension FirstCutPlan {
    func materialized(to document: ProjectDocument, selectedIDs: Set<FirstCutProposalID>? = nil) -> ProjectDocument {
        FirstCutMaterializer.apply(self, to: document, selectedIDs: selectedIDs)
    }

    func applying(to document: ProjectDocument, selectedIDs: Set<FirstCutProposalID>? = nil) -> ProjectDocument {
        materialized(to: document, selectedIDs: selectedIDs)
    }

    func applyingAll(to document: ProjectDocument) -> ProjectDocument {
        var result = document
        for proposal in proposals where proposal.isActionable {
            result = FirstCutMaterializer.apply([proposal], to: result, selectedIDs: [proposal.id])
        }
        return result
    }
}
