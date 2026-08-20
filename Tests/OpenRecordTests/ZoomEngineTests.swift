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
        guard silences.contains(where: { $0.start <= 4.5 && $0.end >= 4.5 }) else {
            throw OpenRecordError.io("expected silence around t=4.5, got \(silences)")
        }
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

    // MARK: - Fixture

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
