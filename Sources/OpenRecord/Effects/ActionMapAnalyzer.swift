import Foundation

/// The value-only inputs consumed by the local ActionMap recognizer.
///
/// The analyzer intentionally receives already privacy-filtered semantic and
/// typing records. It never asks Accessibility for values and it never uses
/// transcript/OCR text as an action label or identifier.
public struct ActionMapAnalysisInput: Codable, Sendable, Hashable {
    public var semanticEvents: [SemanticEventSample]
    public var clicks: [ClickSample]
    public var cursorSamples: [CursorSample]
    public var keySamples: [KeySample]
    public var typingSamples: [TypingSample]
    public var targetGeometry: [TargetGeometrySample]
    public var ocrEvidence: [ActionOCREvidence]
    public var transcript: [TranscriptSegment]

    public init(
        semanticEvents: [SemanticEventSample] = [],
        clicks: [ClickSample] = [],
        cursorSamples: [CursorSample] = [],
        keySamples: [KeySample] = [],
        typingSamples: [TypingSample] = [],
        targetGeometry: [TargetGeometrySample] = [],
        ocrEvidence: [ActionOCREvidence] = [],
        transcript: [TranscriptSegment] = []
    ) {
        self.semanticEvents = semanticEvents
        self.clicks = clicks
        self.cursorSamples = cursorSamples
        self.keySamples = keySamples
        self.typingSamples = typingSamples
        self.targetGeometry = targetGeometry
        self.ocrEvidence = ocrEvidence
        self.transcript = transcript
    }
}

/// Deterministic, offline ActionMap recognition.
///
/// Every output identity is derived from a source stream's sequence number or
/// its line index. In particular, no UUID, timestamp text, typed key text, or
/// OCR text is used to form an ActionCandidate identity.
public struct ActionMapAnalyzer: Sendable {
    public static let analyzerVersion = "action-map-1"
    public static let semanticClickWindow: TimeInterval = 0.25
    public static let typingBurstGap: TimeInterval = 1.0
    public static let cursorContextWindow: TimeInterval = 0.6
    public static let transcriptContextWindow: TimeInterval = 0.5

    public let input: ActionMapAnalysisInput
    public let displayBounds: Rect2D?

    public init(
        input: ActionMapAnalysisInput,
        displayBounds: Rect2D? = nil
    ) {
        self.input = input
        self.displayBounds = displayBounds
    }

    public init(
        semanticEvents: [SemanticEventSample] = [],
        clicks: [ClickSample] = [],
        cursorSamples: [CursorSample] = [],
        keySamples: [KeySample] = [],
        typingSamples: [TypingSample] = [],
        targetGeometry: [TargetGeometrySample] = [],
        ocrEvidence: [ActionOCREvidence] = [],
        transcript: [TranscriptSegment] = [],
        displayBounds: Rect2D? = nil
    ) {
        self.init(
            input: ActionMapAnalysisInput(
                semanticEvents: semanticEvents,
                clicks: clicks,
                cursorSamples: cursorSamples,
                keySamples: keySamples,
                typingSamples: typingSamples,
                targetGeometry: targetGeometry,
                ocrEvidence: ocrEvidence,
                transcript: transcript
            ),
            displayBounds: displayBounds
        )
    }

    /// Convenience entry point for callers that do not need to retain an
    /// analyzer value.
    public static func analyze(
        semanticEvents: [SemanticEventSample] = [],
        clicks: [ClickSample] = [],
        cursorSamples: [CursorSample] = [],
        keySamples: [KeySample] = [],
        typingSamples: [TypingSample] = [],
        targetGeometry: [TargetGeometrySample] = [],
        ocrEvidence: [ActionOCREvidence] = [],
        transcript: [TranscriptSegment] = [],
        displayBounds: Rect2D? = nil
    ) -> [ActionCandidate] {
        ActionMapAnalyzer(
            semanticEvents: semanticEvents,
            clicks: clicks,
            cursorSamples: cursorSamples,
            keySamples: keySamples,
            typingSamples: typingSamples,
            targetGeometry: targetGeometry,
            ocrEvidence: ocrEvidence,
            transcript: transcript,
            displayBounds: displayBounds
        ).analyze()
    }

