import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import OpenRecord

/// A small, deterministic export benchmark. The benchmark deliberately owns
/// source creation so it can be run on a clean checkout without a captured
/// project or any external media.
@main
struct OpenRecordExportBenchmark {
    fileprivate static let defaultDuration: Double = 300
    fileprivate static let defaultWidth = 1920
    fileprivate static let defaultHeight = 1080
    fileprivate static let defaultFPS = 30

    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(Options.usage)
                return
            }
            try await run(options)
        } catch {
            let message = "OpenRecordExportBenchmark: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run(_ options: Options) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: options.workDirectory, withIntermediateDirectories: true)

        let projectURL = options.workDirectory.appendingPathComponent(
            "synthetic-\(options.width)x\(options.height)-\(options.fps)fps.openrecord",
            isDirectory: true
        )
        let sourceURL = ProjectLayout.displayVideoURL(in: projectURL)

        if options.reuseSource {
            guard fm.fileExists(atPath: sourceURL.path) else {
                throw BenchmarkError.invalidOption(
                    "--reuse-source was supplied, but no source exists at \(sourceURL.path). Run once without --reuse-source first."
                )
            }
        } else {
            if fm.fileExists(atPath: projectURL.path) {
                try fm.removeItem(at: projectURL)
            }
            try SyntheticProject.create(
                at: projectURL,
                duration: options.duration,
                width: options.width,
                height: options.height,
                fps: options.fps
            )
        }

        let source = try await MediaSummary(url: sourceURL)
        var report = BenchmarkReport(
            projectPath: projectURL.path,
            sourcePath: sourceURL.path,
            outputPath: nil,
            sourceDurationSeconds: source.duration,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFPS: source.fps,
            sourceCodec: source.codec,
            outputCodec: "h264",
            outputResolution: "1920x1080",
            outputWidth: nil,
            outputHeight: nil,
            totalExportSeconds: nil,
            averageOutputFPS: nil,
            peakMemoryBytes: nil,
            prepareOnly: options.prepareOnly
        )

        if !options.prepareOnly {
            let outputURL = options.workDirectory.appendingPathComponent(
                "export-h264-1080p.mp4",
                isDirectory: false
            )
            let document = ProjectDocument(
                trimIn: 0,
                trimOut: source.duration,
                videoExportSettings: VideoExportSettings(codec: .h264, resolution: .p1080)
            )
            let started = ContinuousClock.now
            let exporter = Exporter(projectBundleURL: projectURL)
            try await exporter.export(
                project: document,
                url: outputURL,
                progress: nil as ExportProgressHandler?
            )
            let elapsed = started.duration(to: .now).components
            let exportSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let output = try await MediaSummary(url: outputURL)
            report.outputPath = outputURL.path
            report.outputCodec = output.codec
            report.outputResolution = "\(output.width)x\(output.height)"
            report.outputWidth = output.width
            report.outputHeight = output.height
            report.totalExportSeconds = exportSeconds
            report.averageOutputFPS = exportSeconds > 0 ? output.frameCount / exportSeconds : nil
            report.peakMemoryBytes = peakResidentMemory()
        }

        let data = try ProjectJSON.encoder.encode(report)
        let reportParent = options.reportURL.deletingLastPathComponent()
        try fm.createDirectory(at: reportParent, withIntermediateDirectories: true)
        try data.write(to: options.reportURL, options: Data.WritingOptions.atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func peakResidentMemory() -> Int64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        // ru_maxrss is bytes on Darwin (unlike the kilobytes convention on
        // some Unix platforms). This is the process high-water mark.
        return Int64(usage.ru_maxrss)
    }
}

private struct Options: Sendable {
    var duration = OpenRecordExportBenchmark.defaultDuration
    var width = OpenRecordExportBenchmark.defaultWidth
    var height = OpenRecordExportBenchmark.defaultHeight
    var fps = OpenRecordExportBenchmark.defaultFPS
    var workDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/openrecord-export-benchmark", isDirectory: true)
    var reportURL: URL
    var prepareOnly = false
    var reuseSource = false
    var showHelp = false

