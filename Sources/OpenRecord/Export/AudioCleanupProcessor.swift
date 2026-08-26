import AVFoundation
import CoreMedia
import Foundation

public enum AudioCleanupProcessor {
    /// Applies the same deterministic sample processing used by exported microphone audio.
    ///
    /// This seam intentionally works on interleaved, normalized Float samples so level
    /// processing can be tested without creating an AVAsset. `trackDuration` is optional
    /// for callers that do not have a timeline duration; fades then use the supplied
    /// `trackStart` and the samples' duration.
    public static func processSamples(
        _ samples: [Float],
        settings: AudioCleanupSettings,
        sampleRate: Double,
        channelCount: Int,
        trackStart: Double = 0,
        trackDuration: Double? = nil
    ) -> [Float] {
        let normalizedSettings = settings.normalized
        let channels = max(channelCount, 1)
        let safeSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let duration = trackDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? Double(samples.count / channels) / safeSampleRate
        let gain = normalizedSettings.normalizeEnabled
            ? rmsNormalizationGain(for: samples)
            : 1
        var processor = SampleProcessor(
            settings: normalizedSettings,
            normalizationGain: gain,
            channelCount: channels,
            sampleRate: safeSampleRate,
            trackStart: trackStart.isFinite ? trackStart : 0,
            trackDuration: duration
        )
        var result = samples
        processor.process(&result, relativeStart: 0)
        return result
    }

    /// Returns a gain that targets approximately -16 dBFS RMS while preserving -1 dBFS
    /// peak headroom. This is an RMS approximation of integrated LUFS suitable for speech
    /// cleanup and intentionally has no time-varying or platform-dependent behavior.
    public static func rmsNormalizationGain(
        for samples: [Float],
        targetRMSDB: Double = -16,
        peakHeadroomDB: Double = -1
    ) -> Float {
        let finiteSamples = samples.lazy.filter { $0.isFinite }
        var sumSquares = 0.0
        var count = 0
        var peak = 0.0
        for sample in finiteSamples {
            let value = Double(sample)
            sumSquares += value * value
            count += 1
            peak = max(peak, abs(value))
        }
        guard count > 0 else { return 1 }
        let rms = sqrt(sumSquares / Double(count))
        guard rms > 0, rms.isFinite else { return 1 }

        let targetRMS = pow(10, targetRMSDB / 20)
        let peakHeadroom = pow(10, peakHeadroomDB / 20)
        guard targetRMS.isFinite, peakHeadroom.isFinite, targetRMS > 0, peakHeadroom > 0 else {
            return 1
        }
        let rmsGain = targetRMS / rms
        let peakLimitedGain = peak > 0 ? peakHeadroom / peak : rmsGain
        return Float(min(max(min(rmsGain, peakLimitedGain), 0.000_1), 8))
    }

