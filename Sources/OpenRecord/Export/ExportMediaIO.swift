import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

enum ExportRenderingBackend: String, Sendable, Equatable {
    case metal
    case softwareCoreImage
}

enum ExportRenderingPreference: Sendable, Equatable {
    case automatic
    case softwareOnly
}

struct ExportRenderContext {
    var context: CIContext
    var colorSpace: CGColorSpace
    var backend: ExportRenderingBackend
}

enum ExportMediaIO {
    static func requireDisplayVideo(in bundleURL: URL) throws -> URL {
        let url = ProjectLayout.displayVideoURL(in: bundleURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw OpenRecordError.io(
                "Missing recording/display.mp4. Export needs the captured screen video in this project."
            )
        }
        return url
    }

    static func usableAudioURL(_ url: URL) async -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0.02 else { return nil }
            return url
        } catch {
            return nil
        }
    }

    static func sourceAverageFPS(track: AVAssetTrack) async -> Double {
        if let nominal = try? await track.load(.nominalFrameRate), nominal > 1 {
            return Double(nominal)
        }
        if let minDuration = try? await track.load(.minFrameDuration),
           minDuration.isNumeric,
           minDuration.seconds > 0
        {
            return min(60, 1.0 / minDuration.seconds)
        }
        return 30
    }

    /// Core Image remains the compositor authority for preview/export parity,
    /// while its rendering backend uses Metal whenever the machine provides a
    /// device. The explicit software preference is the validation and recovery
    /// path used by tests and by callers that cannot create a Metal device.
    static func makeCIContext(
        preference: ExportRenderingPreference = .automatic
    ) -> ExportRenderContext {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIContextOption: Any] = [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            // Video frames are one-shot graphs. Retaining intermediates makes
            // long and 4K exports consume memory without improving reuse.
            .cacheIntermediates: false,
        ]
        if preference == .automatic, let device = MTLCreateSystemDefaultDevice() {
            return ExportRenderContext(
                context: CIContext(mtlDevice: device, options: options),
                colorSpace: colorSpace,
                backend: .metal
            )
        }
        var softwareOptions = options
        softwareOptions[.useSoftwareRenderer] = true
        return ExportRenderContext(
            context: CIContext(options: softwareOptions),
            colorSpace: colorSpace,
            backend: .softwareCoreImage
        )
    }

    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw OpenRecordError.io("Could not allocate a \(width)×\(height) pixel buffer for export.")
        }
        return buffer
    }
}

/// Sequential VFR decoder. Times are seconds from the first encoded frame (file origin).
///
/// AVAssetReader's pixel buffers are retained directly instead of being copied
/// through a second Core Image render. `current` and `peek` keep at most two
/// decoded frames alive, preserving the bounded-memory behavior while removing
/// a full-frame GPU/CPU copy from the export hot path.
final class ExportVideoReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: HeldFrame?
    private var peek: HeldFrame?
    private var firstPTS: CMTime?
    private var exhausted = false

    struct HeldFrame {
        var time: TimeInterval
        var pixelBuffer: CVPixelBuffer

        var image: CIImage {
            CIImage(cvPixelBuffer: pixelBuffer)
        }
    }

    private(set) var sourceWidth = 0
    private(set) var sourceHeight = 0

    init(asset: AVAsset, track: AVAssetTrack) throws {

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw OpenRecordError.io(
                "Could not read recording/display.mp4: \(error.localizedDescription)"
            )
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OpenRecordError.io("Could not decode recording/display.mp4.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OpenRecordError.io(
                "Could not start decoding recording/display.mp4: \(reader.error?.localizedDescription ?? "unknown error")"
            )
        }

        self.reader = reader
        self.output = output
        try prime()
    }

    func image(at time: TimeInterval) throws -> CIImage {
        while let peek, peek.time <= time {
            current = peek
            self.peek = nil
            try fillPeek()
        }
        guard let current else {
            throw OpenRecordError.io("recording/display.mp4 has no video frames to export.")
        }
        return current.image
    }

    private func prime() throws {
        current = try readFrame()
        guard current != nil else {
            exhausted = true
            throw OpenRecordError.io("recording/display.mp4 has no video frames to export.")
        }
        try fillPeek()
    }

    private func fillPeek() throws {
        if exhausted || peek != nil { return }
        if let frame = try readFrame() {
            peek = frame
        } else {
            exhausted = true
        }
    }

    private func readFrame() throws -> HeldFrame? {
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferIsValid(sample),
                  let src = CMSampleBufferGetImageBuffer(sample)
            else {
                continue
            }
            try recordDimensions(matching: src)

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstPTS == nil {
                firstPTS = pts
            }
            let origin = firstPTS ?? .zero
            let time = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, origin)))

            return HeldFrame(time: time, pixelBuffer: src)
        }
        if reader.status == .failed {
            throw OpenRecordError.io(
                "Failed while decoding recording/display.mp4: \(reader.error?.localizedDescription ?? "unknown error")"
            )
        }
        return nil
    }

    private func recordDimensions(matching src: CVPixelBuffer) throws {
        if sourceWidth > 0, sourceHeight > 0 { return }
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width >= 2, height >= 2 else {
            throw OpenRecordError.io("recording/display.mp4 has an empty video frame size.")
        }
        sourceWidth = width
        sourceHeight = height
    }
}

