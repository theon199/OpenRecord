import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Alternate export formats

public extension Exporter {
    /// Writes an animated GIF using the same canvas/compositor as MP4 export.
    /// GIF export is intentionally capped at 30 seconds to keep memory and
    /// encoder costs predictable.
    func exportGIF(
        project: ProjectDocument,
        url: URL,
        progress: ExportProgressHandler?
    ) async throws {
        let bundleURL = projectBundleURL
        let task = Task.detached(priority: .userInitiated) {
            try await ExportAlternateSession.gif(bundleURL: bundleURL, project: project, outputURL: url, progress: progress)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Writes the trimmed and speed-mapped microphone/system mix as an M4A.
    func exportAudio(
        project: ProjectDocument,
        url: URL,
        progress: ExportProgressHandler?
    ) async throws {
        let bundleURL = projectBundleURL
        let task = Task.detached(priority: .userInitiated) {
            try await ExportAlternateSession.audio(bundleURL: bundleURL, project: project, outputURL: url, progress: progress)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Writes a PNG still rendered at a source timeline position.
    func exportSnapshot(project: ProjectDocument, at time: TimeInterval, url: URL) async throws {
        let bundleURL = projectBundleURL
        let task = Task.detached(priority: .userInitiated) {
            try await ExportAlternateSession.snapshot(bundleURL: bundleURL, project: project, sourceTime: time, outputURL: url)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private enum ExportAlternateSession {
    static func gif(bundleURL: URL, project: ProjectDocument, outputURL: URL, progress: ExportProgressHandler?) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer { if accessed { bundleURL.stopAccessingSecurityScopedResource() } }
        let frames = try await ExportFrameSession(bundleURL: bundleURL, project: project)
        let duration = min(30, frames.outputDuration)
        let frameRate = min(30, max(1, Int(frames.fps)))
        let count = max(1, Int((duration * Double(frameRate)).rounded(.up)))
        let tempURL = try temporaryURL(for: outputURL, ext: "gif")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw OpenRecordError.io("Could not create the GIF export file.")
        }
        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ] as [CFString: Any]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        report(progress, 0)
        for index in 0..<count {
            try Task.checkCancellation()
            let outputTime = min(duration, Double(index) / Double(frameRate))
            let sourceTime = frames.speedTimeline.sourceTime(atOutputTime: outputTime, sourceStart: frames.trimStart, sourceEnd: frames.trimEnd)
            guard let image = try frames.image(at: sourceTime) else { throw OpenRecordError.io("Could not render a GIF frame.") }
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(frameRate)] as [CFString: Any]
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            if index == count - 1 || index % 2 == 0 { report(progress, Double(index + 1) / Double(count)) }
        }
        guard CGImageDestinationFinalize(destination) else { throw OpenRecordError.io("Could not finalize the GIF export file.") }
        try install(tempURL, at: outputURL)
        report(progress, 1)
    }

    static func snapshot(bundleURL: URL, project: ProjectDocument, sourceTime: TimeInterval, outputURL: URL) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer { if accessed { bundleURL.stopAccessingSecurityScopedResource() } }
        let frames = try await ExportFrameSession(bundleURL: bundleURL, project: project)
        let clamped = min(max(sourceTime, frames.trimStart), frames.trimEnd)
        guard let image = try frames.image(at: clamped) else { throw OpenRecordError.io("Could not render the snapshot.") }
        let tempURL = try temporaryURL(for: outputURL, ext: "png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OpenRecordError.io("Could not create the snapshot file.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OpenRecordError.io("Could not finalize the snapshot file.") }
        try install(tempURL, at: outputURL)
    }

    static func audio(bundleURL: URL, project: ProjectDocument, outputURL: URL, progress: ExportProgressHandler?) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer { if accessed { bundleURL.stopAccessingSecurityScopedResource() } }
        let displayURL = try ExportMediaIO.requireDisplayVideo(in: bundleURL)
        let display = AVURLAsset(url: displayURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await display.load(.duration)
        let trim = try ExportLayout.clampedTrim(trimIn: project.trimIn, trimOut: project.trimOut, duration: duration.seconds)
        let meta = try AtomicFileWrite.readJSON(ProjectMeta.self, from: ProjectLayout.metaURL(in: bundleURL))
        let speed = SpeedTimeline(segments: project.speedSegments)
        let rawMic = await ExportMediaIO.usableAudioURL(
            ProjectLayout.microphoneAudioURL(in: bundleURL)
        )
        var cleanedMicrophoneURL: URL?
        defer {
            if let cleanedMicrophoneURL {
                try? FileManager.default.removeItem(at: cleanedMicrophoneURL)
            }
        }
        let mic: URL?
        if let rawMic,
           project.audioCleanup.noiseGateEnabled
                || project.audioCleanup.normalizeEnabled
                || project.audioCleanup.deClickEnabled
        {
            let cleanupURL = try temporaryURL(for: outputURL, ext: "mic-cleanup.m4a")
            let processed = try await AudioCleanupProcessor.prepareMicrophone(
                sourceURL: rawMic,
                settings: project.audioCleanup,
                outputURL: cleanupURL
            )
            if processed == cleanupURL {
                cleanedMicrophoneURL = cleanupURL
            }
            mic = processed
        } else {
            mic = rawMic
        }
        let system = await ExportMediaIO.usableAudioURL(ProjectLayout.systemAudioURL(in: bundleURL))
        var sources: [ExportAudioMux.Source] = []
        if let mic {
            sources.append(.init(
                url: mic,
                offset: meta.captureTiming?.microphoneOffset ?? 0,
                gain: project.audioCleanup.microphoneGain,
                correction: meta.captureDiagnostics?.correction(for: .microphone)
            ))
        }
        if let system {
            sources.append(.init(
                url: system,
                offset: meta.captureTiming?.systemAudioOffset ?? 0,
                gain: project.audioCleanup.systemGain,
                correction: meta.captureDiagnostics?.correction(for: .systemAudio)
            ))
        }
        guard let prepared = try await ExportAudioMux.makeComposition(sources: sources, start: trim.start, duration: trim.end - trim.start, speedTimeline: speed, muteAudioWhenSpedUp: project.muteAudioWhenSpedUp) else {
            throw OpenRecordError.io("This project has no audio tracks to export.")
        }
        let tempURL = try temporaryURL(for: outputURL, ext: "m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let exporter = AVAssetExportSession(asset: prepared.composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw OpenRecordError.io("Could not create the audio export session.")
        }
        exporter.audioMix = prepared.audioMix
        exporter.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: prepared.duration, preferredTimescale: 48_000))
        report(progress, 0)
        try await exporter.export(to: tempURL, as: .m4a)
        try Task.checkCancellation()
        try install(tempURL, at: outputURL)
        report(progress, 1)
    }

