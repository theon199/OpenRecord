import OpenRecord
import SwiftUI

struct RecorderView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
        .frame(width: 400)
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
                    .frame(minHeight: 160)
                } else {
                    List(selection: $model.selectedSourceID) {
                        if !model.displaySources.isEmpty {
                            Section("Displays") {
                                ForEach(model.displaySources) { source in
                                    sourceRow(source)
                                }
                            }
                        }
                        if !model.windowSources.isEmpty {
                            Section("Windows") {
                                ForEach(model.windowSources) { source in
                                    sourceRow(source)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 200, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Toggle(
                "Record keyboard shortcuts",
                isOn: $model.capturesKeyboardShortcuts
            )
            .toggleStyle(.switch)
            Text("Shortcut chords and navigation keys are recorded for the overlay. Ordinary typing and Secure Input are omitted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Record webcam", isOn: $model.capturesWebcam)
                .toggleStyle(.switch)
            Text("Uses the default camera and records a separate, movable picture-in-picture track. Camera permission is requested when recording starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceRow(_ source: CaptureSourceOption) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(source.title)
                .lineLimit(1)
            if !source.subtitle.isEmpty {
                Text(source.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tag(source.id)
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
