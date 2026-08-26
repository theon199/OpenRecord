import AppKit
@preconcurrency import AVFoundation
import Foundation
import OpenRecord
import UniformTypeIdentifiers

private actor ProjectSaveCoordinator {
    let library: ProjectLibrary
    let projectURL: URL

    init(library: ProjectLibrary, projectURL: URL) {
        self.library = library
        self.projectURL = projectURL
    }

    func save(document: ProjectDocument) throws {
        try library.save(document: document, to: projectURL)
    }
}

/// A project can still be opened when one telemetry stream is damaged. The
/// issue carries the independently decoded streams so the caller can present
/// an Open Anyway / Cancel choice without losing the healthy track.
struct EditorTelemetryLoadIssue: Error, LocalizedError, Sendable {
    let mouse: [CursorSample]
    let clicks: [ClickSample]
    let keys: [KeySample]
    let messages: [String]

    var errorDescription: String? {
        "Some recording telemetry could not be loaded: \(messages.joined(separator: " "))"
    }
}

@MainActor
@Observable
final class EditorSession {
    let projectURL: URL
    let library: ProjectLibrary

    var meta: ProjectMeta
    var document: ProjectDocument
    var samples: [CursorSample]
    var clicks: [ClickSample]
    var keys: [KeySample]
    var targetGeometry: [TargetGeometrySample]
    var engine: ZoomEngine
    var keyboardTimeline: KeyboardOverlayTimeline

    var duration: TimeInterval
    var playhead: TimeInterval = 0
    var isPlaying = false
    var selectedZoomID: UUID?
    var selectedSpeedID: UUID?
    var selectedCaptionID: UUID?
    var selectedAnnotationID: UUID?
    var isWebcamSelected = false
    var timelineSelection = TimelineSelection()
    var timelineClipboard = TimelineClipboard()
    var timelineZoom: Double = 1
    var transcriptSearchText = ""
    var selectedTranscriptSegmentIDs = Set<UUID>()
    var isTranscribing = false
    var transcriptionStatus: String?
    var silencePreset: SilencePreset = .natural
    var silenceMinimumPause: TimeInterval = SilencePreset.natural.minimumPause
    var silenceBreathingRoom: TimeInterval = SilencePreset.natural.breathingRoom
    var silenceSuggestions: [PauseSuggestion] = []
    var acceptedSilenceSuggestionIDs = Set<UUID>()
    var isAnalyzingSilence = false
    var isPreviewingSilenceSuggestions = false
    var localStylePresets: [EditorStylePreset] = []
    var presetStatus: String?
    var copyExportToLibrary = false
    var exportProgress: ExportProgress?
    private(set) var isCancellingExport = false
    var lastError: String?
    var lastErrorCategory: LocalDiagnosticsErrorCategory = .none
    private(set) var diagnosticsCopied = false
    /// Warnings retained for the lifetime of the editor and shown by the
    /// parent app as a persistent degraded-project indicator.
    private(set) var persistentWarnings: [String] = []
    private(set) var telemetryIssueMessages: [String] = []
    var hasVideo: Bool
    var sourceWidth: Int
    var sourceHeight: Int
    var cursorImage: NSImage?
    var cursorSprite: CursorSprite?
    var webcamPlayer: AVPlayer?
    var webcamDuration: TimeInterval
    var webcamWidth: Int
    var webcamHeight: Int

    let player: AVPlayer

    var hasWebcamVideo: Bool { webcamPlayer != nil }
    var hasMicrophoneAudio: Bool {
        FileManager.default.fileExists(
            atPath: ProjectLayout.microphoneAudioURL(in: projectURL).path
        )
    }
    var hasSystemAudio: Bool {
        FileManager.default.fileExists(
            atPath: ProjectLayout.systemAudioURL(in: projectURL).path
        )
    }
    var webcamAspect: Double {
        Double(max(webcamWidth, 1)) / Double(max(webcamHeight, 1))
    }

    func webcamIsVisible(at time: TimeInterval) -> Bool {
        guard hasWebcamVideo else { return false }
        guard let localTime = webcamSourceTime(at: time) else { return false }
        return localTime >= 0 && localTime <= webcamDuration
    }

    private(set) var editRevision: UInt64 = 0
    private(set) var savedRevision: UInt64 = 0
    private var savedDocument: ProjectDocument
    private var documentHistory = ProjectDocumentHistory()

    var hasUnsavedChanges: Bool { editRevision != savedRevision }
    var canUndo: Bool { documentHistory.canUndo }
    var canRedo: Bool { documentHistory.canRedo }
    var undoMenuTitle: String {
        documentHistory.undoActionName.map { "Undo \($0)" } ?? "Undo"
    }
    var redoMenuTitle: String {
        documentHistory.redoActionName.map { "Redo \($0)" } ?? "Redo"
    }

    var title: String {
        projectURL.deletingPathExtension().lastPathComponent
    }

    var timelineDuration: TimeInterval {
        max(duration, 0.01)
    }

    /// The single timing authority shared with every export path. Editor
    /// lanes remain authored in source time, while this mapper supplies the
    /// ripple/output position and canonical source frame for the playhead.
    var committedProjectTimeMapper: ProjectTimeMapper {
        ProjectTimeMapper(project: document, sourceDuration: duration)
    }

