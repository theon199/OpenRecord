import Darwin
import Foundation
import OpenRecord
import Testing

/// Deterministic checks for the capture-finalization policy.  These tests use
/// only metadata and temporary bundles, so they do not require capture
/// permissions, AVFoundation devices, or a wall-clock recording.
enum CaptureRecoveryTests {
    static let testCount = 7

    static func run() throws {
        try usableDisplayIsThePrimaryRecoveryCriterion()
        try healthSortsWarningsAndClassifiesStopReasons()
        try legacyMetadataDecodesWithoutDiagnostics()
        try diagnosticsRoundTripThroughProjectMeta()
        try timedOutFinalizationPreservesDiagnosticsAndIsIdempotent()
        try optionalFailuresStillPreserveUsableDisplay()
        try recoveryResultCanRepresentDegradedOptionalTracks()
    }

    private static func usableDisplayIsThePrimaryRecoveryCriterion() throws {
        guard CaptureRecovery.shouldPreserveProject(hasUsableDisplayVideo: true),
              !CaptureRecovery.shouldPreserveProject(hasUsableDisplayVideo: false)
        else {
            throw OpenRecordError.io("display media was not used as the primary preservation criterion")
        }
    }

    private static func healthSortsWarningsAndClassifiesStopReasons() throws {
        let warnings: Set<CaptureWarningCode> = [
            .truncatedWebcam,
            .missingMicrophone,
            .keyboardSecureInputGap,
        ]
        let sorted = warnings.sorted { $0.rawValue < $1.rawValue }
        let manual = CaptureRecovery.health(reason: .manual, warnings: warnings)
        guard manual.state == .recovered,
              manual.warnings == sorted
        else {
            throw OpenRecordError.io("manual capture health did not preserve sorted optional-track warnings")
        }

        let secureInputOnly = CaptureRecovery.health(
            reason: .manual,
            warnings: [.keyboardSecureInputGap]
        )
        guard secureInputOnly.state == .complete else {
            throw OpenRecordError.io("secure-input gaps alone incorrectly degraded a manual capture")
        }

        let termination = CaptureRecovery.health(reason: .applicationTermination, warnings: [])
        let unexpected = CaptureRecovery.health(
            reason: .unexpected("display writer stopped"),
            warnings: []
        )
        guard termination.state == .recovered, unexpected.state == .recovered else {
            throw OpenRecordError.io("non-manual stop reasons were not marked recovered")
        }
    }

