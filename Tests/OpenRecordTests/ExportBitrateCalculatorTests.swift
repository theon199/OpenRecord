import Foundation
import Testing
@testable import OpenRecord

@Test("bitrate calculator scales across resolutions, frame rates, and qualities")
func bitrateCalculatorScaling() {
    let w1080 = 1920
    let h1080 = 1080

    let compactH264_30 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .h264,
        quality: .compact
    )
    let balancedH264_30 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .h264,
        quality: .balanced
    )
    let highH264_30 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .h264,
        quality: .high
    )

    // Verify ordering: compact < balanced < high
    #expect(compactH264_30 < balancedH264_30)
    #expect(balancedH264_30 < highH264_30)

    // Compact should be around 2.5 Mbps (~2.48 Mbps)
    #expect(compactH264_30 >= 2_000_000 && compactH264_30 <= 3_000_000)

    // Balanced should be around 5.0 Mbps (~4.97 Mbps)
    #expect(balancedH264_30 >= 4_500_000 && balancedH264_30 <= 5_500_000)

    // High should be around 12.0 Mbps (~11.8 Mbps)
    #expect(highH264_30 >= 10_000_000 && highH264_30 <= 13_000_000)

    // HEVC should be ~35% lower than H.264
    let compactHEVC_30 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .hevc,
        quality: .compact
    )
    let balancedHEVC_30 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .hevc,
        quality: .balanced
    )
    #expect(compactHEVC_30 < compactH264_30)
    #expect(balancedHEVC_30 < balancedH264_30)
    let hevcRatio = Double(balancedHEVC_30) / Double(balancedH264_30)
    #expect(hevcRatio >= 0.60 && hevcRatio <= 0.70)

    // 60 fps should increase bitrate by ~35%
    let balancedH264_60 = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 60,
        codec: .h264,
        quality: .balanced
    )
    #expect(balancedH264_60 > balancedH264_30)
    let fpsRatio = Double(balancedH264_60) / Double(balancedH264_30)
    #expect(fpsRatio >= 1.30 && fpsRatio <= 1.40)

    // ProRes 422 bitrate returns 0 for averageBitRate (handled specially)
    let proResBitrate = VideoExportBitrateCalculator.averageBitRate(
        width: w1080,
        height: h1080,
        fps: 30,
        codec: .proRes422,
        quality: .balanced
    )
    #expect(proResBitrate == 0)
}

@Test("estimated file size produces realistic values and reflects duration and audio")
func estimatedFileSizeCalculations() {
    let duration: TimeInterval = 660 // 11 minutes
    let width = 1920
    let height = 1080

    // Compact HEVC for 11 minutes should be ~140-165 MB (huge reduction from 370 MB)
    let compactHEVCBytes = VideoExportBitrateCalculator.estimatedFileSize(
        duration: duration,
        width: width,
        height: height,
        fps: 30,
        codec: .hevc,
        quality: .compact,
        hasAudio: true
    )
    let compactHEVCMB = Double(compactHEVCBytes) / (1024 * 1024)
    #expect(compactHEVCMB >= 130 && compactHEVCMB <= 170)

    // Balanced HEVC should be ~260-310 MB
    let balancedHEVCBytes = VideoExportBitrateCalculator.estimatedFileSize(
        duration: duration,
        width: width,
        height: height,
        fps: 30,
        codec: .hevc,
        quality: .balanced,
        hasAudio: true
    )
    let balancedHEVCMB = Double(balancedHEVCBytes) / (1024 * 1024)
    #expect(balancedHEVCMB >= 250 && balancedHEVCMB <= 320)

    // Without audio, file size should be smaller
    let noAudioBytes = VideoExportBitrateCalculator.estimatedFileSize(
        duration: duration,
        width: width,
        height: height,
        fps: 30,
        codec: .hevc,
        quality: .compact,
        hasAudio: false
    )
    #expect(noAudioBytes < compactHEVCBytes)

    // Zero duration produces 0
    let zeroBytes = VideoExportBitrateCalculator.estimatedFileSize(
        duration: 0,
        width: width,
        height: height,
        fps: 30,
        codec: .hevc,
        quality: .compact
    )
    #expect(zeroBytes == 0)

    // ProRes 422 produces larger editing master size
    let proResBytes = VideoExportBitrateCalculator.estimatedFileSize(
        duration: duration,
        width: width,
        height: height,
        fps: 30,
        codec: .proRes422,
        quality: .balanced
    )
    let proResGB = Double(proResBytes) / (1024 * 1024 * 1024)
    #expect(proResGB >= 10 && proResGB <= 15)
}

@Test("video export settings decodes legacy JSON missing quality with default balanced")
func videoExportSettingsLegacyDecoding() throws {
    let legacyJSON = Data("""
    {
        "codec": "hevc",
        "resolution": "720p"
    }
    """.utf8)

    let decoded = try JSONDecoder().decode(VideoExportSettings.self, from: legacyJSON)
    #expect(decoded.codec == .hevc)
    #expect(decoded.resolution == .p720)
    #expect(decoded.quality == .balanced)

    let modernJSON = Data("""
    {
        "codec": "h264",
        "resolution": "1080p",
        "quality": "compact"
    }
    """.utf8)

    let modernDecoded = try JSONDecoder().decode(VideoExportSettings.self, from: modernJSON)
    #expect(modernDecoded.codec == .h264)
    #expect(modernDecoded.resolution == .p1080)
    #expect(modernDecoded.quality == .compact)

    // Re-encoding preserves quality
    let reencoded = try JSONEncoder().encode(modernDecoded)
    let roundtrip = try JSONDecoder().decode(VideoExportSettings.self, from: reencoded)
    #expect(roundtrip == modernDecoded)
}

@Test("project library saves document with custom video export quality")
func projectLibrarySavesDocumentWithCustomQuality() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-export-quality-\(UUID().uuidString).openrecord")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    var document = ProjectDocument()
    document.videoExportSettings = VideoExportSettings(codec: .hevc, resolution: .p720, quality: .compact)

    let docURL = ProjectLayout.documentURL(in: tmp)
    try AtomicFileWrite.writeProjectDocument(document, to: docURL)

    let readBack = try AtomicFileWrite.readJSON(ProjectDocument.self, from: docURL)
    #expect(readBack.videoExportSettings.codec == .hevc)
    #expect(readBack.videoExportSettings.resolution == .p720)
    #expect(readBack.videoExportSettings.quality == .compact)
}
