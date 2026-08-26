import Darwin
import Foundation
@testable import OpenRecord
import Testing

/// Deterministic coverage for the composed edit-decision and speed clock.
///
/// Keep these checks in a callable suite as well as `@Test` wrappers. The
/// Command Line Tools test host used by this project loads the test bundle but
/// does not reliably run Swift Testing's generated entry point.
enum EditDecisionMappingSuite {
    static let testCount = 7

    static func run() throws {
        try legacyIdentityAndEndpointSemantics()
        try adjacentAndMultipleCutsRipple()
        try malformedRangesNormalizeWithTrim()
        try speedComposesAcrossCutsAndBoundaries()
        try excludedSourceBoundariesAreHalfOpen()
        try audioPlacementsFollowTheAuthoritativeSlices()
        try previewAndExportFixtureStaysDeterministic()
    }

    static func legacyIdentityAndEndpointSemantics() throws {
        let mapper = ProjectTimeMapper(sourceDuration: 10)
        try expectClose(mapper.sourceStart, 0, "legacy source start")
        try expectClose(mapper.sourceEnd, 10, "legacy source end")
        try expectClose(mapper.outputDuration, 10, "legacy output duration")
        try expectClose(mapper.sourceTime(atOutputTime: 0), 0, "legacy output start")
        try expectClose(mapper.sourceTime(atOutputTime: 10), 10, "legacy output end")
        try expectClose(
            try require(mapper.outputTime(forSourceTime: 4), "legacy source time"),
            4,
            "legacy source/output identity"
        )
        guard mapper.outputTime(forSourceTime: -0.01) == nil,
              mapper.isIncluded(sourceTime: 9.999),
              !mapper.isIncluded(sourceTime: 10)
        else {
            throw OpenRecordError.io("Legacy mapping endpoint semantics changed")
        }
    }

    static func adjacentAndMultipleCutsRipple() throws {
        let first = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            editDecisions: [
                EditDecision(id: first, start: 2, end: 3),
                EditDecision(id: second, start: 3, end: 4),
                EditDecision(start: 6, end: 7),
            ]
        )

