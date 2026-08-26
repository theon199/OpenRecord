import Foundation
import Testing
import OpenRecord

/// Deterministic timing-contract coverage shared by preview and export.
///
/// These tests intentionally exercise the value-only timeline APIs. They do
/// not open media files, so frame timestamps remain stable on every CI host.
enum SpeedMappingSuite {
    static func run() throws {
        try trimBoundariesRoundTripThroughAdjacentSpeedSegments()
        try exactAdjacentSegmentBoundariesAreHalfOpen()
        try captionsAndAnnotationsUseHalfOpenIntervals()
        try authoredTracksStaySynchronizedAcrossCutsAndSpeedChanges()
        try webcamTimelineHonorsLegacyOffsetAndDiagnosticCorrections()
        try cursorTimingHonorsFirstAndHiddenBoundaries()
    }

    static func trimBoundariesRoundTripThroughAdjacentSpeedSegments() throws {
        let fastID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let slowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let timeline = SpeedTimeline(segments: [
            SpeedSegment(id: fastID, start: 0, end: 3, rate: 2),
            SpeedSegment(id: slowID, start: 5, end: 8, rate: 0.5),
        ])

        // The trim [2, 7) produces 0.5 s of 2×, 2 s of 1×, and
        // 4 s of 0.5× playback: 6.5 s in total.
        let sourceStart = 2.0
        let sourceEnd = 7.0
        try expectClose(
            timeline.outputDuration(sourceStart: sourceStart, sourceEnd: sourceEnd),
            6.5,
            "trimmed output duration"
        )

        let sourceBoundaries: [TimeInterval] = [2, 3, 5, 7]
        for source in sourceBoundaries {
            let output = timeline.outputTime(
                forSourceTime: source,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            )
            let roundTrip = timeline.sourceTime(
                atOutputTime: output,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            )
            try expectClose(roundTrip, source, "trim source/output round trip at \(source)")
        }

        // Clamping at both trim edges is part of the shared mapping contract.
        try expectClose(
            timeline.sourceTime(
                atOutputTime: -1,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            ),
            sourceStart,
            "output before trim"
        )
        try expectClose(
            timeline.sourceTime(
                atOutputTime: 99,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            ),
            sourceEnd,
            "output after trim"
        )
        try expectClose(
            timeline.outputTime(
                forSourceTime: -1,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            ),
            0,
            "source before trim"
        )
        try expectClose(
            timeline.outputTime(
                forSourceTime: 99,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            ),
            6.5,
            "source after trim"
        )
    }

    static func exactAdjacentSegmentBoundariesAreHalfOpen() throws {
        let firstID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let secondID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let timeline = SpeedTimeline(segments: [
            SpeedSegment(id: firstID, start: 1, end: 3, rate: 2),
            SpeedSegment(id: secondID, start: 3, end: 5, rate: 0.5),
        ])

        // Segment lookup is [start, end), so the shared edge belongs to the
        // second segment while both mappings still meet at the same instant.
        try expectClose(timeline.rate(at: 2.999_999), 2, "rate before shared edge")
        try expectClose(timeline.rate(at: 3), 0.5, "rate at shared edge")
        try expectClose(timeline.rate(at: 5), 1, "rate at second segment end")

        let expectedOutput: [(source: Double, output: Double)] = [
            (0, 0),
            (1, 1),
            (3, 2),
            (5, 6),
            (6, 7),
        ]
        for point in expectedOutput {
            let output = timeline.outputTime(
                forSourceTime: point.source,
                sourceStart: 0,
                sourceEnd: 6
            )
            try expectClose(output, point.output, "output boundary at source \(point.source)")
            let source = timeline.sourceTime(
                atOutputTime: point.output,
                sourceStart: 0,
                sourceEnd: 6
            )
            try expectClose(source, point.source, "source boundary at output \(point.output)")
        }
    }

