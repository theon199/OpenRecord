import AppKit
import Foundation
import OpenRecord

@MainActor
extension EditorSession {
    func loadFirstCutPlan() {
        do {
            firstCutPlan = try FirstCutAnalysisService(
                projectURL: projectURL,
                meta: meta,
                document: document,
                preset: firstCutPreset
            ).loadPlan()
            selectedFirstCutProposalIDs = Set(
                firstCutPlan?.proposals.filter { $0.state == .accepted }.map(\.id) ?? []
            )
        } catch {
            firstCutPlan = nil
            selectedFirstCutProposalIDs.removeAll()
            firstCutStatusMessage = "First Cut suggestions could not be loaded. Regenerate them locally."
        }
    }

    /// Runs the complete suggestion-only pipeline. Transcription and
    /// ActionMap evidence are held outside ProjectDocument until the user
    /// explicitly applies proposals, so Skip and cancellation are mutation-free.
    func generateFirstCut(preset: FirstCutPreset? = nil) {
        guard analysisTask == nil else { return }
        let selectedPreset = preset ?? firstCutPreset
        firstCutPreset = selectedPreset
        analysisCancellationRequested = false
        analysisError = nil
        analysisPhase = .firstCut
        analysisMessage = "Validating capture health…"
        analysisFraction = 0.05
        firstCutStatusMessage = analysisMessage

        let projectURL = self.projectURL
        let meta = self.meta
        let document = self.document
        let duration = self.duration
        let samples = self.samples
        let clicks = self.clicks
        let typing = self.typing
        let shouldTranscribe = firstCutTranscribesWhenAvailable
            && document.transcript.isEmpty
            && (hasMicrophoneAudio || hasSystemAudio)
        let transcriptSource: TranscriptSource = hasMicrophoneAudio && hasSystemAudio
            ? .mixed
            : (hasMicrophoneAudio ? .microphone : .systemAudio)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                var transcript = document.transcript
                if shouldTranscribe {
                    self.analysisMessage = "Transcribing selected audio locally…"
                    self.analysisFraction = 0.15
                    transcript = try await self.generateLocalTranscript(source: transcriptSource) { fraction, label in
                        self.analysisMessage = "Transcribing \(label)…"
                        self.analysisFraction = 0.15 + fraction * 0.2
                    }
                }

                try Task.checkCancellation()
                self.analysisMessage = "Building the local ActionMap…"
                self.analysisFraction = 0.4
                let actions = try await ActionMapAnalysisService(
                    projectURL: projectURL,
                    meta: meta,
                    document: document
                ).analyze()

                try Task.checkCancellation()
                self.analysisMessage = "Ranking pauses, inactivity, and repeated attempts…"
                self.analysisFraction = 0.65
                let input = FirstCutAnalysisInput(
                    document: document,
                    meta: meta,
                    sourceDuration: duration,
                    transcript: transcript,
                    actions: actions,
                    cursorSamples: samples,
                    clicks: clicks,
                    typingSamples: typing
                )
                let plan = try await FirstCutAnalysisService(
                    projectURL: projectURL,
                    meta: meta,
                    document: document,
                    preset: selectedPreset
                ).analyze(input: input)

                try Task.checkCancellation()
                self.actionCandidates = actions
                self.actionMapStatus = .ready
                self.firstCutPlan = plan
                self.selectedFirstCutProposalIDs = Set(
                    plan.proposals.filter { $0.state == .accepted }.map(\.id)
                )
                self.analysisFraction = 1
                self.firstCutStatusMessage = plan.proposals.isEmpty
                    ? "First Cut found no safe suggestions. The project was not changed."
                    : "First Cut prepared \(plan.proposals.count) reviewable suggestion\(plan.proposals.count == 1 ? "" : "s")."
                self.analysisMessage = self.firstCutStatusMessage
                self.presentedReviewSheet = .firstCut
            } catch {
                self.analysisError = error
            }
        }
        analysisGeneration &+= 1
        let generation = analysisGeneration
        analysisTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.analysisGeneration == generation else { return }
            self.analysisTask = nil
            let error = self.analysisError
            self.analysisError = nil
            let cancelled = error is CancellationError || self.analysisCancellationRequested
            self.analysisPhase = .idle
            self.analysisFraction = nil
            self.analysisCancellationRequested = false
            if cancelled {
                self.firstCutStatusMessage = "First Cut cancelled. Captured media and project edits were preserved."
                self.analysisMessage = self.firstCutStatusMessage
            } else if let error {
                self.firstCutStatusMessage = "First Cut failed: \(error.localizedDescription)"
                self.analysisMessage = self.firstCutStatusMessage
                self.lastErrorCategory = .projectContent
                self.lastError = self.firstCutStatusMessage
            }
        }
    }

    func setFirstCutProposal(_ id: FirstCutProposalID, accepted: Bool) {
        guard var plan = firstCutPlan else { return }
        let state: FirstCutProposalState = accepted ? .accepted : .rejected
        do {
            let proposals = try FirstCutAnalysisService(
                projectURL: projectURL,
                meta: meta,
                document: document,
                preset: plan.preset
            ).updateState(state, for: [id])
            plan.proposals = proposals
            firstCutPlan = plan
            if accepted {
                selectedFirstCutProposalIDs.insert(id)
            } else {
                selectedFirstCutProposalIDs.remove(id)
            }
        } catch {
            lastErrorCategory = .projectContent
            lastError = "Could not save First Cut review state: \(error.localizedDescription)"
        }
    }

    func applySelectedFirstCutProposals() {
        guard let plan = firstCutPlan, !selectedFirstCutProposalIDs.isEmpty else { return }
        let before = document
        let service = FirstCutAnalysisService(
            projectURL: projectURL,
            meta: meta,
            document: document,
            preset: plan.preset
        )
        document = service.materialize(plan, selectedIDs: selectedFirstCutProposalIDs)
            .normalizedForTimelineEditing(sourceDuration: timelineDuration)
        documentDidChange(from: before, actionName: "Apply First Cut", rebuildZoomEngine: true)
        presentedReviewSheet = nil
        firstCutStatusMessage = "Applied \(selectedFirstCutProposalIDs.count) First Cut suggestion\(selectedFirstCutProposalIDs.count == 1 ? "" : "s") as one undoable edit."
    }

    func applyAllFirstCutProposals() {
        guard var plan = firstCutPlan else { return }
        let actionable = Set(plan.proposals.filter(\.isActionable).map(\.id))
        guard !actionable.isEmpty else { return }
        do {
            let proposals = try FirstCutAnalysisService(
                projectURL: projectURL,
                meta: meta,
                document: document,
                preset: plan.preset
            ).updateState(.accepted, for: actionable)
            plan.proposals = proposals
            firstCutPlan = plan
            selectedFirstCutProposalIDs = actionable
            applySelectedFirstCutProposals()
        } catch {
            lastErrorCategory = .projectContent
            lastError = "Could not apply First Cut: \(error.localizedDescription)"
        }
    }

    func rejectAllFirstCutProposals() {
        guard var plan = firstCutPlan else { return }
        let pending = Set(plan.proposals.filter { $0.state == .pending }.map(\.id))
        do {
            plan.proposals = try FirstCutAnalysisService(
                projectURL: projectURL,
                meta: meta,
                document: document,
                preset: plan.preset
            ).updateState(.rejected, for: pending)
            firstCutPlan = plan
            selectedFirstCutProposalIDs.removeAll()
            presentedReviewSheet = nil
            firstCutStatusMessage = "Kept the current edit. No First Cut suggestions were applied."
        } catch {
            lastErrorCategory = .projectContent
            lastError = "Could not save First Cut review state: \(error.localizedDescription)"
        }
    }

    func loadPrivacyFindings() {
        do {
            privacyFindings = try privacyService().loadFresh() ?? []
            privacyReport = privacyService().makeReport(findings: privacyFindings)
        } catch {
            privacyFindings = []
            privacyStatusMessage = "Privacy analysis is unavailable. Run a new local scan."
        }
    }

    func analyzePrivacy() {
        guard analysisTask == nil else { return }
        analysisCancellationRequested = false
        analysisError = nil
        analysisPhase = .privacy
        analysisMessage = "Scanning source frames locally for possible private content…"
        analysisFraction = 0.05
        privacyStatusMessage = analysisMessage
        let service = privacyService()
        let videoURL = ProjectLayout.displayVideoURL(in: projectURL)
        let timestamps = privacyScanTimestamps()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let observations = try await service.scanRenderedOutput(
                    videoURL: videoURL,
                    timestamps: timestamps
                )
                try Task.checkCancellation()
                self.analysisFraction = 0.75
                self.analysisMessage = "Classifying possible findings without storing recognized text…"
                let findings = try service.analyze(
                    textObservations: observations.observations,
                    sensitiveTerms: self.parsedPrivacySensitiveTerms
                )
                try Task.checkCancellation()
                self.privacyFindings = findings
                self.privacyReport = service.makeReport(findings: findings)
                self.analysisFraction = 1
                self.privacyStatusMessage = findings.isEmpty
                    ? "No possible findings were detected. Detection is best effort; review the video before sharing."
                    : "Found \(findings.count) possible privacy item\(findings.count == 1 ? "" : "s") for review."
                self.analysisMessage = self.privacyStatusMessage
            } catch {
                self.analysisError = error
            }
        }
        analysisGeneration &+= 1
        let generation = analysisGeneration
        analysisTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard let self, self.analysisGeneration == generation else { return }
            self.analysisTask = nil
            let error = self.analysisError
            self.analysisError = nil
            let cancelled = error is CancellationError || self.analysisCancellationRequested
            self.analysisPhase = .idle
            self.analysisFraction = nil
            self.analysisCancellationRequested = false
            if cancelled {
                self.privacyStatusMessage = "Privacy scan cancelled. Existing findings and edits were preserved."
                self.analysisMessage = self.privacyStatusMessage
            } else if let error {
                self.privacyStatusMessage = "Privacy scan failed: \(error.localizedDescription)"
                self.analysisMessage = self.privacyStatusMessage
                self.lastErrorCategory = .projectContent
                self.lastError = self.privacyStatusMessage
            }
        }
    }

    func setPrivacyFinding(_ id: AnalysisEvidenceID, state: PrivacyFindingState, materialize: Bool = false) {
        let service = privacyService()
        do {
            privacyFindings = try service.updateState(state, for: id)
            guard materialize,
                  let finding = privacyFindings.first(where: { $0.id == id }),
                  finding.isAccepted
            else {
                privacyReport = service.makeReport(findings: privacyFindings)
                return
            }
            let before = document
            let additions = finding.redactionRegions().filter { candidate in
                !document.redactions.contains { existing in
                    abs(existing.start - candidate.start) < 0.001
                        && abs(existing.end - candidate.end) < 0.001
                        && existing.rect == candidate.rect
                }
            }
            document.redactions.append(contentsOf: additions)
            document = document.normalizedForTimelineEditing(sourceDuration: timelineDuration)
            documentDidChange(from: before, actionName: "Accept Privacy Finding")
            if let first = additions.first {
                selectTimelineItem(.redaction(first.id))
                seek(to: first.start)
            }
            privacyReport = service.makeReport(findings: privacyFindings)
        } catch {
            lastErrorCategory = .projectContent
            lastError = "Could not update privacy review: \(error.localizedDescription)"
        }
    }

    func verifyRenderedPrivacy(videoURL: URL) async -> PrivacyReport {
        do {
            let report = try await privacyService().verifyRenderedOutput(
                findings: privacyFindings,
                videoURL: videoURL,
                duration: committedProjectTimeMapper.outputDuration,
                sampleInterval: 1
            )
            privacyReport = report
            let reportURL = videoURL.deletingPathExtension()
                .appendingPathExtension("privacy-report.json")
            let data = try ProjectJSON.encoder.encode(report)
            try data.write(to: reportURL, options: .atomic)
            privacyStatusMessage = "Rendered output was scanned and a local privacy report was saved beside it."
            return report
        } catch {
            let report = privacyService().makeReport(
                findings: privacyFindings,
                warnings: ["Rendered-output scan failed: \(error.localizedDescription)"]
            )
            privacyReport = report
            privacyStatusMessage = "Rendered-output privacy scan could not complete. Review the exported video manually."
            return report
        }
    }

    func presentSanitizedShareCopyPanel() {
        guard exportProgress == nil else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title) Sanitized.\(ProjectLayout.bundleExtension)"
        panel.title = "Create Sanitized Share Copy"
        panel.prompt = "Create Copy"
        panel.message = "Creates a derivative with rendered-safe media and allowlisted metadata only. The editable source remains unchanged and is not sanitized."
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != ProjectLayout.bundleExtension {
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.createSanitizedShareCopy(to: destination)
        }
        exportTask = task
    }

    private func createSanitizedShareCopy(to destination: URL) async {
        let temporaryVideo = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openrecord-sanitized-\(UUID().uuidString).mp4",
            isDirectory: false
        )
        let temporaryReport = temporaryVideo.deletingPathExtension()
            .appendingPathExtension("privacy-report.json")
        defer {
            try? FileManager.default.removeItem(at: temporaryVideo)
            try? FileManager.default.removeItem(at: temporaryReport)
            exportProgress = nil
            isCancellingExport = false
            exportTask = nil
        }

        exportProgress = ExportProgress(phase: .preparing, fraction: 0)
        isCancellingExport = false
        lastError = nil
        var renderedDocument = document
        renderedDocument.videoExportSettings.codec = .h264
        do {
            try await Exporter(projectBundleURL: projectURL).exportWithStatus(
                project: renderedDocument,
                url: temporaryVideo
            ) { [weak self] status in
                Task { @MainActor in self?.exportProgress = status }
            }
            try Task.checkCancellation()
            let report = await verifyRenderedPrivacy(videoURL: temporaryVideo)
            try Task.checkCancellation()
            let sourceProjectURL = projectURL
            let sourceMeta = meta
            let sourceDocument = document
            _ = try await Task.detached(priority: .utility) {
                try SanitizedShareCopyService().create(
                    sourceProjectURL: sourceProjectURL,
                    renderedDisplayURL: temporaryVideo,
                    sourceMeta: sourceMeta,
                    sourceDocument: sourceDocument,
                    privacyReport: report,
                    destinationURL: destination
                )
            }.value
            privacyStatusMessage = "Created a sanitized derivative. The original editable bundle still contains source media and telemetry."
        } catch is CancellationError {
            privacyStatusMessage = "Sanitized Share Copy cancelled; no partial package was installed."
        } catch {
            lastErrorCategory = .export
            lastError = "Could not create Sanitized Share Copy: \(error.localizedDescription)"
        }
    }

    private func privacyService() -> PrivacyAnalysisService {
        PrivacyAnalysisService(
            projectURL: projectURL,
            meta: meta,
            document: document,
            sensitiveTerms: parsedPrivacySensitiveTerms,
            configuration: PrivacyAnalyzerConfiguration(
                detectFaces: privacyDetectFaces,
                detectNames: privacyDetectNames,
                sourceSize: Size2D(width: Double(sourceWidth), height: Double(sourceHeight))
            )
        )
    }

    private var parsedPrivacySensitiveTerms: [String] {
        privacySensitiveTerms
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func privacyScanTimestamps() -> [TimeInterval] {
        var times = Set<Double>()
        var t = 0.0
        while t <= duration {
            times.insert(t)
            t += 0.5
        }
        times.insert(max(duration, 0))
        for click in clicks where click.down { times.insert(max(click.t, 0)) }
        for action in actionCandidates { times.insert(max(action.start, 0)) }
        return times.sorted()
    }
}
