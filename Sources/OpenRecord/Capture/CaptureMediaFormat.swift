import AVFoundation
import CoreVideo
import Foundation

/// On-disk media conventions produced by `CaptureSession`.
///
/// Export and preview should use sample timestamps (VFR), not frame indexes.
/// Cursor `t` is seconds from `startCapture()` returning. Video PTS is the
/// ScreenCaptureKit clock, remapped so the first encoded frame is the file origin.
public enum CaptureMediaFormat: Sendable {
    /// `recording/display.mp4` — H.264 High, VideoToolbox hardware, BGRA source.
    public static let videoCodec: AVVideoCodecType = .h264
    public static let videoCodecIdentifier = "avc1"
    public static let videoPixelFormat: OSType = kCVPixelFormatType_32BGRA
    public static let maxFrameRate: Int32 = 60

    /// `recording/system.m4a` — AAC, stereo, 48 kHz (ScreenCaptureKit `capturesAudio`).
    public static let systemAudioSampleRate: Double = 48_000
    public static let systemAudioChannelCount = 2
    public static let systemAudioBitRate = 192_000

    /// `recording/mic.m4a` — AAC. Sample rate and channel count follow the hardware input
    /// (often 48 kHz or 44.1 kHz, mono or stereo). Read them from the file; they are not in `meta.json`.
    public static let microphoneAudioBitRate = 192_000

    public static let defaultCursorSpriteID = "arrow"
    public static let mouseSamplesPerSecondCap = 120.0

    /// `mouse.jsonl` / `clicks.jsonl` and `ProjectMeta.displayBounds` use global Quartz
    /// coordinates: points, origin at the top-left of the main display, y increasing downward.
    /// Video pixel (0, 0) maps to `displayBounds` origin. Pixels = points × `scale`.
}
