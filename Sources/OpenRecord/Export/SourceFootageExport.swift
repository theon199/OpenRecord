import AVFoundation
import CoreMedia
import Foundation

/// Copies captured screen and webcam files into an MP4 without the compositor.
///
/// The full export path decodes every frame, draws canvas/cursor/zoom/overlays,
/// and re-encodes. When those effects are absent, the already-encoded
/// `recording/display.mp4` and optional `recording/webcam.mp4` can be remuxed
/// (bitstream copy) with the current trim and audio tracks. That is typically
/// orders of magnitude faster because it never touches pixels.
public enum SourceFootageExport: Sendable {
    /// True when a remux can replace a compositor render without dropping
    /// authored visual effects. Trim is allowed; speed, cuts, zooms, and
    /// overlays are not.
    public static func isAvailable(for project: ProjectDocument) -> Bool {
        project.zoomRanges.isEmpty
            && !project.keyboardOverlay.enabled
            && project.captions.isEmpty
            && project.annotations.isEmpty
            && project.redactions.isEmpty
            && project.drawings.isEmpty
            && !project.deviceFrame.enabled
            && project.cursorEffects.isEmpty
            && project.editDecisions.isEmpty
            && project.speedSegments.allSatisfy { abs($0.rate - 1) < 0.000_001 }
    }

    /// Sidecar next to a chosen screen export, used when a webcam capture exists.
    public static func webcamSidecarURL(beside videoURL: URL) -> URL {
        let folder = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(stem)-webcam.mp4", isDirectory: false)
    }
}

public struct SourceFootageExportResult: Sendable, Equatable {
    public var videoURL: URL
    public var webcamURL: URL?

    public init(videoURL: URL, webcamURL: URL? = nil) {
        self.videoURL = videoURL
        self.webcamURL = webcamURL
    }
}

