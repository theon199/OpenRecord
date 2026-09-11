import AppKit
import OpenRecord
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            MainSplitView(model: model)
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
        .alert(
            "Recording Telemetry Is Damaged",
            isPresented: Binding(
                get: { model.degradedOpenMessage != nil },
                set: { _ in }
            )
        ) {
            Button("Open Anyway") {
                model.openDegradedProjectAnyway()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDegradedOpen()
            }
        } message: {
            Text(model.degradedOpenMessage ?? "")
        }
        .alert(
            "OpenRecord Couldn’t Save Your Changes",
            isPresented: Binding(
                get: { model.saveFailureMessage != nil },
                set: { _ in }
            )
        ) {
            Button("Retry") {
                model.retryPendingSave()
            }
            Button("Save a Copy…") {
                model.saveCopyAndContinue()
            }
            Button("Discard Changes", role: .destructive) {
                model.discardChangesAndContinue()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingEditorTransition()
            }
        } message: {
            Text(model.saveFailureMessage ?? "")
        }
        .onAppear {
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
            model.refreshProjects()
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
        .sheet(isPresented: $model.isPermissionsPresented) {
            PermissionsView(model: model)
        }
        .toolbar {
            ToolbarItem {
                Button("Capture Permissions") {
                    model.isPermissionsPresented = true
                }
                .help("Review capture-only permissions. Browsing and editing do not require them.")
            }
        }
        .onAppear { model.refreshProjects() }
        .overlay {
            if model.isProcessingCapture {
                ZStack {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        if let progress = model.editor?.analysisFraction {
                            ProgressView(value: min(max(progress, 0), 1))
                                .frame(width: 220)
                        } else {
                            ProgressView()
                        }
                        Text("Finishing recording…")
                            .font(.headline)
                        Text(model.editor?.analysisMessage ?? "Finalizing the captured bundle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.editor?.isAnalysisCancellable == true {
                            Button("Cancel Analysis") {
                                model.cancelAnalysis()
                            }
                            .keyboardShortcut(.cancelAction)
                        }
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
