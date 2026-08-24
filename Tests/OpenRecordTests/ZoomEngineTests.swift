import CoreGraphics
import Darwin
import Foundation
import Testing
import OpenRecord

enum ZoomEngineSuite {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let bounds = Rect2D(x: 0, y: 0, width: 1920, height: 1080)

    static func run() throws {
        try cropWithNoZoomsIsUnitRect()
        try cropMidZoomIsSmallerAndNearAnchor()
        try autoZoomSegmentsAroundActivityNotPauses()
        try springAndCropAreDeterministic()
        try nearbyClicksStayInOneZoomedRange()
        try isolatedClickIslandHoldsMinZoom()
        try longPauseZoomsOutAndIsSilence()
        try movementIslandOpensNearStartCursor()
        try sensitivityPresetsProduceIncreasingActivity()
        try easingPresetsProduceOrderedMotion()
    }

    static func cropWithNoZoomsIsUnitRect() throws {
        let engine = ZoomEngine(document: ProjectDocument())
        try expectRect(engine.crop(at: 0), unit, "crop at 0 with no zooms")
        try expectRect(engine.crop(at: 5), unit, "crop at 5 with no zooms")
        try expectRect(engine.crop(at: 100), unit, "crop at 100 with no zooms")
    }

    static func cropMidZoomIsSmallerAndNearAnchor() throws {
        let anchor = Point2D(x: 0.5, y: 0.25)
        let zoom = ZoomRange(start: 1, end: 4, amount: 2, anchor: anchor)
        let engine = ZoomEngine(document: ProjectDocument(zoomRanges: [zoom]))
        let crop = engine.crop(at: 2.5)

        guard crop.width < 1, crop.height < 1 else {
            throw OpenRecordError.io(
                "mid-zoom crop should be smaller than 1×1, got \(crop)"
            )
        }
        guard abs(crop.width - 0.5) < 0.05, abs(crop.height - 0.5) < 0.05 else {
            throw OpenRecordError.io(
                "2× zoom should settle near 0.5×0.5 UV, got \(crop)"
            )
        }

        let cx = crop.midX
        let cy = crop.midY
        guard abs(cx - 0.5) < 0.08 else {
            throw OpenRecordError.io("crop midX \(cx) should be near anchor x 0.5")
        }
        guard abs(cy - 0.25) < 0.08 else {
            throw OpenRecordError.io("crop midY \(cy) should be near anchor y 0.25")
        }

        let before = engine.crop(at: 0)
        try expectRect(before, unit, "before zoom-in, crop should be unit")
    }

    static func autoZoomSegmentsAroundActivityNotPauses() throws {
        let (samples, clicks) = activityFixture()
        let duration: TimeInterval = 8
        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: duration,
            displayBounds: bounds
        )

        guard !zooms.isEmpty else {
            throw OpenRecordError.io("auto-zoom should produce at least one segment")
        }

        let clickTime: TimeInterval = 2.8
        guard zooms.contains(where: { $0.start <= clickTime && $0.end >= clickTime }) else {
            throw OpenRecordError.io(
                "auto-zoom should cover the click/activity at t=2.8, got \(describe(zooms))"
            )
        }

        let pauseTimes: [TimeInterval] = [0.8, 4.5]
        for pause in pauseTimes {
            if zooms.contains(where: { $0.start <= pause && $0.end >= pause }) {
                throw OpenRecordError.io(
                    "auto-zoom should not cover pause at t=\(pause), got \(describe(zooms))"
                )
            }
        }

