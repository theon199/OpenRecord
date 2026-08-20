import AppKit
import Foundation
import OpenRecord
import SwiftUI

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
        let url = url.standardizedFileURL
        do {
            let isOpen = editor?.projectURL.standardizedFileURL == url
                || selectedProjectURL?.standardizedFileURL == url
            if isOpen {
                closeEditor()
            }
            try library.delete(url)
            refreshProjects()
        } catch {
            errorMessage = error.localizedDescription
            refreshProjects()
        }
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
        openGeneration += 1
        let generation = openGeneration
        editor?.shutdown()
        editor = nil
        do {
            let opened = try library.open(url: url)
            let session = await EditorSession.load(opened: opened, library: library)
            guard generation == openGeneration else {
                session.shutdown()
                return
            }
            if generateAutoZooms {
                try session.applyAutoZoomsAndSave()
            }
            guard generation == openGeneration else {
                session.shutdown()
                return
            }
            editor = session
            selectedProjectURL = url
        } catch {
            if generation == openGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeEditor() {
        openGeneration += 1
        editor?.shutdown()
        editor = nil
        selectedProjectURL = nil
    }

    func selectProject(_ url: URL?) {
        guard let url else {
            closeEditor()
            return
        }
        if url == editor?.projectURL { return }
        Task { await openProject(url) }
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
        cancelCountdown()
        elapsedTask?.cancel()
        elapsedTask = nil
        guard isRecording else { return }
        isRecording = false
        isProcessingCapture = true
        defer { isProcessingCapture = false }

        let url = recordingURL
        recordingURL = nil
        do {
            try await capture.stop()
            isRecorderPresented = false
            showMainWindow()
            if let url {
                await openProject(url, generateAutoZooms: true)
                refreshProjects()
            }
        } catch {
            errorMessage = error.localizedDescription
            isRecorderPresented = false
            if let url {
                await openProject(url, generateAutoZooms: false)
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
            isRecording = true
            recordedDuration = 0
            startElapsedTimer()
        } catch {
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
