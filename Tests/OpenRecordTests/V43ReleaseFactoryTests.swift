import CryptoKit
import Foundation
import OpenRecord
import Testing

@Test("release manifest encoding is stable and portable")
func releaseManifestEncodingIsStableAndPortable() throws {
    let file = PublishedFile(
        relativePath: "demo.md",
        byteCount: 3,
        checksum: "aaaaaaaa",
        mediaType: "text/markdown"
    )
    let output = PublishedOutput(
        name: "demo",
        kind: .markdown,
        aspect: "16:9",
        sourceDuration: 2,
        outputDuration: 2,
        settings: ["aspect": "16:9"],
        files: [file]
    )
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        sourceFingerprints: [
            AnalysisSourceFingerprint(
                bundleRelativePath: "recording/display.mp4",
                byteCount: 3,
                digest: "bbbb"
            )
        ],
        outputs: [output],
        warnings: ["z-warning", "a-warning"],
        privacyReview: .complete,
        reproducibilityLimitations: ["encoder"]
    )
    let first = try ProjectJSON.encoder.encode(manifest)
    let roundTrip = try ProjectJSON.decoder.decode(PublishManifest.self, from: first)
    let second = try ProjectJSON.encoder.encode(roundTrip)

    #expect(first == second)
    #expect(!String(decoding: first, as: UTF8.self).contains("/Users/"))
    #expect(!String(decoding: first, as: UTF8.self).contains("2026-"))
    #expect(roundTrip.outputs.first?.files.first?.relativePath == "demo.md")
    #expect(roundTrip.warnings == ["a-warning", "z-warning"])
}

@Test("release verification catches a tampered relative output")
func releaseVerificationCatchesTampering() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("demo.md")
    try Data("one".utf8).write(to: outputURL)
    let digest = SHA256.hash(data: Data("one".utf8)).map { String(format: "%02x", $0) }.joined()
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "demo",
                kind: .markdown,
                aspect: "16:9",
                sourceDuration: 1,
                outputDuration: 1,
                files: [PublishedFile(relativePath: "demo.md", byteCount: 3, checksum: digest)]
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)
    let valid = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(valid.isValid)

    try Data("tampered".utf8).write(to: outputURL)
    let invalid = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!invalid.isValid)
    #expect(invalid.issues.contains { $0.contains("Byte count") || $0.contains("Checksum") })
}

@Test("verification rejects absolute and parent-traversal paths")
func releaseVerificationRejectsUnsafePaths() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "unsafe",
                kind: .markdown,
                aspect: "16:9",
                sourceDuration: 0,
                outputDuration: 0,
                files: [
                    PublishedFile(relativePath: "../outside.txt", byteCount: 0, checksum: ""),
                    PublishedFile(relativePath: "/tmp/outside.txt", byteCount: 0, checksum: "")
                ]
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)
    let verification = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!verification.isValid)
    #expect(verification.issues.count == 2)
}