    static func captionsAndAnnotationsUseHalfOpenIntervals() throws {
        let caption = CaptionCue(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            start: 1,
            end: 2,
            text: "timing"
        )
        let annotation = Annotation(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            start: 1,
            end: 2,
            kind: .arrow
        )

        for time in [1.0, 1.999_999] {
            guard caption.isActive(at: time), annotation.isActive(at: time) else {
                throw OpenRecordError.io("caption/annotation unexpectedly inactive at \(time)")
            }
        }
        for time in [0.999_999, 2.0, 2.000_001] {
            guard !caption.isActive(at: time), !annotation.isActive(at: time) else {
                throw OpenRecordError.io("caption/annotation unexpectedly active at \(time)")
            }
        }
    }

    static func authoredTracksStaySynchronizedAcrossCutsAndSpeedChanges() throws {
        let decisions = [
            EditDecision(start: 2, end: 4),
            EditDecision(start: 7, end: 8),
        ]
        let speeds = [
            SpeedSegment(start: 4, end: 6, rate: 2),
            SpeedSegment(start: 8, end: 10, rate: 0.5),
        ]
        // Preview and export construct the same value mapper independently;
        // this fixture pins their shared source timestamp contract.
        let preview = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 0,
            trimOut: 10,
            editDecisions: decisions,
            speedSegments: speeds
        )
        let export = ProjectTimeMapper(
            sourceDuration: 10,
            trimIn: 0,
            trimOut: 10,
            editDecisions: decisions,
            speedSegments: speeds
        )
        let expected: [(output: TimeInterval, source: TimeInterval)] = [
            (0, 0),
            (1.5, 1.5),
            (2, 4),       // exact cut boundary jumps to the next retained frame
            (2.25, 4.5),  // inside the 2x source region
            (3, 6),
            (4, 8),       // second cut boundary
            (5, 8.5),     // inside the 0.5x source region
            (8, 10),
        ]

