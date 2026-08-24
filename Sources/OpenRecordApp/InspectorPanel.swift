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
                    Text("Drag the focal-point handle in the preview to reframe this zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Picker("Style", selection: canvasPresetID) {
                    ForEach(CanvasPreset.builtIns) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    if CanvasPreset.matching(session.document.canvas) == nil {
                        Divider()
                        Text("Custom").tag(Self.customPresetID)
                    }
                }

                Picker("Aspect ratio", selection: aspectPreset) {
                    ForEach(CanvasAspectPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Background", selection: backgroundMode) {
                    ForEach(CanvasBackgroundMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch session.document.canvas.background {
                case .solid:
                    ColorPicker("Color", selection: solidColor, supportsOpacity: false)
                case .linearGradient:
                    ColorPicker("Start color", selection: gradientStartColor, supportsOpacity: false)
                    ColorPicker("End color", selection: gradientEndColor, supportsOpacity: false)
                    Picker("Direction", selection: gradientDirection) {
                        ForEach(CanvasGradientDirection.allCases) { direction in
                            Text(direction.rawValue).tag(direction)
                        }
                    }
                }
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

            Section("Keyboard") {
                Toggle("Show keyboard shortcuts", isOn: keyboardOverlayEnabled)
                if session.keys.isEmpty {
                    Text("This recording has no keyboard shortcut data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Position", selection: keyboardOverlayPosition) {
                        Text("Center").tag(KeyboardOverlayPosition.bottomCenter)
                        Text("Left").tag(KeyboardOverlayPosition.bottomLeft)
                    }
                    .pickerStyle(.segmented)

                    labeledSlider(
                        "Hold time",
                        value: keyboardOverlayFadeDelay,
                        range: 0.2...3,
                        format: "%.1f s",
                        actionName: "Change Keyboard Hold Time",
                        step: 0.1
                    )

                    Stepper(
                        "Visible shortcuts: \(session.document.keyboardOverlay.maxVisibleKeys)",
                        value: keyboardOverlayMaxVisibleKeys,
                        in: 1...5
                    )
                }
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
                Text("Renders the live trim, zooms, canvas, and keyboard overlay to an H.264 MP4 (1080p-capped). Mic and system audio are mixed when present.")
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

    private var aspectPreset: Binding<CanvasAspectPreset> {
        Binding(
            get: {
                CanvasAspectPreset.matching(
                    aspectWidth: session.document.canvas.aspectWidth,
                    aspectHeight: session.document.canvas.aspectHeight
                ) ?? .widescreen
            },
            set: { preset in
                session.updateCanvas(actionName: "Change Aspect Ratio") {
                    preset.apply(to: &$0)
                }
            }
        )
    }

    private var canvasPresetID: Binding<String> {
        Binding(
            get: {
                CanvasPreset.matching(session.document.canvas)?.id ?? Self.customPresetID
            },
            set: { presetID in
                guard let preset = CanvasPreset.builtIns.first(where: { $0.id == presetID })
                else { return }
                session.applyCanvasPreset(preset)
            }
        )
    }

    private var keyboardOverlayEnabled: Binding<Bool> {
        Binding(
            get: { session.document.keyboardOverlay.enabled },
            set: { enabled in
                session.updateKeyboardOverlay(actionName: "Toggle Keyboard Overlay") {
                    $0.enabled = enabled
                }
            }
        )
    }

    private var keyboardOverlayPosition: Binding<KeyboardOverlayPosition> {
        Binding(
            get: { session.document.keyboardOverlay.position },
            set: { position in
                session.updateKeyboardOverlay(actionName: "Move Keyboard Overlay") {
                    $0.position = position
                }
            }
        )
    }

    private var keyboardOverlayFadeDelay: Binding<Double> {
        Binding(
            get: { session.document.keyboardOverlay.fadeDelay },
            set: { fadeDelay in
                session.updateKeyboardOverlay(actionName: "Change Keyboard Hold Time") {
                    $0.fadeDelay = fadeDelay
                }
            }
        )
    }

    private var keyboardOverlayMaxVisibleKeys: Binding<Int> {
        Binding(
            get: { session.document.keyboardOverlay.maxVisibleKeys },
            set: { count in
                session.updateKeyboardOverlay(actionName: "Change Visible Keyboard Shortcuts") {
                    $0.maxVisibleKeys = count
                }
            }
        )
    }

    private var backgroundMode: Binding<CanvasBackgroundMode> {
        Binding(
            get: {
                switch session.document.canvas.background {
                case .solid: .solid
                case .linearGradient: .gradient
                }
            },
            set: { mode in
                session.updateCanvas(actionName: "Change Background Style") { canvas in
                    switch (mode, canvas.background) {
                    case (.solid, .solid), (.gradient, .linearGradient):
                        return
                    case (.solid, .linearGradient(let start, _, _, _)):
                        canvas.background = .solid(start)
                    case (.gradient, .solid(let color)):
                        let direction = CanvasGradientDirection.diagonalDown
                        canvas.background = .linearGradient(
                            start: color,
                            end: gradientCompanionColor(color),
                            startPoint: direction.startPoint,
                            endPoint: direction.endPoint
                        )
                    }
                }
            }
        )
    }

    private var solidColor: Binding<Color> {
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

    private var gradientStartColor: Binding<Color> {
        Binding(
            get: {
                switch session.document.canvas.background {
                case .solid(let color): return color.swiftUIColor
                case .linearGradient(let start, _, _, _): return start.swiftUIColor
                }
            },
            set: { color in
                session.updateCanvas(actionName: "Change Gradient Start") { canvas in
                    guard case .linearGradient(_, let end, let startPoint, let endPoint) = canvas.background
                    else { return }
                    canvas.background = .linearGradient(
                        start: RGBAColor(color),
                        end: end,
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                }
            }
        )
    }

    private var gradientEndColor: Binding<Color> {
        Binding(
            get: {
                switch session.document.canvas.background {
                case .solid(let color): return gradientCompanionColor(color).swiftUIColor
                case .linearGradient(_, let end, _, _): return end.swiftUIColor
                }
            },
            set: { color in
                session.updateCanvas(actionName: "Change Gradient End") { canvas in
                    guard case .linearGradient(let start, _, let startPoint, let endPoint) = canvas.background
                    else { return }
                    canvas.background = .linearGradient(
                        start: start,
                        end: RGBAColor(color),
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                }
            }
        )
    }

    private var gradientDirection: Binding<CanvasGradientDirection> {
        Binding(
            get: {
                guard case .linearGradient(_, _, let startPoint, let endPoint) =
                    session.document.canvas.background
                else { return .diagonalDown }
                return CanvasGradientDirection.matching(
                    startPoint: startPoint,
                    endPoint: endPoint
                ) ?? .diagonalDown
            },
            set: { direction in
                session.updateCanvas(actionName: "Change Gradient Direction") { canvas in
                    guard case .linearGradient(let start, let end, _, _) = canvas.background
                    else { return }
                    canvas.background = .linearGradient(
                        start: start,
                        end: end,
                        startPoint: direction.startPoint,
                        endPoint: direction.endPoint
                    )
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

    private func gradientCompanionColor(_ color: RGBAColor) -> RGBAColor {
        RGBAColor(
            r: min(color.r + 0.18, 1),
            g: min(color.g + 0.08, 1),
            b: min(color.b + 0.28, 1),
            a: color.a
        )
    }

    private static let customPresetID = "custom"
}

private enum CanvasBackgroundMode: String, CaseIterable, Identifiable {
    case solid = "Solid"
    case gradient = "Gradient"

    var id: Self { self }
}

private enum CanvasGradientDirection: String, CaseIterable, Identifiable {
    case diagonalDown = "Diagonal ↘"
    case horizontal = "Horizontal →"
    case vertical = "Vertical ↓"
    case diagonalUp = "Diagonal ↗"

    var id: Self { self }

    var startPoint: Point2D {
        switch self {
        case .diagonalDown, .horizontal: Point2D(x: 0, y: 0)
        case .vertical: Point2D(x: 0.5, y: 0)
        case .diagonalUp: Point2D(x: 0, y: 1)
        }
    }

    var endPoint: Point2D {
        switch self {
        case .diagonalDown: Point2D(x: 1, y: 1)
        case .horizontal: Point2D(x: 1, y: 0)
        case .vertical: Point2D(x: 0.5, y: 1)
        case .diagonalUp: Point2D(x: 1, y: 0)
        }
    }

    static func matching(startPoint: Point2D, endPoint: Point2D) -> Self? {
        allCases.first {
            $0.startPoint == startPoint && $0.endPoint == endPoint
        }
    }
}