@Test("release factory builds a complete offline tutorial without mutating the project")
func releaseFactoryBuildsOfflineTutorial() async throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let meta = ProjectMeta(
        displayBounds: Rect2D(x: 100, y: 200, width: 640, height: 360),
        scale: 1,
        captureTarget: .display(id: 1)
    )
    let library = ProjectLibrary(rootURL: root)
    let project = try library.create(name: "Tutorial Source", meta: meta)
    try writeOpenRecordTestVideo(to: ProjectLayout.displayVideoURL(in: project))
    let document = ProjectDocument(
        trimOut: 0.9,
        captions: [CaptionCue(start: 0.2, end: 0.75, text: "Choose Save")],
        editDecisions: [EditDecision(start: 0.35, end: 0.55)],
        transcript: [TranscriptSegment(start: 0.1, end: 0.8, recognizedText: "Choose Save to finish")],
        storyBeats: [StoryBeat(start: 0.05, end: 0.85, kind: .step, title: "Save the result")]
    )
    try library.save(document: document, to: project)
    try writeJSONLFixture([
        CursorSample(t: 0.1, x: 180, y: 260, visible: true, sequence: 0),
        CursorSample(t: 0.7, x: 500, y: 380, visible: true, sequence: 1),
    ], to: ProjectLayout.mouseURL(in: project))
    try writeJSONLFixture([
        ClickSample(t: 0.7, button: .left, down: true, x: 500, y: 380, sequence: 0),
    ], to: ProjectLayout.clicksURL(in: project))
    try writeJSONLFixture([
        KeySample(t: 0.72, key: "S", modifiers: [.command], down: true, sequence: 0),
        KeySample(t: 0.73, key: "x", modifiers: [], down: true, sequence: 1),
    ], to: ProjectLayout.keysURL(in: project))

    let projectBefore = try Data(contentsOf: ProjectLayout.documentURL(in: project))
    let recipeURL = root.appendingPathComponent("publish.openrecordrecipe")
    let recipe = PublishRecipe(outputs: [
        PublishOutput(
            name: "Guide",
            kind: .markdown,
            captionDelivery: .sidecar,
            overwrite: .replace,
            includeTranscript: true
        ),
        PublishOutput(
            name: "Tutorial",
            kind: .tutorial,
            overwrite: .replace,
            includeTranscript: true
        ),
    ])
    try ProjectJSON.encoder.encode(recipe).write(to: recipeURL, options: .atomic)
    let artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)

    let manifest = try await ReleaseFactory(projectURL: project).publish(
        recipeURL: recipeURL,
        outputDirectory: artifacts
    )
    let package = artifacts.appendingPathComponent("Tutorial.openrecordweb", isDirectory: true)
    let names = try Set(FileManager.default.contentsOfDirectory(atPath: package.path))
    #expect(names == Set(["index.html", "player.js", "player.css", "video.mp4", "manifest.json", "captions.vtt", "cursor.png", "poster.jpg"]))
    #expect(manifest.outputs.first(where: { $0.kind == .tutorial })?.files.count == 8)
    #expect(try Data(contentsOf: ProjectLayout.documentURL(in: project)) == projectBefore)

    let index = try String(contentsOf: package.appendingPathComponent("index.html"), encoding: .utf8)
    let player = try String(contentsOf: package.appendingPathComponent("player.js"), encoding: .utf8)
    let captions = try String(contentsOf: package.appendingPathComponent("captions.vtt"), encoding: .utf8)
    let guide = try String(contentsOf: artifacts.appendingPathComponent("Guide.md"), encoding: .utf8)
    let guideCaptions = try String(contentsOf: artifacts.appendingPathComponent("Guide.vtt"), encoding: .utf8)
    #expect(index.contains("pause-after"))
    #expect(player.contains("manifest.cursor"))
    #expect(!index.contains("http://") && !index.contains("https://"))
    #expect(!player.contains("fetch("))
    #expect(captions.components(separatedBy: "-->").count == 3)
    #expect(guide.contains("(Tutorial.openrecordweb/index.html#t="))
    #expect(guideCaptions.components(separatedBy: "-->").count == 3)

    let packageManifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    let packageJSON = try #require(JSONSerialization.jsonObject(with: packageManifest) as? [String: Any])
    let cursorValues = try #require(packageJSON["cursor"] as? [[String: Any]])
    #expect(cursorValues.count == 2)
    #expect(abs((cursorValues[1]["time"] as? Double ?? -1) - 0.5) < 0.000_001)
    #expect((packageJSON["clicks"] as? [[String: Any]])?.count == 1)
    let shortcutValues = try #require(packageJSON["shortcuts"] as? [[String: Any]])
    #expect(shortcutValues.count == 1)
    #expect(abs((shortcutValues[0]["time"] as? Double ?? -1) - 0.52) < 0.000_001)
    let verification = try ReleaseFactory.verifyOutput(
        manifestURL: artifacts.appendingPathComponent("manifest.json")
    )
    #expect(verification.isValid)

    let firstManifestBytes = try Data(contentsOf: artifacts.appendingPathComponent("manifest.json"))
    _ = try await ReleaseFactory(projectURL: project).publish(
        recipeURL: recipeURL,
        outputDirectory: artifacts
    )
    #expect(try Data(contentsOf: artifacts.appendingPathComponent("manifest.json")) == firstManifestBytes)

    let unrelated = artifacts.appendingPathComponent("personal-notes.txt")
    try Data("keep me".utf8).write(to: unrelated, options: .atomic)
    var rejectedUnmanagedReplacement = false
    do {
        _ = try await ReleaseFactory(projectURL: project).publish(
            recipeURL: recipeURL,
            outputDirectory: artifacts
        )
    } catch {
        rejectedUnmanagedReplacement = true
    }
    #expect(rejectedUnmanagedReplacement)
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep me")
    #expect(try Data(contentsOf: artifacts.appendingPathComponent("manifest.json")) == firstManifestBytes)
}

@Test("verification rejects symbolic links in the release output")
func releaseVerificationCatchesSymlinks() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("demo.md")
    try Data("one".utf8).write(to: outputURL)
    let digest = SHA256.hash(data: Data("one".utf8)).map { String(format: "%02x", $0) }.joined()
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "demo",
                kind: .markdown,
                aspect: "16:9",
                sourceDuration: 1,
                outputDuration: 1,
                files: [PublishedFile(relativePath: "demo.md", byteCount: 3, checksum: digest)]
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)

    // Add a symlink in root
    let symlinkURL = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outputURL)

    let verification = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!verification.isValid)
    #expect(verification.issues.contains { $0.contains("symbolic link") })
}

