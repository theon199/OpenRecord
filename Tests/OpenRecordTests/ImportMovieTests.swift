import Foundation
import OpenRecord
import Testing

@Test("movie import creates a portable project without changing the source")
func movieImportCreatesPortableProject() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "OpenRecordImportMovieTests-\(UUID().uuidString)",
        isDirectory: true
    )
    let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
    let source = root.appendingPathComponent("iPhone Demo.mov", isDirectory: false)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try writeOpenRecordTestVideo(to: source)
    let originalBytes = try Data(contentsOf: source)

    let templateDocument = ProjectDocument(
        canvas: CanvasSettings(padding: 72, aspectWidth: 9, aspectHeight: 16),
        videoExportSettings: VideoExportSettings(codec: .hevc, resolution: .p1080)
    )
    let library = ProjectLibrary(rootURL: libraryRoot)
    let projectURL = try await library.importMovie(
        from: source,
        document: templateDocument
    )
    let opened = try library.open(url: projectURL)

    #expect(projectURL.lastPathComponent == "iPhone Demo.openrecord")
    #expect(opened.meta.captureTarget == .display(id: 0))
    #expect(opened.meta.displayBounds.width == 16)
    #expect(opened.meta.displayBounds.height == 16)
    #expect(opened.document.canvas.padding == 72)
    #expect(opened.document.trimOut != nil)
    #expect((opened.document.trimOut ?? 0) > 0)
    #expect(fm.fileExists(atPath: ProjectLayout.displayVideoURL(in: projectURL).path))
    #expect(try Data(contentsOf: source) == originalBytes)
}

@Test("failed movie import leaves no partial project")
func failedMovieImportIsAtomic() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "OpenRecordFailedImportTests-\(UUID().uuidString)",
        isDirectory: true
    )
    let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let invalid = root.appendingPathComponent("broken.mp4")
    try Data("not a movie".utf8).write(to: invalid)

    let library = ProjectLibrary(rootURL: libraryRoot)
    do {
        _ = try await library.importMovie(from: invalid)
        Issue.record("invalid media unexpectedly imported")
    } catch {
        // Expected: AVFoundation rejects the source before a bundle is installed.
    }
    #expect(try library.list().isEmpty)
    if fm.fileExists(atPath: libraryRoot.path) {
        let leftovers = try fm.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        #expect(leftovers.isEmpty)
    }
}

func writeOpenRecordTestVideo(to url: URL) throws {
    guard let resources = Bundle.module.resourceURL else {
        throw OpenRecordError.io("test media resources are unavailable")
    }
    let fixtureURL = resources
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Media", isDirectory: true)
        .appendingPathComponent("tiny-display.mp4.base64", isDirectory: false)
    let encoded = try Data(contentsOf: fixtureURL)
    guard let media = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
        throw OpenRecordError.io("test media fixture is invalid")
    }
    try media.write(to: url, options: .atomic)
}
