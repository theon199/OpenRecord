import AVFoundation
import Foundation
import QuartzCore

final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let writeLock = NSLock()
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private(set) var firstBufferHostTime: CFTimeInterval?
    private(set) var writeError: Error?
    var onFailure: (@Sendable (Error) -> Void)?

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
                if self.writeError == nil {
                    self.writeError = error
                    self.onFailure?(error)
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            self.file = nil
            throw error
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let error = OpenRecordError.io(
                "The microphone input changed or became unavailable during recording."
            )
            self.writeLock.withLock {
                if self.writeError == nil { self.writeError = error }
            }
            self.onFailure?(error)
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
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
