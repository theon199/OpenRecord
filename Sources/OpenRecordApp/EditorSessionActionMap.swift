import Foundation
import OpenRecord

/// The ActionMap cache is optional.  This state is intentionally separate
/// from `EditorSaveState`: rebuilding a cache is not an authored document edit.
enum EditorActionMapStatus: String, Sendable, Equatable {
    case idle
    case loading
    case ready
    case unavailable
    case failed
}

enum ActionMapRangeCoverage: String, Sendable, Equatable {
    case included
    case partial
    case cut

    var label: String {
        switch self {
        case .included: "In project"
        case .partial: "Partially cut"
        case .cut: "Cut or outside trim"
        }
    }
}

/// A display row overlays one authored StoryBeat on top of one or more
/// rebuildable candidates.  It contains no transcript payload and is never
/// written to the ActionMap sidecar.
struct ActionMapRow: Identifiable, Hashable, Sendable {
    let id: String
    let candidateID: AnalysisEvidenceID?
    let storyBeatID: UUID?
    let start: TimeInterval
    let end: TimeInterval
    let title: String
    let kind: ActionCandidateKind?
    let storyBeatKind: StoryBeatKind
    let applicationBundleID: String?
    let role: String?
    let confidence: Double
    let evidenceSources: [ActionEvidenceSource]
    let evidenceIDs: [AnalysisEvidenceID]
    let supportingSignals: [String]
    let isLocked: Bool
    let isSuppressed: Bool
    let isAuthored: Bool

    var duration: TimeInterval { max(0, end - start) }

    var kindLabel: String {
        if let kind { return kind.rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
        return storyBeatKind.rawValue.capitalized
    }

    var sourceLabel: String {
        guard !evidenceSources.isEmpty else { return "Authored" }
        return evidenceSources.map { $0.rawValue.replacingOccurrences(of: "-", with: " ") }
            .joined(separator: " · ")
    }
}

@MainActor
extension EditorSession {
    /// Rows are rebuilt from the latest in-memory candidates and authored
    /// corrections.  A beat with no matching candidate remains portable and
    /// visible, which is important when analysis is missing or stale.
    var actionMapRows: [ActionMapRow] {
        let candidates = actionCandidates.map(\.normalized)
        let beats = document.storyBeats.map(\.normalized)
        var usedBeatIDs = Set<UUID>()
        var rows: [ActionMapRow] = []

        for candidate in candidates.sorted(by: Self.actionCandidateOrder) {
            guard let beat = beats.first(where: {
                !usedBeatIDs.contains($0.id) && Self.storyBeat($0, matches: candidate)
            }) else {
                rows.append(Self.row(candidate: candidate, beat: nil))
                continue
            }
            usedBeatIDs.insert(beat.id)
            rows.append(Self.row(candidate: candidate, beat: beat))
        }

        for beat in beats where !usedBeatIDs.contains(beat.id) {
            rows.append(Self.row(candidate: nil, beat: beat))
        }

        let query = actionMapSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows
            .filter { revealSuppressedActionMapRows || !$0.isSuppressed }
            .filter { row in
                guard !query.isEmpty else { return true }
                let transcript = document.transcript
                    .filter { $0.end > row.start && $0.start < row.end }
                    .map(\.displayText)
                    .joined(separator: " ")
                let haystack: [String?] = [
                    row.title,
                    row.applicationBundleID,
                    row.role,
                    row.kind?.rawValue,
                    row.storyBeatKind.rawValue,
                    row.supportingSignals.joined(separator: " "),
                    transcript,
                ]
                return haystack.compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }
    }

    var selectedActionMapRows: [ActionMapRow] {
        actionMapRows.filter(isSelectedActionMapRow)
    }

    var selectedActionMapRow: ActionMapRow? {
        guard selectedActionMapRows.count == 1 else { return nil }
        return selectedActionMapRows[0]
    }

    func actionMapCoverage(for row: ActionMapRow) -> ActionMapRangeCoverage {
        let start = min(max(row.start, 0), timelineDuration)
        let end = min(max(row.end, start), timelineDuration)
        guard end > start else { return .cut }
        let retained = projectTimeMapper.slices.reduce(0.0) { total, slice in
            total + max(0, min(end, slice.sourceEnd) - max(start, slice.sourceStart))
        }
        if retained <= 0.000_1 { return .cut }
        if end - start - retained <= 0.000_1 { return .included }
        return .partial
    }

