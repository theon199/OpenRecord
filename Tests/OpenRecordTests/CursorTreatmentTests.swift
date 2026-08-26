import Foundation
import OpenRecord
import Testing

/// Cursor effects are source-timed. These checks intentionally exercise the
/// evaluator independently of either renderer so preview/export can share the
/// same deterministic decision.
enum CursorTreatmentSuite {
    static let testCount = 5

    static func run() throws {
        try defaultsAndHalfOpenBoundaries()
        try overlapUsesLatestStartThenStableID()
        try normalizationClampsValues()
        try hiddenAndEmphasisState()
        try outputMapperFeedsSourceEvaluation()
    }

    static func defaultsAndHalfOpenBoundaries() throws {
        let evaluator = CursorTreatmentEvaluator(ranges: [])
        let before = evaluator.state(at: -1, baseScale: 0.5)
        let nan = evaluator.state(at: .nan, baseScale: 0.5)
        guard before == CursorTreatmentState(scale: 0.5),
              nan == CursorTreatmentState(scale: 0.5)
        else {
            throw OpenRecordError.io("Cursor treatment defaults changed")
        }

        let range = CursorEffectRange(start: 1, end: 2, visible: false, scale: 2)
        let state = CursorTreatmentEvaluator(ranges: [range])
        guard !state.state(at: 1, baseScale: 0.5).visible,
              state.state(at: 0.999, baseScale: 0.5).visible,
              state.state(at: 2, baseScale: 0.5) == CursorTreatmentState(scale: 0.5)
        else {
            throw OpenRecordError.io("Cursor effect boundaries are not half-open")
        }
    }

    static func overlapUsesLatestStartThenStableID() throws {
        let earlier = CursorEffectRange(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            start: 1,
            end: 4,
            scale: 1.2
        )
        let later = CursorEffectRange(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            start: 2,
            end: 3,
            scale: 2.2
        )
        let evaluator = CursorTreatmentEvaluator(ranges: [later, earlier])
        guard evaluator.state(at: 2.5, baseScale: 0.5).scale == 2.2,
              evaluator.state(at: 3.5, baseScale: 0.5).scale == 1.2
        else {
            throw OpenRecordError.io("Cursor overlap precedence is not source-deterministic")
        }

        let lowID = CursorEffectRange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            start: 2,
            end: 3,
            scale: 1.1
        )
        let highID = CursorEffectRange(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            start: 2,
            end: 3,
            scale: 2.9
        )
        guard CursorTreatmentEvaluator(ranges: [highID, lowID])
            .state(at: 2.5, baseScale: 0.5).scale == 2.9
        else {
            throw OpenRecordError.io("Equal-start cursor overlap did not use stable ID")
        }
    }

    static func normalizationClampsValues() throws {
        let range = CursorEffectRange(
            start: -.infinity,
            end: .infinity,
            scale: 99,
            clickEmphasis: true,
            halo: true
        )
        let state = CursorTreatmentEvaluator(ranges: [range]).state(at: 0, baseScale: 0.5)
        guard state.scale == CursorEffectRange.scaleRange.upperBound,
              state.clickEmphasis,
              state.halo
        else {
            throw OpenRecordError.io("Cursor effect normalization did not clamp")
        }
    }

    static func hiddenAndEmphasisState() throws {
        let range = CursorEffectRange(
            start: 0,
            end: 1,
            visible: false,
            scale: 0.1,
            clickEmphasis: false,
            halo: true
        )
        let state = CursorTreatmentEvaluator(ranges: [range]).state(at: 0.25, baseScale: 0.5)
        guard !state.visible, !state.clickEmphasis, state.halo, state.scale == 0.1 else {
            throw OpenRecordError.io("Cursor hide/emphasis/halo state was not preserved")
        }
    }

    static func outputMapperFeedsSourceEvaluation() throws {
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            editDecisions: [EditDecision(start: 2, end: 4)],
            speedSegments: [SpeedSegment(start: 4, end: 8, rate: 2)]
        )
        let effects = CursorTreatmentEvaluator(ranges: [
            CursorEffectRange(start: 4, end: 5, visible: false)
        ])
        // output 2 lands at source 4 after the cut; the source-time range is
        // therefore active exactly where preview and export should evaluate it.
        let sourceTime = mapper.sourceTime(atOutputTime: 2)
        guard abs(sourceTime - 4) < 0.000_001,
              !effects.state(at: sourceTime, baseScale: 0.5).visible,
              abs(mapper.sourceTime(atOutputTime: 3) - 6) < 0.000_001
        else {
            throw OpenRecordError.io("Cursor treatment did not follow mapped source time")
        }
    }
}

@Test func cursorTreatmentDefaultsAndBoundaries() throws {
    try CursorTreatmentSuite.defaultsAndHalfOpenBoundaries()
}

@Test func cursorTreatmentOverlapPrecedence() throws {
    try CursorTreatmentSuite.overlapUsesLatestStartThenStableID()
}

@Test func cursorTreatmentNormalization() throws {
    try CursorTreatmentSuite.normalizationClampsValues()
}

@Test func cursorTreatmentHideEmphasisAndHalo() throws {
    try CursorTreatmentSuite.hiddenAndEmphasisState()
}

@Test func cursorTreatmentUsesMappedSourceTime() throws {
    try CursorTreatmentSuite.outputMapperFeedsSourceEvaluation()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordCursorTreatmentTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunCursorTreatmentTests()
}

@_cdecl("OpenRecordRunCursorTreatmentTests")
func OpenRecordRunCursorTreatmentTests() {
    do {
        try CursorTreatmentSuite.run()
        fputs(
            "OpenRecordTests: CursorTreatmentTests files=1 tests=\(CursorTreatmentSuite.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: CursorTreatmentTests files=1 tests=\(CursorTreatmentSuite.testCount) failures=1 error=\(error)\n",
            stderr
        )
        abort()
    }
}
#endif
