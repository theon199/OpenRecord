import CryptoKit
import Foundation

/// Deterministic, local-only First Cut planning. The planner consumes values
/// supplied by capture/analysis and returns proposals; it never writes a
/// project, sidecar, or in-memory document.
public struct FirstCutPlanner: Sendable {
    public static let analyzerVersion = "first-cut-1"
    public typealias Input = FirstCutAnalysisInput

    public var preset: FirstCutPreset

    public init(preset: FirstCutPreset = .naturalDemo) {
        self.preset = preset
    }

    public static func plan(
        _ input: FirstCutAnalysisInput,
        preset: FirstCutPreset = .naturalDemo,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await FirstCutPlanner(preset: preset).plan(input, existing: existing)
    }

    public static func plan(
        input: FirstCutAnalysisInput,
        preset: FirstCutPreset = .naturalDemo,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await plan(input, preset: preset, existing: existing)
    }

    public static func analyze(
        input: FirstCutAnalysisInput,
        preset: FirstCutPreset = .naturalDemo,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await plan(input, preset: preset, existing: existing)
    }

    public static func apply(
        _ proposals: [FirstCutProposal],
        to document: ProjectDocument,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        FirstCutMaterializer.apply(proposals, to: document, selectedIDs: selectedIDs)
    }

    public static func materialize(
        _ proposals: [FirstCutProposal],
        into document: ProjectDocument,
        selectedIDs: Set<FirstCutProposalID>? = nil
    ) -> ProjectDocument {
        apply(proposals, to: document, selectedIDs: selectedIDs)
    }

    public func plan(
        _ input: FirstCutAnalysisInput,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await checkpoint()
        let duration = sourceDuration(for: input)
        let warnings = try validateCaptureHealth(input.meta)
        try await checkpoint()

        let revision = revision(for: input, duration: duration)
        var proposals: [FirstCutProposal] = []

        // Transcript pause analysis is intentionally first: it provides the
        // most useful cut candidates and gives later visual heuristics a
        // canonical set of ranges to avoid duplicating.
        proposals.append(contentsOf: try await pauseProposals(input, duration: duration, revision: revision))
        try await checkpoint()

        proposals.append(contentsOf: try await inactivityProposals(input, duration: duration, revision: revision))
        try await checkpoint()

        proposals.append(contentsOf: try await repeatedAttemptProposals(input, duration: duration, revision: revision))
        try await checkpoint()

        proposals.append(contentsOf: try await captionProposals(input, duration: duration, revision: revision))
        try await checkpoint()

        proposals.append(contentsOf: try await visualProposals(input, duration: duration, revision: revision))
        try await checkpoint()

        proposals = deduplicate(proposals)
        let reconciled = reconcile(proposals: proposals, existing: existing)
        try await checkpoint()
        return FirstCutPlan(
            analysisRevision: revision,
            preset: preset,
            sourceDuration: duration,
            proposals: reconciled,
            warnings: warnings
        )
    }

    public func plan(
        input: FirstCutAnalysisInput,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await plan(input, existing: existing)
    }

    /// Alias for callers that use an explicit input label.
    public func analyze(
        input: FirstCutAnalysisInput,
        existing: [FirstCutProposal] = []
    ) async throws -> FirstCutPlan {
        try await plan(input, existing: existing)
    }

    // MARK: - Stages

