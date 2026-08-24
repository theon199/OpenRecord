import AppKit
import Foundation
import OpenRecord
import SwiftUI

private enum PendingEditorTransition {
    case close
    case open(URL, generateAutoZooms: Bool)
    case delete(URL)
}

private struct PendingDegradedOpen {
    var url: URL
    var generateAutoZooms: Bool
}

private enum TerminationCaptureOutcome: Sendable {
    case stopped(CaptureStopResult)
    case failed(String)
    case timedOut
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: sending Value) {
        let continuation = lock.withLock {
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume(returning: value)
    }
}

@MainActor
@Observable
final class AppModel {
    var library: ProjectLibrary
    var projects: [LibraryItem] = []
    var permissionGranted: [CapturePermissionKind: Bool] = [:]
    var errorMessage: String?
    var selectedProjectURL: URL?
    var editor: EditorSession?
    var isRecorderPresented = false
    var isSettingsPresented = false
    var captureSources: [CaptureSourceOption] = []
    var selectedSourceID: String?
    var countdownRemaining: Int?
    var isRecording = false
    var recordedDuration: TimeInterval = 0
    var isProcessingCapture = false
    var isLoadingSources = false
    var degradedOpenMessage: String?
    var saveFailureMessage: String?

    var allPermissionsGranted: Bool {
        CapturePermissionKind.allCases.allSatisfy { permissionGranted[$0] == true }
    }

    var selectedSource: CaptureSourceOption? {
        captureSources.first { $0.id == selectedSourceID }
    }

    var displaySources: [CaptureSourceOption] {
        captureSources.filter(\.isDisplay)
    }

    var windowSources: [CaptureSourceOption] {
        captureSources.filter { !$0.isDisplay }
    }

    private let capture = CaptureSession()
    private var recordingURL: URL?
    private var countdownTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var didStart = false
    private var openGeneration = 0
    private var captureEventTask: Task<Void, Never>?
    private var pendingDegradedOpen: PendingDegradedOpen?
    private var pendingEditorTransition: PendingEditorTransition?

    init() {
        library = .resolved()
        refreshPermissions()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshPermissions()
        refreshProjects()
        installRecordShortcut()
        observeCaptureEvents()
        AppDelegate.terminationHandler = { [weak self] in
            await self?.prepareForTermination() ?? true
        }
    }

    func refreshPermissions() {
        var map: [CapturePermissionKind: Bool] = [:]
        for kind in CapturePermissionKind.allCases {
            map[kind] = CapturePermissions.isGranted(kind)
        }
        permissionGranted = map
    }

    func requestPermission(_ kind: CapturePermissionKind) async {
        _ = await CapturePermissions.request(kind)
        refreshPermissions()
        if permissionGranted[kind] != true {
            CapturePermissions.openSystemSettings(for: kind)
        }
    }

