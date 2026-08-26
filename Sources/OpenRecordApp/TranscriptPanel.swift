import AppKit
import OpenRecord
import SwiftUI

struct TranscriptPanel: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transcript", systemImage: "quote.bubble")
                    .font(.headline)
                Spacer()
                transcriptionMenu
            }

            TextField("Search spoken text", text: $session.transcriptSearchText)
                .textFieldStyle(.roundedBorder)

            if session.document.transcript.isEmpty {
                ContentUnavailableView {
                    Label("No Transcript", systemImage: "waveform")
                } description: {
                    Text("Generate speech text locally from the microphone, system audio, or both.")
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                transcriptList
                transcriptActions
            }

            Divider()
            silenceControls

            if let status = session.transcriptionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minHeight: 250)
    }

    private var transcriptionMenu: some View {
        Menu {
            Button("Microphone") { session.transcribe(source: .microphone) }
                .disabled(!session.hasMicrophoneAudio)
            Button("System Audio") { session.transcribe(source: .systemAudio) }
                .disabled(!session.hasSystemAudio)
            Button("Mixed Microphone + System") { session.transcribe(source: .mixed) }
                .disabled(!session.hasMicrophoneAudio && !session.hasSystemAudio)
        } label: {
            if session.isTranscribing {
                ProgressView().controlSize(.small)
            } else {
                Label("Transcribe", systemImage: "waveform.badge.mic")
            }
        }
        .disabled(session.isTranscribing)
        .help("Uses Apple on-device speech recognition; no account or network service is required")
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(session.filteredTranscript) { segment in
                    let selected = session.selectedTranscriptSegmentIDs.contains(segment.id)
                    let visibility = transcriptVisibility(segment)
                    Button {
                        session.selectTranscriptSegment(
                            segment.id,
                            extending: NSEvent.modifierFlags.contains(.shift)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(Timecode.compact(segment.start))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(segment.source.label)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if segment.editedText != nil {
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if visibility == .removed {
                                    Text("Removed")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                } else if visibility == .partial {
                                    Text("Partially cut")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text(segment.displayText)
                                .font(.callout)
                                .foregroundStyle(
                                    visibility == .removed ? Color.secondary : Color.primary
                                )
                                .strikethrough(visibility == .removed, color: .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(6)
                        .background(
                            selected ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 100, maxHeight: 210)
    }

    @ViewBuilder
    private var transcriptActions: some View {
        if session.selectedTranscriptSegmentIDs.count == 1,
           let id = session.selectedTranscriptSegmentIDs.first,
           let segment = session.document.transcript.first(where: { $0.id == id })
        {
            TextField(
                "Correct recognized text",
                text: Binding(
                    get: { segment.displayText },
                    set: { session.updateTranscriptSegmentText(id, text: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
        }

        HStack {
            Button("Remove Selection") { session.cutSelectedTranscript() }
                .disabled(session.selectedTranscriptSegmentIDs.isEmpty)
            Spacer()
            Menu("Generate Captions") {
                Button("Keep Existing Captions") {
                    session.generateCaptionsFromTranscript(overwrite: false)
                }
                Button("Replace Existing Captions") {
                    session.generateCaptionsFromTranscript(overwrite: true)
                }
            }
        }
        .controlSize(.small)
    }

    private var silenceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pause removal")
                    .font(.subheadline.weight(.semibold))
                Picker(
                    "Pacing",
                    selection: Binding(
                        get: { session.silencePreset },
                        set: { session.selectSilencePreset($0) }
                    )
                ) {
                    ForEach(SilencePreset.allCases, id: \.self) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            LabeledContent("Minimum pause") {
                Text(String(format: "%.1f s", session.silenceMinimumPause))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $session.silenceMinimumPause, in: 0.2...3, step: 0.1)
            LabeledContent("Breathing room") {
                Text(String(format: "%.2f s", session.silenceBreathingRoom))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $session.silenceBreathingRoom, in: 0...0.5, step: 0.05)

            HStack {
                Menu("Analyze") {
                    Button("Microphone") { session.analyzeSilence(source: .microphone) }
                        .disabled(!session.hasMicrophoneAudio)
                    Button("System Audio") { session.analyzeSilence(source: .systemAudio) }
                        .disabled(!session.hasSystemAudio)
                    Button("Mixed") { session.analyzeSilence(source: .mixed) }
                        .disabled(!session.hasMicrophoneAudio && !session.hasSystemAudio)
                }
                .disabled(session.isAnalyzingSilence)
                if session.isAnalyzingSilence {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(
                    session.isPreviewingSilenceSuggestions ? "Stop Preview" : "Preview Accepted"
                ) {
                    session.toggleSilencePreview()
                }
                .disabled(session.acceptedSilenceSuggestionIDs.isEmpty)
                Button("Apply Accepted") { session.applyAcceptedSilenceSuggestions() }
                    .disabled(session.acceptedSilenceSuggestionIDs.isEmpty)
            }
            .controlSize(.small)

            if !session.silenceSuggestions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(session.silenceSuggestions) { suggestion in
                            HStack(spacing: 6) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { session.acceptedSilenceSuggestionIDs.contains(suggestion.id) },
                                        set: { _ in session.toggleSilenceSuggestion(suggestion.id) }
                                    )
                                )
                                .labelsHidden()
                                Button {
                                    session.seek(to: suggestion.cutStart)
                                } label: {
                                    Text("\(Timecode.compact(suggestion.cutStart))–\(Timecode.compact(suggestion.cutEnd))")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Text(suggestion.source.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
        }
    }

    private func transcriptVisibility(_ segment: TranscriptSegment) -> TranscriptVisibility {
        let duration = max(segment.end - segment.start, 0)
        guard duration > 0 else { return .removed }
        let included = session.projectTimeMapper.slices.reduce(0.0) { partial, slice in
            partial + max(min(segment.end, slice.sourceEnd) - max(segment.start, slice.sourceStart), 0)
        }
        if included <= 0.000_1 { return .removed }
        if included < duration - 0.000_1 { return .partial }
        return .included
    }
}

private enum TranscriptVisibility {
    case included
    case partial
    case removed
}

private extension TranscriptSource {
    var label: String {
        switch self {
        case .microphone: "Mic"
        case .systemAudio: "System"
        case .mixed: "Mixed"
        }
    }
}

private extension SilencePreset {
    var label: String {
        switch self {
        case .natural: "Natural"
        case .tight: "Tight"
        case .fast: "Fast"
        }
    }
}

private extension PauseSuggestionSource {
    var label: String {
        switch self {
        case .audio: "Audio"
        case .transcriptGap: "Transcript"
        case .audioAndTranscript: "Both"
        }
    }
}
