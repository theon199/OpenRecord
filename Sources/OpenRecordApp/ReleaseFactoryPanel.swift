import AppKit
import Foundation
import OpenRecord
import SwiftUI
import UniformTypeIdentifiers

/// Local, repository-native publishing controls for one open project.
///
/// The panel deliberately receives only the project URL. Publishing reads the
/// project and writes the selected output directory; it does not edit the
/// editor document or any EditorSession state.
@MainActor
struct ReleaseFactoryPanel: View {
    let projectURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var recipeURL: URL?
    @State private var outputDirectoryURL: URL?
    @State private var isPublishing = false
    @State private var isCancelling = false
    @State private var publishTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var manifestURL: URL?

    private var canPublish: Bool {
        recipeURL != nil && outputDirectoryURL != nil && !isPublishing
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Release Factory") {
                    Text("Publish local, repository-native outputs from a versioned recipe. No network service or account is required.")
                        .font(.callout)
                    Label(
                        "Privacy checks are best-effort. Review generated outputs and the manifest before sharing.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Recipe") {
                    LabeledContent("Selected") {
                        Text(recipeURL?.lastPathComponent ?? "None")
                            .foregroundStyle(recipeURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Choose Recipe…", action: chooseRecipe)
                        .disabled(isPublishing)
                    Text("Choose a .json or .openrecordrecipe file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Output") {
                    LabeledContent("Folder") {
                        Text(outputDirectoryURL?.path ?? "None")
                            .foregroundStyle(outputDirectoryURL == nil ? .secondary : .primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Button("Choose Output Folder…", action: chooseOutputDirectory)
                        .disabled(isPublishing)
                    Text("The release manifest and generated assets are written here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isPublishing {
                    Section("Publishing") {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isCancelling ? "Cancelling…" : "Publishing…")
                            Spacer()
                            Button("Cancel", action: cancelPublish)
                                .disabled(isCancelling)
                        }
                        Text("Publishing may render several deterministic outputs. Keep this panel open until it finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let successMessage {
                    Section("Published") {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let manifestURL {
                            Text("Manifest: \(manifestURL.path)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button("Reveal Manifest in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([manifestURL])
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section("Could Not Publish") {
                        Label {
                            Text(errorMessage)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        Text("Check that the project and recipe are readable and that the output folder is writable, then try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)

            Divider()

            HStack {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isPublishing)
                Spacer()
                Button("Publish", action: publish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPublish)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 590)
        .interactiveDismissDisabled(isPublishing)
        .onDisappear {
            if isPublishing {
                publishTask?.cancel()
            }
        }
    }

    private func chooseRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = recipeContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Publish Recipe"
        panel.message = "Choose a .json or .openrecordrecipe publish recipe."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "json" || fileExtension == "openrecordrecipe" else {
            errorMessage = "Choose a recipe ending in .json or .openrecordrecipe."
            successMessage = nil
            manifestURL = nil
            return
        }
        recipeURL = url
        errorMessage = nil
        successMessage = nil
        manifestURL = nil
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Choose Release Output Folder"
        panel.message = "Choose where generated release assets and manifest.json should be written."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectoryURL = url
        errorMessage = nil
        successMessage = nil
        manifestURL = nil
    }

    private func publish() {
        guard !isPublishing,
              let recipeURL,
              let outputDirectoryURL
        else { return }

        errorMessage = nil
        successMessage = nil
        manifestURL = nil
        isPublishing = true
        isCancelling = false

        let projectURL = projectURL
        publishTask = Task { @MainActor in
            do {
                _ = try await ReleaseFactory(projectURL: projectURL).publish(
                    recipeURL: recipeURL,
                    outputDirectory: outputDirectoryURL
                )
                guard !Task.isCancelled else {
                    isPublishing = false
                    isCancelling = false
                    publishTask = nil
                    return
                }
                let generatedManifestURL = outputDirectoryURL.appendingPathComponent("manifest.json")
                manifestURL = generatedManifestURL
                successMessage = "Release published successfully."
                isPublishing = false
                isCancelling = false
                publishTask = nil
            } catch is CancellationError {
                isPublishing = false
                isCancelling = false
                publishTask = nil
            } catch {
                guard !Task.isCancelled else {
                    isPublishing = false
                    isCancelling = false
                    publishTask = nil
                    return
                }
                errorMessage = error.localizedDescription
                isPublishing = false
                isCancelling = false
                publishTask = nil
            }
        }
    }

    private func cancelPublish() {
        guard isPublishing, !isCancelling else { return }
        isCancelling = true
        publishTask?.cancel()
    }

    private var recipeContentTypes: [UTType] {
        let recipeType = UTType(filenameExtension: "openrecordrecipe") ?? .json
        return [.json, recipeType]
    }
}
