import AVFoundation
import CoreMedia
import Foundation

enum AudioCleanupProcessor {
    static func prepareMicrophone(
        sourceURL: URL,
        settings: AudioCleanupSettings,
        outputURL: URL
    ) async throws -> URL {
        let settings = settings.normalized
        guard settings.noiseGateEnabled
                || settings.normalizeEnabled
                || settings.deClickEnabled
        else {
            return sourceURL
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return sourceURL
        }
        let format = try await audioFormat(for: track)
        let normalizationGain: Float
        if settings.normalizeEnabled {
            let peak = try scanPeak(asset: asset, track: track, format: format)
            // -1 dBFS leaves headroom for the system-audio mix.
            let target = Float(pow(10, -1.0 / 20.0))
            normalizationGain = peak > 0.000_1
                ? min(max(target / peak, 0.25), 8)
                : 1
        } else {
            normalizationGain = 1
        }

        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: linearPCMSettings(format: format)
        )
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else {
            throw OpenRecordError.io("Could not decode the microphone track for cleanup.")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: CaptureMediaFormat.microphoneAudioBitRate,
            ]
        )
        guard writer.canAdd(input) else {
            throw OpenRecordError.io("Could not encode the cleaned microphone track.")
        }
        writer.add(input)
        var completed = false
        defer {
            if !completed {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        guard reader.startReading() else {
            throw OpenRecordError.io(
                "Could not start decoding the microphone for cleanup: "
                    + (reader.error?.localizedDescription ?? "unknown reader error")
            )
        }
        guard writer.startWriting() else {
            throw OpenRecordError.io(
                "Could not start encoding the cleaned microphone: "
                    + (writer.error?.localizedDescription ?? "unknown writer error")
            )
        }
        let trackRange = (try? await track.load(.timeRange)) ?? .zero
        writer.startSession(atSourceTime: trackRange.start.isNumeric ? trackRange.start : .zero)

        var processor = SampleProcessor(
            settings: settings,
            normalizationGain: normalizationGain,
            channelCount: format.channelCount,
            sampleRate: format.sampleRate
        )
        var appended = false
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try processor.process(sample)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw OpenRecordError.io(
                        writer.error?.localizedDescription ?? "Microphone cleanup failed."
                    )
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.append(sample) else {
                throw OpenRecordError.io(
                    writer.error?.localizedDescription ?? "Could not write cleaned microphone audio."
                )
            }
            appended = true
        }

        guard reader.status != .failed else {
            throw OpenRecordError.io(
                reader.error?.localizedDescription ?? "Microphone cleanup decoding failed."
            )
        }
        guard appended else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return sourceURL
        }
        input.markAsFinished()
        try await finish(writer)
        completed = true
        return outputURL
    }

    private static func linearPCMSettings(
        format: (sampleRate: Double, channelCount: Int)
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static func scanPeak(
        asset: AVAsset,
        track: AVAssetTrack,
        format: (sampleRate: Double, channelCount: Int)
    ) throws -> Float {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: linearPCMSettings(format: format)
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OpenRecordError.io("Could not analyze the microphone level.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OpenRecordError.io(
                "Could not start microphone analysis: "
                    + (reader.error?.localizedDescription ?? "unknown reader error")
            )
        }

        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try withFloatSamples(in: sample) { samples in
                for value in samples {
                    peak = max(peak, abs(value))
                }
            }
        }
        guard reader.status != .failed else {
            throw OpenRecordError.io(
                "Microphone level analysis failed: "
                    + (reader.error?.localizedDescription ?? "unknown reader error")
            )
        }
        return peak
    }

    private static func audioFormat(for track: AVAssetTrack) async throws -> (
        sampleRate: Double,
        channelCount: Int
    ) {
        let descriptions = try await track.load(.formatDescriptions)
        if let description = descriptions.first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        {
            return (
                sampleRate: basic.mSampleRate > 0 ? basic.mSampleRate : 48_000,
                channelCount: min(max(Int(basic.mChannelsPerFrame), 1), 2)
            )
        }
        return (48_000, 1)
    }

    private static func withFloatSamples(
        in sample: CMSampleBuffer,
        _ body: (UnsafeMutableBufferPointer<Float>) throws -> Void
    ) throws {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer, totalLength >= MemoryLayout<Float>.size
        else {
            throw OpenRecordError.io("Could not access decoded microphone samples.")
        }
        try pointer.withMemoryRebound(
            to: Float.self,
            capacity: totalLength / MemoryLayout<Float>.size
        ) { values in
            try body(
                UnsafeMutableBufferPointer(
                    start: values,
                    count: totalLength / MemoryLayout<Float>.size
                )
            )
        }
    }

    private static func finish(_ writer: AVAssetWriter) async throws {
        let box = AudioWriterFinishBox(writer: writer)
        try await withCheckedThrowingContinuation { continuation in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: OpenRecordError.io(
                            box.writer.error?.localizedDescription
                                ?? "Microphone cleanup did not finish."
                        )
                    )
                }
            }
        }
    }

    private struct SampleProcessor {
        let settings: AudioCleanupSettings
        let normalizationGain: Float
        let channelCount: Int
        let gateThreshold: Float
        let gateOpenCoefficient: Float
        let gateCloseCoefficient: Float
        var gateGain: Float = 1
        var previous: [Float]

        init(
            settings: AudioCleanupSettings,
            normalizationGain: Float,
            channelCount: Int,
            sampleRate: Double
        ) {
            self.settings = settings
            self.normalizationGain = normalizationGain
            self.channelCount = max(channelCount, 1)
            gateThreshold = Float(pow(10, settings.noiseGateThresholdDB / 20))
            gateOpenCoefficient = Float(min(1, 1 / max(sampleRate * 0.004, 1)))
            gateCloseCoefficient = Float(min(1, 1 / max(sampleRate * 0.035, 1)))
            previous = Array(repeating: 0, count: max(channelCount, 1))
        }

        mutating func process(_ sample: CMSampleBuffer) throws {
            try AudioCleanupProcessor.withFloatSamples(in: sample) { samples in
                let frames = samples.count / channelCount
                for frame in 0..<frames {
                    let base = frame * channelCount
                    var framePeak: Float = 0
                    for channel in 0..<channelCount {
                        framePeak = max(framePeak, abs(samples[base + channel]))
                    }

                    if settings.noiseGateEnabled {
                        let target: Float = framePeak >= gateThreshold ? 1 : 0
                        let coefficient = target > gateGain
                            ? gateOpenCoefficient
                            : gateCloseCoefficient
                        gateGain += (target - gateGain) * coefficient
                    } else {
                        gateGain = 1
                    }

                    for channel in 0..<channelCount {
                        let index = base + channel
                        var value = samples[index]
                        if settings.deClickEnabled,
                           abs(value - previous[channel]) > 0.7,
                           abs(value) > 0.72,
                           abs(previous[channel]) < 0.3
                        {
                            value = previous[channel]
                        }
                        previous[channel] = value
                        value *= normalizationGain * gateGain
                        samples[index] = min(max(value, -0.99), 0.99)
                    }
                }
            }
        }
    }
}

private final class AudioWriterFinishBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }
}
