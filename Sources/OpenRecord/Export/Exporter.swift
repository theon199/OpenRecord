import AVFoundation
import CoreImage
import CoreMedia
import Foundation

public typealias ExportProgressHandler = @Sendable (Double) -> Void

/// Renders a project document to an H.264 MP4 at `url`.
///
/// Call with the **in-memory** `ProjectDocument` (trims, zooms, canvas, sprites) plus
/// the `.openrecord` bundle that holds `meta.json`, `recording/display.mp4`, telemetry,
/// and optional `mic.m4a` / `system.m4a`.
///
/// ```
/// let exporter = Exporter(projectBundleURL: opened.url)
/// try await exporter.export(project: opened.document, url: outputMP4) { progress in
///     // 0...1, may be called off the main actor
/// }
/// ```
///
/// Output: H.264 High Rec.709, 1080p-capped canvas (long ≤ 1920, short ≤ 1080, even),
/// 60 fps if the source average is ≥ 45, else 30. Mic + system audio are mixed into
/// one stereo AAC 48 kHz track when present; missing audio files are skipped.
public struct Exporter: Sendable {
    public var projectBundleURL: URL

    public init(projectBundleURL: URL) {
        self.projectBundleURL = projectBundleURL
    }

    public func export(
        project: ProjectDocument,
        url: URL,
        progress: ExportProgressHandler?
    ) async throws {
        let bundleURL = projectBundleURL
        let work = Task.detached(priority: .userInitiated) {
            try await ExportSession.run(
                bundleURL: bundleURL,
                project: project,
                outputURL: url,
                progress: progress
            )
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

private enum ExportSession {
    static func run(
        bundleURL: URL,
        project: ProjectDocument,
        outputURL: URL,
        progress: ExportProgressHandler?
    ) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }

        report(progress, 0)

        let displayURL = try ExportMediaIO.requireDisplayVideo(in: bundleURL)
        let meta = try AtomicFileWrite.readJSON(
            ProjectMeta.self,
            from: ProjectLayout.metaURL(in: bundleURL)
        )
        let mouse = (try? ExportJSONL.decode(
            CursorSample.self,
            from: ProjectLayout.mouseURL(in: bundleURL)
        )) ?? []
        let clicks = (try? ExportJSONL.decode(
            ClickSample.self,
            from: ProjectLayout.clicksURL(in: bundleURL)
        )) ?? []
        let targetGeometry = (try? ExportJSONL.decode(
            TargetGeometrySample.self,
            from: ProjectLayout.targetGeometryURL(in: bundleURL)
        )) ?? []
        // Keyboard telemetry is optional for v1 projects and for captures made
        // while secure input was enabled. A missing or malformed sidecar must
        // not prevent the video itself from exporting.
        let keys = (try? ExportJSONL.decode(
            KeySample.self,
            from: ProjectLayout.keysURL(in: bundleURL)
        )) ?? []
        let keyboardTimeline = KeyboardOverlayTimeline(samples: keys)

        let engine = ZoomEngine(
            document: project,
            samples: mouse,
            clicks: clicks,
            displayBounds: meta.displayBounds,
            targetGeometry: targetGeometry
        )

        let sourceAsset = AVURLAsset(
            url: displayURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw OpenRecordError.io("recording/display.mp4 has no video track.")
        }
        let sourceDuration = try await sourceAsset.load(.duration)
        guard sourceDuration.isNumeric, sourceDuration.seconds > 0 else {
            throw OpenRecordError.io("recording/display.mp4 has an empty duration.")
        }

        var webcamAsset: AVURLAsset?
        var webcamTrack: AVAssetTrack?
        var webcamDuration: TimeInterval = 0
        if project.webcamOverlay.enabled {
            let webcamURL = ProjectLayout.webcamVideoURL(in: bundleURL)
            if FileManager.default.fileExists(atPath: webcamURL.path) {
                let candidate = AVURLAsset(
                    url: webcamURL,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                if let track = try? await candidate.loadTracks(withMediaType: .video).first,
                   let duration = try? await candidate.load(.duration),
                   duration.isNumeric,
                   duration.seconds > 0
                {
                    webcamAsset = candidate
                    webcamTrack = track
                    if let timeRange = try? await track.load(.timeRange),
                       timeRange.duration.isNumeric,
                       timeRange.duration.seconds > 0
                    {
                        webcamDuration = timeRange.duration.seconds
                    } else {
                        webcamDuration = duration.seconds
                    }
                }
            }
        }

        let (trimStart, trimEnd) = try ExportLayout.clampedTrim(
            trimIn: project.trimIn,
            trimOut: project.trimOut,
            duration: sourceDuration.seconds
        )

        let fps = ExportLayout.outputFrameRate(
            sourceAverageFPS: await ExportMediaIO.sourceAverageFPS(track: videoTrack)
        )
        let sourceSpan = trimEnd - trimStart
        let speedTimeline = SpeedTimeline(segments: project.speedSegments)
        let mappedSpan = speedTimeline.outputDuration(
            sourceStart: trimStart,
            sourceEnd: trimEnd
        )
        let frameCount = max(1, Int((mappedSpan * Double(fps)).rounded(.down)))

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).export-\(UUID().uuidString).mp4",
            isDirectory: false
        )

        let rawMicURL = await ExportMediaIO.usableAudioURL(
            ProjectLayout.microphoneAudioURL(in: bundleURL)
        )
        var cleanedMicrophoneURL: URL?
        defer {
            if let cleanedMicrophoneURL {
                try? FileManager.default.removeItem(at: cleanedMicrophoneURL)
            }
        }
        let micURL: URL?
        if let rawMicURL,
           project.audioCleanup.noiseGateEnabled
                || project.audioCleanup.normalizeEnabled
                || project.audioCleanup.deClickEnabled
        {
            let cleanupURL = parent.appendingPathComponent(
                ".\(outputURL.lastPathComponent).mic-cleanup-\(UUID().uuidString).m4a",
                isDirectory: false
            )
            let processed = try await AudioCleanupProcessor.prepareMicrophone(
                sourceURL: rawMicURL,
                settings: project.audioCleanup,
                outputURL: cleanupURL
            )
            if processed == cleanupURL {
                cleanedMicrophoneURL = cleanupURL
            }
            micURL = processed
        } else {
            micURL = rawMicURL
        }
        let systemURL = await ExportMediaIO.usableAudioURL(
            ProjectLayout.systemAudioURL(in: bundleURL)
        )
        var audioSources: [ExportAudioMux.Source] = []
        if let micURL {
            audioSources.append(
                ExportAudioMux.Source(
                    url: micURL,
                    offset: meta.captureTiming?.microphoneOffset ?? 0,
                    gain: project.audioCleanup.microphoneGain
                )
            )
        }
        if let systemURL {
            audioSources.append(
                ExportAudioMux.Source(
                    url: systemURL,
                    offset: meta.captureTiming?.systemAudioOffset ?? 0,
                    gain: project.audioCleanup.systemGain
                )
            )
        }
        let audioComposition = try await ExportAudioMux.makeComposition(
            sources: audioSources,
            start: trimStart,
            duration: sourceSpan,
            speedTimeline: speedTimeline,
            muteAudioWhenSpedUp: project.muteAudioWhenSpedUp
        )

        let (ciContext, colorSpace) = ExportMediaIO.makeCIContext()
        let reader = try ExportVideoReader(
            asset: sourceAsset,
            track: videoTrack,
            copyContext: ciContext,
            colorSpace: colorSpace
        )
        let webcamReader: ExportVideoReader?
        if let webcamAsset, let webcamTrack {
            webcamReader = try? ExportVideoReader(
                asset: webcamAsset,
                track: webcamTrack,
                copyContext: ciContext,
                colorSpace: colorSpace
            )
        } else {
            webcamReader = nil
        }
        let webcamOffset = meta.captureTiming?.webcamOffset ?? 0
        let sourceWidth = reader.sourceWidth
        let sourceHeight = reader.sourceHeight

        let layout = ExportLayout.canvasLayout(
            canvas: project.canvas,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        let cursor = ExportCursorImage.load(document: project, bundleURL: bundleURL)
        let compositor = ExportCompositor(
            context: ciContext,
            colorSpace: colorSpace,
            canvas: project.canvas,
            keyboardOverlay: project.keyboardOverlay,
            webcamOverlay: project.webcamOverlay,
            webcamMirror: meta.webcam?.mirror ?? false,
            layout: layout,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            displayScale: meta.scale,
            cursorImage: cursor?.image,
            cursorSprite: cursor?.sprite
        )

        let (writer, videoInput, adaptor) = try ExportWriterFactory.makeVideoWriter(
            url: tempURL,
            width: layout.width,
            height: layout.height,
            fps: fps
        )

        var audioInput: AVAssetWriterInput?
        if audioComposition != nil {
            let input = ExportWriterFactory.makeAudioInput()
            guard writer.canAdd(input) else {
                throw OpenRecordError.io("Could not add an audio track to the export file.")
            }
            writer.add(input)
            audioInput = input
        }

        var succeeded = false
        var audioTask: Task<Void, Error>?
        defer {
            audioTask?.cancel()
            if !succeeded {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        guard writer.startWriting() else {
            throw OpenRecordError.io(
                writer.error?.localizedDescription ?? "Could not start writing the export file."
            )
        }
        writer.startSession(atSourceTime: .zero)

        if let audioInput, let audioComposition {
            let box = ExportAudioTaskBox(
                writer: writer,
                input: audioInput,
                composition: audioComposition
            )
            audioTask = Task.detached(priority: .userInitiated) {
                try box.appendAndFinish()
            }
        }

        report(progress, 0.02)

        let canvasWidth = layout.width
        let canvasHeight = layout.height

        for index in 0..<frameCount {
            try Task.checkCancellation()
            try ExportAudioMux.waitUntilReady(videoInput, writer: writer)

            let outputTime = Double(index) / Double(fps)
            let t = speedTimeline.sourceTime(
                atOutputTime: outputTime,
                sourceStart: trimStart,
                sourceEnd: trimEnd
            )
            let pts = CMTime(value: Int64(index), timescale: fps)

            try autoreleasepool {
                let source = try reader.image(at: t)
                let webcamTime = t - webcamOffset
                let webcamFrame: CIImage?
                if let webcamReader,
                   webcamTime >= 0,
                   webcamTime <= webcamDuration
                {
                    webcamFrame = try? webcamReader.image(at: webcamTime)
                } else {
                    webcamFrame = nil
                }
                let crop = engine.crop(at: t)
                let cursorUV = engine.interpolateCursor(at: t)
                let cursorVelocity = engine.cursorVelocity(at: t)
                let clicking = engine.isClicking(at: t)
                let clickAge = clicking
                    ? (ExportLayout.primaryClickAge(at: t, clicks: engine.smoother.clicks) ?? 0)
                    : nil
                let keyboardState = keyboardTimeline.state(
                    at: t,
                    settings: project.keyboardOverlay
                )

                let pixelBuffer: CVPixelBuffer
                if let pool = adaptor.pixelBufferPool {
                    var buffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard status == kCVReturnSuccess, let buffer else {
                        throw OpenRecordError.io("Could not allocate an export frame buffer.")
                    }
                    pixelBuffer = buffer
                } else {
                    pixelBuffer = try ExportMediaIO.makePixelBuffer(
                        width: canvasWidth,
                        height: canvasHeight
                    )
                }

                compositor.render(
                    source: source,
                    webcam: webcamFrame,
                    cropUV: crop,
                    cursorUV: cursorUV,
                    cursorVelocity: cursorVelocity,
                    clicking: clicking,
                    clickAge: clickAge,
                    keyboardState: keyboardState,
                    into: pixelBuffer
                )

                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw OpenRecordError.io(
                        writer.error?.localizedDescription ?? "Could not append an export video frame."
                    )
                }
            }

            if index == frameCount - 1 || index % 4 == 0 {
                let fraction = Double(index + 1) / Double(frameCount)
                report(progress, 0.02 + 0.86 * fraction)
            }
        }

        videoInput.markAsFinished()
        report(progress, 0.90)

        if let audioTask {
            do {
                let cancellationBox = WriterCancellationBox(writer: writer)
                try await withTaskCancellationHandler {
                    try await audioTask.value
                } onCancel: {
                    audioTask.cancel()
                    cancellationBox.cancel()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        report(progress, 0.97)

        try Task.checkCancellation()
        try await finish(writer)
        try Task.checkCancellation()
        try install(tempURL, at: outputURL)
        succeeded = true
        report(progress, 1)
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        let cancellationBox = WriterCancellationBox(writer: writer)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let box = WriterFinishBox(writer: writer, continuation: continuation)
                    box.start()
                }
            } onCancel: {
                cancellationBox.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func install(_ tempURL: URL, at outputURL: URL) throws {
        let fm = FileManager.default
        if tempURL.standardizedFileURL == outputURL.standardizedFileURL {
            return
        }
        do {
            if fm.fileExists(atPath: outputURL.path) {
                _ = try fm.replaceItemAt(
                    outputURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fm.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw OpenRecordError.io(
                "Could not write \(outputURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func report(_ progress: ExportProgressHandler?, _ value: Double) {
        progress?(min(1, max(0, value)))
    }
}

/// AVAssetWriter expects enabled inputs to advance together. Keeping audio on
/// its own producer prevents video backpressure from deadlocking while it waits
/// for the first audio samples.
private final class ExportAudioTaskBox: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let prepared: ExportAudioMux.Prepared

    init(
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        composition: ExportAudioMux.Prepared
    ) {
        self.writer = writer
        self.input = input
        self.prepared = composition
    }

    func appendAndFinish() throws {
        try ExportAudioMux.append(
            to: writer,
            input: input,
            prepared: prepared
        )
        input.markAsFinished()
    }
}

private final class WriterCancellationBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }

    func cancel() {
        writer.cancelWriting()
    }
}

private final class WriterFinishBox: @unchecked Sendable {
    let writer: AVAssetWriter
    let continuation: CheckedContinuation<Void, Error>

    init(writer: AVAssetWriter, continuation: CheckedContinuation<Void, Error>) {
        self.writer = writer
        self.continuation = continuation
    }

    func start() {
        writer.finishWriting { [self] in
            if writer.status == .failed || writer.status != .completed {
                continuation.resume(
                    throwing: OpenRecordError.io(
                        writer.error?.localizedDescription ?? "Failed to finish the export file."
                    )
                )
            } else {
                continuation.resume()
            }
        }
    }
}
