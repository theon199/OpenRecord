import Foundation
import OpenRecord
import Testing

@Test("automation parser accepts inspect and export commands")
func automationParserAcceptsCommands() throws {
    let inspect = try OpenRecordAutomationParser.parse(
        arguments: ["inspect", "/tmp/demo.openrecord", "--json"]
    )
    guard case .inspect(let project, let json) = inspect else {
        throw OpenRecordError.io("inspect parser returned the wrong command")
    }
    #expect(project.path == "/tmp/demo.openrecord")
    #expect(json)

    let export = try OpenRecordAutomationParser.parse(
        arguments: [
            "export", "demo.openrecord", "--output", "out.mov",
            "--codec", "prores422", "--resolution", "4k"
        ]
    )
    guard case .export(_, let output, let codec, let resolution) = export else {
        throw OpenRecordError.io("export parser returned the wrong command")
    }
    #expect(output.lastPathComponent == "out.mov")
    #expect(codec == .proRes422)
    #expect(resolution == .p2160)
}

@Test("automation parser reports missing and invalid options")
func automationParserRejectsInvalidArguments() {
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(arguments: ["export", "demo.openrecord"])
    }
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(
            arguments: ["batch", "folder", "--output", "out", "--codec", "vp9"]
        )
    }
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(arguments: ["inspect", "movie.mp4"])
    }
}

@Test("automation discovers only top-level bundles in stable order")
func automationDiscoversTopLevelBundles() throws {
    let fixture = try AutomationFixture()
    defer { fixture.destroy() }
    try fixture.makeBundle(named: "zulu")
    try fixture.makeBundle(named: "alpha")
    try fixture.makeNestedBundle()
    try Data("not a bundle".utf8).write(
        to: fixture.root.appendingPathComponent("ignore.openrecord")
    )

    let found = try OpenRecordAutomation().discoverProjects(in: fixture.root)
    #expect(found.map(\.lastPathComponent) == ["alpha.openrecord", "zulu.openrecord"])
}

@Test("automation inspection and validation preserve project files")
func automationInspectsAndValidatesWithoutWriting() async throws {
    let fixture = try AutomationFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Demo")
    let documentURL = ProjectLayout.documentURL(in: project)
    let before = try Data(contentsOf: documentURL)

    let automation = OpenRecordAutomation()
    let inspection = await automation.inspect(project: project)
    #expect(inspection.formatVersion == ProjectDocument.currentFormatVersion)
    #expect(inspection.trackPresence[.displayVideo] == true)
    #expect(inspection.trackPresence[.microphone] == false)
    #expect(inspection.validationIssues.isEmpty)

    let validation = await automation.validate(project: project)
    #expect(validation.valid)
    #expect(validation.issues.isEmpty)
    let after = try Data(contentsOf: documentURL)
    #expect(after == before)

    try FileManager.default.removeItem(at: ProjectLayout.metaURL(in: project))
    let invalid = await automation.validate(project: project)
    #expect(!invalid.valid)
    #expect(invalid.issues.contains { $0.contains("meta.json") })
}

@Test("automation export rejects outputs inside the source bundle")
func automationRejectsProjectOwnedOutput() async throws {
    let fixture = try AutomationFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Protected")
    let documentURL = ProjectLayout.documentURL(in: project)
    let before = try Data(contentsOf: documentURL)

    var rejected = false
    do {
        try await OpenRecordAutomation().export(
            project: project,
            output: documentURL
        )
    } catch let error as OpenRecordAutomationError {
        rejected = true
        #expect(error.errorDescription?.contains("outside") == true)
    }

    #expect(rejected)
    #expect(try Data(contentsOf: documentURL) == before)
}

private struct AutomationFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRecordAutomation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeBundle(named name: String) throws -> URL {
        let meta = ProjectMeta(
            displayBounds: Rect2D(x: 0, y: 0, width: 1_920, height: 1_080),
            scale: 2,
            captureTarget: .display(id: 1)
        )
        let bundle = try ProjectLibrary(rootURL: root).create(name: name, meta: meta)
        try writeOpenRecordTestVideo(to: ProjectLayout.displayVideoURL(in: bundle))
        return bundle
    }

    func makeNestedBundle() throws {
        let nestedRoot = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nestedRoot.appendingPathComponent("hidden.openrecord", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
