import AppKit
import Foundation
import OpenRecord
import UniformTypeIdentifiers
#if canImport(Speech)
import Speech
#endif

@MainActor
extension EditorSession {
    var filteredTranscript: [TranscriptSegment] {
        let query = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return document.transcript }
        return document.transcript.filter {
            $0.displayText.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedTranscriptRange: TimelineEditRange? {
        TranscriptTimelineSelection.range(
            in: document.transcript,
            selectedIDs: selectedTranscriptSegmentIDs
        )
    }

    var selectedCursorEffect: CursorEffectRange? {
        guard case .cursorEffect(let id) = timelineSelection.primary else { return nil }
        return document.cursorEffects.first { $0.id == id }
    }

    func selectTimelineItem(_ item: TimelineItemID, extending: Bool = false) {
        selectedSourceRange = nil
        timelineSelection.select(item, extending: extending)
        applyPrimaryTimelineSelection()
    }

    func applyPrimaryTimelineSelection() {
        selectedZoomID = nil
        selectedSpeedID = nil
        selectedCaptionID = nil
        selectedAnnotationID = nil
        selectedRedactionID = nil
        selectedDrawingID = nil
        isWebcamSelected = false
        switch timelineSelection.primary {
        case .zoom(let id): selectedZoomID = id
        case .speed(let id): selectedSpeedID = id
        case .caption(let id): selectedCaptionID = id
        case .annotation(let id): selectedAnnotationID = id
        case .redaction(let id): selectedRedactionID = id
        case .drawing(let id): selectedDrawingID = id
        case .cursorEffect, .none: break
        }
    }

    func deleteTimelineSelection() {
        guard !timelineSelection.isEmpty else { return }
        let before = document
        let rebuild = timelineSelection.kind == .zoom
        document = ProjectTimelineOperations.deleting(
            from: document,
            selection: timelineSelection
        )
        timelineSelection.clear()
        applyPrimaryTimelineSelection()
        documentDidChange(
            from: before,
            actionName: "Delete Timeline Items",
            rebuildZoomEngine: rebuild
        )
    }

    func copyTimelineSelection() {
        let copied = ProjectTimelineOperations.copy(
            from: document,
            selection: timelineSelection
        )
        guard !copied.isEmpty else { return }
        timelineClipboard = copied
    }

    func pasteTimelineItems() {
        guard !timelineClipboard.isEmpty else { return }
        let before = document
        let result = ProjectTimelineOperations.paste(
            timelineClipboard,
            into: document,
            at: playhead,
            sourceDuration: timelineDuration
        )
        document = result.document
        timelineSelection = result.selection
        applyPrimaryTimelineSelection()
        documentDidChange(
            from: before,
            actionName: "Paste Timeline Items",
            rebuildZoomEngine: timelineSelection.kind == .zoom
        )
    }

    func duplicateTimelineSelection() {
        guard !timelineSelection.isEmpty else { return }
        let before = document
        let result = ProjectTimelineOperations.duplicate(
            selection: timelineSelection,
            in: document,
            offset: 0.25,
            sourceDuration: timelineDuration
        )
        document = result.document
        timelineSelection = result.selection
        applyPrimaryTimelineSelection()
        documentDidChange(
            from: before,
            actionName: "Duplicate Timeline Items",
            rebuildZoomEngine: timelineSelection.kind == .zoom
        )
    }

    func addCursorEffectAtPlayhead(
        visible: Bool = true,
        clickEmphasis: Bool = true,
        halo: Bool = false
    ) {
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 3, timelineDuration)
        guard end - start >= TimelineRangeEditing.minimumOverlayDuration else { return }
        let before = document
        let effect = CursorEffectRange(
            start: start,
            end: end,
            visible: visible,
            scale: document.canvas.cursorScale,
            clickEmphasis: clickEmphasis,
            halo: halo
        ).normalized
        document.cursorEffects.append(effect)
        document.cursorEffects.sort {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        timelineSelection = TimelineSelection(
            items: [.cursorEffect(effect.id)],
            primary: .cursorEffect(effect.id)
        )
        applyPrimaryTimelineSelection()
        documentDidChange(from: before, actionName: visible ? "Add Cursor Treatment" : "Hide Cursor")
    }

    func replaceCursorEffect(_ effect: CursorEffectRange) {
        guard let index = document.cursorEffects.firstIndex(where: { $0.id == effect.id })
        else { return }
        let before = document
        var value = effect.normalized
        value.start = min(max(value.start, 0), timelineDuration)
        value.end = min(max(value.end, value.start + TimelineRangeEditing.minimumOverlayDuration), timelineDuration)
        if value.end <= value.start {
            value.start = max(0, value.end - TimelineRangeEditing.minimumOverlayDuration)
        }
        document.cursorEffects[index] = value
        document.cursorEffects.sort {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        documentDidChange(from: before, actionName: "Adjust Cursor Treatment")
    }

    func updateSelectedCursorEffect(
        actionName: String = "Edit Cursor Treatment",
        _ body: (inout CursorEffectRange) -> Void
    ) {
        guard let selectedCursorEffect,
              let index = document.cursorEffects.firstIndex(where: { $0.id == selectedCursorEffect.id })
        else { return }
        let before = document
        body(&document.cursorEffects[index])
        document.cursorEffects[index] = document.cursorEffects[index].normalized
        documentDidChange(from: before, actionName: actionName)
    }

    func selectTranscriptSegment(_ id: UUID, extending: Bool = false) {
        guard let segment = document.transcript.first(where: { $0.id == id }) else { return }
        if extending {
            if selectedTranscriptSegmentIDs.contains(id) {
                selectedTranscriptSegmentIDs.remove(id)
            } else {
                selectedTranscriptSegmentIDs.insert(id)
            }
        } else {
            selectedTranscriptSegmentIDs = [id]
        }
        selectedSourceRange = selectedTranscriptRange
        seek(to: segment.start)
    }

    func deleteSelectedSourceRange() {
        guard let selectedSourceRange,
              selectedSourceRange.end - selectedSourceRange.start
                >= ProjectTimeMapper.minimumDecisionDuration
        else { return }
        let before = document
        document.editDecisions = ProjectTimeMapper.normalizedDecisions(
            document.editDecisions + [EditDecision(
                start: selectedSourceRange.start,
                end: selectedSourceRange.end
            )],
            sourceDuration: timelineDuration
        )
        self.selectedSourceRange = nil
        documentDidChange(from: before, actionName: "Delete Selected Range")
        seek(to: selectedSourceRange.start)
    }

    func updateTranscriptSegmentText(_ id: UUID, text: String) {
        guard let index = document.transcript.firstIndex(where: { $0.id == id }) else { return }
        let before = document
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        document.transcript[index].editedText = normalized.isEmpty ? nil : normalized
        documentDidChange(from: before, actionName: "Correct Transcript")
    }

    func cutSelectedTranscript() {
        let selected = document.transcript.filter {
            selectedTranscriptSegmentIDs.contains($0.id) && $0.end > $0.start
        }
        guard !selected.isEmpty else { return }
        let before = document
        let decisions = selected.map {
            EditDecision(start: $0.start, end: $0.end)
        }
        document.editDecisions = ProjectTimeMapper.normalizedDecisions(
            document.editDecisions + decisions,
            sourceDuration: timelineDuration
        )
        documentDidChange(from: before, actionName: "Remove Transcript Selection")
        seek(to: selected.map(\.start).min() ?? playhead)
    }

    func generateCaptionsFromTranscript(overwrite: Bool = false) {
        guard !document.transcript.isEmpty else { return }
        let before = document
        let generated = CaptionGenerator.regenerate(
            from: document.transcript,
            existing: document.captions,
            overwrite: overwrite
        )
        if overwrite || document.captions.isEmpty {
            document.captions = generated.map {
                var cue = $0
                cue.style = document.defaultCaptionStyle
                return cue
            }
        } else {
            document.captions = generated
        }
        documentDidChange(from: before, actionName: "Generate Captions")
    }

    func transcribe(source: TranscriptSource) {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcriptionStatus = "Preparing on-device transcription…"
        Task { @MainActor in
            defer { isTranscribing = false }
            do {
                try await Self.authorizeSpeechRecognition()
                let requests = try transcriptionRequests(for: source)
                let provider = OnDeviceSpeechTranscriptionProvider()
                var transcript: [TranscriptSegment] = []
                for request in requests {
                    transcriptionStatus = "Transcribing \(request.label)…"
                    let raw = try await provider.transcribe(request: TranscriptionRequest(
                        audioURL: request.url,
                        source: request.source,
                        trackOffset: 0
                    ))
                    transcript.append(contentsOf: raw.map { segment in
                        var value = segment
                        value.start = request.offset + value.start / request.sourceRate
                        value.end = request.offset + value.end / request.sourceRate
                        return value.normalized
                    })
                }
                transcript.sort {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.id.uuidString < $1.id.uuidString
                }
                let before = document
                let corrections = Dictionary(
                    uniqueKeysWithValues: document.transcript.compactMap { segment in
                        segment.editedText.map { (segment.id, $0) }
                    }
                )
                transcript = transcript.map { segment in
                    var value = segment
                    value.editedText = corrections[segment.id]
                    return value
                }
                document.transcript = transcript
                selectedTranscriptSegmentIDs.removeAll()
                documentDidChange(from: before, actionName: "Generate Transcript")
                transcriptionStatus = transcript.isEmpty
                    ? "No speech was recognized."
                    : "Generated \(transcript.count) transcript segments on device."
            } catch {
                transcriptionStatus = nil
                lastErrorCategory = .projectContent
                lastError = "Could not transcribe locally: \(error.localizedDescription)"
            }
        }
    }

    func analyzeSilence(source: TranscriptSource, preset: SilencePreset? = nil) {
        guard !isAnalyzingSilence else { return }
        let selectedPreset = preset ?? silencePreset
        if let preset {
            selectSilencePreset(preset)
        }
        let minimumPause = silenceMinimumPause
        let breathingRoom = silenceBreathingRoom
        isPreviewingSilenceSuggestions = false
        isAnalyzingSilence = true
        transcriptionStatus = "Analyzing pauses locally…"
        let micURL = hasMicrophoneAudio ? ProjectLayout.microphoneAudioURL(in: projectURL) : nil
        let systemURL = hasSystemAudio ? ProjectLayout.systemAudioURL(in: projectURL) : nil
        let microphoneTiming = trackTiming(for: .microphone)
        let systemTiming = trackTiming(for: .systemAudio)
        let transcript = TranscriptTimelineSelection.segments(
            in: document.transcript,
            for: source
        )
        let duration = duration
        Task { @MainActor in
            defer { isAnalyzingSilence = false }
            do {
                let levels = try await Task.detached(priority: .userInitiated) {
                    try Self.audioLevels(
                        source: source,
                        microphoneURL: micURL,
                        microphoneOffset: microphoneTiming.offset,
                        microphoneSourceRate: microphoneTiming.sourceRate,
                        systemURL: systemURL,
                        systemOffset: systemTiming.offset,
                        systemSourceRate: systemTiming.sourceRate
                    )
                }.value
                silenceSuggestions = SilenceAnalyzer.detect(
                    samples: levels,
                    options: SilenceAnalysisOptions(
                        preset: selectedPreset,
                        minimumPause: minimumPause,
                        retainedBreathingRoom: breathingRoom
                    ),
                    duration: duration,
                    transcript: transcript
                )
                acceptedSilenceSuggestionIDs = Set(silenceSuggestions.map(\.id))
                transcriptionStatus = silenceSuggestions.isEmpty
                    ? "No matching pauses found."
                    : "Found \(silenceSuggestions.count) pause suggestions."
            } catch {
                transcriptionStatus = nil
                lastErrorCategory = .projectContent
                lastError = "Could not analyze pauses: \(error.localizedDescription)"
            }
        }
    }

    func toggleSilenceSuggestion(_ id: UUID) {
        let wasPreviewing = isPreviewingSilenceSuggestions
        if acceptedSilenceSuggestionIDs.contains(id) {
            acceptedSilenceSuggestionIDs.remove(id)
        } else {
            acceptedSilenceSuggestionIDs.insert(id)
        }
        if acceptedSilenceSuggestionIDs.isEmpty {
            isPreviewingSilenceSuggestions = false
        } else if isPreviewingSilenceSuggestions {
            seek(to: playhead)
        }
        if wasPreviewing || isPreviewingSilenceSuggestions {
            schedulePreviewAudioRebuild()
        }
    }

    func selectSilencePreset(_ preset: SilencePreset) {
        silencePreset = preset
        silenceMinimumPause = preset.minimumPause
        silenceBreathingRoom = preset.breathingRoom
    }

    func toggleSilencePreview() {
        if isPreviewingSilenceSuggestions {
            isPreviewingSilenceSuggestions = false
            pause()
            seek(to: playhead)
            schedulePreviewAudioRebuild()
            return
        }
        let accepted = silenceSuggestions.filter {
            acceptedSilenceSuggestionIDs.contains($0.id)
        }
        guard let start = accepted.map(\.start).min() else { return }
        isPreviewingSilenceSuggestions = true
        schedulePreviewAudioRebuild()
        seek(to: max(start - 0.5, document.trimIn))
        play()
    }

    func applyAcceptedSilenceSuggestions() {
        let accepted = silenceSuggestions.filter { acceptedSilenceSuggestionIDs.contains($0.id) }
        guard !accepted.isEmpty else { return }
        isPreviewingSilenceSuggestions = false
        let before = document
        let generated = PauseSuggestionApplier.acceptedEditDecisions(
            accepted,
            mapper: committedProjectTimeMapper
        )
        document.editDecisions = ProjectTimeMapper.normalizedDecisions(
            document.editDecisions + generated,
            sourceDuration: timelineDuration
        )
        silenceSuggestions.removeAll()
        acceptedSilenceSuggestionIDs.removeAll()
        documentDidChange(from: before, actionName: "Remove Suggested Pauses")
        seek(to: playhead)
    }

    func nudgeTimelineSelection(by delta: TimeInterval, snappingDisabled: Bool = false) {
        guard !timelineSelection.isEmpty else { return }
        let before = document
        let result = ProjectTimelineOperations.moving(
            selection: timelineSelection,
            in: document,
            by: delta,
            sourceDuration: timelineDuration,
            snapTargets: TimelineSnapping.targets(
                in: document,
                playhead: playhead,
                sourceDuration: timelineDuration,
                excluding: timelineSelection
            ),
            snapThreshold: 0.08,
            snappingDisabled: snappingDisabled
        )
        document = result.document
        timelineSelection = result.selection
        applyPrimaryTimelineSelection()
        documentDidChange(
            from: before,
            actionName: "Nudge Timeline Items",
            rebuildZoomEngine: timelineSelection.kind == .zoom
        )
    }

    func moveTimelineSelection(
        from baseDocument: ProjectDocument,
        by delta: TimeInterval,
        snappingDisabled: Bool
    ) {
        guard timelineSelection.items.count > 1 else { return }
        let before = document
        let result = ProjectTimelineOperations.moving(
            selection: timelineSelection,
            in: baseDocument,
            by: delta,
            sourceDuration: timelineDuration,
            snapTargets: TimelineSnapping.targets(
                in: baseDocument,
                playhead: playhead,
                sourceDuration: timelineDuration,
                excluding: timelineSelection
            ),
            snapThreshold: max(timelineDuration * 0.006, 0.04),
            snappingDisabled: snappingDisabled
        )
        document = result.document
        documentDidChange(
            from: before,
            actionName: "Move Timeline Items",
            rebuildZoomEngine: timelineSelection.kind == .zoom
        )
    }

    func selectAdjacentTimelineItem(forward: Bool) {
        let items = allTimelineItemsSorted()
        guard !items.isEmpty else { return }
        let current = timelineSelection.primary.flatMap { items.firstIndex(of: $0) }
        let nextIndex: Int
        if let current {
            nextIndex = forward
                ? min(current + 1, items.count - 1)
                : max(current - 1, 0)
        } else {
            nextIndex = forward ? 0 : items.count - 1
        }
        selectTimelineItem(items[nextIndex])
    }

    func jumpToAdjacentEditPoint(forward: Bool) {
        let points = editPoints().filter { forward ? $0 > playhead + 0.000_1 : $0 < playhead - 0.000_1 }
        guard let target = forward ? points.min() : points.max() else { return }
        seek(to: target)
    }

    func changeTimelineZoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        timelineZoom = min(max(timelineZoom * factor, 0.5), 8)
    }

    func splitSelectedTimelineItemsAtPlayhead() {
        guard !timelineSelection.isEmpty else {
            addCutAroundPlayhead()
            return
        }
        let before = document
        var inserted = Set<TimelineItemID>()
        let selected = timelineSelection.items

        func splitRange<T>(
            _ items: inout [T],
            id: (T) -> UUID,
            start: (T) -> TimeInterval,
            end: (T) -> TimeInterval,
            setEnd: (inout T, TimeInterval) -> Void,
            clone: (T, UUID, TimeInterval) -> T,
            reference: (UUID) -> TimelineItemID
        ) {
            let originals = items
            for original in originals where selected.contains(reference(id(original))) {
                guard playhead > start(original) + TimelineRangeEditing.minimumOverlayDuration,
                      playhead < end(original) - TimelineRangeEditing.minimumOverlayDuration,
                      let index = items.firstIndex(where: { id($0) == id(original) })
                else { continue }
                var left = items[index]
                setEnd(&left, playhead)
                items[index] = left
                let newID = UUID()
                items.append(clone(original, newID, playhead))
                inserted.insert(reference(newID))
            }
        }

        splitRange(
            &document.captions,
            id: { $0.id }, start: { $0.start }, end: { $0.end },
            setEnd: { $0.end = $1 },
            clone: { value, id, start in
                var copy = value; copy.id = id; copy.start = start; return copy
            },
            reference: TimelineItemID.caption
        )
        splitRange(
            &document.annotations,
            id: { $0.id }, start: { $0.start }, end: { $0.end },
            setEnd: { $0.end = $1 },
            clone: { value, id, start in
                var copy = value; copy.id = id; copy.start = start; return copy
            },
            reference: TimelineItemID.annotation
        )
        splitRange(
            &document.cursorEffects,
            id: { $0.id }, start: { $0.start }, end: { $0.end },
            setEnd: { $0.end = $1 },
            clone: { value, id, start in
                var copy = value; copy.id = id; copy.start = start; return copy
            },
            reference: TimelineItemID.cursorEffect
        )
        splitRange(
            &document.redactions,
            id: { $0.id }, start: { $0.start }, end: { $0.end },
            setEnd: { $0.end = $1 },
            clone: { value, id, start in
                var copy = value; copy.id = id; copy.start = start; return copy
            },
            reference: TimelineItemID.redaction
        )
        splitRange(
            &document.drawings,
            id: { $0.id }, start: { $0.start }, end: { $0.end },
            setEnd: { $0.end = $1 },
            clone: { value, id, start in
                var copy = value; copy.id = id; copy.start = start; return copy
            },
            reference: TimelineItemID.drawing
        )
        guard before != document else { return }
        timelineSelection = TimelineSelection(items: selected.union(inserted), primary: inserted.first)
        applyPrimaryTimelineSelection()
        documentDidChange(from: before, actionName: "Split Timeline Items")
    }

    func addCut(start: TimeInterval, end: TimeInterval, actionName: String = "Add Cut") {
        let lower = min(max(start, document.trimIn), effectiveTrimOut)
        let upper = min(max(end, lower), effectiveTrimOut)
        guard upper - lower >= ProjectTimeMapper.minimumDecisionDuration else { return }
        let before = document
        document.editDecisions.append(EditDecision(start: lower, end: upper))
        document.editDecisions = ProjectTimeMapper.normalizedDecisions(
            document.editDecisions,
            sourceDuration: timelineDuration
        )
        documentDidChange(from: before, actionName: actionName)
        seek(to: lower)
    }

    func applyStylePreset(_ preset: EditorStylePreset) {
        let before = document
        document = preset.applying(to: document)
        documentDidChange(
            from: before,
            actionName: "Apply \(preset.name) Preset",
            rebuildZoomEngine: false
        )
    }

    func reloadLocalStylePresets() {
        do {
            localStylePresets = try LocalPresetStore.applicationSupport().load()
        } catch {
            localStylePresets = []
            presetStatus = "Could not load local presets: \(error.localizedDescription)"
        }
    }

    func saveCurrentStylePreset(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let slug = name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        let preset = EditorStylePreset(
            id: "user-\(slug)",
            name: name,
            caption: document.captions.first?.style ?? document.defaultCaptionStyle,
            webcam: document.webcamOverlay,
            annotation: document.annotations.first.map(AnnotationStylePreset.init)
                ?? document.defaultAnnotationStyle
                ?? AnnotationStylePreset(),
            cursor: CursorStylePreset(
                scale: document.canvas.cursorScale,
                clickEmphasis: document.canvas.cursorClickEmphasis,
                halo: document.canvas.cursorHalo,
                motionBlur: document.canvas.cursorMotionBlur
            ),
            export: document.videoExportSettings
        )
        do {
            _ = try LocalPresetStore.applicationSupport().save(preset)
            reloadLocalStylePresets()
            presetStatus = "Saved \(name) locally."
        } catch {
            presetStatus = "Could not save the preset: \(error.localizedDescription)"
        }
    }

    func applyProjectTemplate(_ template: ProjectTemplate) {
        let before = document
        document = template.applying(to: document)
        documentDidChange(
            from: before,
            actionName: "Apply \(template.name) Template",
            rebuildZoomEngine: false
        )
        projectTemplateStatus = "Applied \(template.name). Concrete values are stored in this project."
    }

    func reloadLocalProjectTemplates() {
        do {
            localProjectTemplates = try LocalProjectTemplateStore.applicationSupport().load()
        } catch {
            localProjectTemplates = []
            projectTemplateStatus = "Could not load project templates: \(error.localizedDescription)"
        }
    }

    func saveCurrentProjectTemplate(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let slug = name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        var template = ProjectTemplate(
            id: "user-\(slug)",
            name: name,
            document: document
        )
        template.caption = document.captions.first?.style ?? document.defaultCaptionStyle
        template.annotation = document.annotations.first.map(AnnotationStylePreset.init)
            ?? document.defaultAnnotationStyle
        do {
            _ = try LocalProjectTemplateStore.applicationSupport().save(template)
            reloadLocalProjectTemplates()
            projectTemplateStatus = "Saved \(name) as a media-free project template."
        } catch {
            projectTemplateStatus = "Could not save the project template: \(error.localizedDescription)"
        }
    }

    func importProjectTemplatePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let templateType = UTType(filenameExtension: ProjectTemplate.fileExtension) {
            panel.allowedContentTypes = [templateType]
        }
        panel.prompt = "Import"
        panel.message = "Import a portable .\(ProjectTemplate.fileExtension) file. Templates never contain recorded media."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let template = try LocalProjectTemplateStore.applicationSupport().import(from: url)
            reloadLocalProjectTemplates()
            projectTemplateStatus = "Imported \(template.name)."
        } catch {
            projectTemplateStatus = "Could not import the project template: \(error.localizedDescription)"
        }
    }

    func exportProjectTemplatePanel(_ template: ProjectTemplate) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let templateType = UTType(filenameExtension: ProjectTemplate.fileExtension) {
            panel.allowedContentTypes = [templateType]
        }
        panel.nameFieldStringValue = "\(template.id).\(ProjectTemplate.fileExtension)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try LocalProjectTemplateStore.applicationSupport().export(template, to: url)
            projectTemplateStatus = "Exported \(template.name)."
        } catch {
            projectTemplateStatus = "Could not export the project template: \(error.localizedDescription)"
        }
    }

    private func addCutAroundPlayhead() {
        let frame = 1.0 / 30.0
        addCut(start: playhead, end: min(playhead + frame, effectiveTrimOut), actionName: "Cut at Playhead")
    }

    private struct TranscriptTrackRequest {
        var url: URL
        var source: TranscriptSource
        var label: String
        var offset: TimeInterval
        var sourceRate: Double
    }

    private func transcriptionRequests(for source: TranscriptSource) throws -> [TranscriptTrackRequest] {
        func request(
            url: URL,
            source: TranscriptSource,
            label: String,
            track: CaptureTrackKind
        ) -> TranscriptTrackRequest? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let timing = trackTiming(for: track)
            return TranscriptTrackRequest(
                url: url,
                source: source,
                label: label,
                offset: timing.offset,
                sourceRate: timing.sourceRate
            )
        }
        let microphone = request(
            url: ProjectLayout.microphoneAudioURL(in: projectURL),
            source: .microphone,
            label: "microphone audio",
            track: .microphone
        )
        let system = request(
            url: ProjectLayout.systemAudioURL(in: projectURL),
            source: .systemAudio,
            label: "system audio",
            track: .systemAudio
        )
        let values: [TranscriptTrackRequest]
        switch source {
        case .microphone: values = microphone.map { [$0] } ?? []
        case .systemAudio: values = system.map { [$0] } ?? []
        case .mixed: values = [microphone, system].compactMap { $0 }
        }
        guard !values.isEmpty else { throw TranscriptionError.missingAudioURL }
        return values
    }

    private func trackTiming(for track: CaptureTrackKind) -> (offset: TimeInterval, sourceRate: Double) {
        if let diagnostic = meta.captureDiagnostics?.diagnostic(for: track) {
            return (
                diagnostic.initialOffset ?? 0,
                diagnostic.correction?.sourceRate ?? 1
            )
        }
        switch track {
        case .microphone: return (meta.captureTiming?.microphoneOffset ?? 0, 1)
        case .systemAudio: return (meta.captureTiming?.systemAudioOffset ?? 0, 1)
        default: return (0, 1)
        }
    }

    nonisolated private static func audioLevels(
        source: TranscriptSource,
        microphoneURL: URL?,
        microphoneOffset: TimeInterval,
        microphoneSourceRate: Double,
        systemURL: URL?,
        systemOffset: TimeInterval,
        systemSourceRate: Double
    ) throws -> [AudioLevelSample] {
        let reader = LocalAudioLevelReader()
        var tracks: [[AudioLevelSample]] = []
        if source == .microphone || source == .mixed, let microphoneURL {
            tracks.append(LocalAudioLevelAnalyzer.mapToTimeline(
                try reader.read(from: microphoneURL),
                offset: microphoneOffset,
                sourceRate: microphoneSourceRate
            ))
        }
        if source == .systemAudio || source == .mixed, let systemURL {
            tracks.append(LocalAudioLevelAnalyzer.mapToTimeline(
                try reader.read(from: systemURL),
                offset: systemOffset,
                sourceRate: systemSourceRate
            ))
        }
        guard !tracks.isEmpty else { throw TranscriptionError.missingAudioURL }
        return LocalAudioLevelAnalyzer.merge(tracks: tracks)
    }

    private static func authorizeSpeechRecognition() async throws {
        #if canImport(Speech)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw TranscriptionError.onDeviceRecognitionUnavailable(
                "Speech Recognition permission was not granted"
            )
        }
        #else
        throw TranscriptionError.onDeviceRecognitionUnavailable(
            "the Speech framework is unavailable"
        )
        #endif
    }

    private func allTimelineItemsSorted() -> [TimelineItemID] {
        var values: [(TimelineItemID, TimeInterval)] = []
        values += document.zoomRanges.map { (.zoom($0.id), $0.start) }
        values += document.speedSegments.map { (.speed($0.id), $0.start) }
        values += document.captions.map { (.caption($0.id), $0.start) }
        values += document.annotations.map { (.annotation($0.id), $0.start) }
        values += document.cursorEffects.map { (.cursorEffect($0.id), $0.start) }
        values += document.redactions.map { (.redaction($0.id), $0.start) }
        values += document.drawings.map { (.drawing($0.id), $0.start) }
        return values.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.kind.rawValue != $1.0.kind.rawValue {
                return $0.0.kind.rawValue < $1.0.kind.rawValue
            }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map(\.0)
    }

    private func editPoints() -> [TimeInterval] {
        var points = [document.trimIn, effectiveTrimOut]
        points += document.editDecisions.flatMap { [$0.start, $0.end] }
        points += document.zoomRanges.flatMap { [$0.start, $0.end] }
        points += document.speedSegments.flatMap { [$0.start, $0.end] }
        points += document.captions.flatMap { [$0.start, $0.end] }
        points += document.annotations.flatMap { [$0.start, $0.end] }
        points += document.cursorEffects.flatMap { [$0.start, $0.end] }
        points += document.redactions.flatMap { [$0.start, $0.end] }
        points += document.drawings.flatMap { [$0.start, $0.end] }
        return Array(Set(points.filter(\.isFinite))).sorted()
    }
}
