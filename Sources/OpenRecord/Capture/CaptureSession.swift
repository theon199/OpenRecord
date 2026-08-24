import AppKit
import Foundation
import os
import ScreenCaptureKit

/// Coordinates one capture pipeline and makes finalization idempotent.
public final class CaptureSession: @unchecked Sendable {
    public private(set) var projectURL: URL?
    public let events: AsyncStream<CaptureEvent>

    public var state: CaptureSessionState {
        unfairLock.withLock { sessionState }
    }

    public var isRunning: Bool { state == .recording }

    private let unfairLock = OSAllocatedUnfairLock()
    private var pipeline: CapturePipeline?
    private var sessionState: CaptureSessionState = .idle
    private var stopTask: Task<CaptureStopResult, Error>?
    private var finalResult: CaptureStopResult?
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation

    public init() {
        var continuation: AsyncStream<CaptureEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    deinit { eventContinuation.finish() }

    public func start(target: CaptureTarget, projectURL: URL, capturesKeyboardShortcuts: Bool = true) async throws {
        try await CapturePermissions.ensureGranted()
        let reserved = unfairLock.withLock { () -> Bool in
            guard sessionState == .idle || sessionState == .finalized else { return false }
            sessionState = .starting
            self.projectURL = projectURL
            finalResult = nil
            stopTask = nil
            return true
        }
        guard reserved else { throw OpenRecordError.io("Capture is already running.") }
        let pipeline = CapturePipeline()
        unfairLock.withLock { self.pipeline = pipeline }
        pipeline.onUnexpectedStop = { [weak self] error in
            guard let self else { return }
            self.eventContinuation.yield(.stoppedUnexpectedly(error.localizedDescription))
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.stop(reason: .unexpected(error.localizedDescription))
            }
        }
        do {
            try await pipeline.start(target: target, projectURL: projectURL, capturesKeyboardShortcuts: capturesKeyboardShortcuts)
        } catch {
            unfairLock.withLock {
                if stopTask == nil {
                    sessionState = .idle
                }
                self.pipeline = nil
            }
            throw error
        }
        unfairLock.withLock {
            if stopTask == nil {
                sessionState = .recording
                self.pipeline = pipeline
            }
        }
        if state == .recording {
            eventContinuation.yield(.started(projectURL))
        }
    }

    @discardableResult
    public func stop(reason: CaptureStopReason = .manual) async throws -> CaptureStopResult {
        let task: Task<CaptureStopResult, Error> = unfairLock.withLock {
            if let stopTask { return stopTask }
            if let finalResult { return Task<CaptureStopResult, Error> { finalResult } }
            guard let pipeline else {
                return Task<CaptureStopResult, Error> { throw OpenRecordError.io("Capture is not running.") }
            }
            sessionState = .stopping
            let session = self
            let task = Task {
                session.eventContinuation.yield(.stopRequested(reason))
                do {
                    let result = try await pipeline.stop(reason: reason)
                    session.unfairLock.withLock {
                        session.sessionState = .finalized
                        session.pipeline = nil
                        session.finalResult = result
                    }
                    session.eventContinuation.yield(.finalized(result))
                    return result
                } catch {
                    session.unfairLock.withLock {
                        session.sessionState = .finalized
                        session.pipeline = nil
                    }
                    session.eventContinuation.yield(.finalizationFailed(error.localizedDescription))
                    throw error
                }
            }
            stopTask = task
            return task
        }
        return try await task.value
    }

    /// Displays first (main display leading), then on-screen windows, excluding this process.
    public static func availableTargets() async throws -> [CaptureSourceOption] {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw OpenRecordError.io("Could not list capture targets: \(error.localizedDescription)") }
        let ownIDs = Set([OpenRecordInfo.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 })
        struct RawDisplay: Sendable { var id: UInt32; var width: Int; var height: Int }
        struct RawWindow: Sendable { var id: UInt32; var title: String; var appName: String }
        let rawDisplays = content.displays.map { RawDisplay(id: $0.displayID, width: $0.width, height: $0.height) }
        var rawWindows: [RawWindow] = []
        for window in content.windows {
            guard let app = window.owningApplication, !ownIDs.contains(app.bundleIdentifier), window.frame.width >= 80, window.frame.height >= 60 else { continue }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let appName = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty, appName.isEmpty { continue }
            rawWindows.append(RawWindow(id: UInt32(window.windowID), title: title.isEmpty ? appName : title, appName: title.isEmpty ? "" : appName))
        }
        return await MainActor.run {
            let mainID = CGMainDisplayID()
            let displays = rawDisplays.sorted { a, b in
                if a.id == mainID { return true }; if b.id == mainID { return false }; return a.id < b.id
            }
            var options: [CaptureSourceOption] = []
            for (index, display) in displays.enumerated() {
                let name = Self.displayName(for: display.id) ?? (index == 0 ? "Built-in Display" : "Display \(index + 1)")
                options.append(CaptureSourceOption(target: .display(id: display.id), title: name, subtitle: "\(display.width)×\(display.height)"))
            }
            for window in rawWindows.sorted(by: { $0.appName == $1.appName ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }) {
                options.append(CaptureSourceOption(target: .window(id: window.id), title: window.title, subtitle: window.appName))
            }
            return options
        }
    }

    @MainActor private static func displayName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == displayID { return screen.localizedName }
        }
        return nil
    }
}

public struct CaptureSourceOption: Identifiable, Hashable, Sendable {
    public var target: CaptureTarget
    public var title: String
    public var subtitle: String
    public init(target: CaptureTarget, title: String, subtitle: String = "") { self.target = target; self.title = title; self.subtitle = subtitle }
    public var id: String { switch target { case .display(let id): return "display-\(id)"; case .window(let id): return "window-\(id)" } }
    public var isDisplay: Bool { if case .display = target { return true }; return false }
}
