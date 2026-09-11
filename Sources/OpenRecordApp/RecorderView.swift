import OpenRecord
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var isPickingSource: Bool {
        model.countdownRemaining == nil && !model.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let remaining = model.countdownRemaining {
                countdown(remaining)
            } else if model.isRecording {
                recordingStatus
            } else {
                sourcePicker
            }
            controls
        }
        .padding(22)
        .frame(width: isPickingSource ? 720 : 400)
        .interactiveDismissDisabled(model.isRecording || model.countdownRemaining != nil)
        .task {
            await model.reloadCaptureSources()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Recording")
                    .font(.title3.weight(.semibold))
                Text("⌃⌥⌘R starts and stops from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func countdown(_ remaining: Int) -> some View {
        VStack(spacing: 8) {
            Text("\(remaining)")
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
            Text(model.selectedSource?.title ?? "Recording")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .animation(.snappy, value: remaining)
    }

    private var recordingStatus: some View {
        VStack(spacing: 8) {
            Text(Timecode.compact(model.recordedDuration))
                .font(.system(size: 36, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text(model.selectedSource?.title ?? "Recording")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if model.capturesMicrophone {
                Button(model.isMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone") {
                    model.toggleRecordingMicrophoneMuted()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.reloadCaptureSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoadingSources)
                .help("Refresh displays and windows")
            }

            Group {
                if model.isLoadingSources && model.captureSources.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .frame(minHeight: 240)
                } else {
                    sourceOverview
                }
            }

            Picker("Project template", selection: $model.selectedProjectTemplateID) {
                Text("None").tag(String?.none)
                ForEach(model.projectTemplates) { template in
                    Text(template.name).tag(String?.some(template.id))
                }
            }
            .pickerStyle(.menu)
            Text("Templates copy portable canvas, cursor, webcam, caption, annotation, device-frame, keyboard, and export defaults into the new project. They never contain recorded media.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Record keyboard shortcuts",
                isOn: $model.capturesKeyboardShortcuts
            )
            .toggleStyle(.switch)
            Text("Shortcut chords and navigation keys are recorded for the overlay. Ordinary typing and Secure Input are omitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record cursor activity", isOn: $model.capturesCursorTelemetry)
                .toggleStyle(.switch)
            Text("Stores cursor, click, and window-focus telemetry for editing and auto-zoom. Accessibility permission is requested when this or keyboard shortcuts is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record semantic UI interactions", isOn: $model.capturesSemanticTargets)
                .toggleStyle(.switch)
            Text("Optional privacy-filtered UI semantics make the ActionMap searchable. Control labels are filtered; ordinary typing and secure values are omitted. The story-beat marker is ⌃⌥⌘M while recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record microphone", isOn: $model.capturesMicrophone)
                .toggleStyle(.switch)
            Text("Adds a local microphone track. Microphone permission is requested only when this is enabled and you start recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record system audio", isOn: $model.capturesSystemAudio)
                .toggleStyle(.switch)
            Text("Adds a local system-audio track. System audio does not require a separate permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record webcam", isOn: $model.capturesWebcam)
                .toggleStyle(.switch)
            Text("Uses the default camera. A live circular preview appears while you record so you can see how you look; the same picture-in-picture is composited in the editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceOverview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !model.displaySources.isEmpty {
                    sourceSection(title: "Displays", sources: model.displaySources)
                }
                if !model.windowSources.isEmpty {
                    sourceSection(title: "Windows", sources: model.windowSources)
                }
            }
            .padding(10)
        }
        .frame(minHeight: 280, maxHeight: 420)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceSection(title: String, sources: [CaptureSourceOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 10)],
                spacing: 10
            ) {
                ForEach(sources) { source in
                    sourceCard(source)
                }
            }
        }
    }

    private func sourceCard(_ source: CaptureSourceOption) -> some View {
        let selected = model.selectedSourceID == source.id
        return Button {
            model.selectedSourceID = source.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                sourcePreview(source, selected: selected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !source.subtitle.isEmpty {
                        Text(source.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(source.subtitle.isEmpty ? source.title : "\(source.title), \(source.subtitle)")
    }

    private func sourcePreview(_ source: CaptureSourceOption, selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.18))
            if let thumbnail = model.captureSourceThumbnails[source.id] {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let icon = model.captureSourceIcons[source.id] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: source.isDisplay ? "display" : "macwindow")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let icon = model.captureSourceIcons[source.id],
               model.captureSourceThumbnails[source.id] != nil {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .padding(6)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
        }
    }

    private var controls: some View {
        HStack {
            if model.countdownRemaining != nil {
                Button("Cancel") {
                    model.cancelCountdown()
                }
                Spacer()
            } else if model.isRecording {
                Spacer()
                Button("Stop", role: .destructive) {
                    Task { await model.stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record") {
                    Task { await model.startCountdownAndRecord() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedSource == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
