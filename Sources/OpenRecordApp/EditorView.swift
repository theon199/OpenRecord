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
            }
        }
        .overlay {
            if let progress = session.exportProgress {
                ZStack {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .frame(width: 220)
                        Text("Exporting…")
                            .font(.headline)
                        Button("Cancel") {
                            session.cancelExport()
                        }
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
                model.errorMessage = error
                session.lastError = nil
            }
        }
        .focusable()
        .onKeyPress(.space) {
            session.togglePlay()
            return .handled
        }
        .onKeyPress(.delete) {
            if session.selectedSpeedID != nil {
                session.deleteSelectedSpeedSegment()
            } else {
                session.deleteSelectedZoom()
            }
            return .handled
        }
        .onDisappear {
            session.pause()
        }
    }
}
