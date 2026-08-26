import OpenRecord
import SwiftUI

struct InspectorPanel: View {
    @Bindable var session: EditorSession
    @State private var confirmRegenerateZooms = false
    @State private var newPresetName = ""

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
                    Picker("Framing", selection: zoomTracking) {
                        Text("Follow Cursor").tag(ZoomTrackingMode.followCursor)
                        Text("Fixed Anchor").tag(ZoomTrackingMode.fixed)
                    }
                    Toggle("Lock during regeneration", isOn: zoomLocked)
                    Text("Drag the focal-point handle in the preview to reframe this zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Start", value: Timecode.string(session.selectedZoom?.start ?? 0))
                    LabeledContent("End", value: Timecode.string(session.selectedZoom?.end ?? 0))
                    Button("Delete Zoom", role: .destructive) {
                        session.deleteSelectedTimelineItem()
                    }
                    autoZoomControls
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
                    autoZoomControls
                }
            }

            Section("Cursor Treatment") {
                if session.selectedCursorEffect != nil {
                    Toggle("Show cursor", isOn: selectedCursorVisible)
                    labeledSlider(
                        "Scale",
                        value: selectedCursorScale,
                        range: CursorEffectRange.scaleRange,
                        format: "%.2f×",
                        actionName: "Change Cursor Treatment Scale",
                        step: 0.05
                    )
                    Toggle("Emphasize clicks", isOn: selectedCursorClickEmphasis)
                    Toggle("Highlight halo", isOn: selectedCursorHalo)
                    Button("Delete Cursor Treatment", role: .destructive) {
                        session.deleteTimelineSelection()
                    }
                } else {
                    HStack {
                        Button("Hide at Playhead") {
                            session.addCursorEffectAtPlayhead(visible: false)
                        }
                        Button("Highlight") {
                            session.addCursorEffectAtPlayhead(
                                visible: true,
                                clickEmphasis: true,
                                halo: true
                            )
                        }
                    }
                    Text("Cursor treatments are source-timed and remain non-destructive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Captions") {
                HStack {
                    Button("Add") { session.addCaptionAtPlayhead() }
                    Button("Import…") { session.importCaptionsPanel() }
                    Spacer()
                }
                if let caption = session.selectedCaption {
                    TextField("Caption text", text: captionText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Position", selection: captionPosition) {
                        ForEach(CaptionPosition.allCases, id: \.self) { position in
                            Text(position.rawValue.capitalized).tag(position)
                        }
                    }
                    labeledSlider("Font size", value: captionFontSize, range: CaptionStyle.fontSizeRange, format: "%.0f pt", actionName: "Change Caption Font Size", step: 1)
                    labeledSlider("Max width", value: captionMaxWidth, range: CaptionStyle.maxWidthRange, format: "%.0f%%", actionName: "Change Caption Width", step: 0.01, displayScale: 100)
                    ColorPicker("Text color", selection: captionForeground)
                    ColorPicker("Background", selection: captionBackground)
                    LabeledContent("Range") {
                        Text("\(Timecode.string(caption.start)) – \(Timecode.string(caption.end))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete Caption", role: .destructive) { session.deleteSelectedTimelineItem() }
                } else {
                    Text("Add or import timed captions, then edit their style here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Annotations") {
                HStack {
                    Button("Text") { session.addAnnotationAtPlayhead(kind: .text) }
                    Button("Arrow") { session.addAnnotationAtPlayhead(kind: .arrow) }
                    Button("Spotlight") { session.addAnnotationAtPlayhead(kind: .spotlight) }
                }
                if let annotation = session.selectedAnnotation {
                    Picker("Type", selection: annotationKind) {
                        ForEach(AnnotationKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue.capitalized).tag(kind)
                        }
                    }
                    if annotation.kind == .text {
                        TextField("Annotation text", text: annotationText)
                    }
                    labeledSlider("Font size", value: annotationFontSize, range: Annotation.fontSizeRange, format: "%.0f pt", actionName: "Change Annotation Font Size", step: 1)
                    if annotation.kind == .spotlight {
                        labeledSlider("Dim amount", value: annotationDimAmount, range: Annotation.dimAmountRange, format: "%.0f%%", actionName: "Change Spotlight Dim", step: 0.01, displayScale: 100)
                    }
                    ColorPicker("Color", selection: annotationColor)
                    Button("Delete Annotation", role: .destructive) { session.deleteSelectedTimelineItem() }
                    Text("Drag active annotations in the preview to position them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Add a text, arrow, or spotlight annotation at the playhead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Toggle("Emphasize cursor clicks", isOn: cursorClickEmphasis)
                Toggle("Cursor highlight halo", isOn: cursorHalo)
                Toggle("Cursor motion blur", isOn: cursorMotionBlurEnabled)
                if session.document.canvas.cursorMotionBlur.enabled {
                    labeledSlider(
                        "Blur amount",
                        value: cursorMotionBlurAmount,
                        range: CursorMotionBlurSettings.amountRange,
                        format: "%.0f%%",
                        actionName: "Change Cursor Motion Blur",
                        step: 0.05,
                        displayScale: 100
                    )
                }
            }

            Section("Reusable Presets") {
                ForEach(EditorStylePreset.builtIns) { preset in
                    Button("Apply \(preset.name)") {
                        session.applyStylePreset(preset)
                    }
                }
                ForEach(session.localStylePresets) { preset in
                    Button("Apply \(preset.name)") {
                        session.applyStylePreset(preset)
                    }
                }
                HStack {
                    TextField("Preset name", text: $newPresetName)
                    Button("Save Current") {
                        session.saveCurrentStylePreset(named: newPresetName)
                        newPresetName = ""
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let status = session.presetStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !session.document.appliedPresetIDs.isEmpty {
                    LabeledContent("Applied") {
                        Text(session.document.appliedPresetIDs.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Preset values are copied into the project for portability; optional IDs record provenance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Webcam") {
                if session.hasWebcamVideo {
                    Toggle("Show webcam", isOn: webcamOverlayEnabled)
                    if session.document.webcamOverlay.enabled {
                        Picker("Shape", selection: webcamOverlayShape) {
                            Text("Circle").tag(WebcamOverlayShape.circle)
                            Text("Rounded").tag(WebcamOverlayShape.roundedRectangle)
                        }
                        .pickerStyle(.segmented)

                        labeledSlider(
                            "Horizontal position",
                            value: webcamOverlayPositionX,
                            range: 0...1,
                            format: "%.0f%%",
                            actionName: "Move Webcam Overlay",
                            step: 0.01,
                            displayScale: 100
                        )
                        labeledSlider(
                            "Vertical position",
                            value: webcamOverlayPositionY,
                            range: 0...1,
                            format: "%.0f%%",
                            actionName: "Move Webcam Overlay",
                            step: 0.01,
                            displayScale: 100
                        )
                        labeledSlider(
                            "Size",
                            value: webcamOverlaySize,
                            range: WebcamOverlaySettings.sizeRange,
                            format: "%.0f%%",
                            actionName: "Resize Webcam Overlay",
                            step: 0.01,
                            displayScale: 100
                        )
                        labeledSlider(
                            "Border",
                            value: webcamOverlayBorderWidth,
                            range: WebcamOverlaySettings.borderWidthRange,
                            format: "%.0f px",
                            actionName: "Change Webcam Border",
                            step: 1
                        )
                        Toggle("Shadow", isOn: webcamOverlayShadow)
                        Button("Reset Position and Size") {
                            session.updateWebcamOverlay(actionName: "Reset Webcam Overlay") {
                                $0.position = WebcamOverlaySettings.defaultPosition
                                $0.size = WebcamOverlaySettings.defaultSize
                            }
                        }
                        Text("Click the webcam in the preview to select it, then drag it or use its lower-right resize handle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("This project has no recording/webcam.mp4. Add that file to the project bundle to use a webcam overlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Speed") {
                if let segment = session.selectedSpeedSegment {
                    labeledSlider(
                        "Rate",
                        value: selectedSpeedRate,
                        range: SpeedSegment.rateRange,
                        format: "%.2f×",
                        actionName: "Change Playback Speed",
                        step: 0.25
                    )
                    LabeledContent("Start", value: Timecode.string(segment.start))
                    LabeledContent("End", value: Timecode.string(segment.end))
                    Text("Drag the orange or blue region and its edges on the timeline to adjust it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete Speed Region", role: .destructive) {
                        session.deleteSelectedTimelineItem()
                    }
                } else {
                    Text("Add a speed region at the playhead, then choose 0.25×–4× playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Speed Region at Playhead") {
                        session.addSpeedAtPlayhead()
                    }
                    .disabled(!session.canAddSpeedAtPlayhead)
                }
                Toggle("Mute audio in sped-up regions", isOn: muteAudioWhenSpedUp)
            }

            Section("Audio") {
                if session.hasMicrophoneAudio {
                    labeledSlider(
                        "Microphone",
                        value: microphoneGain,
                        range: AudioCleanupSettings.gainRange,
                        format: "%.0f%%",
                        actionName: "Change Microphone Level",
                        step: 0.05,
                        displayScale: 100
                    )
                    Toggle("Normalize microphone", isOn: normalizeMicrophone)
                    Toggle("Microphone noise gate", isOn: microphoneNoiseGate)
                    if session.document.audioCleanup.noiseGateEnabled {
                        labeledSlider(
                            "Gate threshold",
                            value: noiseGateThreshold,
                            range: AudioCleanupSettings.noiseGateThresholdRange,
                            format: "%.0f dB",
                            actionName: "Change Noise Gate",
                            step: 1
                        )
                    }
                    Toggle("Remove microphone clicks", isOn: deClickMicrophone)
                }
                if session.hasSystemAudio {
                    labeledSlider(
                        "System audio",
                        value: systemGain,
                        range: AudioCleanupSettings.gainRange,
                        format: "%.0f%%",
                        actionName: "Change System Audio Level",
                        step: 0.05,
                        displayScale: 100
                    )
                }
                if !session.hasMicrophoneAudio, !session.hasSystemAudio {
                    Text("This project has no microphone or system-audio track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Cleanup is local, non-destructive, and applied when video or audio is exported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Picker("Codec", selection: exportCodec) {
                    Text("H.264").tag(VideoExportCodec.h264)
                    Text("HEVC").tag(VideoExportCodec.hevc)
                    Text("ProRes 422").tag(VideoExportCodec.proRes422)
                }
                Picker("Resolution", selection: exportResolution) {
                    Text("Source").tag(ExportResolutionPreset.source)
                    Text("720p").tag(ExportResolutionPreset.p720)
                    Text("1080p").tag(ExportResolutionPreset.p1080)
                    Text("4K").tag(ExportResolutionPreset.p2160)
                }
                Button("Export Video…") {
                    session.presentExportPanel(kind: .video)
                }
                .disabled(session.exportProgress != nil)
                HStack {
                    Button("GIF…") { session.presentExportPanel(kind: .gif) }
                    Button("Audio…") { session.presentExportPanel(kind: .audio) }
                    Button("Snapshot…") { session.presentExportPanel(kind: .snapshot) }
                }
                .disabled(session.exportProgress != nil)
                Text("Video uses the selected codec and resolution. GIF, mixed M4A audio, and a PNG of the current playhead are available separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .confirmationDialog(
            "Regenerate Automatic Zooms?",
            isPresented: $confirmRegenerateZooms,
            titleVisibility: .visible
        ) {
            Button("Regenerate") {
                session.regenerateAutoZooms()
            }
        } message: {
            Text("Automatic zooms will be regenerated from clicks, dwell, and cursor activity. Locked and manual zooms are preserved.")
        }
    }

    private var autoZoomControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sensitivity", selection: autoZoomSensitivity) {
                Text("Subtle").tag(AutoZoomSensitivity.subtle)
                Text("Normal").tag(AutoZoomSensitivity.normal)
                Text("Aggressive").tag(AutoZoomSensitivity.aggressive)
            }

            Picker("Easing", selection: zoomEasing) {
                Text("Fast").tag(ZoomEasingPreset.fast)
                Text("Smooth").tag(ZoomEasingPreset.smooth)
                Text("Cinematic").tag(ZoomEasingPreset.cinematic)
            }

            Text("Sensitivity applies when auto-zooms are regenerated. Easing updates preview and export immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            regenerateZoomsButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var zoomTracking: Binding<ZoomTrackingMode> {
        Binding(
            get: { session.selectedZoom?.tracking ?? .followCursor },
            set: { value in session.updateSelectedZoom { $0.tracking = value } }
        )
    }

    private var zoomLocked: Binding<Bool> {
        Binding(
            get: { session.selectedZoom?.isLocked ?? false },
            set: { value in session.updateSelectedZoom { $0.isLocked = value } }
        )
    }

    private var selectedCursorVisible: Binding<Bool> {
        Binding(
            get: { session.selectedCursorEffect?.visible ?? true },
            set: { value in session.updateSelectedCursorEffect { $0.visible = value } }
        )
    }

    private var selectedCursorScale: Binding<Double> {
        Binding(
            get: { session.selectedCursorEffect?.scale ?? session.document.canvas.cursorScale },
            set: { value in session.updateSelectedCursorEffect { $0.scale = value } }
        )
    }

    private var selectedCursorClickEmphasis: Binding<Bool> {
        Binding(
            get: { session.selectedCursorEffect?.clickEmphasis ?? true },
            set: { value in session.updateSelectedCursorEffect { $0.clickEmphasis = value } }
        )
    }

    private var selectedCursorHalo: Binding<Bool> {
        Binding(
            get: { session.selectedCursorEffect?.halo ?? false },
            set: { value in session.updateSelectedCursorEffect { $0.halo = value } }
        )
    }

    private var captionText: Binding<String> {
        Binding(
            get: { session.selectedCaption?.text ?? "" },
            set: { value in session.updateSelectedCaption { $0.text = value } }
        )
    }

    private var captionPosition: Binding<CaptionPosition> {
        Binding(
            get: { session.selectedCaption?.style.position ?? .bottom },
            set: { value in session.updateSelectedCaption { $0.style.position = value } }
        )
    }

    private var captionFontSize: Binding<Double> {
        Binding(
            get: { session.selectedCaption?.style.fontSize ?? CaptionStyle.default.fontSize },
            set: { value in session.updateSelectedCaption { $0.style.fontSize = value } }
        )
    }

    private var captionMaxWidth: Binding<Double> {
        Binding(
            get: { session.selectedCaption?.style.maxWidth ?? CaptionStyle.default.maxWidth },
            set: { value in session.updateSelectedCaption { $0.style.maxWidth = value } }
        )
    }

    private var captionForeground: Binding<Color> {
        Binding(
            get: { session.selectedCaption?.style.foreground.swiftUIColor ?? .white },
            set: { value in session.updateSelectedCaption { $0.style.foreground = RGBAColor(value) } }
        )
    }

    private var captionBackground: Binding<Color> {
        Binding(
            get: { session.selectedCaption?.style.background.swiftUIColor ?? .black },
            set: { value in session.updateSelectedCaption { $0.style.background = RGBAColor(value) } }
        )
    }

    private var annotationKind: Binding<AnnotationKind> {
        Binding(
            get: { session.selectedAnnotation?.kind ?? .text },
            set: { value in session.updateSelectedAnnotation { $0.kind = value } }
        )
    }

    private var annotationText: Binding<String> {
        Binding(
            get: { session.selectedAnnotation?.text ?? "" },
            set: { value in session.updateSelectedAnnotation { $0.text = value } }
        )
    }

    private var annotationFontSize: Binding<Double> {
        Binding(
            get: { session.selectedAnnotation?.fontSize ?? 42 },
            set: { value in session.updateSelectedAnnotation { $0.fontSize = value } }
        )
    }

    private var annotationDimAmount: Binding<Double> {
        Binding(
            get: { session.selectedAnnotation?.dimAmount ?? 0.58 },
            set: { value in session.updateSelectedAnnotation { $0.dimAmount = value } }
        )
    }

    private var annotationColor: Binding<Color> {
        Binding(
            get: { session.selectedAnnotation?.color.swiftUIColor ?? .red },
            set: { value in session.updateSelectedAnnotation { $0.color = RGBAColor(value) } }
        )
    }

    private var exportCodec: Binding<VideoExportCodec> {
        Binding(
            get: { session.document.videoExportSettings.codec },
            set: { value in session.updateVideoExportSettings { $0.codec = value } }
        )
    }

    private var exportResolution: Binding<ExportResolutionPreset> {
        Binding(
            get: { session.document.videoExportSettings.resolution },
            set: { value in session.updateVideoExportSettings { $0.resolution = value } }
        )
    }

    private var autoZoomSensitivity: Binding<AutoZoomSensitivity> {
        Binding(
            get: { session.document.autoZoomSensitivity },
            set: { session.updateAutoZoomSensitivity($0) }
        )
    }

    private var zoomEasing: Binding<ZoomEasingPreset> {
        Binding(
            get: { session.document.zoomEasing },
            set: { session.updateZoomEasing($0) }
        )
    }

    private var cursorMotionBlurEnabled: Binding<Bool> {
        Binding(
            get: { session.document.canvas.cursorMotionBlur.enabled },
            set: { enabled in
                session.updateCanvas(actionName: "Toggle Cursor Motion Blur") {
                    $0.cursorMotionBlur.enabled = enabled
                }
            }
        )
    }

    private var cursorClickEmphasis: Binding<Bool> {
        Binding(
            get: { session.document.canvas.cursorClickEmphasis },
            set: { enabled in
                session.updateCanvas(actionName: "Toggle Cursor Click Emphasis") {
                    $0.cursorClickEmphasis = enabled
                }
            }
        )
    }

    private var cursorHalo: Binding<Bool> {
        Binding(
            get: { session.document.canvas.cursorHalo },
            set: { enabled in
                session.updateCanvas(actionName: "Toggle Cursor Halo") {
                    $0.cursorHalo = enabled
                }
            }
        )
    }

    private var cursorMotionBlurAmount: Binding<Double> {
        Binding(
            get: { session.document.canvas.cursorMotionBlur.amount },
            set: { amount in
                session.updateCanvas(actionName: "Change Cursor Motion Blur") {
                    $0.cursorMotionBlur.amount = amount
                }
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

    private var webcamOverlayEnabled: Binding<Bool> {
        Binding(
            get: { session.document.webcamOverlay.enabled },
            set: { enabled in
                session.updateWebcamOverlay(actionName: "Toggle Webcam Overlay") {
                    $0.enabled = enabled
                }
                if enabled {
                    session.selectWebcam()
                }
            }
        )
    }

    private var webcamOverlayShape: Binding<WebcamOverlayShape> {
        Binding(
            get: { session.document.webcamOverlay.shape },
            set: { shape in
                session.updateWebcamOverlay(actionName: "Change Webcam Shape") {
                    $0.shape = shape
                }
            }
        )
    }

    private var webcamOverlaySize: Binding<Double> {
        Binding(
            get: { session.document.webcamOverlay.size },
            set: { size in
                session.updateWebcamOverlay(actionName: "Resize Webcam Overlay") {
                    $0.size = size
                }
            }
        )
    }

    private var webcamOverlayPositionX: Binding<Double> {
        Binding(
            get: { session.document.webcamOverlay.position.x },
            set: { x in
                session.updateWebcamOverlay(actionName: "Move Webcam Overlay") {
                    $0.position.x = x
                }
            }
        )
    }

    private var webcamOverlayPositionY: Binding<Double> {
        Binding(
            get: { session.document.webcamOverlay.position.y },
            set: { y in
                session.updateWebcamOverlay(actionName: "Move Webcam Overlay") {
                    $0.position.y = y
                }
            }
        )
    }

    private var webcamOverlayBorderWidth: Binding<Double> {
        Binding(
            get: { session.document.webcamOverlay.borderWidth },
            set: { width in
                session.updateWebcamOverlay(actionName: "Change Webcam Border") {
                    $0.borderWidth = width
                }
            }
        )
    }

    private var webcamOverlayShadow: Binding<Bool> {
        Binding(
            get: { session.document.webcamOverlay.shadow },
            set: { shadow in
                session.updateWebcamOverlay(actionName: "Toggle Webcam Shadow") {
                    $0.shadow = shadow
                }
            }
        )
    }

    private var selectedSpeedRate: Binding<Double> {
        Binding(
            get: { session.selectedSpeedSegment?.rate ?? 1 },
            set: { session.updateSelectedSpeedRate($0) }
        )
    }

    private var muteAudioWhenSpedUp: Binding<Bool> {
        Binding(
            get: { session.document.muteAudioWhenSpedUp },
            set: { session.setMuteAudioWhenSpedUp($0) }
        )
    }

    private var microphoneGain: Binding<Double> {
        audioBinding(\.microphoneGain, actionName: "Change Microphone Level")
    }

    private var systemGain: Binding<Double> {
        audioBinding(\.systemGain, actionName: "Change System Audio Level")
    }

    private var normalizeMicrophone: Binding<Bool> {
        audioBinding(\.normalizeEnabled, actionName: "Toggle Microphone Normalization")
    }

    private var microphoneNoiseGate: Binding<Bool> {
        audioBinding(\.noiseGateEnabled, actionName: "Toggle Microphone Noise Gate")
    }

    private var noiseGateThreshold: Binding<Double> {
        audioBinding(\.noiseGateThresholdDB, actionName: "Change Noise Gate")
    }

    private var deClickMicrophone: Binding<Bool> {
        audioBinding(\.deClickEnabled, actionName: "Toggle Microphone De-Click")
    }

    private func audioBinding<Value>(
        _ keyPath: WritableKeyPath<AudioCleanupSettings, Value>,
        actionName: String
    ) -> Binding<Value> {
        Binding(
            get: { session.document.audioCleanup[keyPath: keyPath] },
            set: { value in
                session.updateAudioCleanup(actionName: actionName) {
                    $0[keyPath: keyPath] = value
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
        step: Double? = nil,
        displayScale: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * displayScale))
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