    private func pauseProposals(
        _ input: FirstCutAnalysisInput,
        duration: TimeInterval,
        revision: String
    ) async throws -> [FirstCutProposal] {
        let options = SilenceAnalysisOptions(
            preset: silencePreset,
            minimumPause: preset.minimumPause,
            retainedBreathingRoom: preset.breathingRoom,
            includeTranscriptGaps: true
        )
        let pauses = SilenceAnalyzer.detect(
            samples: input.audioSamples,
            options: options,
            duration: duration > 0 ? duration : nil,
            transcript: input.transcript
        )
        var result: [FirstCutProposal] = []
        for pause in pauses {
            try Task.checkCancellation()
            let start = clamp(pause.cutStart, upperBound: duration)
            let end = clamp(pause.cutEnd, upperBound: duration)
            guard end - start >= ProjectTimeMapper.minimumDecisionDuration,
                  !overlapsManualCut(start: start, end: end, document: input.document),
                  !overlapsCaptureLoss(start: start, end: end, meta: input.meta)
            else { continue }

            let source = pause.source.rawValue
            let evidenceID = evidenceID("pause", start, end, source)
            let decision = EditDecision(
                id: stableUUID("cut|\(startToken(start))|\(endToken(end))|\(source)"),
                start: start,
                end: end
            )
            result.append(makeProposal(
                id: proposalID(.cut, start: start, end: end, signature: source),
                revision: revision,
                kind: .cut,
                confidence: pauseConfidence(pause),
                evidence: [FirstCutEvidenceReference(id: evidenceID, source: "transcript-pause", start: pause.start, end: pause.end)],
                reasons: ["speech-pause", source == "audio-and-transcript" ? "audio-and-transcript-agreement" : "transcript-timing"],
                payload: .cut(decision),
                preview: FirstCutPreview(
                    sourceStart: start,
                    sourceEnd: end,
                    outputDurationBefore: end - start,
                    outputDurationAfter: 0,
                    summary: "Remove pause while retaining breathing room"
                )
            ))
        }
        return result
    }

    private func inactivityProposals(
        _ input: FirstCutAnalysisInput,
        duration: TimeInterval,
        revision: String
    ) async throws -> [FirstCutProposal] {
        let events = activityEvents(input)
        guard duration > 0, !events.isEmpty else { return [] }
        var result: [FirstCutProposal] = []
        var previous = events.first!
        for next in events.dropFirst() {
            try Task.checkCancellation()
            let gap = next.time - previous.time
            if gap >= preset.minimumInactivity {
                let start = previous.time + min(preset.breathingRoom, gap * 0.2)
                let end = next.time - min(preset.breathingRoom, gap * 0.2)
                if end - start >= 0.2,
                   !overlapsCaptureLoss(start: start, end: end, meta: input.meta)
                {
                    let source = stableUniqueStrings(previous.sources + next.sources).joined(separator: "+")
                    let evidence = [
                        FirstCutEvidenceReference(id: previous.resolveID(planner: self), source: source, start: previous.time),
                        FirstCutEvidenceReference(id: next.resolveID(planner: self), source: source, start: next.time)
                    ]
                    let speed = SpeedSegment(
                        id: stableUUID("speed|\(startToken(start))|\(endToken(end))|\(source)"),
                        start: start,
                        end: end,
                        rate: preset == .naturalDemo ? 1.4 : (preset == .tightTutorial ? 1.8 : 2.4)
                    )
                    result.append(makeProposal(
                        id: proposalID(.speed, start: start, end: end, signature: "inactivity|\(source)"),
                        revision: revision,
                        kind: .speed,
                        confidence: min(0.92, 0.53 + min(gap / 12, 0.35)),
                        evidence: evidence,
                        reasons: ["visual-inactivity", "cursor-click-typing-gap"],
                        payload: .speed(speed),
                        preview: FirstCutPreview(
                            sourceStart: start,
                            sourceEnd: end,
                            outputDurationBefore: end - start,
                            outputDurationAfter: (end - start) / speed.rate,
                            summary: "Compress inactive screen time"
                        )
                    ))
                }
            }
            previous = next
        }
        return result.filter { !overlapsManualSpeed($0, document: input.document) }
    }

