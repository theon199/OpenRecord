import AVFoundation
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
        let mouse = try ExportJSONL.decode(
            CursorSample.self,
            from: ProjectLayout.mouseURL(in: bundleURL)
        )
        let clicks = try ExportJSONL.decode(
            ClickSample.self,
            from: ProjectLayout.clicksURL(in: bundleURL)
        )

        let engine = ZoomEngine(
            document: project,
            samples: mouse,
            clicks: clicks,
            displayBounds: meta.displayBounds
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

        let (trimStart, trimEnd) = try ExportLayout.clampedTrim(
            trimIn: project.trimIn,
            trimOut: project.trimOut,
            duration: sourceDuration.seconds
        )

        let fps = ExportLayout.outputFrameRate(
            sourceAverageFPS: await ExportMediaIO.sourceAverageFPS(track: videoTrack)
        )
        let span = trimEnd - trimStart
        let frameCount = max(1, Int((span * Double(fps)).rounded(.down)))
        let exportDuration = Double(frameCount) / Double(fps)

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).export-\(UUID().uuidString).mp4",
            isDirectory: false
        )

        let micURL = await ExportMediaIO.usableAudioURL(
            ProjectLayout.microphoneAudioURL(in: bundleURL)
        )
        let systemURL = await ExportMediaIO.usableAudioURL(
            ProjectLayout.systemAudioURL(in: bundleURL)
        )
        let audioSources = [micURL, systemURL].compactMap { $0 }
        let audioComposition = try await ExportAudioMux.makeComposition(
            sources: audioSources,
            start: trimStart,
            duration: exportDuration
        )

        let (ciContext, colorSpace) = ExportMediaIO.makeCIContext()
        let reader = try ExportVideoReader(
            asset: sourceAsset,
            track: videoTrack,
            copyContext: ciContext,
            colorSpace: colorSpace
        )
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
        defer {
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

        report(progress, 0.02)

        let canvasWidth = layout.width
        let canvasHeight = layout.height

        for index in 0..<frameCount {
            try Task.checkCancellation()
            try ExportAudioMux.waitUntilReady(videoInput, writer: writer)

            let t = trimStart + Double(index) / Double(fps)
            let pts = CMTime(value: Int64(index), timescale: fps)

            try autoreleasepool {
                let source = try reader.image(at: t)
                let crop = engine.crop(at: t)
                let cursorUV = engine.interpolateCursor(at: t)
                let clicking = engine.isClicking(at: t)
                let clickAge = clicking
                    ? (ExportLayout.primaryClickAge(at: t, clicks: clicks) ?? 0)
                    : nil

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
                    cropUV: crop,
                    cursorUV: cursorUV,
                    clicking: clicking,
                    clickAge: clickAge,
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

        if let audioInput, let audioComposition {
            try ExportAudioMux.append(
                to: writer,
                input: audioInput,
                composition: audioComposition
            )
            audioInput.markAsFinished()
        }
        report(progress, 0.97)

        try await finish(writer)
        try install(tempURL, at: outputURL)
        succeeded = true
        report(progress, 1)
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = WriterFinishBox(writer: writer, continuation: continuation)
            box.start()
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
