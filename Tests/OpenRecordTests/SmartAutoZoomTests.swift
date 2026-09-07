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

@Test
func smartAutoZoomTypingGeneratesFixedRangeOnTextBox() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = stride(from: 0.0, through: 6.0, by: 0.1).map {
        CursorSample(t: $0, x: 500, y: 300)
    }
    // User types in a text box located at (400, 250, 400, 60) between t=1.0 and t=3.0
    let typing = stride(from: 1.0, through: 3.0, by: 0.2).map {
        TypingSample(t: $0, x: 400, y: 250, width: 400, height: 60)
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: [],
        typing: typing,
        duration: 6,
        displayBounds: bounds
    )
    #expect(ranges.count == 1)
    let range = ranges[0]
    #expect(range.source == .automatic)
    #expect(range.tracking == .fixed)
    #expect(range.start <= 1.0)
    // Should hold for ~2 seconds after typing ends at 3.0
    #expect(range.end >= 4.9)
    // Anchor should be near the text box center
    let expectedU = (400.0 + min(400.0 * 0.35, 120)) / 1920.0
    let expectedV = (250.0 + 30.0) / 1080.0
    #expect(abs(range.anchor.x - expectedU) < 0.05)
    #expect(abs(range.anchor.y - expectedV) < 0.05)
}

@Test
func smartAutoZoomSuppressesCasualSweeps() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    // Mouse casually moves across the screen for 0.4s without dwell, click, or typing
    let samples = (0...8).map { i -> CursorSample in
        let t = Double(i) * 0.05
        return CursorSample(t: t, x: 100 + Double(i) * 100, y: 400)
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: [],
        typing: [],
        duration: 2,
        displayBounds: bounds
    )
    #expect(ranges.isEmpty)
}

@Test
func smartAutoZoomDynamicHoldScalesWithActivity() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = (0...20).map { i -> CursorSample in
        let t = Double(i) * 0.05
        return CursorSample(t: t, x: 100 + Double(i) * 40, y: 540)
    }
    // Sustained typing for 3 seconds (from 1.0 to 4.0)
    let typing = stride(from: 1.0, through: 4.0, by: 0.25).map {
        TypingSample(t: $0, x: 960, y: 540)
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: [],
        typing: typing,
        duration: 10,
        displayBounds: bounds,
        config: SmartAutoZoomConfig(requireDwellEngagement: true)
    )
    #expect(ranges.count == 1)
    // Post-typing hold should be ~2.0s (ends around 6.0)
    #expect(ranges[0].end >= 5.9 && ranges[0].end <= 6.2)
}

/// A cursor that stops and stays still is a target for only a short while;
/// afterwards the range must end so the zoom eases back out instead of pinning
/// the viewer on an idle pointer for the rest of the recording.
@Test
func smartAutoZoomLongIdleDwellEasesOut() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    var samples: [CursorSample] = []
    // Move for one second, then sit still for twelve.
    for i in 0...30 {
        let t = Double(i) / 30
        samples.append(CursorSample(t: t, x: 200 + t * 600, y: 400))
    }
    for i in 1...120 {
        samples.append(CursorSample(t: 1 + Double(i) / 10, x: 800, y: 400))
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        duration: 13,
        displayBounds: bounds
    )
    #expect(ranges.count == 1)
    guard let range = ranges.first else { return }
    #expect(range.start <= 1.0)
    // Motion stopped at t=1.0; idle should ease out shortly after maxDwell,
    // not stay zoomed for the remaining twelve seconds of stillness.
    #expect(range.end <= 3.3)
    #expect(range.end >= 2.0)
}

/// A click followed by a long still cursor must not keep the zoom pinned.
/// After the click window, inactivity eases back out to 1×.
@Test
func smartAutoZoomClickThenIdleZoomsOut() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    let samples = stride(from: 0.0, through: 12.0, by: 0.1).map {
        CursorSample(t: $0, x: 900, y: 500)
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: [
            ClickSample(t: 1.0, button: .left, down: true),
            ClickSample(t: 1.05, button: .left, down: false),
        ],
        duration: 12,
        displayBounds: bounds
    )
    #expect(ranges.count == 1)
    guard let range = ranges.first else { return }
    #expect(range.start <= 1.0)
    #expect(range.end <= 3.5)
    #expect(range.end >= 1.5)
}

/// Click at one spot, flick to a far spot and rest there. The two signals
/// overlap after hold expansion, and the merged range must follow the cursor:
/// a fixed anchor on the click would leave the pointer out of frame.
@Test
func smartAutoZoomMixedAnchorsFollowCursor() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    var samples: [CursorSample] = []
    for i in 0...30 {
        samples.append(CursorSample(t: Double(i) / 30, x: 300, y: 300))
    }
    // Fast flick from (300,300) to (1600,800) in 0.2s starting at t=1.2.
    for i in 1...6 {
        let u = Double(i) / 6
        samples.append(CursorSample(t: 1.2 + 0.2 * u, x: 300 + 1300 * u, y: 300 + 500 * u))
    }
    for i in 1...60 {
        samples.append(CursorSample(t: 1.4 + Double(i) / 30, x: 1600, y: 800))
    }
    let clicks = [
        ClickSample(t: 1.0, button: .left, down: true),
        ClickSample(t: 1.05, button: .left, down: false),
    ]
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        clicks: clicks,
        duration: 4,
        displayBounds: bounds
    )
    #expect(!ranges.isEmpty)
    #expect(ranges.allSatisfy { $0.tracking == .followCursor })
    #expect(ranges.contains { $0.start <= 1.0 && $0.end >= 2.0 })
}

/// Typing keeps its text-box anchor only while the pointer stays inside that
/// frame; once the pointer wanders off the range has to follow it.
@Test
func smartAutoZoomTypingFollowsCursorWhenPointerLeavesFrame() {
    let bounds = Rect2D(x: 0, y: 0, width: 1_920, height: 1_080)
    var samples: [CursorSample] = []
    for i in 0...20 {
        samples.append(CursorSample(t: Double(i) / 10, x: 500, y: 300))
    }
    // While the text hold is still active the pointer goes to the far corner.
    for i in 1...30 {
        samples.append(CursorSample(t: 2 + Double(i) / 10, x: 1_850, y: 1_000))
    }
    let typing = stride(from: 1.0, through: 1.8, by: 0.2).map {
        TypingSample(t: $0, x: 400, y: 250, width: 400, height: 60)
    }
    let ranges = SmartAutoZoom.generateRanges(
        samples: samples,
        typing: typing,
        duration: 6,
        displayBounds: bounds
    )
    #expect(!ranges.isEmpty)
    #expect(ranges.allSatisfy { $0.tracking == .followCursor })
}

