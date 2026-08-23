import AVFoundation
import Foundation
import QuartzCore

final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let writeLock = NSLock()
    private var tapInstalled = false
    private(set) var firstBufferHostTime: CFTimeInterval?
    private(set) var writeError: Error?

    func start(url: URL) throws {
        firstBufferHostTime = nil
        writeError = nil
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CapturePermissionError(
                kind: .microphone,
                message: CapturePermissions.denialMessage(for: .microphone)
            )
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: CaptureMediaFormat.microphoneAudioBitRate,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.file = file

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, buffer.frameLength > 0 else { return }
            self.writeLock.lock()
            defer { self.writeLock.unlock() }
            if self.firstBufferHostTime == nil {
                // AVAudioEngine's host time uses the same mach clock as
                // ScreenCaptureKit/CACurrentMediaTime.
                let hostTime = when.hostTime
                self.firstBufferHostTime = hostTime == 0
                    ? CACurrentMediaTime()
                    : AVAudioTime.seconds(forHostTime: hostTime)
            }
            do {
                try self.file?.write(from: buffer)
            } catch {
                if self.writeError == nil { self.writeError = error }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        writeLock.lock()
        file = nil
        writeLock.unlock()
    }
}
