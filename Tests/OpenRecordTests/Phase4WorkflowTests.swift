import Foundation
import Testing
@testable import OpenRecord

@Test
func recordingOptionsPreserveExistingDefaults() {
    let request = CaptureRequest.default
    #expect(request.capturesMicrophone)
    #expect(request.capturesSystemAudio)
    #expect(request.capturesCursorTelemetry)
    #expect(request.capturesKeyboardShortcuts)
    #expect(!request.capturesWebcam)
    #expect(request.requiresAccessibility)
}

@Test
func recordingOptionsRequestOnlySelectedPermissions() {
    let screenOnly = CaptureRequest(
        capturesMicrophone: false,
        capturesSystemAudio: false,
        capturesCursorTelemetry: false,
        capturesKeyboardShortcuts: false,
        capturesWebcam: false
    )
    #expect(CapturePermissions.requiredPermissions(for: screenOnly) == [.screenRecording])

    let micAndCamera = CaptureRequest(
        capturesMicrophone: true,
        capturesSystemAudio: false,
        capturesCursorTelemetry: false,
        capturesKeyboardShortcuts: false,
        capturesWebcam: true
    )
    #expect(
        CapturePermissions.requiredPermissions(for: micAndCamera)
            == [.screenRecording, .microphone, .camera]
    )

    let keyboardOnly = CaptureRequest(
        capturesMicrophone: false,
        capturesSystemAudio: true,
        capturesCursorTelemetry: false,
        capturesKeyboardShortcuts: true,
        capturesWebcam: false
    )
    #expect(
        CapturePermissions.requiredPermissions(for: keyboardOnly)
            == [.screenRecording, .accessibility]
    )
}

@Test
func unrequestedTracksProduceNotRequestedDiagnostics() {
    let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
        referenceDuration: 12,
        observations: [
            CaptureTrackObservation(track: .displayVideo, duration: 12),
            CaptureTrackObservation(track: .systemAudio, requested: false),
            CaptureTrackObservation(track: .microphone, requested: false),
            CaptureTrackObservation(track: .webcam, requested: false),
        ]
    )

    #expect(diagnostics.diagnostic(for: .displayVideo)?.status == .complete)
    #expect(diagnostics.diagnostic(for: .systemAudio)?.status == .notRequested)
    #expect(diagnostics.diagnostic(for: .microphone)?.status == .notRequested)
    #expect(diagnostics.diagnostic(for: .webcam)?.status == .notRequested)
}

@Test
func recordingOptionsRoundTripAsPortableJSON() throws {
    let request = CaptureRequest(
        capturesMicrophone: false,
        capturesSystemAudio: true,
        capturesCursorTelemetry: true,
        capturesKeyboardShortcuts: false,
        capturesWebcam: true
    )
    let data = try ProjectJSON.encoder.encode(request)
    let decoded = try ProjectJSON.decoder.decode(CaptureRequest.self, from: data)
    #expect(decoded == request)
}