    private func repeatedAttemptProposals(
        _ input: FirstCutAnalysisInput,
        duration: TimeInterval,
        revision: String
    ) async throws -> [FirstCutProposal] {
        let actions = input.actions
            .map(\.normalized)
            .filter { $0.start.isFinite && $0.end.isFinite }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        guard actions.count > 1 else { return [] }
        var result: [FirstCutProposal] = []
        for (index, action) in actions.enumerated() {
            try Task.checkCancellation()
            guard index + 1 < actions.count else { continue }
            let following = actions[index + 1]
            let sameLabel = normalizedLabel(action.label) == normalizedLabel(following.label)
                && action.kind == following.kind
            let sameApp = action.applicationBundleID == following.applicationBundleID
                || action.applicationBundleID == nil || following.applicationBundleID == nil
            guard sameLabel, sameApp,
                  following.start - action.start >= 0.45,
                  following.start - action.start <= 12
            else { continue }

            let start = max(0, min(action.start, duration))
            let end = min(max(action.end, start + 0.45), duration > 0 ? duration : action.end + 0.45)
            guard end - start >= 0.2,
                  !overlapsCaptureLoss(start: start, end: end, meta: input.meta),
                  !overlapsManualSpeedRange(start: start, end: end, document: input.document)
            else { continue }
            let evidence = action.evidenceIDs.map {
                FirstCutEvidenceReference(id: $0, source: "action-map", start: action.start, end: action.end)
            } + following.evidenceIDs.map {
                FirstCutEvidenceReference(id: $0, source: "action-map", start: following.start, end: following.end)
            }
            let speed = SpeedSegment(
                id: stableUUID("repeat|\(action.id.rawValue)|\(following.id.rawValue)"),
                start: start,
                end: end,
                rate: preset.repeatedAttemptRate
            )
            result.append(makeProposal(
                id: proposalID(.speed, start: start, end: end, signature: "repeated|\(action.id.rawValue)|\(following.id.rawValue)"),
                revision: revision,
                kind: .speed,
                confidence: min(0.9, 0.56 + action.confidence * 0.2 + following.confidence * 0.2),
                evidence: evidence,
                reasons: ["repeated-action-attempt", "likely-abandoned-navigation"],
                payload: .speed(speed),
                preview: FirstCutPreview(
                    sourceStart: start,
                    sourceEnd: end,
                    outputDurationBefore: end - start,
                    outputDurationAfter: (end - start) / speed.rate,
                    summary: "Compress an earlier repeated attempt"
                )
            ))
        }
        return result
    }

    private func captionProposals(
        _ input: FirstCutAnalysisInput,
        duration: TimeInterval,
        revision: String
    ) async throws -> [FirstCutProposal] {
        let segments = input.transcript
            .map(\.normalized)
            .filter { $0.end > $0.start && !displayText($0).isEmpty }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var result: [FirstCutProposal] = []
        for segment in segments {
            try Task.checkCancellation()
            let start = max(0, min(segment.start, duration > 0 ? duration : segment.start))
            let end = max(start + 0.05, min(segment.end, duration > 0 ? duration : segment.end))
            guard end > start else { continue }
            let cue = CaptionCue(
                id: stableUUID("caption|\(segment.id.uuidString.lowercased())|\(startToken(start))|\(endToken(end))"),
                start: start,
                end: end,
                text: displayText(segment)
            )
            let confidence = segment.confidence.map { min(max($0, 0), 1) } ?? 0.65
            result.append(makeProposal(
                id: proposalID(.caption, start: start, end: end, signature: segment.id.uuidString),
                revision: revision,
                kind: .caption,
                confidence: confidence,
                evidence: [FirstCutEvidenceReference(
                    id: evidenceID("transcript", start, end, segment.id.uuidString),
                    source: "transcript",
                    start: segment.start,
                    end: segment.end
                )],
                reasons: ["transcript-caption"],
                payload: .caption(cue),
                preview: FirstCutPreview(sourceStart: start, sourceEnd: end, summary: "Add transcript caption")
            ))
        }
        return result
    }

