import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the media writers and telemetry for one recording. All track times are
/// anchored to the first complete display frame.
final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let videoQueue = DispatchQueue(label: "app.openrecord.desktop.capture.video")
    private let audioQueue = DispatchQueue(label: "app.openrecord.desktop.capture.audio")
    private let stateLock = NSLock()
    private let cursor = CursorMonitor()
    private let mic = MicrophoneRecorder()
    private var stream: SCStream?
    private var videoWriter: SampleBufferWriter?
    private var systemAudioWriter: SampleBufferWriter?
    private var pendingAudio: [CMSampleBuffer] = []
    private var projectURL: URL?
    private var captureTarget: CaptureTarget?
    private var displayBounds = Rect2D.unit
    private var scale = 1.0
    private var createdAt = Date()
    private var cursorSprite: CursorSprite?
    private var streamError: Error?
    private var originHostTime: CFTimeInterval?
    private var systemAudioOffset: TimeInterval?
    private var originCMTime: CMTime?
    private var stopping = false
    private var unexpectedNotified = false
    private var healthWarnings = Set<CaptureWarningCode>()
    private var targetInitialBounds: Rect2D?
    var onUnexpectedStop: ((Error) -> Void)?

    func start(target: CaptureTarget, projectURL: URL) async throws {
        self.projectURL = projectURL; self.captureTarget = target; createdAt = Date()
        try prepareRecordingDirectory(in: projectURL)
        cursorSprite = try await MainActor.run { try CursorSpriteCapture.writeDefaultArrow(to: ProjectLayout.cursorsDirectory(in: projectURL)) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, bounds, scale, pixelWidth, pixelHeight) = try Self.makeFilter(target: target, content: content)
        displayBounds = bounds; self.scale = scale; targetInitialBounds = bounds
        if case .window = target, let windowBounds = Self.windowBounds(for: target, content: content) { targetInitialBounds = windowBounds }
        try writeProvisionalMeta()
        videoWriter = try SampleBufferWriter.video(url: ProjectLayout.displayVideoURL(in: projectURL), width: pixelWidth, height: pixelHeight, queue: videoQueue)
        systemAudioWriter = try SampleBufferWriter.systemAudio(url: ProjectLayout.systemAudioURL(in: projectURL), queue: audioQueue)
        let targetURL = ProjectLayout.targetGeometryURL(in: projectURL)
        try await MainActor.run {
            try cursor.start(mouseURL: ProjectLayout.mouseURL(in: projectURL), clicksURL: ProjectLayout.clicksURL(in: projectURL), target: target, initialBounds: targetInitialBounds, targetURL: targetURL)
            try mic.start(url: ProjectLayout.microphoneAudioURL(in: projectURL))
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true; configuration.showsCursor = false
        configuration.width = pixelWidth; configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CaptureMediaFormat.maxFrameRate)
        configuration.queueDepth = 8; configuration.pixelFormat = CaptureMediaFormat.videoPixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB; configuration.sampleRate = Int(CaptureMediaFormat.systemAudioSampleRate)
        configuration.channelCount = CaptureMediaFormat.systemAudioChannelCount; configuration.scalesToFit = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            await teardownAfterFailedStart(stream: stream)
            throw OpenRecordError.io("Could not start screen capture: \(error.localizedDescription)")
        }
    }

    func stop(reason: CaptureStopReason = .manual) async throws -> CaptureStopResult {
        stateLock.withLock { stopping = true }
        await MainActor.run { cursor.stop() }
        if let stream {
            try? stream.removeStreamOutput(self, type: .screen); try? stream.removeStreamOutput(self, type: .audio)
            do {
                try await stream.stopCapture()
            } catch {
                stateLock.withLock {
                    if streamError == nil { streamError = error }
                }
            }
            self.stream = nil
        }
        await MainActor.run { mic.stop() }
        var finalError: Error?
        let video = videoWriter
        let system = systemAudioWriter
        do { try await video?.finish() } catch { finalError = error; healthWarnings.insert(.truncatedVideo) }
        do { try await system?.finish() } catch { finalError = finalError ?? error; healthWarnings.insert(.truncatedSystemAudio) }
        if video?.appendError != nil || video?.droppedSamples == true { healthWarnings.insert(.truncatedVideo) }
        if system?.appendError != nil || system?.droppedSamples == true { healthWarnings.insert(.truncatedSystemAudio) }
        videoWriter = nil; systemAudioWriter = nil
        do { try cursor.closeFiles() } catch { finalError = finalError ?? error }
        healthWarnings.formUnion(cursor.closeWarnings)
        if mic.writeError != nil { healthWarnings.insert(.truncatedMicrophone); finalError = finalError ?? mic.writeError }
        if mic.firstBufferHostTime == nil { healthWarnings.insert(.missingMicrophone) }
        if system?.didAppend != true { healthWarnings.insert(.missingSystemAudio) }
        let capturedStreamError = stateLock.withLock { streamError }
        if let capturedStreamError {
            healthWarnings.insert(.screenStoppedUnexpectedly)
            finalError = finalError ?? OpenRecordError.io("Screen capture stopped: \(capturedStreamError.localizedDescription)")
        }
        let hasUsableVideo = await Self.hasUsableVideo(at: ProjectLayout.displayVideoURL(in: projectURL!))
        if !hasUsableVideo { healthWarnings.insert(.missingDisplayVideo) }
        let recovered = reason != .manual || !healthWarnings.isEmpty
        let health = CaptureHealth(state: recovered ? .recovered : .complete, warnings: healthWarnings.sorted { $0.rawValue < $1.rawValue })
        do { try writeSidecars(health: health) } catch { finalError = finalError ?? error }
        if let finalError, !hasUsableVideo { throw finalError }
        return CaptureStopResult(
            projectURL: projectURL!,
            reason: reason,
            health: health,
            hasUsableVideo: hasUsableVideo,
            finalizationError: finalError?.localizedDescription
        )
    }

    /// Kept for older internal callers; normal finalization uses `stop`.
    func writeSidecars() throws { try writeSidecars(health: .complete) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard Self.isCompleteVideoFrame(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            stateLock.lock()
            let first = originCMTime == nil
            if first { originCMTime = pts; originHostTime = CMTimeGetSeconds(pts) }
            let origin = originCMTime
            stateLock.unlock()
            if first, let origin {
                videoWriter?.startSession(at: origin)
                cursor.setRecordingStart(CMTimeGetSeconds(origin))
                audioQueue.async { [weak self] in self?.flushPendingAudio(origin: origin) }
            }
            videoWriter?.append(sampleBuffer)
        case .audio:
            stateLock.lock(); let origin = originCMTime
            if origin == nil, pendingAudio.count < 120 { pendingAudio.append(sampleBuffer) }
            stateLock.unlock()
            guard let origin else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= origin else { return }
            stateLock.lock()
            let candidate = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - origin)
            if systemAudioOffset == nil || candidate < systemAudioOffset! { systemAudioOffset = candidate }
            stateLock.unlock()
            systemAudioWriter?.startSession(at: origin); systemAudioWriter?.append(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let notify = !stopping && !unexpectedNotified
        if !stopping { streamError = error }
        if notify { unexpectedNotified = true }
        stateLock.unlock()
        if notify { onUnexpectedStop?(error) }
    }

    private func flushPendingAudio(origin: CMTime) {
        stateLock.lock(); let samples = pendingAudio; pendingAudio.removeAll(); stateLock.unlock()
        systemAudioWriter?.startSession(at: origin)
        for sample in samples where CMSampleBufferGetPresentationTimeStamp(sample) >= origin {
            stateLock.lock()
            let candidate = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample) - origin)
            if systemAudioOffset == nil || candidate < systemAudioOffset! { systemAudioOffset = candidate }
            stateLock.unlock()
            systemAudioWriter?.append(sample)
        }
    }

    private func teardownAfterFailedStart(stream: SCStream) async {
        try? stream.removeStreamOutput(self, type: .screen); try? stream.removeStreamOutput(self, type: .audio); try? await stream.stopCapture()
        await MainActor.run { cursor.stop(); mic.stop() }
        try? await videoWriter?.finish(); try? await systemAudioWriter?.finish(); try? cursor.closeFiles()
        videoWriter = nil; systemAudioWriter = nil; self.stream = nil
    }

    private func prepareRecordingDirectory(in projectURL: URL) throws {
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let recording = ProjectLayout.recordingDirectory(in: projectURL)
        if FileManager.default.fileExists(atPath: recording.path) { try FileManager.default.removeItem(at: recording) }
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ProjectLayout.cursorsDirectory(in: projectURL), withIntermediateDirectories: true)
    }

    private func writeSidecars(health: CaptureHealth) throws {
        guard let projectURL, let captureTarget else { throw OpenRecordError.io("Capture has no project URL.") }
        var existingCreatedAt = createdAt
        let url = ProjectLayout.metaURL(in: projectURL)
        if let data = try? Data(contentsOf: url), let existing = try? ProjectJSON.decoder.decode(ProjectMeta.self, from: data) { existingCreatedAt = existing.createdAt }
        let microphoneOffset: TimeInterval?
        if let originHostTime, let firstBufferHostTime = mic.firstBufferHostTime {
            microphoneOffset = firstBufferHostTime - originHostTime
        } else {
            microphoneOffset = nil
        }
        let timing = CaptureTiming(systemAudioOffset: systemAudioOffset, microphoneOffset: microphoneOffset)
        let meta = ProjectMeta(createdAt: existingCreatedAt, appVersion: OpenRecordInfo.appVersion, displayBounds: displayBounds, scale: scale, captureTarget: captureTarget, captureTiming: timing, captureHealth: health)
        try ProjectJSON.encoder.encode(meta).write(to: url, options: .atomic)
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        if !FileManager.default.fileExists(atPath: documentURL.path) {
            let document = ProjectDocument(cursorSprites: cursorSprite.map { [$0] } ?? [])
            try ProjectJSON.encoder.encode(document).write(to: documentURL, options: .atomic)
        }
    }

    /// Replace the library's 1x1 reservation metadata as soon as the capture
    /// filter resolves its real bounds. A successful stop overwrites this
    /// recovery-default health and adds final timing offsets.
    private func writeProvisionalMeta() throws {
        guard let projectURL, let captureTarget else {
            throw OpenRecordError.io("Capture has no project URL.")
        }
        let metaURL = ProjectLayout.metaURL(in: projectURL)
        let existing = try AtomicFileWrite.readJSON(ProjectMeta.self, from: metaURL)
        let meta = ProjectMeta(
            createdAt: existing.createdAt,
            appVersion: OpenRecordInfo.appVersion,
            displayBounds: displayBounds,
            scale: scale,
            captureTarget: captureTarget,
            captureHealth: CaptureHealth(
                state: .recovered,
                warnings: [.finalizationTimedOut]
            )
        )
        try AtomicFileWrite.writeJSON(meta, to: metaURL)
    }

    private static func hasUsableVideo(at url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration), duration.isNumeric
        else { return false }
        return duration.seconds > 0
    }

    private static func windowBounds(for target: CaptureTarget, content: SCShareableContent) -> Rect2D? {
        guard case .window(let id) = target, let window = content.windows.first(where: { UInt32($0.windowID) == id }) else { return nil }
        return Rect2D(window.frame)
    }

    private static func makeFilter(target: CaptureTarget, content: SCShareableContent) throws -> (SCContentFilter, Rect2D, Double, Int, Int) {
        let ownIDs = Set([OpenRecordInfo.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 })
        let excludedApps = content.applications.filter { ownIDs.contains($0.bundleIdentifier) }
        let filter: SCContentFilter
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw OpenRecordError.io("Display \(id) is not available for capture.") }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(id) }) else { throw OpenRecordError.io("Window \(id) is not available for capture.") }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let rect = filter.contentRect
        guard rect.width > 1, rect.height > 1 else { throw OpenRecordError.io("Capture target has an empty frame.") }
        let pixelScale = CGFloat(filter.pointPixelScale)
        return (filter, Rect2D(rect), Double(pixelScale), evenDimension(Int((rect.width * pixelScale).rounded())), evenDimension(Int((rect.height * pixelScale).rounded())))
    }

    private static func evenDimension(_ value: Int) -> Int { max(2, value - (value % 2)) }

    private static func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let info = attachments.first else { return true }
        if let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) { return status == .complete }
        return true
    }
}
