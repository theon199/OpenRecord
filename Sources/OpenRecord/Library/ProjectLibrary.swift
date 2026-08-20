import AppKit
import Foundation

/// Local `.openrecord` library under a folder the user may already sync
/// (Movies, Dropbox, Google Drive, iCloud Drive).
///
/// **On-disk bundle** (`<root>/<Name>.openrecord/`):
/// ```
/// meta.json
/// project.json
/// recording/
///   display.mp4
///   mic.m4a
///   system.m4a
///   mouse.jsonl
///   clicks.jsonl
///   cursors/
/// ```
///
/// **Editor usage:** `ProjectLibrary.resolved()` after launch; `create` before
/// capture; `save(document:to:)` after timeline edits; `persistRootURL` when
/// the user picks a library folder in Settings.
public struct ProjectLibrary: Sendable {
    public var rootURL: URL

    public init(rootURL: URL = ProjectLibrary.defaultRootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// Default library: `~/Movies/OpenRecord/Projects`.
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/OpenRecord/Projects", isDirectory: true)
    }

    public static let libraryRootBookmarkKey = "OpenRecord.libraryRootBookmark"
    public static let libraryRootPathKey = "OpenRecord.libraryRootPath"

    /// Library rooted at the persisted custom folder, or `defaultRootURL`.
    public static func resolved() -> ProjectLibrary {
        ProjectLibrary(rootURL: resolvedRootURL())
    }

    /// Reads the Settings library folder (bookmark, then path), else default.
    public static func resolvedRootURL() -> URL {
        resolvedRootURL(defaults: .standard)
    }

    public static func resolvedRootURL(defaults: UserDefaults) -> URL {
        if let data = defaults.data(forKey: libraryRootBookmarkKey) {
            do {
                let (url, isStale) = try resolveBookmark(data)
                if isStale {
                    try? persistRootURL(url, defaults: defaults)
                }
                return url.standardizedFileURL
            } catch {
                // Fall through to the path string.
            }
        }
        if let path = defaults.string(forKey: libraryRootPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return defaultRootURL
    }

    /// Persist a user-chosen library folder (Dropbox / Drive / iCloud / local).
    /// Stores a security-scoped bookmark when possible, plus a path fallback.
    public static func persistRootURL(_ url: URL) throws {
        try persistRootURL(url, defaults: .standard)
    }

    public static func persistRootURL(_ url: URL, defaults: UserDefaults) throws {
        let url = url.standardizedFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw OpenRecordError.io(
                "Could not create library folder \(url.path): \(error.localizedDescription)"
            )
        }
        defaults.set(url.path, forKey: libraryRootPathKey)
        do {
            let bookmark = try makeBookmark(for: url)
            defaults.set(bookmark, forKey: libraryRootBookmarkKey)
        } catch {
            defaults.removeObject(forKey: libraryRootBookmarkKey)
        }
    }

    /// Settings → reset library folder to `~/Movies/OpenRecord/Projects`.
    public static func clearPersistedRootURL() {
        clearPersistedRootURL(defaults: .standard)
    }

    public static func clearPersistedRootURL(defaults: UserDefaults) {
        defaults.removeObject(forKey: libraryRootBookmarkKey)
        defaults.removeObject(forKey: libraryRootPathKey)
    }

    /// Persist `url` as the library folder and update this instance.
    public mutating func setRootURL(_ url: URL) throws {
        try Self.persistRootURL(url)
        rootURL = url.standardizedFileURL
    }

    /// Create `<root>/<sanitized-name>.openrecord/` with `recording/cursors/`,
    /// `meta.json`, and a default `project.json`.
    public func create(name: String, meta: ProjectMeta) throws -> URL {
        try withAccess(to: rootURL) {
            try ensureRootExists()
            let baseName = ProjectBundleNaming.sanitizedBaseName(name)
            let projectURL = ProjectBundleNaming.uniqueBundleURL(
                root: rootURL,
                baseName: baseName,
                fileManager: .default
            )
            try stageNewBundle(at: projectURL, meta: meta, document: ProjectDocument())
            return projectURL
        }
    }

