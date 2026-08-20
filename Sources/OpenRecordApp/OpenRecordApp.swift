import AppKit
import OpenRecord
import SwiftUI

@main
struct OpenRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "H1",
            location: "OpenRecordApp.swift:init",
            message: "App.init after setActivationPolicy",
            data: [
                "windowCount": NSApp.windows.count,
                "windows": AgentDebugLog.windowDump(),
                "activationPolicy": NSApp.activationPolicy().rawValue,
            ]
        )
        // #endregion
    }

    var body: some Scene {
        // #region agent log
        let _ = AgentDebugLog.write(
            hypothesisId: "H2",
            location: "OpenRecordApp.swift:body",
            message: "App.body evaluated",
            data: ["windowCount": NSApp.windows.count]
        )
        // #endregion
        WindowGroup("OpenRecord") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "H1",
            location: "OpenRecordApp.swift:applicationDidFinishLaunching",
            message: "didFinishLaunching before orderFront",
            data: [
                "windowCount": NSApp.windows.count,
                "windows": AgentDebugLog.windowDump(),
            ]
        )
        // #endregion
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            Self.orderFrontMainWindows()
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "H4",
                location: "OpenRecordApp.swift:applicationDidFinishLaunching.async",
                message: "after orderFrontMainWindows",
                data: [
                    "windowCount": NSApp.windows.count,
                    "windows": AgentDebugLog.windowDump(),
                    "keyTitle": NSApp.keyWindow?.title ?? "nil",
                    "mainTitle": NSApp.mainWindow?.title ?? "nil",
                ]
            )
            // #endregion
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.orderFrontMainWindows()
        return true
    }

    @MainActor
    static func orderFrontMainWindows() {
        for window in NSApp.windows where window.canBecomeMain || window.canBecomeKey {
            let className = String(describing: type(of: window))
            if className.contains("StatusBar") || className.contains("NSStatus") {
                continue
            }
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "H4",
                location: "OpenRecordApp.swift:orderFrontMainWindows",
                message: "ordering window front",
                data: [
                    "class": className,
                    "title": window.title,
                    "frame": NSStringFromRect(window.frame),
                    "contentSize": NSStringFromSize(window.contentView?.bounds.size ?? .zero),
                    "subviews": window.contentView?.subviews.map { String(describing: type(of: $0)) }.joined(separator: ",") ?? "",
                ]
            )
            // #endregion
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private let _keepContractsLinked = OpenRecordInfo.bundleIdentifier