    public func analyze() -> [ActionCandidate] {
        let semantic = indexed(input.semanticEvents).map { IndexedSemantic(index: $0.index, value: $0.value.normalized) }
        let clicks = indexed(input.clicks).map { IndexedClick(index: $0.index, value: normalize($0.value)) }
        let cursor = indexed(input.cursorSamples).map { IndexedCursor(index: $0.index, value: normalize($0.value)) }
        let keys = indexed(input.keySamples).map { IndexedKey(index: $0.index, value: normalize($0.value)) }
        let typing = indexed(input.typingSamples).map { IndexedTyping(index: $0.index, value: normalize($0.value)) }
        let geometry = indexed(input.targetGeometry).map { IndexedGeometry(index: $0.index, value: normalize($0.value)) }
        let ocr = VisionActionFallback.filtered(input.ocrEvidence)
            .enumerated()
            .map { IndexedOCR(index: $0.offset, value: $0.element) }
        let transcript = input.transcript.enumerated().map {
            IndexedTranscript(index: $0.offset, value: $0.element.normalized)
        }

        let sortedSemantic = semantic.sorted(by: semanticSort)
        let sortedClicks = clicks.sorted(by: clickSort)
        let sortedCursor = cursor.sorted(by: cursorSort)
        let sortedKeys = keys.sorted(by: keySort)
        let sortedTyping = typing.sorted(by: typingSort)
        let sortedGeometry = geometry.sorted(by: geometrySort)
        let sortedOCR = ocr.sorted(by: ocrSort)
        let sortedTranscript = transcript.sorted { transcriptSort($0, $1) }

        var candidates: [ActionCandidate] = []
        var consumedClickIndices = Set<Int>()
        var semanticCandidateIndexes: [Int: Int] = [:]

        // A semantic event is the strongest signal. A nearby click is fused
        // exactly once, so the same click still gets a fallback candidate only
        // when no semantic event claimed it.
        for event in sortedSemantic {
            let matchingClick = sortedClicks
                .filter { !consumedClickIndices.contains($0.index) }
                .filter { $0.value.down }
                .filter { abs(time($0.value) - time(event.value)) <= Self.semanticClickWindow }
                .sorted {
                    let distanceA = abs(time($0.value) - time(event.value))
                    let distanceB = abs(time($1.value) - time(event.value))
                    if distanceA != distanceB { return distanceA < distanceB }
                    return canonicalEvidenceID(prefix: "click", sequence: $0.value.sequence, line: $0.index).rawValue
                        < canonicalEvidenceID(prefix: "click", sequence: $1.value.sequence, line: $1.index).rawValue
                }
                .first

            if let matchingClick {
                consumedClickIndices.insert(matchingClick.index)
            }

            let kind = semanticKind(event.value)
            let semanticID = canonicalEvidenceID(
                prefix: "semantic",
                sequence: event.value.sequence,
                line: event.index
            )
            var evidenceIDs = [semanticID]
            var sources: [ActionEvidenceSource] = [.semantic]
            var start = time(event.value)
            var end = start + duration(event.value)
            var label = semanticLabel(event.value)
            let appID = SemanticPrivacyFilter.sanitizeBundleID(event.value.applicationBundleID)
            let role = SemanticPrivacyFilter.sanitizeRole(event.value.role)
            var bounds = event.value.bounds.map(SemanticPrivacyFilter.normalizedBounds)
            var confidence = event.value.confidence
            var signals: [String] = [event.value.source == .accessibility ? "accessibility" : "semantic-\(event.value.source.rawValue)"]

            if let matchingClick {
                let clickIDs = clickEvidenceIDs(matchingClick, all: sortedClicks)
                evidenceIDs.append(contentsOf: clickIDs)
                sources.append(.click)
                start = min(start, time(matchingClick.value))
                end = max(end, clickEnd(matchingClick, all: sortedClicks))
                confidence = combine(confidence, clickConfidence(matchingClick))
                signals.append("semantic-click-fusion")
                if label == "Activate control" || label == "Focus control" {
                    label = clickLabel(matchingClick.value)
                }
                if bounds == nil {
                    bounds = clickBounds(matchingClick.value)
                }
            }

            let context = cursorContext(
                at: start,
                point: matchingClick.flatMap(clickPoint),
                cursor: sortedCursor
            )
            evidenceIDs.append(contentsOf: context.ids)
            sources.append(contentsOf: context.ids.isEmpty ? [] : [.cursor])
            signals.append(contentsOf: context.signals)

            let geometryContext = geometryContext(at: start, geometry: sortedGeometry)
            evidenceIDs.append(contentsOf: geometryContext.ids)
            sources.append(contentsOf: geometryContext.ids.isEmpty ? [] : [.targetGeometry])
            signals.append(contentsOf: geometryContext.signals)
            if bounds == nil { bounds = geometryContext.bounds }

            let transcriptContext = transcriptContext(
                start: start,
                end: end,
                transcript: sortedTranscript
            )
            evidenceIDs.append(contentsOf: transcriptContext.ids)
            sources.append(contentsOf: transcriptContext.ids.isEmpty ? [] : [.transcript])
            signals.append(contentsOf: transcriptContext.signals)
            confidence = confidenceWithSignals(
                confidence,
                cursor: context,
                geometry: geometryContext,
                transcript: transcriptContext
            )

            var candidate = makeCandidate(
                idKind: kind,
                primaryID: semanticID,
                start: start,
                end: end,
                kind: kind,
                label: label,
                applicationBundleID: appID,
                role: role,
                bounds: bounds,
                confidence: confidence,
                sources: sources,
                evidenceIDs: evidenceIDs,
                signals: signals
            )

            if let ocrMatch = nearestOCR(to: start, point: clickPoint(matchingClick), ocr: sortedOCR) {
                candidate = applyOCR(ocrMatch, to: candidate)
            }
            semanticCandidateIndexes[event.index] = candidates.count
            candidates.append(candidate)
        }

        // Unclaimed mouse-downs provide a useful generic action for AX
        // unavailable applications. Pairing the following mouse-up avoids
        // shortening the visible interval while remaining deterministic.
        for click in sortedClicks where click.value.down && !consumedClickIndices.contains(click.index) {
            let clickID = canonicalEvidenceID(prefix: "click", sequence: click.value.sequence, line: click.index)
            let context = cursorContext(at: time(click.value), point: clickPoint(click), cursor: sortedCursor)
            let geometryContext = geometryContext(at: time(click.value), geometry: sortedGeometry)
            let transcriptContext = transcriptContext(
                start: time(click.value),
                end: clickEnd(click, all: sortedClicks),
                transcript: sortedTranscript
            )
            let clickCandidate = makeCandidate(
                idKind: .click,
                primaryID: clickID,
                start: time(click.value),
                end: clickEnd(click, all: sortedClicks),
                kind: .click,
                label: clickLabel(click.value),
                applicationBundleID: nil,
                role: nil,
                bounds: clickBounds(click.value) ?? geometryContext.bounds,
                confidence: confidenceWithSignals(
                    clickConfidence(click),
                    cursor: context,
                    geometry: geometryContext,
                    transcript: transcriptContext
                ),
                sources: [.click]
                    + (context.ids.isEmpty ? [] : [.cursor])
                    + (geometryContext.ids.isEmpty ? [] : [.targetGeometry])
                    + (transcriptContext.ids.isEmpty ? [] : [.transcript]),
                evidenceIDs: [clickID]
                    + clickEvidenceIDs(click, all: sortedClicks).dropFirst()
                    + context.ids
                    + geometryContext.ids
                    + transcriptContext.ids,
                signals: ["click-fallback"]
                    + context.signals
                    + geometryContext.signals
                    + transcriptContext.signals
            )
            candidates.append(clickCandidate)
        }

        addShortcutCandidates(from: sortedKeys, to: &candidates, cursor: sortedCursor, geometry: sortedGeometry, transcript: sortedTranscript)

        let typingBursts = makeTypingBursts(sortedTyping)
        for burst in typingBursts {
            let typingIDs = burst.samples.map {
                canonicalEvidenceID(prefix: "typing", sequence: $0.value.sequence, line: $0.index)
            }
            let nearbyFocus = sortedSemantic.first {
                $0.value.kind == .focus
                    && abs(time($0.value) - burst.start) <= Self.transcriptContextWindow
            }
            if let nearbyFocus,
               let candidateIndex = semanticCandidateIndexes[nearbyFocus.index]
            {
                var candidate = candidates[candidateIndex]
                candidate.kind = .textInput
                candidate.label = "Text input"
                candidate.end = max(candidate.end, burst.end)
                candidate.evidenceIDs.append(contentsOf: typingIDs)
                candidate.evidenceSources.append(.typing)
                candidate.supportingSignals.append("typing-burst")
                candidate.confidence = rounded(clamp(candidate.confidence * 0.65 + 0.35 * typingConfidence(burst)))
                candidates[candidateIndex] = candidate.normalized
            } else {
                candidates.append(makeCandidate(
                    idKind: .textInput,
                    primaryID: typingIDs[0],
                    start: burst.start,
                    end: burst.end,
                    kind: .textInput,
                    label: "Text input",
                    applicationBundleID: nil,
                    role: nil,
                    bounds: typingBounds(burst),
                    confidence: typingConfidence(burst),
                    sources: [.typing],
                    evidenceIDs: typingIDs,
                    signals: ["typing-burst", "privacy-safe"]
                ))
            }
        }

        addCursorDwellCandidates(from: sortedCursor, to: &candidates)
        addGeometryCandidates(from: sortedGeometry, to: &candidates)

        return candidates
            .map { applyOCRIfNeeded($0, ocr: sortedOCR) }
            .map(\.normalized)
            .sorted(by: candidateSort)
    }