        let silences = ZoomEngine.detectSilenceZones(
            samples: samples,
            clicks: clicks,
            duration: duration
        )
        guard silences.contains(where: { $0.start <= 0.8 && $0.end >= 0.8 }) else {
            throw OpenRecordError.io("expected silence around t=0.8, got \(silences)")
        }
        // The fixture's 2.3s still (3.2–5.5) stays uncovered at t=4.5 above. Click
        // padding can shrink that idle below minSilence, so 4.5 may not be a
        // SilenceZone even though it is not inside a zoom range.
    }

    static func springAndCropAreDeterministic() throws {
        let a = SpringSolver.solve1D(
            displacement: 0.4,
            velocity: 0.1,
            time: 0.25,
            omega0: SpringConfig.zoomTransition.omega0,
            zeta: SpringConfig.zoomTransition.zeta
        )
        let b = SpringSolver.solve1D(
            displacement: 0.4,
            velocity: 0.1,
            time: 0.25,
            omega0: SpringConfig.zoomTransition.omega0,
            zeta: SpringConfig.zoomTransition.zeta
        )
        guard a.displacement == b.displacement, a.velocity == b.velocity else {
            throw OpenRecordError.io("analytical spring solve is not bit-stable")
        }

        let (samples, clicks) = activityFixture()
        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: 8,
            displayBounds: bounds
        )
        var document = ProjectDocument(trimOut: 8, zoomRanges: zooms)
        if document.zoomRanges.isEmpty {
            document.zoomRanges = [
                ZoomRange(start: 2, end: 3.2, amount: 1.5, anchor: Point2D(x: 0.5, y: 0.25))
            ]
        }

        let engineA = ZoomEngine(
            document: document,
            samples: samples,
            clicks: clicks,
            displayBounds: bounds
        )
        let engineB = ZoomEngine(
            document: document,
            samples: samples,
            clicks: clicks,
            displayBounds: bounds
        )

        let times: [TimeInterval] = [0, 0.4, 1.2, 2.5, 2.8, 4.0, 6.0, 7.5]
        for time in times {
            try expectRect(
                engineA.crop(at: time),
                engineB.crop(at: time),
                "two engines at t=\(time)"
            )
        }

        let later = engineA.crop(at: 3.1)
        _ = engineA.crop(at: 0.05)
        _ = engineA.crop(at: 6.7)
        try expectRect(engineA.crop(at: 3.1), later, "crop(at:) must not depend on call order")

        let noSamples = ZoomEngine(document: document)
        try expectRect(noSamples.crop(at: 2.6), noSamples.crop(at: 2.6), "live crop twice")

        if engineA.interpolateCursor(at: 2.8) == nil {
            throw OpenRecordError.io("interpolateCursor should return a UV point when samples exist")
        }
        let p1 = engineA.interpolateCursor(at: 2.5)
        let p2 = engineA.interpolateCursor(at: 2.5)
        guard let p1, let p2, p1 == p2 else {
            throw OpenRecordError.io("cursor interpolation is not deterministic")
        }
    }

    /// Two clicks ~0.8s apart should merge into one island (mergeGap 1.4s), and
    /// the crop between them must never return the unit rect.
    static func nearbyClicksStayInOneZoomedRange() throws {
        let duration: TimeInterval = 6
        let samples = hold(x: 960, y: 540, from: 0, to: duration)
        let clicks = [
            ClickSample(t: 1.0, button: .left, down: true),
            ClickSample(t: 1.05, button: .left, down: false),
            ClickSample(t: 1.8, button: .left, down: true),
            ClickSample(t: 1.85, button: .left, down: false),
        ]
        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: duration,
            displayBounds: bounds
        )
        guard zooms.count == 1 else {
            throw OpenRecordError.io(
                "clicks 0.8s apart should merge into one range, got \(describe(zooms))"
            )
        }
        guard zooms[0].start <= 1.0, zooms[0].end >= 1.8 else {
            throw OpenRecordError.io(
                "merged range should cover both clicks, got \(describe(zooms))"
            )
        }

        let engine = ZoomEngine(
            document: ProjectDocument(trimOut: duration, zoomRanges: zooms),
            samples: samples,
            clicks: clicks,
            displayBounds: bounds
        )
        let between: [TimeInterval] = [1.1, 1.4, 1.7]
        for time in between {
            let crop = engine.crop(at: time)
            if isNearlyUnit(crop) {
                throw OpenRecordError.io(
                    "crop between nearby clicks at t=\(time) should stay zoomed, got \(crop)"
                )
            }
        }
    }

    /// A lone click island is expanded to at least `minZoomHold`.
    static func isolatedClickIslandHoldsMinZoom() throws {
        let duration: TimeInterval = 6
        let samples = hold(x: 960, y: 540, from: 0, to: duration)
        let clicks = [
            ClickSample(t: 2.0, button: .left, down: true),
            ClickSample(t: 2.05, button: .left, down: false),
        ]
        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: clicks,
            duration: duration,
            displayBounds: bounds
        )
        guard zooms.count == 1 else {
            throw OpenRecordError.io(
                "isolated click should produce one range, got \(describe(zooms))"
            )
        }
        let hold = AutoZoomConfig.default.minZoomHold
        let span = zooms[0].end - zooms[0].start
        guard span + 1e-9 >= hold else {
            throw OpenRecordError.io(
                "isolated click island duration \(span) should be ≥ minZoomHold \(hold)"
            )
        }
        guard zooms[0].start <= 2.0, zooms[0].end > 2.0 else {
            throw OpenRecordError.io(
                "isolated click island should cover the click, got \(describe(zooms))"
            )
        }
    }

    /// A ~2.3s pause (same length as the activityFixture still at 3.2–5.5) between
    /// two already-long islands is silence and eases out to the unit crop.
    static func longPauseZoomsOutAndIsSilence() throws {
        let duration: TimeInterval = 8.5
        var samples: [CursorSample] = []
        samples += hold(x: 400, y: 300, from: 0, to: 0.5)
        samples += move(
            from: Point2D(x: 400, y: 300),
            to: Point2D(x: 900, y: 400),
            start: 0.5,
            end: 2.6
        )
        samples += hold(x: 900, y: 400, from: 2.6, to: 4.9)
        samples += move(
            from: Point2D(x: 900, y: 400),
            to: Point2D(x: 1400, y: 700),
            start: 4.9,
            end: 7.0
        )
        samples += hold(x: 1400, y: 700, from: 7.0, to: duration)

        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: [],
            duration: duration,
            displayBounds: bounds
        )
        let pause: TimeInterval = 3.7
        if zooms.contains(where: { $0.start <= pause && $0.end >= pause }) {
            throw OpenRecordError.io(
                "2.3s pause at t=\(pause) should not be inside a zoom range, got \(describe(zooms))"
            )
        }
        guard zooms.count >= 2 else {
            throw OpenRecordError.io(
                "expected two islands around a 2.3s pause, got \(describe(zooms))"
            )
        }

        let silences = ZoomEngine.detectSilenceZones(
            samples: samples,
            clicks: [],
            duration: duration
        )
        guard silences.contains(where: { $0.start <= pause && $0.end >= pause }) else {
            throw OpenRecordError.io("expected silence around t=\(pause), got \(silences)")
        }

        let engine = ZoomEngine(
            document: ProjectDocument(trimOut: duration, zoomRanges: zooms),
            samples: samples,
            displayBounds: bounds
        )
        let firstEnd = zooms[0].end
        let settled = firstEnd + ZoomEngine.zoomOutDuration + 0.05
        guard settled < zooms[1].start else {
            throw OpenRecordError.io(
                "zoom-out from \(firstEnd) should finish before the next island \(zooms[1].start)"
            )
        }
        let crop = engine.crop(at: settled)
        guard isNearlyUnit(crop, eps: 0.02) else {
            throw OpenRecordError.io(
                "after a 2.3s pause, crop should ease out to unit, got \(crop)"
            )
        }
    }

    /// Movement islands anchor (and open) on the start cursor, not the path centroid.
    static func movementIslandOpensNearStartCursor() throws {
        let duration: TimeInterval = 8
        let startPt = Point2D(x: 768, y: 324)
        let endPt = Point2D(x: 1536, y: 918)
        var samples: [CursorSample] = []
        samples += hold(x: startPt.x, y: startPt.y, from: 0, to: 1.0)
        samples += move(from: startPt, to: endPt, start: 1.0, end: 6.0)
        samples += hold(x: endPt.x, y: endPt.y, from: 6.0, to: duration)

        let zooms = ZoomEngine.generateAutoZooms(
            samples: samples,
            clicks: [],
            duration: duration,
            displayBounds: bounds
        )
        guard let island = zooms.first(where: { $0.start <= 1.0 && $0.end > 1.0 }) ?? zooms.first else {
            throw OpenRecordError.io("expected a movement island, got \(describe(zooms))")
        }

        let startUV = CursorSmoother.uv(x: startPt.x, y: startPt.y, displayBounds: bounds)
        let endUV = CursorSmoother.uv(x: endPt.x, y: endPt.y, displayBounds: bounds)
        let centroid = Point2D(x: (startUV.x + endUV.x) / 2, y: (startUV.y + endUV.y) / 2)

        let dAnchorStart = hypot(island.anchor.x - startUV.x, island.anchor.y - startUV.y)
        let dAnchorCentroid = hypot(island.anchor.x - centroid.x, island.anchor.y - centroid.y)
        guard dAnchorStart + 0.02 < dAnchorCentroid else {
            throw OpenRecordError.io(
                "island anchor \(island.anchor) should be nearer start \(startUV) than centroid \(centroid)"
            )
        }

        // Live crop (no sequential follow-cam) so the opening frame uses the range anchor.
        let engine = ZoomEngine(
            document: ProjectDocument(trimOut: duration, zoomRanges: zooms)
        )
        let opening = engine.crop(at: island.start + ZoomEngine.zoomInDuration)
        if isNearlyUnit(opening) {
            throw OpenRecordError.io("opening crop should be zoomed, got \(opening)")
        }
        let cropCenter = Point2D(x: Double(opening.midX), y: Double(opening.midY))
        let dCropStart = hypot(cropCenter.x - startUV.x, cropCenter.y - startUV.y)
        let dCropCentroid = hypot(cropCenter.x - centroid.x, cropCenter.y - centroid.y)
        guard dCropStart + 0.05 < dCropCentroid else {
            throw OpenRecordError.io(
                "opening crop center \(cropCenter) should be nearer start \(startUV) than centroid \(centroid)"
            )
        }
    }

    static func sensitivityPresetsProduceIncreasingActivity() throws {
        let duration: TimeInterval = 12
        let samples = sensitivityFixture(duration: duration)
        let presets: [AutoZoomSensitivity] = [.subtle, .normal, .aggressive]
        let ranges = presets.map { preset in
            ZoomEngine.generateAutoZooms(
                samples: samples,
                duration: duration,
                displayBounds: bounds,
                config: preset.config
            )
        }
        let counts = ranges.map(\.count)
        guard counts == [1, 2, 3] else {
            throw OpenRecordError.io(
                "sensitivity presets should detect 1/2/3 movement islands, got \(counts)"
            )
        }
        let amounts = ranges.compactMap { $0.first?.amount }
        guard amounts == [1.35, 1.5, 1.7] else {
            throw OpenRecordError.io(
                "sensitivity presets should apply subtle/normal/aggressive zoom amounts, got \(amounts)"
            )
        }
    }

    static func easingPresetsProduceOrderedMotion() throws {
        let zoom = ZoomRange(
            start: 1,
            end: 4,
            amount: 2,
            anchor: Point2D(x: 0.5, y: 0.5)
        )
        let presets: [ZoomEasingPreset] = [.fast, .smooth, .cinematic]
        let engines = presets.map { preset in
            ZoomEngine(
                document: ProjectDocument(
                    trimOut: 8,
                    zoomRanges: [zoom],
                    zoomEasing: preset
                )
            )
        }

        let openingWidths = engines.map { $0.crop(at: 1.25).width }
        guard openingWidths[0] < openingWidths[1],
              openingWidths[1] < openingWidths[2]
        else {
            throw OpenRecordError.io(
                "Fast/Smooth/Cinematic should open from quickest to slowest, got \(openingWidths)"
            )
        }

        let closingWidths = engines.map { $0.crop(at: 4.45).width }
        guard closingWidths[0] > closingWidths[1],
              closingWidths[1] > closingWidths[2]
        else {
            throw OpenRecordError.io(
                "Fast/Smooth/Cinematic should close from quickest to slowest, got \(closingWidths)"
            )
        }

        for (preset, engine) in zip(presets, engines) {
            guard engine.easing == preset,
                  engine.viewportSpring == preset.viewportSpring
            else {
                throw OpenRecordError.io("ZoomEngine did not adopt the \(preset.rawValue) motion preset")
            }
            try expectRect(engine.crop(at: 7), unit, "\(preset.rawValue) zoom should settle to unit")
        }
    }

    // MARK: - Fixture

    static func sensitivityFixture(duration: TimeInterval) -> [CursorSample] {
        var samples: [CursorSample] = []
        var x = 100.0
        var t = 0.0
        while t <= duration + 1e-9 {
            if t >= 1, t < 1.8 {
                x += 18
            } else if t >= 5, t < 5.8 {
                x += 7
            } else if t >= 9, t < 9.8 {
                x += 3.5
            }
            samples.append(CursorSample(t: t, x: x, y: 300))
            t += 0.1
        }
        return samples
    }

    /// 0–2s still, 2–3.2s move+click, 3.2–5.5s still, 5.5–6.5s move, 6.5–8s still.
    static func activityFixture() -> ([CursorSample], [ClickSample]) {
        var samples: [CursorSample] = []
        samples += hold(x: 120, y: 140, from: 0, to: 2)
        samples += move(from: Point2D(x: 120, y: 140), to: Point2D(x: 960, y: 270), start: 2, end: 3.2)
        samples += hold(x: 960, y: 270, from: 3.2, to: 5.5)
        samples += move(from: Point2D(x: 960, y: 270), to: Point2D(x: 1500, y: 820), start: 5.5, end: 6.5)
        samples += hold(x: 1500, y: 820, from: 6.5, to: 8)

        let clicks = [
            ClickSample(t: 2.8, button: .left, down: true),
            ClickSample(t: 2.9, button: .left, down: false),
        ]
        return (samples, clicks)
    }

    static func hold(x: Double, y: Double, from: TimeInterval, to: TimeInterval) -> [CursorSample] {
        strideSamples(from: from, to: to) { t in
            CursorSample(t: t, x: x, y: y)
        }
    }

    static func move(
        from: Point2D,
        to: Point2D,
        start: TimeInterval,
        end: TimeInterval
    ) -> [CursorSample] {
        strideSamples(from: start, to: end) { t in
            let u = (t - start) / max(end - start, 1e-9)
            return CursorSample(
                t: t,
                x: from.x + (to.x - from.x) * u,
                y: from.y + (to.y - from.y) * u
            )
        }
    }

    static func strideSamples(
        from: TimeInterval,
        to: TimeInterval,
        sample: (TimeInterval) -> CursorSample
    ) -> [CursorSample] {
        let dt = 1.0 / 30.0
        var t = from
        var out: [CursorSample] = []
        while t < to - 1e-9 {
            out.append(sample(t))
            t += dt
        }
        out.append(sample(to))
        return out
    }

    static func expectRect(_ got: CGRect, _ expected: CGRect, _ label: String) throws {
        let eps: CGFloat = 1e-6
        let dx = abs(got.origin.x - expected.origin.x)
        let dy = abs(got.origin.y - expected.origin.y)
        let dw = abs(got.width - expected.width)
        let dh = abs(got.height - expected.height)
        guard dx <= eps, dy <= eps, dw <= eps, dh <= eps else {
            throw OpenRecordError.io("\(label): got \(got), expected \(expected)")
        }
    }

    static func isNearlyUnit(_ rect: CGRect, eps: CGFloat = 1e-3) -> Bool {
        abs(rect.origin.x) <= eps
            && abs(rect.origin.y) <= eps
            && abs(rect.width - 1) <= eps
            && abs(rect.height - 1) <= eps
    }

    static func describe(_ zooms: [ZoomRange]) -> String {
        zooms.map { "[\($0.start), \($0.end)]×\($0.amount)" }.joined(separator: ", ")
    }
}

