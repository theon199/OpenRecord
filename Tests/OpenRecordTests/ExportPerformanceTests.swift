import Darwin
import Foundation
import Testing
@testable import OpenRecord

enum ExportPerformanceTests {
    static func run() throws {
        try estimatorWithholdsUnstableEstimates()
        try estimatorReportsRollingFPSAndETA()
        try progressSanitizesAndDoesNotRegress()
        try completionForcesFinalStatus()
        try failuresContainActionableRecovery()
    }

    static func estimatorWithholdsUnstableEstimates() throws {
        var estimator = ExportProgressEstimator(
            totalFrames: 120,
            sampleWindowSize: 4,
            minimumSampleCount: 3,
            minimumElapsedSeconds: 0.5
        )

        let first = estimator.update(framesCompleted: 10, elapsedSeconds: 0)
        let second = estimator.update(framesCompleted: 20, elapsedSeconds: 0.1)
        let third = estimator.update(framesCompleted: 30, elapsedSeconds: 0.6)

        guard first.framesPerSecond == nil, first.estimatedRemainingSeconds == nil,
              second.framesPerSecond == nil, second.estimatedRemainingSeconds == nil,
              let fps = third.framesPerSecond, abs(fps - 33.3333333333) < 0.0001,
              let eta = third.estimatedRemainingSeconds, abs(eta - 2.7) < 0.0001
        else {
            throw OpenRecordError.io("progress estimator exposed an unstable startup estimate")
        }
    }

    static func estimatorReportsRollingFPSAndETA() throws {
        var estimator = ExportProgressEstimator(
            totalFrames: 100,
            sampleWindowSize: 3,
            minimumSampleCount: 2,
            minimumElapsedSeconds: 0.1
        )
        _ = estimator.update(framesCompleted: 10, elapsedSeconds: 0)
        _ = estimator.update(framesCompleted: 30, elapsedSeconds: 1)
        let beforeRoll = estimator.update(framesCompleted: 50, elapsedSeconds: 2)
        let afterRoll = estimator.update(framesCompleted: 70, elapsedSeconds: 3)

        guard let beforeFPS = beforeRoll.framesPerSecond,
              let beforeETA = beforeRoll.estimatedRemainingSeconds,
              abs(beforeFPS - 20) < 0.0001,
              abs(beforeETA - 2.5) < 0.0001,
              let afterFPS = afterRoll.framesPerSecond,
              let afterETA = afterRoll.estimatedRemainingSeconds,
              abs(afterFPS - 20) < 0.0001,
              abs(afterETA - 1.5) < 0.0001
        else {
            throw OpenRecordError.io("rolling FPS or ETA was not calculated from the bounded sample window")
        }
    }

    static func progressSanitizesAndDoesNotRegress() throws {
        let sanitized = ExportProgress(
            phase: .rendering,
            fraction: .nan,
            framesCompleted: 99,
            totalFrames: -4,
            elapsedSeconds: -.infinity,
            framesPerSecond: .infinity,
            estimatedRemainingSeconds: -10
        )
        guard sanitized.fraction == 0,
              sanitized.framesCompleted == 0,
              sanitized.totalFrames == 0,
              sanitized.elapsedSeconds == 0,
              sanitized.framesPerSecond == nil,
              sanitized.estimatedRemainingSeconds == 0
        else {
            throw OpenRecordError.io("export progress did not sanitize invalid values")
        }

        var estimator = ExportProgressEstimator(totalFrames: 100)
        let later = estimator.update(framesCompleted: 70, elapsedSeconds: 3)
        let earlier = estimator.update(framesCompleted: 10, elapsedSeconds: 1)
        guard earlier.fraction >= later.fraction,
              earlier.framesCompleted == later.framesCompleted,
              earlier.elapsedSeconds == later.elapsedSeconds
        else {
            throw OpenRecordError.io("export progress regressed after an out-of-order sample")
        }

        let alternate = ExportProgress.fractionOnly(2, phase: .preparing)
        guard alternate.fraction == 1, alternate.framesCompleted == 0 else {
            throw OpenRecordError.io("fraction-only progress did not clamp or omit frame counts")
        }
    }

    static func completionForcesFinalStatus() throws {
        var estimator = ExportProgressEstimator(totalFrames: 120)
        _ = estimator.update(framesCompleted: 80, elapsedSeconds: 2)
        let completed = estimator.complete(elapsedSeconds: 2.5)
        guard completed.phase == .completed,
              completed.fraction == 1,
              completed.framesCompleted == 120,
              completed.totalFrames == 120,
              completed.estimatedRemainingSeconds == 0,
              completed.elapsedSeconds == 2.5
        else {
            throw OpenRecordError.io("completed export status was not final and deterministic")
        }
    }

    static func failuresContainActionableRecovery() throws {
        let stages: [(ExportFailureStage, String)] = [
            (.sourceReading, "source"),
            (.frameRendering, "frame"),
            (.videoEncoding, "video"),
            (.audioMixing, "audio"),
            (.finalization, "final"),
            (.installation, "install"),
        ]
        for (stage, marker) in stages {
            let failure = ExportFailure(stage: stage, message: "fixture failure")
            guard failure.errorDescription?.localizedCaseInsensitiveContains(marker) == true,
                  !failure.recoverySuggestion.isEmpty,
                  failure.failureReason == "fixture failure"
            else {
                throw OpenRecordError.io("export failure for \(stage.rawValue) lacked actionable context")
            }
        }

        let custom = ExportFailure(
            stage: .installation,
            message: "destination unavailable",
            recoverySuggestion: "Choose another writable folder."
        )
        guard custom.recoverySuggestion == "Choose another writable folder." else {
            throw OpenRecordError.io("custom export recovery guidance was not preserved")
        }
    }
}

@Test
func exportPerformanceModel() throws {
    try ExportPerformanceTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordExportPerformanceTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunExportPerformanceTests()
}

@_cdecl("OpenRecordRunExportPerformanceTests")
func OpenRecordRunExportPerformanceTests() {
    do {
        try ExportPerformanceTests.run()
        fputs("OpenRecordTests: export performance model tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: export performance model tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