    // MARK: - Indexed values and normalization

    private struct Indexed<Value> {
        let index: Int
        let value: Value
    }
    private typealias IndexedSemantic = Indexed<SemanticEventSample>
    private typealias IndexedClick = Indexed<ClickSample>
    private typealias IndexedCursor = Indexed<CursorSample>
    private typealias IndexedKey = Indexed<KeySample>
    private typealias IndexedTyping = Indexed<TypingSample>
    private typealias IndexedGeometry = Indexed<TargetGeometrySample>
    private typealias IndexedOCR = Indexed<ActionOCREvidence>
    private typealias IndexedTranscript = Indexed<TranscriptSegment>

    private func indexed<Value>(_ values: [Value]) -> [Indexed<Value>] {
        values.enumerated().map { Indexed(index: $0.offset, value: $0.element) }
    }

    private func normalize(_ sample: CursorSample) -> CursorSample {
        var value = sample
        value.t = finiteTime(value.t)
        value.x = finite(value.x)
        value.y = finite(value.y)
        return value
    }

    private func normalize(_ sample: ClickSample) -> ClickSample {
        var value = sample
        value.t = finiteTime(value.t)
        value.x = value.x.map(finite)
        value.y = value.y.map(finite)
        return value
    }

    private func normalize(_ sample: KeySample) -> KeySample {
        var value = sample
        value.t = finiteTime(value.t)
        value.key = String(value.key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        value.modifiers = KeyModifier.allCases.filter { value.modifiers.contains($0) }
        return value
    }

    private func normalize(_ sample: TypingSample) -> TypingSample {
        var value = sample
        value.t = finiteTime(value.t)
        value.x = finite(value.x)
        value.y = finite(value.y)
        value.width = value.width.map(finite)
        value.height = value.height.map(finite)
        return value
    }

    private func normalize(_ sample: TargetGeometrySample) -> TargetGeometrySample {
        var value = sample
        value.t = finiteTime(value.t)
        return value
    }

    private func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
    private func finiteTime(_ value: TimeInterval) -> TimeInterval { max(0, finite(value)) }
    private func time(_ value: SemanticEventSample) -> TimeInterval { finiteTime(value.t) }
    private func time(_ value: ClickSample) -> TimeInterval { finiteTime(value.t) }
    private func time(_ value: KeySample) -> TimeInterval { finiteTime(value.t) }
    private func duration(_ value: SemanticEventSample) -> TimeInterval {
        max(0, value.duration.isFinite ? value.duration : 0)
    }

    private func semanticSort(_ lhs: IndexedSemantic, _ rhs: IndexedSemantic) -> Bool {
        compare(time(lhs.value), time(rhs.value), tie: semanticTie(lhs), rhsTie: semanticTie(rhs))
    }
    private func clickSort(_ lhs: IndexedClick, _ rhs: IndexedClick) -> Bool {
        compare(time(lhs.value), time(rhs.value), tie: clickTie(lhs), rhsTie: clickTie(rhs))
    }
    private func cursorSort(_ lhs: IndexedCursor, _ rhs: IndexedCursor) -> Bool {
        compare(lhs.value.t, rhs.value.t, tie: cursorTie(lhs), rhsTie: cursorTie(rhs))
    }
    private func keySort(_ lhs: IndexedKey, _ rhs: IndexedKey) -> Bool {
        compare(lhs.value.t, rhs.value.t, tie: keyTie(lhs), rhsTie: keyTie(rhs))
    }
    private func typingSort(_ lhs: IndexedTyping, _ rhs: IndexedTyping) -> Bool {
        compare(lhs.value.t, rhs.value.t, tie: typingTie(lhs), rhsTie: typingTie(rhs))
    }
    private func geometrySort(_ lhs: IndexedGeometry, _ rhs: IndexedGeometry) -> Bool {
        compare(lhs.value.t, rhs.value.t, tie: geometryTie(lhs), rhsTie: geometryTie(rhs))
    }
    private func ocrSort(_ lhs: IndexedOCR, _ rhs: IndexedOCR) -> Bool {
        compare(lhs.value.t, rhs.value.t, tie: lhs.value.id.rawValue + "-" + String(lhs.index), rhsTie: rhs.value.id.rawValue + "-" + String(rhs.index))
    }
    private func transcriptSort(_ lhs: IndexedTranscript, _ rhs: IndexedTranscript) -> Bool {
        compare(lhs.value.start, rhs.value.start, tie: String(lhs.index), rhsTie: String(rhs.index))
    }

    private func compare(_ lhs: Double, _ rhs: Double, tie: String, rhsTie: String) -> Bool {
        if lhs != rhs { return lhs < rhs }
        return tie < rhsTie
    }

    private func semanticTie(_ item: IndexedSemantic) -> String {
        canonicalEvidenceID(prefix: "semantic", sequence: item.value.sequence, line: item.index).rawValue
    }
    private func clickTie(_ item: IndexedClick) -> String {
        canonicalEvidenceID(prefix: "click", sequence: item.value.sequence, line: item.index).rawValue
    }
    private func cursorTie(_ item: IndexedCursor) -> String {
        canonicalEvidenceID(prefix: "cursor", sequence: item.value.sequence, line: item.index).rawValue
    }
    private func keyTie(_ item: IndexedKey) -> String {
        canonicalEvidenceID(prefix: "key", sequence: item.value.sequence, line: item.index).rawValue
    }
    private func typingTie(_ item: IndexedTyping) -> String {
        canonicalEvidenceID(prefix: "typing", sequence: item.value.sequence, line: item.index).rawValue
    }
    private func geometryTie(_ item: IndexedGeometry) -> String {
        canonicalEvidenceID(prefix: "geometry", sequence: item.value.sequence, line: item.index).rawValue
    }

    // MARK: - Candidate construction

    private func semanticKind(_ event: SemanticEventSample) -> ActionCandidateKind {
        switch event.kind {
        case .storyBeat: .marker
        case .focus where SemanticPrivacyFilter.isSecureRole(event.role): .textInput
        case .focus: .navigation
        case .activate, .genericClick: .click
        case .shortcut: .shortcut
        }
    }

    private func semanticLabel(_ event: SemanticEventSample) -> String {
        if let label = event.label,
           let safe = SemanticPrivacyFilter.sanitizeCapturedLabel(label, role: event.role)
        {
            return safe
        }
        switch event.kind {
        case .activate: return "Activate " + genericRole(event.role)
        case .focus: return "Focus " + genericRole(event.role)
        case .shortcut: return "Shortcut"
        case .storyBeat: return "Story marker"
        case .genericClick: return "Click"
        }
    }

    private func genericRole(_ role: String?) -> String {
        guard let role = SemanticPrivacyFilter.sanitizeRole(role), !role.isEmpty else { return "control" }
        switch role {
        case "AXButton", "button": return "button"
        case "AXLink", "link": return "link"
        case "AXMenuItem", "menu-item": return "menu item"
        case "AXTextField", "text-field": return "text field"
        default: return "control"
        }
    }

    private func clickLabel(_ click: ClickSample) -> String {
        switch click.button {
        case .left: "Left click"
        case .right: "Right click"
        case .middle: "Middle click"
        case .other: "Click"
        }
    }

    private func makeCandidate(
        idKind: ActionCandidateKind,
        primaryID: AnalysisEvidenceID,
        start: TimeInterval,
        end: TimeInterval,
        kind: ActionCandidateKind,
        label: String,
        applicationBundleID: String?,
        role: String?,
        bounds: Rect2D?,
        confidence: Double,
        sources: [ActionEvidenceSource],
        evidenceIDs: [AnalysisEvidenceID],
        signals: [String]
    ) -> ActionCandidate {
        let candidateID = makeCandidateID(kind: idKind, primaryID: primaryID)
        return ActionCandidate(
            id: candidateID,
            start: finiteTime(start),
            end: max(finiteTime(start), finiteTime(end)),
            kind: kind,
            label: label,
            applicationBundleID: applicationBundleID,
            role: role,
            bounds: bounds,
            confidence: rounded(clamp(confidence)),
            evidenceSources: stableUnique(sources),
            evidenceIDs: stableUnique(evidenceIDs),
            supportingSignals: stableUnique(signals)
        ).normalized
    }

    private func makeCandidateID(kind: ActionCandidateKind, primaryID: AnalysisEvidenceID) -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("action-" + kind.rawValue + "-" + primaryID.rawValue)
    }

