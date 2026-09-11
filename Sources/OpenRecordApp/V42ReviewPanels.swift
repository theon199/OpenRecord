import OpenRecord
import SwiftUI

struct FirstCutReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("First Cut", systemImage: "wand.and.stars")
                    .font(.title2.weight(.semibold))
                Spacer()
                if session.analysisPhase == .firstCut {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { session.cancelAnalysis() }
                }
            }

            Text("Build a local, reviewable draft. Nothing changes in the project until you apply suggestions.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Intent", selection: $session.firstCutPreset) {
                    ForEach(FirstCutPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Transcribe locally when needed", isOn: $session.firstCutTranscribesWhenAvailable)
                    .toggleStyle(.checkbox)
                Button(session.firstCutPlan == nil ? "Generate" : "Regenerate") {
                    session.generateFirstCut()
                }
                .disabled(session.isAnalysisCancellable)
            }

            if let plan = session.firstCutPlan, !plan.proposals.isEmpty {
                List(plan.proposals) { proposal in
                    FirstCutProposalRow(session: session, proposal: proposal)
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "No First Cut Suggestions",
                    systemImage: "wand.and.stars",
                    description: Text("Generate a draft to review cuts, pacing, zooms, captions, and chapters.")
                )
            }

            if let message = session.firstCutStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Keep Current Edit") {
                    session.rejectAllFirstCutProposals()
                    dismiss()
                }
                Spacer()
                Button("Apply Selected") {
                    session.applySelectedFirstCutProposals()
                    dismiss()
                }
                .disabled(session.selectedFirstCutProposalIDs.isEmpty)
                Button("Apply All") {
                    session.applyAllFirstCutProposals()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.firstCutPlan?.proposals.contains(where: \.isActionable) != true)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct FirstCutProposalRow: View {
    @Bindable var session: EditorSession
    let proposal: FirstCutProposal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { session.selectedFirstCutProposalIDs.contains(proposal.id) },
                    set: { session.setFirstCutProposal(proposal.id, accepted: $0) }
                )
            )
            .labelsHidden()
            .disabled(proposal.state == .stale)

            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(proposal.state == .stale ? Color.secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(proposal.kind.label)
                        .font(.headline)
                    Text("\(Timecode.compact(proposal.range.start))–\(Timecode.compact(proposal.range.end))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((proposal.confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(proposal.state.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(proposal.state == .rejected ? .secondary : .primary)
                }
                if !proposal.reasons.isEmpty {
                    Text(proposal.reasons.map { $0.replacingOccurrences(of: "-", with: " ") }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let preview = proposal.preview {
                    Button {
                        session.seek(to: preview.sourceStart)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle")
                            Text(preview.summary)
                            if let before = preview.outputDurationBefore,
                               let after = preview.outputDurationAfter
                            {
                                Text("\(before, specifier: "%.1f")s → \(after, specifier: "%.1f")s")
                                    .monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch proposal.kind {
        case .cut: "scissors"
        case .speed: "gauge.with.dots.needle.67percent"
        case .zoom: "plus.magnifyingglass"
        case .caption: "captions.bubble"
        case .annotation: "pencil.and.outline"
        case .cursorEffect: "cursorarrow.motionlines"
        case .chapter: "bookmark"
        }
    }
}

struct PrivacyReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: EditorSession
    let continuesToExport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Privacy Firewall", systemImage: "checkmark.shield")
                    .font(.title2.weight(.semibold))
                Spacer()
                if session.analysisPhase == .privacy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { session.cancelAnalysis() }
                }
            }

            Label(
                "Detection is local and best effort; it can miss private content. The editable source bundle is not sanitized.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sensitive terms (comma or line separated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $session.privacySensitiveTerms)
                        .font(.body)
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Look for faces", isOn: $session.privacyDetectFaces)
                    Toggle("Look for names", isOn: $session.privacyDetectNames)
                    Text("Face and name checks are opt-in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                Button(session.privacyFindings.isEmpty ? "Scan" : "Scan Again") {
                    session.analyzePrivacy()
                }
                .disabled(session.isAnalysisCancellable)
            }

            privacySummary

            if session.privacyFindings.isEmpty {
                ContentUnavailableView(
                    "No Findings to Review",
                    systemImage: "checkmark.shield",
                    description: Text("Run a scan, then manually review the finished video before sharing.")
                )
            } else {
                List(session.privacyFindings) { finding in
                    PrivacyFindingRow(session: session, finding: finding)
                }
                .listStyle(.inset)
            }

            if let message = session.privacyStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }
                Button("Sanitized Share Copy…") {
                    dismiss()
                    session.presentSanitizedShareCopyPanel()
                }
                Spacer()
                if continuesToExport {
                    Button("Continue to Export…") {
                        dismiss()
                        session.continueAfterPrivacyReview()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 620)
    }

    private var privacySummary: some View {
        HStack(spacing: 18) {
            summary("Possible", session.privacyFindings.filter(\.isPossible).count)
            summary("Accepted masks", session.privacyFindings.filter(\.isAccepted).count)
            summary("Verified masks", session.privacyReport?.verifiedMaskCount ?? 0)
            summary("Rejected", session.privacyFindings.filter { $0.state == .rejected }.count)
            Spacer()
        }
    }

    private func summary(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PrivacyFindingRow: View {
    @Bindable var session: EditorSession
    let finding: PrivacyFinding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: finding.state == .verified ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.category.label).font(.headline)
                    Text("\(Timecode.compact(finding.start))–\(Timecode.compact(finding.end))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("\(finding.confidence.rawValue.capitalized) confidence · \(finding.state.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reject") {
                session.setPrivacyFinding(finding.id, state: .rejected)
            }
            .disabled(finding.state == .rejected)
            Button("Accept Mask") {
                session.setPrivacyFinding(finding.id, state: .accepted, materialize: true)
            }
            .disabled(finding.isAccepted)
            Button("Edit Mask") {
                session.setPrivacyFinding(finding.id, state: .accepted, materialize: true)
                session.presentedReviewSheet = nil
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch finding.state {
        case .verified: .green
        case .accepted: .blue
        case .rejected, .stale: .secondary
        case .pending: .orange
        }
    }
}

private extension FirstCutProposalKind {
    var label: String {
        switch self {
        case .cut: "Cut"
        case .speed: "Speed region"
        case .zoom: "Zoom"
        case .caption: "Caption"
        case .annotation: "Annotation"
        case .cursorEffect: "Cursor effect"
        case .chapter: "Chapter"
        }
    }
}

private extension PrivacyCategory {
    var label: String { rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
}

private extension PrivacyFindingState {
    var label: String {
        switch self {
        case .pending: "Possible finding"
        case .accepted: "Accepted mask"
        case .rejected: "Rejected"
        case .stale: "Stale evidence"
        case .verified: "Verified accepted mask"
        }
    }
}
