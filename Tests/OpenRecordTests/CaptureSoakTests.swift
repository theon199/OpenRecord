import Darwin
import Foundation
import OpenRecord
import Testing

/// Accelerated long-session profiles.  A profile is represented by timestamp
/// observations, keeping this suite deterministic and independent of devices,
/// permissions, and wall-clock sleeps.
enum CaptureSoakTests {
    static let testCount = 6

    private static func approximately(
        _ actual: TimeInterval?,
        _ expected: TimeInterval,
        tolerance: TimeInterval = 0.000_001
    ) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) <= tolerance
    }

    static func run() throws {
        try acceleratedLongSessionProfiles()
        try driftToleranceHasExactBoundary()
        try positiveAndNegativeDriftMapAtStartMiddleAndEnd()
        try truncatedTracksNeverReceiveCorrections()
        try diskThresholdBoundariesAreStable()
        try diagnosticsJSONRoundTripPreservesCorrections()
    }

    private static func acceleratedLongSessionProfiles() throws {
        let profiles: [(name: String, duration: TimeInterval)] = [
            ("30m", 30 * 60),
            ("1h", 60 * 60),
            ("2h", 2 * 60 * 60),
        ]
        for profile in profiles {
            let reference = profile.duration
            // End timestamps model VFR-like tracks whose final sample does not
            // land exactly on the display duration.
            let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
                referenceDuration: reference,
                observations: [
                    CaptureTrackObservation(track: .displayVideo, duration: reference + 0.033),
                    CaptureTrackObservation(track: .microphone, duration: reference + 0.19, initialOffset: 0.04),
                    CaptureTrackObservation(track: .systemAudio, duration: reference - 0.16, initialOffset: -0.03),
                    CaptureTrackObservation(track: .webcam, duration: reference + 0.24, initialOffset: 0.06),
                ],
                minimumAvailableDiskBytes: 3 * 1_024 * 1_024 * 1_024
            )
            guard diagnostics.referenceDuration == reference,
                  diagnostics.diagnostic(for: .displayVideo)?.status == .complete,
                  diagnostics.correction(for: .microphone) != nil,
                  diagnostics.correction(for: .systemAudio) != nil,
                  diagnostics.correction(for: .webcam) != nil,
                  diagnostics.sourceTime(for: .webcam, atTimelineTime: reference) != nil
            else {
                throw OpenRecordError.io("accelerated \(profile.name) soak profile lost VFR-like correction data")
            }
        }
    }

    private static func driftToleranceHasExactBoundary() throws {
        let reference: TimeInterval = 100
        let cases: [(label: String, endDrift: TimeInterval, corrected: Bool)] = [
            ("below", 0.099, false),
            ("exact", 0.100, false),
            ("above", 0.101, true),
        ]
        for item in cases {
            let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
                referenceDuration: reference,
                observations: [
                    CaptureTrackObservation(track: .displayVideo, duration: reference),
                    CaptureTrackObservation(
                        track: .webcam,
                        duration: reference + item.endDrift - 0.02,
                        initialOffset: 0.02
                    ),
                ]
            )
            let webcam = diagnostics.diagnostic(for: .webcam)
            guard approximately(webcam?.endDrift, item.endDrift),
                  (webcam?.correction != nil) == item.corrected
            else {
                throw OpenRecordError.io("100 ms drift tolerance mishandled the \(item.label) boundary")
            }
        }
    }

    private static func positiveAndNegativeDriftMapAtStartMiddleAndEnd() throws {
        let reference = 3_600.0
        let positive = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: reference,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: reference),
                CaptureTrackObservation(track: .webcam, duration: reference + 0.15, initialOffset: 0.10),
            ]
        )
        let negative = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: reference,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: reference),
                CaptureTrackObservation(track: .microphone, duration: reference - 0.30, initialOffset: -0.20),
            ]
        )

        let positiveCorrection = positive.correction(for: .webcam)
        let negativeCorrection = negative.correction(for: .microphone)
        guard let positiveCorrection, let negativeCorrection,
              approximately(positive.diagnostic(for: .webcam)?.endDrift, 0.25),
              approximately(negative.diagnostic(for: .microphone)?.endDrift, -0.5)
        else {
            throw OpenRecordError.io("positive or negative drift did not produce a correction")
        }

        let positiveExpected: [(timeline: TimeInterval, source: TimeInterval)] = [
            (0.10, 0),
            (reference / 2, (reference / 2 - 0.10) * positiveCorrection.sourceRate),
            (reference, positiveCorrection.sourceDuration),
        ]
        for point in positiveExpected {
            guard let mapped = positive.sourceTime(for: .webcam, atTimelineTime: point.timeline),
                  abs(mapped - point.source) < 0.000_001
            else {
                throw OpenRecordError.io("positive drift mapping failed at timeline \(point.timeline)")
            }
        }

        let negativeExpected: [(timeline: TimeInterval, source: TimeInterval)] = [
            (0, 0.20 * negativeCorrection.sourceRate),
            (reference / 2, (reference / 2 + 0.20) * negativeCorrection.sourceRate),
            (reference, negativeCorrection.sourceDuration),
        ]
        for point in negativeExpected {
            guard let mapped = negative.sourceTime(for: .microphone, atTimelineTime: point.timeline),
                  abs(mapped - point.source) < 0.000_001
            else {
                throw OpenRecordError.io("negative drift mapping failed at timeline \(point.timeline)")
            }
        }
    }

    private static func truncatedTracksNeverReceiveCorrections() throws {
        let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 600,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: 600),
                CaptureTrackObservation(track: .webcam, duration: 620, initialOffset: 0.2, truncated: true),
            ]
        )
        let webcam = diagnostics.diagnostic(for: .webcam)
        guard webcam?.status == .truncated,
              approximately(webcam?.endDrift, 20.2),
              webcam?.correction == nil,
              diagnostics.sourceRate(for: .webcam) == 1
        else {
            throw OpenRecordError.io("truncated track received a non-destructive clock correction")
        }
    }

    private static func diskThresholdBoundariesAreStable() throws {
        let low = CaptureDiskSpacePolicy.lowBytes
        let critical = CaptureDiskSpacePolicy.criticalBytes
        guard CaptureDiskSpacePolicy.level(availableBytes: critical - 1) == .critical,
              CaptureDiskSpacePolicy.level(availableBytes: critical) == .critical,
              CaptureDiskSpacePolicy.level(availableBytes: critical + 1) == .low,
              CaptureDiskSpacePolicy.level(availableBytes: low) == .low,
              CaptureDiskSpacePolicy.level(availableBytes: low + 1) == .sufficient
        else {
            throw OpenRecordError.io("capture disk-space threshold boundary changed unexpectedly")
        }
    }

    private static func diagnosticsJSONRoundTripPreservesCorrections() throws {
        let diagnostics = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 1_800,
            observations: [
                CaptureTrackObservation(track: .displayVideo, duration: 1_800),
                CaptureTrackObservation(track: .microphone, duration: 1_801, initialOffset: 0.2),
                CaptureTrackObservation(track: .webcam, duration: 1_799, initialOffset: -0.1),
            ],
            minimumAvailableDiskBytes: CaptureDiskSpacePolicy.lowBytes
        )
        let data = try ProjectJSON.encoder.encode(diagnostics)
        let decoded = try ProjectJSON.decoder.decode(CaptureDiagnostics.self, from: data)
        guard decoded == diagnostics,
              approximately(decoded.correction(for: .microphone)?.timelineDuration, 1_799.8),
              approximately(decoded.correction(for: .webcam)?.timelineDuration, 1_800.1)
        else {
            throw OpenRecordError.io("diagnostics JSON round-trip changed correction or disk-health data")
        }
    }
}

@Test
func captureSoakPhase3Contracts() throws {
    try CaptureSoakTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCaptureSoakTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCaptureSoakTests()
}

@_cdecl("OpenRecordRunCaptureSoakTests")
func OpenRecordRunCaptureSoakTests() {
    do {
        try CaptureSoakTests.run()
        fputs(
            "OpenRecordTests: CaptureSoakTests files=1 tests=\(CaptureSoakTests.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: CaptureSoakTests files=1 tests=\(CaptureSoakTests.testCount) failures=1 error=\(error)\n", stderr)
        abort()
    }
}
#endif
