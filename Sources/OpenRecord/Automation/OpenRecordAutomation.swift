import AVFoundation
import Foundation

/// A command understood by the local OpenRecord automation interface.
///
/// The command model intentionally contains URLs rather than strings so callers
/// can use the API without going through a shell.  Export settings are optional
/// overrides and are applied only to the in-memory document passed to
/// ``Exporter``.
public enum OpenRecordAutomationCommand: Sendable, Equatable {
    case inspect(project: URL, json: Bool)
    case validate(project: URL, json: Bool)
    case export(
        project: URL,
        output: URL,
        codec: VideoExportCodec?,
        resolution: ExportResolutionPreset?
    )
    case batch(
        folder: URL,
        output: URL,
        codec: VideoExportCodec?,
        resolution: ExportResolutionPreset?
    )
}

/// Short aliases useful to clients that expose this as a conventional CLI
/// parser rather than as the broader automation API.
public typealias OpenRecordCLICommand = OpenRecordAutomationCommand

/// Errors raised while parsing or running an automation command.
public enum OpenRecordAutomationError: Error, LocalizedError, Sendable, Equatable {
    case invalidArguments(String)
    case invalidProject(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .invalidProject(let message), .io(let message):
            message
        }
    }
}

/// A JSON- and human-readable summary of one project bundle.
public struct ProjectInspection: Codable, Sendable, Equatable {
    public let projectURL: URL
    public let formatVersion: Int?
    public let duration: TimeInterval?
    public let editDuration: TimeInterval?
    public let trackPresence: [CaptureTrackKind: Bool]
    public let validationIssues: [String]

    public init(
        projectURL: URL,
        formatVersion: Int?,
        duration: TimeInterval?,
        editDuration: TimeInterval?,
        trackPresence: [CaptureTrackKind: Bool],
        validationIssues: [String]
    ) {
        self.projectURL = projectURL
        self.formatVersion = formatVersion
        self.duration = duration
        self.editDuration = editDuration
        self.trackPresence = trackPresence
        self.validationIssues = validationIssues
    }

    /// Compatibility-friendly aliases for callers that prefer shorter names.
    public var format: Int? { formatVersion }
    public var issues: [String] { validationIssues }
    public var tracks: [CaptureTrackKind: Bool] { trackPresence }
}

/// Validation result for a project bundle.
public struct ProjectValidation: Codable, Sendable, Equatable {
    public let projectURL: URL
    public let valid: Bool
    public let issues: [String]
    public let inspection: ProjectInspection

    public init(
        projectURL: URL,
        valid: Bool,
        issues: [String],
        inspection: ProjectInspection
    ) {
        self.projectURL = projectURL
        self.valid = valid
        self.issues = issues
        self.inspection = inspection
    }
}

/// Result for one batch export job.
public struct BatchJobResult: Codable, Sendable, Equatable {
    public let projectURL: URL
    public let outputURL: URL
    public let succeeded: Bool
    public let error: String?

    public init(projectURL: URL, outputURL: URL, succeeded: Bool, error: String? = nil) {
        self.projectURL = projectURL
        self.outputURL = outputURL
        self.succeeded = succeeded
        self.error = error
    }
}

/// Aggregate result for a deterministic folder batch.
public struct BatchResult: Codable, Sendable, Equatable {
    public let folderURL: URL
    public let outputDirectoryURL: URL
    public let jobs: [BatchJobResult]

    public init(folderURL: URL, outputDirectoryURL: URL, jobs: [BatchJobResult]) {
        self.folderURL = folderURL
        self.outputDirectoryURL = outputDirectoryURL
        self.jobs = jobs
    }

    public var succeededCount: Int { jobs.filter(\.succeeded).count }
    public var failedCount: Int { jobs.count - succeededCount }
    public var succeeded: Bool { failedCount == 0 }
    public var failed: Bool { !succeeded }
}

/// Parser for the dependency-free OpenRecord command line interface.
public enum OpenRecordAutomationParser: Sendable {
    public static let usage = """
    Usage:
      openrecord-cli inspect <project.openrecord> [--json]
      openrecord-cli validate <project.openrecord> [--json]
      openrecord-cli export <project.openrecord> --output <file> [--codec h264|hevc|prores422] [--resolution 720p|1080p|4k|source]
      openrecord-cli batch <folder> --output <folder> [--codec h264|hevc|prores422] [--resolution 720p|1080p|4k|source]
    """

