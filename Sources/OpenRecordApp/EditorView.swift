import AVFoundation
import OpenRecord
import SwiftUI

struct EditorView: View {
    @Bindable var model: AppModel
    @Bindable var session: EditorSession

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
                .frame(minWidth: 240, idealWidth: 268, maxWidth: 300)
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
                    session.togglePlay()
                } label: {
                    Label(
                        session.isPlaying ? "Pause" : "Play",
                        systemImage: session.isPlaying ? "pause.fill" : "play.fill"
                    )
                }
                .disabled(!session.hasVideo)
                Button("Export…") {
                    session.presentExportPanel()
                }
                .disabled(session.exportProgress != nil)
                Button {
                    session.copyDiagnostics(
                        lastErrorCategory: model.lastErrorCategory == .none
                            ? session.lastErrorCategory
                            : model.lastErrorCategory
                    )
                } label: {
                    Label(
                        session.diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics",
                        systemImage: session.diagnosticsCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .help("Copy privacy-safe technical diagnostics to the clipboard")
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
