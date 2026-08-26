import Foundation
import Testing
import OpenRecord
import Darwin

enum AudioPolishSmokeSuite {
    static func run() throws {
        let normalizationInput = Array(repeating: Float(0.1), count: 4_800)
        let normalized = AudioCleanupProcessor.processSamples(
            normalizationInput,
            settings: AudioCleanupSettings(normalizeEnabled: true, limiterEnabled: false),
            sampleRate: 48_000,
            channelCount: 1
        )
        let rms = sqrt(normalized.reduce(0.0) { $0 + Double($1 * $1) } / Double(normalized.count))
        guard abs(20 * log10(rms) + 16) < 0.05 else {
            throw OpenRecordError.io("Audio RMS normalization missed the -16 dBFS target")
        }

        let loud = [Float](repeating: 2, count: 512)
        let limited = AudioCleanupProcessor.processSamples(
            loud,
            settings: AudioCleanupSettings(compressorEnabled: true, limiterEnabled: true),
            sampleRate: 48_000,
            channelCount: 1
        )
        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        guard limited.allSatisfy({ abs($0) <= ceiling + 0.000_1 }) else {
            throw OpenRecordError.io("Audio limiter exceeded its -1 dBFS ceiling")
        }

        let faded = AudioCleanupProcessor.processSamples(
            [Float](repeating: 1, count: 100),
            settings: AudioCleanupSettings(
                limiterEnabled: false,
                fadeInDuration: 0.2,
                fadeOutDuration: 0.2
            ),
            sampleRate: 100,
            channelCount: 1,
            trackDuration: 1
        )
        guard faded.first == 0, faded.last == 0,
              faded[10] > 0.45, faded[10] < 0.55,
              faded[89] > 0.45, faded[89] < 0.55
        else {
            throw OpenRecordError.io("Audio fades were not track-relative")
        }
    }
}

@Test("RMS normalization targets -16 dBFS without exceeding peak headroom")
func rmsNormalizationTargetsSpeechLevel() {
    let input = Array(repeating: Float(0.1), count: 4_800)
    let gain = AudioCleanupProcessor.rmsNormalizationGain(for: input)
    let output = AudioCleanupProcessor.processSamples(
        input,
        settings: AudioCleanupSettings(normalizeEnabled: true, limiterEnabled: false),
        sampleRate: 48_000,
        channelCount: 1
    )
    let rms = sqrt(output.reduce(0.0) { $0 + Double($1 * $1) } / Double(output.count))
    #expect(abs(20 * log10(rms) - (-16)) < 0.05)
    #expect(gain > 1.5 && gain < 1.6)
    #expect(output.max() ?? 1 <= Float(pow(10.0, -1.0 / 20.0)) + 0.000_1)
}

@Test("speech compressor is deterministic and reduces sustained loud material")
func speechCompressorIsDeterministic() {
    let input = (0..<9_600).map { index in
        Float(index < 4_800 ? 0.05 : 0.8 * sin(Double(index) * 0.07))
    }
    let settings = AudioCleanupSettings(compressorEnabled: true, limiterEnabled: false)
    let first = AudioCleanupProcessor.processSamples(
        input, settings: settings, sampleRate: 48_000, channelCount: 1
    )
    let second = AudioCleanupProcessor.processSamples(
        input, settings: settings, sampleRate: 48_000, channelCount: 1
    )
    #expect(first == second)
    let inputPeak = input.map { abs($0) }.max() ?? 0
    let outputPeak = first.map { abs($0) }.max() ?? 0
    #expect(outputPeak < inputPeak)
}

@Test("limiter keeps peaks below the deterministic -1 dBFS ceiling")
func limiterKeepsPeakHeadroom() {
    let input = [Float](repeating: 2, count: 512)
    let output = AudioCleanupProcessor.processSamples(
        input,
        settings: AudioCleanupSettings(limiterEnabled: true),
        sampleRate: 48_000,
        channelCount: 1
    )
    let ceiling = Float(pow(10.0, -1.0 / 20.0))
    #expect(output.allSatisfy { abs($0) <= ceiling + 0.000_1 })
}

@Test("fades are relative to the complete track duration")
func fadesUseTrackRelativeTime() {
    let input = [Float](repeating: 1, count: 100)
    let output = AudioCleanupProcessor.processSamples(
        input,
        settings: AudioCleanupSettings(
            limiterEnabled: false,
            fadeInDuration: 0.2,
            fadeOutDuration: 0.2
        ),
        sampleRate: 100,
        channelCount: 1,
        trackDuration: 1
    )
    #expect(output[0] == 0)
    #expect(output[10] > 0.45 && output[10] < 0.55)
    #expect(output[20] > 0.99)
    #expect(output[89] > 0.45 && output[89] < 0.55)
    #expect(output[99] == 0)
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordAudioPolishTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunAudioPolishTests()
}

@_cdecl("OpenRecordRunAudioPolishTests")
func OpenRecordRunAudioPolishTests() {
    do {
        try AudioPolishSmokeSuite.run()
        fputs("OpenRecordTests: AudioPolishTests files=1 tests=4 failures=0\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: AudioPolishTests failures=1 error=\(error)\n", stderr)
        abort()
    }
}
#endif