        let caption = CaptionCue(start: 4, end: 6, text: "caption")
        let annotation = Annotation.arrow(start: 8, end: 10)
        let keyboardSettings = KeyboardOverlaySettings(enabled: true, fadeDelay: 1)
        let keyboard = KeyboardOverlayTimeline(samples: [
            KeySample(t: 4.25, key: "K", modifiers: [.command], down: true),
        ])
        let engine = ZoomEngine(
            document: ProjectDocument(
                trimOut: 10,
                zoomRanges: [
                    ZoomRange(
                        start: 4,
                        end: 6,
                        amount: 1.8,
                        anchor: Point2D(x: 0.5, y: 0.5)
                    )
                ]
            ),
            samples: [
                CursorSample(t: 0, x: 100, y: 100, visible: true),
                CursorSample(t: 2, x: 200, y: 200, visible: true),
                CursorSample(t: 4, x: 400, y: 400, visible: true),
                CursorSample(t: 6, x: 600, y: 600, visible: true),
                CursorSample(t: 8, x: 800, y: 800, visible: true),
                CursorSample(t: 10, x: 900, y: 900, visible: true),
            ],
            clicks: [
                ClickSample(t: 4.25, button: .left, down: true),
                ClickSample(t: 5.25, button: .left, down: false),
            ],
            displayBounds: Rect2D(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        for point in expected {
            let previewSource = preview.sourceTime(atOutputTime: point.output)
            let exportSource = export.sourceTime(atOutputTime: point.output)
            try expectClose(previewSource, point.source, "preview source at \(point.output)")
            try expectClose(exportSource, point.source, "export source at \(point.output)")
            guard caption.isActive(at: previewSource) == caption.isActive(at: exportSource),
                  annotation.isActive(at: previewSource) == annotation.isActive(at: exportSource),
                  keyboard.state(at: previewSource, settings: keyboardSettings)
                    == keyboard.state(at: exportSource, settings: keyboardSettings),
                  engine.interpolateCursor(at: previewSource)
                    == engine.interpolateCursor(at: exportSource),
                  engine.isClicking(at: previewSource) == engine.isClicking(at: exportSource),
                  WebcamTimeline.sourceTime(
                    atTimelineTime: previewSource,
                    sourceDuration: 9.5,
                    legacyOffset: 0.5
                  ) == WebcamTimeline.sourceTime(
                    atTimelineTime: exportSource,
                    sourceDuration: 9.5,
                    legacyOffset: 0.5
                  )
            else {
                throw OpenRecordError.io(
                    "preview/export track state diverged at output \(point.output)"
                )
            }
        }

        guard preview.outputDuration == 8,
              caption.isActive(at: preview.sourceTime(atOutputTime: 2)),
              !caption.isActive(at: preview.sourceTime(atOutputTime: 3)),
              annotation.isActive(at: preview.sourceTime(atOutputTime: 4)),
              keyboard.state(at: preview.sourceTime(atOutputTime: 2.25), settings: keyboardSettings)
                .isVisible,
              engine.isClicking(at: preview.sourceTime(atOutputTime: 2.25))
        else {
            throw OpenRecordError.io("mapped authored-track fixture produced the wrong state")
        }
    }

    static func webcamTimelineHonorsLegacyOffsetAndDiagnosticCorrections() throws {
        // Legacy projects have only a first-frame offset. The endpoint is
        // inclusive because it denotes the last usable source frame.
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 0.5,
                sourceDuration: 4,
                legacyOffset: 0.5
            ),
            0,
            "legacy webcam first frame"
        )
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 4.5,
                sourceDuration: 4,
                legacyOffset: 0.5
            ),
            4,
            "legacy webcam last frame"
        )
        try expectNil(
            WebcamTimeline.sourceTime(
                atTimelineTime: 0.499_999,
                sourceDuration: 4,
                legacyOffset: 0.5
            ),
            "legacy webcam before first frame"
        )
        try expectNil(
            WebcamTimeline.sourceTime(
                atTimelineTime: 4.500_001,
                sourceDuration: 4,
                legacyOffset: 0.5
            ),
            "legacy webcam after last frame"
        )
        try expectNil(
            WebcamTimeline.sourceTime(
                atTimelineTime: 1,
                sourceDuration: 4,
                legacyOffset: .nan
            ),
            "legacy webcam non-finite offset"
        )

        let unavailable = CaptureDiagnostics(
            referenceDuration: 4,
            driftTolerance: 0.05,
            tracks: [
                CaptureTrackDiagnostic(track: .webcam, status: .missing),
            ]
        )
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 0.5,
                sourceDuration: 4,
                legacyOffset: 0.5,
                diagnostics: unavailable
            ),
            0,
            "unavailable diagnostic uses legacy offset"
        )

        let corrected = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 10,
            observations: [
                CaptureTrackObservation(
                    track: .displayVideo,
                    duration: 10
                ),
                CaptureTrackObservation(
                    track: .webcam,
                    duration: 11,
                    initialOffset: 0.5
                ),
            ]
        )
        guard let correction = corrected.correction(for: .webcam) else {
            throw OpenRecordError.io("late complete webcam should receive a drift correction")
        }
        try expectClose(correction.sourceDuration, 11, "webcam corrected source duration")
        try expectClose(correction.timelineDuration, 9.5, "webcam corrected timeline duration")
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 0.5,
                sourceDuration: 11,
                diagnostics: corrected
            ),
            0,
            "corrected webcam first frame"
        )
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 5.25,
                sourceDuration: 11,
                diagnostics: corrected
            ),
            5.5,
            "corrected webcam midpoint"
        )
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 10,
                sourceDuration: 11,
                diagnostics: corrected
            ),
            11,
            "corrected webcam last frame"
        )
        try expectNil(
            WebcamTimeline.sourceTime(
                atTimelineTime: 10.000_001,
                sourceDuration: 11,
                diagnostics: corrected
            ),
            "corrected webcam after timeline end"
        )

        let truncated = CaptureDiagnosticsAnalyzer.analyze(
            referenceDuration: 10,
            observations: [
                CaptureTrackObservation(
                    track: .displayVideo,
                    duration: 10
                ),
                CaptureTrackObservation(
                    track: .webcam,
                    duration: 11,
                    initialOffset: 0.5,
                    truncated: true
                ),
            ]
        )
        guard truncated.diagnostic(for: .webcam)?.status == .truncated,
              truncated.correction(for: .webcam) == nil
        else {
            throw OpenRecordError.io("truncated webcam unexpectedly received a correction")
        }
        try expectOptionalClose(
            WebcamTimeline.sourceTime(
                atTimelineTime: 11.5,
                sourceDuration: 11,
                diagnostics: truncated
            ),
            11,
            "truncated webcam source end"
        )
        try expectNil(
            WebcamTimeline.sourceTime(
                atTimelineTime: 11.500_001,
                sourceDuration: 11,
                diagnostics: truncated
            ),
            "truncated webcam after source end"
        )
    }

    static func cursorTimingHonorsFirstAndHiddenBoundaries() throws {
        let bounds = Rect2D(x: 0, y: 0, width: 1000, height: 1000)
        let engine = ZoomEngine(
            document: ProjectDocument(),
            samples: [
                CursorSample(t: 1, x: 100, y: 200, visible: true),
                CursorSample(t: 2, x: 800, y: 700, visible: true),
                CursorSample(t: 3, x: 800, y: 700, visible: false),
                CursorSample(t: 4, x: 300, y: 400, visible: true),
            ],
            clicks: [
                ClickSample(t: 1.25, button: .left, down: true),
                ClickSample(t: 2.25, button: .left, down: false),
            ],
            displayBounds: bounds
        )

        guard engine.interpolateCursor(at: 0.999_999) == nil,
              engine.cursorVelocity(at: 0.999_999) == nil,
              engine.interpolateCursor(at: 1) != nil,
              engine.cursorVelocity(at: 1.5) != nil,
              engine.interpolateCursor(at: 1.5) != nil
        else {
            throw OpenRecordError.io("cursor interpolation did not start at the first visible sample")
        }

        guard engine.isClicking(at: 1.5), !engine.isClicking(at: 2.5) else {
            throw OpenRecordError.io("cursor click state did not follow down/up timing")
        }
        guard engine.interpolateCursor(at: 3) == nil,
              engine.cursorVelocity(at: 3) == nil,
              !engine.isClicking(at: 3),
              engine.interpolateCursor(at: 4) != nil,
              engine.cursorVelocity(at: 4) != nil
        else {
            throw OpenRecordError.io("cursor hidden/visible boundary was not honored")
        }
    }

    private static func expectClose(
        _ got: Double,
        _ expected: Double,
        _ label: String,
        tolerance: Double = 1e-9
    ) throws {
        guard abs(got - expected) <= tolerance else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }

    private static func expectOptionalClose(
        _ got: TimeInterval?,
        _ expected: TimeInterval,
        _ label: String
    ) throws {
        guard let got else {
            throw OpenRecordError.io("\(label): got nil, expected \(expected)")
        }
        try expectClose(got, expected, label)
    }

    private static func expectNil(_ got: TimeInterval?, _ label: String) throws {
        guard got == nil else {
            throw OpenRecordError.io("\(label): got \(String(describing: got)), expected nil")
        }
    }
}

