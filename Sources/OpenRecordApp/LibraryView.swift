import OpenRecord
import SwiftUI

struct LibrarySidebar: View {
    @Bindable var model: AppModel
    @State private var pendingDelete: LibraryItem?
    @State private var pendingRename: LibraryItem?
    @State private var renameText = ""

    var body: some View {
        List(selection: $model.selectedProjectURL) {
            Section("Projects") {
                if model.projects.isEmpty {
                    Text("No recordings yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.projects) { item in
                    HStack(spacing: 10) {
                        Toggle(
                            "Include \(item.name) in batch export",
                            isOn: Binding(
                                get: {
                                    model.batchSelectedProjectURLs.contains(
                                        item.url.standardizedFileURL
                                    )
                                },
                                set: { model.setBatchSelected(item.url, selected: $0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        ProjectThumbnailView(image: model.thumbnail(for: item.url))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)
                            if let modified = item.modified {
                                Text(modified, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(item.url)
                    .contextMenu {
                        Button("Rename…") {
                            renameText = item.name
                            pendingRename = item
                        }
                        Button("Reveal in Finder") {
                            model.reveal(item.url)
                        }
                        Divider()
                        Button("Delete…", role: .destructive) {
                            pendingDelete = item
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            pendingDelete = item
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
        .onChange(of: model.selectedProjectURL) { _, url in
            model.selectProject(url)
        }
        .onDeleteCommand {
            if let url = model.selectedProjectURL,
               let item = model.projects.first(where: { $0.url == url })
            {
                pendingDelete = item
            }
        }
        .confirmationDialog(
            "Delete Recording?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                model.deleteProject(item.url)
            }
        } message: { item in
            Text("“\(item.name)” will be moved to the Trash.")
        }
        .alert(
            "Rename Recording",
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                pendingRename = nil
            }
            Button("Rename") {
                if let item = pendingRename {
                    model.renameProject(item.url, to: renameText)
                }
                pendingRename = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The recording and all of its media will stay together in the library.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.presentRecorder(autoStart: false) }
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                .help("New Recording  ⌃⌥⌘R")
                Button {
                    model.presentImportMoviePanel()
                } label: {
                    Label("Import Movie", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isImportingMedia || model.batchExportProgress != nil)
                .help("Import an MP4, MOV, or M4V recording, including device captures")
                Button {
                    model.isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "folder")
                }
                .help("Library folder")
                Button {
                    model.presentBatchExportPanel()
                } label: {
                    Label("Batch Export Selected", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(
                    model.isBatchExportRunning
                        || model.batchSelectedProjectURLs.isEmpty
                        || model.isImportingMedia
                )
                .help("Export selected projects using each project's saved export preset")
                Menu {
                    Button("Select All") { model.selectAllProjectsForBatchExport() }
                    Button("Clear Selection") { model.clearBatchExportSelection() }
                        .disabled(model.batchSelectedProjectURLs.isEmpty)
                } label: {
                    Label("Batch Selection", systemImage: "checklist")
                }
                .disabled(model.projects.isEmpty || model.isBatchExportRunning)
            }
        }
        .overlay {
            if model.isImportingMedia {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Importing movie…")
                        .font(.caption)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if !model.batchExportQueue.jobs.isEmpty {
                batchQueuePanel
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(model.library.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(model.library.rootURL.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.bar)
        }
    }

    private var batchQueuePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.isBatchExportRunning ? "Batch exporting…" : "Batch export")
                    .font(.headline)
                Spacer()
                if model.isBatchExportRunning {
                    Button("Cancel") { model.cancelBatchExport() }
                } else {
                    if model.batchExportQueue.jobs.contains(where: { $0.status == .failed }) {
                        Button("Retry Failed") { model.retryFailedBatchExports() }
                    }
                    Button("Close") { model.clearBatchExportQueue() }
                }
            }
            if let progress = model.batchExportProgress {
                ProgressView(value: progress)
            }
            ForEach(model.batchExportQueue.jobs) { job in
                HStack(spacing: 8) {
                    Image(systemName: batchStatusIcon(job.status))
                        .foregroundStyle(batchStatusColor(job.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.projectURL.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                        Text(batchStatusText(job))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if !model.isBatchExportRunning, job.status == .queued {
                        Button {
                            model.moveBatchExportJob(job.id, offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            model.moveBatchExportJob(job.id, offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if job.status == .running {
                    ProgressView(value: job.progress)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func batchStatusText(_ job: BatchExportJob) -> String {
        switch job.status {
        case .queued: "Queued • \(job.settings.codec.rawValue), \(job.settings.resolution.rawValue)"
        case .running: "Exporting • attempt \(job.attemptCount)"
        case .succeeded: "Complete"
        case .failed: job.lastError.map { "Failed: \($0)" } ?? "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func batchStatusIcon(_ status: BatchExportJobStatus) -> String {
        switch status {
        case .queued: "clock"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func batchStatusColor(_ status: BatchExportJobStatus) -> Color {
        switch status {
        case .queued, .cancelled: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private struct ProjectThumbnailView: View {
    var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "video")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library")
                .font(.title2.weight(.semibold))
            Text("OpenRecord writes `.openrecord` bundles directly into this folder. Choose a Dropbox, Google Drive, or iCloud folder to sync projects with the desktop client — no extra Projects subdirectory is added.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(model.library.rootURL.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Button("Choose Folder…") {
                    model.chooseLibraryFolder()
                }
                .buttonStyle(.borderedProminent)
                Button("Reset to Default") {
                    model.resetLibraryFolder()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