        guard mapper.editDecisions.count == 3 else {
            throw OpenRecordError.io("Adjacent edit-decision identities were lost")
        }
        try expectClose(mapper.outputDuration, 7, "multiple-cut output duration")
        try expectClose(mapper.sourceTime(atOutputTime: 2), 4, "first ripple boundary")
        try expectClose(mapper.sourceTime(atOutputTime: 4), 7, "second ripple boundary")
        guard mapper.outputTime(forSourceTime: 2.5) == nil,
              mapper.outputTime(forSourceTime: 3.5) == nil,
              mapper.outputTime(forSourceTime: 6.5) == nil
        else {
            throw OpenRecordError.io("Excluded source interiors unexpectedly mapped to output")
        }
        try expectClose(
            try require(mapper.outputTime(forSourceTime: 4), "retained source after adjacent cuts"),
            2,
            "adjacent-cut ripple output"
        )
        try expectClose(mapper.clampedOutputTime(forSourceTime: 3.5), 2, "clamped adjacent cut")
        try expectClose(mapper.clampedOutputTime(forSourceTime: 9), 6, "retained tail output")
    }

    static func malformedRangesNormalizeWithTrim() throws {
        let duplicateID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 2,
            trimOut: 8,
            editDecisions: [
                EditDecision(id: duplicateID, start: 3, end: 5),
                EditDecision(id: duplicateID, start: 5, end: 6),
                EditDecision(start: 4, end: 7),
                EditDecision(start: -10, end: -9),
            ]
        )

        guard mapper.editDecisions.count == 2 else {
            throw OpenRecordError.io("Malformed decisions did not normalize deterministically")
        }
        try expectClose(mapper.sourceStart, 2, "trimmed source start")
        try expectClose(mapper.sourceEnd, 8, "trimmed source end")
        try expectClose(mapper.editDecisions[0].start, 3, "first normalized cut start")
        try expectClose(mapper.editDecisions[0].end, 5, "first normalized cut end")
        try expectClose(mapper.editDecisions[1].start, 5, "overlap-trimmed cut start")
        try expectClose(mapper.editDecisions[1].end, 7, "overlap-trimmed cut end")
        try expectClose(mapper.outputDuration, 2, "trim-plus-cut output duration")
        try expectClose(mapper.sourceTime(atOutputTime: 0), 2, "trimmed output start")
        try expectClose(mapper.sourceTime(atOutputTime: 1), 7, "trimmed cut boundary")
        try expectClose(mapper.sourceTime(atOutputTime: 2), 8, "trimmed output end")

        let reusableID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let duplicateAfterInvalid = ProjectTimeMapper.normalizedDecisions(
            [
                EditDecision(id: reusableID, start: 1, end: 1),
                EditDecision(id: reusableID, start: 2, end: 3),
            ],
            sourceDuration: 10
        )
        guard duplicateAfterInvalid.count == 1,
              duplicateAfterInvalid[0].start == 2,
              duplicateAfterInvalid[0].end == 3
        else {
            throw OpenRecordError.io("An invalid range consumed a valid duplicate identity")
        }
    }

    static func speedComposesAcrossCutsAndBoundaries() throws {
        let speedID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            editDecisions: [EditDecision(start: 4, end: 6)],
            speedSegments: [SpeedSegment(id: speedID, start: 2, end: 8, rate: 2)]
        )

        guard mapper.slices.count == 4,
              mapper.slices[1].speedSegmentID == speedID,
              mapper.slices.allSatisfy({ slice in
                  stride(from: slice.sourceStart, to: slice.sourceEnd, by: 0.01).allSatisfy {
                      mapper.isIncluded(sourceTime: $0)
                  }
              })
        else {
            throw OpenRecordError.io("Speed/cut slices crossed an excluded boundary")
        }
        try expectClose(mapper.outputDuration, 6, "speed-plus-cut output duration")
        try expectClose(mapper.slices[1].rate, 2, "speed slice rate")
        try expectClose(mapper.sourceTime(atOutputTime: 3), 6, "speed/cut output boundary")
        try expectClose(
            try require(mapper.outputTime(forSourceTime: 3), "included fast source"),
            2.5,
            "included fast source output"
        )
        guard mapper.outputTime(forSourceTime: 5) == nil else {
            throw OpenRecordError.io("Cut interior mapped through a speed region")
        }
        try expectClose(
            try require(mapper.outputTime(forSourceTime: 6), "included source after cut"),
            3,
            "post-cut speed output"
        )
    }

    static func excludedSourceBoundariesAreHalfOpen() throws {
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 1,
            trimOut: 9,
            editDecisions: [
                EditDecision(start: 1, end: 2),
                EditDecision(start: 4, end: 6),
                EditDecision(start: 8, end: 10),
            ]
        )

        guard mapper.outputTime(forSourceTime: 1) == nil,
              mapper.outputTime(forSourceTime: 4) == nil,
              mapper.outputTime(forSourceTime: 5.999) == nil,
              mapper.outputTime(forSourceTime: 8) == mapper.outputDuration,
              mapper.outputTime(forSourceTime: 9) == nil,
              !mapper.isIncluded(sourceTime: 4),
              mapper.isIncluded(sourceTime: 6)
        else {
            throw OpenRecordError.io("Cut ranges are not half-open at their source boundaries")
        }
        try expectClose(mapper.sourceTime(atOutputTime: 0), 2, "cut at trim start")
        try expectClose(mapper.sourceTime(atOutputTime: 2), 6, "internal cut boundary")
        try expectClose(mapper.sourceTime(atOutputTime: 4), 8, "cut at trim end")
        try expectClose(mapper.clampedOutputTime(forSourceTime: 1), 0, "clamped trim-start cut")
        try expectClose(mapper.clampedOutputTime(forSourceTime: 4), 2, "clamped internal cut")
        try expectClose(mapper.clampedOutputTime(forSourceTime: 8.5), 4, "clamped trim-end cut")

        let fullyExcluded = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 2,
            trimOut: 8,
            editDecisions: [EditDecision(start: 0, end: 10)]
        )
        guard fullyExcluded.slices.isEmpty else {
            throw OpenRecordError.io("A fully excluded trim unexpectedly retained a slice")
        }
        try expectClose(fullyExcluded.outputDuration, 0, "fully excluded output duration")

        let shortTrimAndCut = ProjectTimeMapper(
            sourceDuration: 1,
            trimIn: 0,
            trimOut: 0.05,
            editDecisions: [EditDecision(start: 0.01, end: 0.02)]
        )
        try expectClose(shortTrimAndCut.sourceEnd, 0.05, "short trim endpoint")
        try expectClose(shortTrimAndCut.outputDuration, 0.04, "short trim and cut duration")
    }

    static func previewAndExportFixtureStaysDeterministic() throws {
        let document = ProjectDocument(
            trimIn: 1,
            trimOut: 11,
            speedSegments: [SpeedSegment(start: 5, end: 10, rate: 0.5)],
            editDecisions: [EditDecision(start: 3, end: 5), EditDecision(start: 8, end: 9)]
        )
        let preview = ProjectTimeMapper(project: document, sourceDuration: 12)
        let export = ProjectTimeMapper(project: document, sourceDuration: 12)
        let expected: [(output: TimeInterval, source: TimeInterval)] = [
            (0, 1),
            (2, 5),
            (4, 6),
            (8, 9),
            (11, 11),
        ]

        for point in expected {
            let previewSource = preview.sourceTime(atOutputTime: point.output)
            let exportSource = export.sourceTime(atOutputTime: point.output)
            try expectClose(previewSource, point.source, "preview fixture at \(point.output)")
            try expectClose(exportSource, point.source, "export fixture at \(point.output)")
            guard point.source == preview.sourceEnd
                    || preview.isIncluded(sourceTime: point.source)
            else {
                throw OpenRecordError.io("Fixture mapped output into an excluded source range")
            }
        }
        try expectClose(preview.outputDuration, 11, "deterministic fixture duration")
        try expectClose(export.outputDuration, 11, "export fixture duration")
    }

    static func audioPlacementsFollowTheAuthoritativeSlices() throws {
        let mapper = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 1,
            trimOut: 9,
            editDecisions: [
                EditDecision(start: 2, end: 3),
                EditDecision(start: 3, end: 4),
                EditDecision(start: 6, end: 7),
            ],
            speedSegments: [SpeedSegment(start: 4, end: 6, rate: 2)]
        )
        let placements = ExportAudioMux.placements(
            timeMapper: mapper,
            sourceOffset: 1.5,
            sourceTimelineDuration: 7,
            sourceMediaDuration: 7
        )
        guard placements.count == 3 else {
            throw OpenRecordError.io("Audio placement did not preserve all retained intersections")
        }
        let expected: [(local: Double, localDuration: Double, output: Double, outputDuration: Double, rate: Double)] = [
            (0, 0.5, 0.5, 0.5, 1),
            (2.5, 2, 1, 1, 2),
            (5.5, 1.5, 2, 1.5, 1),
        ]
        for (placement, expected) in zip(placements, expected) {
            try expectClose(placement.localSourceStart, expected.local, "audio local start")
            try expectClose(
                placement.localSourceDuration,
                expected.localDuration,
                "audio local duration"
            )
            try expectClose(placement.outputStart, expected.output, "audio output start")
            try expectClose(
                placement.outputDuration,
                expected.outputDuration,
                "audio output duration"
            )
            try expectClose(placement.rate, expected.rate, "audio placement rate")
        }

        let mutedFastPlacements = ExportAudioMux.placements(
            timeMapper: mapper,
            sourceOffset: 1.5,
            sourceTimelineDuration: 7,
            sourceMediaDuration: 7,
            muteAudioWhenSpedUp: true
        )
        guard mutedFastPlacements.count == 2,
              mutedFastPlacements.allSatisfy({ $0.rate <= 1.000_001 })
        else {
            throw OpenRecordError.io("Mute-when-sped-up retained a fast audio placement")
        }
    }

    private static func expectClose(
        _ lhs: Double,
        _ rhs: Double,
        _ label: String,
        tolerance: Double = 0.000_001
    ) throws {
        guard abs(lhs - rhs) <= tolerance else {
            throw OpenRecordError.io("\(label): got \(lhs), expected \(rhs)")
        }
    }

    private static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else {
            throw OpenRecordError.io("\(label): unexpectedly nil")
        }
        return value
    }
}

