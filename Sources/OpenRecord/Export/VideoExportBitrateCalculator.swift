import Foundation

/// Determines target video bitrates and file size estimates for export.
///
/// Screen recordings have distinct entropy characteristics compared to camera
/// video: large areas of flat color, static code or documents, and sharp text.
/// Bitrate targets are tailored to maintain razor-sharp text clarity while
/// avoiding inflated file sizes.
public enum VideoExportBitrateCalculator: Sendable {
    /// Computes the target average bitrate in bits per second for the given
    /// canvas resolution, frame rate, codec, and quality preset.
    public static func averageBitRate(
        width: Int,
        height: Int,
        fps: Int32,
        codec: VideoExportCodec,
        quality: VideoExportQualityPreset
    ) -> Int {
        guard codec != .proRes422 else { return 0 }
        let pixels = Double(max(width * height, 1))
        let fpsFactor = fps >= 60 ? 1.35 : 1.0

        // Base bits per pixel per frame for H.264 at 30 fps on screen content
        let baseBitsPerPixel: Double
        switch quality {
        case .compact:
            baseBitsPerPixel = 0.040 // ~2.5 Mbps for 1080p 30fps
        case .balanced:
            baseBitsPerPixel = 0.080 // ~5.0 Mbps for 1080p 30fps
        case .high:
            baseBitsPerPixel = 0.190 // ~12.0 Mbps for 1080p 30fps
        }

        var bps = pixels * 30.0 * baseBitsPerPixel * fpsFactor

        if codec == .hevc {
            // HEVC achieves ~35% lower bitrate at equivalent perceptual quality
            bps *= 0.65
        }

        let minFloor: Double
        let maxCeiling: Double
        switch quality {
        case .compact:
            minFloor = codec == .hevc ? 800_000 : 1_200_000
            maxCeiling = codec == .hevc ? 15_000_000 : 25_000_000
        case .balanced:
            minFloor = codec == .hevc ? 1_500_000 : 2_500_000
            maxCeiling = codec == .hevc ? 30_000_000 : 45_000_000
        case .high:
            minFloor = codec == .hevc ? 3_500_000 : 5_000_000
            maxCeiling = 60_000_000
        }

        return Int(min(maxCeiling, max(minFloor, bps.rounded())))
    }

    /// Estimates total output file size in bytes based on duration, dimensions,
    /// codec, quality preset, and audio presence.
    public static func estimatedFileSize(
        duration: TimeInterval,
        width: Int,
        height: Int,
        fps: Int32,
        codec: VideoExportCodec,
        quality: VideoExportQualityPreset,
        hasAudio: Bool = true
    ) -> Int64 {
        guard duration > 0, width > 0, height > 0 else { return 0 }

        let videoBps: Double
        if codec == .proRes422 {
            // Apple ProRes 422 is roughly 147 Mbps for 1080p at 30 fps
            let pixels = Double(width * height)
            let referencePixels = 1920.0 * 1080.0
            let referenceBps = 147_000_000.0
            let fpsScale = Double(max(fps, 1)) / 30.0
            videoBps = (pixels / referencePixels) * referenceBps * fpsScale
        } else {
            videoBps = Double(averageBitRate(
                width: width,
                height: height,
                fps: fps,
                codec: codec,
                quality: quality
            ))
        }

        let audioBps = hasAudio ? Double(CaptureMediaFormat.systemAudioBitRate) : 0
        let totalBps = videoBps + audioBps
        let rawBytes = (totalBps * duration) / 8.0
        // Add ~2% overhead for MP4 container, moov atom, and index tables
        return Int64((rawBytes * 1.02).rounded(.up))
    }
}