    var projectTimeMapper: ProjectTimeMapper {
        guard isPreviewingSilenceSuggestions else {
            return committedProjectTimeMapper
        }
        let accepted = silenceSuggestions.filter {
            acceptedSilenceSuggestionIDs.contains($0.id)
        }
        guard !accepted.isEmpty else { return committedProjectTimeMapper }
        var preview = document
        let proposed = accepted.map {
            EditDecision(start: $0.cutStart, end: $0.cutEnd)
        }
        preview.editDecisions = ProjectTimeMapper.normalizedDecisions(
            document.editDecisions + proposed,
            sourceDuration: duration
        )
        return ProjectTimeMapper(project: preview, sourceDuration: duration)
    }

    var outputDuration: TimeInterval {
        projectTimeMapper.outputDuration
    }

    var outputPlayhead: TimeInterval {
        projectTimeMapper.clampedOutputTime(forSourceTime: playhead)
    }

    var previewSourceTime: TimeInterval {
        projectTimeMapper.sourceTime(atOutputTime: outputPlayhead)
    }

    var selectedZoom: ZoomRange? {
        guard let selectedZoomID else { return nil }
        return document.zoomRanges.first { $0.id == selectedZoomID }
    }

    var selectedSpeedSegment: SpeedSegment? {
        guard let selectedSpeedID else { return nil }
        return document.speedSegments.first { $0.id == selectedSpeedID }
    }

    var selectedCaption: CaptionCue? {
        guard let selectedCaptionID else { return nil }
        return document.captions.first { $0.id == selectedCaptionID }
    }

    var selectedAnnotation: Annotation? {
        guard let selectedAnnotationID else { return nil }
        return document.annotations.first { $0.id == selectedAnnotationID }
    }

    var currentPlaybackRate: Double {
        SpeedTimeline(segments: document.speedSegments).rate(at: previewSourceTime)
    }

    var canAddSpeedAtPlayhead: Bool {
        if document.speedSegments.contains(where: { playhead >= $0.start && playhead < $0.end }) {
            return true
        }
        let nextStart = document.speedSegments
            .filter { $0.start > playhead }
            .map(\.start)
            .min() ?? timelineDuration
        return min(playhead + 3, nextStart, timelineDuration) - playhead
            >= SpeedTimeline.minimumSegmentDuration
    }

    /// Whether the playhead has either an existing range to select or a
    /// collision-free interval large enough for a new zoom.
    var canAddZoomAtPlayhead: Bool {
        ZoomInsertion.proposal(
            at: playhead,
            timelineDuration: timelineDuration,
            ranges: document.zoomRanges
        ) != .unavailable
    }