    init(arguments: [String]) throws {
        var parsedReportURL: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                showHelp = true
            case "--prepare-only":
                prepareOnly = true
            case "--reuse-source":
                reuseSource = true
            case "--duration":
                duration = try Self.number(for: argument, arguments: arguments, index: &index)
            case "--width":
                width = try Self.integer(for: argument, arguments: arguments, index: &index)
            case "--height":
                height = try Self.integer(for: argument, arguments: arguments, index: &index)
            case "--fps":
                fps = try Self.integer(for: argument, arguments: arguments, index: &index)
            case "--work-dir":
                workDirectory = try Self.url(for: argument, arguments: arguments, index: &index)
            case "--report":
                parsedReportURL = try Self.url(for: argument, arguments: arguments, index: &index)
            default:
                throw BenchmarkError.invalidOption(
                    "Unknown option '\(argument)'. Use --help to see the supported options."
                )
            }
            index += 1
        }

        guard duration.isFinite, duration > 0 else {
            throw BenchmarkError.invalidOption("--duration must be greater than zero seconds.")
        }
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw BenchmarkError.invalidOption("--width and --height must be positive even numbers.")
        }
        guard fps > 0, fps <= 120 else {
            throw BenchmarkError.invalidOption("--fps must be an integer between 1 and 120.")
        }
        workDirectory = workDirectory.standardizedFileURL
        self.reportURL = (parsedReportURL ?? workDirectory.appendingPathComponent("report.json", isDirectory: false))
            .standardizedFileURL
    }

    private static func nextValue(
        for option: String,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("--") else {
            throw BenchmarkError.invalidOption("Missing value for \(option).")
        }
        index = next
        return arguments[next]
    }

    private static func number(
        for option: String,
        arguments: [String],
        index: inout Int
    ) throws -> Double {
        let value = try nextValue(for: option, arguments: arguments, index: &index)
        guard let number = Double(value) else {
            throw BenchmarkError.invalidOption("\(option) expects a number, got '\(value)'.")
        }
        return number
    }

    private static func integer(
        for option: String,
        arguments: [String],
        index: inout Int
    ) throws -> Int {
        let value = try nextValue(for: option, arguments: arguments, index: &index)
        guard let number = Int(value) else {
            throw BenchmarkError.invalidOption("\(option) expects an integer, got '\(value)'.")
        }
        return number
    }

    private static func url(
        for option: String,
        arguments: [String],
        index: inout Int
    ) throws -> URL {
        let value = try nextValue(for: option, arguments: arguments, index: &index)
        let url = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL
    }

    static let usage = """
    Usage: swift run -c release OpenRecordExportBenchmark [options]

      --duration SECONDS  Synthetic source duration (default: 300)
      --width PIXELS      Synthetic source width (default: 1920)
      --height PIXELS     Synthetic source height (default: 1080)
      --fps FPS           Synthetic source frame rate (default: 30)
      --work-dir PATH     Artifact directory (default: .build/openrecord-export-benchmark)
      --report PATH       JSON report path (default: <work-dir>/report.json)
      --prepare-only      Create the source project, but skip export
      --reuse-source      Reuse an existing source in <work-dir>
      --help              Show this help
    """
}

private enum SyntheticProject {
    static func create(
        at projectURL: URL,
        duration: Double,
        width: Int,
        height: Int,
        fps: Int
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ProjectLayout.recordingDirectory(in: projectURL), withIntermediateDirectories: true)
        try fm.createDirectory(at: ProjectLayout.cursorsDirectory(in: projectURL), withIntermediateDirectories: true)

