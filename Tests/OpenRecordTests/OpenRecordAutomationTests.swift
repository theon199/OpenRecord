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
            "--codec", "prores422", "--resolution", "4k", "--quality", "compact",
            "--framerate", "60"
        ]
    )
    guard case .export(_, let output, let codec, let resolution, let quality, let frameRate) = export else {
        throw OpenRecordError.io("export parser returned the wrong command")
    }
    #expect(output.lastPathComponent == "out.mov")
    #expect(codec == .proRes422)
    #expect(resolution == .p2160)
    #expect(quality == .compact)
    #expect(frameRate == .fps60)

    let exportWithFps = try OpenRecordAutomationParser.parse(
        arguments: [
            "export", "demo.openrecord", "--output", "out.mp4",
            "--fps", "30"
        ]
    )
    guard case .export(_, _, _, _, _, let fpsFrameRate) = exportWithFps else {
        throw OpenRecordError.io("export parser with fps returned the wrong command")
    }
    #expect(fpsFrameRate == .fps30)

    let batch = try OpenRecordAutomationParser.parse(
        arguments: [
            "batch", "folder", "--output", "out", "--json", "--framerate", "24"
        ]
    )
    guard case .batch(_, _, _, _, _, let batchRate, let batchJSON) = batch else {
        throw OpenRecordError.io("batch parser returned the wrong command")
    }
    #expect(batchJSON)
    #expect(batchRate == .fps24)

    let analyze = try OpenRecordAutomationParser.parse(
        arguments: ["analyze", "./Demo.openrecord", "--no-vision", "--json"]
    )
    guard case .analyze(let analyzedProject, let includeVision, let analyzeJSON) = analyze else {
        throw OpenRecordError.io("analyze parser returned the wrong command")
    }
    #expect(analyzedProject.path.hasSuffix("/Demo.openrecord"))
    #expect(!includeVision)
    #expect(analyzeJSON)

    let publish = try OpenRecordAutomationParser.parse(
        arguments: [
            "publish", "Demo.openrecord", "--recipe", "release.openrecordrecipe",
            "--output", "./Artifacts", "--json"
        ]
    )
    guard case .publish(let publishProject, let recipe, let output, let publishJSON) = publish else {
        throw OpenRecordError.io("publish parser returned the wrong command")
    }
    #expect(publishProject.path.hasSuffix("/Demo.openrecord"))
    #expect(recipe.path.hasSuffix("/release.openrecordrecipe"))
    #expect(output.path.hasSuffix("/Artifacts"))
    #expect(publishJSON)

    let verify = try OpenRecordAutomationParser.parse(
        arguments: ["verify-output", "./Artifacts/manifest.json"]
    )
    guard case .verifyOutput(let manifest, let verifyJSON) = verify else {
        throw OpenRecordError.io("verify-output parser returned the wrong command")
    }
    #expect(manifest.path.hasSuffix("/Artifacts/manifest.json"))
    #expect(!verifyJSON)
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
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(arguments: ["analyze", "Demo.openrecord", "--vision"])
    }
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(
            arguments: ["publish", "Demo.openrecord", "--recipe", "release.txt", "--output", "Artifacts"]
        )
    }
    #expect(throws: OpenRecordAutomationError.self) {
        try OpenRecordAutomationParser.parse(arguments: ["verify-output", "Artifacts"])
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
    #expect(inspection.storyBeatCount == 0)
    #expect(inspection.editDecisionCount == 0)
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

@Test("automation analysis writes only the rebuildable cache")
func automationAnalyzesWithoutMutatingProjectDocument() async throws {
    let fixture = try AutomationFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Analysis")
    let metaURL = ProjectLayout.metaURL(in: project)
    let documentURL = ProjectLayout.documentURL(in: project)
    let beforeMeta = try Data(contentsOf: metaURL)
    let beforeDocument = try Data(contentsOf: documentURL)

    let summary = try await OpenRecordAutomation().analyze(
        project: project,
        includeVisionFallback: false
    )
    #expect(summary.projectURL == project.standardizedFileURL)
    #expect(summary.actionCount == 0)
    #expect(summary.analyzerVersion == ActionMapAnalysisService.analyzerVersion)
    #expect(try Data(contentsOf: metaURL) == beforeMeta)
    #expect(try Data(contentsOf: documentURL) == beforeDocument)
    #expect(FileManager.default.fileExists(atPath: ProjectLayout.analysisManifestURL(in: project).path))
}

@Test("automation verification reports invalid manifests with verification exit code")
func automationVerifyOutputUsesVerificationFailureCode() async throws {
    let fixture = try AutomationFixture()
    defer { fixture.destroy() }
    let artifacts = fixture.root.appendingPathComponent("Artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    let manifest = artifacts.appendingPathComponent("manifest.json", isDirectory: false)
    try Data("{not valid json".utf8).write(to: manifest)

    let exitCode = await OpenRecordAutomationCLI.run(
        arguments: ["verify-output", manifest.path, "--json"]
    )
    #expect(exitCode == 1)
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

@Test("automation CLI exit codes follow 0, 1, and 64 contract")
func automationCLIExitCodeUsage() {
    func exitCode(for args: [String]) -> Int32 {
        do {
            _ = try OpenRecordAutomationParser.parse(arguments: args)
            return 0
        } catch let error as OpenRecordAutomationError {
            return error.isUsageError ? 64 : 1
        } catch {
            return 1
        }
    }

    #expect(exitCode(for: []) == 64)
    #expect(exitCode(for: ["unknown"]) == 64)
    #expect(exitCode(for: ["publish", "Demo.openrecord", "--output", "out"]) == 64)
    #expect(exitCode(for: ["publish", "Demo.openrecord", "--recipe", "publish.json"]) == 64)
    #expect(exitCode(for: ["analyze", "Demo.openrecord", "--invalid"]) == 64)
    #expect(exitCode(for: ["verify-output"]) == 64)
    #expect(exitCode(for: ["verify-output", "manifest.txt"]) == 64)
}

enum OpenRecordAutomationSuite {
    static func run() throws {
        try automationParserAcceptsCommands()
        automationParserRejectsInvalidArguments()
        try automationDiscoversTopLevelBundles()
        automationCLIExitCodeUsage()
    }
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordAutomationTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunAutomationTests()
}

@_cdecl("OpenRecordRunAutomationTests")
func OpenRecordRunAutomationTests() {
    do {
        try OpenRecordAutomationSuite.run()
        fputs("OpenRecordTests: OpenRecordAutomation tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: OpenRecordAutomation tests failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif
