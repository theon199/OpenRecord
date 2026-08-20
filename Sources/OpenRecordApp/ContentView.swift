import AppKit
import OpenRecord
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let screen = !model.allPermissionsGranted ? "permissions" : "library"
        // #region agent log
        let _ = AgentDebugLog.write(
            hypothesisId: "H2",
            location: "ContentView.swift:body",
            message: "ContentView.body",
            data: [
                "screen": screen,
                "permissionScreen": model.permissionGranted.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","),
                "projectCount": model.projects.count,
                "hasEditor": model.editor != nil,
            ]
        )
        // #endregion
        Group {
            if !model.allPermissionsGranted {
                PermissionsView(model: model)
            } else {
                MainSplitView(model: model)
            }
        }
        .alert(
            "OpenRecord",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        // #region agent log
                        AgentDebugLog.write(
                            hypothesisId: "H5",
                            location: "ContentView.swift:geometry.onAppear",
                            message: "ContentView layout size",
                            data: [
                                "width": Double(geo.size.width),
                                "height": Double(geo.size.height),
                                "windows": AgentDebugLog.windowDump(),
                            ]
                        )
                        // #endregion
                    }
            }
        }
        .onAppear {
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "H2",
                location: "ContentView.swift:onAppear",
                message: "ContentView.onAppear",
                data: [
                    "allPermissionsGranted": model.allPermissionsGranted,
                    "windows": AgentDebugLog.windowDump(),
                ]
            )
            // #endregion
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            if model.allPermissionsGranted {
                model.refreshProjects()
            }
        }
    }
}

struct MainSplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .sheet(isPresented: $model.isRecorderPresented) {
            RecorderView(model: model)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView(model: model)
        }
        .onAppear { model.refreshProjects() }
        .overlay {
            if model.isProcessingCapture {
                ZStack {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finishing recording…")
                            .font(.headline)
                        Text("Generating auto-zooms from cursor activity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = model.editor {
            EditorView(model: model, session: session)
        } else {
            ContentUnavailableView {
                Label("No Project Selected", systemImage: "film.stack")
            } description: {
                Text("Open a recording from the sidebar, or start a new one.")
            } actions: {
                Button("New Recording") {
                    Task { await model.presentRecorder(autoStart: false) }
                }
                .keyboardShortcut("n")
            }
            .navigationTitle("OpenRecord")
        }
    }
}
