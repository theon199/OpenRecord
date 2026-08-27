import AVFoundation
import CoreVideo
import Dispatch
import Foundation
import OpenRecord
import Testing
import VideoToolbox

private let openRecordTestVideoWriterLock = NSLock()

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
    // GitHub's virtualized macOS runners can expose a hardware encoder that
    // never completes. Serialize fixture creation and require VideoToolbox's
    // software path so these tests exercise media import, not runner hardware.
    openRecordTestVideoWriterLock.lock()
    defer { openRecordTestVideoWriterLock.unlock() }

    let width = 16
    let height = 16
    let fps: Int32 = 10
    let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
            ],
        ]
    )
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        throw OpenRecordError.io("test writer rejected video input")
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    guard writer.startWriting() else {
        throw OpenRecordError.io(writer.error?.localizedDescription ?? "test writer failed")
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        throw OpenRecordError.io("test writer created no pixel buffer pool")
    }
    for frame in 0..<3 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw OpenRecordError.io(writer.error?.localizedDescription ?? "test writer failed")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else {
            throw OpenRecordError.io("test writer could not allocate a frame")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            base.initializeMemory(
                as: UInt8.self,
                repeating: UInt8(32 + frame * 48),
                count: CVPixelBufferGetDataSize(buffer)
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(value: Int64(frame), timescale: fps)
        ) else {
            throw OpenRecordError.io(writer.error?.localizedDescription ?? "test frame append failed")
        }
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    guard finished.wait(timeout: .now() + 30) == .success,
          writer.status == .completed
    else {
        writer.cancelWriting()
        throw OpenRecordError.io(writer.error?.localizedDescription ?? "test writer timed out")
    }
}
