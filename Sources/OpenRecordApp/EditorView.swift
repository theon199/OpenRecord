import AVFoundation
import OpenRecord
import SwiftUI

struct EditorView: View {
    @Bindable var model: AppModel
    @Bindable var session: EditorSession
    @State private var showingTranscript = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !session.persistentWarnings.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(session.persistentWarnings.joined(separator: " "))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.yellow.opacity(0.12))
            }
        }
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
                Button("Export…") {
                    session.presentExportPanel()
                }
                .disabled(session.exportProgress != nil)
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
