import AppKit
import Foundation
import os
import ScreenCaptureKit

/// Writes capture artifacts under a `.openrecord` project URL.
///
/// `start` requires Screen Recording, Microphone, and Accessibility. Accessibility
/// denial is an error — the session will not record an empty cursor track.
public final class CaptureSession: @unchecked Sendable {
    public private(set) var projectURL: URL?
    public private(set) var isRunning = false

    private let unfairLock = OSAllocatedUnfairLock()
    private var pipeline: CapturePipeline?
    private var isStarting = false

    public init() {}

    public func start(target: CaptureTarget, projectURL: URL) async throws {
        try await CapturePermissions.ensureGranted()

        let reserved = unfairLock.withLock { () -> Bool in
            if isRunning || isStarting {
                return false
            }
            isStarting = true
            self.projectURL = projectURL
            return true
        }
        guard reserved else {
            throw OpenRecordError.io("Capture is already running.")
        }

        let pipeline = CapturePipeline()
        do {
            try await pipeline.start(target: target, projectURL: projectURL)
        } catch {
            unfairLock.withLock {
                isStarting = false
                self.pipeline = nil
            }
            throw error
        }

        unfairLock.withLock {
            isStarting = false
            isRunning = true
            self.pipeline = pipeline
        }
    }

    public func stop() async throws {
        let pipeline = unfairLock.withLock { () -> CapturePipeline? in
            guard isRunning else { return nil }
            isRunning = false
            let current = self.pipeline
            self.pipeline = nil
            return current
        }
        guard let pipeline else {
            throw OpenRecordError.io("Capture is not running.")
        }

        var stopError: Error?
        do {
            try await pipeline.stop()
        } catch {
            stopError = error
        }

        do {
            try pipeline.writeSidecars()
        } catch {
            stopError = stopError ?? error
        }

        if let stopError {
            throw stopError
        }
    }

    /// Displays first (main display leading), then on-screen windows, excluding this process.
    public static func availableTargets() async throws -> [CaptureSourceOption] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw OpenRecordError.io("Could not list capture targets: \(error.localizedDescription)")
        }

        let ownIDs = Set(
            [OpenRecordInfo.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 }
        )

        struct RawDisplay: Sendable {
            var id: UInt32
            var width: Int
            var height: Int
        }
        struct RawWindow: Sendable {
            var id: UInt32
            var title: String
            var appName: String
        }

        let rawDisplays: [RawDisplay] = content.displays.map {
            RawDisplay(id: $0.displayID, width: $0.width, height: $0.height)
        }
        var rawWindows: [RawWindow] = []
        rawWindows.reserveCapacity(content.windows.count)
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            if ownIDs.contains(app.bundleIdentifier) { continue }
            guard window.frame.width >= 80, window.frame.height >= 60 else { continue }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let appName = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty, appName.isEmpty { continue }
            rawWindows.append(
                RawWindow(
                    id: UInt32(window.windowID),
                    title: title.isEmpty ? appName : title,
                    appName: title.isEmpty ? "" : appName
                )
            )
        }

        return await MainActor.run {
            let mainID = CGMainDisplayID()
            let displays = rawDisplays.sorted { a, b in
                if a.id == mainID { return true }
                if b.id == mainID { return false }
                return a.id < b.id
            }

            var options: [CaptureSourceOption] = []
            options.reserveCapacity(displays.count + rawWindows.count)
            for (index, display) in displays.enumerated() {
                let name = Self.displayName(for: display.id) ?? (index == 0 ? "Built-in Display" : "Display \(index + 1)")
                options.append(
                    CaptureSourceOption(
                        target: .display(id: display.id),
                        title: name,
                        subtitle: "\(display.width)×\(display.height)"
                    )
                )
            }

            let windows = rawWindows.sorted {
                if $0.appName != $1.appName {
                    return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            for window in windows {
                options.append(
                    CaptureSourceOption(
                        target: .window(id: window.id),
                        title: window.title,
                        subtitle: window.appName
                    )
                )
            }
            return options
        }
    }

    @MainActor
    private static func displayName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return nil
    }
}

/// One row in the recorder source picker (`CaptureSession.availableTargets()`).
public struct CaptureSourceOption: Identifiable, Hashable, Sendable {
    public var target: CaptureTarget
    public var title: String
    public var subtitle: String

    public init(target: CaptureTarget, title: String, subtitle: String = "") {
        self.target = target
        self.title = title
        self.subtitle = subtitle
    }

    public var id: String {
        switch target {
        case .display(let id):
            return "display-\(id)"
        case .window(let id):
            return "window-\(id)"
        }
    }

    public var isDisplay: Bool {
        if case .display = target { return true }
        return false
    }
}