@Test("verification rejects unexpected files in the release directory")
func releaseVerificationCatchesUnexpectedFiles() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("demo.md")
    try Data("one".utf8).write(to: outputURL)
    let digest = SHA256.hash(data: Data("one".utf8)).map { String(format: "%02x", $0) }.joined()
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "demo",
                kind: .markdown,
                aspect: "16:9",
                sourceDuration: 1,
                outputDuration: 1,
                files: [PublishedFile(relativePath: "demo.md", byteCount: 3, checksum: digest)]
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)

    // Add an unexpected file in root
    let extraURL = root.appendingPathComponent("unrelated.txt")
    try Data("extra".utf8).write(to: extraURL)

    let verification = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!verification.isValid)
    #expect(verification.issues.contains { $0.contains("Unexpected published file") })
}

@Test("verification rejects remote URLs in tutorial player assets")
func releaseVerificationCatchesRemoteURLInPlayerAssets() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("Tutorial.openrecordweb", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

    let allowedFiles = ["index.html", "player.js", "player.css", "video.mp4", "manifest.json", "captions.vtt", "cursor.png", "poster.jpg"]
    var publishedFiles: [PublishedFile] = []
    for file in allowedFiles {
        let fileURL = package.appendingPathComponent(file)
        let content: Data
        if file == "player.js" {
            content = Data("const x = 'https://analytics.example.com';".utf8)
        } else {
            content = Data("data".utf8)
        }
        try content.write(to: fileURL)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        publishedFiles.append(PublishedFile(
            relativePath: "Tutorial.openrecordweb/" + file,
            byteCount: Int64(content.count),
            checksum: digest
        ))
    }
    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "Tutorial",
                kind: .tutorial,
                aspect: "16:9",
                sourceDuration: 1,
                outputDuration: 1,
                files: publishedFiles
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)

    let verification = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!verification.isValid)
    #expect(verification.issues.contains { $0.contains("remote URL") })
}

@Test("verification rejects non-allowlisted files in tutorial package")
func releaseVerificationCatchesInvalidTutorialContents() throws {
    let root = temporaryReleaseDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let package = root.appendingPathComponent("Tutorial.openrecordweb", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

    let allowedFiles = ["index.html", "player.js", "player.css", "video.mp4", "manifest.json", "captions.vtt", "cursor.png", "poster.jpg"]
    var publishedFiles: [PublishedFile] = []
    for file in allowedFiles {
        let fileURL = package.appendingPathComponent(file)
        let content = Data("data".utf8)
        try content.write(to: fileURL)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        publishedFiles.append(PublishedFile(
            relativePath: "Tutorial.openrecordweb/" + file,
            byteCount: Int64(content.count),
            checksum: digest
        ))
    }
    // Add extra unapproved file inside package
    let extraURL = package.appendingPathComponent("secret.txt")
    try Data("leak".utf8).write(to: extraURL)

    let manifest = PublishManifest(
        projectFormatVersion: 8,
        recipeFormatVersion: 1,
        outputs: [
            PublishedOutput(
                name: "Tutorial",
                kind: .tutorial,
                aspect: "16:9",
                sourceDuration: 1,
                outputDuration: 1,
                files: publishedFiles
            )
        ]
    )
    let manifestURL = root.appendingPathComponent("manifest.json")
    try ProjectJSON.encoder.encode(manifest).write(to: manifestURL)

    let verification = try ReleaseFactory.verifyOutput(manifestURL: manifestURL)
    #expect(!verification.isValid)
    #expect(verification.issues.contains { $0.contains("non-allowlisted") || $0.contains("Unexpected published file") })
}

enum V43ReleaseFactorySuite {
    static func run() throws {
        try releaseManifestEncodingIsStableAndPortable()
        try releaseVerificationCatchesTampering()
        try releaseVerificationRejectsUnsafePaths()
        try releaseVerificationCatchesSymlinks()
        try releaseVerificationCatchesUnexpectedFiles()
        try releaseVerificationCatchesRemoteURLInPlayerAssets()
        try releaseVerificationCatchesInvalidTutorialContents()
        // Note: releaseFactoryBuildsOfflineTutorial is an @Test function with full media encoding
    }

    private static func runAsync(_ body: @Sendable @escaping () async throws -> Void) throws {
        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await body()
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error {
            throw error
        }
    }
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV43ReleaseFactoryTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunV43ReleaseFactoryTests()
}

@_cdecl("OpenRecordRunV43ReleaseFactoryTests")
func OpenRecordRunV43ReleaseFactoryTests() {
    do {
        try V43ReleaseFactorySuite.run()
        fputs("OpenRecordTests: v4.3 ReleaseFactory tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: v4.3 ReleaseFactory tests failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif

private func writeJSONLFixture<Value: Encodable>(_ values: [Value], to url: URL) throws {
    let lines = try values.map { String(decoding: try ProjectJSON.jsonlEncoder.encode($0), as: UTF8.self) }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
}

private func temporaryReleaseDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenRecord-V43-\(UUID().uuidString)", isDirectory: true)
}