    public static func parse<S: Sequence>(arguments: S) throws -> OpenRecordAutomationCommand
    where S.Element == String {
        let args = Array(arguments)
        guard let rawCommand = args.first, !rawCommand.isEmpty else {
            throw OpenRecordAutomationError.invalidArguments(usage)
        }

        switch rawCommand {
        case "inspect":
            let (positionals, flags) = try parseOptions(Array(args.dropFirst()), options: [])
            guard positionals.count == 1 else {
                throw OpenRecordAutomationError.invalidArguments(
                    "inspect expects exactly one project bundle.\n\n\(usage)"
                )
            }
            guard flags.contains("json") || flags.isEmpty else {
                throw OpenRecordAutomationError.invalidArguments("Unknown inspect option.\n\n\(usage)")
            }
            return .inspect(
                project: try requireProjectURL(positionals[0]),
                json: flags.contains("json")
            )

        case "validate":
            let (positionals, flags) = try parseOptions(Array(args.dropFirst()), options: [])
            guard positionals.count == 1 else {
                throw OpenRecordAutomationError.invalidArguments(
                    "validate expects exactly one project bundle.\n\n\(usage)"
                )
            }
            guard flags.contains("json") || flags.isEmpty else {
                throw OpenRecordAutomationError.invalidArguments("Unknown validate option.\n\n\(usage)")
            }
            return .validate(
                project: try requireProjectURL(positionals[0]),
                json: flags.contains("json")
            )

        case "export":
            let parsed = try parseExportLike(
                command: rawCommand,
                arguments: Array(args.dropFirst()),
                requireOutputDirectory: false
            )
            return .export(
                project: try requireProjectURL(parsed.primary),
                output: parsed.output,
                codec: parsed.codec,
                resolution: parsed.resolution
            )

        case "batch":
            let parsed = try parseExportLike(
                command: rawCommand,
                arguments: Array(args.dropFirst()),
                requireOutputDirectory: true
            )
            return .batch(
                folder: projectURL(parsed.primary),
                output: parsed.output,
                codec: parsed.codec,
                resolution: parsed.resolution
            )

        default:
            throw OpenRecordAutomationError.invalidArguments(
                "Unknown command '\(rawCommand)'.\n\n\(usage)"
            )
        }
    }

    private struct ParsedExportLike {
        var primary: String
        var output: URL
        var codec: VideoExportCodec?
        var resolution: ExportResolutionPreset?
    }

    private static func parseExportLike(
        command: String,
        arguments: [String],
        requireOutputDirectory: Bool
    ) throws -> ParsedExportLike {
        var positionals: [String] = []
        var output: String?
        var codec: VideoExportCodec?
        var resolution: ExportResolutionPreset?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw OpenRecordAutomationError.invalidArguments(
                        "\(command) requires a value after --output.\n\n\(usage)"
                    )
                }
                guard output == nil else {
                    throw OpenRecordAutomationError.invalidArguments("--output may only be provided once.")
                }
                output = arguments[index]

            case "--codec":
                index += 1
                guard index < arguments.count, let value = VideoExportCodec.parseCLI(arguments[index]) else {
                    throw OpenRecordAutomationError.invalidArguments(
                        "Invalid codec. Expected h264, hevc, or prores422.\n\n\(usage)"
                    )
                }
                codec = value

            case "--resolution":
                index += 1
                guard index < arguments.count,
                      let value = ExportResolutionPreset(rawValue: arguments[index].lowercased())
                else {
                    throw OpenRecordAutomationError.invalidArguments(
                        "Invalid resolution. Expected 720p, 1080p, 4k, or source.\n\n\(usage)"
                    )
                }
                resolution = value

            case let option where option.hasPrefix("--"):
                throw OpenRecordAutomationError.invalidArguments(
                    "Unknown option '\(option)' for \(command).\n\n\(usage)"
                )

