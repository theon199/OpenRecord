import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public typealias ExportProgressHandler = @Sendable (Double) -> Void

/// Renders a project document to the configured video codec and resolution at `url`.
///
/// Call with the **in-memory** `ProjectDocument` (trims, zooms, canvas, sprites) plus
/// the `.openrecord` bundle that holds `meta.json`, `recording/display.mp4`, telemetry,
/// and optional `mic.m4a` / `system.m4a`.
///
/// ```
/// let exporter = Exporter(projectBundleURL: opened.url)
/// try await exporter.export(project: opened.document, url: outputVideo) { progress in
///     // 0...1, may be called off the main actor
/// }
/// ```
///
/// Output: H.264/HEVC MP4 or ProRes 422 MOV in Rec.709 at the document's 720p,
/// 1080p, 4K, or source-sized preset. Frame rate is 60 fps if the source average
/// is ≥ 45, otherwise 30. Mic + system audio are mixed into one stereo AAC
/// 48 kHz track when present; missing audio files are skipped.
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
        try await export(
            project: project,
            url: url,
            legacyProgress: progress,
            status: nil
        )
    }

    /// Rich progress for editor UX. The original fractional callback remains
    /// source-compatible for callers that do not need FPS or ETA details.
    public func exportWithStatus(
        project: ProjectDocument,
        url: URL,
        status: ExportStatusHandler?
    ) async throws {
        try await export(
            project: project,
            url: url,
            legacyProgress: nil,
            status: status
        )
    }

    private func export(
        project: ProjectDocument,
        url: URL,
        legacyProgress: ExportProgressHandler?,
        status: ExportStatusHandler?
    ) async throws {
        let bundleURL = projectBundleURL
        let work = Task.detached(priority: .userInitiated) {
            try await ExportSession.run(
                bundleURL: bundleURL,
                project: project,
                outputURL: url,
                progress: legacyProgress,
                status: status
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
        progress: ExportProgressHandler?,
        status: ExportStatusHandler?
    ) async throws {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }

        report(
            progress,
            status,
            ExportProgress(phase: .preparing, fraction: 0)
        )

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
        let videoTracks: [AVAssetTrack]
        let sourceDuration: CMTime
        do {
            videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            sourceDuration = try await sourceAsset.load(.duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportFailure(stage: .sourceReading, detail: error.localizedDescription)
        }
        guard let videoTrack = videoTracks.first else {
            throw ExportFailure(
                stage: .sourceReading,
                detail: "recording/display.mp4 has no video track."
            )
        }
        guard sourceDuration.isNumeric, sourceDuration.seconds > 0 else {
            throw ExportFailure(
                stage: .sourceReading,
                detail: "recording/display.mp4 has an empty duration."
            )
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

        let timeMapper = ProjectTimeMapper(
            project: project,
            sourceDuration: sourceDuration.seconds
        )
        guard timeMapper.outputDuration > 0 else {
            throw ExportFailure(
                stage: .sourceReading,
                detail: "The project has no included media to export."
            )
        }

        let fps = ExportLayout.outputFrameRate(
            sourceAverageFPS: await ExportMediaIO.sourceAverageFPS(track: videoTrack)
        )
        let frameCount = max(1, Int((timeMapper.outputDuration * Double(fps)).rounded(.down)))

        let parent = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw ExportFailure(
                stage: .installation,
                detail: "Could not prepare the destination folder: \(error.localizedDescription)"
            )
        }
        let tempURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).export-\(UUID().uuidString).\(project.videoExportSettings.codec == .proRes422 ? "mov" : "mp4")",
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
                || project.audioCleanup.compressorEnabled
                || project.audioCleanup.limiterEnabled
                || project.audioCleanup.fadeInDuration > 0
                || project.audioCleanup.fadeOutDuration > 0
        {
            let cleanupURL = parent.appendingPathComponent(
                ".\(outputURL.lastPathComponent).mic-cleanup-\(UUID().uuidString).m4a",
                isDirectory: false
            )
            let processed: URL
            do {
                processed = try await AudioCleanupProcessor.prepareMicrophone(
                    sourceURL: rawMicURL,
                    settings: project.audioCleanup,
                    outputURL: cleanupURL
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ExportFailure(
                    stage: .audioMixing,
                    detail: "Could not prepare microphone audio: \(error.localizedDescription)"
                )
            }
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
                    gain: project.audioCleanup.microphoneGain,
                    correction: meta.captureDiagnostics?.correction(for: .microphone)
                )
            )
        }
        if let systemURL {
            audioSources.append(
                ExportAudioMux.Source(
                    url: systemURL,
                    offset: meta.captureTiming?.systemAudioOffset ?? 0,
                    gain: project.audioCleanup.systemGain,
                    correction: meta.captureDiagnostics?.correction(for: .systemAudio)
                )
            )
        }
        let audioComposition: ExportAudioMux.Prepared?
        do {
            audioComposition = try await ExportAudioMux.makeComposition(
                sources: audioSources,
                timeMapper: timeMapper,
                muteAudioWhenSpedUp: project.muteAudioWhenSpedUp
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportFailure(stage: .audioMixing, detail: error.localizedDescription)
        }

        let renderContext = ExportMediaIO.makeCIContext()
        let ciContext = renderContext.context
        let colorSpace = renderContext.colorSpace
        let reader: ExportVideoReader
        do {
            reader = try ExportVideoReader(asset: sourceAsset, track: videoTrack)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportFailure(stage: .sourceReading, detail: error.localizedDescription)
        }
        let webcamReader: ExportVideoReader?
        if let webcamAsset, let webcamTrack {
            webcamReader = try? ExportVideoReader(
                asset: webcamAsset,
                track: webcamTrack
            )
        } else {
            webcamReader = nil
        }
        let webcamOffset = meta.captureTiming?.webcamOffset ?? 0
        let captureDiagnostics = meta.captureDiagnostics
        let sourceWidth = reader.sourceWidth
        let sourceHeight = reader.sourceHeight

        let layout = ExportLayout.canvasLayout(
            canvas: project.canvas,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            resolution: project.videoExportSettings.resolution
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
            cursorSprite: cursor?.sprite,
            cursorEffects: project.cursorEffects,
            captions: project.captions,
            annotations: project.annotations,
            redactions: project.redactions,
            drawings: project.drawings,
            deviceFrame: project.deviceFrame
        )

        let writerParts: (
            AVAssetWriter,
            AVAssetWriterInput,
            AVAssetWriterInputPixelBufferAdaptor
        )
        do {
            writerParts = try ExportWriterFactory.makeVideoWriter(
                url: tempURL,
                width: layout.width,
                height: layout.height,
                fps: fps,
                codec: project.videoExportSettings.codec
            )
        } catch {
            throw ExportFailure(stage: .videoEncoding, detail: error.localizedDescription)
        }
        let (writer, videoInput, adaptor) = writerParts

        var audioInput: AVAssetWriterInput?
        if audioComposition != nil {
            let input = ExportWriterFactory.makeAudioInput()
            guard writer.canAdd(input) else {
                throw ExportFailure(
                    stage: .audioMixing,
                    detail: "Could not add the mixed audio track to the export file."
                )
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
            throw ExportFailure(
                stage: .videoEncoding,
                detail: writer.error?.localizedDescription
                    ?? "Could not start writing the export file."
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

        report(
            progress,
            status,
            ExportProgress(
                phase: .rendering,
                fraction: 0.02,
                framesCompleted: 0,
                totalFrames: frameCount
            )
        )

        // Decode and compose on one producer while the consumer serially feeds
        // AVAssetWriter. A three-frame queue is enough to overlap encoder
        // backpressure without allowing a long or 4K export to fan out memory.
        let frameQueue = ExportBoundedQueue<PreparedExportFrame>(capacity: 3)
        let framePreparer = ExportFramePreparer(
            reader: reader,
            webcamReader: webcamReader,
            webcamDuration: webcamDuration,
            webcamOffset: webcamOffset,
            captureDiagnostics: captureDiagnostics,
            timeMapper: timeMapper,
            fps: fps,
            engine: engine,
            keyboardTimeline: keyboardTimeline,
            keyboardSettings: project.keyboardOverlay,
            compositor: compositor,
            pixelBufferPool: adaptor.pixelBufferPool,
            canvasWidth: layout.width,
            canvasHeight: layout.height
        )
        let framePreparationTask = Task.detached(priority: .userInitiated) {
            do {
                for index in 0..<frameCount {
                    try Task.checkCancellation()
                    let frame = try autoreleasepool {
                        try framePreparer.prepare(index: index)
                    }
                    try frameQueue.append(frame)
                }
                frameQueue.finish()
            } catch {
                frameQueue.finish(throwing: error)
            }
        }

        let renderStarted = ContinuousClock.now
        var estimator = ExportProgressEstimator(totalFrames: frameCount)
        var completedFrames = 0
        do {
            while let frame = try frameQueue.next() {
                try Task.checkCancellation()
                try ExportAudioMux.waitUntilReady(videoInput, writer: writer)
                guard adaptor.append(
                    frame.pixelBuffer,
                    withPresentationTime: frame.presentationTime
                ) else {
                    throw ExportFailure(
                        stage: .videoEncoding,
                        detail: writer.error?.localizedDescription
                            ?? "Could not append a video frame."
                    )
                }
                completedFrames += 1

                if completedFrames == frameCount || completedFrames % 4 == 0 {
                    let measured = estimator.update(
                        framesCompleted: completedFrames,
                        elapsedSeconds: elapsedSeconds(since: renderStarted)
                    )
                    report(
                        progress,
                        status,
                        renderingProgress(from: measured)
                    )
                }
            }
            await framePreparationTask.value
            guard completedFrames == frameCount else {
                throw ExportFailure(
                    stage: .frameRendering,
                    detail: "Frame preparation ended before every output frame was produced."
                )
            }
        } catch {
            frameQueue.cancel()
            framePreparationTask.cancel()
            audioTask?.cancel()
            writer.cancelWriting()
            await framePreparationTask.value
            if let audioTask {
                _ = await audioTask.result
            }
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }

        videoInput.markAsFinished()
        report(
            progress,
            status,
            ExportProgress(
                phase: .finalizing,
                fraction: 0.90,
                framesCompleted: frameCount,
                totalFrames: frameCount,
                elapsedSeconds: elapsedSeconds(since: renderStarted)
            )
        )

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
                throw ExportFailure(
                    stage: .audioMixing,
                    detail: error.localizedDescription
                )
            }
        }
        report(
            progress,
            status,
            ExportProgress(
                phase: .finalizing,
                fraction: 0.97,
                framesCompleted: frameCount,
                totalFrames: frameCount,
                elapsedSeconds: elapsedSeconds(since: renderStarted)
            )
        )

        try Task.checkCancellation()
        do {
            try await finish(writer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportFailure(stage: .finalization, detail: error.localizedDescription)
        }
        try Task.checkCancellation()
        try install(tempURL, at: outputURL)
        succeeded = true
        let completed = estimator.complete(
            elapsedSeconds: elapsedSeconds(since: renderStarted)
        )
        report(progress, status, completed)
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
            throw ExportFailure(
                stage: .installation,
                detail: "Could not write \(outputURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func renderingProgress(from measured: ExportProgress) -> ExportProgress {
        ExportProgress(
            phase: .rendering,
            fraction: 0.02 + 0.86 * measured.fraction,
            framesCompleted: measured.framesCompleted,
            totalFrames: measured.totalFrames,
            elapsedSeconds: measured.elapsedSeconds,
            framesPerSecond: measured.framesPerSecond,
            estimatedRemainingSeconds: measured.estimatedRemainingSeconds
        )
    }

    private static func elapsedSeconds(
        since start: ContinuousClock.Instant
    ) -> TimeInterval {
        let components = start.duration(to: .now).components
        return max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
    }

    private static func report(
        _ progress: ExportProgressHandler?,
        _ status: ExportStatusHandler?,
        _ value: ExportProgress
    ) {
        progress?(value.fraction)
        status?(value)
    }
}

private struct PreparedExportFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var presentationTime: CMTime
}

/// Owns every sequential, non-thread-safe decoder/compositor dependency. Only
/// one producer task calls `prepare`, while the writer consumes already-rendered
/// buffers in order from `ExportBoundedQueue`.
private final class ExportFramePreparer: @unchecked Sendable {
    let reader: ExportVideoReader
    let webcamReader: ExportVideoReader?
    let webcamDuration: TimeInterval
    let webcamOffset: TimeInterval
    let captureDiagnostics: CaptureDiagnostics?
    let timeMapper: ProjectTimeMapper
    let fps: Int32
    let engine: ZoomEngine
    let keyboardTimeline: KeyboardOverlayTimeline
    let keyboardSettings: KeyboardOverlaySettings
    let compositor: ExportCompositor
    let pixelBufferPool: CVPixelBufferPool?
    let canvasWidth: Int
    let canvasHeight: Int

    init(
        reader: ExportVideoReader,
        webcamReader: ExportVideoReader?,
        webcamDuration: TimeInterval,
        webcamOffset: TimeInterval,
        captureDiagnostics: CaptureDiagnostics?,
        timeMapper: ProjectTimeMapper,
        fps: Int32,
        engine: ZoomEngine,
        keyboardTimeline: KeyboardOverlayTimeline,
        keyboardSettings: KeyboardOverlaySettings,
        compositor: ExportCompositor,
        pixelBufferPool: CVPixelBufferPool?,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        self.reader = reader
        self.webcamReader = webcamReader
        self.webcamDuration = webcamDuration
        self.webcamOffset = webcamOffset
        self.captureDiagnostics = captureDiagnostics
        self.timeMapper = timeMapper
        self.fps = fps
        self.engine = engine
        self.keyboardTimeline = keyboardTimeline
        self.keyboardSettings = keyboardSettings
        self.compositor = compositor
        self.pixelBufferPool = pixelBufferPool
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    func prepare(index: Int) throws -> PreparedExportFrame {
        try Task.checkCancellation()
        let outputTime = Double(index) / Double(fps)
        let sourceTime = timeMapper.sourceTime(atOutputTime: outputTime)

        let source: CIImage
        do {
            source = try reader.image(at: sourceTime)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportFailure(stage: .sourceReading, detail: error.localizedDescription)
        }

        let webcamTime = WebcamTimeline.sourceTime(
            atTimelineTime: sourceTime,
            sourceDuration: webcamDuration,
            legacyOffset: webcamOffset,
            diagnostics: captureDiagnostics
        )
        let webcamFrame: CIImage?
        if let webcamReader,
           let webcamTime,
           webcamTime >= 0,
           webcamTime <= webcamDuration
        {
            do {
                webcamFrame = try webcamReader.image(at: webcamTime)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Webcam is an optional overlay. Preserve the existing
                // degraded-export behavior when only that track is damaged.
                webcamFrame = nil
            }
        } else {
            webcamFrame = nil
        }

        let pixelBuffer: CVPixelBuffer
        do {
            if let pixelBufferPool {
                var buffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pixelBufferPool,
                    &buffer
                )
                guard status == kCVReturnSuccess, let buffer else {
                    throw OpenRecordError.io(
                        "Could not allocate an export frame buffer (Core Video status \(status))."
                    )
                }
                pixelBuffer = buffer
            } else {
                pixelBuffer = try ExportMediaIO.makePixelBuffer(
                    width: canvasWidth,
                    height: canvasHeight
                )
            }
        } catch {
            throw ExportFailure(stage: .frameRendering, detail: error.localizedDescription)
        }

        let clicking = engine.isClicking(at: sourceTime)
        compositor.render(
            source: source,
            webcam: webcamFrame,
            cropUV: engine.crop(at: sourceTime),
            cursorUV: engine.interpolateCursor(at: sourceTime),
            cursorVelocity: engine.cursorVelocity(at: sourceTime),
            clicking: clicking,
            clickAge: clicking
                ? (ExportLayout.primaryClickAge(
                    at: sourceTime,
                    clicks: engine.smoother.clicks
                ) ?? 0)
                : nil,
            keyboardState: keyboardTimeline.state(
                at: sourceTime,
                settings: keyboardSettings
            ),
            sourceTime: sourceTime,
            into: pixelBuffer
        )
        try Task.checkCancellation()
        return PreparedExportFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: Int64(index), timescale: fps)
        )
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
        defer { input.markAsFinished() }
        try ExportAudioMux.append(
            to: writer,
            input: input,
            prepared: prepared
        )
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
