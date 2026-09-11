import AppKit
import Foundation
import OpenRecord
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

private enum PendingEditorTransition {
    case close
    case open(URL, generateAutoZooms: Bool)
    case delete(URL)
    case rename(URL, String)
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
    private(set) var projectThumbnails: [URL: NSImage] = [:]
    var permissionGranted: [CapturePermissionKind: Bool] = [:]
    var errorMessage: String?
    private(set) var lastErrorCategory: LocalDiagnosticsErrorCategory = .none
    var selectedProjectURL: URL?
    var editor: EditorSession?
    var isRecorderPresented = false
    var isSettingsPresented = false
    var isPermissionsPresented = false
    var captureSources: [CaptureSourceOption] = []
    var selectedSourceID: String?
    var captureSourceThumbnails: [String: NSImage] = [:]
    var captureSourceIcons: [String: NSImage] = [:]
    var countdownRemaining: Int?
    var isRecording = false
    var recordedDuration: TimeInterval = 0
    var isProcessingCapture = false
    var isLoadingSources = false
    var isImportingMedia = false
    var batchExportProgress: Double?
    var batchExportQueue = BatchExportQueue()
    var batchSelectedProjectURLs = Set<URL>()
    private var batchExportTask: Task<Void, Never>?
    var degradedOpenMessage: String?
    var saveFailureMessage: String?
    var capturesKeyboardShortcuts = true {
        didSet {
            UserDefaults.standard.set(
                capturesKeyboardShortcuts,
                forKey: Self.capturesKeyboardShortcutsDefaultsKey
            )
        }
    }
    var capturesMicrophone = true {
        didSet {
            UserDefaults.standard.set(
                capturesMicrophone,
                forKey: Self.capturesMicrophoneDefaultsKey
            )
        }
    }
    var capturesSystemAudio = true {
        didSet {
            UserDefaults.standard.set(
                capturesSystemAudio,
                forKey: Self.capturesSystemAudioDefaultsKey
            )
        }
    }
    var capturesCursorTelemetry = true {
        didSet {
            UserDefaults.standard.set(
                capturesCursorTelemetry,
                forKey: Self.capturesCursorTelemetryDefaultsKey
            )
        }
    }
    /// Privacy-filtered Accessibility semantics are opt-in and independent
    /// from cursor telemetry. Secure values and ordinary typed text are
    /// excluded by the capture layer.
    var capturesSemanticTargets = false {
        didSet {
            UserDefaults.standard.set(
                capturesSemanticTargets,
                forKey: Self.capturesSemanticTargetsDefaultsKey
            )
        }
    }
    var capturesWebcam = false {
        didSet {
            UserDefaults.standard.set(
                capturesWebcam,
                forKey: Self.capturesWebcamDefaultsKey
            )
        }
    }
    var projectTemplates: [ProjectTemplate] = ProjectTemplate.builtIns
    var selectedProjectTemplateID: String?
    var isMicrophoneMuted = false
    var isRecordingCameraCollapsed = false

    var allPermissionsGranted: Bool {
        CapturePermissionKind.requiredForScreenCapture.allSatisfy {
            permissionGranted[$0] == true
        }
    }

    var isBatchExportRunning: Bool { batchExportTask != nil }

    var selectedSource: CaptureSourceOption? {
        captureSources.first { $0.id == selectedSourceID }
    }

    var selectedProjectTemplate: ProjectTemplate? {
        projectTemplates.first { $0.id == selectedProjectTemplateID }
    }

    var displaySources: [CaptureSourceOption] {
        captureSources.filter(\.isDisplay)
    }

    var windowSources: [CaptureSourceOption] {
        captureSources.filter { !$0.isDisplay }
    }

    private let capture = CaptureSession()
    private let recordingOverlay = RecordingOverlayController()
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
    private var thumbnailTask: Task<Void, Never>?
    private var sourcePreviewTask: Task<Void, Never>?
    private static let capturesKeyboardShortcutsDefaultsKey =
        "OpenRecord.capturesKeyboardShortcuts"
    private static let capturesMicrophoneDefaultsKey =
        "OpenRecord.capturesMicrophone"
    private static let capturesSystemAudioDefaultsKey =
        "OpenRecord.capturesSystemAudio"
    private static let capturesCursorTelemetryDefaultsKey =
        "OpenRecord.capturesCursorTelemetry"
    private static let capturesSemanticTargetsDefaultsKey =
        "OpenRecord.capturesSemanticTargets"
    private static let capturesWebcamDefaultsKey = "OpenRecord.capturesWebcam"