    func refreshProjects() {
        do {
            try library.ensureRootExists()
            projects = try library.list().map(LibraryItem.from)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ url: URL) {
        do {
            try library.reveal(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProject(_ url: URL) {
        Task { await requestEditorTransition(.delete(url.standardizedFileURL)) }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Projects are saved directly in this folder as .openrecord bundles. Point it at Dropbox, Drive, or iCloud to sync."
        panel.directoryURL = library.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectLibrary.persistRootURL(url)
            library = .resolved()
            try library.ensureRootExists()
            refreshProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetLibraryFolder() {
        ProjectLibrary.clearPersistedRootURL()
        library = .resolved()
        refreshProjects()
    }

    func openProject(_ url: URL, generateAutoZooms: Bool = false) async {
        await requestEditorTransition(.open(url, generateAutoZooms: generateAutoZooms))
    }

    private func performOpenProject(
        _ url: URL,
        generateAutoZooms: Bool,
        allowDegradedTelemetry: Bool = false
    ) async {
        openGeneration += 1
        let generation = openGeneration
        do {
            let opened = try library.open(url: url)
            let session = try await EditorSession.load(
                opened: opened,
                library: library,
                allowDegradedTelemetry: allowDegradedTelemetry
            )
            guard generation == openGeneration else {
                session.shutdown()
                return
            }
            if generateAutoZooms {
                try await session.applyAutoZoomsAndSave()
            }
            guard generation == openGeneration else {
                session.shutdown()
                return
            }
            editor?.shutdown()
            editor = session
            selectedProjectURL = url
            pendingDegradedOpen = nil
            degradedOpenMessage = nil
        } catch let issue as EditorTelemetryLoadIssue {
            if generation == openGeneration {
                pendingDegradedOpen = PendingDegradedOpen(
                    url: url,
                    generateAutoZooms: generateAutoZooms
                )
                degradedOpenMessage = issue.localizedDescription
                selectedProjectURL = editor?.projectURL
            }
        } catch {
            if generation == openGeneration {
                errorMessage = error.localizedDescription
                selectedProjectURL = editor?.projectURL
            }
        }
    }

    func closeEditor() {
        Task { await requestEditorTransition(.close) }
    }

    func selectProject(_ url: URL?) {
        guard let url else {
            closeEditor()
            return
        }
        if url == editor?.projectURL { return }
        Task { await openProject(url) }
    }

    func openDegradedProjectAnyway() {
        guard let pending = pendingDegradedOpen else { return }
        Task {
            await performOpenProject(
                pending.url,
                generateAutoZooms: pending.generateAutoZooms,
                allowDegradedTelemetry: true
            )
        }
    }

    func cancelDegradedOpen() {
        pendingDegradedOpen = nil
        degradedOpenMessage = nil
        selectedProjectURL = editor?.projectURL
    }

    func retryPendingSave() {
        guard let transition = pendingEditorTransition else { return }
        Task {
            do {
                try await editor?.flushSave()
                pendingEditorTransition = nil
                saveFailureMessage = nil
                await performEditorTransition(transition)
            } catch {
                saveFailureMessage = error.localizedDescription
            }
        }
    }

    func saveCopyAndContinue() {
        guard let transition = pendingEditorTransition, let editor else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(editor.title) Copy.\(ProjectLayout.bundleExtension)"
        panel.title = "Save a Copy"
        panel.prompt = "Save Copy"
        panel.message = "Saves the complete recording bundle with your current edits."
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() == ProjectLayout.bundleExtension,
           destination.pathExtension != ProjectLayout.bundleExtension
        {
            destination.deletePathExtension()
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        } else if destination.pathExtension != ProjectLayout.bundleExtension {
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        }
        Task {
            do {
                _ = try await editor.saveCopy(to: destination)
                await editor.discardUnsavedChanges()
                pendingEditorTransition = nil
                saveFailureMessage = nil
                await performEditorTransition(transition)
            } catch {
                saveFailureMessage = error.localizedDescription
            }
        }
    }

    func discardChangesAndContinue() {
        guard let transition = pendingEditorTransition else { return }
        let editor = editor
        pendingEditorTransition = nil
        saveFailureMessage = nil
        Task {
            await editor?.discardUnsavedChanges()
            await performEditorTransition(transition)
        }
    }

    func cancelPendingEditorTransition() {
        pendingEditorTransition = nil
        saveFailureMessage = nil
        selectedProjectURL = editor?.projectURL
    }

    private func requestEditorTransition(_ transition: PendingEditorTransition) async {
        if let editor, editor.hasUnsavedChanges {
            do {
                try await editor.flushSave()
            } catch {
                pendingEditorTransition = transition
                saveFailureMessage = error.localizedDescription
                selectedProjectURL = editor.projectURL
                return
            }
        }
        await performEditorTransition(transition)
    }

    private func performEditorTransition(_ transition: PendingEditorTransition) async {
        switch transition {
        case .close:
            openGeneration += 1
            editor?.shutdown()
            editor = nil
            selectedProjectURL = nil
        case .open(let url, let generateAutoZooms):
            await performOpenProject(url, generateAutoZooms: generateAutoZooms)
        case .delete(let url):
            do {
                if editor?.projectURL.standardizedFileURL == url {
                    openGeneration += 1
                    editor?.shutdown()
                    editor = nil
                    selectedProjectURL = nil
                }
                try library.delete(url)
                refreshProjects()
            } catch {
                errorMessage = error.localizedDescription
                refreshProjects()
            }
        }
    }

    func presentRecorder(autoStart: Bool) async {
        showMainWindow()
        refreshPermissions()
        guard allPermissionsGranted else { return }
        guard !isRecording, !isProcessingCapture else { return }
        isRecorderPresented = true
        await reloadCaptureSources()
        if autoStart {
            await startCountdownAndRecord()
        }
    }

    func reloadCaptureSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
        do {
            let sources = try await CaptureSession.availableTargets()
            captureSources = sources
            if selectedSourceID == nil || !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = sources.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startCountdownAndRecord() async {
        guard !isRecording, !isProcessingCapture else { return }
        guard countdownTask == nil else { return }
        guard selectedSource != nil else {
            errorMessage = "Pick a display or window to record."
            return
        }

        countdownTask = Task { @MainActor in
            for value in [3, 2, 1] {
                countdownRemaining = value
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    countdownRemaining = nil
                    return
                }
            }
            countdownRemaining = nil
            await startCapture()
        }
        await countdownTask?.value
        countdownTask = nil
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
    }

    func stopRecording() async {
        await finishRecording(reason: .manual)
    }

    private func finishRecording(reason: CaptureStopReason) async {
        cancelCountdown()
        elapsedTask?.cancel()
        elapsedTask = nil
        guard isRecording || recordingURL != nil else { return }
        isRecording = false
        isProcessingCapture = true
        defer { isProcessingCapture = false }

        let url = recordingURL
        do {
            let result = try await capture.stop(reason: reason)
            recordingURL = nil
            if let finalizationError = result.finalizationError {
                errorMessage = finalizationError
            }
            isRecorderPresented = false
            showMainWindow()
            if result.hasUsableVideo {
                await openProject(result.projectURL, generateAutoZooms: true)
                refreshProjects()
            } else if let url {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            recordingURL = nil
            errorMessage = error.localizedDescription
            isRecorderPresented = false
            if let url {
                // Capture finalization only throws when the display track is
                // unusable. This exact, newly-created bundle is safe to remove.
                try? FileManager.default.removeItem(at: url)
                refreshProjects()
            }
        }
    }

    func handleRecordShortcut() async {
        if isProcessingCapture { return }
        if isRecording {
            await stopRecording()
            return
        }
        if countdownTask != nil {
            cancelCountdown()
            return
        }
        refreshPermissions()
        if !allPermissionsGranted {
            showMainWindow()
            return
        }
        await presentRecorder(autoStart: true)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.orderFrontMainWindows()
    }

    func prepareForTermination() async -> Bool {
        cancelCountdown()
        if recordingURL != nil || isRecording || isProcessingCapture {
            elapsedTask?.cancel()
            elapsedTask = nil
            isRecording = false
            let url = recordingURL
            let outcome = await stopCaptureForTermination()
            switch outcome {
            case .stopped(let result):
                recordingURL = nil
                if !result.hasUsableVideo, let url {
                    try? FileManager.default.removeItem(at: url)
                }
            case .failed:
                recordingURL = nil
                if let url {
                    try? FileManager.default.removeItem(at: url)
                }
            case .timedOut:
                if let url {
                    try? CaptureRecovery.markFinalizationTimedOut(at: url)
                }
            }
        }

        guard let editor, editor.hasUnsavedChanges else { return true }
        while editor.hasUnsavedChanges {
            do {
                try await editor.flushSave()
                return true
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "OpenRecord Couldn’t Save Your Changes"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Save a Copy…")
                alert.addButton(withTitle: "Discard Changes")
                alert.addButton(withTitle: "Cancel Quit")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    continue
                case .alertSecondButtonReturn:
                    if await saveCopyForTermination(editor) {
                        await editor.discardUnsavedChanges()
                        return true
                    }
                case .alertThirdButtonReturn:
                    await editor.discardUnsavedChanges()
                    return true
                default:
                    return false
                }
            }
        }
        return true
    }

    private func stopCaptureForTermination() async -> TerminationCaptureOutcome {
        await withCheckedContinuation { continuation in
            let gate = OneShotContinuation(continuation)
            Task { @MainActor [capture] in
                do {
                    let result = try await capture.stop(reason: .applicationTermination)
                    gate.resume(returning: .stopped(result))
                } catch {
                    gate.resume(returning: .failed(error.localizedDescription))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                gate.resume(returning: .timedOut)
            }
        }
    }

    private func saveCopyForTermination(_ editor: EditorSession) async -> Bool {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(editor.title) Copy.\(ProjectLayout.bundleExtension)"
        panel.title = "Save a Copy"
        panel.prompt = "Save Copy"
        guard panel.runModal() == .OK, var destination = panel.url else { return false }
        if destination.pathExtension.lowercased() == ProjectLayout.bundleExtension,
           destination.pathExtension != ProjectLayout.bundleExtension
        {
            destination.deletePathExtension()
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        } else if destination.pathExtension != ProjectLayout.bundleExtension {
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        }
        do {
            _ = try await editor.saveCopy(to: destination)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }

    private func startCapture() async {
        guard let source = selectedSource else {
            errorMessage = "Pick a display or window to record."
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Recording \(formatter.string(from: Date()))"
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let meta = ProjectMeta(
            displayBounds: Rect2D.unit,
            scale: Double(scale),
            captureTarget: source.target
        )

        do {
            try library.ensureRootExists()
            let url = try library.create(name: name, meta: meta)
            recordingURL = url
            try await capture.start(target: source.target, projectURL: url)
            guard capture.isRunning else { return }
            isRecording = true
            recordedDuration = 0
            startElapsedTimer()
        } catch {
            if capture.state == .stopping || capture.state == .finalized {
                // An unexpected-stop or termination finalizer owns this exact
                // bundle; do not race it by deleting a potentially playable capture.
                return
            }
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
                recordingURL = nil
            }
            errorMessage = error.localizedDescription
            refreshPermissions()
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        let started = Date()
        elapsedTask = Task { @MainActor in
            while !Task.isCancelled, isRecording {
                recordedDuration = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func observeCaptureEvents() {
        captureEventTask?.cancel()
        captureEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in capture.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .stoppedUnexpectedly(let message):
                    await finishRecording(reason: .unexpected(message))
                case .finalizationFailed(let message):
                    errorMessage = message
                case .started, .stopRequested, .finalized:
                    break
                }
            }
        }
    }

    private func installRecordShortcut() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard RecordShortcut.matches(event) else { return event }
            Task { @MainActor in
                await self?.handleRecordShortcut()
            }
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard RecordShortcut.matches(event) else { return }
            Task { @MainActor in
                await self?.handleRecordShortcut()
            }
        }
    }
}
