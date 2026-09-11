import AppKit
import OpenRecord
import SwiftUI

@main
struct OpenRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("OpenRecord") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.editor?.undoMenuTitle ?? "Undo") {
                    model.editor?.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.editor?.canUndo != true)

                Button(model.editor?.redoMenuTitle ?? "Redo") {
                    model.editor?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.editor?.canRedo != true)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") {
                    Task { await model.presentRecorder(autoStart: false) }
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    model.presentOpenProjectPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Recording") {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await model.handleRecordShortcut() }
                }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
                Button("Cancel Countdown") {
                    model.cancelCountdown()
                }
                .disabled(model.countdownRemaining == nil)
            }
            CommandMenu("Timeline") {
                Button("Split at Playhead") {
                    model.editor?.splitSelectedTimelineItemsAtPlayhead()
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.editor == nil)

                Button("Delete Selected Range") {
                    model.editor?.deleteSelectedSourceRange()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.editor?.selectedSourceRange == nil)

                Divider()
                Button("Copy Timeline Items") {
                    model.editor?.copyTimelineSelection()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.editor?.timelineSelection.isEmpty != false)
                Button("Paste Timeline Items") {
                    model.editor?.pasteTimelineItems()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model.editor?.timelineClipboard.isEmpty != false)
                Button("Duplicate Timeline Items") {
                    model.editor?.duplicateTimelineSelection()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.editor?.timelineSelection.isEmpty != false)

                Divider()
                Button("Nudge Left") { model.editor?.nudgeTimelineSelection(by: -1.0 / 30.0) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                    .disabled(model.editor?.timelineSelection.isEmpty != false)
                Button("Nudge Right") { model.editor?.nudgeTimelineSelection(by: 1.0 / 30.0) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                    .disabled(model.editor?.timelineSelection.isEmpty != false)
                Button("Previous Edit Point") { model.editor?.jumpToAdjacentEditPoint(forward: false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                    .disabled(model.editor == nil)
                Button("Next Edit Point") { model.editor?.jumpToAdjacentEditPoint(forward: true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                    .disabled(model.editor == nil)
                Button("Select Previous Item") { model.editor?.selectAdjacentTimelineItem(forward: false) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(model.editor == nil)
                Button("Select Next Item") { model.editor?.selectAdjacentTimelineItem(forward: true) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(model.editor == nil)

                Divider()
                Button("Zoom Timeline In") { model.editor?.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model.editor == nil)
                Button("Zoom Timeline Out") { model.editor?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.editor == nil)
                Button("Zoom Timeline to Fit") { model.editor?.resetTimelineZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.editor == nil)
            }
            CommandMenu("ActionMap") {
                Button("Build / Rebuild ActionMap") {
                    model.editor?.rebuildActionMap()
                }
                .disabled(model.editor == nil || model.editor?.isAnalysisCancellable == true)

                Button("Merge Selected Actions") {
                    model.editor?.mergeSelectedActions()
                }
                .disabled(model.editor?.selectedActionMapRows.count ?? 0 < 2)
                Button("Split Selected Action") {
                    model.editor?.splitSelectedAction()
                }
                .disabled(model.editor?.selectedActionMapRows.count != 1)
                Button("Lock Selected Actions") {
                    model.editor?.setSelectedActionsLocked(true)
                }
                .disabled(model.editor?.selectedActionMapRows.isEmpty != false)
                Button("Suppress Selected Actions") {
                    model.editor?.setSelectedActionsSuppressed(true)
                }
                .disabled(model.editor?.selectedActionMapRows.isEmpty != false)
            }
            CommandMenu("Review") {
                Button("First Cut…") {
                    model.editor?.presentedReviewSheet = .firstCut
                }
                .disabled(model.editor == nil)
                Button("Privacy Firewall…") {
                    model.editor?.presentedReviewSheet = .privacyReview
                }
                .disabled(model.editor == nil)
                Button("Create Sanitized Share Copy…") {
                    model.editor?.presentSanitizedShareCopyPanel()
                }
                .disabled(model.editor == nil || model.editor?.exportProgress != nil)
            }
            CommandGroup(after: .newItem) {
                Button("Export…") {
                    model.editor?.presentExportPanel()
                }
                .keyboardShortcut("e")
                .disabled(model.editor == nil)
                Button("Fast Export…") {
                    model.editor?.presentExportPanel(kind: .sourceFootage)
                }
                .disabled(
                    model.editor == nil
                        || model.editor?.exportProgress != nil
                        || model.editor?.canExportSourceFootage != true
                )
                Button("Export Snapshot…") {
                    model.editor?.presentExportPanel(kind: .snapshot)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.editor == nil)
                Divider()
                Button(model.editor?.diagnosticsCopied == true ? "Diagnostics Copied" : "Copy Diagnostics") {
                    guard let editor = model.editor else { return }
                    editor.copyDiagnostics(
                        lastErrorCategory: model.lastErrorCategory == .none
                            ? editor.lastErrorCategory
                            : model.lastErrorCategory
                    )
                }
                .disabled(model.editor == nil)
                .help("Copy privacy-safe technical diagnostics to the clipboard")
            }
        }

        MenuBarExtra("OpenRecord", systemImage: model.isRecording ? "record.circle.fill" : "record.circle") {
            if model.isRecording {
                Button("Stop Recording") {
                    Task { await model.stopRecording() }
                }
            } else if model.countdownRemaining != nil {
                Button("Cancel Countdown") {
                    model.cancelCountdown()
                }
            } else {
                Button("New Recording…") {
                    Task { await model.presentRecorder(autoStart: false) }
                }
            }
            Button("Show Window") {
                model.showMainWindow()
            }
            Divider()
            Button("Quit OpenRecord") {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() async -> Bool)?
    private static var openURLHandler: (([URL]) -> Void)?
    private static var pendingOpenURLs: [URL] = []
    private static let preferredMainWindowContentSize = NSSize(width: 1_100, height: 720)
    private static let visibleWorkspaceMargin: CGFloat = 12
    private var terminationInProgress = false

    static func installOpenURLHandler(_ handler: @escaping ([URL]) -> Void) {
        openURLHandler = handler
        let pending = pendingOpenURLs
        pendingOpenURLs.removeAll()
        if !pending.isEmpty {
            handler(pending)
        }
    }

    private static func deliverOpenURLs(_ urls: [URL]) {
        let projects = urls.filter {
            $0.pathExtension.lowercased() == ProjectLayout.bundleExtension
        }
        guard !projects.isEmpty else { return }
        if let openURLHandler {
            openURLHandler(projects)
        } else {
            pendingOpenURLs.append(contentsOf: projects)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            Self.orderFrontMainWindows()
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        Self.deliverOpenURLs(filenames.map { URL(fileURLWithPath: $0) })
        application.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.deliverOpenURLs(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.orderFrontMainWindows()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = Self.terminationHandler else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor [weak self] in
            let shouldTerminate = await handler()
            self?.terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    @MainActor
    static func orderFrontMainWindows() {
        for window in NSApp.windows where window.canBecomeMain || window.canBecomeKey {
            let className = String(describing: type(of: window))
            if className.contains("StatusBar") || className.contains("NSStatus") {
                continue
            }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if window.canBecomeMain {
                normalizeMainWindowFrame(window)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// SwiftUI's `defaultSize` is only a launch suggestion. A malformed saved
    /// frame or a first-layout negotiation failure can therefore create a
    /// window taller than the active display. Reset oversized/off-screen main
    /// windows to the preferred launch size and keep ordinary saved sizes
    /// entirely inside the usable macOS workspace.
    @MainActor
    private static func normalizeMainWindowFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let workspace = screen.visibleFrame.insetBy(
            dx: visibleWorkspaceMargin,
            dy: visibleWorkspaceMargin
        )
        guard workspace.width > 0, workspace.height > 0 else { return }

        let current = window.frame
        let hasInvalidSize = !current.width.isFinite
            || !current.height.isFinite
            || current.width <= 0
            || current.height <= 0
        let isOversized = current.width > workspace.width
            || current.height > workspace.height
        let isOffscreen = !current.intersects(workspace)

        var target = current
        if hasInvalidSize || isOversized || isOffscreen {
            let preferredFrameSize = window.frameRect(
                forContentRect: NSRect(
                    origin: .zero,
                    size: preferredMainWindowContentSize
                )
            ).size
            target.size = NSSize(
                width: min(preferredFrameSize.width, workspace.width),
                height: min(preferredFrameSize.height, workspace.height)
            )
            target.origin = NSPoint(
                x: workspace.midX - target.width / 2,
                y: workspace.midY - target.height / 2
            )
        } else {
            target.origin.x = min(
                max(target.origin.x, workspace.minX),
                workspace.maxX - target.width
            )
            target.origin.y = min(
                max(target.origin.y, workspace.minY),
                workspace.maxY - target.height
            )
        }

        guard target != current else { return }
        window.setFrame(target, display: true, animate: false)
    }
}

private let _keepContractsLinked = OpenRecordInfo.bundleIdentifier
