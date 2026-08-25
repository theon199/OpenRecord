@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Captures the default camera into `recording/webcam.mp4`. Camera samples and
/// ScreenCaptureKit frames share the host clock; samples are buffered until the
/// first complete display frame establishes the recording origin.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.openrecord.desktop.capture.webcam")
    private var session: AVCaptureSession?
    private var writer: SampleBufferWriter?
    private var outputURL: URL?
    private var recordingOrigin: CMTime?
    private var pendingFrames: [CMSampleBuffer] = []
    private var failure: Error?
    private var notificationObservers: [NSObjectProtocol] = []

    private(set) var captureInfo: WebcamCaptureInfo?
    private(set) var firstFrameOffset: TimeInterval?
    var onFailure: (@Sendable (Error) -> Void)?

    var didAppend: Bool { writer?.didAppend == true }
    var appendError: Error? { failure ?? writer?.appendError }
    var droppedSamples: Bool { writer?.droppedSamples == true }

    func start(url: URL, mirror: Bool = true) async throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw OpenRecordError.io("No camera is available for webcam recording.")
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw OpenRecordError.io(
                "Could not open \(device.localizedName): \(error.localizedDescription)"
            )
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw OpenRecordError.io(
                "Could not add \(device.localizedName) to the webcam capture session."
            )
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw OpenRecordError.io("Could not add the webcam video output.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                    .localizedDescription ?? "unknown camera error"
                self?.recordFailure(
                    OpenRecordError.io("Webcam capture failed: \(detail)")
                )
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.recordFailure(
                    OpenRecordError.io("The webcam became unavailable during recording.")
                )
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: device,
                queue: nil
            ) { [weak self] _ in
                self?.recordFailure(
                    OpenRecordError.io("The webcam was disconnected during recording.")
                )
            },
        ]

        self.session = session
        outputURL = url
        captureInfo = WebcamCaptureInfo(deviceID: device.uniqueID, mirror: mirror)
        recordingOrigin = nil
        pendingFrames.removeAll(keepingCapacity: true)
        failure = nil
        firstFrameOffset = nil

        await withCheckedContinuation { continuation in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
        guard session.isRunning else {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.session = nil
                    for observer in self.notificationObservers {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    self.notificationObservers.removeAll(keepingCapacity: false)
                    self.pendingFrames.removeAll(keepingCapacity: false)
                    continuation.resume()
                }
            }
            throw OpenRecordError.io("The webcam capture session did not start.")
        }
    }

    func setRecordingStart(_ origin: CMTime) {
        queue.async { [weak self] in
            guard let self, self.recordingOrigin == nil else { return }
            self.recordingOrigin = origin
            let frames = self.pendingFrames
            self.pendingFrames.removeAll(keepingCapacity: true)
            for frame in frames {
                self.append(frame, origin: origin)
            }
        }
    }

    func stop() async throws {
        let currentWriter: SampleBufferWriter? = await withCheckedContinuation { continuation in
            queue.async {
                self.session?.stopRunning()
                self.session = nil
                for observer in self.notificationObservers {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.notificationObservers.removeAll(keepingCapacity: false)
                self.pendingFrames.removeAll(keepingCapacity: false)
                continuation.resume(returning: self.writer)
            }
        }
        try await currentWriter?.finish()
        if let failure {
            throw failure
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard failure == nil,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { return }

        guard let origin = recordingOrigin else {
            if pendingFrames.count < 180 {
                pendingFrames.append(sampleBuffer)
            }
            return
        }
        append(sampleBuffer, origin: origin)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, origin: CMTime) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric, pts >= origin else { return }

        if writer == nil {
            guard let outputURL, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            do {
                let writer = try SampleBufferWriter.video(
                    url: outputURL,
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer),
                    queue: queue
                )
                writer.onFailure = { [weak self] error in
                    self?.recordFailure(error)
                }
                self.writer = writer
            } catch {
                recordFailure(OpenRecordError.io(
                    "Could not create recording/webcam.mp4: \(error.localizedDescription)"
                ))
                return
            }
        }

        if firstFrameOffset == nil {
            firstFrameOffset = max(0, CMTimeGetSeconds(pts - origin))
        }
        writer?.startSession(at: origin)
        writer?.append(sampleBuffer)
    }

    private func recordFailure(_ error: Error) {
        queue.async { [weak self] in
            guard let self, self.failure == nil else { return }
            self.failure = error
            self.onFailure?(error)
        }
    }
}