@Test
func speedTrimBoundariesRoundTrip() throws {
    try SpeedMappingSuite.trimBoundariesRoundTripThroughAdjacentSpeedSegments()
}

@Test
func speedAdjacentSegmentBoundariesAreHalfOpen() throws {
    try SpeedMappingSuite.exactAdjacentSegmentBoundariesAreHalfOpen()
}

@Test
func captionAndAnnotationIntervalsAreHalfOpen() throws {
    try SpeedMappingSuite.captionsAndAnnotationsUseHalfOpenIntervals()
}

@Test
func authoredTracksStaySynchronizedAcrossCutsAndSpeedChanges() throws {
    try SpeedMappingSuite.authoredTracksStaySynchronizedAcrossCutsAndSpeedChanges()
}

@Test
func webcamTimelineMapsLegacyAndDiagnosticTiming() throws {
    try SpeedMappingSuite.webcamTimelineHonorsLegacyOffsetAndDiagnosticCorrections()
}

@Test
func cursorTimingHonorsFirstAndHiddenBoundaries() throws {
    try SpeedMappingSuite.cursorTimingHonorsFirstAndHiddenBoundaries()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordSpeedMappingTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunSpeedMappingTests()
}

@_cdecl("OpenRecordRunSpeedMappingTests")
func OpenRecordRunSpeedMappingTests() {
    do {
        try SpeedMappingSuite.run()
        fputs("OpenRecordTests: Speed mapping tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: Speed mapping tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