@Test
func editDecisionMappingHasLegacyIdentityAndEndpointSemantics() throws {
    try EditDecisionMappingSuite.legacyIdentityAndEndpointSemantics()
}

@Test
func editDecisionMappingRipplesAdjacentAndMultipleCuts() throws {
    try EditDecisionMappingSuite.adjacentAndMultipleCutsRipple()
}

@Test
func editDecisionMappingNormalizesMalformedRangesAndTrim() throws {
    try EditDecisionMappingSuite.malformedRangesNormalizeWithTrim()
}

@Test
func editDecisionMappingComposesSpeedAcrossCutsAndBoundaries() throws {
    try EditDecisionMappingSuite.speedComposesAcrossCutsAndBoundaries()
}

@Test
func editDecisionMappingUsesHalfOpenCutBoundaries() throws {
    try EditDecisionMappingSuite.excludedSourceBoundariesAreHalfOpen()
}

@Test
func editDecisionAudioPlacementsUseAuthoritativeSlices() throws {
    try EditDecisionMappingSuite.audioPlacementsFollowTheAuthoritativeSlices()
}

@Test
func editDecisionMappingPreviewAndExportFixtureStayDeterministic() throws {
    try EditDecisionMappingSuite.previewAndExportFixtureStaysDeterministic()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordEditDecisionMappingTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunEditDecisionMappingTests()
}

@_cdecl("OpenRecordRunEditDecisionMappingTests")
func OpenRecordRunEditDecisionMappingTests() {
    do {
        try EditDecisionMappingSuite.run()
        fputs(
            "OpenRecordTests: EditDecisionMappingTests files=1 tests=\(EditDecisionMappingSuite.testCount) failures=0\n",
            stderr
        )
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: EditDecisionMappingTests files=1 tests=\(EditDecisionMappingSuite.testCount) failures=1 error=\(error)\n",
            stderr
        )
        abort()
    }
}
#endif