    static func prepareMicrophone(
        sourceURL: URL,
        settings: AudioCleanupSettings,
        outputURL: URL
    ) async throws -> URL {
        let settings = settings.normalized
        guard settings.noiseGateEnabled
                || settings.normalizeEnabled
                || settings.deClickEnabled
                || settings.compressorEnabled
                || settings.limiterEnabled
                || settings.fadeInDuration > 0
                || settings.fadeOutDuration > 0
        else {
            return sourceURL
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return sourceURL
        }
        let format = try await audioFormat(for: track)
        let trackRange = (try? await track.load(.timeRange)) ?? .zero
        let normalizationGain = settings.normalizeEnabled
            ? try scanRMSNormalizationGain(asset: asset, track: track, format: format)
            : 1

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
        writer.startSession(atSourceTime: trackRange.start.isNumeric ? trackRange.start : .zero)

        var processor = SampleProcessor(
            settings: settings,
            normalizationGain: normalizationGain,
            channelCount: format.channelCount,
            sampleRate: format.sampleRate,
            trackStart: trackRange.start.seconds,
            trackDuration: trackRange.duration.seconds
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

    private static func scanRMSNormalizationGain(
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

        var sumSquares = 0.0
        var count = 0
        var peak = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try withFloatSamples(in: sample) { samples in
                for value in samples {
                    guard value.isFinite else { continue }
                    let doubleValue = Double(value)
                    sumSquares += doubleValue * doubleValue
                    count += 1
                    peak = max(peak, abs(doubleValue))
                }
            }
        }
        guard reader.status != .failed else {
            throw OpenRecordError.io(
                "Microphone level analysis failed: "
                    + (reader.error?.localizedDescription ?? "unknown reader error")
            )
        }
        guard count > 0 else { return 1 }
        let rms = sqrt(sumSquares / Double(count))
        guard rms > 0, rms.isFinite else { return 1 }
        let targetRMS = pow(10.0, -16.0 / 20.0)
        let peakHeadroom = pow(10.0, -1.0 / 20.0)
        let rmsGain = targetRMS / rms
        let peakLimitedGain = peak > 0 ? peakHeadroom / peak : rmsGain
        return Float(min(max(min(rmsGain, peakLimitedGain), 0.000_1), 8))
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
        let compressorThreshold: Float
        let compressorRatio: Float
        let compressorAttackCoefficient: Float
        let compressorReleaseCoefficient: Float
        let limiterCeiling: Float
        let limiterReleaseCoefficient: Float
        let sampleRate: Double
        let trackStart: Double
        let trackDuration: Double
        var gateGain: Float = 1
        var compressorEnvelope: Float = 0
        var compressorGain: Float = 1
        var limiterGain: Float = 1
        var previous: [Float]
        var processedFrames = 0

        init(
            settings: AudioCleanupSettings,
            normalizationGain: Float,
            channelCount: Int,
            sampleRate: Double,
            trackStart: Double = 0,
            trackDuration: Double
        ) {
            self.settings = settings
            self.normalizationGain = normalizationGain
            self.channelCount = max(channelCount, 1)
            gateThreshold = Float(pow(10, settings.noiseGateThresholdDB / 20))
            gateOpenCoefficient = Float(min(1, 1 / max(sampleRate * 0.004, 1)))
            gateCloseCoefficient = Float(min(1, 1 / max(sampleRate * 0.035, 1)))
            // A modest speech compressor: -18 dBFS threshold, 3:1 ratio, with
            // deterministic attack/release smoothing. The linked-channel envelope
            // avoids stereo image movement on a two-channel microphone.
            compressorThreshold = Float(pow(10, -18.0 / 20.0))
            compressorRatio = 3
            compressorAttackCoefficient = Float(1 - exp(-1 / max(sampleRate * 0.005, 1)))
            compressorReleaseCoefficient = Float(1 - exp(-1 / max(sampleRate * 0.08, 1)))
            limiterCeiling = Float(pow(10, -1.0 / 20.0))
            limiterReleaseCoefficient = Float(1 - exp(-1 / max(sampleRate * 0.05, 1)))
            self.sampleRate = sampleRate
            self.trackStart = trackStart.isFinite ? trackStart : 0
            self.trackDuration = trackDuration.isFinite && trackDuration > 0
                ? trackDuration
                : 0
            previous = Array(repeating: 0, count: max(channelCount, 1))
        }

        mutating func process(_ sample: CMSampleBuffer) throws {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let relativeStart = presentationTime.isNumeric
                ? max(presentationTime.seconds - trackStart, 0)
                : Double(processedFrames) / max(sampleRate, 1)
            try AudioCleanupProcessor.withFloatSamples(in: sample) { samples in
                process(samples, relativeStart: relativeStart)
            }
        }

        mutating func process(_ samples: inout [Float], relativeStart: Double) {
            samples.withUnsafeMutableBufferPointer { buffer in
                process(buffer, relativeStart: relativeStart)
            }
        }

        private mutating func process(
            _ samples: UnsafeMutableBufferPointer<Float>,
            relativeStart: Double
        ) {
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

                var postGatePeak: Float = 0
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
                    samples[index] = value
                    postGatePeak = max(postGatePeak, abs(value))
                }

                var frameGain: Float = 1
                if settings.compressorEnabled {
                    let envelopeCoefficient = postGatePeak > compressorEnvelope
                        ? compressorAttackCoefficient
                        : compressorReleaseCoefficient
                    compressorEnvelope += (postGatePeak - compressorEnvelope) * envelopeCoefficient
                    let targetGain: Float
                    if compressorEnvelope > compressorThreshold {
                        let compressed = compressorThreshold
                            + (compressorEnvelope - compressorThreshold) / compressorRatio
                        targetGain = min(1, compressed / max(compressorEnvelope, 0.000_1))
                    } else {
                        targetGain = 1
                    }
                    let gainCoefficient = targetGain < compressorGain
                        ? compressorAttackCoefficient
                        : compressorReleaseCoefficient
                    compressorGain += (targetGain - compressorGain) * gainCoefficient
                    frameGain *= compressorGain
                } else {
                    compressorEnvelope = 0
                    compressorGain = 1
                }

                var compressedPeak = postGatePeak * frameGain
                if settings.limiterEnabled, compressedPeak > limiterCeiling {
                    // Instant attack guarantees the ceiling even for a one-sample
                    // transient; release is smoothed to avoid audible pumping.
                    let targetGain = limiterCeiling / max(compressedPeak, 0.000_1)
                    limiterGain = min(limiterGain, targetGain)
                    frameGain *= limiterGain
                    compressedPeak *= limiterGain
                } else if settings.limiterEnabled {
                    limiterGain += (1 - limiterGain) * limiterReleaseCoefficient
                    frameGain *= limiterGain
                    compressedPeak *= limiterGain
                } else {
                    limiterGain = 1
                }

                let frameTime = relativeStart + Double(frame) / max(Double(sampleRate), 1)
                let fadeGain = fadeGain(at: frameTime)
                frameGain *= fadeGain
                for channel in 0..<channelCount {
                    let index = base + channel
                    let value = samples[index] * frameGain
                    // Safety clipping is retained for malformed or unbounded input.
                    samples[index] = min(max(value, -0.99), 0.99)
                }
            }
            processedFrames += frames
        }

        private func fadeGain(at relativeTime: Double) -> Float {
            var gain = 1.0
            if settings.fadeInDuration > 0 {
                gain *= min(max(relativeTime / settings.fadeInDuration, 0), 1)
            }
            if settings.fadeOutDuration > 0, trackDuration > 0 {
                // Audio duration ends one sample period after its last frame.
                // Anchor the ramp to the last representable frame so the
                // exported track reaches silence deterministically.
                let lastFrameTime = max(trackDuration - 1 / max(sampleRate, 1), 0)
                let remaining = lastFrameTime - relativeTime
                gain *= min(max(remaining / settings.fadeOutDuration, 0), 1)
            }
            return Float(gain)
        }
    }
}

private final class AudioWriterFinishBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }
}
