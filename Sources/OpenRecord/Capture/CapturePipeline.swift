import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class CapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let videoQueue = DispatchQueue(label: "app.openrecord.desktop.capture.video")
    private let audioQueue = DispatchQueue(label: "app.openrecord.desktop.capture.audio")

    private let cursor = CursorMonitor()
    private let mic = MicrophoneRecorder()
    private var stream: SCStream?
    private var videoWriter: SampleBufferWriter?
    private var systemAudioWriter: SampleBufferWriter?

    private var projectURL: URL?
    private var captureTarget: CaptureTarget?
    private var displayBounds = Rect2D.unit
    private var scale = 1.0
    private var createdAt = Date()
    private var cursorSprite: CursorSprite?
    private var streamError: Error?

    func start(target: CaptureTarget, projectURL: URL) async throws {
        self.projectURL = projectURL
        self.captureTarget = target
        createdAt = Date()

        try prepareRecordingDirectory(in: projectURL)

        cursorSprite = try await MainActor.run {
            try CursorSpriteCapture.writeDefaultArrow(
                to: ProjectLayout.cursorsDirectory(in: projectURL)
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, bounds, scale, pixelWidth, pixelHeight) = try Self.makeFilter(target: target, content: content)
        displayBounds = bounds
        self.scale = scale

        videoWriter = try SampleBufferWriter.video(
            url: ProjectLayout.displayVideoURL(in: projectURL),
            width: pixelWidth,
            height: pixelHeight,
            queue: videoQueue
        )
        systemAudioWriter = try SampleBufferWriter.systemAudio(
            url: ProjectLayout.systemAudioURL(in: projectURL),
            queue: audioQueue
        )

        try await MainActor.run {
            try self.cursor.start(
                mouseURL: ProjectLayout.mouseURL(in: projectURL),
                clicksURL: ProjectLayout.clicksURL(in: projectURL)
            )
            try self.mic.start(url: ProjectLayout.microphoneAudioURL(in: projectURL))
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.showsCursor = false
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CaptureMediaFormat.maxFrameRate)
        configuration.queueDepth = 8
        configuration.pixelFormat = CaptureMediaFormat.videoPixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.sampleRate = Int(CaptureMediaFormat.systemAudioSampleRate)
        configuration.channelCount = CaptureMediaFormat.systemAudioChannelCount
        configuration.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
        } catch {
            await teardownAfterFailedStart(stream: stream)
            throw OpenRecordError.io("Could not start screen capture: \(error.localizedDescription)")
        }

        self.stream = stream
        cursor.setRecordingStart(CACurrentMediaTime())
    }

    func stop() async throws {
        await MainActor.run {
            self.cursor.stop()
        }

        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            do {
                try await stream.stopCapture()
            } catch {
                // Already stopped (display sleep, user revoked permission, etc.).
                if streamError == nil {
                    streamError = error
                }
            }
            self.stream = nil
        }

        await MainActor.run {
            self.mic.stop()
        }

        var mediaError: Error?
        do {
            try await videoWriter?.finish()
        } catch {
            mediaError = error
        }
        do {
            try await systemAudioWriter?.finish()
        } catch {
            mediaError = mediaError ?? error
        }
        videoWriter = nil
        systemAudioWriter = nil

        do {
            try cursor.closeFiles()
        } catch {
            mediaError = mediaError ?? error
        }

        if let streamError {
            throw OpenRecordError.io("Screen capture stopped: \(streamError.localizedDescription)")
        }
        if let mediaError {
            throw mediaError
        }
    }

    func writeSidecars() throws {
        guard let projectURL, let captureTarget else {
            throw OpenRecordError.io("Capture has no project URL.")
        }

        try writeMeta(projectURL: projectURL, target: captureTarget)

        let documentURL = ProjectLayout.documentURL(in: projectURL)
        if !FileManager.default.fileExists(atPath: documentURL.path) {
            let document = ProjectDocument(cursorSprites: cursorSprite.map { [$0] } ?? [])
            let data = try ProjectJSON.encoder.encode(document)
            try data.write(to: documentURL, options: .atomic)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard Self.isCompleteVideoFrame(sampleBuffer) else { return }
            videoWriter?.append(sampleBuffer)
        case .audio:
            systemAudioWriter?.append(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }

    private func teardownAfterFailedStart(stream: SCStream) async {
        try? stream.removeStreamOutput(self, type: .screen)
        try? stream.removeStreamOutput(self, type: .audio)
        try? await stream.stopCapture()
        await MainActor.run {
            self.cursor.stop()
            self.mic.stop()
        }
        try? await videoWriter?.finish()
        try? await systemAudioWriter?.finish()
        try? cursor.closeFiles()
        videoWriter = nil
        systemAudioWriter = nil
        self.stream = nil
    }

    private func prepareRecordingDirectory(in projectURL: URL) throws {
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let recording = ProjectLayout.recordingDirectory(in: projectURL)
        if FileManager.default.fileExists(atPath: recording.path) {
            try FileManager.default.removeItem(at: recording)
        }
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: ProjectLayout.cursorsDirectory(in: projectURL),
            withIntermediateDirectories: true
        )
    }

    private func writeMeta(projectURL: URL, target: CaptureTarget) throws {
        let url = ProjectLayout.metaURL(in: projectURL)
        var createdAt = self.createdAt
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? ProjectJSON.decoder.decode(ProjectMeta.self, from: data) {
            createdAt = existing.createdAt
        }
        let meta = ProjectMeta(
            createdAt: createdAt,
            appVersion: OpenRecordInfo.appVersion,
            displayBounds: displayBounds,
            scale: scale,
            captureTarget: target
        )
        try ProjectJSON.encoder.encode(meta).write(to: url, options: .atomic)
    }

    private static func makeFilter(
        target: CaptureTarget,
        content: SCShareableContent
    ) throws -> (SCContentFilter, Rect2D, Double, Int, Int) {
        let ownIDs = Set(
            [OpenRecordInfo.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 }
        )
        let excludedApps = content.applications.filter { ownIDs.contains($0.bundleIdentifier) }

        let filter: SCContentFilter
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw OpenRecordError.io("Display \(id) is not available for capture.")
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(id) }) else {
                throw OpenRecordError.io("Window \(id) is not available for capture.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let rect = filter.contentRect
        guard rect.width > 1, rect.height > 1 else {
            throw OpenRecordError.io("Capture target has an empty frame.")
        }
        let pixelScale = CGFloat(filter.pointPixelScale)
        let scale = Double(pixelScale)
        let width = evenDimension(Int((rect.width * pixelScale).rounded()))
        let height = evenDimension(Int((rect.height * pixelScale).rounded()))
        return (filter, Rect2D(rect), scale, width, height)
    }

    private static func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    private static func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else {
            return false
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first
        else {
            return true
        }
        if let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) {
            return status == .complete
        }
        return true
    }
}