    private func canonicalEvidenceID(prefix: String, sequence: UInt64?, line: Int) -> AnalysisEvidenceID {
        if let sequence {
            return try! AnalysisEvidenceID(prefix + "-seq-" + String(sequence))
        }
        return try! AnalysisEvidenceID(prefix + "-line-" + String(line))
    }

    private func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func candidateSort(_ lhs: ActionCandidate, _ rhs: ActionCandidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.rawValue < rhs.id.rawValue
    }

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func rounded(_ value: Double) -> Double {
        let scale = 1_000_000.0
        return (clamp(value) * scale).rounded() / scale
    }

    private func combine(_ a: Double, _ b: Double) -> Double {
        rounded(0.65 * clamp(a) + 0.35 * clamp(b))
    }

    private func clickConfidence(_ click: IndexedClick) -> Double {
        var confidence = click.value.down ? 0.62 : 0.3
        if clickPoint(click) != nil { confidence += 0.12 }
        return rounded(confidence)
    }

    // MARK: - Click context

    private func clickPoint(_ click: IndexedClick?) -> Point2D? {
        guard let click,
              let x = click.value.x,
              let y = click.value.y,
              x.isFinite, y.isFinite
        else { return nil }
        return Point2D(x: x, y: y)
    }

    private func clickBounds(_ click: ClickSample) -> Rect2D? {
        guard let x = click.x, let y = click.y, x.isFinite, y.isFinite else { return nil }
        guard let displayBounds, displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let nx = (x - displayBounds.x) / displayBounds.width
        let ny = (y - displayBounds.y) / displayBounds.height
        guard nx.isFinite, ny.isFinite, nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return Rect2D(x: nx, y: ny, width: 0, height: 0)
    }

