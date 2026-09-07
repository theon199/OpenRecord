import AVFoundation
import CoreGraphics
import Darwin
import Testing
@testable import OpenRecord

enum RecordingHUDLayoutSuite {
    private static let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    static func run() throws {
        try sizeRangeAllowsLargeCamera()
        try overlayRoundTripPreservesFrame()
        try yFlipMapsBottomRightToHighNormalizedY()
        try clampKeepsCircleInsideDisplay()
        try defaultFrameIsOnDisplay()
        try windowFramePlacesPillBelowCamera()
        try collapsedWindowCentersOnCamera()
        try silentMicrophoneBufferMatchesFormat()
    }

    private static func sizeRangeAllowsLargeCamera() throws {
        guard WebcamOverlaySettings.sizeRange.upperBound == 0.65 else {
            throw failure("webcam size cap should allow a large-camera mode of 0.65")
        }
        var settings = WebcamOverlaySettings(enabled: true, size: 0.7)
        settings = settings.normalized
        guard settings.size == 0.65 else {
            throw failure("size 0.7 should clamp to 0.65, got \(settings.size)")
        }
        settings.size = 0.5
        settings = settings.normalized
        guard settings.size == 0.5 else {
            throw failure("size 0.5 should remain inside the expanded range")
        }
    }

    private static func overlayRoundTripPreservesFrame() throws {
        let original = RecordingHUDLayout.clampCameraFrame(
            RecordingHUDLayout.cameraFrame(
                center: CGPoint(x: display.midX + 200, y: display.midY - 80),
                diameter: 216
            ),
            to: display
        )
        let settings = RecordingHUDLayout.overlaySettings(
            cameraFrame: original,
            displayBounds: display,
            existing: WebcamOverlaySettings(enabled: true)
        )
        let restored = RecordingHUDLayout.cameraFrame(
            settings: settings,
            displayBounds: display
        )
        try expectClose(restored.midX, original.midX, "round-trip center x")
        try expectClose(restored.midY, original.midY, "round-trip center y")
        try expectClose(restored.width, original.width, "round-trip diameter")
        guard settings.shape == .circle, settings.enabled else {
            throw failure("mapped overlay should stay an enabled circle")
        }
    }

    private static func yFlipMapsBottomRightToHighNormalizedY() throws {
        let frame = RecordingHUDLayout.cameraFrame(
            settings: WebcamOverlaySettings(
                enabled: true,
                position: WebcamOverlaySettings.defaultPosition,
                size: WebcamOverlaySettings.defaultSize
            ),
            displayBounds: display
        )
        let settings = RecordingHUDLayout.overlaySettings(
            cameraFrame: frame,
            displayBounds: display,
            existing: WebcamOverlaySettings()
        )
        try expectClose(settings.position.x, WebcamOverlaySettings.defaultPosition.x, "default x")
        try expectClose(settings.position.y, WebcamOverlaySettings.defaultPosition.y, "default y")
        guard frame.midY < display.midY else {
            throw failure("default overlay sits in the lower half of AppKit coordinates")
        }
    }

    private static func clampKeepsCircleInsideDisplay() throws {
        let offscreen = RecordingHUDLayout.cameraFrame(
            center: CGPoint(x: display.maxX + 400, y: display.minY - 200),
            diameter: 4_000
        )
        let clamped = RecordingHUDLayout.clampCameraFrame(offscreen, to: display)
        let range = RecordingHUDLayout.allowedDiameterRange(displayBounds: display)
        guard display.insetBy(dx: 1, dy: 1).contains(clamped) else {
            throw failure("clamped camera left the captured display: \(clamped)")
        }
        guard clamped.width <= range.upperBound + 0.5,
              clamped.width >= range.lowerBound - 0.5
        else {
            throw failure("clamped diameter \(clamped.width) is outside \(range)")
        }
    }

    private static func defaultFrameIsOnDisplay() throws {
        let frame = RecordingHUDLayout.defaultCameraFrame(displayBounds: display)
        let clamped = RecordingHUDLayout.clampCameraFrame(frame, to: display)
        try expectClose(frame.midX, clamped.midX, "default x already on-display")
        try expectClose(frame.midY, clamped.midY, "default y already on-display")
        guard display.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            throw failure("default camera center is not on the display")
        }
    }

    private static func windowFramePlacesPillBelowCamera() throws {
        let camera = RecordingHUDLayout.cameraFrame(
            center: CGPoint(x: display.midX, y: display.midY),
            diameter: 180
        )
        let window = RecordingHUDLayout.windowFrame(
            cameraFrame: camera,
            showsCamera: true,
            collapsed: false
        )
        guard window.maxY >= camera.maxY,
              window.minY < camera.minY,
              abs(window.midX - camera.midX) < 1
        else {
            throw failure("expanded HUD window should wrap the camera with the pill below it")
        }
    }

    private static func collapsedWindowCentersOnCamera() throws {
        let camera = RecordingHUDLayout.cameraFrame(
            center: CGPoint(x: display.maxX - 200, y: display.minY + 160),
            diameter: 180
        )
        let window = RecordingHUDLayout.windowFrame(
            cameraFrame: camera,
            showsCamera: true,
            collapsed: true
        )
        try expectClose(window.midX, camera.midX, "collapsed pill x")
        try expectClose(window.midY, camera.midY, "collapsed pill y")
        guard window.height < camera.height else {
            throw failure("collapsed HUD should be smaller than the camera bubble")
        }
    }

    private static func silentMicrophoneBufferMatchesFormat() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)
        else {
            throw failure("could not create a PCM buffer for mute coverage")
        }
        buffer.frameLength = 512
        if let samples = buffer.floatChannelData {
            samples[0][0] = 0.75
            samples[0][100] = -0.5
        }
        let silent = MicrophoneRecorder.silentBuffer(matching: buffer)
        guard silent.frameLength == buffer.frameLength,
              silent.format.sampleRate == buffer.format.sampleRate
        else {
            throw failure("silent buffer did not preserve format or frame length")
        }
        if let samples = silent.floatChannelData {
            guard samples[0][0] == 0, samples[0][100] == 0 else {
                throw failure("muted buffer still contained audio samples")
            }
        }
    }

    private static func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ label: String) throws {
        guard abs(actual - expected) < 0.75 else {
            throw failure("\(label): expected \(expected), got \(actual)")
        }
    }

    private static func expectClose(_ actual: Double, _ expected: Double, _ label: String) throws {
        try expectClose(CGFloat(actual), CGFloat(expected), label)
    }

    private static func failure(_ message: String) -> OpenRecordError {
        .io("Recording HUD layout regression: \(message)")
    }
}

@Test
func recordingHUDLayout() throws {
    try RecordingHUDLayoutSuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordRecordingHUDLayoutTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunRecordingHUDLayoutTests()
}

@_cdecl("OpenRecordRunRecordingHUDLayoutTests")
func OpenRecordRunRecordingHUDLayoutTests() {
    do {
        try RecordingHUDLayoutSuite.run()
        fputs("OpenRecordTests: recording HUD layout tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: recording HUD layout tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