    private static func temporaryURL(for outputURL: URL, ext: String) throws -> URL {
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(".\(outputURL.lastPathComponent).export-\(UUID().uuidString).\(ext)")
    }

    private static func install(_ temp: URL, at output: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: output.path) { _ = try fm.replaceItemAt(output, withItemAt: temp, backupItemName: nil, options: []) }
            else { try fm.moveItem(at: temp, to: output) }
        } catch { throw OpenRecordError.io("Could not write \(output.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func report(_ progress: ExportProgressHandler?, _ value: Double) { progress?(min(1, max(0, value))) }
}

private final class ExportFrameSession: @unchecked Sendable {
    let reader: ExportVideoReader
    let webcamReader: ExportVideoReader?
    let webcamDuration: TimeInterval
    let webcamOffset: TimeInterval
    let captureDiagnostics: CaptureDiagnostics?
    let engine: ZoomEngine
    let keyboardTimeline: KeyboardOverlayTimeline
    let compositor: ExportCompositor
    let speedTimeline: SpeedTimeline
    let trimStart: TimeInterval
    let trimEnd: TimeInterval
    let outputDuration: TimeInterval
    let fps: Int32
    let context: CIContext
    let width: Int
    let height: Int

    init(bundleURL: URL, project: ProjectDocument) async throws {
        let displayURL = try ExportMediaIO.requireDisplayVideo(in: bundleURL)
        let meta = try AtomicFileWrite.readJSON(ProjectMeta.self, from: ProjectLayout.metaURL(in: bundleURL))
        let mouse = (try? ExportJSONL.decode(CursorSample.self, from: ProjectLayout.mouseURL(in: bundleURL))) ?? []
        let clicks = (try? ExportJSONL.decode(ClickSample.self, from: ProjectLayout.clicksURL(in: bundleURL))) ?? []
        let target = (try? ExportJSONL.decode(TargetGeometrySample.self, from: ProjectLayout.targetGeometryURL(in: bundleURL))) ?? []
        let keys = (try? ExportJSONL.decode(KeySample.self, from: ProjectLayout.keysURL(in: bundleURL))) ?? []
        let asset = AVURLAsset(url: displayURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw OpenRecordError.io("Recording has no video track.") }
        let duration = try await asset.load(.duration)
        let trim = try ExportLayout.clampedTrim(trimIn: project.trimIn, trimOut: project.trimOut, duration: duration.seconds)
        let renderContext = ExportMediaIO.makeCIContext()
        let ci = renderContext.context
        let colorSpace = renderContext.colorSpace
        let reader = try ExportVideoReader(asset: asset, track: track)
        let webcamOffset = meta.captureTiming?.webcamOffset ?? 0
        var webcamReader: ExportVideoReader?
        var webcamDuration = 0.0
        if project.webcamOverlay.enabled {
            let webcamURL = ProjectLayout.webcamVideoURL(in: bundleURL)
            if FileManager.default.fileExists(atPath: webcamURL.path) {
                let webcam = AVURLAsset(url: webcamURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                if let wt = try? await webcam.loadTracks(withMediaType: .video).first {
                    let wduration = (try? await webcam.load(.duration))?.seconds ?? 0
                    webcamDuration = wduration
                    webcamReader = try? ExportVideoReader(asset: webcam, track: wt)
                }
            }
        }
        let speed = SpeedTimeline(segments: project.speedSegments)
        let fps = ExportLayout.outputFrameRate(sourceAverageFPS: await ExportMediaIO.sourceAverageFPS(track: track))
        let layout = ExportLayout.canvasLayout(canvas: project.canvas, sourceWidth: reader.sourceWidth, sourceHeight: reader.sourceHeight, resolution: project.videoExportSettings.resolution)
        let cursor = ExportCursorImage.load(document: project, bundleURL: bundleURL)
        let compositor = ExportCompositor(context: ci, colorSpace: colorSpace, canvas: project.canvas, keyboardOverlay: project.keyboardOverlay, webcamOverlay: project.webcamOverlay, webcamMirror: meta.webcam?.mirror ?? false, layout: layout, sourceWidth: reader.sourceWidth, sourceHeight: reader.sourceHeight, displayScale: meta.scale, cursorImage: cursor?.image, cursorSprite: cursor?.sprite, captions: project.captions, annotations: project.annotations)
        self.reader = reader; self.webcamReader = webcamReader; self.webcamDuration = webcamDuration; self.webcamOffset = webcamOffset; self.captureDiagnostics = meta.captureDiagnostics
        self.engine = ZoomEngine(document: project, samples: mouse, clicks: clicks, displayBounds: meta.displayBounds, targetGeometry: target)
        self.keyboardTimeline = KeyboardOverlayTimeline(samples: keys); self.compositor = compositor; self.speedTimeline = speed; self.trimStart = trim.start; self.trimEnd = trim.end
        self.outputDuration = speed.outputDuration(sourceStart: trim.start, sourceEnd: trim.end); self.fps = fps; self.context = ci; self.width = layout.width; self.height = layout.height
    }

    func image(at time: TimeInterval) throws -> CGImage? {
        let source = try reader.image(at: time)
        let webcamTime = WebcamTimeline.sourceTime(
            atTimelineTime: time,
            sourceDuration: webcamDuration,
            legacyOffset: webcamOffset,
            diagnostics: captureDiagnostics
        )
        let webcam = webcamReader.flatMap { reader in
            webcamTime.flatMap { try? reader.image(at: $0) }
        }
        let crop = engine.crop(at: time)
        let clicking = engine.isClicking(at: time)
        let buffer = try ExportMediaIO.makePixelBuffer(width: width, height: height)
        compositor.render(source: source, webcam: webcam, cropUV: crop, cursorUV: engine.interpolateCursor(at: time), cursorVelocity: engine.cursorVelocity(at: time), clicking: clicking, clickAge: clicking ? (ExportLayout.primaryClickAge(at: time, clicks: engine.smoother.clicks) ?? 0) : nil, keyboardState: keyboardTimeline.state(at: time, settings: engine.document.keyboardOverlay), sourceTime: time, into: buffer)
        return context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
