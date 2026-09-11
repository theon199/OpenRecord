import Foundation
@testable import OpenRecord
import Testing

@Suite("Export Frame Rate and Timeline Zoom Tests")
struct ExportFrameRateAndTimelineZoomTests {
    @Test("VideoExportFrameRate resolves expected FPS across presets and auto")
    func videoExportFrameRateResolvedFPS() {
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 60) == 60)
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 50) == 60)
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 45) == 60)
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 44) == 30)
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 30) == 30)
        #expect(VideoExportFrameRate.auto.resolvedFPS(sourceAverageFPS: 0) == 30)

        #expect(VideoExportFrameRate.fps60.resolvedFPS(sourceAverageFPS: 30) == 60)
        #expect(VideoExportFrameRate.fps50.resolvedFPS(sourceAverageFPS: 60) == 50)
        #expect(VideoExportFrameRate.fps30.resolvedFPS(sourceAverageFPS: 60) == 30)
        #expect(VideoExportFrameRate.fps25.resolvedFPS(sourceAverageFPS: 60) == 25)
        #expect(VideoExportFrameRate.fps24.resolvedFPS(sourceAverageFPS: 60) == 24)
        #expect(VideoExportFrameRate.fps15.resolvedFPS(sourceAverageFPS: 60) == 15)

        #expect(VideoExportFrameRate.auto.title == "Auto")
        #expect(VideoExportFrameRate.fps60.title == "60 fps")
        #expect(VideoExportFrameRate.fps50.title == "50 fps")
        #expect(VideoExportFrameRate.fps30.title == "30 fps")
        #expect(VideoExportFrameRate.fps25.title == "25 fps")
        #expect(VideoExportFrameRate.fps24.title == "24 fps")
        #expect(VideoExportFrameRate.fps15.title == "15 fps")
    }

    @Test("VideoExportSettings decodes legacy JSON missing frameRate to auto and round-trips explicit values")
    func videoExportSettingsJSONRoundTrip() throws {
        let legacyJSON = """
        {
            "codec": "h264",
            "resolution": "1080p",
            "quality": "high"
        }
        """.data(using: .utf8)!
        let legacySettings = try JSONDecoder().decode(VideoExportSettings.self, from: legacyJSON)
        #expect(legacySettings.frameRate == .auto)
        #expect(legacySettings.codec == .h264)
        #expect(legacySettings.resolution == .p1080)
        #expect(legacySettings.quality == .high)

        let customSettings = VideoExportSettings(
            codec: .hevc,
            resolution: .p2160,
            quality: .compact,
            frameRate: .fps24
        )
        let encoded = try JSONEncoder().encode(customSettings)
        let decoded = try JSONDecoder().decode(VideoExportSettings.self, from: encoded)
        #expect(decoded == customSettings)
        #expect(decoded.frameRate == .fps24)
    }

    @Test("AtomicFileWrite writeProjectDocument and persistence validation handles frameRate")
    func atomicFileWriteFrameRateValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-framerate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var document = ProjectDocument()
        document.videoExportSettings = VideoExportSettings(
            codec: .hevc,
            resolution: .p1080,
            quality: .balanced,
            frameRate: .fps60
        )

        let docURL = tempDir.appendingPathComponent("project.json")
        try AtomicFileWrite.writeProjectDocument(document, to: docURL)

        let readBack = try AtomicFileWrite.readJSON(ProjectDocument.self, from: docURL)
        #expect(readBack.videoExportSettings.frameRate == .fps60)
        #expect(readBack.videoExportSettings.codec == .hevc)

        let invalidExistingJSON = """
        {
            "formatVersion": 4,
            "videoExportSettings": {
                "codec": "hevc",
                "resolution": "1080p",
                "quality": "balanced",
                "frameRate": "144"
            }
        }
        """.data(using: .utf8)!
        try invalidExistingJSON.write(to: docURL)
        #expect(throws: OpenRecordError.self) {
            try AtomicFileWrite.writeProjectDocument(document, to: docURL)
        }
    }

    @Test("Estimated file size scales with target frame rate")
    func estimatedFileSizeScalesWithFPS() {
        let size60H264 = VideoExportBitrateCalculator.estimatedFileSize(
            duration: 60,
            width: 1920,
            height: 1080,
            fps: 60,
            codec: .h264,
            quality: .balanced,
            hasAudio: true
        )
        let size30H264 = VideoExportBitrateCalculator.estimatedFileSize(
            duration: 60,
            width: 1920,
            height: 1080,
            fps: 30,
            codec: .h264,
            quality: .balanced,
            hasAudio: true
        )
        #expect(size60H264 > size30H264)

        let size60ProRes = VideoExportBitrateCalculator.estimatedFileSize(
            duration: 60,
            width: 1920,
            height: 1080,
            fps: 60,
            codec: .proRes422,
            quality: .balanced,
            hasAudio: true
        )
        let size30ProRes = VideoExportBitrateCalculator.estimatedFileSize(
            duration: 60,
            width: 1920,
            height: 1080,
            fps: 30,
            codec: .proRes422,
            quality: .balanced,
            hasAudio: true
        )
        let size15ProRes = VideoExportBitrateCalculator.estimatedFileSize(
            duration: 60,
            width: 1920,
            height: 1080,
            fps: 15,
            codec: .proRes422,
            quality: .balanced,
            hasAudio: true
        )
        #expect(size60ProRes > size30ProRes)
        #expect(size30ProRes > size15ProRes)
    }
}
