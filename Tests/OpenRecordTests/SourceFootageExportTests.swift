import AVFoundation
import Foundation
import OpenRecord
import Testing

@Test("source footage export is available only without compositor effects")
func sourceFootageExportAvailabilityMatchesEffectState() {
    #expect(SourceFootageExport.isAvailable(for: ProjectDocument()))
    #expect(
        SourceFootageExport.isAvailable(
            for: ProjectDocument(webcamOverlay: WebcamOverlaySettings(enabled: true))
        )
    )

    #expect(
        !SourceFootageExport.isAvailable(
            for: ProjectDocument(
                zoomRanges: [
                    ZoomRange(start: 0, end: 1, amount: 1.5, anchor: Point2D(x: 0.5, y: 0.5))
                ]
            )
        )
    )
    #expect(
        !SourceFootageExport.isAvailable(
            for: ProjectDocument(keyboardOverlay: KeyboardOverlaySettings(enabled: true))
        )
    )
    #expect(
        !SourceFootageExport.isAvailable(
            for: ProjectDocument(captions: [CaptionCue(start: 0, end: 1, text: "Hi")])
        )
    )
    #expect(
        !SourceFootageExport.isAvailable(
            for: ProjectDocument(editDecisions: [EditDecision(start: 1, end: 2)])
        )
    )
    #expect(
        !SourceFootageExport.isAvailable(
            for: ProjectDocument(speedSegments: [SpeedSegment(start: 0, end: 2, rate: 2)])
        )
    )
    #expect(
        SourceFootageExport.isAvailable(
            for: ProjectDocument(speedSegments: [SpeedSegment(start: 0, end: 2, rate: 1)])
        )
    )
}

@Test("webcam sidecar sits beside the chosen screen export")
func sourceFootageWebcamSidecarURLUsesStem() {
    let url = URL(fileURLWithPath: "/tmp/Demo Recording.mp4")
    #expect(
        SourceFootageExport.webcamSidecarURL(beside: url).path
            == "/tmp/Demo Recording-webcam.mp4"
    )
}

@Test("fast export copies screen footage and a webcam sidecar")
func sourceFootageExportCopiesScreenAndWebcam() async throws {
    let fixture = try SourceFootageFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Raw")
    try writeOpenRecordTestVideo(to: ProjectLayout.webcamVideoURL(in: project))

    let output = fixture.root.appendingPathComponent("out.mp4")
    let result = try await Exporter(projectBundleURL: project).exportSourceFootage(
        project: ProjectDocument(),
        url: output,
        progress: nil
    )

    #expect(FileManager.default.fileExists(atPath: result.videoURL.path))
    #expect(result.webcamURL == SourceFootageExport.webcamSidecarURL(beside: output))
    #expect(FileManager.default.fileExists(atPath: result.webcamURL?.path ?? ""))
    #expect(try await videoTrackCount(at: result.videoURL) == 1)
    #expect(try await videoTrackCount(at: result.webcamURL!) == 1)

    let sourceDuration = try await AVURLAsset(
        url: ProjectLayout.displayVideoURL(in: project)
    ).load(.duration).seconds
    let outputDuration = try await AVURLAsset(url: result.videoURL).load(.duration).seconds
    #expect(abs(outputDuration - sourceDuration) < 0.05)
}

@Test("fast export applies trim without requiring compositor effects")
func sourceFootageExportHonorsTrim() async throws {
    let fixture = try SourceFootageFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Trim")
    let sourceDuration = try await AVURLAsset(
        url: ProjectLayout.displayVideoURL(in: project)
    ).load(.duration).seconds
    let trimOut = min(sourceDuration, 0.08)
    guard trimOut > 0.03 else {
        throw OpenRecordError.io("test video is too short to trim")
    }

    let output = fixture.root.appendingPathComponent("trimmed.mp4")
    try await Exporter(projectBundleURL: project).exportSourceFootage(
        project: ProjectDocument(trimIn: 0, trimOut: trimOut),
        url: output,
        progress: nil
    )
    let exported = try await AVURLAsset(url: output).load(.duration).seconds
    #expect(exported <= trimOut + 0.05)
    #expect(exported < sourceDuration - 0.01)
}

@Test("fast export refuses projects that still need a compositor render")
func sourceFootageExportRejectsZoomProjects() async throws {
    let fixture = try SourceFootageFixture()
    defer { fixture.destroy() }
    let project = try fixture.makeBundle(named: "Zoomed")
    let output = fixture.root.appendingPathComponent("blocked.mp4")
    await #expect(throws: OpenRecordError.self) {
        try await Exporter(projectBundleURL: project).exportSourceFootage(
            project: ProjectDocument(
                zoomRanges: [
                    ZoomRange(start: 0, end: 1, amount: 2, anchor: Point2D(x: 0.5, y: 0.5))
                ]
            ),
            url: output,
            progress: nil
        )
    }
}

private struct SourceFootageFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordSourceFootage-\(UUID().uuidString)",
            isDirectory: true
        )
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
}

private func videoTrackCount(at url: URL) async throws -> Int {
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
    return tracks.count
}