            default:
                positionals.append(argument)
            }
            index += 1
        }

        guard positionals.count == 1 else {
            throw OpenRecordAutomationError.invalidArguments(
                "\(command) expects exactly one \(requireOutputDirectory ? "folder" : "project bundle") and --output.\n\n\(usage)"
            )
        }
        guard let output else {
            throw OpenRecordAutomationError.invalidArguments("\(command) requires --output.\n\n\(usage)")
        }
        return ParsedExportLike(
            primary: positionals[0],
            output: projectURL(output),
            codec: codec,
            resolution: resolution
        )
    }

    private static func parseOptions(
        _ arguments: [String],
        options: Set<String>
    ) throws -> (positionals: [String], flags: Set<String>) {
        var positionals: [String] = []
        var flags: Set<String> = []
        for argument in arguments {
            if argument.hasPrefix("--") {
                let flag = String(argument.dropFirst(2))
                guard !flag.isEmpty, options.contains(flag) || flag == "json" else {
                    throw OpenRecordAutomationError.invalidArguments("Unknown option '\(argument)'.\n\n\(usage)")
                }
                flags.insert(flag)
            } else {
                positionals.append(argument)
            }
        }
        return (positionals, flags)
    }

    private static func projectURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: path.hasSuffix("/")).standardizedFileURL
    }

    private static func requireProjectURL(_ path: String) throws -> URL {
        let url = projectURL(path)
        guard url.pathExtension == ProjectLayout.bundleExtension else {
            throw OpenRecordAutomationError.invalidArguments(
                "Project path must be a .\(ProjectLayout.bundleExtension) bundle: \(path)"
            )
        }
        return url
    }
}

public typealias OpenRecordCLIParser = OpenRecordAutomationParser

private extension VideoExportCodec {
    static func parseCLI(_ value: String) -> VideoExportCodec? {
        switch value.lowercased() {
        case "h264": .h264
        case "hevc": .hevc
        case "prores422", "prores-422", "prores": .proRes422
        default: nil
        }
    }
}

/// Local inspection, validation, export, and batch automation for `.openrecord`
/// bundles.  This type never writes `meta.json` or `project.json`.
public struct OpenRecordAutomation: Sendable {
    public init() {}

    public func inspect(project url: URL) async -> ProjectInspection {
        await makeInspection(projectURL: url.standardizedFileURL)
    }

    public func validate(project url: URL) async -> ProjectValidation {
        let inspection = await makeInspection(projectURL: url.standardizedFileURL)
        return ProjectValidation(
            projectURL: inspection.projectURL,
            valid: inspection.validationIssues.isEmpty,
            issues: inspection.validationIssues,
            inspection: inspection
        )
    }

    /// Discovers only direct child `.openrecord` directories, ordered by their
    /// standardized path.  Nested bundles and regular files are ignored.
    public func discoverProjects(in folderURL: URL) throws -> [URL] {
        let folderURL = folderURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw OpenRecordAutomationError.io("Batch folder does not exist or is not a directory: \(folderURL.path)")
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw OpenRecordAutomationError.io("Could not list batch folder \(folderURL.path): \(error.localizedDescription)")
        }
        return contents
            .filter { url in
                guard url.pathExtension == ProjectLayout.bundleExtension else { return false }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
                return values.isDirectory == true
            }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    public func export(
        project url: URL,
        output outputURL: URL,
        codec: VideoExportCodec? = nil,
        resolution: ExportResolutionPreset? = nil
    ) async throws {
        let projectURL = try requireBundleURL(url)
        let safeOutputURL = outputURL.standardizedFileURL
        try requireOutputOutsideProject(safeOutputURL, projectURL: projectURL)
        let library = ProjectLibrary(rootURL: projectURL.deletingLastPathComponent())
        let opened = try library.open(url: projectURL)
        var document = opened.document
        if let codec { document.videoExportSettings.codec = codec }
        if let resolution { document.videoExportSettings.resolution = resolution }
        try await Exporter(projectBundleURL: projectURL).export(
            project: document,
            url: safeOutputURL,
            progress: nil
        )
    }