@Test
func cropWithNoZoomsIsUnitRect() throws {
    try ZoomEngineSuite.cropWithNoZoomsIsUnitRect()
}

@Test
func cropMidZoomIsSmallerAndNearAnchor() throws {
    try ZoomEngineSuite.cropMidZoomIsSmallerAndNearAnchor()
}

@Test
func autoZoomSegmentsAroundActivityNotPauses() throws {
    try ZoomEngineSuite.autoZoomSegmentsAroundActivityNotPauses()
}

@Test
func springAndCropAreDeterministic() throws {
    try ZoomEngineSuite.springAndCropAreDeterministic()
}

@Test
func nearbyClicksStayInOneZoomedRange() throws {
    try ZoomEngineSuite.nearbyClicksStayInOneZoomedRange()
}

@Test
func isolatedClickIslandHoldsMinZoom() throws {
    try ZoomEngineSuite.isolatedClickIslandHoldsMinZoom()
}

@Test
func longPauseZoomsOutAndIsSilence() throws {
    try ZoomEngineSuite.longPauseZoomsOutAndIsSilence()
}

@Test
func movementIslandOpensNearStartCursor() throws {
    try ZoomEngineSuite.movementIslandOpensNearStartCursor()
}

@Test
func sensitivityPresetsProduceIncreasingActivity() throws {
    try ZoomEngineSuite.sensitivityPresetsProduceIncreasingActivity()
}

@Test
func easingPresetsProduceOrderedMotion() throws {
    try ZoomEngineSuite.easingPresetsProduceOrderedMotion()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordZoomEngineTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunZoomEngineTests()
}

@_cdecl("OpenRecordRunZoomEngineTests")
func OpenRecordRunZoomEngineTests() {
    do {
        try ZoomEngineSuite.run()
        fputs("OpenRecordTests: ZoomEngine tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: ZoomEngine tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
