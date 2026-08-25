import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Realtime `AVAssetWriter` wrapper. All methods except `finish()` must run on `queue`.
final class SampleBufferWriter: @unchecked Sendable {
    let url: URL
    let queue: DispatchQueue
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var didStartSession = false
    private var requestedSessionTime: CMTime?
    private(set) var didAppend = false
    private(set) var appendError: Error?
    private(set) var droppedSamples = false
    var onFailure: (@Sendable (Error) -> Void)?

    static func video(url: URL, width: Int, height: Int, queue: DispatchQueue) throws -> SampleBufferWriter {
        let bitRate = min(80_000_000, max(10_000_000, width * height * 10))
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: CaptureMediaFormat.maxFrameRate,
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
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return try SampleBufferWriter(url: url, fileType: .mp4, input: input, queue: queue)
    }

    static func systemAudio(url: URL, queue: DispatchQueue) throws -> SampleBufferWriter {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: CaptureMediaFormat.systemAudioSampleRate,
            AVNumberOfChannelsKey: CaptureMediaFormat.systemAudioChannelCount,
            AVEncoderBitRateKey: CaptureMediaFormat.systemAudioBitRate,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return try SampleBufferWriter(url: url, fileType: .m4a, input: input, queue: queue)
    }

    private init(url: URL, fileType: AVFileType, input: AVAssetWriterInput, queue: DispatchQueue) throws {
        self.url = url
        self.queue = queue
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        self.input = input
        guard writer.canAdd(input) else {
            throw OpenRecordError.io("Could not add a media input for \(url.lastPathComponent).")
        }
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        if writer.status == .failed {
            return
        }
        if writer.status == .unknown {
            guard writer.startWriting() else {
                recordFailure(
                    writer.error ?? OpenRecordError.io("Could not start \(url.lastPathComponent).")
                )
                return
            }
        }
        if writer.status == .failed {
            return
        }
        if !didStartSession, writer.status == .writing {
            writer.startSession(atSourceTime: requestedSessionTime ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            didStartSession = true
        }
        guard didStartSession, writer.status == .writing else {
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedSamples = true
            return
        }
        if input.append(sampleBuffer) {
            didAppend = true
        } else {
            recordFailure(
                writer.error ?? OpenRecordError.io("Could not append to \(url.lastPathComponent).")
            )
        }
    }

    /// Configures the shared host-time origin used by the capture pipeline.
    /// Must be called on `queue`, before the first append.
    func startSession(at sourceTime: CMTime) {
        requestedSessionTime = sourceTime
    }

    private func recordFailure(_ error: Error) {
        guard appendError == nil else { return }
        appendError = error
        onFailure?(error)
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finishOnQueue(continuation: continuation)
            }
        }
    }

    private func finishOnQueue(continuation: CheckedContinuation<Void, Error>) {
        switch writer.status {
        case .writing:
            input.markAsFinished()
            writer.finishWriting {
                if self.writer.status == .failed {
                    continuation.resume(
                        throwing: self.writer.error
                            ?? OpenRecordError.io("Failed to finish \(self.url.lastPathComponent).")
                    )
                } else {
                    continuation.resume()
                }
            }
        case .failed:
            continuation.resume(
                throwing: writer.error ?? appendError ?? OpenRecordError.io("Media writer failed for \(url.lastPathComponent).")
            )
        case .unknown:
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            continuation.resume()
        default:
            if !didAppend {
                try? FileManager.default.removeItem(at: url)
            }
            continuation.resume()
        }
    }
}