    private func requireOutputOutsideProject(_ outputURL: URL, projectURL: URL) throws {
        let resolvedProject = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOutput = outputURL.resolvingSymlinksInPath().standardizedFileURL
        let projectPath = resolvedProject.path
        let outputPath = resolvedOutput.path
        guard outputPath != projectPath,
              !outputPath.hasPrefix(projectPath + "/")
        else {
            throw OpenRecordAutomationError.invalidArguments(
                "Export output must be outside the source project bundle: \(outputURL.path)"
            )
        }
    }

    /// Exports jobs sequentially, catches each failure, and continues to the
    /// next bundle.  A caller can use `failedCount` to choose a non-zero exit.
    public func batch(
        folder folderURL: URL,
        output outputDirectoryURL: URL,
        codec: VideoExportCodec? = nil,
        resolution: ExportResolutionPreset? = nil
    ) async throws -> BatchResult {
        let folderURL = folderURL.standardizedFileURL
        let outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        let projects = try discoverProjects(in: folderURL)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw OpenRecordAutomationError.io("Could not create batch output folder \(outputDirectoryURL.path): \(error.localizedDescription)")
        }

        var jobs: [BatchJobResult] = []
        jobs.reserveCapacity(projects.count)
        for projectURL in projects {
            let savedCodec = (try? ProjectLibrary(
                rootURL: projectURL.deletingLastPathComponent()
            ).open(url: projectURL).document.videoExportSettings.codec) ?? .h264
            let extensionName = (codec ?? savedCodec) == .proRes422 ? "mov" : "mp4"
            let baseName = projectURL.deletingPathExtension().lastPathComponent
            let destination = outputDirectoryURL.appendingPathComponent(
                "\(baseName).\(extensionName)",
                isDirectory: false
            )
            do {
                try await export(
                    project: projectURL,
                    output: destination,
                    codec: codec,
                    resolution: resolution
                )
                jobs.append(BatchJobResult(projectURL: projectURL, outputURL: destination, succeeded: true))
            } catch {
                jobs.append(
                    BatchJobResult(
                        projectURL: projectURL,
                        outputURL: destination,
                        succeeded: false,
                        error: error.localizedDescription
                    )
                )
            }
        }
        return BatchResult(
            folderURL: folderURL,
            outputDirectoryURL: outputDirectoryURL,
            jobs: jobs
        )
    }

    private func requireBundleURL(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension == ProjectLayout.bundleExtension else {
            throw OpenRecordAutomationError.invalidProject(
                "Expected a .\(ProjectLayout.bundleExtension) bundle: \(standardized.path)"
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw OpenRecordAutomationError.invalidProject("Project does not exist: \(standardized.path)")
        }
        return standardized
    }

    private func makeInspection(projectURL: URL) async -> ProjectInspection {
        let projectURL = projectURL.standardizedFileURL
        var issues: [String] = []
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let isBundleDirectory = fm.fileExists(atPath: projectURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && projectURL.pathExtension == ProjectLayout.bundleExtension
        if !isBundleDirectory {
            issues.append("Not a .\(ProjectLayout.bundleExtension) project bundle: \(projectURL.path)")
        }

        let metaURL = ProjectLayout.metaURL(in: projectURL)
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let displayURL = ProjectLayout.displayVideoURL(in: projectURL)
        let recordingURL = ProjectLayout.recordingDirectory(in: projectURL)
        if !fileExists(metaURL) { issues.append("Missing required meta.json") }
        if !fileExists(documentURL) { issues.append("Missing required project.json") }
        if !fileExists(displayURL) { issues.append("Missing required recording/display.mp4") }
        if !directoryExists(recordingURL) { issues.append("Missing required recording directory") }

        let trackURLs: [CaptureTrackKind: URL] = [
            .displayVideo: displayURL,
            .webcam: ProjectLayout.webcamVideoURL(in: projectURL),
            .microphone: ProjectLayout.microphoneAudioURL(in: projectURL),
            .systemAudio: ProjectLayout.systemAudioURL(in: projectURL)
        ]
        let tracks = Dictionary(uniqueKeysWithValues: CaptureTrackKind.allCases.map { track in
            (track, fileExists(trackURLs[track]!))
        })

        var opened: OpenedProject?
        if isBundleDirectory, fileExists(metaURL), fileExists(documentURL) {
            do {
                let library = ProjectLibrary(rootURL: projectURL.deletingLastPathComponent())
                opened = try library.open(url: projectURL)
            } catch {
                issues.append("Could not open project: \(error.localizedDescription)")
            }
        }

        let formatVersion = opened?.document.formatVersion ?? readFormatVersion(from: documentURL)
        let duration = await mediaDuration(at: displayURL)
        if fileExists(displayURL), duration == nil {
            issues.append("Display media is unreadable or has no positive duration")
        }
        let editDuration: TimeInterval?
        if let document = opened?.document, let duration {
            editDuration = ProjectTimeMapper(project: document, sourceDuration: duration).outputDuration
        } else {
            editDuration = nil
        }
        return ProjectInspection(
            projectURL: projectURL,
            formatVersion: formatVersion,
            duration: duration,
            editDuration: editDuration,
            trackPresence: tracks,
            validationIssues: stableUnique(issues)
        )
    }

    private func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func mediaDuration(at url: URL) async -> TimeInterval? {
        guard fileExists(url) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func readFormatVersion(from url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["formatVersion"] as? NSNumber
        else { return nil }
        return value.intValue
    }

    private func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Small command runner shared by the executable target and tests.
public enum OpenRecordAutomationCLI: Sendable {
    public static func run(arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            print(OpenRecordAutomationParser.usage)
            return 0
        }
        if arguments == ["--version"] {
            print("openrecord-cli \(OpenRecordInfo.appVersion)")
            return 0
        }
        do {
            let command = try OpenRecordAutomationParser.parse(arguments: arguments)
            let automation = OpenRecordAutomation()
            switch command {
            case .inspect(let project, let json):
                let report = await automation.inspect(project: project)
                printReport(report, json: json)
                return 0
            case .validate(let project, let json):
                let report = await automation.validate(project: project)
                printReport(report, json: json)
                return report.valid ? 0 : 2
            case .export(let project, let output, let codec, let resolution):
                try await automation.export(
                    project: project,
                    output: output,
                    codec: codec,
                    resolution: resolution
                )
                print("Exported \(output.path)")
                return 0
            case .batch(let folder, let output, let codec, let resolution):
                let result = try await automation.batch(
                    folder: folder,
                    output: output,
                    codec: codec,
                    resolution: resolution
                )
                printReport(result, json: false)
                return result.succeeded ? 0 : 1
            }
        } catch let error as OpenRecordAutomationError {
            writeError("Error: \(error.localizedDescription)\n")
            return error.isUsageError ? 64 : 1
        } catch {
            writeError("Error: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func printReport<T: Encodable>(_ report: T, json: Bool) {
        if json {
            let encoder = ProjectJSON.encoder
            if let data = try? encoder.encode(report), let string = String(data: data, encoding: .utf8) {
                print(string)
            }
            return
        }
        if let report = report as? ProjectInspection {
            print("Project: \(report.projectURL.path)")
            print("Format version: \(report.formatVersion.map(String.init) ?? "unknown")")
            print("Duration: \(formatted(report.duration))")
            print("Edit duration: \(formatted(report.editDuration))")
            print("Tracks:")
            for track in CaptureTrackKind.allCases {
                print("  \(track.rawValue): \(report.trackPresence[track] == true ? "present" : "missing")")
            }
            printIssues(report.validationIssues)
        } else if let report = report as? ProjectValidation {
            print(report.valid ? "Valid: \(report.projectURL.path)" : "Invalid: \(report.projectURL.path)")
            printIssues(report.issues)
        } else if let report = report as? BatchResult {
            for job in report.jobs {
                print("\(job.succeeded ? "OK" : "FAILED"): \(job.projectURL.lastPathComponent) → \(job.outputURL.path)")
                if let error = job.error { print("  \(error)") }
            }
            print("Batch: \(report.succeededCount) succeeded, \(report.failedCount) failed")
        }
    }

    private static func printIssues(_ issues: [String]) {
        guard !issues.isEmpty else { print("Issues: none"); return }
        print("Issues:")
        issues.forEach { print("  - \($0)") }
    }

    private static func formatted(_ value: TimeInterval?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f s", value)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private extension OpenRecordAutomationError {
    var isUsageError: Bool {
        if case .invalidArguments = self { return true }
        return false
    }
}
