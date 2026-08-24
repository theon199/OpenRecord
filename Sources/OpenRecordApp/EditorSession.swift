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
    var copyExportToLibrary = false
    var exportProgress: Double?
    var lastError: String?
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
    var webcamAspect: Double {
        Double(max(webcamWidth, 1)) / Double(max(webcamHeight, 1))
    }

    func webcamIsVisible(at time: TimeInterval) -> Bool {
        guard hasWebcamVideo else { return false }
        let localTime = time - (meta.captureTiming?.webcamOffset ?? 0)
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

    var selectedZoom: ZoomRange? {
        guard let selectedZoomID else { return nil }
        return document.zoomRanges.first { $0.id == selectedZoomID }
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
    private var saveTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
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

        let engine = ZoomEngine(
            document: opened.document,
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
            document: opened.document,
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
        if let health = opened.meta.captureHealth, health.state == .recovered {
            let recovery = health.warnings.map { "Capture recovery: \($0.rawValue)." }
            session.persistentWarnings.append(contentsOf: recovery)
        }
        session.loadCursorSprite()
        session.playhead = opened.document.trimIn
        if hasVideo {
            session.attachPlayer()
            session.seek(to: opened.document.trimIn)
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
    }

    func shutdown() {
        exportTask?.cancel()
        saveTask?.cancel()
        engineTask?.cancel()
        detachPlayer()
        player.pause()
        webcamPlayer?.pause()
    }

    func applyAutoZoomsAndSave() async throws {
        document.zoomRanges = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: max(duration, 0.01),
            displayBounds: meta.displayBounds,
            config: document.autoZoomSensitivity.config,
            targetGeometry: targetGeometry
        )
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
                try await applyAutoZoomsAndSave()
                documentHistory.record(
                    before: before,
                    after: document,
                    actionName: "Regenerate Auto-Zooms"
                )
            } catch {
                document = before
                selectedZoomID = previousSelection
                rebuildEngine()
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
        guard hasVideo else { return }
        if playhead >= effectiveTrimOut - 0.02 {
            seek(to: document.trimIn)
        }
        player.play()
        syncWebcam(to: playhead, playing: true)
        isPlaying = true
    }

    func pause() {
        player.pause()
        webcamPlayer?.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), timelineDuration)
        playhead = clamped
        guard hasVideo else { return }
        isSeeking = true
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
        syncWebcam(to: clamped, playing: false)
    }

    func addZoomAtPlayhead() {
        let proposal = ZoomInsertion.proposal(
            at: playhead,
            timelineDuration: timelineDuration,
            ranges: document.zoomRanges
        )
        switch proposal {
        case .select(let id):
            selectedZoomID = id
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
            selectedZoomID = zoom.id
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
        let maxIn = max(0, effectiveTrimOut - 0.1)
        document.trimIn = min(max(time, 0), maxIn)
        documentDidChange(from: before, actionName: "Adjust Trim")
    }

    func setTrimOut(_ time: TimeInterval) {
        let before = document
        let minOut = document.trimIn + 0.1
        document.trimOut = min(max(time, minOut), timelineDuration)
        documentDidChange(from: before, actionName: "Adjust Trim")
    }

    func updateCanvas(
        actionName: String,
        _ body: (inout CanvasSettings) -> Void
    ) {
        let before = document
        body(&document.canvas)
        document.stylePresetID = CanvasPreset.matching(document.canvas)?.id
        documentDidChange(from: before, actionName: actionName)
    }

    func applyCanvasPreset(_ preset: CanvasPreset) {
        let before = document
        preset.apply(to: &document.canvas)
        document.stylePresetID = preset.id
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
        document.webcamOverlay = document.webcamOverlay.normalized
        documentDidChange(from: before, actionName: actionName)
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

    private func documentDidChange(
        from before: ProjectDocument,
        actionName: String,
        rebuildZoomEngine: Bool = false
    ) {
        guard before != document else { return }
        documentHistory.record(before: before, after: document, actionName: actionName)
        markDirty()
        if rebuildZoomEngine {
            scheduleEngineRebuild()
        }
        scheduleSave()
    }

    private func restoreHistorySnapshot(_ snapshot: ProjectDocument) {
        let previousZoomIDs = Set(document.zoomRanges.map(\.id))
        document = snapshot
        if let selectedZoomID,
           !document.zoomRanges.contains(where: { $0.id == selectedZoomID })
        {
            self.selectedZoomID = nil
        }
        if selectedZoomID == nil {
            let restoredZoomIDs = Set(document.zoomRanges.map(\.id)).subtracting(previousZoomIDs)
            if restoredZoomIDs.count == 1 {
                selectedZoomID = restoredZoomIDs.first
            }
        }
        let clampedPlayhead = min(max(playhead, document.trimIn), effectiveTrimOut)
        if abs(clampedPlayhead - playhead) > 0.000_001 {
            seek(to: clampedPlayhead)
        }
        markDirty()
        scheduleEngineRebuild()
        scheduleSave()
    }

    func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title).mp4"
        panel.title = "Export Video"
        panel.prompt = "Export"
        panel.message = "Renders the current trim, zooms, and canvas into an MP4."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportTask?.cancel()
        exportTask = Task { await export(to: url) }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = nil
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
        documentHistory.removeAll()
        rebuildEngine()
        // Serialize behind any save already in flight, then restore the last
        // known-good bytes so a stale autosave cannot win after Discard.
        try? await saveCoordinator.save(document: snapshot)
        savedDocument = snapshot
        savedRevision = editRevision
    }

    func export(to url: URL) async {
        exportProgress = 0
        lastError = nil
        let exporter = Exporter(projectBundleURL: projectURL)
        do {
            try await exporter.export(project: document, url: url) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.exportProgress != nil else { return }
                    self.exportProgress = progress
                }
            }
            if Task.isCancelled { return }
            if copyExportToLibrary {
                try library.copyExport(from: url, to: library.rootURL)
            }
            exportProgress = nil
        } catch is CancellationError {
            exportProgress = nil
        } catch {
            exportProgress = nil
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
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
        playhead = min(max(seconds, 0), timelineDuration)
        syncWebcam(to: playhead, playing: isPlaying)
        if isPlaying, playhead >= effectiveTrimOut - 0.01 {
            pause()
            seek(to: document.trimIn)
        }
    }

    private func syncWebcam(to screenTime: TimeInterval, playing: Bool) {
        guard let webcamPlayer else { return }
        let localTime = screenTime - (meta.captureTiming?.webcamOffset ?? 0)
        guard localTime >= 0, localTime <= webcamDuration else {
            webcamPlayer.pause()
            if localTime < 0 {
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
        if playing, webcamPlayer.timeControlStatus != .playing {
            webcamPlayer.play()
        } else if !playing {
            webcamPlayer.pause()
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