    private func clickEvidenceIDs(_ click: IndexedClick, all clicks: [IndexedClick]) -> [AnalysisEvidenceID] {
        let downID = canonicalEvidenceID(prefix: "click", sequence: click.value.sequence, line: click.index)
        guard click.value.down else { return [downID] }
        guard let up = clicks
            .filter({ $0.value.button == click.value.button && !$0.value.down })
            .filter({ time($0.value) >= time(click.value) && time($0.value) - time(click.value) <= 0.5 })
            .sorted(by: { clickSort($0, $1) })
            .first
        else { return [downID] }
        return [downID, canonicalEvidenceID(prefix: "click", sequence: up.value.sequence, line: up.index)]
    }

    private func clickEnd(_ click: IndexedClick, all clicks: [IndexedClick]) -> TimeInterval {
        guard click.value.down else { return time(click.value) }
        guard let up = clicks
            .filter({ $0.value.button == click.value.button && !$0.value.down })
            .filter({ time($0.value) >= time(click.value) && time($0.value) - time(click.value) <= 0.5 })
            .sorted(by: { clickSort($0, $1) })
            .first
        else { return time(click.value) }
        return time(up.value)
    }

    // MARK: - Cursor signals

    private struct Context {
        var ids: [AnalysisEvidenceID] = []
        var signals: [String] = []
        var score: Double = 0
        var bounds: Rect2D?
    }

