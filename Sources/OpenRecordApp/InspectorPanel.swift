import OpenRecord
import SwiftUI

struct InspectorPanel: View {
    @Bindable var session: EditorSession
    @State private var confirmRegenerateZooms = false

    var body: some View {
        Form {
            if session.selectedZoom != nil {
                Section("Zoom") {
                    LabeledContent("Amount") {
                        Text(session.selectedZoom.map { String(format: "%.2f×", $0.amount) } ?? "")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: zoomAmount, in: 1...4, step: 0.05)
                    LabeledContent("Start", value: Timecode.string(session.selectedZoom?.start ?? 0))
                    LabeledContent("End", value: Timecode.string(session.selectedZoom?.end ?? 0))
                    Button("Delete Zoom", role: .destructive) {
                        session.deleteSelectedZoom()
                    }
                    regenerateZoomsButton
                }
            } else {
                Section("Zoom") {
                    Text("Select a zoom on the timeline, or add one at the playhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Zoom at Playhead") {
                        session.addZoomAtPlayhead()
                    }
                    .disabled(!session.canAddZoomAtPlayhead)
                    regenerateZoomsButton
                }
            }

            Section("Canvas") {
                ColorPicker("Background", selection: backgroundColor, supportsOpacity: false)
                labeledSlider("Padding", value: padding, range: 0...120, format: "%.0f")
                labeledSlider("Corner radius", value: cornerRadius, range: 0...48, format: "%.0f")
                labeledSlider("Cursor scale", value: cursorScale, range: 0.5...3, format: "%.2f")
            }

            Section("Trim") {
                LabeledContent("In", value: Timecode.string(session.document.trimIn))
                LabeledContent("Out", value: Timecode.string(session.effectiveTrimOut))
                Text("Drag the handles on the timeline to trim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Toggle("Copy into library folder", isOn: $session.copyExportToLibrary)
                Button("Export MP4…") {
                    session.presentExportPanel()
                }
                .disabled(session.exportProgress != nil)
                Text("Renders the live trim, zooms, and canvas to an H.264 MP4 (1080p-capped). Mic and system audio are mixed when present.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .confirmationDialog(
            "Replace Existing Zooms?",
            isPresented: $confirmRegenerateZooms,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                session.regenerateAutoZooms()
            }
        } message: {
            Text("Auto-zooms from cursor activity will replace the current zoom ranges.")
        }
    }

    private var regenerateZoomsButton: some View {
        Button("Regenerate from Cursor Activity") {
            if session.document.zoomRanges.isEmpty {
                session.regenerateAutoZooms()
            } else {
                confirmRegenerateZooms = true
            }
        }
        .disabled(session.exportProgress != nil)
    }

    private var zoomAmount: Binding<Double> {
        Binding(
            get: { session.selectedZoom?.amount ?? 1.5 },
            set: { value in
                session.updateSelectedZoom { $0.amount = value }
            }
        )
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: {
                switch session.document.canvas.background {
                case .solid(let color):
                    return color.swiftUIColor
                case .linearGradient(let start, _, _, _):
                    return start.swiftUIColor
                }
            },
            set: { color in
                session.document.canvas.background = .solid(RGBAColor(color))
                session.canvasDidChange()
            }
        )
    }

    private var padding: Binding<Double> {
        Binding(
            get: { session.document.canvas.padding },
            set: { value in
                session.document.canvas.padding = value
                session.canvasDidChange()
            }
        )
    }

    private var cornerRadius: Binding<Double> {
        Binding(
            get: { session.document.canvas.cornerRadius },
            set: { value in
                session.document.canvas.cornerRadius = value
                session.canvasDidChange()
            }
        )
    }

    private var cursorScale: Binding<Double> {
        Binding(
            get: { session.document.canvas.cursorScale },
            set: { value in
                session.document.canvas.cursorScale = value
                session.canvasDidChange()
            }
        )
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