public extension Exporter {
    /// Remuxes captured screen (and webcam) footage without re-rendering.
    ///
    /// The screen file is written to `url`. When `recording/webcam.mp4` exists,
    /// a matching `-webcam.mp4` sidecar is written beside it. Canvas, cursor,
    /// and zoom are omitted by design — this path exists only for speed.
    @discardableResult
    func exportSourceFootage(
        project: ProjectDocument,
        url: URL,
        progress: ExportProgressHandler?
    ) async throws -> SourceFootageExportResult {
        let bundleURL = projectBundleURL
        let work = Task.detached(priority: .userInitiated) {
            try await SourceFootageSession.run(
                bundleURL: bundleURL,
                project: project,
                outputURL: url,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

private enum SourceFootageSession {
    static func run(
        bundleURL: URL,
        project: ProjectDocument,
        outputURL: URL,
        progress: ExportProgressHandler?
    ) async throws -> SourceFootageExportResult {
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                bundleURL.stopAccessingSecurityScopedResource()
            }
        }

        guard SourceFootageExport.isAvailable(for: project) else {
            throw OpenRecordError.io(
                "Fast export copies the captured screen and webcam files. It is available only when zoom, overlays, speed changes, and cuts are not applied. Use Export Video to render those effects."
            )
        }

        report(progress, 0)
        try Task.checkCancellation()

        let displayURL = try ExportMediaIO.requireDisplayVideo(in: bundleURL)
        let meta = try AtomicFileWrite.readJSON(
            ProjectMeta.self,
            from: ProjectLayout.metaURL(in: bundleURL)
        )
        let displayAsset = AVURLAsset(
            url: displayURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let displayDuration = try await displayAsset.load(.duration)
        guard displayDuration.isNumeric, displayDuration.seconds > 0.02 else {
            throw OpenRecordError.io("recording/display.mp4 has no usable duration.")
        }

        let mapper = ProjectTimeMapper(project: project, sourceDuration: displayDuration.seconds)
        guard mapper.outputDuration > 0, let span = mapper.slices.first else {
            throw OpenRecordError.io("The project has no included media to export.")
        }

        let mic = await ExportMediaIO.usableAudioURL(
            ProjectLayout.microphoneAudioURL(in: bundleURL)
        )
        let system = await ExportMediaIO.usableAudioURL(
            ProjectLayout.systemAudioURL(in: bundleURL)
        )
        var audioSources: [AudioSource] = []
        if let mic {
            audioSources.append(
                AudioSource(
                    url: mic,
                    offset: meta.captureTiming?.microphoneOffset ?? 0,
                    correction: meta.captureDiagnostics?.correction(for: .microphone)
                )
            )
        }
        if let system {
            audioSources.append(
                AudioSource(
                    url: system,
                    offset: meta.captureTiming?.systemAudioOffset ?? 0,
                    correction: meta.captureDiagnostics?.correction(for: .systemAudio)
                )
            )
        }

        report(progress, 0.2)
        try Task.checkCancellation()

        let canCopyDisplay = audioSources.isEmpty && isFullMediaSpan(
            start: span.sourceStart,
            end: span.sourceEnd,
            mediaDuration: displayDuration.seconds
        )
        if canCopyDisplay {
            try copyFile(displayURL, to: outputURL)
        } else {
            let composition = AVMutableComposition()
            try await insertVideo(
                from: displayAsset,
                sourceStart: span.sourceStart,
                sourceEnd: span.sourceEnd,
                at: 0,
                into: composition
            )
            for source in audioSources {
                try await insertAudio(
                    source,
                    mapper: mapper,
                    into: composition
                )
            }
            try await remux(composition, to: outputURL)
        }

        report(progress, 0.7)
        try Task.checkCancellation()

        let webcamURL = ProjectLayout.webcamVideoURL(in: bundleURL)
        var sidecar: URL?
        if FileManager.default.fileExists(atPath: webcamURL.path) {
            let destination = SourceFootageExport.webcamSidecarURL(beside: outputURL)
            try await exportWebcam(
                from: webcamURL,
                offset: meta.captureTiming?.webcamOffset ?? 0,
                mapper: mapper,
                to: destination
            )
            sidecar = destination
        }

        report(progress, 1)
        return SourceFootageExportResult(videoURL: outputURL, webcamURL: sidecar)
    }

    private struct AudioSource {
        var url: URL
        var offset: TimeInterval
        var correction: CaptureTrackCorrection?
    }

    private static func exportWebcam(
        from url: URL,
        offset: TimeInterval,
        mapper: ProjectTimeMapper,
        to destination: URL
    ) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0.02 else { return }
        guard let span = mapper.slices.first else { return }

        let sourceStart = max(0, span.sourceStart - offset)
        let sourceEnd = min(duration.seconds, span.sourceEnd - offset)
        guard sourceEnd - sourceStart > 0.02 else { return }

        let canCopy = abs(offset) < 0.000_5
            && isFullMediaSpan(
                start: sourceStart,
                end: sourceEnd,
                mediaDuration: duration.seconds
            )
        if canCopy {
            try copyFile(url, to: destination)
            return
        }

        let composition = AVMutableComposition()
        try await insertVideo(
            from: asset,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd,
            at: 0,
            into: composition
        )
        try await remux(composition, to: destination)
    }

    private static func insertVideo(
        from asset: AVURLAsset,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        at outputStart: TimeInterval,
        into composition: AVMutableComposition
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw OpenRecordError.io("The captured video has no video track.")
        }
        guard let dest = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw OpenRecordError.io("Could not create a video track for fast export.")
        }
        let trackRange = try await track.load(.timeRange)
        let timescale = max(try await track.load(.naturalTimeScale), 600)
        let start = CMTimeAdd(
            trackRange.start,
            CMTime(seconds: sourceStart, preferredTimescale: timescale)
        )
        let duration = CMTime(
            seconds: max(0, sourceEnd - sourceStart),
            preferredTimescale: timescale
        )
        do {
            try dest.insertTimeRange(
                CMTimeRange(start: start, duration: duration),
                of: track,
                at: CMTime(seconds: outputStart, preferredTimescale: timescale)
            )
        } catch {
            throw OpenRecordError.io(
                "Could not copy the captured video: \(error.localizedDescription)"
            )
        }
        dest.preferredTransform = try await track.load(.preferredTransform)
    }

