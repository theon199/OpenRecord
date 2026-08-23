import Darwin
import Foundation
import Testing
import OpenRecord

enum ProjectLibraryBundleRoundTrip {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("OpenRecordLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        let meta = try roundTripped(
            ProjectMeta(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: OpenRecordInfo.appVersion,
                displayBounds: Rect2D(x: 0, y: 22, width: 1920, height: 1080),
                scale: 2,
                captureTarget: .display(id: 1)
            )
        )

        let created = try library.create(name: "Demo Recording", meta: meta)
        try assertBundleLayout(created)

        let opened = try library.open(url: created)
        guard opened.url.standardizedFileURL == created.standardizedFileURL else {
            throw OpenRecordError.io("open() returned a different URL than create()")
        }
        guard opened.meta == meta else {
            throw OpenRecordError.io("meta.json did not round-trip through create/open")
        }
        guard opened.document == ProjectDocument() else {
            throw OpenRecordError.io("create() did not write the default project.json")
        }

        let listed = try library.list()
        guard listed.map(\.standardizedFileURL).contains(created.standardizedFileURL) else {
            throw OpenRecordError.io("list() did not include the created bundle")
        }

        let edited = ProjectDocument(
            formatVersion: ProjectDocument.currentFormatVersion,
            trimIn: 0.25,
            trimOut: 8,
            zoomRanges: [
                ZoomRange(
                    id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
                    start: 1,
                    end: 2,
                    amount: 1.8,
                    anchor: Point2D(x: 0.4, y: 0.6)
                )
            ],
            canvas: CanvasSettings(
                background: .solid(RGBAColor(r: 0.1, g: 0.2, b: 0.3, a: 1)),
                padding: 24,
                cornerRadius: 8,
                cursorScale: 1.25,
                aspectWidth: 16,
                aspectHeight: 9
            ),
            cursorSprites: []
        )
        try library.save(document: edited, to: created)
        let reopened = try library.open(url: created)
        guard reopened.document == edited else {
            throw OpenRecordError.io("save(document:to:) did not round-trip project.json")
        }
        guard reopened.meta == meta else {
            throw OpenRecordError.io("save(document:to:) mutated meta.json")
        }