    private func cursorContext(
        at timestamp: TimeInterval,
        point: Point2D?,
        cursor: [IndexedCursor]
    ) -> Context {
        let window = Self.cursorContextWindow
        let lowTime = timestamp - window
        let highTime = timestamp + window

        var low = 0
        var high = cursor.count
        while low < high {
            let mid = (low + high) / 2
            if cursor[mid].value.t < lowTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let startIndex = low

        high = cursor.count
        while low < high {
            let mid = (low + high) / 2
            if cursor[mid].value.t <= highTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let endIndex = low
        guard startIndex < endIndex else { return Context() }
        let nearby = Array(cursor[startIndex..<endIndex])
        var context = Context()
        context.ids = nearby.map { canonicalEvidenceID(prefix: "cursor", sequence: $0.value.sequence, line: $0.index) }
        let before = nearby.last { $0.value.t <= timestamp }
        let after = nearby.first { $0.value.t >= timestamp }
        if nearby.count >= 2 {
            let positions = nearby.map { Point2D(x: $0.value.x, y: $0.value.y) }
            let spread = max(
                positions.map(\.x).max()! - positions.map(\.x).min()!,
                positions.map(\.y).max()! - positions.map(\.y).min()!
            )
            if spread <= 16 || point != nil && spread <= 32 {
                context.signals.append("cursor-dwell")
                context.score += 0.12
            }
        }
        if let point, let before {
            let previous = cursor.last { $0.value.t < before.value.t }
            if let previous {
                let oldDistance = distance(previous.value, point)
                let newDistance = distance(before.value, point)
                if newDistance <= oldDistance + 1 {
                    context.signals.append("cursor-approach")
                    context.score += 0.1
                }
            }
            if let after {
                let next = cursor.first { $0.value.t > after.value.t }
                if let next, distance(next.value, point) > distance(after.value, point) + 1 {
                    context.signals.append("cursor-departure")
                    context.score += 0.08
                }
            }
        }
        if let latest = nearby.last, let displayBounds,
           displayBounds.width > 0, displayBounds.height > 0
        {
            let nx = (latest.value.x - displayBounds.x) / displayBounds.width
            let ny = (latest.value.y - displayBounds.y) / displayBounds.height
            if nx.isFinite, ny.isFinite, nx >= 0, nx <= 1, ny >= 0, ny <= 1 {
                context.bounds = Rect2D(x: nx, y: ny, width: 0, height: 0)
            }
        }
        context.score = rounded(context.score)
        return context
    }

    private func distance(_ cursor: CursorSample, _ point: Point2D) -> Double {
        hypot(cursor.x - point.x, cursor.y - point.y)
    }

    private func addCursorDwellCandidates(from cursor: [IndexedCursor], to candidates: inout [ActionCandidate]) {
        guard cursor.count >= 3 else { return }
        var run: [IndexedCursor] = []
        func flush() {
            guard run.count >= 3,
                  let first = run.first,
                  let last = run.last,
                  last.value.t - first.value.t >= 0.5
            else { run.removeAll(); return }
            let spread = max(
                run.map { $0.value.x }.max()! - run.map { $0.value.x }.min()!,
                run.map { $0.value.y }.max()! - run.map { $0.value.y }.min()!
            )
            guard spread <= 16 else { run.removeAll(); return }
            let ids = run.map { canonicalEvidenceID(prefix: "cursor", sequence: $0.value.sequence, line: $0.index) }
            candidates.append(makeCandidate(
                idKind: .visual,
                primaryID: ids[0],
                start: first.value.t,
                end: last.value.t,
                kind: .visual,
                label: "Cursor dwell",
                applicationBundleID: nil,
                role: nil,
                bounds: nil,
                confidence: min(0.82, 0.52 + Double(run.count) * 0.04),
                sources: [.cursor],
                evidenceIDs: ids,
                signals: ["cursor-dwell"]
            ))
            run.removeAll()
        }
        for item in cursor {
            guard item.value.isVisible else { flush(); continue }
            if let previous = run.last, item.value.t - previous.value.t > 0.35 { flush() }
            run.append(item)
        }
        flush()
    }

    // MARK: - Geometry and transcript context

    private func geometryContext(at timestamp: TimeInterval, geometry: [IndexedGeometry]) -> Context {
        guard let nearest = geometry.min(by: {
            abs($0.value.t - timestamp) == abs($1.value.t - timestamp)
                ? geometryTie($0) < geometryTie($1)
                : abs($0.value.t - timestamp) < abs($1.value.t - timestamp)
        }), abs(nearest.value.t - timestamp) <= 0.75 else { return Context() }
        let id = canonicalEvidenceID(prefix: "geometry", sequence: nearest.value.sequence, line: nearest.index)
        let safeBounds: Rect2D? = {
            guard nearest.value.available else { return nil }
            let raw = nearest.value.bounds
            guard [raw.x, raw.y, raw.width, raw.height].allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return nil }
            return SemanticPrivacyFilter.normalizedBounds(raw)
        }()
        return Context(
            ids: [id],
            signals: [nearest.value.available ? "window-geometry" : "window-unavailable"],
            score: nearest.value.available ? 0.08 : 0,
            bounds: safeBounds
        )
    }

    private func addGeometryCandidates(from geometry: [IndexedGeometry], to candidates: inout [ActionCandidate]) {
        guard geometry.count >= 2 else { return }
        for pair in zip(geometry, geometry.dropFirst()) {
            let previous = pair.0
            let current = pair.1
            guard current.value.available != previous.value.available || current.value.bounds != previous.value.bounds else { continue }
            let currentID = canonicalEvidenceID(prefix: "geometry", sequence: current.value.sequence, line: current.index)
            candidates.append(makeCandidate(
                idKind: .navigation,
                primaryID: currentID,
                start: previous.value.t,
                end: current.value.t,
                kind: .navigation,
                label: current.value.available ? "Window geometry changed" : "Window unavailable",
                applicationBundleID: nil,
                role: nil,
                bounds: nil,
                confidence: current.value.available ? 0.56 : 0.45,
                sources: [.targetGeometry],
                evidenceIDs: [canonicalEvidenceID(prefix: "geometry", sequence: previous.value.sequence, line: previous.index), currentID],
                signals: [current.value.available ? "window-geometry" : "window-unavailable"]
            ))
        }
    }

    private func transcriptContext(
        start: TimeInterval,
        end: TimeInterval,
        transcript: [IndexedTranscript]
    ) -> Context {
        let overlapping = transcript.filter {
            let segment = $0.value
            return segment.end >= start - Self.transcriptContextWindow
                && segment.start <= end + Self.transcriptContextWindow
        }
        guard !overlapping.isEmpty else { return Context() }
        let ids = overlapping.map { try! AnalysisEvidenceID("transcript-line-" + String($0.index)) }
        let transcriptConfidence = overlapping.compactMap(\.value.confidence).average ?? 0.5
        return Context(ids: ids, signals: ["transcript-signal"], score: rounded(0.04 * transcriptConfidence))
    }

    private func confidenceWithSignals(
        _ base: Double,
        cursor: Context,
        geometry: Context,
        transcript: Context
    ) -> Double {
        rounded(clamp(base + cursor.score + geometry.score + transcript.score))
    }

    // MARK: - OCR

    private func nearestOCR(
        to timestamp: TimeInterval,
        point: Point2D?,
        ocr: [IndexedOCR]
    ) -> IndexedOCR? {
        ocr.filter { abs($0.value.t - timestamp) <= Self.semanticClickWindow }
            .filter { item in
                guard let point else { return true }
                let bounds = item.value.bounds
                guard bounds.width > 0, bounds.height > 0 else { return true }
                let directMatch = point.x >= bounds.x && point.x <= bounds.x + bounds.width
                    && point.y >= bounds.y && point.y <= bounds.y + bounds.height
                let normalizedMatch: Bool = {
                    guard let displayBounds,
                          displayBounds.width > 0,
                          displayBounds.height > 0
                    else { return false }
                    let normalizedX = (point.x - displayBounds.x) / displayBounds.width
                    let normalizedY = (point.y - displayBounds.y) / displayBounds.height
                    return normalizedX >= bounds.x && normalizedX <= bounds.x + bounds.width
                        && normalizedY >= bounds.y && normalizedY <= bounds.y + bounds.height
                }()
                return directMatch || normalizedMatch
            }
            .min {
                let a = abs($0.value.t - timestamp)
                let b = abs($1.value.t - timestamp)
                return a == b ? ocrSort($0, $1) : a < b
            }
    }

    private func applyOCR(_ ocr: IndexedOCR, to candidate: ActionCandidate) -> ActionCandidate {
        var value = candidate
        value.evidenceIDs.append(ocr.value.id)
        value.evidenceSources.append(.vision)
        value.supportingSignals.append(ocr.value.label == nil ? "vision-ocr-filtered" : "vision-ocr")
        if let label = ocr.value.label, !label.isEmpty,
           candidate.label == "Click" || candidate.label.hasPrefix("Left click") || candidate.label.hasPrefix("Right click") || candidate.label.hasPrefix("Middle click")
        {
            value.label = label
        }
        value.confidence = rounded(value.confidence * 0.8 + ocr.value.confidence * 0.2)
        return value.normalized
    }

    private func applyOCRIfNeeded(_ candidate: ActionCandidate, ocr: [IndexedOCR]) -> ActionCandidate {
        guard !candidate.evidenceSources.contains(.vision) else { return candidate }
        guard let item = nearestOCR(to: candidate.start, point: nil, ocr: ocr) else { return candidate }
        // Semantic candidate fusion already selected its OCR row; this pass is
        // only for standalone visual/cursor/geometry candidates.
        guard candidate.kind == .click else { return candidate }
        return applyOCR(item, to: candidate)
    }

    // MARK: - Typing

    private struct TypingBurst {
        let samples: [IndexedTyping]
        let start: TimeInterval
        let end: TimeInterval
    }

    private func makeTypingBursts(_ typing: [IndexedTyping]) -> [TypingBurst] {
        guard !typing.isEmpty else { return [] }
        var result: [TypingBurst] = []
        var current: [IndexedTyping] = []
        func flush() {
            guard let first = current.first, let last = current.last else { current.removeAll(); return }
            result.append(TypingBurst(samples: current, start: first.value.t, end: max(first.value.t, last.value.t + 0.25)))
            current.removeAll()
        }
        for sample in typing {
            if let previous = current.last, sample.value.t - previous.value.t > Self.typingBurstGap { flush() }
            current.append(sample)
        }
        flush()
        return result
    }

    private func typingConfidence(_ burst: TypingBurst) -> Double {
        rounded(min(0.9, 0.58 + Double(min(burst.samples.count, 8)) * 0.035))
    }

    private func typingBounds(_ burst: TypingBurst) -> Rect2D? {
        guard let first = burst.samples.first else { return nil }
        guard let displayBounds, displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let x = (first.value.x - displayBounds.x) / displayBounds.width
        let y = (first.value.y - displayBounds.y) / displayBounds.height
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= 1, y <= 1 else { return nil }
        let width = (first.value.width ?? 0) / displayBounds.width
        let height = (first.value.height ?? 0) / displayBounds.height
        return SemanticPrivacyFilter.normalizedBounds(Rect2D(x: x, y: y, width: width, height: height))
    }

    // MARK: - Shortcut grouping

    private func addShortcutCandidates(
        from keys: [IndexedKey],
        to candidates: inout [ActionCandidate],
        cursor: [IndexedCursor],
        geometry: [IndexedGeometry],
        transcript: [IndexedTranscript]
    ) {
        let safe = keys.filter { $0.value.down && isSafeShortcut($0.value) }
        var groups: [[IndexedKey]] = []
        for key in safe {
            if let previous = groups.last?.last,
               key.value.t - previous.value.t <= 0.25,
               shortcutSignature(key.value) == shortcutSignature(previous.value)
            {
                groups[groups.count - 1].append(key)
            } else {
                groups.append([key])
            }
        }
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let ids = group.map { canonicalEvidenceID(prefix: "key", sequence: $0.value.sequence, line: $0.index) }
            let context = cursorContext(at: first.value.t, point: nil, cursor: cursor)
            let geometryContext = geometryContext(at: first.value.t, geometry: geometry)
            let transcriptContext = transcriptContext(start: first.value.t, end: last.value.t, transcript: transcript)
            candidates.append(makeCandidate(
                idKind: .shortcut,
                primaryID: ids[0],
                start: first.value.t,
                end: last.value.t,
                kind: .shortcut,
                label: shortcutLabel(first.value),
                applicationBundleID: nil,
                role: nil,
                bounds: geometryContext.bounds,
                confidence: confidenceWithSignals(0.82, cursor: context, geometry: geometryContext, transcript: transcriptContext),
                sources: [.shortcut]
                    + (context.ids.isEmpty ? [] : [.cursor])
                    + (geometryContext.ids.isEmpty ? [] : [.targetGeometry])
                    + (transcriptContext.ids.isEmpty ? [] : [.transcript]),
                evidenceIDs: ids + context.ids + geometryContext.ids + transcriptContext.ids,
                signals: ["safe-shortcut"] + context.signals + geometryContext.signals + transcriptContext.signals
            ))
        }
    }

    private func isSafeShortcut(_ key: KeySample) -> Bool {
        let normalized = key.key.lowercased()
        let safeKeys: Set<String> = [
            "a", "c", "f", "g", "n", "o", "p", "q", "r", "s", "t", "v", "w", "x", "z",
            "return", "enter", "escape", "esc", "tab", "space", "delete", "backspace",
            "left", "right", "up", "down", "home", "end", "pageup", "pagedown"
        ]
        let safeModifiers = !key.modifiers.isEmpty
        return safeModifiers && safeKeys.contains(normalized)
    }

    private func shortcutSignature(_ key: KeySample) -> String {
        key.key.lowercased() + ":" + KeyModifier.allCases
            .filter { key.modifiers.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func shortcutLabel(_ key: KeySample) -> String {
        let modifiers = KeyModifier.allCases
            .filter { key.modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        let keyLabel = key.key.uppercased()
        return modifiers.isEmpty
            ? "Shortcut " + keyLabel
            : "Shortcut " + modifiers + keyLabel
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
