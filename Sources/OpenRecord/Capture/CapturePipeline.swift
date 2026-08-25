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
    private let webcam = WebcamRecorder()
    private let healthMonitor = CaptureHealthMonitor()
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
    private var componentError: Error?
    private var originHostTime: CFTimeInterval?
    private var systemAudioOffset: TimeInterval?
    private var originCMTime: CMTime?
    private var stopping = false
    private var captureStarted = false
    private var pendingUnexpectedError: Error?
    private var unexpectedNotified = false
    private var healthWarnings = Set<CaptureWarningCode>()
    private var targetInitialBounds: Rect2D?
    private var capturesWebcam = false
    private var webcamActive = false
    private var microphoneActive = false
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    func start(
        target: CaptureTarget,
        projectURL: URL,
        capturesKeyboardShortcuts: Bool = true,
        capturesWebcam: Bool = false
    ) async throws {
        self.projectURL = projectURL; self.captureTarget = target; createdAt = Date()
        self.capturesWebcam = capturesWebcam
        try prepareRecordingDirectory(in: projectURL)
        cursorSprite = try await MainActor.run { try CursorSpriteCapture.writeDefaultArrow(to: ProjectLayout.cursorsDirectory(in: projectURL)) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, bounds, scale, pixelWidth, pixelHeight) = try Self.makeFilter(target: target, content: content)
        displayBounds = bounds; self.scale = scale; targetInitialBounds = bounds
        if case .window = target, let windowBounds = Self.windowBounds(for: target, content: content) { targetInitialBounds = windowBounds }
        try writeProvisionalMeta()
        try healthMonitor.start(
            projectURL: projectURL,
            capturesWebcam: capturesWebcam
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .warning(let warning):
                self.recordWarning(warning)
            case .stop(let warning, let message):
                self.recordWarning(warning)
                self.requestUnexpectedStop(error: OpenRecordError.io(message))
            }
        }
        do {
            videoWriter = try SampleBufferWriter.video(url: ProjectLayout.displayVideoURL(in: projectURL), width: pixelWidth, height: pixelHeight, queue: videoQueue)
        } catch {
            _ = healthMonitor.stop()
            throw error
        }
        videoWriter?.onFailure = { [weak self] error in
            self?.recordWarning(.truncatedVideo)
            self?.requestUnexpectedStop(error: error)
        }
        do {
            systemAudioWriter = try SampleBufferWriter.systemAudio(
                url: ProjectLayout.systemAudioURL(in: projectURL),
                queue: audioQueue
            )
            systemAudioWriter?.onFailure = { [weak self] error in
                self?.recordOptionalFailure(error, warning: .truncatedSystemAudio)
            }
        } catch {
            systemAudioWriter = nil
            recordOptionalFailure(error, warning: .missingSystemAudio)
        }
        let targetURL = ProjectLayout.targetGeometryURL(in: projectURL)
        let keysURL = capturesKeyboardShortcuts ? ProjectLayout.keysURL(in: projectURL) : nil
        cursor.onTargetUnavailable = { [weak self] in
            guard let self else { return }
            self.recordWarning(.captureTargetUnavailable)
            self.requestUnexpectedStop(
                error: OpenRecordError.io(
                    "The captured window closed or became unavailable. OpenRecord is finalizing the display recording."
                )
            )
        }
        mic.onFailure = { [weak self] error in
            self?.recordOptionalFailure(error, warning: .microphoneInterrupted)
        }
        webcam.onFailure = { [weak self] error in
            self?.recordOptionalFailure(error, warning: .cameraInterrupted)
        }
        do {
            try await MainActor.run {
                try cursor.start(mouseURL: ProjectLayout.mouseURL(in: projectURL), clicksURL: ProjectLayout.clicksURL(in: projectURL), target: target, initialBounds: targetInitialBounds, targetURL: targetURL, keysURL: keysURL)
            }
        } catch {
            recordWarning(.truncatedMouseTelemetry)
            recordWarning(.truncatedClickTelemetry)
            recordWarning(.truncatedTargetGeometry)
            if capturesKeyboardShortcuts { recordWarning(.truncatedKeyboardTelemetry) }
            recordComponentError(error)
        }
        do {
            try await MainActor.run {
                try mic.start(url: ProjectLayout.microphoneAudioURL(in: projectURL))
            }
            microphoneActive = true
        } catch {
            recordOptionalFailure(error, warning: .missingMicrophone)
        }
        if capturesWebcam {
            do {
                try await webcam.start(url: ProjectLayout.webcamVideoURL(in: projectURL))
                webcamActive = true
            } catch {
                recordOptionalFailure(error, warning: .missingWebcam)
            }
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = systemAudioWriter != nil; configuration.excludesCurrentProcessAudio = true; configuration.showsCursor = false
        configuration.width = pixelWidth; configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CaptureMediaFormat.maxFrameRate)
        configuration.queueDepth = 8; configuration.pixelFormat = CaptureMediaFormat.videoPixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB; configuration.sampleRate = Int(CaptureMediaFormat.systemAudioSampleRate)
        configuration.channelCount = CaptureMediaFormat.systemAudioChannelCount; configuration.scalesToFit = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if systemAudioWriter != nil {
                do {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                } catch {
                    try? await systemAudioWriter?.finish()
                    systemAudioWriter = nil
                    recordOptionalFailure(error, warning: .missingSystemAudio)
                }
            }
            self.stream = stream
            try await stream.startCapture()
            notifyPendingUnexpectedStopAfterStart()
        } catch {
            await teardownAfterFailedStart(stream: stream)
            throw OpenRecordError.io("Could not start screen capture: \(error.localizedDescription)")
        }
    }

    func stop(reason: CaptureStopReason = .manual) async throws -> CaptureStopResult {
        stateLock.withLock { stopping = true }
        let minimumAvailableDiskBytes = healthMonitor.stop()
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
        if microphoneActive {
            await MainActor.run { mic.stop() }
        }
        var finalError = stateLock.withLock { componentError }
        var displayFinalizationError: Error?
        if webcamActive {
            do {
                try await webcam.stop()
            } catch {
                finalError = finalError ?? error
                recordWarning(.truncatedWebcam)
            }
            if webcam.appendError != nil || webcam.droppedSamples {
                recordWarning(.truncatedWebcam)
                finalError = finalError ?? webcam.appendError
            }
            if !webcam.didAppend {
                recordWarning(.missingWebcam)
            }
        } else if capturesWebcam {
            recordWarning(.missingWebcam)
        }
        let video = videoWriter
        let system = systemAudioWriter
        do {
            try await video?.finish()
        } catch {
            displayFinalizationError = error
            finalError = error
            recordWarning(.truncatedVideo)
        }
        do { try await system?.finish() } catch { finalError = finalError ?? error; recordWarning(.truncatedSystemAudio) }
        if video?.appendError != nil || video?.droppedSamples == true { recordWarning(.truncatedVideo) }
        if system?.appendError != nil || system?.droppedSamples == true { recordWarning(.truncatedSystemAudio) }
        videoWriter = nil; systemAudioWriter = nil
        do { try cursor.closeFiles() } catch { finalError = finalError ?? error }
        for warning in cursor.closeWarnings { recordWarning(warning) }
        if mic.writeError != nil { recordWarning(.truncatedMicrophone); finalError = finalError ?? mic.writeError }
        if mic.firstBufferHostTime == nil { recordWarning(.missingMicrophone) }
        if system?.didAppend != true { recordWarning(.missingSystemAudio) }
        let capturedStreamError = stateLock.withLock { streamError }
        if let capturedStreamError {
            recordWarning(.screenStoppedUnexpectedly)
            recordWarning(.displayInterrupted)
            finalError = finalError ?? OpenRecordError.io("Screen capture stopped: \(capturedStreamError.localizedDescription)")
            displayFinalizationError = displayFinalizationError ?? capturedStreamError
        }
        let hasUsableVideo = await Self.hasUsableVideo(at: ProjectLayout.displayVideoURL(in: projectURL!))
        if !hasUsableVideo { recordWarning(.missingDisplayVideo) }
        let diagnostics = await makeDiagnostics(
            minimumAvailableDiskBytes: minimumAvailableDiskBytes
        )
        recordDriftWarnings(from: diagnostics)
        let health = CaptureRecovery.health(
            reason: reason,
            warnings: currentWarnings()
        )
        do { try writeSidecars(health: health, diagnostics: diagnostics) } catch { finalError = finalError ?? error }
        if !hasUsableVideo {
            throw displayFinalizationError
                ?? video?.appendError
                ?? OpenRecordError.io(
                    "The display recording could not be finalized into a playable video."
                )
        }
        return CaptureStopResult(
            projectURL: projectURL!,
            reason: reason,
            health: health,
            hasUsableVideo: hasUsableVideo,
            finalizationError: finalError?.localizedDescription
        )
    }

    /// Kept for older internal callers; normal finalization uses `stop`.
    func writeSidecars() throws { try writeSidecars(health: .complete, diagnostics: nil) }

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
                if webcamActive {
                    webcam.setRecordingStart(origin)
                }
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
        stateLock.withLock {
            if !stopping { streamError = error }
        }
        requestUnexpectedStop(error: error)
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
        _ = healthMonitor.stop()
        await teardownCaptureComponents()
        try? cursor.closeFiles()
        videoWriter = nil; systemAudioWriter = nil; self.stream = nil
    }

    private func teardownCaptureComponents() async {
        await MainActor.run {
            cursor.stop()
            if microphoneActive { mic.stop() }
        }
        if webcamActive {
            try? await webcam.stop()
        }
        try? await videoWriter?.finish()
        try? await systemAudioWriter?.finish()
    }

    private func prepareRecordingDirectory(in projectURL: URL) throws {
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let recording = ProjectLayout.recordingDirectory(in: projectURL)
        if FileManager.default.fileExists(atPath: recording.path) { try FileManager.default.removeItem(at: recording) }
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ProjectLayout.cursorsDirectory(in: projectURL), withIntermediateDirectories: true)
    }

    private func writeSidecars(
        health: CaptureHealth,
        diagnostics: CaptureDiagnostics?
    ) throws {
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
        let timing = CaptureTiming(
            systemAudioOffset: systemAudioOffset,
            microphoneOffset: microphoneOffset,
            webcamOffset: capturesWebcam ? webcam.firstFrameOffset : nil
        )
        let meta = ProjectMeta(
            createdAt: existingCreatedAt,
            appVersion: OpenRecordInfo.appVersion,
            displayBounds: displayBounds,
            scale: scale,
            captureTarget: captureTarget,
            captureTiming: timing,
            captureHealth: health,
            captureDiagnostics: diagnostics,
            webcam: capturesWebcam ? webcam.captureInfo : nil
        )
        try AtomicFileWrite.writeJSON(meta, to: url)
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        if !FileManager.default.fileExists(atPath: documentURL.path) {
            let document = ProjectDocument(cursorSprites: cursorSprite.map { [$0] } ?? [])
            try AtomicFileWrite.writeProjectDocument(document, to: documentURL)
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

    private func makeDiagnostics(
        minimumAvailableDiskBytes: Int64?
    ) async -> CaptureDiagnostics {
        guard let projectURL else {
            return CaptureDiagnosticsAnalyzer.analyze(
                referenceDuration: 0,
                observations: [],
                minimumAvailableDiskBytes: minimumAvailableDiskBytes
            )
        }
        let displayDuration = await CaptureMediaProbe.duration(
            at: ProjectLayout.displayVideoURL(in: projectURL),
            track: .displayVideo
        )
        let systemDuration = await CaptureMediaProbe.duration(
            at: ProjectLayout.systemAudioURL(in: projectURL),
            track: .systemAudio
        )
        let microphoneDuration = await CaptureMediaProbe.duration(
            at: ProjectLayout.microphoneAudioURL(in: projectURL),
            track: .microphone
        )
        let webcamDuration = await CaptureMediaProbe.duration(
            at: ProjectLayout.webcamVideoURL(in: projectURL),
            track: .webcam
        )
        let microphoneOffset: TimeInterval?
        if let originHostTime, let firstBufferHostTime = mic.firstBufferHostTime {
            microphoneOffset = firstBufferHostTime - originHostTime
        } else {
            microphoneOffset = nil
        }
        let warnings = currentWarnings()
        let observations = [
            CaptureTrackObservation(
                track: .displayVideo,
                duration: displayDuration,
                initialOffset: 0,
                truncated: warnings.contains(.truncatedVideo)
            ),
            CaptureTrackObservation(
                track: .systemAudio,
                duration: systemDuration,
                initialOffset: systemAudioOffset,
                truncated: warnings.contains(.truncatedSystemAudio)
            ),
            CaptureTrackObservation(
                track: .microphone,
                duration: microphoneDuration,
                initialOffset: microphoneOffset,
                truncated: warnings.contains(.truncatedMicrophone)
                    || warnings.contains(.microphoneInterrupted)
            ),
            CaptureTrackObservation(
                track: .webcam,
                requested: capturesWebcam,
                duration: webcamDuration,
                initialOffset: webcam.firstFrameOffset,
                truncated: warnings.contains(.truncatedWebcam)
                    || warnings.contains(.cameraInterrupted)
            ),
        ]
        return CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: displayDuration ?? 0,
            observations: observations,
            minimumAvailableDiskBytes: minimumAvailableDiskBytes
        )
    }

    private func recordDriftWarnings(from diagnostics: CaptureDiagnostics) {
        if diagnostics.correction(for: .systemAudio) != nil {
            recordWarning(.systemAudioDriftCorrected)
        }
        if diagnostics.correction(for: .microphone) != nil {
            recordWarning(.microphoneDriftCorrected)
        }
        if diagnostics.correction(for: .webcam) != nil {
            recordWarning(.webcamDriftCorrected)
        }
    }

    private func recordWarning(_ warning: CaptureWarningCode) {
        _ = stateLock.withLock { healthWarnings.insert(warning) }
    }

    private func currentWarnings() -> Set<CaptureWarningCode> {
        stateLock.withLock { healthWarnings }
    }

    private func recordComponentError(_ error: Error) {
        stateLock.withLock {
            if componentError == nil { componentError = error }
        }
    }

    private func recordOptionalFailure(
        _ error: Error,
        warning: CaptureWarningCode
    ) {
        recordWarning(warning)
        recordComponentError(error)
    }

    private func requestUnexpectedStop(error: Error) {
        let callback = stateLock.withLock { () -> (@Sendable (Error) -> Void)? in
            guard !stopping, !unexpectedNotified else { return nil }
            guard captureStarted else {
                if pendingUnexpectedError == nil { pendingUnexpectedError = error }
                return nil
            }
            unexpectedNotified = true
            if componentError == nil { componentError = error }
            return onUnexpectedStop
        }
        callback?(error)
    }

    private func notifyPendingUnexpectedStopAfterStart() {
        let pending = stateLock.withLock { () -> Error? in
            captureStarted = true
            guard !stopping,
                  !unexpectedNotified,
                  let error = pendingUnexpectedError
            else {
                return nil
            }
            pendingUnexpectedError = nil
            unexpectedNotified = true
            if componentError == nil { componentError = error }
            return error
        }
        if let pending { onUnexpectedStop?(pending) }
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