        try assertNameSanitization(library: library, meta: meta)
        try assertListIsNotRecursive(library: library, root: root, created: created)
        try assertCopyExport(library: library, root: root)
        try assertSaveCopy(library: library, root: root, source: created, document: edited)
        try assertSaveRejectsEscapes(library: library, root: root, source: created)
        try assertDelete(library: library, meta: meta)
        try assertLibraryFolderPersistence(root: root)
        try assertOpenRejectsJunk(root: root)
    }

    private static func roundTripped<T: Codable>(_ value: T) throws -> T {
        let data = try ProjectJSON.encoder.encode(value)
        return try ProjectJSON.decoder.decode(T.self, from: data)
    }

    private static func assertBundleLayout(_ projectURL: URL) throws {
        let fm = FileManager.default
        let expectedDirectories = [
            projectURL,
            ProjectLayout.recordingDirectory(in: projectURL),
            ProjectLayout.cursorsDirectory(in: projectURL),
        ]
        for directory in expectedDirectories {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw OpenRecordError.io("Missing bundle directory: \(directory.path)")
            }
        }
        for file in [
            ProjectLayout.metaURL(in: projectURL),
            ProjectLayout.documentURL(in: projectURL),
        ] {
            guard fm.fileExists(atPath: file.path) else {
                throw OpenRecordError.io("Missing bundle file: \(file.path)")
            }
        }
        guard projectURL.pathExtension == ProjectLayout.bundleExtension else {
            throw OpenRecordError.io("Bundle extension was not .openrecord")
        }
    }

    private static func assertNameSanitization(library: ProjectLibrary, meta: ProjectMeta) throws {
        let slash = try library.create(name: "foo/bar:baz", meta: meta)
        guard slash.lastPathComponent == "foo-bar-baz.openrecord" else {
            throw OpenRecordError.io("Sanitized name was \(slash.lastPathComponent)")
        }

        let duplicate = try library.create(name: "foo/bar:baz", meta: meta)
        guard duplicate.lastPathComponent == "foo-bar-baz 2.openrecord" else {
            throw OpenRecordError.io("Duplicate name was \(duplicate.lastPathComponent)")
        }

        let untitled = try library.create(name: "///", meta: meta)
        guard untitled.lastPathComponent == "Untitled.openrecord" else {
            throw OpenRecordError.io("Empty name became \(untitled.lastPathComponent)")
        }
    }

    private static func assertListIsNotRecursive(
        library: ProjectLibrary,
        root: URL,
        created: URL
    ) throws {
        let fm = FileManager.default
        let nested = root
            .appendingPathComponent("nested-junk", isDirectory: true)
            .appendingPathComponent("Hidden.openrecord", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ProjectLayout.metaURL(in: nested))

        let listed = try library.list()
        let names = Set(listed.map(\.lastPathComponent))
        guard !names.contains("Hidden.openrecord") else {
            throw OpenRecordError.io("list() recursed into nested junk")
        }
        guard names.contains(created.lastPathComponent) else {
            throw OpenRecordError.io("list() dropped the top-level bundle")
        }
    }

    private static func assertCopyExport(library: ProjectLibrary, root: URL) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent("export-source.mp4", isDirectory: false)
        try Data("fake-mp4".utf8).write(to: source)

        let destDir = root.appendingPathComponent("Dropbox/Exports", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try library.copyExport(from: source, to: destDir)

        let copied = destDir.appendingPathComponent("export-source.mp4")
        guard try Data(contentsOf: copied) == Data("fake-mp4".utf8) else {
            throw OpenRecordError.io("copyExport into a folder did not copy bytes")
        }

        let explicit = root.appendingPathComponent("saved.mp4")
        try library.copyExport(from: source, to: explicit)
        guard try Data(contentsOf: explicit) == Data("fake-mp4".utf8) else {
            throw OpenRecordError.io("copyExport to an explicit file URL failed")
        }

        try Data("replacement".utf8).write(to: source)
        try library.copyExport(from: source, to: explicit)
        guard try Data(contentsOf: explicit) == Data("replacement".utf8) else {
            throw OpenRecordError.io("copyExport did not replace an existing file")
        }
    }

    private static func assertSaveCopy(
        library: ProjectLibrary,
        root: URL,
        source: URL,
        document: ProjectDocument
    ) throws {
        let marker = ProjectLayout.recordingDirectory(in: source)
            .appendingPathComponent("capture-marker.bin")
        try Data("capture".utf8).write(to: marker)
        let destination = root
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Current Edit.openrecord", isDirectory: true)
        let saved = try library.saveCopy(of: source, document: document, to: destination)
        let opened = try library.open(url: saved)
        guard opened.document == document,
              try Data(contentsOf: ProjectLayout.recordingDirectory(in: saved)
                .appendingPathComponent("capture-marker.bin")) == Data("capture".utf8)
        else {
            throw OpenRecordError.io("Save Copy did not preserve current edits and the complete bundle")
        }
    }

    private static func assertSaveRejectsEscapes(
        library: ProjectLibrary,
        root: URL,
        source: URL
    ) throws {
        let fm = FileManager.default
        let nestedParent = root.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nestedParent, withIntermediateDirectories: true)
        let nested = nestedParent.appendingPathComponent("Nested.openrecord", isDirectory: true)
        try fm.copyItem(at: source, to: nested)
        do {
            try library.save(document: ProjectDocument(trimIn: 9), to: nested)
            throw OpenRecordError.io("ordinary save accepted a nested project")
        } catch let error as OpenRecordError {
            if case .io(let message) = error, message.contains("accepted a nested") { throw error }
        }

        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "OpenRecordOutside-\(UUID().uuidString).openrecord",
            isDirectory: true
        )
        try fm.copyItem(at: source, to: outside)
        defer { try? fm.removeItem(at: outside) }
        let link = root.appendingPathComponent("Symlink.openrecord", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            try library.save(document: ProjectDocument(trimIn: 9), to: link)
            throw OpenRecordError.io("ordinary save followed a bundle symlink outside the library")
        } catch let error as OpenRecordError {
            if case .io(let message) = error, message.contains("followed a bundle symlink") { throw error }
        }
    }

    private static func assertDelete(library: ProjectLibrary, meta: ProjectMeta) throws {
        let fm = FileManager.default
        let created = try library.create(name: "Delete Me", meta: meta)
        guard fm.fileExists(atPath: created.path) else {
            throw OpenRecordError.io("delete test bundle was not created")
        }

        do {
            try library.delete(created)
            guard !fm.fileExists(atPath: created.path) else {
                throw OpenRecordError.io("delete() left the bundle on disk")
            }
            let listed = try library.list()
            guard !listed.map(\.standardizedFileURL).contains(created.standardizedFileURL) else {
                throw OpenRecordError.io("list() still includes a deleted bundle")
            }

            do {
                try library.delete(created)
                throw OpenRecordError.io("delete() succeeded on a missing bundle")
            } catch let error as OpenRecordError {
                if case .io(let message) = error, message.contains("succeeded on a missing") {
                    throw error
                }
            }
        } catch let error as OpenRecordError {
            // Some sandboxed test runners cannot access Finder's Trash. The
            // safety contract is that failure retains the project and reports
            // the error; it must never fall back to permanent removal.
            guard fm.fileExists(atPath: created.path) else {
                throw OpenRecordError.io("failed Trash operation permanently removed the bundle")
            }
            guard case .io(let message) = error, message.contains("Trash") || message.contains("trash") else {
                throw error
            }
        }

        let junk = library.rootURL.appendingPathComponent("not-a-bundle", isDirectory: true)
        try fm.createDirectory(at: junk, withIntermediateDirectories: true)
        do {
            try library.delete(junk)
            throw OpenRecordError.io("delete() accepted a folder without .openrecord")
        } catch let error as OpenRecordError {
            if case .io(let message) = error, message.contains("accepted a folder") {
                throw error
            }
        }
    }

    private static func assertLibraryFolderPersistence(root: URL) throws {
        let suiteName = "app.openrecord.tests.library.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw OpenRecordError.io("Could not create UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let custom = root.appendingPathComponent("Cloud/OpenRecord", isDirectory: true)
        try ProjectLibrary.persistRootURL(custom, defaults: defaults)
        let resolved = ProjectLibrary.resolvedRootURL(defaults: defaults)
        let expected = custom.standardizedFileURL.path
        let actual = resolved.standardizedFileURL.path
        guard actual == expected else {
            throw OpenRecordError.io("resolvedRootURL was \(actual), expected \(expected)")
        }

        ProjectLibrary.clearPersistedRootURL(defaults: defaults)
        let reset = ProjectLibrary.resolvedRootURL(defaults: defaults)
        guard reset.standardizedFileURL == ProjectLibrary.defaultRootURL.standardizedFileURL else {
            throw OpenRecordError.io("clearPersistedRootURL did not restore the default root")
        }
    }

    private static func assertOpenRejectsJunk(root: URL) throws {
        let library = ProjectLibrary(rootURL: root)
        let junk = root.appendingPathComponent("not-a-project", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        do {
            _ = try library.open(url: junk)
            throw OpenRecordError.io("open() accepted a folder without .openrecord")
        } catch let error as OpenRecordError {
            if case .io(let message) = error, message.contains("open() accepted") {
                throw error
            }
        }
    }
}

@Test
func projectLibraryCreateOpenListSaveRoundTrip() throws {
    try ProjectLibraryBundleRoundTrip.run()
}

/// Mach-O constructor: CLT `swift test` dlopens the bundle without reliably
/// running Swift Testing's `@main`, so the library I/O test must run at load.
@section("__DATA,__mod_init_func")
@used
let openRecordLibraryTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunProjectLibraryBundleRoundTrip()
}

@_cdecl("OpenRecordRunProjectLibraryBundleRoundTrip")
func OpenRecordRunProjectLibraryBundleRoundTrip() {
    do {
        try ProjectLibraryBundleRoundTrip.run()
        fputs("OpenRecordTests: ProjectLibrary bundle I/O round-trip passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: ProjectLibrary bundle I/O round-trip failed: \(error)\n", stderr)
        abort()
    }
}