    private static func legacyMetadataDecodesWithoutDiagnostics() throws {
        let legacy = Data(
            #"""
            {
              "appVersion":"1.0.1",
              "captureTarget":{"display":{"id":1}},
              "createdAt":"2024-01-02T03:04:05Z",
              "displayBounds":{"height":1080,"width":1920,"x":0,"y":0},
              "scale":2
            }
            """#.utf8
        )
        let meta = try ProjectJSON.decoder.decode(ProjectMeta.self, from: legacy)
        guard meta.captureHealth == nil, meta.captureDiagnostics == nil,
              meta.captureTiming == nil, meta.displayBounds.width == 1920
        else {
            throw OpenRecordError.io("legacy metadata did not default missing capture diagnostics safely")
        }
    }

    private static func diagnosticsRoundTripThroughProjectMeta() throws {
        let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 60,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: 60),
                CaptureTrackObservation(track: .microphone, duration: 60.25, initialOffset: 0.1),
                CaptureTrackObservation(track: .webcam, requested: false),
            ],
            minimumAvailableDiskBytes: 3 * 1_024 * 1_024 * 1_024
        )
        let original = ProjectMeta(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            displayBounds: Rect2D(x: 0, y: 0, width: 1920, height: 1080),
            scale: 2,
            captureTarget: .display(id: 1),
            captureDiagnostics: diagnostics
        )
        let decoded = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: ProjectJSON.encoder.encode(original)
        )
        guard decoded == original,
              decoded.captureDiagnostics?.minimumAvailableDiskBytes == 3 * 1_024 * 1_024 * 1_024,
              decoded.captureDiagnostics?.correction(for: .microphone) != nil
        else {
            throw OpenRecordError.io("capture diagnostics did not round-trip through ProjectMeta")
        }
    }

    private static func timedOutFinalizationPreservesDiagnosticsAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordCaptureRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundle = root.appendingPathComponent("Timeout.openrecord", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 10,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: 10),
                CaptureTrackObservation(track: .microphone, duration: 10, initialOffset: 0),
            ]
        )
        let original = ProjectMeta(
            displayBounds: Rect2D(x: 12, y: 34, width: 640, height: 480),
            scale: 2,
            captureTarget: .window(id: 7),
            captureHealth: CaptureHealth(state: .recovered, warnings: [.truncatedMicrophone]),
            captureDiagnostics: diagnostics
        )
        try ProjectJSON.encoder.encode(original).write(
            to: ProjectLayout.metaURL(in: bundle),
            options: .atomic
        )

        try CaptureRecovery.markFinalizationTimedOut(at: bundle)
        let once = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: Data(contentsOf: ProjectLayout.metaURL(in: bundle))
        )
        try CaptureRecovery.markFinalizationTimedOut(at: bundle)
        let twice = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: Data(contentsOf: ProjectLayout.metaURL(in: bundle))
        )
        guard once.displayBounds == original.displayBounds,
              once.captureDiagnostics == diagnostics,
              once.captureHealth?.state == .recovered,
              once.captureHealth?.warnings == [.finalizationTimedOut, .truncatedMicrophone],
              twice == once
        else {
            throw OpenRecordError.io("timed-out finalization did not preserve metadata atomically and idempotently")
        }
    }

    private static func optionalFailuresStillPreserveUsableDisplay() throws {
        let optionalTracks: [CaptureTrackKind] = [.systemAudio, .microphone, .webcam]
        let observations = [CaptureTrackObservation(track: .displayVideo, duration: 30)]
            + optionalTracks.map {
                CaptureTrackObservation(track: $0, requested: true, duration: nil)
            }
        let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 30,
            observations: observations
        )
        guard diagnostics.diagnostic(for: .displayVideo)?.status == .complete,
              optionalTracks.allSatisfy({ diagnostics.diagnostic(for: $0)?.status == .missing }),
              CaptureRecovery.shouldPreserveProject(hasUsableDisplayVideo: true)
        else {
            throw OpenRecordError.io("optional track failure made a usable display capture unrecoverable")
        }
    }

    private static func recoveryResultCanRepresentDegradedOptionalTracks() throws {
        let result = CaptureStopResult(
            projectURL: URL(fileURLWithPath: "/tmp/recovered.openrecord"),
            reason: .unexpected("microphone writer failed"),
            health: CaptureRecovery.health(reason: .unexpected("microphone writer failed"), warnings: [.missingMicrophone]),
            hasUsableVideo: true,
            finalizationError: "microphone unavailable"
        )
        guard result.hasUsableVideo,
              result.health.state == .recovered,
              result.health.warnings == [.missingMicrophone]
        else {
            throw OpenRecordError.io("degraded capture result did not retain usable display recovery")
        }
    }
}

@Test
func captureRecoveryPhase3Contracts() throws {
    try CaptureRecoveryTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCaptureRecoveryTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCaptureRecoveryTests()
}

@_cdecl("OpenRecordRunCaptureRecoveryTests")
func OpenRecordRunCaptureRecoveryTests() {
    do {
        try CaptureRecoveryTests.run()
        fputs(
            "OpenRecordTests: CaptureRecoveryTests files=1 tests=\(CaptureRecoveryTests.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: CaptureRecoveryTests files=1 tests=\(CaptureRecoveryTests.testCount) failures=1 error=\(error)\n", stderr)
        abort()
    }
}
#endif
