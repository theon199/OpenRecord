import Foundation
import Testing
import OpenRecord

@Test
func smartAutoZoomDwellProducesFollowCursorAutomaticRange() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    var samples: [CursorSample] = []
    for i in 0...60 {
        let t = Double(i) / 30
        let x = t < 1 ? 100 + t * 700 : 800
        samples.append(CursorSample(t: t, x: x, y: 400))
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        duration: 2,
        displayBounds: bounds,
        config: SmartAutoZoomConfig(minDwell: 0.6)
    )
    #expect(ranges.contains { $0.source == .automatic })
    #expect(ranges.contains { $0.tracking == .followCursor && $0.end - $0.start >= 0.6 })
}

@Test
func smartAutoZoomSuppressesVeryFastTransit() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = [
        CursorSample(t: 0, x: 0, y: 400),
        CursorSample(t: 0.04, x: 960, y: 400),
        CursorSample(t: 0.08, x: 1_920, y: 400),
    ]
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        duration: 1,
        displayBounds: bounds
    )
    #expect(ranges.isEmpty)
}

@Test
func smartAutoZoomClustersNearbyClicksWithoutOscillation() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = stride(from: 0.0, through: 4.0, by: 0.05).map {
        CursorSample(t: $0, x: 1_000, y: 500)
    }
    let clicks = [
        ClickSample(t: 1, button: .left, down: true),
        ClickSample(t: 2, button: .left, down: true),
    ]
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: clicks,
        duration: 4,
        displayBounds: bounds
    )
    #expect(ranges.count == 1)
    #expect(abs(ranges[0].anchor.x - CursorSmoother.uv(x: 1_000, y: 500, displayBounds: bounds).x) < 0.01)
}

@Test
func smartAutoZoomUsesEdgeSafeAnchorsAndMinimumHold() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = [CursorSample(t: 0, x: 0, y: 0), CursorSample(t: 3, x: 0, y: 0)]
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: [ClickSample(t: 1, button: .left, down: true)],
        duration: 3,
        displayBounds: bounds
    )
    #expect(ranges.count == 1)
    #expect(ranges[0].anchor.x >= 0.14)
    #expect(ranges[0].anchor.y >= 0.14)
    #expect(ranges[0].end - ranges[0].start >= AutoZoomConfig.default.minZoomHold)
}

@Test
func smartAutoZoomRegenerationPreservesLockedManualAndAvoidsOverlap() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let locked = ZoomRange(
        start: 1.5,
        end: 2.5,
        amount: 2,
        anchor: Point2D(x: 0.5, y: 0.5),
        tracking: .fixed,
        isLocked: true,
        source: .manual
    )
    let samples = stride(from: 0.0, through: 4.0, by: 0.05).map {
        CursorSample(t: $0, x: $0 < 2 ? 200 : 1_700, y: 500)
    }
    let ranges = SmartAutoZoom.regenerateRanges(
        existing: [locked],
        samples: samples,
        duration: 4,
        displayBounds: bounds
    )
    #expect(ranges.contains { $0.id == locked.id })
    #expect(ranges.filter { $0.source == .automatic }.allSatisfy {
        $0.end <= locked.start || $0.start >= locked.end
    })
}