    public func open(url: URL) throws -> OpenedProject {
        let url = url.standardizedFileURL
        return try withAccess(to: url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OpenRecordError.io("Not a project bundle: \(url.path)")
            }
            guard url.pathExtension == ProjectLayout.bundleExtension else {
                throw OpenRecordError.io(
                    "Expected a .\(ProjectLayout.bundleExtension) bundle: \(url.path)"
                )
            }
            let meta = try AtomicFileWrite.readJSON(ProjectMeta.self, from: ProjectLayout.metaURL(in: url))
            let document = try AtomicFileWrite.readJSON(
                ProjectDocument.self,
                from: ProjectLayout.documentURL(in: url)
            )
            return OpenedProject(url: url, meta: meta, document: document)
        }
    }

    /// `.openrecord` directories directly in `rootURL` (not nested junk).
    public func list() throws -> [URL] {
        try withAccess(to: rootURL) {
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return []
            }

            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
            } catch {
                throw OpenRecordError.io(
                    "Could not list library \(rootURL.path): \(error.localizedDescription)"
                )
            }

            var bundles: [(url: URL, modified: Date?)] = []
            bundles.reserveCapacity(contents.count)
            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard item.pathExtension == ProjectLayout.bundleExtension,
                      values?.isDirectory == true
                else {
                    continue
                }
                bundles.append((item.standardizedFileURL, values?.contentModificationDate))
            }

            bundles.sort { lhs, rhs in
                switch (lhs.modified, rhs.modified) {
                case let (a?, b?) where a != b:
                    return a > b
                default:
                    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
                        == .orderedAscending
                }
            }
            return bundles.map(\.url)
        }
    }

    public func reveal(_ url: URL) throws {
        let url = url.standardizedFileURL
        try withAccess(to: url) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OpenRecordError.io("Nothing to reveal in Finder: \(url.path)")
            }
            let select = {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if Thread.isMainThread {
                select()
            } else {
                DispatchQueue.main.sync(execute: select)
            }
        }
    }

    /// Copy an exported MP4 (or any file / bundle) to `destinationURL`.
    /// If `destinationURL` is an existing directory, the source’s filename is appended.
    public func copyExport(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        var destination = destinationURL.standardizedFileURL
        try withAccess(to: source) {
            let fm = FileManager.default
            var sourceIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
                throw OpenRecordError.io("Nothing to copy: \(source.path)")
            }

            var destIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: destination.path, isDirectory: &destIsDirectory),
               destIsDirectory.boolValue
            {
                destination = destination.appendingPathComponent(source.lastPathComponent)
            }

            if source == destination {
                return
            }

            let parent = destination.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw OpenRecordError.io(
                    "Could not create destination folder \(parent.path): \(error.localizedDescription)"
                )
            }

            let tempURL = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).copy-\(UUID().uuidString)",
                isDirectory: sourceIsDirectory.boolValue
            )
            do {
                try fm.copyItem(at: source, to: tempURL)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(
                        destination,
                        withItemAt: tempURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fm.moveItem(at: tempURL, to: destination)
                }
            } catch let error as OpenRecordError {
                try? fm.removeItem(at: tempURL)
                throw error
            } catch {
                try? fm.removeItem(at: tempURL)
                throw OpenRecordError.io(
                    "Could not copy to \(destination.path): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Atomically replace `project.json` inside an existing bundle.
    public func save(document: ProjectDocument, to projectURL: URL) throws {
        let projectURL = projectURL.standardizedFileURL
        try withAccess(to: projectURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OpenRecordError.io("Project does not exist: \(projectURL.path)")
            }
            try AtomicFileWrite.writeJSON(document, to: ProjectLayout.documentURL(in: projectURL))
        }
    }

    /// Atomically replace `meta.json` (capture agents may refresh bounds after record).
    public func save(meta: ProjectMeta, to projectURL: URL) throws {
        let projectURL = projectURL.standardizedFileURL
        try withAccess(to: projectURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OpenRecordError.io("Project does not exist: \(projectURL.path)")
            }
            try AtomicFileWrite.writeJSON(meta, to: ProjectLayout.metaURL(in: projectURL))
        }
    }

    public func ensureRootExists() throws {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw OpenRecordError.io(
                "Could not create library folder \(rootURL.path): \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Private

extension ProjectLibrary {
    fileprivate func withAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let rootAccessed = rootURL.startAccessingSecurityScopedResource()
        let urlAccessed = url.startAccessingSecurityScopedResource()
        defer {
            if urlAccessed {
                url.stopAccessingSecurityScopedResource()
            }
            if rootAccessed {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    fileprivate func stageNewBundle(at projectURL: URL, meta: ProjectMeta, document: ProjectDocument) throws {
        let fm = FileManager.default
        let stagingURL = rootURL.appendingPathComponent(
            ".\(UUID().uuidString).creating",
            isDirectory: true
        )
        do {
            try fm.createDirectory(
                at: ProjectLayout.cursorsDirectory(in: stagingURL),
                withIntermediateDirectories: true
            )
            try AtomicFileWrite.writeJSON(meta, to: ProjectLayout.metaURL(in: stagingURL))
            try AtomicFileWrite.writeJSON(document, to: ProjectLayout.documentURL(in: stagingURL))
            try fm.moveItem(at: stagingURL, to: projectURL)
        } catch let error as OpenRecordError {
            try? fm.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw OpenRecordError.io(
                "Could not create project \(projectURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    fileprivate static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    fileprivate static func resolveBookmark(_ data: Data) throws -> (URL, Bool) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    }
}

enum ProjectBundleNaming {
    static func sanitizedBaseName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if forbidden.contains(scalar) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }

        var name = String(String.UnicodeScalarView(scalars))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        while name.contains("  ") {
            name = name.replacingOccurrences(of: "  ", with: " ")
        }

        if name.isEmpty || name == "." || name == ".." {
            name = "Untitled"
        }

        let ext = "." + ProjectLayout.bundleExtension
        let maxLength = 255 - ext.count
        while name.utf8.count > maxLength && !name.isEmpty {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "Untitled"
        }
        return name
    }

    static func uniqueBundleURL(root: URL, baseName: String, fileManager: FileManager) -> URL {
        func makeURL(_ name: String) -> URL {
            root.appendingPathComponent(
                "\(name).\(ProjectLayout.bundleExtension)",
                isDirectory: true
            )
        }

        var candidate = makeURL(baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = makeURL("\(baseName) \(suffix)")
            suffix += 1
            if suffix > 10_000 {
                candidate = makeURL("\(baseName)-\(UUID().uuidString)")
                break
            }
        }
        return candidate
    }
}
