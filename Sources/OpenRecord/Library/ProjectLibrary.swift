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
///   webcam.mp4
///   thumb.jpg
///   mic.m4a
///   system.m4a
///   mouse.jsonl
///   clicks.jsonl
///   keys.jsonl
///   target.jsonl
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

    /// Move a top-level `.openrecord` bundle to the Trash.
    ///
    /// We deliberately do not fall back to `removeItem`: if Finder cannot
    /// honor the recoverable delete, retaining the project is safer than
    /// silently turning a user mistake or transient filesystem failure into
    /// permanent data loss.
    public func delete(_ url: URL) throws {
        let url = url.standardizedFileURL
        try withAccess(to: url) {
            let fm = FileManager.default
            try validateProjectBundleURL(url, fileManager: fm)
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw OpenRecordError.io(
                    "Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Rename a top-level project bundle while preserving every file inside it.
    /// Name collisions use the same numbered suffixes as project creation.
    @discardableResult
    public func rename(_ url: URL, to rawName: String) throws -> URL {
        let source = url.standardizedFileURL
        return try withAccess(to: source) {
            let fm = FileManager.default
            try validateProjectBundleURL(source, fileManager: fm)

            let baseName = ProjectBundleNaming.sanitizedBaseName(rawName)
            let currentBaseName = source.deletingPathExtension().lastPathComponent
            guard baseName != currentBaseName else { return source }

            let requested = rootURL.appendingPathComponent(
                "\(baseName).\(ProjectLayout.bundleExtension)",
                isDirectory: true
            )
            let requestedExists = fm.fileExists(atPath: requested.path)
            let requestedIsSource = requestedExists && ProjectBundleNaming.sameFileSystemItem(
                requested,
                source,
                fileManager: fm
            )
            let isCaseOnlyRename = requested.path.caseInsensitiveCompare(source.path) == .orderedSame
                && (!requestedExists || requestedIsSource)
            let destination = isCaseOnlyRename
                ? requested
                : ProjectBundleNaming.uniqueBundleURL(
                    root: rootURL,
                    baseName: baseName,
                    fileManager: fm
                )

            do {
                if isCaseOnlyRename {
                    let staging = rootURL.appendingPathComponent(
                        ".\(UUID().uuidString).renaming",
                        isDirectory: true
                    )
                    try fm.moveItem(at: source, to: staging)
                    do {
                        try fm.moveItem(at: staging, to: destination)
                    } catch {
                        do {
                            try fm.moveItem(at: staging, to: source)
                        } catch let rollbackError {
                            throw OpenRecordError.io(
                                "Could not finish renaming \(source.lastPathComponent), and recovery failed. "
                                    + "The project remains at \(staging.path): \(rollbackError.localizedDescription)"
                            )
                        }
                        throw error
                    }
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
            } catch let error as OpenRecordError {
                throw error
            } catch {
                throw OpenRecordError.io(
                    "Could not rename \(source.lastPathComponent): \(error.localizedDescription)"
                )
            }
            return destination.standardizedFileURL
        }
    }

    /// Generate and cache a representative JPEG for a project that has video.
    /// Existing thumbnails are reused so library refreshes do not re-decode media.
    public func generateThumbnailIfNeeded(for projectURL: URL) async throws -> URL? {
        let projectURL = projectURL.standardizedFileURL
        let rootAccessed = rootURL.startAccessingSecurityScopedResource()
        let projectAccessed = projectURL.startAccessingSecurityScopedResource()
        defer {
            if projectAccessed {
                projectURL.stopAccessingSecurityScopedResource()
            }
            if rootAccessed {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        try validateProjectBundleURL(projectURL, fileManager: .default)
        return try await ProjectThumbnail.generateIfNeeded(in: projectURL)
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
            try validateProjectBundleURL(projectURL, fileManager: .default)
            try AtomicFileWrite.writeProjectDocument(
                document,
                to: ProjectLayout.documentURL(in: projectURL)
            )
        }
    }

    /// Save a complete project bundle to another location.
    ///
    /// If `destinationURL` is an existing directory, the source bundle's
    /// filename is appended. The copy is staged beside the destination and
    /// installed with a single replace/move operation so an interrupted copy
    /// cannot leave a partially-written `.openrecord` bundle behind.
    @discardableResult
    public func saveCopy(
        of projectURL: URL,
        document: ProjectDocument,
        to destinationURL: URL
    ) throws -> URL {
        let source = projectURL.standardizedFileURL
        var destination = destinationURL.standardizedFileURL
        try withAccess(to: source) {
            let fm = FileManager.default
            try validateProjectBundleURL(source, fileManager: fm)

            var destinationIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
               destinationIsDirectory.boolValue
            {
                destination = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            }
            guard destination.pathExtension == ProjectLayout.bundleExtension else {
                throw OpenRecordError.io(
                    "Save Copy destination must be a .\(ProjectLayout.bundleExtension) bundle: \(destination.path)"
                )
            }
            guard source.standardizedFileURL != destination.standardizedFileURL else {
                throw OpenRecordError.io("Save Copy destination must differ from the source project")
            }

            let parent = destination.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw OpenRecordError.io(
                    "Could not create Save Copy folder \(parent.path): \(error.localizedDescription)"
                )
            }

            let staging = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).copy-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fm.copyItem(at: source, to: staging)
                try AtomicFileWrite.writeProjectDocument(
                    document,
                    to: ProjectLayout.documentURL(in: staging)
                )
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staging, backupItemName: nil, options: [])
                } else {
                    try fm.moveItem(at: staging, to: destination)
                }
            } catch {
                try? fm.removeItem(at: staging)
                throw OpenRecordError.io(
                    "Could not save project copy to \(destination.path): \(error.localizedDescription)"
                )
            }
        }
        return destination
    }

    /// Atomically replace `meta.json` (capture agents may refresh bounds after record).
    public func save(meta: ProjectMeta, to projectURL: URL) throws {
        let projectURL = projectURL.standardizedFileURL
        try withAccess(to: projectURL) {
            try validateProjectBundleURL(projectURL, fileManager: .default)
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
    /// Validate that an operation targets an existing, top-level project in
    /// this library. This prevents a malformed URL from saving into a nested
    /// bundle or an arbitrary directory outside the active library.
    fileprivate func validateProjectBundleURL(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw OpenRecordError.io("Project does not exist: \(url.path)")
        }
        guard url.pathExtension == ProjectLayout.bundleExtension else {
            throw OpenRecordError.io(
                "Expected a .\(ProjectLayout.bundleExtension) bundle: \(url.path)"
            )
        }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let parent = resolvedURL.deletingLastPathComponent()
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard parent == resolvedRoot else {
            throw OpenRecordError.io("Project is not in this library: \(url.path)")
        }
    }

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
            try AtomicFileWrite.writeProjectDocument(
                document,
                to: ProjectLayout.documentURL(in: stagingURL)
            )
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

    static func sameFileSystemItem(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let lhsAttributes = try? fileManager.attributesOfItem(atPath: lhs.path),
              let rhsAttributes = try? fileManager.attributesOfItem(atPath: rhs.path),
              let lhsVolume = lhsAttributes[.systemNumber] as? NSNumber,
              let rhsVolume = rhsAttributes[.systemNumber] as? NSNumber,
              let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
              let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber
        else {
            return false
        }
        return lhsVolume == rhsVolume && lhsFile == rhsFile
    }
}
