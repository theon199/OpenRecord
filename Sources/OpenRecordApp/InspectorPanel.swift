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
                    Slider(
                        value: zoomAmount,
                        in: 1...4,
                        step: 0.05,
                        onEditingChanged: { editing in
                            setEditing(editing, actionName: "Adjust Zoom")
                        }
                    )
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
                labeledSlider(
                    "Padding",
                    value: padding,
                    range: 0...120,
                    format: "%.0f",
                    actionName: "Change Padding"
                )
                labeledSlider(
                    "Corner radius",
                    value: cornerRadius,
                    range: 0...48,
                    format: "%.0f",
                    actionName: "Change Corner Radius"
                )
                labeledSlider(
                    "Cursor scale",
                    value: cursorScale,
                    range: CanvasSettings.cursorScaleRange,
                    format: "%.2f×",
                    actionName: "Change Cursor Scale",
                    step: 0.05
                )
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
                session.updateCanvas(actionName: "Change Background") {
                    $0.background = .solid(RGBAColor(color))
                }
            }
        )
    }

    private var padding: Binding<Double> {
        Binding(
            get: { session.document.canvas.padding },
            set: { value in
                session.updateCanvas(actionName: "Change Padding") {
                    $0.padding = value
                }
            }
        )
    }

    private var cornerRadius: Binding<Double> {
        Binding(
            get: { session.document.canvas.cornerRadius },
            set: { value in
                session.updateCanvas(actionName: "Change Corner Radius") {
                    $0.cornerRadius = value
                }
            }
        )
    }

    private var cursorScale: Binding<Double> {
        Binding(
            get: { session.document.canvas.cursorScale },
            set: { value in
                session.updateCanvas(actionName: "Change Cursor Scale") {
                    $0.cursorScale = value
                }
            }
        )
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        actionName: String,
        step: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(
                    value: value,
                    in: range,
                    step: step,
                    onEditingChanged: { editing in
                        setEditing(editing, actionName: actionName)
                    }
                )
            } else {
                Slider(
                    value: value,
                    in: range,
                    onEditingChanged: { editing in
                        setEditing(editing, actionName: actionName)
                    }
                )
            }
        }
    }

    private func setEditing(_ editing: Bool, actionName: String) {
        if editing {
            session.beginDocumentEdit(actionName: actionName)
        } else {
            session.endDocumentEdit()
        }
    }
}
