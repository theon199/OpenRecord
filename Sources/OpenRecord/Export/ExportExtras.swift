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

    /// Writes a PNG still rendered at an output timeline position.
    ///
    /// The output timestamp is mapped through the same edit/speed map used by
    /// video, GIF, and audio exports before source-timed effects are sampled.
    func exportSnapshot(project: ProjectDocument, atOutputTime outputTime: TimeInterval, url: URL) async throws {
        let bundleURL = projectBundleURL
        let task = Task.detached(priority: .userInitiated) {
            try await ExportAlternateSession.snapshot(bundleURL: bundleURL, project: project, outputTime: outputTime, outputURL: url)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Source-timeline overload retained for clients built against v2.5.
    /// New callers should use `atOutputTime:` to make the clock explicit.
    func exportSnapshot(project: ProjectDocument, at time: TimeInterval, url: URL) async throws {
        let bundleURL = projectBundleURL
        let task = Task.detached(priority: .userInitiated) {
            try await ExportAlternateSession.snapshot(
                bundleURL: bundleURL,
                project: project,
                sourceTime: time,
                outputURL: url
            )
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private enum ExportAlternateSession {
    private enum SnapshotPosition {
        case output(TimeInterval)
        case source(TimeInterval)
    }

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
            try autoreleasepool {
                guard let image = try frames.image(atOutputTime: outputTime) else {
                    throw OpenRecordError.io("Could not render a GIF frame.")
                }
                let frameProperties: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(frameRate)] as [CFString: Any]
                ]
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            }
            if index == count - 1 || index % 2 == 0 { report(progress, Double(index + 1) / Double(count)) }
        }
        guard CGImageDestinationFinalize(destination) else { throw OpenRecordError.io("Could not finalize the GIF export file.") }
        try install(tempURL, at: outputURL)
        report(progress, 1)
    }

    static func snapshot(bundleURL: URL, project: ProjectDocument, outputTime: TimeInterval, outputURL: URL) async throws {
        try await snapshot(
            bundleURL: bundleURL,
            project: project,
            position: .output(outputTime),
            outputURL: outputURL
        )
    }

    static func snapshot(bundleURL: URL, project: ProjectDocument, sourceTime: TimeInterval, outputURL: URL) async throws {
        try await snapshot(
            bundleURL: bundleURL,
            project: project,
            position: .source(sourceTime),
            outputURL: outputURL
        )
    }

    private static func snapshot(
        bundleURL: URL,
        project: ProjectDocument,
        position: SnapshotPosition,
        outputURL: URL
    ) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer { if accessed { bundleURL.stopAccessingSecurityScopedResource() } }
        let frames = try await ExportFrameSession(bundleURL: bundleURL, project: project)
        guard frames.outputDuration > 0 else {
            throw OpenRecordError.io("The project has no included media to export.")
        }
        let outputTime: TimeInterval
        switch position {
        case .output(let requestedOutputTime):
            outputTime = FrameSceneResolver.canonicalOutputTime(
                requestedOutputTime,
                duration: frames.outputDuration
            )
        case .source(let requestedSourceTime):
            outputTime = frames.timeMapper.clampedOutputTime(
                forSourceTime: requestedSourceTime
            )
        }
        guard let image = try frames.image(atOutputTime: outputTime) else {
            throw OpenRecordError.io("Could not render the snapshot.")
        }
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
        let displayDuration = try await display.load(.duration)
        let timeMapper = ProjectTimeMapper(
            project: project,
            sourceDuration: displayDuration.seconds
        )
        guard timeMapper.outputDuration > 0 else {
            throw OpenRecordError.io("The project has no included media to export.")
        }
        let meta = try AtomicFileWrite.readJSON(ProjectMeta.self, from: ProjectLayout.metaURL(in: bundleURL))
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
                || project.audioCleanup.compressorEnabled
                || project.audioCleanup.limiterEnabled
                || project.audioCleanup.fadeInDuration > 0
                || project.audioCleanup.fadeOutDuration > 0
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
        guard let prepared = try await ExportAudioMux.makeComposition(sources: sources, timeMapper: timeMapper, muteAudioWhenSpedUp: project.muteAudioWhenSpedUp) else {
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
    let renderService: FrameRenderService
    let timeMapper: ProjectTimeMapper
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
        let timeMapper = ProjectTimeMapper(
            project: project,
            sourceDuration: duration.seconds
        )
        guard timeMapper.outputDuration > 0 else {
            throw OpenRecordError.io("The project has no included media to export.")
        }
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
                    let assetDuration = (try? await webcam.load(.duration))?.seconds ?? 0
                    let wduration: TimeInterval
                    if let timeRange = try? await wt.load(.timeRange),
                       timeRange.duration.isNumeric,
                       timeRange.duration.seconds > 0
                    {
                        wduration = timeRange.duration.seconds
                    } else {
                        wduration = assetDuration
                    }
                    webcamDuration = wduration
                    webcamReader = try? ExportVideoReader(asset: webcam, track: wt)
                }
            }
        }
        let fps = project.videoExportSettings.frameRate.resolvedFPS(sourceAverageFPS: await ExportMediaIO.sourceAverageFPS(track: track))
        let layout = ExportLayout.canvasLayout(canvas: project.canvas, sourceWidth: reader.sourceWidth, sourceHeight: reader.sourceHeight, resolution: project.videoExportSettings.resolution)
        let cursor = ExportCursorImage.load(document: project, bundleURL: bundleURL)
        let engine = ZoomEngine(document: project, samples: mouse, clicks: clicks, displayBounds: meta.displayBounds, targetGeometry: target)
        let keyboardTimeline = KeyboardOverlayTimeline(samples: keys)
        let compositor = ExportCompositor(context: ci, colorSpace: colorSpace, canvas: project.canvas, keyboardOverlay: project.keyboardOverlay, webcamOverlay: project.webcamOverlay, webcamMirror: meta.webcam?.mirror ?? false, layout: layout, sourceWidth: reader.sourceWidth, sourceHeight: reader.sourceHeight, displayScale: meta.scale, cursorImage: cursor?.image, cursorSprite: cursor?.sprite, cursorEffects: project.cursorEffects, captions: project.captions, annotations: project.annotations, redactions: project.redactions, drawings: project.drawings, deviceFrame: project.deviceFrame)
        let incomingReader = try? ExportVideoReader(asset: asset, track: track)
        self.renderService = FrameRenderService(project: project, reader: reader, incomingReader: incomingReader, webcamReader: webcamReader, webcamDuration: webcamDuration, webcamOffset: webcamOffset, captureDiagnostics: meta.captureDiagnostics, webcamMirror: meta.webcam?.mirror ?? false, webcamSourceAspect: webcamReader.map { Double(max($0.sourceWidth, 1)) / Double(max($0.sourceHeight, 1)) }, timeMapper: timeMapper, engine: engine, keyboardTimeline: keyboardTimeline, cursor: FrameSceneCursorMetadata(sprite: cursor?.sprite, imagePixelSize: cursor.map { Size2D(width: $0.image.extent.width, height: $0.image.extent.height) }), compositor: compositor, context: ci, width: layout.width, height: layout.height, displayScale: meta.scale)
        self.timeMapper = timeMapper
        self.outputDuration = timeMapper.outputDuration; self.fps = fps; self.context = ci; self.width = layout.width; self.height = layout.height
    }

    func image(atOutputTime outputTime: TimeInterval) throws -> CGImage? {
        try renderService.image(atOutputTime: outputTime)
    }
}
