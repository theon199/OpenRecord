import AVFoundation
import Foundation
import QuartzCore

final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let writeLock = NSLock()
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var isMuted = false
    private(set) var firstBufferHostTime: CFTimeInterval?
    private(set) var writeError: Error?
    var onFailure: (@Sendable (Error) -> Void)?

    func setMuted(_ muted: Bool) {
        writeLock.lock()
        isMuted = muted
        writeLock.unlock()
    }

    func start(url: URL) throws {
        firstBufferHostTime = nil
        writeError = nil
        writeLock.lock()
        isMuted = false
        writeLock.unlock()
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
            let sample = self.isMuted ? Self.silentBuffer(matching: buffer) : buffer
            do {
                try self.file?.write(from: sample)
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
        isMuted = false
        writeLock.unlock()
    }

    deinit {
        stop()
    }

    /// Zero-filled copy with the same format and frame length so muting does
    /// not shorten the microphone timeline.
    static func silentBuffer(matching buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let silent = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return buffer
        }
        silent.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        if let floatChannelData = silent.floatChannelData {
            for channel in 0..<channelCount {
                memset(floatChannelData[channel], 0, frameLength * MemoryLayout<Float>.size)
            }
        } else if let int16ChannelData = silent.int16ChannelData {
            for channel in 0..<channelCount {
                memset(int16ChannelData[channel], 0, frameLength * MemoryLayout<Int16>.size)
            }
        } else if let int32ChannelData = silent.int32ChannelData {
            for channel in 0..<channelCount {
                memset(int32ChannelData[channel], 0, frameLength * MemoryLayout<Int32>.size)
            }
        }
        return silent
    }
}