    private func visualProposals(
        _ input: FirstCutAnalysisInput,
        duration: TimeInterval,
        revision: String
    ) async throws -> [FirstCutProposal] {
        let actions = input.actions.map(\.normalized).sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        var result: [FirstCutProposal] = []
        for action in actions {
            try Task.checkCancellation()
            let start = max(0, min(action.start - 0.4, duration > 0 ? duration : action.start))
            let end = min(max(action.end + 0.8, start + 0.8), duration > 0 ? duration : action.end + 0.8)
            guard end > start else { continue }
            let point = actionAnchor(action, displayBounds: input.meta.displayBounds)
            let evidence = action.evidenceIDs.map {
                FirstCutEvidenceReference(id: $0, source: "action-map", start: action.start, end: action.end)
            }
            if let point, (action.kind == .click || action.kind == .navigation || action.kind == .shortcut || action.kind == .visual) {
                let zoom = ZoomRange(
                    id: stableUUID("zoom|\(action.id.rawValue)|\(startToken(start))|\(endToken(end))"),
                    start: start,
                    end: end,
                    amount: preset == .changelog ? 1.55 : (preset == .tightTutorial ? 1.8 : 1.6),
                    anchor: point,
                    tracking: .followCursor,
                    isLocked: false,
                    source: .automatic
                )
                if !overlapsManualZoom(start: start, end: end, document: input.document) {
                    result.append(makeProposal(
                        id: proposalID(.zoom, start: start, end: end, signature: action.id.rawValue),
                        revision: revision,
                        kind: .zoom,
                        confidence: min(0.95, action.confidence * 0.8 + 0.15),
                        evidence: evidence,
                        reasons: ["action-focus", "cursor-or-target-geometry"],
                        payload: .zoom(zoom),
                        preview: FirstCutPreview(sourceStart: start, sourceEnd: end, summary: "Focus the active control")
                    ))
                }
            }

            if action.kind == .navigation || action.kind == .shortcut {
                let title = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let point else { continue }
                let annotation = Annotation(
                    id: stableUUID("annotation|\(action.id.rawValue)|\(startToken(start))"),
                    start: start,
                    end: end,
                    kind: .stepMarker,
                    text: String(title.prefix(120)),
                    position: point
                )
                result.append(makeProposal(
                    id: proposalID(.annotation, start: start, end: end, signature: action.id.rawValue),
                    revision: revision,
                    kind: .annotation,
                    confidence: min(0.9, action.confidence * 0.75 + 0.15),
                    evidence: evidence,
                    reasons: ["action-callout", "navigation-step"],
                    payload: .annotation(annotation),
                    preview: FirstCutPreview(sourceStart: start, sourceEnd: end, summary: "Mark the interaction")
                ))
            }

            if action.kind == .navigation || action.kind == .marker {
                let beat = StoryBeat(
                    id: stableUUID("chapter|\(action.id.rawValue)|\(startToken(action.start))"),
                    start: max(0, action.start),
                    end: max(action.start + 0.1, action.end),
                    kind: .chapter,
                    title: String(action.label.isEmpty ? "Step" : action.label.prefix(120)),
                    applicationBundleID: action.applicationBundleID,
                    evidenceIDs: action.evidenceIDs,
                    isLocked: false,
                    isSuppressed: false,
                    provenance: StoryBeatProvenance(
                        analyzerVersion: Self.analyzerVersion,
                        confidence: action.confidence,
                        source: "first-cut"
                    )
                )
                result.append(makeProposal(
                    id: proposalID(.chapter, start: beat.start, end: beat.end, signature: action.id.rawValue),
                    revision: revision,
                    kind: .chapter,
                    confidence: action.confidence,
                    evidence: evidence,
                    reasons: ["successful-interaction", "chapter-candidate"],
                    payload: .chapter(beat),
                    preview: FirstCutPreview(sourceStart: beat.start, sourceEnd: beat.end, summary: "Add a chapter marker")
                ))
            }
        }

        let clicks = input.clicks.enumerated().filter { $0.element.down }.sorted {
            if $0.element.t != $1.element.t { return $0.element.t < $1.element.t }
            return $0.offset < $1.offset
        }
        for (index, click) in clicks {
            try Task.checkCancellation()
            let start = max(0, min(click.t - 0.12, duration > 0 ? duration : click.t))
            let end = min(max(start + 0.45, click.t + 0.35), duration > 0 ? duration : click.t + 0.35)
            guard end > start else { continue }
            let effect = CursorEffectRange(
                id: stableUUID("cursor-effect|\(clickToken(click, index: index))"),
                start: start,
                end: end,
                visible: true,
                scale: 1,
                clickEmphasis: true,
                halo: preset != .changelog
            )
            result.append(makeProposal(
                id: proposalID(.cursorEffect, start: start, end: end, signature: clickToken(click, index: index)),
                revision: revision,
                kind: .cursorEffect,
                confidence: 0.62,
                evidence: [FirstCutEvidenceReference(
                    id: evidenceID("click", click.t, click.t, clickToken(click, index: index)),
                    source: "click",
                    start: click.t,
                    end: click.t
                )],
                reasons: ["click-emphasis"],
                payload: .cursorEffect(effect),
                preview: FirstCutPreview(sourceStart: start, sourceEnd: end, summary: "Emphasize the click")
            ))
        }
        return result
    }

