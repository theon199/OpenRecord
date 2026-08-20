import AppKit
import AVFoundation
import Foundation
import OpenRecord
import UniformTypeIdentifiers

@MainActor
@Observable
final class EditorSession {
    let projectURL: URL
    let library: ProjectLibrary

    var meta: ProjectMeta
    var document: ProjectDocument
    var samples: [CursorSample]
    var clicks: [ClickSample]
    var engine: ZoomEngine

    var duration: TimeInterval
    var playhead: TimeInterval = 0
    var isPlaying = false
    var selectedZoomID: UUID?
    var copyExportToLibrary = false
    var exportProgress: Double?
    var lastError: String?
    var hasVideo: Bool
    var cursorImage: NSImage?
    var cursorSprite: CursorSprite?

    let player: AVPlayer

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

    var effectiveTrimOut: TimeInterval {
        min(document.trimOut ?? duration, timelineDuration)
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var saveTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?

    static func load(opened: OpenedProject, library: ProjectLibrary) async -> EditorSession {
        let telemetry: (mouse: [CursorSample], clicks: [ClickSample])
        do {
            telemetry = try TelemetryLoader.load(from: opened.url)
        } catch {
            telemetry = ([], [])
        }

        let videoURL = ProjectLayout.displayVideoURL(in: opened.url)
        let hasVideo = FileManager.default.fileExists(atPath: videoURL.path)
        let duration = await mediaDuration(
            videoURL: videoURL,
            samples: telemetry.mouse,
            clicks: telemetry.clicks
        )

        let engine = ZoomEngine(
            document: opened.document,
            samples: telemetry.mouse,
            clicks: telemetry.clicks,
            displayBounds: opened.meta.displayBounds
        )

        let player: AVPlayer
        if hasVideo {
            player = AVPlayer(url: videoURL)
            player.actionAtItemEnd = .pause
        } else {
            player = AVPlayer()
        }

        let session = EditorSession(
            projectURL: opened.url,
            library: library,
            meta: opened.meta,
            document: opened.document,
            samples: telemetry.mouse,
            clicks: telemetry.clicks,
            engine: engine,
            duration: duration,
            hasVideo: hasVideo,
            player: player
        )
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
        engine: ZoomEngine,
        duration: TimeInterval,
        hasVideo: Bool,
        player: AVPlayer
    ) {
        self.projectURL = projectURL
        self.library = library
        self.meta = meta
        self.document = document
        self.samples = samples
        self.clicks = clicks
        self.engine = engine
        self.duration = duration
        self.hasVideo = hasVideo
        self.player = player
    }

    func shutdown() {
        saveTask?.cancel()
        engineTask?.cancel()
        saveNow()
        detachPlayer()
        player.pause()
    }

    func applyAutoZoomsAndSave() throws {
        document.zoomRanges = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: max(duration, 0.01),
            displayBounds: meta.displayBounds
        )
        if document.trimOut == nil, duration > 0 {
            document.trimOut = duration
        }
        attachCursorSpriteIfMissing()
        rebuildEngine()
        try library.save(document: document, to: projectURL)
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
        isPlaying = true
    }

    func pause() {
        player.pause()
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
    }

    func addZoomAtPlayhead() {
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 2, timelineDuration)
        let span = max(end - start, 0.25)
        let zoom = ZoomRange(
            start: start,
            end: start + span,
            amount: 1.8,
            anchor: engine.interpolateCursor(at: start) ?? Point2D(x: 0.5, y: 0.5)
        )
        document.zoomRanges.append(zoom)
        document.zoomRanges.sort { $0.start < $1.start }
        selectedZoomID = zoom.id
        zoomRangesDidChange()
    }

    func deleteSelectedZoom() {
        guard let selectedZoomID else { return }
        document.zoomRanges.removeAll { $0.id == selectedZoomID }
        self.selectedZoomID = nil
        zoomRangesDidChange()
    }

    func updateSelectedZoom(_ body: (inout ZoomRange) -> Void) {
        guard let selectedZoomID,
              let index = document.zoomRanges.firstIndex(where: { $0.id == selectedZoomID })
        else { return }
        body(&document.zoomRanges[index])
        clampZoom(&document.zoomRanges[index])
        zoomRangesDidChange()
    }

    func replaceZoom(_ range: ZoomRange) {
        guard let index = document.zoomRanges.firstIndex(where: { $0.id == range.id }) else { return }
        var next = range
        clampZoom(&next)
        document.zoomRanges[index] = next
        zoomRangesDidChange()
    }

    func setTrimIn(_ time: TimeInterval) {
        let maxIn = max(0, effectiveTrimOut - 0.1)
        document.trimIn = min(max(time, 0), maxIn)
        canvasDidChange()
    }

    func setTrimOut(_ time: TimeInterval) {
        let minOut = document.trimIn + 0.1
        document.trimOut = min(max(time, minOut), timelineDuration)
        canvasDidChange()
    }

    func canvasDidChange() {
        scheduleSave()
    }

    func zoomRangesDidChange() {
        scheduleEngineRebuild()
        scheduleSave()
    }

    func presentExportPanel() {
        saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title).mp4"
        panel.title = "Export Video"
        panel.prompt = "Export"
        panel.message = "Renders the current trim, zooms, and canvas into an MP4."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await export(to: url) }
    }

    func export(to url: URL) async {
        saveNow()
        exportProgress = 0
        lastError = nil
        let exporter = Exporter(projectBundleURL: projectURL)
        do {
            try await exporter.export(project: document, url: url) { [weak self] progress in
                Task { @MainActor in
                    self?.exportProgress = progress
                }
            }
            if copyExportToLibrary {
                try library.copyExport(from: url, to: library.rootURL)
            }
            exportProgress = nil
        } catch {
            exportProgress = nil
            lastError = error.localizedDescription
        }
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
        if isPlaying, playhead >= effectiveTrimOut - 0.01 {
            pause()
            seek(to: document.trimIn)
        }
    }

    private func rebuildEngine() {
        engine = ZoomEngine(
            document: document,
            samples: samples,
            clicks: clicks,
            displayBounds: meta.displayBounds
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
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        do {
            try library.save(document: document, to: projectURL)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clampZoom(_ zoom: inout ZoomRange) {
        zoom.start = min(max(zoom.start, 0), timelineDuration)
        zoom.end = min(max(zoom.end, zoom.start + 0.12), timelineDuration)
        zoom.amount = min(max(zoom.amount, 1), 5)
        zoom.anchor.x = min(max(zoom.anchor.x, 0), 1)
        zoom.anchor.y = min(max(zoom.anchor.y, 0), 1)
    }

    private func loadCursorSprite() {
        cursorSprite = document.cursorSprites.first
        let relative = cursorSprite?.pngRelativePath
            ?? "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(CaptureMediaFormat.defaultCursorSpriteID).png"
        let url = projectURL.appendingPathComponent(relative)
        cursorImage = NSImage(contentsOf: url)
    }

    private func attachCursorSpriteIfMissing() {
        guard document.cursorSprites.isEmpty else { return }
        let relative = "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(CaptureMediaFormat.defaultCursorSpriteID).png"
        let url = projectURL.appendingPathComponent(relative)
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

    private static func mediaDuration(
        videoURL: URL,
        samples: [CursorSample],
        clicks: [ClickSample]
    ) async -> TimeInterval {
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            if let duration = try? await asset.load(.duration) {
                let seconds = duration.seconds
                if seconds.isFinite, seconds > 0 {
                    return seconds
                }
            }
        }
        return max(samples.map(\.t).max() ?? 0, clicks.map(\.t).max() ?? 0)
    }
}