    func loadFreshActionMap() {
        do {
            let service = ActionMapAnalysisService(
                projectURL: projectURL,
                meta: meta,
                document: document
            )
            if let fresh = try service.loadFresh() {
                actionCandidates = fresh.map(\.normalized)
                actionMapStatus = .ready
                actionMapStatusMessage = "Loaded \(actionCandidates.count) local action\(actionCandidates.count == 1 ? "" : "s")."
            } else {
                actionCandidates = []
                actionMapStatus = .unavailable
                actionMapStatusMessage = "No ActionMap yet. Build one from this recording."
            }
        } catch {
            actionCandidates = []
            actionMapStatus = .unavailable
            actionMapStatusMessage = "ActionMap unavailable; authored story beats remain available."
        }
    }

    /// Starts a cancellable local rebuild.  Only the rebuildable candidate
    /// cache is replaced when it completes; authored story beats and all other
    /// ProjectDocument lanes are left untouched.
    func rebuildActionMap(includeVisionFallback: Bool = true) {
        guard analysisTask == nil else { return }
        analysisCancellationRequested = false
        analysisError = nil
        actionMapStatus = .loading
        actionMapStatusMessage = "Building a private local ActionMap…"
        analysisPhase = .actionMap
        analysisMessage = actionMapStatusMessage
        analysisFraction = 0

        let projectURL = self.projectURL
        let meta = self.meta
        let document = self.document
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard !self.analysisCancellationRequested else { throw CancellationError() }
                let service = ActionMapAnalysisService(
                    projectURL: projectURL,
                    meta: meta,
                    document: document
                )
                self.analysisFraction = 0.15
                let fresh = try await service.analyze(includeVisionFallback: includeVisionFallback)
                try Task.checkCancellation()
                guard !self.analysisCancellationRequested else { throw CancellationError() }
                self.actionCandidates = fresh.map(\.normalized)
                self.actionMapStatus = .ready
                self.actionMapStatusMessage = "Built \(self.actionCandidates.count) local action\(self.actionCandidates.count == 1 ? "" : "s")."
                self.analysisFraction = 1
                self.analysisMessage = self.actionMapStatusMessage
            } catch {
                self.analysisError = error
                if error is CancellationError || self.analysisCancellationRequested {
                    self.actionMapStatus = self.actionCandidates.isEmpty ? .unavailable : .ready
                    self.actionMapStatusMessage = "ActionMap build cancelled. Existing edits were preserved."
                    self.analysisMessage = self.actionMapStatusMessage
                } else {
                    self.actionMapStatus = .failed
                    self.actionMapStatusMessage = "ActionMap failed: \(error.localizedDescription)"
                    self.analysisMessage = self.actionMapStatusMessage
                }
            }
        }
        analysisTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.analysisTask != nil else { return }
            self.analysisTask = nil
            self.analysisPhase = .idle
            self.analysisFraction = nil
            self.analysisError = nil
            self.analysisCancellationRequested = false
        }
    }

    func selectActionMapRow(_ row: ActionMapRow, extending: Bool = false) {
        let alreadySelected = isSelectedActionMapRow(row)
        if !extending {
            selectedActionCandidateIDs.removeAll()
            selectedStoryBeatIDs.removeAll()
        }
        if extending && alreadySelected {
            if let candidateID = row.candidateID { selectedActionCandidateIDs.remove(candidateID) }
            if let storyBeatID = row.storyBeatID { selectedStoryBeatIDs.remove(storyBeatID) }
        } else {
            if let candidateID = row.candidateID { selectedActionCandidateIDs.insert(candidateID) }
            if let storyBeatID = row.storyBeatID { selectedStoryBeatIDs.insert(storyBeatID) }
        }
        selectedSourceRange = TimelineEditRange(start: row.start, end: row.end)
        seek(to: row.start)
    }

    func clearActionMapSelection() {
        selectedActionCandidateIDs.removeAll()
        selectedStoryBeatIDs.removeAll()
        selectedSourceRange = nil
    }

    func renameSelectedAction(to rawTitle: String) {
        guard let row = selectedActionMapRow else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let before = document
        var beat = authoredBeat(for: row)
            ?? makeAuthoredBeat(from: row, title: row.title)
        beat.title = String(title.prefix(120))
        upsert(beat)
        documentDidChange(from: before, actionName: "Rename Action")
    }

    func mergeSelectedActions() {
        let rows = selectedActionMapRows
        guard rows.count >= 2 else { return }
        let before = document
        let authoredIDs = Set(rows.compactMap(\.storyBeatID))
        document.storyBeats.removeAll { authoredIDs.contains($0.id) }
        let references = stableUnique(rows.flatMap { row in
            ([row.candidateID].compactMap { $0 } + row.evidenceIDs)
        })
        let merged = StoryBeat(
            start: max(0, rows.map(\.start).min() ?? 0),
            end: min(timelineDuration, rows.map(\.end).max() ?? 0),
            kind: rows.first?.storyBeatKind ?? .action,
            title: rows.first?.title ?? "Merged action",
            applicationBundleID: rows.map(\.applicationBundleID).dropFirst().reduce(rows.first?.applicationBundleID) {
                $0 == $1 ? $0 : nil
            },
            evidenceIDs: references,
            isLocked: rows.contains(where: \.isLocked),
            isSuppressed: rows.allSatisfy(\.isSuppressed),
            provenance: StoryBeatProvenance(source: "user-merge")
        ).normalized
        document.storyBeats.append(merged)
        document.storyBeats.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        selectedActionCandidateIDs = Set(rows.compactMap(\.candidateID))
        selectedStoryBeatIDs = [merged.id]
        selectedSourceRange = TimelineEditRange(start: merged.start, end: merged.end)
        documentDidChange(from: before, actionName: "Merge Actions")
    }

    func splitSelectedAction(at proposedTime: TimeInterval? = nil) {
        guard let row = selectedActionMapRow else { return }
        let source = authoredBeat(for: row) ?? makeAuthoredBeat(from: row, title: row.title)
        let lower = max(0, source.start)
        let upper = min(timelineDuration, max(source.end, lower))
        guard upper - lower >= 0.1 else { return }
        var split = proposedTime ?? playhead
        if !split.isFinite || split <= lower + 0.05 || split >= upper - 0.05 {
            split = lower + (upper - lower) / 2
        }
        guard split > lower, split < upper else { return }
        let first = StoryBeat(
            id: UUID(), start: lower, end: split, kind: source.kind,
            title: source.title, applicationBundleID: source.applicationBundleID,
            evidenceIDs: source.evidenceIDs, isLocked: source.isLocked,
            isSuppressed: source.isSuppressed,
            provenance: StoryBeatProvenance(source: "user-split")
        ).normalized
        let second = StoryBeat(
            id: UUID(), start: split, end: upper, kind: source.kind,
            title: source.title, applicationBundleID: source.applicationBundleID,
            evidenceIDs: source.evidenceIDs, isLocked: source.isLocked,
            isSuppressed: source.isSuppressed,
            provenance: StoryBeatProvenance(source: "user-split")
        ).normalized
        let before = document
        if let sourceID = row.storyBeatID {
            document.storyBeats.removeAll { $0.id == sourceID }
        }
        document.storyBeats.append(contentsOf: [first, second])
        document.storyBeats.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        selectedActionCandidateIDs = [row.candidateID].compactMap { $0 }.reduce(into: Set()) { $0.insert($1) }
        selectedStoryBeatIDs = [first.id, second.id]
        selectedSourceRange = TimelineEditRange(start: first.start, end: second.end)
        documentDidChange(from: before, actionName: "Split Action")
    }

    func setSelectedActionsSuppressed(_ suppressed: Bool) {
        updateSelectedActions(actionName: suppressed ? "Suppress Actions" : "Restore Actions") {
            $0.isSuppressed = suppressed
        }
    }

    func setSelectedActionsLocked(_ locked: Bool) {
        updateSelectedActions(actionName: locked ? "Lock Actions" : "Unlock Actions") {
            $0.isLocked = locked
        }
    }

    func convertSelectedActionToChapter() { convertSelectedAction(to: .chapter) }
    func convertSelectedActionToStep() { convertSelectedAction(to: .step) }

    func convertSelectedAction(to kind: StoryBeatKind) {
        guard let row = selectedActionMapRow else { return }
        let before = document
        var beat = authoredBeat(for: row) ?? makeAuthoredBeat(from: row, title: row.title)
        beat.kind = kind
        beat.provenance = StoryBeatProvenance(source: "user-convert")
        upsert(beat)
        documentDidChange(from: before, actionName: "Convert Action to \(kind.rawValue.capitalized)")
    }

    func convertSelectedActionToZoom() {
        guard let row = selectedActionMapRow else { return }
        let start = min(max(row.start, 0), timelineDuration)
        let end = min(max(row.end, start), timelineDuration)
        guard end - start >= TimelineRangeEditing.minimumOverlayDuration else { return }
        let before = document
        let anchor: Point2D
        if let bounds = candidate(for: row)?.bounds {
            anchor = Point2D(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2)
        } else {
            anchor = engine.interpolateCursor(at: start) ?? Point2D(x: 0.5, y: 0.5)
        }
        let zoom = ZoomRange(
            start: start, end: end, amount: 1.8, anchor: anchor,
            tracking: .followCursor, isLocked: row.isLocked, source: .manual
        )
        document.zoomRanges.append(zoom)
        document.zoomRanges.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        selectZoom(zoom.id)
        documentDidChange(from: before, actionName: "Convert Action to Zoom", rebuildZoomEngine: true)
    }

    func convertSelectedActionToAnnotation(kind: AnnotationKind = .text) {
        guard let row = selectedActionMapRow else { return }
        let start = min(max(row.start, 0), timelineDuration)
        let end = min(max(row.end, start), timelineDuration)
        guard end - start >= TimelineRangeEditing.minimumOverlayDuration else { return }
        let before = document
        let position = candidate(for: row)?.bounds.map {
            Point2D(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2)
        } ?? Point2D(x: 0.5, y: 0.25)
        var annotation = Annotation(
            start: start, end: end, kind: kind,
            text: kind == .text || kind == .label || kind == .stepMarker ? row.title : "",
            position: position
        )
        document.defaultAnnotationStyle?.apply(to: &annotation)
        document.annotations.append(annotation)
        document.annotations.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        selectAnnotation(annotation.id)
        documentDidChange(from: before, actionName: "Convert Action to Annotation")
    }

    // Short aliases keep menu and automation call sites readable.
    func convertSelectedActionToChapterOrSection() { convertSelectedActionToChapter() }
    func convertSelectedActionToNumberedStep() { convertSelectedActionToStep() }

    // MARK: - Patch Takes Workflow

    /// Creates a patch take guide for the currently selected action or source range.
    func patchGuideForSelection() -> PatchTakeGuide? {
        let range: TimelineEditRange
        if let selected = selectedSourceRange {
            range = selected
        } else if let row = selectedActionMapRow {
            range = TimelineEditRange(start: row.start, end: row.end)
        } else {
            return nil
        }

        let entry = engine.interpolateCursor(at: range.start)
        let exit = engine.interpolateCursor(at: range.end)
        let row = selectedActionMapRow
        let cand = row.flatMap { candidate(for: $0) }
        let bounds = cand?.bounds
        let nearby = document.transcript.filter {
            $0.start >= range.start - 2.0 && $0.end <= range.end + 2.0
        }

        return PatchTakeGuide(
            targetStart: range.start,
            targetEnd: range.end,
            entryCursorPosition: entry,
            exitCursorPosition: exit,
            targetGeometry: bounds,
            actionTitle: row?.title,
            nearbyTranscript: nearby
        )
    }

    /// Replaces the selected action/source range with a patch take.
    func replaceWithPatchTake(
        takeSource: MediaSource,
        patchStart: TimeInterval,
        patchEnd: TimeInterval,
        seamTransition: SeamTransition = .cut,
        transitionDuration: TimeInterval = 0.2,
        audioMode: SeamAudioMode = .sourceAudio
    ) {
        let targetRange: TimelineEditRange
        if let selected = selectedSourceRange {
            targetRange = selected
        } else if let row = selectedActionMapRow {
            targetRange = TimelineEditRange(start: row.start, end: row.end)
        } else {
            return
        }

        let before = document
        document = PatchTakeOperations.applying(
            targetStart: targetRange.start,
            targetEnd: targetRange.end,
            take: takeSource,
            patchStart: patchStart,
            patchEnd: patchEnd,
            seamTransition: seamTransition,
            transitionDuration: transitionDuration,
            audioMode: audioMode,
            to: document,
            primaryDuration: timelineDuration
        )
        selectedSourceRange = nil
        documentDidChange(from: before, actionName: "Replace with Patch Take", rebuildZoomEngine: true)
    }

    /// Reverts a patch take, restoring the timeline.
    func revertPatchTake(sourceID: String) {
        let before = document
        document = PatchTakeOperations.reverting(
            takeID: sourceID,
            in: document,
            primaryDuration: timelineDuration
        )
        documentDidChange(from: before, actionName: "Revert Patch Take", rebuildZoomEngine: true)
    }

    private func updateSelectedActions(
        actionName: String,
        _ mutate: (inout StoryBeat) -> Void
    ) {
        let rows = selectedActionMapRows
        guard !rows.isEmpty else { return }
        let before = document
        for row in rows {
            var beat = authoredBeat(for: row) ?? makeAuthoredBeat(from: row, title: row.title)
            mutate(&beat)
            upsert(beat)
        }
        documentDidChange(from: before, actionName: actionName)
    }

    private func authoredBeat(for row: ActionMapRow) -> StoryBeat? {
        guard let storyBeatID = row.storyBeatID else { return nil }
        return document.storyBeats.first { $0.id == storyBeatID }
    }

    private func candidate(for row: ActionMapRow) -> ActionCandidate? {
        guard let id = row.candidateID else { return nil }
        return actionCandidates.first { $0.id == id }
    }

    private func makeAuthoredBeat(from row: ActionMapRow, title: String) -> StoryBeat {
        StoryBeat(
            start: min(max(row.start, 0), timelineDuration),
            end: min(max(row.end, row.start), timelineDuration),
            kind: row.storyBeatKind,
            title: title,
            applicationBundleID: row.applicationBundleID,
            evidenceIDs: stableUnique(([row.candidateID].compactMap { $0 }) + row.evidenceIDs),
            isLocked: row.isLocked,
            isSuppressed: row.isSuppressed,
            provenance: StoryBeatProvenance(confidence: row.confidence, source: "user")
        ).normalized
    }

    private func upsert(_ beat: StoryBeat) {
        let value = beat.normalized
        if let index = document.storyBeats.firstIndex(where: { $0.id == value.id }) {
            document.storyBeats[index] = value
        } else {
            document.storyBeats.append(value)
        }
        document.storyBeats.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    private func isSelectedActionMapRow(_ row: ActionMapRow) -> Bool {
        row.candidateID.map(selectedActionCandidateIDs.contains) == true
            || row.storyBeatID.map(selectedStoryBeatIDs.contains) == true
    }

    private static func row(candidate: ActionCandidate?, beat: StoryBeat?) -> ActionMapRow {
        let normalizedCandidate = candidate?.normalized
        let normalizedBeat = beat?.normalized
        let candidateID = normalizedCandidate?.id
        let storyBeatID = normalizedBeat?.id
        let references = stableUnique(([candidateID].compactMap { $0 }) + (normalizedCandidate?.evidenceIDs ?? []))
        let sourceIDs = normalizedBeat?.evidenceIDs ?? references
        let sources = normalizedCandidate?.evidenceSources ?? []
        return ActionMapRow(
            id: storyBeatID.map { "story-\($0.uuidString)" } ?? "action-\(candidateID?.rawValue ?? UUID().uuidString)",
            candidateID: candidateID,
            storyBeatID: storyBeatID,
            start: normalizedBeat?.start ?? normalizedCandidate?.start ?? 0,
            end: normalizedBeat?.end ?? normalizedCandidate?.end ?? 0,
            title: normalizedBeat?.title ?? normalizedCandidate?.label ?? "Action",
            kind: normalizedCandidate?.kind,
            storyBeatKind: normalizedBeat?.kind ?? .action,
            applicationBundleID: normalizedBeat?.applicationBundleID ?? normalizedCandidate?.applicationBundleID,
            role: normalizedCandidate?.role,
            confidence: normalizedCandidate?.confidence ?? normalizedBeat?.provenance?.confidence ?? 0,
            evidenceSources: sources,
            evidenceIDs: sourceIDs.isEmpty ? references : sourceIDs,
            supportingSignals: normalizedCandidate?.supportingSignals ?? [],
            isLocked: normalizedBeat?.isLocked ?? false,
            isSuppressed: normalizedBeat?.isSuppressed ?? false,
            isAuthored: normalizedBeat != nil
        )
    }

    private static func storyBeat(_ beat: StoryBeat, matches candidate: ActionCandidate) -> Bool {
        let references = Set(beat.evidenceIDs)
        if references.contains(candidate.id) { return true }
        if !references.isDisjoint(with: candidate.evidenceIDs) { return true }
        // Older v8 authored beats may predate candidate IDs.  A same-range
        // action with a matching title is still a safe correction overlay.
        return abs(beat.start - candidate.start) <= 0.001
            && abs(beat.end - candidate.end) <= 0.001
            && beat.title.localizedCaseInsensitiveCompare(candidate.label) == .orderedSame
    }

    private static func actionCandidateOrder(_ lhs: ActionCandidate, _ rhs: ActionCandidate) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

private func stableUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen = Set<Value>()
    return values.filter { seen.insert($0).inserted }
}