    // MARK: - Deterministic reconciliation and helpers

    private func reconcile(
        proposals: [FirstCutProposal],
        existing: [FirstCutProposal]
    ) -> [FirstCutProposal] {
        let generatedByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
        var merged: [FirstCutProposal] = []
        for proposal in proposals {
            var value = proposal
            if let prior = existing.first(where: { $0.id == proposal.id }) {
                if prior.state == .accepted || prior.state == .rejected {
                    value.state = prior.state
                }
            }
            merged.append(value)
        }
        for prior in existing where generatedByID[prior.id] == nil {
            var stale = prior
            stale.state = .stale
            merged.append(stale)
        }
        return merged
    }

    private func deduplicate(_ proposals: [FirstCutProposal]) -> [FirstCutProposal] {
        var seen = Set<FirstCutProposalID>()
        return proposals
            .sorted { lhs, rhs in
                if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
                if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .filter { seen.insert($0.id).inserted }
    }

    private func makeProposal(
        id: FirstCutProposalID,
        revision: String,
        kind: FirstCutProposalKind,
        confidence: Double,
        evidence: [FirstCutEvidenceReference],
        reasons: [String],
        payload: FirstCutProposalPayload,
        preview: FirstCutPreview?
    ) -> FirstCutProposal {
        FirstCutProposal(
            id: id,
            analysisRevision: revision,
            preset: preset,
            kind: kind,
            confidence: confidence,
            evidence: evidence,
            reasons: reasons,
            payload: payload,
            preview: preview
        )
    }

    private func sourceDuration(for input: FirstCutAnalysisInput) -> TimeInterval {
        var values = [input.sourceDuration ?? 0, input.meta.captureDiagnostics?.referenceDuration ?? 0]
        values += input.transcript.map(\.end)
        values += input.actions.map(\.end)
        values += input.cursorSamples.map(\.t)
        values += input.clicks.map(\.t)
        values += input.typingSamples.map(\.t)
        values += input.audioSamples.map(\.timestamp)
        values += input.document.zoomRanges.map(\.end)
        values += input.document.speedSegments.map(\.end)
        values += input.document.captions.map(\.end)
        return values.filter { $0.isFinite }.max().map { max($0, 0) } ?? 0
    }

    private func validateCaptureHealth(_ meta: ProjectMeta) throws -> [String] {
        var fatal: [CaptureWarningCode] = []
        var warnings: [String] = []
        if let health = meta.captureHealth {
            if health.warnings.contains(.missingDisplayVideo) {
                fatal.append(.missingDisplayVideo)
            }
            warnings += health.warnings.map { "capture-\($0.rawValue)" }
        }
        if let diagnostic = meta.captureDiagnostics?.tracks.first(where: { $0.track == .displayVideo }) {
            if diagnostic.status == .missing || diagnostic.status == .truncated {
                fatal.append(diagnostic.status == .missing ? .missingDisplayVideo : .truncatedVideo)
            }
        }
        if !fatal.isEmpty { throw FirstCutPlannerError.invalidCaptureHealth(stableWarnings(fatal)) }
        return stableUniqueStrings(warnings)
    }

    private var silencePreset: SilencePreset {
        switch preset {
        case .naturalDemo: .natural
        case .tightTutorial: .tight
        case .changelog: .fast
        }
    }

    private struct ActivityEvent {
        let time: TimeInterval
        let source: String
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
        let explicitID: AnalysisEvidenceID?
        let sources: [String]

        func resolveID(planner: FirstCutPlanner) -> AnalysisEvidenceID {
            if let explicitID { return explicitID }
            return planner.evidenceID(source, start, end, String(index))
        }
    }

    private func activityEvents(_ input: FirstCutAnalysisInput) -> [ActivityEvent] {
        var values: [ActivityEvent] = []
        values += input.cursorSamples.enumerated().compactMap { index, value in
            guard value.t.isFinite else { return nil }
            let t = max(0, value.t)
            return ActivityEvent(time: t, source: "cursor", index: index, start: value.t, end: value.t, explicitID: nil, sources: ["cursor"])
        }
        values += input.clicks.enumerated().compactMap { index, value in
            guard value.t.isFinite else { return nil }
            let t = max(0, value.t)
            return ActivityEvent(time: t, source: "click", index: index, start: value.t, end: value.t, explicitID: nil, sources: ["click"])
        }
        values += input.typingSamples.enumerated().compactMap { index, value in
            guard value.t.isFinite else { return nil }
            let t = max(0, value.t)
            return ActivityEvent(time: t, source: "typing", index: index, start: value.t, end: value.t, explicitID: nil, sources: ["typing"])
        }
        values += input.actions.enumerated().compactMap { index, value in
            guard value.start.isFinite else { return nil }
            let t = max(0, value.start)
            return ActivityEvent(time: t, source: "action", index: index, start: value.start, end: value.end, explicitID: value.evidenceIDs.first, sources: ["action"])
        }
        return values.sorted {
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.resolveID(planner: self).rawValue < $1.resolveID(planner: self).rawValue
        }
    }

    private func actionAnchor(_ action: ActionCandidate, displayBounds: Rect2D?) -> Point2D? {
        if let bounds = action.bounds {
            let normalized = bounds.width <= 1.001 && bounds.height <= 1.001
                ? SemanticPrivacyFilter.normalizedBounds(bounds)
                : normalizedBounds(bounds, displayBounds: displayBounds)
            return Point2D(x: normalized.x + normalized.width / 2, y: normalized.y + normalized.height / 2)
        }
        return nil
    }

    private func normalizedBounds(_ bounds: Rect2D, displayBounds: Rect2D?) -> Rect2D {
        guard let displayBounds, displayBounds.width > 0, displayBounds.height > 0 else { return .unit }
        return SemanticPrivacyFilter.normalizedBounds(Rect2D(
            x: (bounds.x - displayBounds.x) / displayBounds.width,
            y: (bounds.y - displayBounds.y) / displayBounds.height,
            width: bounds.width / displayBounds.width,
            height: bounds.height / displayBounds.height
        ))
    }

    private func overlapsCaptureLoss(start: TimeInterval, end: TimeInterval, meta: ProjectMeta) -> Bool {
        meta.captureDiagnostics?.lossIntervals.contains { interval in
            interval.normalized.map { overlaps(start, end, $0.start, $0.end) } ?? false
        } ?? false
    }

    private func overlapsManualCut(start: TimeInterval, end: TimeInterval, document: ProjectDocument) -> Bool {
        document.editDecisions.contains { overlaps(start, end, $0.start, $0.end) }
    }

    private func overlapsManualSpeed(_ proposal: FirstCutProposal, document: ProjectDocument) -> Bool {
        overlapsManualSpeedRange(start: proposal.range.start, end: proposal.range.end, document: document)
    }

    private func overlapsManualSpeedRange(start: TimeInterval, end: TimeInterval, document: ProjectDocument) -> Bool {
        document.speedSegments.contains { overlaps(start, end, $0.start, $0.end) }
    }

    private func overlapsManualZoom(start: TimeInterval, end: TimeInterval, document: ProjectDocument) -> Bool {
        document.zoomRanges.contains {
            overlaps(start, end, $0.start, $0.end) && ($0.isLocked || $0.source == .manual)
        }
    }

    private func overlaps(_ lhsStart: TimeInterval, _ lhsEnd: TimeInterval, _ rhsStart: TimeInterval, _ rhsEnd: TimeInterval) -> Bool {
        lhsStart < rhsEnd && rhsStart < lhsEnd
    }

    private func pauseConfidence(_ pause: PauseSuggestion) -> Double {
        switch pause.source {
        case .audioAndTranscript: 0.94
        case .transcriptGap: 0.76
        case .audio: 0.70
        }
    }

    private func displayText(_ segment: TranscriptSegment) -> String {
        String(segment.displayText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }

    private func proposalID(_ kind: FirstCutProposalKind, start: TimeInterval, end: TimeInterval, signature: String) -> FirstCutProposalID {
        let seed = "\(Self.analyzerVersion)|\(preset.rawValue)|\(kind.rawValue)|\(startToken(start))|\(endToken(end))|\(signature)"
        let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        return FirstCutProposalID("first-cut-\(kind.rawValue)-\(digest.prefix(24))")
    }

    private func evidenceID(_ source: String, _ start: TimeInterval, _ end: TimeInterval, _ signature: String) -> AnalysisEvidenceID {
        let seed = "\(source)|\(startToken(start))|\(endToken(end))|\(signature)"
        let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        return try! AnalysisEvidenceID("first-cut-\(source)-\(digest.prefix(24))")
    }

    private func stableUUID(_ seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private func revision(for input: FirstCutAnalysisInput, duration: TimeInterval) -> String {
        var pieces = [preset.rawValue, startToken(duration)]
        pieces += input.transcript.map { "t:\($0.id.uuidString):\(startToken($0.start)):\(endToken($0.end)):\($0.displayText)" }
        pieces += input.actions.map { "a:\($0.id.rawValue):\(startToken($0.start)):\(endToken($0.end)):\($0.kind.rawValue)" }
        pieces += input.cursorSamples.enumerated().map { "c:\($0.offset):\(startToken($0.element.t))" }
        pieces += input.clicks.enumerated().map { "k:\($0.offset):\(startToken($0.element.t)):\($0.element.down)" }
        let digest = SHA256.hash(data: Data(pieces.sorted().joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "first-cut-\(digest.prefix(24))"
    }

    private func startToken(_ value: TimeInterval) -> String {
        String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0, value.isFinite ? value : 0)
        )
    }
    private func endToken(_ value: TimeInterval) -> String { startToken(value) }
    private func clamp(_ value: TimeInterval, upperBound: TimeInterval) -> TimeInterval {
        max(0, min(value.isFinite ? value : 0, upperBound > 0 ? upperBound : max(value, 0)))
    }
    private func normalizedLabel(_ value: String) -> String { value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    private func clickToken(_ value: ClickSample, index: Int) -> String {
        value.sequence.map(String.init) ?? "line-\(index)"
    }
    private func stableUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    private func stableWarnings(_ values: [CaptureWarningCode]) -> [CaptureWarningCode] {
        var seen = Set<CaptureWarningCode>()
        return values.filter { seen.insert($0).inserted }
    }

    private func checkpoint() async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }
}