enum ExportAudioMux {
    struct Source: Sendable {
        var url: URL
        /// Position of the first source sample relative to the first video frame.
        var offset: TimeInterval
        var gain: Double
        var correction: CaptureTrackCorrection?

        init(
            url: URL,
            offset: TimeInterval = 0,
            gain: Double = 1,
            correction: CaptureTrackCorrection? = nil
        ) {
            self.url = url
            self.offset = offset.isFinite ? offset : 0
            self.gain = gain.isFinite ? min(max(gain, 0), 2) : 1
            self.correction = correction
        }
    }

    final class Prepared: @unchecked Sendable {
        let composition: AVMutableComposition
        let audioMix: AVAudioMix
        let duration: TimeInterval

        init(composition: AVMutableComposition, audioMix: AVAudioMix, duration: TimeInterval) {
            self.composition = composition
            self.audioMix = audioMix
            self.duration = duration
        }
    }

    static func makeComposition(
        sources: [URL],
        start: TimeInterval,
        duration: TimeInterval
    ) async throws -> Prepared? {
        try await makeComposition(
            sources: sources.map { Source(url: $0) },
            start: start,
            duration: duration,
            speedTimeline: SpeedTimeline(segments: []),
            muteAudioWhenSpedUp: false
        )
    }

    static func makeComposition(
        sources: [Source],
        start: TimeInterval,
        duration: TimeInterval,
        speedTimeline: SpeedTimeline,
        muteAudioWhenSpedUp: Bool
    ) async throws -> Prepared? {
        guard !sources.isEmpty, duration > 0 else { return nil }

        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var mixParameters: [AVAudioMixInputParameters] = []
        var inserted = false
        for source in sources {
            try Task.checkCancellation()
            let url = source.url
            let asset = AVURLAsset(url: url)
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let sourceTrack = tracks.first else { continue }
            let trackRange = (try? await sourceTrack.load(.timeRange)) ?? .zero
            guard trackRange.start.isNumeric, trackRange.duration.isNumeric else { continue }

            guard let dest = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            let timescale = max(trackRange.duration.timescale, 48_000)
            let sourceGlobalStart = source.offset
            let sourceTimelineDuration: TimeInterval
            if let correction = source.correction,
               correction.sourceDuration > 0,
               correction.timelineDuration > 0
            {
                sourceTimelineDuration = correction.timelineDuration
            } else {
                sourceTimelineDuration = trackRange.duration.seconds
            }
            let sourceGlobalEnd = source.offset + sourceTimelineDuration

            for slice in speedTimeline.slices(sourceStart: start, sourceEnd: start + duration) {
                if muteAudioWhenSpedUp, slice.rate > 1.000_001 { continue }
                let intersectionStart = max(slice.sourceStart, sourceGlobalStart)
                let intersectionEnd = min(slice.sourceEnd, sourceGlobalEnd)
                guard intersectionEnd - intersectionStart > 0.01 else { continue }

                let timelineLocalStart = intersectionStart - source.offset
                let timelineLocalEnd = intersectionEnd - source.offset
                let localStart = source.correction?.sourceTime(
                    forTimelineOffset: timelineLocalStart
                ) ?? timelineLocalStart
                let localEnd = source.correction?.sourceTime(
                    forTimelineOffset: timelineLocalEnd
                ) ?? timelineLocalEnd
                let localDuration = min(
                    max(0, localEnd - localStart),
                    max(0, trackRange.duration.seconds - localStart)
                )
                let timelineDuration = intersectionEnd - intersectionStart
                guard localDuration > 0, timelineDuration > 0 else { continue }
                let destinationSeconds = slice.outputStart
                    + (intersectionStart - slice.sourceStart) / slice.rate
                let destination = CMTime(
                    seconds: destinationSeconds,
                    preferredTimescale: timescale
                )
                let sourceTime = CMTimeAdd(
                    trackRange.start,
                    CMTime(seconds: localStart, preferredTimescale: timescale)
                )
                let insertDuration = CMTime(
                    seconds: localDuration,
                    preferredTimescale: timescale
                )

                do {
                    try dest.insertTimeRange(
                        CMTimeRange(start: sourceTime, duration: insertDuration),
                        of: sourceTrack,
                        at: destination
                    )
                    let outputDuration = CMTime(
                        seconds: timelineDuration / slice.rate,
                        preferredTimescale: timescale
                    )
                    dest.scaleTimeRange(
                        CMTimeRange(start: destination, duration: insertDuration),
                        toDuration: outputDuration
                    )
                    inserted = true
                } catch {
                    throw OpenRecordError.io(
                        "Could not mix \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }

            let parameters = AVMutableAudioMixInputParameters(track: dest)
            parameters.setVolume(Float(source.gain), at: .zero)
            mixParameters.append(parameters)
        }
        guard inserted else { return nil }
        audioMix.inputParameters = mixParameters
        let outputDuration = speedTimeline.outputDuration(
            sourceStart: start,
            sourceEnd: start + duration
        )
        return Prepared(
            composition: composition,
            audioMix: audioMix,
            duration: outputDuration
        )
    }

    static func append(
        to writer: AVAssetWriter,
        input: AVAssetWriterInput,
        prepared: Prepared
    ) throws {
        let composition = prepared.composition
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw OpenRecordError.io("Could not read mixed audio: \(error.localizedDescription)")
        }

        let mixOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: CaptureMediaFormat.systemAudioSampleRate,
                AVNumberOfChannelsKey: CaptureMediaFormat.systemAudioChannelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        mixOutput.audioMix = prepared.audioMix
        mixOutput.audioTimePitchAlgorithm = .spectral
        mixOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(mixOutput) else {
            throw OpenRecordError.io("Could not decode mixed audio for export.")
        }
        reader.add(mixOutput)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: prepared.duration, preferredTimescale: 48_000)
        )
        try Task.checkCancellation()
        guard reader.startReading() else {
            throw OpenRecordError.io(
                "Could not start reading mixed audio: \(reader.error?.localizedDescription ?? "unknown error")"
            )
        }

        while let sample = mixOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try waitUntilReady(input, writer: writer)
            guard input.append(sample) else {
                throw OpenRecordError.io(
                    writer.error?.localizedDescription ?? "Could not write mixed audio to the export file."
                )
            }
        }
        if reader.status == .failed {
            throw OpenRecordError.io(
                "Audio mix failed: \(reader.error?.localizedDescription ?? "unknown error")"
            )
        }
        try Task.checkCancellation()
    }

    static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw OpenRecordError.io(
                    writer.error?.localizedDescription ?? "Export writer failed."
                )
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if writer.status == .cancelled {
                throw OpenRecordError.io("Export writer stopped before all media was written.")
            }
            if writer.status == .completed {
                throw OpenRecordError.io("Export writer completed before all media was written.")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

enum ExportWriterFactory {
    static func makeVideoWriter(
        url: URL,
        width: Int,
        height: Int,
        fps: Int32,
        codec: VideoExportCodec = .h264
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: url,
                fileType: codec == .proRes422 ? .mov : .mp4
            )
        } catch {
            throw OpenRecordError.io("Could not create the export file: \(error.localizedDescription)")
        }
        writer.shouldOptimizeForNetworkUse = codec != .proRes422

        let bitRate = min(50_000_000, max(6_000_000, width * height * (fps >= 60 ? 12 : 8)))
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec != .proRes422 {
            compression[AVVideoAverageBitRateKey] = codec == .hevc
                ? max(4_000_000, bitRate * 2 / 3)
                : bitRate
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            if codec == .h264 {
                compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
        }
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        var settings: [String: Any] = [
            AVVideoCodecKey: codec == .h264
                ? AVVideoCodecType.h264
                : (codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.proRes422),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if codec != .proRes422 {
            settings[AVVideoCompressionPropertiesKey] = compression
            settings[AVVideoEncoderSpecificationKey] = encoderSpec
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity
        guard writer.canAdd(videoInput) else {
            throw OpenRecordError.io("Could not add a video track to the export file.")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        return (writer, videoInput, adaptor)
    }

    static func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: CaptureMediaFormat.systemAudioSampleRate,
            AVNumberOfChannelsKey: CaptureMediaFormat.systemAudioChannelCount,
            AVEncoderBitRateKey: CaptureMediaFormat.systemAudioBitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }
}
