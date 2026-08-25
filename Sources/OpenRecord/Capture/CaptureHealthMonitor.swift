import AppKit
import Foundation

/// Lightweight runtime checks for failures that media callbacks do not report
/// early enough to protect an in-progress display recording.
final class CaptureHealthMonitor: @unchecked Sendable {
    enum Event: Sendable {
        case warning(CaptureWarningCode)
        case stop(CaptureWarningCode, String)
    }

    private let queue = DispatchQueue(
        label: "app.openrecord.desktop.capture.health",
        qos: .utility
    )
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var sleepObserver: NSObjectProtocol?
    private var projectURL: URL?
    private var capturesWebcam = false
    private var handler: (@Sendable (Event) -> Void)?
    private var emittedWarnings = Set<CaptureWarningCode>()
    private var minimumAvailableDiskBytes: Int64?

    /// Starts monitoring and returns the initial capacity snapshot. Critically
    /// low space is rejected before writers are opened.
    @discardableResult
    func start(
        projectURL: URL,
        capturesWebcam: Bool,
        handler: @escaping @Sendable (Event) -> Void
    ) throws -> Int64? {
        let initial = Self.availableDiskBytes(at: projectURL)
        if let initial,
           CaptureDiskSpacePolicy.level(availableBytes: initial) == .critical
        {
            throw OpenRecordError.io(
                "Not enough free disk space to start recording. Free at least 512 MB and try again."
            )
        }
        lock.withLock {
            self.projectURL = projectURL
            self.capturesWebcam = capturesWebcam
            self.handler = handler
            emittedWarnings.removeAll()
            minimumAvailableDiskBytes = initial
        }

        if let initial,
           CaptureDiskSpacePolicy.level(availableBytes: initial) == .low
        {
            emit(.warning(.lowDiskSpace), once: .lowDiskSpace)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.emit(
                .stop(
                    .displayInterrupted,
                    "The Mac went to sleep while recording. OpenRecord is finalizing the captured display video."
                ),
                once: .displayInterrupted
            )
        }
        return initial
    }

    func stop() -> Int64? {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        return lock.withLock {
            let minimum = minimumAvailableDiskBytes
            handler = nil
            projectURL = nil
            return minimum
        }
    }

    private func poll() {
        let snapshot = lock.withLock { (projectURL, capturesWebcam) }
        guard let projectURL = snapshot.0 else { return }
        if let available = Self.availableDiskBytes(at: projectURL) {
            lock.withLock {
                minimumAvailableDiskBytes = min(minimumAvailableDiskBytes ?? available, available)
            }
            switch CaptureDiskSpacePolicy.level(availableBytes: available) {
            case .sufficient:
                break
            case .low:
                emit(.warning(.lowDiskSpace), once: .lowDiskSpace)
            case .critical:
                emit(.warning(.lowDiskSpace), once: .lowDiskSpace)
                emit(
                    .stop(
                        .captureStoppedForLowDiskSpace,
                        "Disk space is nearly exhausted. OpenRecord stopped capture early to preserve the display recording."
                    ),
                    once: .captureStoppedForLowDiskSpace
                )
            }
        }

        if !CapturePermissions.isGranted(.screenRecording) {
            emit(
                .stop(
                    .screenPermissionLost,
                    "Screen Recording permission was revoked. OpenRecord is finalizing the captured display video."
                ),
                once: .screenPermissionLost
            )
        }
        if !CapturePermissions.isGranted(.microphone) {
            emit(.warning(.microphonePermissionLost), once: .microphonePermissionLost)
        }
        if !CapturePermissions.isGranted(.accessibility) {
            emit(.warning(.accessibilityPermissionLost), once: .accessibilityPermissionLost)
        }
        if snapshot.1, !CapturePermissions.isGranted(.camera) {
            emit(.warning(.cameraPermissionLost), once: .cameraPermissionLost)
        }
    }

    private func emit(_ event: Event, once warning: CaptureWarningCode) {
        let callback = lock.withLock { () -> (@Sendable (Event) -> Void)? in
            guard emittedWarnings.insert(warning).inserted else { return nil }
            return handler
        }
        callback?(event)
    }

    private static func availableDiskBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
