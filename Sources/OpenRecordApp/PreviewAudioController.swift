import AVFoundation
import Foundation
import OpenRecord

@MainActor
final class PreviewAudioController {
    private(set) var isAvailable = false
    private var player: AVPlayer?
    private var session: PreviewAudioMixer.Session?

    func shutdown() {
        player?.pause()
        player = nil
        session?.discardTemporaryFiles()
        session = nil
        isAvailable = false
    }

    func rebuild(
        projectURL: URL,
        meta: ProjectMeta,
        document: ProjectDocument,
        timeMapper: ProjectTimeMapper
    ) async {
        session?.discardTemporaryFiles()
        session = nil
        player?.pause()
        player = nil
        isAvailable = false

        guard let built = try? await PreviewAudioMixer.buildSession(
            bundleURL: projectURL,
            meta: meta,
            document: document,
            timeMapper: timeMapper
        ) else {
            return
        }

        session = built
        let item = AVPlayerItem(asset: built.composition)
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        let audioPlayer = AVPlayer(playerItem: item)
        audioPlayer.actionAtItemEnd = .pause
        player = audioPlayer
        isAvailable = true
    }

    func seek(to outputTime: TimeInterval) {
        guard isAvailable, let player else { return }
        let clamped = min(max(outputTime, 0), session?.duration ?? outputTime)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setPlaying(_ playing: Bool) {
        guard isAvailable, let player else { return }
        if playing {
            player.playImmediately(atRate: 1)
        } else {
            player.pause()
        }
    }
}
