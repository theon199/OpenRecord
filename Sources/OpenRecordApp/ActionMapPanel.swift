import AppKit
import OpenRecord
import SwiftUI

/// A compact, local-only ActionMap inspector.  The panel intentionally keeps
/// transcript phrases in memory for filtering; they are never copied into
/// the rebuildable actions sidecar or authored story beats.
struct ActionMapPanel: View {
    @Bindable var session: EditorSession
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchControls
            Divider()
            rows
            if let row = session.selectedActionMapRow {
                Divider()
                detail(for: row)
            }
        }
        .padding(12)
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420)
        .onChange(of: session.selectedActionCandidateIDs) { _, _ in
            syncRenameText()
        }
        .onChange(of: session.selectedStoryBeatIDs) { _, _ in
            syncRenameText()
        }
        .onAppear { syncRenameText() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("ActionMap", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Spacer()
            switch session.actionMapStatus {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                Text("Local")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            case .unavailable, .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ActionMap")
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search actions or transcript", text: $session.actionMapSearchText)
                    .textFieldStyle(.roundedBorder)
                if !session.actionMapSearchText.isEmpty {
                    Button {
                        session.actionMapSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            HStack(spacing: 8) {
                Button {
                    session.rebuildActionMap()
                } label: {
                    Label(
                        session.actionMapStatus == .loading ? "Building…" : "Build / Rebuild",
                        systemImage: session.actionMapStatus == .loading
                            ? "arrow.triangle.2.circlepath"
                            : "wand.and.stars"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isAnalysisCancellable)
                .help("Build a private ActionMap from local recording evidence")

                Toggle("Show suppressed", isOn: $session.revealSuppressedActionMapRows)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            Text(session.actionMapStatusMessage ?? "Actions are inferred locally from privacy-filtered evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rows: some View {
        Group {
            if session.actionMapRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(session.actionMapSearchText.isEmpty
                        ? "No actions yet"
                        : "No matching actions")
                        .font(.subheadline.weight(.semibold))
                    Text(session.actionMapSearchText.isEmpty
                        ? "Build an ActionMap to index this recording, or add a story beat after seeking."
                        : "Try an approved label, app bundle ID, chapter, step, or a spoken phrase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(session.actionMapRows) { row in
                            ActionMapRowView(
                                row: row,
                                coverage: session.actionMapCoverage(for: row),
                                isSelected: session.selectedActionMapRows.contains(row),
                                onSelect: {
                                    let extending = NSEvent.modifierFlags.contains(.shift)
                                    session.selectActionMapRow(row, extending: extending)
                                    renameText = row.title
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func detail(for row: ActionMapRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.selectedActionMapRows.count > 1
                    ? "\(session.selectedActionMapRows.count) selected"
                    : "Selected action")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Timecode.compact(row.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if session.selectedActionMapRows.count == 1 {
                HStack(spacing: 6) {
                    TextField("Action label", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                    Button("Rename") {
                        session.renameSelectedAction(to: renameText)
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            actionButtons
            if row.confidence > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Confidence")
                        Spacer()
                        Text("\(Int((row.confidence * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    ProgressView(value: min(max(row.confidence, 0), 1))
                        .tint(confidenceColor(row.confidence))
                }
                .font(.caption)
            }
            if !row.supportingSignals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Supporting signals")
                        .font(.caption.weight(.semibold))
                    ForEach(row.supportingSignals, id: \.self) { signal in
                        Label(signal, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Label(row.kindLabel, systemImage: "tag")
                Label(row.sourceLabel, systemImage: "waveform.path")
                Label(session.actionMapCoverage(for: row).label, systemImage: coverageSymbol(for: row))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                operationButtons
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) { operationButtons }
            }
        }
    }

    @ViewBuilder
    private var operationButtons: some View {
        Button("Merge") { session.mergeSelectedActions() }
            .disabled(session.selectedActionMapRows.count < 2)
        Button("Split") { session.splitSelectedAction() }
            .disabled(session.selectedActionMapRows.count != 1)
        Button(session.selectedActionMapRows.contains(where: \.isSuppressed) ? "Restore" : "Suppress") {
            session.setSelectedActionsSuppressed(!session.selectedActionMapRows.allSatisfy(\.isSuppressed))
        }
        .disabled(session.selectedActionMapRows.isEmpty)
        Button(session.selectedActionMapRows.contains(where: \.isLocked) ? "Unlock" : "Lock") {
            session.setSelectedActionsLocked(!session.selectedActionMapRows.allSatisfy(\.isLocked))
        }
        .disabled(session.selectedActionMapRows.isEmpty)
        Menu("Convert") {
            Button("Chapter") { session.convertSelectedActionToChapter() }
            Button("Numbered Step") { session.convertSelectedActionToStep() }
            Divider()
            Button("Zoom") { session.convertSelectedActionToZoom() }
            Button("Annotation") { session.convertSelectedActionToAnnotation() }
        }
        .disabled(session.selectedActionMapRows.count != 1)
        .menuStyle(.borderlessButton)
    }

    private func syncRenameText() {
        guard let row = session.selectedActionMapRow else { return }
        renameText = row.title
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        confidence >= 0.8 ? .green : confidence >= 0.5 ? .orange : .secondary
    }

    private func coverageSymbol(for row: ActionMapRow) -> String {
        switch session.actionMapCoverage(for: row) {
        case .included: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .cut: "scissors"
        }
    }
}

private struct ActionMapRowView: View {
    let row: ActionMapRow
    let coverage: ActionMapRangeCoverage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .frame(width: 17)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if row.isAuthored {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if row.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(row.kindLabel)
                        if let bundle = row.applicationBundleID {
                            Text(bundle).lineLimit(1)
                        }
                        Text(Timecode.compact(row.start))
                            .monospacedDigit()
                        Text(coverage.label)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if row.confidence > 0 {
                    Text("\(Int((row.confidence * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.title), \(row.kindLabel), \(coverage.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var iconName: String {
        switch row.storyBeatKind {
        case .chapter: "bookmark"
        case .step: "list.number"
        case .marker: "flag"
        case .action: "cursorarrow.click"
        }
    }

    private var iconColor: Color {
        switch coverage {
        case .included: .accentColor
        case .partial: .orange
        case .cut: .secondary
        }
    }
}
