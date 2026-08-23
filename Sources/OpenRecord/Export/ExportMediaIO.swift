import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

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

    static func makeCIContext() -> (CIContext, CGColorSpace) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIContextOption: Any] = [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return (CIContext(mtlDevice: device, options: options), colorSpace)
        }
        return (CIContext(options: options), colorSpace)
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
final class ExportVideoReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let copyContext: CIContext
    private let colorSpace: CGColorSpace
    private var slotA: CVPixelBuffer?
    private var slotB: CVPixelBuffer?
    private var nextSlotIsA = true
    private var current: HeldFrame?
    private var peek: HeldFrame?
    private var firstPTS: CMTime?
    private var exhausted = false

    struct HeldFrame {
        var time: TimeInterval
        var image: CIImage
    }

    private(set) var sourceWidth = 0
    private(set) var sourceHeight = 0

    init(asset: AVAsset, track: AVAssetTrack, copyContext: CIContext, colorSpace: CGColorSpace) throws {

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
        self.copyContext = copyContext
        self.colorSpace = colorSpace
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
        current = try readCopied()
        guard current != nil else {
            exhausted = true
            throw OpenRecordError.io("recording/display.mp4 has no video frames to export.")
        }
        try fillPeek()
    }

    private func fillPeek() throws {
        if exhausted || peek != nil { return }
        if let frame = try readCopied() {
            peek = frame
        } else {
            exhausted = true
        }
    }

    private func readCopied() throws -> HeldFrame? {
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferIsValid(sample),
                  let src = CMSampleBufferGetImageBuffer(sample)
            else {
                continue
            }
            try ensureSlots(matching: src)
            guard let dest = nextSlotIsA ? slotA : slotB else {
                throw OpenRecordError.io("Export decoder lost its frame buffers.")
            }
            nextSlotIsA.toggle()

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstPTS == nil {
                firstPTS = pts
            }
            let origin = firstPTS ?? .zero
            let time = max(0, CMTimeGetSeconds(CMTimeSubtract(pts, origin)))

            copyContext.render(
                CIImage(cvPixelBuffer: src),
                to: dest,
                bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                colorSpace: colorSpace
            )
            return HeldFrame(time: time, image: CIImage(cvPixelBuffer: dest))
        }
        if reader.status == .failed {
            throw OpenRecordError.io(
                "Failed while decoding recording/display.mp4: \(reader.error?.localizedDescription ?? "unknown error")"
            )
        }
        return nil
    }

    private func ensureSlots(matching src: CVPixelBuffer) throws {
        if slotA != nil { return }
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width >= 2, height >= 2 else {
            throw OpenRecordError.io("recording/display.mp4 has an empty video frame size.")
        }
        sourceWidth = width
        sourceHeight = height
        slotA = try ExportMediaIO.makePixelBuffer(width: width, height: height)
        slotB = try ExportMediaIO.makePixelBuffer(width: width, height: height)
    }
}

enum ExportAudioMux {
    struct Source: Sendable {
        var url: URL
        /// Position of the first source sample relative to the first video frame.
        var offset: TimeInterval

        init(url: URL, offset: TimeInterval = 0) {
            self.url = url
            self.offset = offset.isFinite ? offset : 0
        }
    }

    static func makeComposition(
        sources: [URL],
        start: TimeInterval,
        duration: TimeInterval
    ) async throws -> AVMutableComposition? {
        try await makeComposition(
            sources: sources.map { Source(url: $0) },
            start: start,
            duration: duration
        )
    }

    static func makeComposition(
        sources: [Source],
        start: TimeInterval,
        duration: TimeInterval
    ) async throws -> AVMutableComposition? {
        guard !sources.isEmpty, duration > 0 else { return nil }

        let composition = AVMutableComposition()
        var inserted = false
        for source in sources {
            try Task.checkCancellation()
            let url = source.url
            let asset = AVURLAsset(url: url)
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            guard let sourceTrack = tracks.first else { continue }
            let trackRange = (try? await sourceTrack.load(.timeRange)) ?? .zero
            guard trackRange.start.isNumeric, trackRange.duration.isNumeric else { continue }

            let timescale = max(trackRange.duration.timescale, 48_000)
            guard let placement = ExportLayout.audioPlacement(
                trackOffset: source.offset,
                trimStart: start,
                exportDuration: duration,
                sourceDuration: trackRange.duration.seconds
            ) else { continue }
            let relativeSourceStart = CMTime(
                seconds: placement.sourceStart,
                preferredTimescale: timescale
            )
            let sourceStart = CMTimeAdd(trackRange.start, relativeSourceStart)
            let insertDuration = CMTime(
                seconds: placement.duration,
                preferredTimescale: timescale
            )
            guard insertDuration.seconds > 0.01 else { continue }
            let destination = CMTime(
                seconds: placement.destinationStart,
                preferredTimescale: timescale
            )

            guard let dest = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }
            do {
                try dest.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: insertDuration),
                    of: sourceTrack,
                    at: destination
                )
                inserted = true
            } catch {
                throw OpenRecordError.io(
                    "Could not mix \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return inserted ? composition : nil
    }

    static func append(
        to writer: AVAssetWriter,
        input: AVAssetWriterInput,
        composition: AVMutableComposition
    ) throws {
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
        mixOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(mixOutput) else {
            throw OpenRecordError.io("Could not decode mixed audio for export.")
        }
        reader.add(mixOutput)
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
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

enum ExportWriterFactory {
    static func makeVideoWriter(
        url: URL,
        width: Int,
        height: Int,
        fps: Int32
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw OpenRecordError.io("Could not create the export file: \(error.localizedDescription)")
        }
        writer.shouldOptimizeForNetworkUse = true

        let bitRate = min(50_000_000, max(6_000_000, width * height * (fps >= 60 ? 12 : 8)))
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: CaptureMediaFormat.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: encoderSpec,
        ]

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