    var captureRequest: CaptureRequest {
        CaptureRequest(
            capturesMicrophone: capturesMicrophone,
            capturesSystemAudio: capturesSystemAudio,
            capturesCursorTelemetry: capturesCursorTelemetry,
            capturesKeyboardShortcuts: capturesKeyboardShortcuts,
            capturesWebcam: capturesWebcam,
            capturesSemanticTargets: capturesSemanticTargets
        )
    }

    init() {
        library = .resolved()
        if UserDefaults.standard.object(
            forKey: Self.capturesKeyboardShortcutsDefaultsKey
        ) != nil {
            capturesKeyboardShortcuts = UserDefaults.standard.bool(
                forKey: Self.capturesKeyboardShortcutsDefaultsKey
            )
        }
        if UserDefaults.standard.object(forKey: Self.capturesWebcamDefaultsKey) != nil {
            capturesWebcam = UserDefaults.standard.bool(
                forKey: Self.capturesWebcamDefaultsKey
            )
        }
        if UserDefaults.standard.object(forKey: Self.capturesMicrophoneDefaultsKey) != nil {
            capturesMicrophone = UserDefaults.standard.bool(
                forKey: Self.capturesMicrophoneDefaultsKey
            )
        }
        if UserDefaults.standard.object(forKey: Self.capturesSystemAudioDefaultsKey) != nil {
            capturesSystemAudio = UserDefaults.standard.bool(
                forKey: Self.capturesSystemAudioDefaultsKey
            )
        }
        if UserDefaults.standard.object(forKey: Self.capturesCursorTelemetryDefaultsKey) != nil {
            capturesCursorTelemetry = UserDefaults.standard.bool(
                forKey: Self.capturesCursorTelemetryDefaultsKey
            )
        }
        if UserDefaults.standard.object(forKey: Self.capturesSemanticTargetsDefaultsKey) != nil {
            capturesSemanticTargets = UserDefaults.standard.bool(
                forKey: Self.capturesSemanticTargetsDefaultsKey
            )
        }
        refreshPermissions()
        reloadProjectTemplates()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshPermissions()
        refreshProjects()
        installRecordShortcut()
        observeCaptureEvents()
        configureRecordingOverlay()
        AppDelegate.installOpenURLHandler { [weak self] urls in
            Task { @MainActor [weak self] in
                await self?.openExternalProjects(urls)
            }
        }
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
            recordErrorCategory(.permissions)
            CapturePermissions.openSystemSettings(for: kind)
        }
    }

    func reportError(
        _ message: String,
        category: LocalDiagnosticsErrorCategory
    ) {
        recordErrorCategory(category)
        errorMessage = message
    }

    private func recordErrorCategory(_ category: LocalDiagnosticsErrorCategory) {
        lastErrorCategory = category == .none ? .unknown : category
    }

    func refreshProjects() {
        do {
            try library.ensureRootExists()
            let items = try library.list().map(LibraryItem.from)
            projects = items
            let currentURLs = Set(items.map(\.url))
            batchSelectedProjectURLs.formIntersection(currentURLs)
            projectThumbnails = projectThumbnails.filter { currentURLs.contains($0.key) }
            for item in items where projectThumbnails[item.url] == nil {
                let thumbnailURL = ProjectLayout.thumbnailURL(in: item.url)
                if let image = NSImage(contentsOf: thumbnailURL) {
                    projectThumbnails[item.url] = image
                }
            }
            scheduleThumbnailBackfill(for: items)
        } catch {
            reportError(error.localizedDescription, category: .projectContent)
        }
    }

    func reloadProjectTemplates() {
        do {
            let local = try LocalProjectTemplateStore.applicationSupport().load()
            let builtInIDs = Set(ProjectTemplate.builtIns.map(\.id))
            projectTemplates = ProjectTemplate.builtIns
                + local.filter { !builtInIDs.contains($0.id) }
            if let selectedProjectTemplateID,
               !projectTemplates.contains(where: { $0.id == selectedProjectTemplateID })
            {
                self.selectedProjectTemplateID = nil
            }
        } catch {
            projectTemplates = ProjectTemplate.builtIns
            reportError(
                "Could not load project templates: \(error.localizedDescription)",
                category: .projectContent
            )
        }
    }

    func thumbnail(for url: URL) -> NSImage? {
        projectThumbnails[url.standardizedFileURL]
    }

    func reveal(_ url: URL) {
        do {
            try library.reveal(url)
        } catch {
            reportError(error.localizedDescription, category: .projectContent)
        }
    }

    func setBatchSelected(_ url: URL, selected: Bool) {
        let url = url.standardizedFileURL
        if selected {
            batchSelectedProjectURLs.insert(url)
        } else {
            batchSelectedProjectURLs.remove(url)
        }
    }

    func selectAllProjectsForBatchExport() {
        batchSelectedProjectURLs = Set(projects.map { $0.url.standardizedFileURL })
    }

    func clearBatchExportSelection() {
        batchSelectedProjectURLs.removeAll()
    }

    func deleteProject(_ url: URL) {
        Task { await requestEditorTransition(.delete(url.standardizedFileURL)) }
    }

    func renameProject(_ url: URL, to name: String) {
        Task { await requestEditorTransition(.rename(url.standardizedFileURL, name)) }
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
            reportError(error.localizedDescription, category: .projectContent)
        }
    }

    func resetLibraryFolder() {
        ProjectLibrary.clearPersistedRootURL()
        library = .resolved()
        refreshProjects()
    }

    func presentBatchExportPanel() {
        guard batchExportTask == nil else {
            reportError(
                "Wait for the current batch export to finish or cancel it before starting another.",
                category: .export
            )
            return
        }
        let selectedItems = projects.filter {
            batchSelectedProjectURLs.contains($0.url.standardizedFileURL)
        }
        guard !selectedItems.isEmpty else {
            reportError("Select at least one project for batch export.", category: .export)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(selectedItems.count) selected project export\(selectedItems.count == 1 ? "" : "s"). Each project keeps its own export preset."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        batchExportQueue = BatchExportQueue()
        for item in selectedItems {
            let settings = (try? library.open(url: item.url).document.videoExportSettings)
                ?? .default
            let fileExtension = settings.codec == .proRes422 ? "mov" : "mp4"
            let output = destination
                .appendingPathComponent(item.name, isDirectory: false)
                .appendingPathExtension(fileExtension)
            batchExportQueue.enqueue(
                projectURL: item.url,
                outputURL: output,
                settings: settings
            )
        }
        batchExportTask = Task { @MainActor in
            await runBatchExportQueue()
        }
    }

    func presentImportMoviePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        panel.prompt = "Import"
        panel.message = "Import an MP4, MOV, or M4V recording, including a movie copied from an iPhone or external capture device. The original file is not changed."
        guard panel.runModal() == .OK, let source = panel.url else { return }

        isImportingMedia = true
        Task { @MainActor in
            defer { isImportingMedia = false }
            do {
                let initial = selectedProjectTemplate?.applying(to: ProjectDocument())
                    ?? ProjectDocument()
                let projectURL = try await library.importMovie(
                    from: source,
                    document: initial
                )
                refreshProjects()
                selectedProjectURL = projectURL
                await openProject(projectURL)
            } catch {
                reportError(error.localizedDescription, category: .projectContent)
            }
        }
    }

    func cancelBatchExport() {
        batchExportTask?.cancel()
        batchExportQueue.cancelAll()
        batchExportProgress = nil
    }

    func retryFailedBatchExports() {
        guard batchExportTask == nil else { return }
        guard !batchExportQueue.retryFailed().isEmpty else { return }
        batchExportTask = Task { @MainActor in
            await runBatchExportQueue()
        }
    }

    func clearBatchExportQueue() {
        guard batchExportTask == nil else { return }
        batchExportQueue = BatchExportQueue()
        batchExportProgress = nil
    }

    func moveBatchExportJob(_ id: UUID, offset: Int) {
        guard batchExportTask == nil,
              let index = batchExportQueue.jobs.firstIndex(where: { $0.id == id })
        else { return }
        let targetIndex = min(max(index + offset, 0), batchExportQueue.jobs.count - 1)
        guard targetIndex != index else { return }
        let insertionOffset = targetIndex > index ? targetIndex + 1 : targetIndex
        _ = batchExportQueue.move(jobID: id, to: insertionOffset)
    }

    private func runBatchExportQueue() async {
        let total = max(batchExportQueue.jobs.count, 1)
        batchExportProgress = 0
        while !Task.isCancelled, let job = batchExportQueue.startNext() {
            do {
                let opened = try library.open(url: job.projectURL)
                let exporter = Exporter(projectBundleURL: job.projectURL)
                var document = opened.document
                document.videoExportSettings = job.settings
                try await exporter.export(project: document, url: job.outputURL) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.batchExportQueue.currentJobID == job.id
                        else { return }
                        _ = self.batchExportQueue.updateProgress(
                            for: job.id,
                            progress: progress
                        )
                        self.refreshBatchExportProgress(total: total)
                    }
                }
                _ = batchExportQueue.markSucceeded(for: job.id)
            } catch is CancellationError {
                _ = batchExportQueue.cancel(jobID: job.id)
                break
            } catch {
                _ = batchExportQueue.markFailed(
                    for: job.id,
                    error: error.localizedDescription
                )
            }
            refreshBatchExportProgress(total: total)
        }
        if Task.isCancelled {
            batchExportQueue.cancelAll()
        }
        let failures = batchExportQueue.jobs.filter { $0.status == .failed }
        if !failures.isEmpty {
            reportError(
                "Batch export finished with \(failures.count) failed job\(failures.count == 1 ? "" : "s"). Retry them from the queue.",
                category: .export
            )
        }
        batchExportTask = nil
        batchExportProgress = batchExportQueue.jobs.allSatisfy { $0.status == .succeeded }
            ? 1
            : nil
    }

    private func refreshBatchExportProgress(total: Int) {
        let completed = batchExportQueue.jobs.reduce(0.0) { partial, job in
            switch job.status {
            case .succeeded, .failed, .cancelled:
                partial + 1
            case .running:
                partial + job.progress
            case .queued:
                partial
            }
        }
        batchExportProgress = completed / Double(max(total, 1))
    }

    func openProject(_ url: URL, generateAutoZooms: Bool = false) async {
        await requestEditorTransition(.open(url, generateAutoZooms: generateAutoZooms))
    }

    func presentOpenProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType(filenameExtension: ProjectLayout.bundleExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.prompt = "Open"
        panel.message = "Open an existing .\(ProjectLayout.bundleExtension) project. Projects outside the library open read-only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(url) }
    }

    private func openExternalProjects(_ urls: [URL]) async {
        for url in urls {
            guard url.pathExtension.lowercased() == ProjectLayout.bundleExtension else {
                continue
            }
            await openProject(url)
        }
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
            editor?.shutdown()
            editor = session
            if session.lastErrorCategory != .none {
                recordErrorCategory(session.lastErrorCategory)
            }
            selectedProjectURL = url
            pendingDegradedOpen = nil
            degradedOpenMessage = nil
            if generateAutoZooms {
                // v4.2 replaces the post-capture mutating auto-zoom pass with
                // a staged, suggestion-only First Cut. The captured project
                // remains unchanged until the user reviews and applies items.
                session.generateFirstCut()
            }
        } catch let issue as EditorTelemetryLoadIssue {
            if generation == openGeneration {
                pendingDegradedOpen = PendingDegradedOpen(
                    url: url,
                    generateAutoZooms: generateAutoZooms
                )
                degradedOpenMessage = issue.localizedDescription
                recordErrorCategory(.telemetry)
                selectedProjectURL = editor?.projectURL
            }
        } catch {
            if generation == openGeneration {
                reportError(error.localizedDescription, category: .projectContent)
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

    func cancelAnalysis() {
        editor?.cancelAnalysis()
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
                recordErrorCategory(.projectSave)
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
                recordErrorCategory(.projectSave)
                saveFailureMessage = error.localizedDescription
            }
        }
    }

    func saveEditorCopy() {
        saveEditorCopy(toLibrary: false)
    }

    func addEditorCopyToLibrary() {
        saveEditorCopy(toLibrary: true)
    }

    private func saveEditorCopy(toLibrary: Bool) {
        guard let editor else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = toLibrary ? library.rootURL : nil
        panel.nameFieldStringValue = "\(editor.title) Copy.\(ProjectLayout.bundleExtension)"
        panel.title = toLibrary ? "Add a Copy to Library" : "Save a Copy"
        panel.prompt = toLibrary ? "Add to Library" : "Save Copy"
        panel.message = toLibrary
            ? "Adds a writable copy to the configured library folder."
            : "Saves the complete recording bundle with your current edits."
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != ProjectLayout.bundleExtension {
            destination.deletePathExtension()
            destination.appendPathExtension(ProjectLayout.bundleExtension)
        }
        Task {
            do {
                let saved = try await editor.saveCopy(to: destination)
                if toLibrary {
                    refreshProjects()
                    await openProject(saved)
                } else {
                    editor.noteAnalysisMessage("Saved a copy to \(saved.lastPathComponent).")
                }
            } catch {
                reportError(error.localizedDescription, category: .projectSave)
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
                recordErrorCategory(.projectSave)
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
                reportError(error.localizedDescription, category: .projectContent)
                refreshProjects()
            }
        case .rename(let url, let name):
            do {
                let wasOpen = editor?.projectURL.standardizedFileURL == url
                let renamedURL = try library.rename(url, to: name)
                guard renamedURL != url else {
                    refreshProjects()
                    return
                }
                if let thumbnail = projectThumbnails.removeValue(forKey: url) {
                    projectThumbnails[renamedURL] = thumbnail
                }
                if wasOpen {
                    editor?.shutdown()
                    editor = nil
                    await performOpenProject(
                        renamedURL,
                        generateAutoZooms: false,
                        allowDegradedTelemetry: true
                    )
                } else if selectedProjectURL?.standardizedFileURL == url {
                    selectedProjectURL = renamedURL
                }
                refreshProjects()
            } catch {
                reportError(error.localizedDescription, category: .projectContent)
                refreshProjects()
            }
        }
    }

    private func scheduleThumbnailBackfill(for items: [LibraryItem]) {
        thumbnailTask?.cancel()
        let missing = items.filter { projectThumbnails[$0.url] == nil }
        guard !missing.isEmpty else {
            thumbnailTask = nil
            return
        }
        let library = library
        thumbnailTask = Task { @MainActor [weak self] in
            for item in missing {
                guard !Task.isCancelled else { return }
                guard let thumbnailURL = try? await library.generateThumbnailIfNeeded(for: item.url),
                      let image = NSImage(contentsOf: thumbnailURL)
                else {
                    continue
                }
                self?.projectThumbnails[item.url] = image
            }
        }
    }

    func presentRecorder(autoStart: Bool) async {
        showMainWindow()
        refreshPermissions()
        guard !isRecording, !isProcessingCapture else { return }
        reloadProjectTemplates()
        isRecorderPresented = true
        await reloadCaptureSources()
        if autoStart {
            await startCountdownAndRecord()
        }
    }

    func reloadCaptureSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
        sourcePreviewTask?.cancel()
        do {
            let sources = try await CaptureSession.availableTargets()
            captureSources = sources
            captureSourceThumbnails = [:]
            captureSourceIcons = Self.icons(for: sources)
            if selectedSourceID == nil || !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = sources.first?.id
            }
            sourcePreviewTask = Task { [weak self] in
                await self?.loadCaptureSourceThumbnails(sources)
            }
        } catch {
            reportError(error.localizedDescription, category: .capture)
        }
    }

    private func loadCaptureSourceThumbnails(_ sources: [CaptureSourceOption]) async {
        guard !sources.isEmpty else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return
        }
        for source in sources {
            if Task.isCancelled { return }
            if let image = await CaptureSourceThumbnail.image(for: source.target, content: content) {
                captureSourceThumbnails[source.id] = image
            }
        }
    }

    private static func icons(for sources: [CaptureSourceOption]) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for source in sources {
            guard let bundleID = source.bundleIdentifier, !bundleID.isEmpty else { continue }
            if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon {
                icons[source.id] = icon
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                icons[source.id] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return icons
    }

    func startCountdownAndRecord() async {
        guard !isRecording, !isProcessingCapture else { return }
        guard countdownTask == nil else { return }
        guard selectedSource != nil else {
            reportError("Pick a display or window to record.", category: .capture)
            return
        }
        sourcePreviewTask?.cancel()

        countdownTask = Task { @MainActor in
            isMicrophoneMuted = false
            isRecordingCameraCollapsed = false
            let warmup = Task { [capturesWebcam] in
                if capturesWebcam {
                    await capture.prepareWebcam()
                    await MainActor.run {
                        self.recordingOverlay.setPreviewSession(self.capture.webcamPreviewSession)
                        self.refreshRecordingHUD()
                    }
                }
            }
            for value in [3, 2, 1] {
                countdownRemaining = value
                refreshRecordingHUD()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    countdownRemaining = nil
                    warmup.cancel()
                    await capture.cancelWebcamPrepare()
                    refreshRecordingHUD()
                    return
                }
            }
            _ = await warmup.result
            if Task.isCancelled {
                countdownRemaining = nil
                await capture.cancelWebcamPrepare()
                refreshRecordingHUD()
                return
            }
            await startCapture()
        }
        await countdownTask?.value
        countdownTask = nil
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        Task { await capture.cancelWebcamPrepare() }
        if !isRecording {
            refreshRecordingHUD()
        }
    }

    func stopRecording() async {
        await finishRecording(reason: .manual)
    }

    private func finishRecording(reason: CaptureStopReason) async {
        cancelCountdown()
        elapsedTask?.cancel()
        elapsedTask = nil
        guard isRecording || recordingURL != nil else { return }
        persistRecordingHUDOverlay()
        isRecording = false
        recordingOverlay.dismiss()
        isProcessingCapture = true
        defer { isProcessingCapture = false }

        let url = recordingURL
        do {
            let result = try await capture.stop(reason: reason)
            recordingURL = nil
            if let finalizationError = result.finalizationError {
                reportError(finalizationError, category: .capture)
            }
            isRecorderPresented = false
            showMainWindow()
            if result.hasUsableVideo {
                _ = try? await library.generateThumbnailIfNeeded(for: result.projectURL)
                await openProject(result.projectURL, generateAutoZooms: true)
                refreshProjects()
            } else if let url {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            recordingURL = nil
            reportError(error.localizedDescription, category: .capture)
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
            recordingOverlay.dismiss()
            let url = recordingURL
            let outcome = await stopCaptureForTermination()
            switch outcome {
            case .stopped(let result):
                recordingURL = nil
                if !result.hasUsableVideo, let url {
                    try? FileManager.default.removeItem(at: url)
                }
            case .failed:
                recordErrorCategory(.capture)
                recordingURL = nil
                if let url {
                    try? FileManager.default.removeItem(at: url)
                }
            case .timedOut:
                recordErrorCategory(.capture)
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
                recordErrorCategory(.projectSave)
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
            recordErrorCategory(.projectSave)
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }

    private func startCapture() async {
        guard let source = selectedSource else {
            reportError("Pick a display or window to record.", category: .capture)
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
            var initialDocument = selectedProjectTemplate?.applying(to: ProjectDocument())
                ?? ProjectDocument()
            initialDocument.keyboardOverlay.enabled = capturesKeyboardShortcuts
            initialDocument.webcamOverlay.enabled = capturesWebcam
            if capturesWebcam, recordingHUDMapsToOverlay {
                initialDocument.webcamOverlay = RecordingHUDLayout.overlaySettings(
                    cameraFrame: recordingOverlay.currentCameraFrame,
                    displayBounds: recordingHUDClampBounds(),
                    existing: initialDocument.webcamOverlay
                )
                initialDocument.webcamOverlay.enabled = true
            }
            try library.save(document: initialDocument, to: url)
            recordingURL = url
            try await capture.start(
                target: source.target,
                projectURL: url,
                request: captureRequest
            )
            guard capture.isRunning else {
                countdownRemaining = nil
                refreshRecordingHUD()
                return
            }
            if capturesMicrophone {
                capture.setMicrophoneMuted(isMicrophoneMuted)
            }
            isRecording = true
            countdownRemaining = nil
            isRecorderPresented = false
            recordedDuration = 0
            startElapsedTimer()
            recordingOverlay.setPreviewSession(capture.webcamPreviewSession)
            refreshRecordingHUD()
        } catch {
            countdownRemaining = nil
            if capture.state == .stopping || capture.state == .finalized {
                // An unexpected-stop or termination finalizer owns this exact
                // bundle; do not race it by deleting a potentially playable capture.
                refreshRecordingHUD()
                return
            }
            if let url = recordingURL {
                try? FileManager.default.removeItem(at: url)
                recordingURL = nil
            }
            reportError(error.localizedDescription, category: .capture)
            refreshPermissions()
            await capture.cancelWebcamPrepare()
            refreshRecordingHUD()
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        let started = Date()
        elapsedTask = Task { @MainActor in
            while !Task.isCancelled, isRecording {
                recordedDuration = Date().timeIntervalSince(started)
                recordingOverlay.update(
                    countdownRemaining: countdownRemaining,
                    elapsed: recordedDuration,
                    isRecording: isRecording,
                    isMuted: isMicrophoneMuted,
                    collapsed: isRecordingCameraCollapsed,
                    showsCamera: capturesWebcam,
                    clampBounds: recordingHUDClampBounds()
                )
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
                    reportError(message, category: .capture)
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

    private func configureRecordingOverlay() {
        recordingOverlay.onStop = { [weak self] in
            Task { await self?.stopRecording() }
        }
        recordingOverlay.onCancel = { [weak self] in
            self?.cancelCountdown()
        }
        recordingOverlay.onToggleMute = { [weak self] in
            self?.toggleRecordingMicrophoneMuted()
        }
        recordingOverlay.onToggleCollapsed = { [weak self] in
            self?.toggleRecordingCameraCollapsed()
        }
        recordingOverlay.onLayoutCommitted = { [weak self] in
            self?.persistRecordingHUDOverlay()
        }
    }

    func toggleRecordingMicrophoneMuted() {
        guard capturesMicrophone else { return }
        isMicrophoneMuted.toggle()
        capture.setMicrophoneMuted(isMicrophoneMuted)
        refreshRecordingHUD()
    }

    func toggleRecordingCameraCollapsed() {
        isRecordingCameraCollapsed.toggle()
        refreshRecordingHUD()
    }

    private var recordingHUDMapsToOverlay: Bool {
        capturesWebcam && selectedSource?.isDisplay == true
    }

    private func recordingHUDClampBounds() -> CGRect {
        if case .display(let id) = selectedSource?.target,
           let screen = Self.screen(forDisplayID: id)
        {
            return screen.frame
        }
        let cameraFrame = recordingOverlay.currentCameraFrame
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(cameraFrame) }) {
            return screen.frame
        }
        return NSScreen.main?.frame
            ?? NSScreen.screens.first?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func refreshRecordingHUD() {
        let shouldShow = countdownRemaining != nil || isRecording
        if shouldShow {
            recordingOverlay.present(
                clampBounds: recordingHUDClampBounds(),
                showsCamera: capturesWebcam
            )
            recordingOverlay.setPreviewSession(capture.webcamPreviewSession)
            recordingOverlay.update(
                countdownRemaining: countdownRemaining,
                elapsed: recordedDuration,
                isRecording: isRecording,
                isMuted: isMicrophoneMuted,
                collapsed: isRecordingCameraCollapsed,
                showsCamera: capturesWebcam,
                clampBounds: recordingHUDClampBounds()
            )
        } else {
            recordingOverlay.dismiss()
        }
    }

    private func persistRecordingHUDOverlay() {
        guard recordingHUDMapsToOverlay, let url = recordingURL else { return }
        do {
            var document = try library.open(url: url).document
            document.webcamOverlay = RecordingHUDLayout.overlaySettings(
                cameraFrame: recordingOverlay.currentCameraFrame,
                displayBounds: recordingHUDClampBounds(),
                existing: document.webcamOverlay
            )
            document.webcamOverlay.enabled = capturesWebcam
            try library.save(document: document, to: url)
        } catch {
            return
        }
    }

    private static func screen(forDisplayID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == id
        }
    }
}
