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
                Button("Zoom Timeline In") { model.editor?.changeTimelineZoom(by: 1.25) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model.editor == nil)
                Button("Zoom Timeline Out") { model.editor?.changeTimelineZoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.editor == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Export…") {
                    model.editor?.presentExportPanel()
                }
                .keyboardShortcut("e")
                .disabled(model.editor == nil)
                Button("Export Snapshot…") {
                    model.editor?.presentExportPanel(kind: .snapshot)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.editor == nil)
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
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            Self.orderFrontMainWindows()
        }
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
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private let _keepContractsLinked = OpenRecordInfo.bundleIdentifier