        let meta = ProjectMeta(
            createdAt: Date(timeIntervalSince1970: 0),
            displayBounds: Rect2D(x: 0, y: 0, width: Double(width), height: Double(height)),
            scale: 1,
            captureTarget: .display(id: 0),
            captureHealth: .complete
        )
        let document = ProjectDocument(
            trimIn: 0,
            trimOut: duration,
            videoExportSettings: VideoExportSettings(codec: .h264, resolution: .p1080)
        )
        try ProjectJSON.encoder.encode(meta).write(to: ProjectLayout.metaURL(in: projectURL), options: .atomic)
        try ProjectJSON.encoder.encode(document).write(to: ProjectLayout.documentURL(in: projectURL), options: .atomic)
        try writeVideo(
            to: ProjectLayout.displayVideoURL(in: projectURL),
            duration: duration,
            width: width,
            height: height,
            fps: fps
        )
    }

    private static func writeVideo(
        to url: URL,
        duration: Double,
        width: Int,
        height: Int,
        fps: Int
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: min(50_000_000, max(6_000_000, width * height * 8)),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw BenchmarkError.media("AVAssetWriter rejected the synthetic H.264 video input.")
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        guard writer.startWriting() else {
            throw BenchmarkError.media(writer.error?.localizedDescription ?? "Could not start synthetic video writer.")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw BenchmarkError.media("AVAssetWriter did not provide a pixel buffer pool for the synthetic source.")
        }

        let frameCount = max(1, Int((duration * Double(fps)).rounded(.down)))
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw BenchmarkError.media(writer.error?.localizedDescription ?? "Synthetic video writer failed.")
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw BenchmarkError.media("Could not allocate synthetic \(width)×\(height) frame \(frameIndex).")
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                // Every frame is a deterministic grayscale value. Using a
                // single fill keeps source preparation bounded while still
                // exercising decode, composition, and H.264 encode paths.
                baseAddress.initializeMemory(
                    as: UInt8.self,
                    repeating: UInt8(frameIndex & 0xff),
                    count: CVPixelBufferGetDataSize(pixelBuffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: Int64(frameIndex), timescale: CMTimeScale(fps))
            ) else {
                throw BenchmarkError.media(writer.error?.localizedDescription ?? "Could not append synthetic frame \(frameIndex).")
            }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw BenchmarkError.media(writer.error?.localizedDescription ?? "Synthetic video writer did not complete.")
        }
    }
}

private struct MediaSummary: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Double
    let codec: String

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BenchmarkError.media("\(url.path) has no video track.")
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw BenchmarkError.media("\(url.path) has an empty video duration.")
        }
        let naturalSize = try await track.load(.naturalSize)
        let nominalRate = try await track.load(.nominalFrameRate)
        let descriptions = try await track.load(.formatDescriptions)
        let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BenchmarkError.media("Could not count video frames in \(url.path).")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw BenchmarkError.media(
                reader.error?.localizedDescription
                    ?? "Could not start counting video frames in \(url.path)."
            )
        }
        var actualFrameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            actualFrameCount += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else {
            throw BenchmarkError.media(
                reader.error?.localizedDescription
                    ?? "Could not finish counting video frames in \(url.path)."
            )
        }
        self.duration = duration.seconds
        self.width = Int(abs(naturalSize.width.rounded()))
        self.height = Int(abs(naturalSize.height.rounded()))
        self.fps = nominalRate > 0 ? Double(nominalRate) : 0
        self.frameCount = Double(actualFrameCount)
        // The harness only creates H.264 sources. Keep that useful fallback
        // for older AVFoundation versions that omit format descriptions.
        self.codec = subtype.map(Self.codecName) ?? "h264"
    }

    private static func codecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        default:
            let bytes = [
                UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff),
            ]
            return String(bytes: bytes, encoding: .ascii) ?? "unknown"
        }
    }
}

private struct BenchmarkReport: Codable, Sendable {
    var schemaVersion = 1
    let projectPath: String
    let sourcePath: String
    var outputPath: String?
    let sourceDurationSeconds: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFPS: Double
    let sourceCodec: String
    var outputCodec: String
    var outputResolution: String
    var outputWidth: Int?
    var outputHeight: Int?
    var totalExportSeconds: Double?
    var averageOutputFPS: Double?
    var peakMemoryBytes: Int64?
    let prepareOnly: Bool
}

private enum BenchmarkError: LocalizedError {
    case invalidOption(String)
    case media(String)

    var errorDescription: String? {
        switch self {
        case .invalidOption(let message), .media(let message): message
        }
    }
}