    private static func insertAudio(
        _ source: AudioSource,
        mapper: ProjectTimeMapper,
        into composition: AVMutableComposition
    ) async throws {
        let asset = AVURLAsset(
            url: source.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = tracks.first else { return }
        let trackRange = (try? await track.load(.timeRange)) ?? .zero
        guard trackRange.start.isNumeric, trackRange.duration.isNumeric else { return }

        let sourceTimelineDuration: TimeInterval
        if let correction = source.correction,
           correction.sourceDuration > 0,
           correction.timelineDuration > 0
        {
            sourceTimelineDuration = correction.timelineDuration
        } else {
            sourceTimelineDuration = trackRange.duration.seconds
        }
        let placements = ExportAudioMux.placements(
            timeMapper: mapper,
            sourceOffset: source.offset,
            sourceTimelineDuration: sourceTimelineDuration,
            sourceMediaDuration: trackRange.duration.seconds,
            correction: source.correction
        )
        guard !placements.isEmpty else { return }
        guard let dest = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return
        }
        let timescale = max(trackRange.duration.timescale, 48_000)
        for placement in placements {
            let sourceTime = CMTimeAdd(
                trackRange.start,
                CMTime(
                    seconds: placement.localSourceStart,
                    preferredTimescale: timescale
                )
            )
            let insertDuration = CMTime(
                seconds: placement.localSourceDuration,
                preferredTimescale: timescale
            )
            do {
                try dest.insertTimeRange(
                    CMTimeRange(start: sourceTime, duration: insertDuration),
                    of: track,
                    at: CMTime(seconds: placement.outputStart, preferredTimescale: timescale)
                )
            } catch {
                throw OpenRecordError.io(
                    "Could not copy \(source.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func remux(_ composition: AVMutableComposition, to outputURL: URL) async throws {
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ), session.supportedFileTypes.contains(.mp4) else {
            throw OpenRecordError.io(
                "The captured footage could not be copied without re-encoding."
            )
        }
        let tempURL = try temporaryURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let box = SessionCancellationBox(session)
        try await withTaskCancellationHandler {
            try await session.export(to: tempURL, as: .mp4)
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        try install(tempURL, at: outputURL)
    }

    private static func isFullMediaSpan(
        start: TimeInterval,
        end: TimeInterval,
        mediaDuration: TimeInterval
    ) -> Bool {
        start <= 0.000_5 && abs(end - mediaDuration) <= 0.02
    }

    private static func copyFile(_ source: URL, to destination: URL) throws {
        let tempURL = try temporaryURL(for: destination)
        do {
            try FileManager.default.copyItem(at: source, to: tempURL)
            try install(tempURL, at: destination)
        } catch let error as OpenRecordError {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw OpenRecordError.io(
                "Could not copy \(source.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func temporaryURL(for outputURL: URL) throws -> URL {
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).fast-\(UUID().uuidString).mp4",
            isDirectory: false
        )
    }

    private static func install(_ temp: URL, at output: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: output.path) {
                _ = try fm.replaceItemAt(output, withItemAt: temp, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: temp, to: output)
            }
        } catch {
            throw OpenRecordError.io(
                "Could not write \(output.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private static func report(_ progress: ExportProgressHandler?, _ value: Double) {
        progress?(min(1, max(0, value)))
    }
}

private final class SessionCancellationBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) {
        self.session = session
    }
    func cancel() {
        session.cancelExport()
    }
}
