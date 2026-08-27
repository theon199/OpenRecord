import AVFoundation
import Foundation

/// Builds the same trimmed, speed-mapped microphone/system mix used by export
/// so editor preview playback can stay aligned with the output timeline.
public enum PreviewAudioMixer {
    public final class Session: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let audioMix: AVAudioMix
        public let duration: TimeInterval
        private var cleanedMicrophoneURL: URL?

        init(prepared: ExportAudioMux.Prepared, cleanedMicrophoneURL: URL?) {
            composition = prepared.composition
            audioMix = prepared.audioMix
            duration = prepared.duration
            self.cleanedMicrophoneURL = cleanedMicrophoneURL
        }

        public func discardTemporaryFiles() {
            if let cleanedMicrophoneURL {
                try? FileManager.default.removeItem(at: cleanedMicrophoneURL)
                self.cleanedMicrophoneURL = nil
            }
        }

        deinit {
            discardTemporaryFiles()
        }
    }

    public static func buildSession(
        bundleURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        timeMapper: ProjectTimeMapper
    ) async throws -> Session? {
        guard timeMapper.outputDuration > 0 else { return nil }

        let rawMic = await ExportMediaIO.usableAudioURL(
            ProjectLayout.microphoneAudioURL(in: bundleURL)
        )
        var cleanedMicrophoneURL: URL?
        let mic: URL?
        if let rawMic,
           document.audioCleanup.noiseGateEnabled
                || document.audioCleanup.normalizeEnabled
                || document.audioCleanup.deClickEnabled
                || document.audioCleanup.compressorEnabled
                || document.audioCleanup.limiterEnabled
                || document.audioCleanup.fadeInDuration > 0
                || document.audioCleanup.fadeOutDuration > 0
        {
            let cleanupURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openrecord-preview-mic-\(UUID().uuidString).m4a")
            let processed = try await AudioCleanupProcessor.prepareMicrophone(
                sourceURL: rawMic,
                settings: document.audioCleanup,
                outputURL: cleanupURL
            )
            if processed == cleanupURL {
                cleanedMicrophoneURL = cleanupURL
            }
            mic = processed
        } else {
            mic = rawMic
        }

        let system = await ExportMediaIO.usableAudioURL(
            ProjectLayout.systemAudioURL(in: bundleURL)
        )
        var sources: [ExportAudioMux.Source] = []
        if let mic {
            sources.append(
                ExportAudioMux.Source(
                    url: mic,
                    offset: meta.captureTiming?.microphoneOffset ?? 0,
                    gain: document.audioCleanup.microphoneGain,
                    correction: meta.captureDiagnostics?.correction(for: .microphone)
                )
            )
        }
        if let system {
            sources.append(
                ExportAudioMux.Source(
                    url: system,
                    offset: meta.captureTiming?.systemAudioOffset ?? 0,
                    gain: document.audioCleanup.systemGain,
                    correction: meta.captureDiagnostics?.correction(for: .systemAudio)
                )
            )
        }
        guard let prepared = try await ExportAudioMux.makeComposition(
            sources: sources,
            timeMapper: timeMapper,
            muteAudioWhenSpedUp: document.muteAudioWhenSpedUp
        ) else {
            cleanedMicrophoneURL.map { try? FileManager.default.removeItem(at: $0) }
            return nil
        }
        return Session(prepared: prepared, cleanedMicrophoneURL: cleanedMicrophoneURL)
    }
}
