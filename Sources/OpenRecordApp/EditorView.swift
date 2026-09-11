import AVFoundation
import OpenRecord
import SwiftUI

struct EditorView: View {
    @Bindable var model: AppModel
    @Bindable var session: EditorSession
    @State private var showingTranscript = false
    @State private var showingActionMap = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if !session.persistentWarnings.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(session.persistentWarnings.joined(separator: " "))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            session.dismissPersistentWarnings()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss warning")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.yellow.opacity(0.12))
                }

                editorStatusBar

                PreviewCanvas(session: session)
                    .padding(12)
                Divider()
                TimelineView(session: session)
                    .padding(12)
                    .frame(minHeight: 118)
            }
            .frame(minWidth: 560)

            InspectorPanel(session: session)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Library") {
                    model.closeEditor()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingTranscript.toggle()
                } label: {
                    HStack(spacing: 5) {
                        if session.isTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "waveform")
                        }
                        Text("Transcript")
                        if !session.document.transcript.isEmpty {
                            Text("\(session.document.transcript.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .help(transcriptToolbarHelp)
                .accessibilityLabel("Transcript")
                .popover(isPresented: $showingTranscript, arrowEdge: .bottom) {
                    TranscriptPanel(session: session)
                        .frame(width: 340, height: 420)
                }
                Button {
                    showingActionMap.toggle()
                } label: {
                    HStack(spacing: 5) {
                        if session.actionMapStatus == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                        }
                        Text("ActionMap")
                        if !session.actionMapRows.isEmpty {
                            Text("\(session.actionMapRows.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .help("Search and edit local ActionMap actions")
                .accessibilityLabel("ActionMap")
                .popover(isPresented: $showingActionMap, arrowEdge: .bottom) {
                    ActionMapPanel(session: session)
                        .frame(width: 420, height: 620)
                }
                Button("Export…") {
                    session.presentExportPanel()
                }
                .disabled(session.exportProgress != nil)
                if session.isAnalysisCancellable {
                    Button("Cancel Analysis") {
                        session.cancelAnalysis()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .overlay {
            if let progress = session.exportProgress {
                ZStack {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        ProgressView(value: min(max(progress.fraction, 0), 1))
                            .frame(width: 220)
                            .accessibilityLabel("Export progress")
                        Text(session.isCancellingExport ? "Cancelling…" : "Exporting…")
                            .font(.headline)
                        if let fps = progress.framesPerSecond,
                           fps.isFinite,
                           fps > 0
                        {
                            Text("\(fps, specifier: "%.1f") FPS")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Rendering speed \(fps, specifier: "%.1f") frames per second")
                        }
                        if let eta = progress.estimatedRemainingSeconds,
                           eta.isFinite,
                           eta >= 0
                        {
                            Text("About \(formattedDuration(eta)) remaining")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Estimated time remaining \(formattedDuration(eta))")
                        }
                        Button("Cancel") {
                            session.cancelExport()
                        }
                        .disabled(session.isCancellingExport)
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: session.lastError) { _, error in
            if let error {
                model.reportError(error, category: session.lastErrorCategory)
                session.lastError = nil
            }
        }
        .focusable()
        .onKeyPress(.space) {
            session.togglePlay()
            return .handled
        }
        .onKeyPress(.delete) {
            session.deleteSelectedTimelineItem()
            return .handled
        }
        .onDisappear {
            session.pause()
        }
    }

    private var editorStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: saveStateSymbol)
                .foregroundStyle(saveStateColor)
            Text(saveStateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.isReadOnly {
                Button("Save Copy…") { model.saveEditorCopy() }
                    .buttonStyle(.link)
                Button("Add to Library…") { model.addEditorCopyToLibrary() }
                    .buttonStyle(.link)
            }
            if let message = session.analysisMessage,
               session.analysisPhase != .idle || session.isAnalysisCancellable
            {
                Divider().frame(height: 12)
                if let fraction = session.analysisFraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .frame(width: 100)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if session.isAnalysisCancellable {
                    Button("Cancel") { session.cancelAnalysis() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.2))
    }

    private var saveStateLabel: String {
        switch session.saveState {
        case .dirty: "Unsaved changes"
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed: "Save failed"
        case .readOnly: "Read-only copy"
        }
    }

    private var saveStateSymbol: String {
        switch session.saveState {
        case .dirty: "pencil.circle"
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .readOnly: "lock"
        }
    }

    private var saveStateColor: Color {
        switch session.saveState {
        case .dirty: .orange
        case .saving: .accentColor
        case .saved: .green
        case .failed: .red
        case .readOnly: .secondary
        }
    }

    private var transcriptToolbarHelp: String {
        if session.isTranscribing {
            return session.transcriptionStatus ?? "Transcribing…"
        }
        return "Transcript"
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 {
            return "\(Int(clamped.rounded())) sec"
        }
        let minutes = Int(clamped) / 60
        let remaining = Int(clamped) % 60
        return "\(minutes) min \(remaining) sec"
    }
}