    var effectiveTrimOut: TimeInterval {
        min(document.trimOut ?? duration, timelineDuration)
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var activePlaybackRate: Float = 1
    private var saveTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// Monotonically increasing identity for the active export. Exporter
    /// callbacks are delivered from a detached worker and may arrive after
    /// the worker has finished, so the identity also acts as a callback fence.
    private var exportGeneration: UInt64 = 0
    private let saveCoordinator: ProjectSaveCoordinator

    static func load(
        opened: OpenedProject,
        library: ProjectLibrary,
        allowDegradedTelemetry: Bool = true
    ) async throws -> EditorSession {
        let mouseResult = Result { try ProjectJSON.decodeJSONL(
            CursorSample.self,
            from: ProjectLayout.mouseURL(in: opened.url)
        ) }
        let clicksResult = Result { try ProjectJSON.decodeJSONL(
            ClickSample.self,
            from: ProjectLayout.clicksURL(in: opened.url)
        ) }
        let keysResult = Result { try ProjectJSON.decodeJSONL(
            KeySample.self,
            from: ProjectLayout.keysURL(in: opened.url)
        ) }
        let targetGeometryResult = Result { try ProjectJSON.decodeJSONL(
            TargetGeometrySample.self,
            from: ProjectLayout.targetGeometryURL(in: opened.url)
        ) }
        var messages: [String] = []
        let mouse = (try? mouseResult.get()) ?? []
        let clicks = (try? clicksResult.get()) ?? []
        let keys = (try? keysResult.get()) ?? []
        let targetGeometry = (try? targetGeometryResult.get()) ?? []
        if case .failure(let error) = mouseResult {
            messages.append("Mouse telemetry: \(error.localizedDescription)")
        }
        if case .failure(let error) = clicksResult {
            messages.append("Click telemetry: \(error.localizedDescription)")
        }
        if case .failure(let error) = keysResult {
            messages.append("Keyboard telemetry: \(error.localizedDescription)")
        }
        if case .failure(let error) = targetGeometryResult {
            messages.append("Target geometry: \(error.localizedDescription)")
        }
        if !messages.isEmpty, !allowDegradedTelemetry {
            throw EditorTelemetryLoadIssue(
                mouse: mouse,
                clicks: clicks,
                keys: keys,
                messages: messages
            )
        }

        let videoURL = ProjectLayout.displayVideoURL(in: opened.url)
        let hasVideo = FileManager.default.fileExists(atPath: videoURL.path)
        let media = await mediaInfo(
            videoURL: videoURL,
            samples: mouse,
            clicks: clicks,
            keys: keys,
            fallbackWidth: max(Int((opened.meta.displayBounds.width * opened.meta.scale).rounded()), 1),
            fallbackHeight: max(Int((opened.meta.displayBounds.height * opened.meta.scale).rounded()), 1)
        )
        let webcamURL = ProjectLayout.webcamVideoURL(in: opened.url)
        let webcamMedia = await optionalVideoInfo(videoURL: webcamURL)
        let editorDocument = opened.document.normalizedForTimelineEditing(
            sourceDuration: media.duration
        )

        let engine = ZoomEngine(
            document: editorDocument,
            samples: mouse,
            clicks: clicks,
            displayBounds: opened.meta.displayBounds,
            targetGeometry: targetGeometry
        )

        let player: AVPlayer
        if hasVideo {
            player = AVPlayer(url: videoURL)
            player.actionAtItemEnd = .pause
        } else {
            player = AVPlayer()
        }
        let webcamPlayer: AVPlayer?
        if webcamMedia != nil {
            let player = AVPlayer(url: webcamURL)
            player.actionAtItemEnd = .pause
            webcamPlayer = player
        } else {
            webcamPlayer = nil
        }

        let session = EditorSession(
            projectURL: opened.url,
            library: library,
            meta: opened.meta,
            document: editorDocument,
            samples: mouse,
            clicks: clicks,
            keys: keys,
            targetGeometry: targetGeometry,
            engine: engine,
            duration: media.duration,
            hasVideo: hasVideo,
            sourceWidth: media.width,
            sourceHeight: media.height,
            player: player,
            webcamPlayer: webcamPlayer,
            webcamDuration: webcamMedia?.duration ?? 0,
            webcamWidth: webcamMedia?.width ?? 1,
            webcamHeight: webcamMedia?.height ?? 1
        )
        session.telemetryIssueMessages = messages
        session.persistentWarnings = messages
        if !messages.isEmpty {
            session.lastErrorCategory = .telemetry
        }
        if let health = opened.meta.captureHealth, health.state == .recovered {
            let recovery = health.warnings.map { "Capture recovery: \($0.rawValue)." }
            session.persistentWarnings.append(contentsOf: recovery)
            if session.lastErrorCategory == .none {
                session.lastErrorCategory = .capture
            }
        }
        session.loadCursorSprite()
        session.reloadLocalStylePresets()
        session.playhead = editorDocument.trimIn
        if hasVideo {
            session.attachPlayer()
            session.seek(to: editorDocument.trimIn)
        }
        return session
    }

    private init(
        projectURL: URL,
        library: ProjectLibrary,
        meta: ProjectMeta,
        document: ProjectDocument,
        samples: [CursorSample],
        clicks: [ClickSample],
        keys: [KeySample],
        targetGeometry: [TargetGeometrySample],
        engine: ZoomEngine,
        duration: TimeInterval,
        hasVideo: Bool,
        sourceWidth: Int,
        sourceHeight: Int,
        player: AVPlayer,
        webcamPlayer: AVPlayer?,
        webcamDuration: TimeInterval,
        webcamWidth: Int,
        webcamHeight: Int
    ) {
        self.projectURL = projectURL
        self.library = library
        self.meta = meta
        self.document = document
        self.samples = samples
        self.clicks = clicks
        self.keys = keys
        self.targetGeometry = targetGeometry
        self.engine = engine
        self.keyboardTimeline = KeyboardOverlayTimeline(samples: keys)
        self.duration = duration
        self.hasVideo = hasVideo
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.player = player
        self.webcamPlayer = webcamPlayer
        self.webcamDuration = webcamDuration
        self.webcamWidth = webcamWidth
        self.webcamHeight = webcamHeight
        self.savedDocument = document
        self.saveCoordinator = ProjectSaveCoordinator(library: library, projectURL: projectURL)
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        webcamPlayer?.currentItem?.audioTimePitchAlgorithm = .spectral
    }

    func shutdown() {
        exportTask?.cancel()
        saveTask?.cancel()
        engineTask?.cancel()
        detachPlayer()
        player.pause()
        webcamPlayer?.pause()
    }

    func applyAutoZoomsAndSave(preserveExisting: Bool = false) async throws {
        let config = SmartAutoZoomConfig(base: document.autoZoomSensitivity.config)
        if preserveExisting {
            document.zoomRanges = SmartAutoZoom.regenerateRanges(
                existing: document.zoomRanges,
                samples: samples,
                clicks: clicks,
                duration: max(duration, 0.01),
                displayBounds: meta.displayBounds,
                config: config,
                targetGeometry: targetGeometry,
                preserveLockedAndManual: true
            )
        } else {
            document.zoomRanges = SmartAutoZoom.generateRanges(
                samples: samples,
                clicks: clicks,
                duration: max(duration, 0.01),
                displayBounds: meta.displayBounds,
                config: config,
                targetGeometry: targetGeometry
            )
        }
        if document.trimOut == nil, duration > 0 {
            document.trimOut = duration
        }
        attachCursorSpriteIfMissing()
        rebuildEngine()
        markDirty()
        try await flushSave()
    }

    func regenerateAutoZooms() {
        Task { @MainActor in
            let before = document
            let previousSelection = selectedZoomID
            selectedZoomID = nil
            do {
                try await applyAutoZoomsAndSave(preserveExisting: true)
                documentHistory.record(
                    before: before,
                    after: document,
                    actionName: "Regenerate Auto-Zooms"
                )
            } catch {
                document = before
                selectedZoomID = previousSelection
                rebuildEngine()
                lastErrorCategory = .projectSave
                lastError = error.localizedDescription
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard hasVideo, outputDuration > 0 else { return }
        if outputPlayhead >= outputDuration - 0.02 {
            seek(to: document.trimIn)
        }
        isPlaying = true
        applyPlaybackRate(force: true)
        syncWebcam(to: previewSourceTime, playing: true)
    }

    func pause() {
        player.pause()
        webcamPlayer?.pause()
        isPlaying = false
        activePlaybackRate = 1
    }

    func seek(to time: TimeInterval) {
        let requestedSourceTime = min(max(time, 0), timelineDuration)
        let mapper = projectTimeMapper
        let outputTime = mapper.clampedOutputTime(forSourceTime: requestedSourceTime)
        let clamped = mapper.sourceTime(atOutputTime: outputTime)
        playhead = clamped
        guard hasVideo else { return }
        isSeeking = true
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
        syncWebcam(to: clamped, playing: isPlaying)
    }

    func addZoomAtPlayhead() {
        let proposal = ZoomInsertion.proposal(
            at: playhead,
            timelineDuration: timelineDuration,
            ranges: document.zoomRanges
        )
        switch proposal {
        case .select(let id):
            selectZoom(id)
            return
        case .unavailable:
            return
        case .create(let start, let end):
            let before = document
            let zoom = ZoomRange(
                start: start,
                end: end,
                amount: 1.8,
                anchor: engine.interpolateCursor(at: start) ?? Point2D(x: 0.5, y: 0.5)
            )
            document.zoomRanges.append(zoom)
            document.zoomRanges.sort { $0.start < $1.start }
            selectZoom(zoom.id)
            documentDidChange(
                from: before,
                actionName: "Add Zoom",
                rebuildZoomEngine: true
            )
        }
    }

    func deleteSelectedZoom() {
        guard let selectedZoomID else { return }
        let before = document
        document.zoomRanges.removeAll { $0.id == selectedZoomID }
        self.selectedZoomID = nil
        documentDidChange(
            from: before,
            actionName: "Delete Zoom",
            rebuildZoomEngine: true
        )
    }

    func addSpeedAtPlayhead() {
        if let existing = document.speedSegments.first(where: {
            playhead >= $0.start && playhead < $0.end
        }) {
            selectSpeed(existing.id)
            return
        }

        let nextStart = document.speedSegments
            .filter { $0.start > playhead }
            .map(\.start)
            .min() ?? timelineDuration
        let end = min(playhead + 3, nextStart, timelineDuration)
        guard end - playhead >= SpeedTimeline.minimumSegmentDuration else { return }

        let before = document
        let segment = SpeedSegment(start: playhead, end: end, rate: 2)
        document.speedSegments.append(segment)
        document.speedSegments = SpeedTimeline.normalizedSegments(
            document.speedSegments,
            sourceDuration: timelineDuration
        )
        selectSpeed(segment.id)
        documentDidChange(from: before, actionName: "Add Speed Region")
    }

    func deleteSelectedSpeedSegment() {
        guard let selectedSpeedID else { return }
        let before = document
        document.speedSegments.removeAll { $0.id == selectedSpeedID }
        self.selectedSpeedID = nil
        documentDidChange(from: before, actionName: "Delete Speed Region")
        applyPlaybackRate(force: true)
    }

    func updateSelectedSpeedRate(_ rate: Double) {
        guard let selectedSpeedID,
              let index = document.speedSegments.firstIndex(where: { $0.id == selectedSpeedID })
        else { return }
        let before = document
        document.speedSegments[index].rate = min(
            max(rate, SpeedSegment.rateRange.lowerBound),
            SpeedSegment.rateRange.upperBound
        )
        documentDidChange(from: before, actionName: "Change Playback Speed")
        applyPlaybackRate(force: true)
    }

    func replaceSpeedSegment(_ segment: SpeedSegment) {
        guard let index = document.speedSegments.firstIndex(where: { $0.id == segment.id }) else {
            return
        }
        let before = document
        let bounds = speedNeighborBounds(excluding: segment.id, referenceStart: document.speedSegments[index].start)
        var next = segment.normalized
        guard let range = TimelineRangeEditing.normalized(
            TimelineEditRange(start: next.start, end: next.end),
            lowerBound: max(0, bounds.lower),
            upperBound: min(timelineDuration, bounds.upper),
            minimumDuration: SpeedTimeline.minimumSegmentDuration
        ) else { return }
        next.start = range.start
        next.end = range.end
        document.speedSegments[index] = next
        document.speedSegments.sort { $0.start < $1.start }
        documentDidChange(from: before, actionName: "Adjust Speed Region")
        applyPlaybackRate(force: true)
    }

    func setMuteAudioWhenSpedUp(_ enabled: Bool) {
        let before = document
        document.muteAudioWhenSpedUp = enabled
        documentDidChange(from: before, actionName: "Change Speed Audio")
    }

    func updateAudioCleanup(
        actionName: String,
        _ body: (inout AudioCleanupSettings) -> Void
    ) {
        let before = document
        body(&document.audioCleanup)
        document.audioCleanup = document.audioCleanup.normalized
        documentDidChange(from: before, actionName: actionName)
    }

    func updateSelectedZoom(_ body: (inout ZoomRange) -> Void) {
        guard let selectedZoomID,
              let index = document.zoomRanges.firstIndex(where: { $0.id == selectedZoomID })
        else { return }
        let before = document
        // Mutate a local value before assigning it back. `clampZoom` reads
        // neighboring ranges from `document`; passing the array element as
        // `inout` while doing that violates Swift's runtime exclusivity rules.
        var next = document.zoomRanges[index]
        body(&next)
        clampZoom(&next)
        document.zoomRanges[index] = next
        documentDidChange(
            from: before,
            actionName: "Adjust Zoom",
            rebuildZoomEngine: true
        )
    }

    func replaceZoom(_ range: ZoomRange) {
        guard let index = document.zoomRanges.firstIndex(where: { $0.id == range.id }) else { return }
        let before = document
        var next = range
        clampZoom(&next)
        document.zoomRanges[index] = next
        documentDidChange(
            from: before,
            actionName: "Adjust Zoom",
            rebuildZoomEngine: true
        )
    }

    func setTrimIn(_ time: TimeInterval) {
        let before = document
        guard let range = TimelineRangeEditing.resizingStart(
            TimelineEditRange(start: document.trimIn, end: effectiveTrimOut),
            to: time,
            lowerBound: 0,
            upperBound: timelineDuration,
            minimumDuration: min(
                TimelineRangeEditing.minimumTrimDuration,
                timelineDuration
            )
        ) else { return }
        document.trimIn = range.start
        documentDidChange(from: before, actionName: "Adjust Trim")
    }

    func setTrimOut(_ time: TimeInterval) {
        let before = document
        guard let range = TimelineRangeEditing.resizingEnd(
            TimelineEditRange(start: document.trimIn, end: effectiveTrimOut),
            to: time,
            lowerBound: 0,
            upperBound: timelineDuration,
            minimumDuration: min(
                TimelineRangeEditing.minimumTrimDuration,
                timelineDuration
            )
        ) else { return }
        document.trimOut = range.end
        documentDidChange(from: before, actionName: "Adjust Trim")
    }

    func updateCanvas(
        actionName: String,
        _ body: (inout CanvasSettings) -> Void
    ) {
        let before = document
        body(&document.canvas)
        document.stylePresetID = CanvasPreset.matching(document.canvas)?.id
        clampWebcamOverlayToCanvas()
        documentDidChange(from: before, actionName: actionName)
    }

    func applyCanvasPreset(_ preset: CanvasPreset) {
        let before = document
        preset.apply(to: &document.canvas)
        document.stylePresetID = preset.id
        clampWebcamOverlayToCanvas()
        documentDidChange(from: before, actionName: "Apply \(preset.name) Style")
    }

    func updateKeyboardOverlay(
        actionName: String,
        _ body: (inout KeyboardOverlaySettings) -> Void
    ) {
        let before = document
        body(&document.keyboardOverlay)
        document.keyboardOverlay = document.keyboardOverlay.normalized
        documentDidChange(from: before, actionName: actionName)
    }

    func updateWebcamOverlay(
        actionName: String,
        _ body: (inout WebcamOverlaySettings) -> Void
    ) {
        let before = document
        body(&document.webcamOverlay)
        clampWebcamOverlayToCanvas()
        if !document.webcamOverlay.enabled {
            isWebcamSelected = false
        }
        documentDidChange(from: before, actionName: actionName)
    }

    func clampWebcamOverlayToCanvas() {
        let outputSize = ExportLayout.outputPixelSize(
            aspectWidth: document.canvas.aspectWidth,
            aspectHeight: document.canvas.aspectHeight,
            resolution: document.videoExportSettings.resolution,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        document.webcamOverlay = WebcamOverlayLayout.clampedSettings(
            document.webcamOverlay,
            canvasSize: CGSize(width: outputSize.width, height: outputSize.height),
            sourceAspect: webcamAspect
        )
    }

    func updateAutoZoomSensitivity(_ sensitivity: AutoZoomSensitivity) {
        let before = document
        document.autoZoomSensitivity = sensitivity
        documentDidChange(from: before, actionName: "Change Auto-Zoom Sensitivity")
    }

    func updateZoomEasing(_ easing: ZoomEasingPreset) {
        let before = document
        document.zoomEasing = easing
        documentDidChange(
            from: before,
            actionName: "Change Zoom Easing",
            rebuildZoomEngine: true
        )
    }

    func beginDocumentEdit(actionName: String) {
        documentHistory.begin(document: document, actionName: actionName)
    }

    func endDocumentEdit(rebuildZoomEngine: Bool = false) {
        documentHistory.commit(currentDocument: document)
        if rebuildZoomEngine {
            engineTask?.cancel()
            rebuildEngine()
        }
    }

    func undo() {
        guard let snapshot = documentHistory.undo(currentDocument: document) else { return }
        restoreHistorySnapshot(snapshot)
    }

    func redo() {
        guard let snapshot = documentHistory.redo(currentDocument: document) else { return }
        restoreHistorySnapshot(snapshot)
    }

    func documentDidChange(
        from before: ProjectDocument,
        actionName: String,
        rebuildZoomEngine: Bool = false
    ) {
        guard before != document else { return }
        isPreviewingSilenceSuggestions = false
        documentHistory.record(before: before, after: document, actionName: actionName)
        markDirty()
        if rebuildZoomEngine {
            scheduleEngineRebuild()
        }
        scheduleSave()
    }

    private func restoreHistorySnapshot(_ snapshot: ProjectDocument) {
        isPreviewingSilenceSuggestions = false
        let previousDocument = document
        let previousTimelineSelection = timelineSelection
        let restoredDocument = snapshot.normalizedForTimelineEditing(
            sourceDuration: timelineDuration
        )
        let selection = EditorDocumentSelection.reconciled(
            current: documentSelection,
            previousDocument: previousDocument,
            restoredDocument: restoredDocument
        )
        document = restoredDocument
        timelineSelection = previousTimelineSelection.reconciled(with: restoredDocument)
        if timelineSelection.isEmpty {
            applyDocumentSelection(selection)
        } else {
            applyPrimaryTimelineSelection()
        }
        let clampedPlayhead = min(max(playhead, document.trimIn), effectiveTrimOut)
        // Seeking through the mapper also moves a restored playhead out of a
        // newly excluded range, even when it is already inside the trim.
        seek(to: clampedPlayhead)
        markDirty()
        scheduleEngineRebuild()
        applyPlaybackRate(force: true)
        scheduleSave()
    }

    func presentExportPanel() {
        presentExportPanel(kind: .video)
    }

    func presentExportPanel(kind: EditorExportKind) {
        let panel = NSSavePanel()
        let isProRes = kind == .video && document.videoExportSettings.codec == .proRes422
        let contentType: UTType = isProRes ? .quickTimeMovie : kind.contentType
        let fileExtension = isProRes ? "mov" : kind.fileExtension
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title).\(fileExtension)"
        panel.title = kind.panelTitle
        panel.prompt = "Export"
        panel.message = isProRes
            ? "Renders the current trim, overlays, and canvas into a ProRes 422 QuickTime movie."
            : kind.message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard exportProgress == nil else { return }
        exportTask?.cancel()
        exportTask = Task { await export(to: url, kind: kind) }
    }

    func cancelExport() {
        guard exportProgress != nil else { return }
        isCancellingExport = true
        exportTask?.cancel()
    }

    func copyDiagnostics(
        lastErrorCategory categoryOverride: LocalDiagnosticsErrorCategory? = nil
    ) {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? OpenRecordInfo.appVersion
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let operatingSystem = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let snapshot = LocalDiagnosticsSnapshot(
            appVersion: appVersion,
            appBuild: appBuild,
            operatingSystem: operatingSystem,
            architecture: architecture,
            projectMeta: meta,
            document: document,
            trackPresence: [
                .displayVideo: hasVideo,
                .systemAudio: hasSystemAudio,
                .microphone: hasMicrophoneAudio,
                .webcam: hasWebcamVideo,
            ],
            trackDurations: [
                .displayVideo: duration,
                .webcam: webcamDuration,
            ],
            lastErrorCategory: categoryOverride ?? lastErrorCategory
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(snapshot.text, forType: .string) else {
            diagnosticsCopied = false
            lastErrorCategory = .unknown
            lastError = "Could not copy diagnostics to the clipboard."
            return
        }
        diagnosticsCopied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.diagnosticsCopied = false
        }
    }

    /// Flush the latest document revision and return only after its bytes are
    /// durably installed. Autosaves use the same operation, serialized on a
    /// detached task so JSON encoding/filesystem I/O do not block the main
    /// actor.
    func flushSave() async throws {
        saveTask?.cancel()
        let revision = editRevision
        let snapshot = document.upgradedForSave()
        try await saveCoordinator.save(document: snapshot)
        guard revision == editRevision else { return }
        document = snapshot
        markSaved()
        lastError = nil
    }

    /// Save a complete, independently-openable project bundle. Pending edits
    /// are flushed first so the copy never contains an older project.json.
    @discardableResult
    func saveCopy(to destinationURL: URL) async throws -> URL {
        let snapshot = document.upgradedForSave()
        let library = library
        let projectURL = projectURL
        return try await Task.detached(priority: .utility) {
            try library.saveCopy(of: projectURL, document: snapshot, to: destinationURL)
        }.value
    }

    /// Revert to the latest successfully persisted revision. The snapshot is
    /// written again behind any save already in flight so Discard wins races.
    func discardUnsavedChanges() async {
        guard hasUnsavedChanges else { return }
        saveTask?.cancel()
        let snapshot = savedDocument.upgradedForSave()
        document = snapshot
        editRevision &+= 1
        selectedZoomID = nil
        selectedSpeedID = nil
        selectedCaptionID = nil
        selectedAnnotationID = nil
        isWebcamSelected = false
        documentHistory.removeAll()
        rebuildEngine()
        // Serialize behind any save already in flight, then restore the last
        // known-good bytes so a stale autosave cannot win after Discard.
        try? await saveCoordinator.save(document: snapshot)
        savedDocument = snapshot
        savedRevision = editRevision
    }

    func export(to url: URL) async {
        await export(to: url, kind: .video)
    }

    func export(to url: URL, kind: EditorExportKind) async {
        exportGeneration &+= 1
        let generation = exportGeneration
        exportProgress = ExportProgress(
            phase: .preparing,
            fraction: 0,
            framesCompleted: 0,
            totalFrames: 0,
            elapsedSeconds: 0,
            framesPerSecond: nil,
            estimatedRemainingSeconds: nil
        )
        isCancellingExport = false
        lastError = nil
        let exporter = Exporter(projectBundleURL: projectURL)
        do {
            try Task.checkCancellation()
            switch kind {
            case .video:
                try await exporter.exportWithStatus(project: document, url: url, status: { [weak self] status in
                    Task { @MainActor in
                        guard let self,
                              self.exportGeneration == generation,
                              self.exportProgress != nil
                        else { return }
                        self.exportProgress = status
                    }
                })
            case .gif:
                try await exporter.exportGIF(project: document, url: url) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.exportGeneration == generation,
                              self.exportProgress != nil
                        else { return }
                        self.exportProgress = self.syntheticExportProgress(
                            fraction: progress,
                            phase: progress >= 0.999 ? .finalizing : .rendering
                        )
                    }
                }
            case .audio:
                try await exporter.exportAudio(project: document, url: url) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.exportGeneration == generation,
                              self.exportProgress != nil
                        else { return }
                        self.exportProgress = self.syntheticExportProgress(
                            fraction: progress,
                            phase: progress >= 0.999 ? .finalizing : .rendering
                        )
                    }
                }
            case .snapshot:
                try await exporter.exportSnapshot(
                    project: document,
                    atOutputTime: outputPlayhead,
                    url: url
                )
                exportProgress = syntheticExportProgress(fraction: 1, phase: .completed)
            }
            try Task.checkCancellation()
            if copyExportToLibrary {
                try library.copyExport(from: url, to: library.rootURL)
            }
            finishExport(generation: generation)
        } catch is CancellationError {
            finishExport(generation: generation)
        } catch {
            finishExport(generation: generation, error: error)
        }
    }

    private func syntheticExportProgress(
        fraction: Double,
        phase: ExportPhase
    ) -> ExportProgress {
        ExportProgress(
            phase: phase,
            fraction: min(max(fraction, 0), 1),
            framesCompleted: 0,
            totalFrames: 0,
            elapsedSeconds: 0,
            framesPerSecond: nil,
            estimatedRemainingSeconds: nil
        )
    }

    private func finishExport(generation: UInt64, error: Error? = nil) {
        guard exportGeneration == generation else { return }
        // Invalidate callbacks before clearing the visible state. A callback
        // already queued on MainActor must not resurrect a completed export.
        exportGeneration &+= 1
        exportProgress = nil
        isCancellingExport = false
        exportTask = nil
        if let error, !(error is CancellationError), !Task.isCancelled {
            lastErrorCategory = .export
            lastError = error.localizedDescription
        }
    }

    /// Inclusive gap this zoom may occupy without overlapping neighbors.
    func zoomNeighborBounds(
        excluding id: UUID,
        referenceStart: TimeInterval? = nil
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        let others = document.zoomRanges.filter { $0.id != id }
        let pivot = referenceStart
            ?? document.zoomRanges.first(where: { $0.id == id })?.start
            ?? 0
        let previous = others.filter { $0.start < pivot }.max { $0.start < $1.start }
        let next = others.filter { $0.start > pivot }.min { $0.start < $1.start }
        return (previous?.end ?? 0, next?.start ?? timelineDuration)
    }

    func speedNeighborBounds(
        excluding id: UUID,
        referenceStart: TimeInterval? = nil
    ) -> (lower: TimeInterval, upper: TimeInterval) {
        let others = document.speedSegments.filter { $0.id != id }
        let pivot = referenceStart
            ?? document.speedSegments.first(where: { $0.id == id })?.start
            ?? 0
        let previous = others.filter { $0.start < pivot }.max { $0.start < $1.start }
        let next = others.filter { $0.start > pivot }.min { $0.start < $1.start }
        return (previous?.end ?? 0, next?.start ?? timelineDuration)
    }

    private func attachPlayer() {
        detachPlayer()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.playerTimeDidChange(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                if let self {
                    self.seek(to: self.document.trimIn)
                }
            }
        }
    }

    private func detachPlayer() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func playerTimeDidChange(_ time: CMTime) {
        guard !isSeeking else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let rawSourceTime = min(max(seconds, 0), timelineDuration)
        let mapper = projectTimeMapper
        let canonicalSourceTime = mapper.sourceTime(
            atOutputTime: mapper.clampedOutputTime(forSourceTime: rawSourceTime)
        )
        // AVPlayer advances on the source PTS clock. Crossing an excluded
        // range therefore requires an explicit discontinuous seek so preview
        // follows the same ripple mapping as export.
        if canonicalSourceTime - rawSourceTime > 0.001 {
            seek(to: canonicalSourceTime)
            return
        }

        playhead = canonicalSourceTime
        applyPlaybackRate()
        syncWebcam(to: canonicalSourceTime, playing: isPlaying)
        if isPlaying, outputPlayhead >= outputDuration - 0.01 {
            pause()
            seek(to: document.trimIn)
        }
    }

    private func syncWebcam(to screenTime: TimeInterval, playing: Bool) {
        guard let webcamPlayer else { return }
        guard let localTime = webcamSourceTime(at: screenTime),
              localTime >= 0,
              localTime <= webcamDuration
        else {
            webcamPlayer.pause()
            if screenTime < webcamTimelineOffset {
                webcamPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }

        let current = webcamPlayer.currentTime().seconds
        if !current.isFinite || abs(current - localTime) > 0.15 || !playing {
            webcamPlayer.seek(
                to: CMTime(seconds: localTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        let desiredRate = activePlaybackRate * Float(
            meta.captureDiagnostics?.sourceRate(for: .webcam) ?? 1
        )
        if playing,
           webcamPlayer.timeControlStatus != .playing
                || abs(webcamPlayer.rate - desiredRate) > 0.001
        {
            webcamPlayer.playImmediately(atRate: desiredRate)
        } else if !playing {
            webcamPlayer.pause()
        }
    }

    private func webcamSourceTime(at screenTime: TimeInterval) -> TimeInterval? {
        WebcamTimeline.sourceTime(
            atTimelineTime: screenTime,
            sourceDuration: webcamDuration,
            legacyOffset: meta.captureTiming?.webcamOffset ?? 0,
            diagnostics: meta.captureDiagnostics
        )
    }

    private var webcamTimelineOffset: TimeInterval {
        meta.captureDiagnostics?.diagnostic(for: .webcam)?.initialOffset
            ?? meta.captureTiming?.webcamOffset
            ?? 0
    }

    private func applyPlaybackRate(force: Bool = false) {
        guard isPlaying else { return }
        let next = Float(currentPlaybackRate)
        guard force || abs(next - activePlaybackRate) > 0.001 else { return }
        activePlaybackRate = next
        player.playImmediately(atRate: next)
        if webcamIsVisible(at: previewSourceTime) {
            let webcamRate = next * Float(
                meta.captureDiagnostics?.sourceRate(for: .webcam) ?? 1
            )
            webcamPlayer?.playImmediately(atRate: webcamRate)
        }
    }

    private func rebuildEngine() {
        engine = ZoomEngine(
            document: document,
            samples: samples,
            clicks: clicks,
            displayBounds: meta.displayBounds,
            targetGeometry: targetGeometry
        )
    }

    private func scheduleEngineRebuild() {
        engineTask?.cancel()
        engineTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            rebuildEngine()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try await flushSave()
            } catch {
                lastErrorCategory = .projectSave
                lastError = error.localizedDescription
            }
        }
    }

    private func markDirty() {
        document = document.upgradedForSave()
        editRevision &+= 1
    }

    private func markSaved() {
        savedRevision = editRevision
        savedDocument = document
    }

    private func clampZoom(_ zoom: inout ZoomRange) {
        let minDuration = 0.12
        let (lower, upper) = zoomNeighborBounds(excluding: zoom.id)
        let lo = max(0, lower)
        let hi = min(timelineDuration, upper)

        zoom.amount = min(max(zoom.amount, 1), 5)
        zoom.anchor.x = min(max(zoom.anchor.x, 0), 1)
        zoom.anchor.y = min(max(zoom.anchor.y, 0), 1)

        let original = document.zoomRanges.first(where: { $0.id == zoom.id })
        let originalSpan = original.map { $0.end - $0.start }
        let preserveSpan = originalSpan.map { abs($0 - (zoom.end - zoom.start)) < 0.0005 } ?? false

        if preserveSpan, let span = originalSpan, span <= hi - lo, span >= minDuration {
            let start = min(max(zoom.start, lo), hi - span)
            zoom.start = start
            zoom.end = start + span
            return
        }

        zoom.start = min(max(zoom.start, lo), hi)
        zoom.end = min(max(zoom.end, zoom.start), hi)
        if zoom.end - zoom.start < minDuration, hi - lo >= minDuration {
            if zoom.start + minDuration <= hi {
                zoom.end = zoom.start + minDuration
            } else {
                zoom.end = hi
                zoom.start = hi - minDuration
            }
            zoom.start = min(max(zoom.start, lo), hi)
            zoom.end = min(max(zoom.end, zoom.start), hi)
        }
    }

    private func loadCursorSprite() {
        cursorSprite = document.cursorSprites.first
        let relative = cursorSprite?.pngRelativePath
            ?? "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(CaptureMediaFormat.defaultCursorSpriteID).png"
        guard let url = ProjectAssetResolver.cursorPNG(relativePath: relative, in: projectURL) else {
            cursorImage = nil
            if cursorSprite != nil {
                persistentWarnings.append("The cursor image path is outside the project bundle and was ignored.")
            }
            return
        }
        cursorImage = NSImage(contentsOf: url)
    }

    private func attachCursorSpriteIfMissing() {
        guard document.cursorSprites.isEmpty else { return }
        let relative = "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(CaptureMediaFormat.defaultCursorSpriteID).png"
        guard let url = ProjectAssetResolver.cursorPNG(relativePath: relative, in: projectURL) else { return }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url)
        else { return }
        document.cursorSprites = [
            CursorSprite(
                id: CaptureMediaFormat.defaultCursorSpriteID,
                hotspot: Point2D(x: 1, y: 1),
                pngRelativePath: relative,
                standardSize: Size2D(width: image.size.width, height: image.size.height)
            )
        ]
        loadCursorSprite()
    }

    private static func mediaInfo(
        videoURL: URL,
        samples: [CursorSample],
        clicks: [ClickSample],
        keys: [KeySample],
        fallbackWidth: Int,
        fallbackHeight: Int
    ) async -> (duration: TimeInterval, width: Int, height: Int) {
        var duration = max(
            samples.map(\.t).max() ?? 0,
            clicks.map(\.t).max() ?? 0,
            keys.map(\.t).max() ?? 0
        )
        var width = fallbackWidth
        var height = fallbackHeight
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            if let loadedDuration = try? await asset.load(.duration) {
                let seconds = loadedDuration.seconds
                if seconds.isFinite, seconds > 0 {
                    duration = seconds
                }
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               size.width.isFinite, size.height.isFinite,
               abs(size.width) >= 1, abs(size.height) >= 1
            {
                width = max(Int(abs(size.width).rounded()), 1)
                height = max(Int(abs(size.height).rounded()), 1)
            }
        }
        return (duration, width, height)
    }

    private static func optionalVideoInfo(
        videoURL: URL
    ) async -> (duration: TimeInterval, width: Int, height: Int)? {
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              size.width.isFinite,
              size.height.isFinite,
              abs(size.width) >= 1,
              abs(size.height) >= 1
        else { return nil }
        let trackDuration: TimeInterval
        if let timeRange = try? await track.load(.timeRange),
           timeRange.duration.isNumeric,
           timeRange.duration.seconds > 0
        {
            trackDuration = timeRange.duration.seconds
        } else {
            trackDuration = duration.seconds
        }
        return (
            trackDuration,
            max(Int(abs(size.width).rounded()), 1),
            max(Int(abs(size.height).rounded()), 1)
        )
    }
}
