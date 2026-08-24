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
