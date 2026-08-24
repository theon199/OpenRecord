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
                    model.isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "folder")
                }
                .help("Library folder")
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
