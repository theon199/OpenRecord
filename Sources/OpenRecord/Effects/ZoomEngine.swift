import CoreGraphics
import Foundation

/// Viewport crop and cursor interpolation for a project.
///
/// `crop(at:)` returns a UV rect (origin top-left, 0...1). With no zoom ranges it is the unit rect.
/// Amount eases with an analytical spring (zoom-in faster than zoom-out); with cursor samples the
/// viewport is a spring-driven camera with a central deadzone: it stays still while the cursor
/// moves inside the middle of the frame, pans continuously once the cursor pushes past it, and
/// never lets the cursor leave the frame. Short gaps hold zoom and pan between ranges instead of
/// returning to 1×.
///
/// After capture stop, generate ranges then build an engine:
/// ```
/// document.zoomRanges = ZoomEngine.generateAutoZooms(
///     samples: mouse, clicks: clicks, duration: duration, displayBounds: meta.displayBounds
/// )
/// let engine = ZoomEngine(
///     document: document, samples: mouse, clicks: clicks, displayBounds: meta.displayBounds
/// )
/// ```
/// Preview and export sample `crop(at:)` and `interpolateCursor(at:)` at each frame timestamp.
public struct ZoomEngine: Sendable {
    /// Seconds for a full zoom-in spring.
    public static let zoomInDuration: TimeInterval = 0.85
    /// Seconds for a full zoom-out spring (prompt disengagement).
    public static let zoomOutDuration: TimeInterval = 0.70
    /// If the next range starts within this gap, stay zoomed and pan instead of easing to 1×.
    public static let holdThroughGap: TimeInterval = 0.85
    /// Compatibility alias for `zoomInDuration`.
    public static let zoomDuration: TimeInterval = zoomInDuration

    public var document: ProjectDocument
    public let smoother: CursorSmoother
    public let displayBounds: Rect2D
    public let targetGeometry: [TargetGeometrySample]
    public let easing: ZoomEasingPreset
    public let viewportSpring: SpringConfig

    private let bake: BakeCache
    private let telemetryHorizon: TimeInterval

    public init(document: ProjectDocument) {
        self.init(document: document, samples: [], clicks: [], displayBounds: .unit)
    }

    public init(
        document: ProjectDocument,
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        displayBounds: Rect2D = .unit,
        targetGeometry: [TargetGeometrySample] = [],
        viewportSpring: SpringConfig? = nil
    ) {
        self.document = document
        self.displayBounds = displayBounds
        self.targetGeometry = targetGeometry
        self.easing = document.zoomEasing
        self.viewportSpring = viewportSpring ?? document.zoomEasing.viewportSpring
        self.smoother = CursorSmoother(
            samples: samples,
            clicks: clicks,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        )
        self.telemetryHorizon = max(samples.map(\.t).max() ?? 0, clicks.map(\.t).max() ?? 0)
        self.bake = BakeCache()
        self.bake.rebuild(
            ranges: document.zoomRanges,
            smoother: smoother,
            duration: Self.timelineEnd(
                document: document,
                telemetryHorizon: telemetryHorizon
            ),
            easing: easing,
            viewportSpring: self.viewportSpring
        )
    }

    /// Normalized crop in UV space (0...1). Origin is top-left. Always clamped inside the unit square.
    public func crop(at time: TimeInterval) -> CGRect {
        let ranges = document.zoomRanges
        if ranges.isEmpty {
            return .uvUnit
        }

        bake.rebuildIfNeeded(
            ranges: ranges,
            smoother: smoother,
            duration: Self.timelineEnd(
                document: document,
                telemetryHorizon: telemetryHorizon
            ),
            easing: easing,
            viewportSpring: viewportSpring
        )

        if bake.matches(ranges, easing: easing), let baked = bake.crop(at: time) {
            return clampUV(baked)
        }

        let evaluator = ZoomEvaluator(
            ranges: ranges,
            smoother: smoother,
            easing: easing,
            viewportSpring: viewportSpring
        )
        return clampUV(evaluator.evaluateLive(at: time))
    }

    /// Spring-smoothed cursor in source UV. `nil` when the engine was built without mouse samples
    /// (export should omit the overlay).
    public func interpolateCursor(at time: TimeInterval) -> Point2D? {
        smoother.interpolateIfVisible(at: time)
    }

    /// Spring-smoothed cursor velocity in source UV units per second.
    public func cursorVelocity(at time: TimeInterval) -> Point2D? {
        smoother.velocityIfVisible(at: time)
    }

    /// Primary-button down at `time`, from click telemetry captured with the engine.
    public func isClicking(at time: TimeInterval) -> Bool {
        guard smoother.isVisible(at: time) else { return false }
        return smoother.isClicking(at: time)
    }

    /// Detect idle stretches (cursor still ≥ ~1.6s; clicks count as activity).
    public static func detectSilenceZones(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        duration: TimeInterval? = nil,
        config: AutoZoomConfig = .default,
        displayBounds: Rect2D = .unit,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [SilenceZone] {
        AutoZoom.detectSilenceZones(
            samples: samples,
            clicks: clicks,
            duration: duration,
            config: config,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        )
    }

    /// Build `ZoomRange` segments for active (non-silent) regions. Assign onto `ProjectDocument.zoomRanges`.
    public static func generateAutoZooms(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: AutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        AutoZoom.generateRanges(
            samples: samples,
            clicks: clicks,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry
        )
    }

    static func timelineEnd(
        document: ProjectDocument,
        telemetryHorizon: TimeInterval
    ) -> TimeInterval {
        var end = max(document.trimOut ?? 0, telemetryHorizon)
        if let last = document.zoomRanges.map(\.end).max() {
            end = max(end, last + document.zoomEasing.zoomOutDuration)
        }
        return max(end, 0)
    }
}

private extension CGRect {
    static let uvUnit = CGRect(x: 0, y: 0, width: 1, height: 1)
}

private func clamp01(_ v: Double) -> Double {
    min(1, max(0, v))
}

private func clampUV(_ rect: CGRect) -> CGRect {
    var w = min(max(rect.width, 0), 1)
    var h = min(max(rect.height, 0), 1)
    var x = rect.origin.x
    var y = rect.origin.y
    if !x.isFinite { x = 0 }
    if !y.isFinite { y = 0 }
    if !w.isFinite { w = 1 }
    if !h.isFinite { h = 1 }
    x = min(1 - w, max(0, x))
    y = min(1 - h, max(0, y))
    return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - Evaluator

private struct ZoomEvaluator {
    struct SegmentBounds {
        var tlX: Double
        var tlY: Double
        var brX: Double
        var brY: Double

        static let unit = SegmentBounds(tlX: 0, tlY: 0, brX: 1, brY: 1)
    }

    struct InterpolatedZoom {
        var t: Double
        var bounds: SegmentBounds
    }

    struct SegmentCursor {
        var time: TimeInterval
        var segment: ZoomRange?
        var prevSegment: ZoomRange?
        var nextSegment: ZoomRange?
    }

    /// Sequential follow-cam state. The spring body is the camera center in UV
    /// space; its target is pushed by the deadzone rule below.
    struct PlaybackState {
        var spring: SpringState2D
        var lastTime: TimeInterval?

        static let initial = PlaybackState(
            spring: SpringState2D.rest(at: Point2D(x: 0.5, y: 0.5)),
            lastTime: nil
        )
    }

    var ranges: [ZoomRange]
    var smoother: CursorSmoother
    var easing: ZoomEasingPreset
    var viewportSpring: SpringConfig

    /// Half-extent of the deadzone as a fraction of the viewport size. The
    /// camera target does not move while the (lead) cursor stays inside the
    /// central 30% of the frame; beyond it the target is pushed just enough to
    /// keep the cursor on the deadzone boundary, so pans are continuous.
    static let deadzoneFraction = 0.15
    /// The live cursor is never allowed closer to a viewport edge than this
    /// fraction of the viewport size. Enforced on the camera position, after
    /// the spring, so spring lag can never push the cursor off-frame.
    static let edgeGuardFraction = 0.06
    /// The camera target anticipates the cursor by averaging its path over
    /// this window (telemetry is complete after capture, so this is lookahead,
    /// not prediction).
    static let leadWindow: TimeInterval = 0.25
    private static let leadSamples = 5

    func evaluateLive(at time: TimeInterval) -> CGRect {
        let sorted = ranges.sorted { $0.start < $1.start }
        let cursor = segmentCursor(at: time, ranges: sorted)
        let activeRange = cursor.segment ?? cursor.prevSegment
        let center: Point2D?
        if cursor.segment == nil,
           let prev = cursor.prevSegment,
           let next = cursor.nextSegment,
           next.start - prev.end <= ZoomEngine.holdThroughGap
        {
            center = nil
        } else {
            center = activeRange?.tracking == .followCursor
                ? smoother.interpolateIfVisible(at: time) ?? activeRange?.anchor
                : activeRange?.anchor
        }
        let zoom = interpolatedZoom(cursor: cursor, cursorCenter: center, ranges: sorted)
        return boundsToCrop(zoom.bounds)
    }

    func evaluateSequential(at time: TimeInterval, state: inout PlaybackState) -> CGRect {
        let sorted = ranges.sorted { $0.start < $1.start }
        if sorted.isEmpty {
            state = .initial
            return .uvUnit
        }

        let cursor = segmentCursor(at: time, ranges: sorted)
        if cursor.segment == nil, cursor.prevSegment == nil {
            state = .initial
            return .uvUnit
        }

        var dt: TimeInterval = 0
        var seekDetected = false
        if let last = state.lastTime {
            let d = time - last
            if d > 0, d < 0.5 {
                dt = min(d, 0.1)
            } else if d != 0 {
                seekDetected = true
            }
        }
        state.lastTime = time

        let activeRange = cursor.segment ?? cursor.prevSegment
        let follows = Self.followsCursor(cursor) && !smoother.isEmpty

        // Zoom level is independent of the camera center, so probe it first.
        let probe = interpolatedZoom(cursor: cursor, cursorCenter: state.spring.position, ranges: sorted)
        let z = probe.bounds.brX - probe.bounds.tlX

        if z <= 1.001 {
            // Fully zoomed out: park the camera where the next zoom should open
            // so a zoom-in always starts on the cursor (or the fixed anchor).
            let upcoming = cursor.segment ?? cursor.nextSegment ?? activeRange
            let seed: Point2D
            if upcoming?.tracking == .followCursor, !smoother.isEmpty {
                seed = leadTarget(at: time)
            } else {
                seed = upcoming?.anchor ?? Point2D(x: 0.5, y: 0.5)
            }
            state.spring = SpringState2D.rest(at: seed)
            return boundsToCrop(probe.bounds)
        }

        guard follows else {
            // Fixed framing: keep the spring parked on the anchor so an
            // adjacent follow-cursor range pans away from it smoothly.
            if let anchor = activeRange?.anchor {
                state.spring = SpringState2D.rest(at: anchor)
            }
            return boundsToCrop(probe.bounds)
        }

        let live = smoother.interpolate(at: time)
        let lead = leadTarget(at: time)
        let viewport = 1 / z
        let deadzone = viewport * Self.deadzoneFraction
        // Camera centers are clamped by the *settled* amount, not the current
        // transitional zoom level: while zooming in the crop is a lerp toward
        // the settled viewport, so the center must already be free to reach
        // the settled clamp or a cursor near the canvas edge is cut off.
        let rawAmount = max(
            cursor.segment?.amount ?? 1,
            cursor.prevSegment?.amount ?? 1,
            cursor.nextSegment?.amount ?? 1
        )
        let settledAmount = rawAmount.isFinite ? max(1, rawAmount) : 1.0
        let half = 0.5 / settledAmount

        var targetX = state.spring.targetU
        var targetY = state.spring.targetV
        if lead.x.isFinite, targetX.isFinite {
            if lead.x > targetX + deadzone {
                targetX = lead.x - deadzone
            } else if lead.x < targetX - deadzone {
                targetX = lead.x + deadzone
            }
        }
        if lead.y.isFinite, targetY.isFinite {
            if lead.y > targetY + deadzone {
                targetY = lead.y - deadzone
            } else if lead.y < targetY - deadzone {
                targetY = lead.y + deadzone
            }
        }
        if targetX.isFinite {
            state.spring.targetU = min(1 - half, max(half, targetX))
        }
        if targetY.isFinite {
            state.spring.targetV = min(1 - half, max(half, targetY))
        }

        if seekDetected {
            state.spring.posU = state.spring.targetU
            state.spring.posV = state.spring.targetV
            state.spring.velU = 0
            state.spring.velV = 0
        } else {
            SpringSolver.step(&state.spring, dt: dt, config: viewportSpring)
        }

        var crop = boundsToCrop(
            interpolatedZoom(cursor: cursor, cursorCenter: state.spring.position, ranges: sorted).bounds
        )

        // Hard visibility guard. During transitions the crop center is not the
        // spring position, so measure how the crop responds to a center shift
        // and correct the camera by exactly the amount needed.
        let guardInset = Double(crop.width) * Self.edgeGuardFraction
        var shiftX = 0.0
        var shiftY = 0.0
        if live.x < Double(crop.minX) + guardInset {
            shiftX = live.x - guardInset - Double(crop.minX)
        } else if live.x > Double(crop.maxX) - guardInset {
            shiftX = live.x + guardInset - Double(crop.maxX)
        }
        if live.y < Double(crop.minY) + guardInset {
            shiftY = live.y - guardInset - Double(crop.minY)
        } else if live.y > Double(crop.maxY) - guardInset {
            shiftY = live.y + guardInset - Double(crop.maxY)
        }
        if shiftX != 0 || shiftY != 0 {
            let epsilon = 0.01
            let probeCenter = Point2D(
                x: state.spring.posU + (shiftX >= 0 ? epsilon : -epsilon),
                y: state.spring.posV + (shiftY >= 0 ? epsilon : -epsilon)
            )
            let shifted = boundsToCrop(
                interpolatedZoom(cursor: cursor, cursorCenter: probeCenter, ranges: sorted).bounds
            )
            let slopeX = abs(Double(shifted.minX - crop.minX)) / epsilon
            let slopeY = abs(Double(shifted.minY - crop.minY)) / epsilon
            if shiftX != 0, slopeX > 1e-6 {
                state.spring.posU = min(1 - half, max(half, state.spring.posU + shiftX / slopeX))
                state.spring.velU = 0
                if (shiftX > 0 && state.spring.targetU < state.spring.posU)
                    || (shiftX < 0 && state.spring.targetU > state.spring.posU)
                {
                    state.spring.targetU = state.spring.posU
                }
            }
            if shiftY != 0, slopeY > 1e-6 {
                state.spring.posV = min(1 - half, max(half, state.spring.posV + shiftY / slopeY))
                state.spring.velV = 0
                if (shiftY > 0 && state.spring.targetV < state.spring.posV)
                    || (shiftY < 0 && state.spring.targetV > state.spring.posV)
                {
                    state.spring.targetV = state.spring.posV
                }
            }
            crop = boundsToCrop(
                interpolatedZoom(cursor: cursor, cursorCenter: state.spring.position, ranges: sorted).bounds
            )
        }
        return crop
    }

    /// Whether the camera should track the cursor at this point of the
    /// timeline. Inside a range this is the range's mode; across a
    /// hold-through gap either neighbor following is enough (the lerp between
    /// them reads the spring for the follow side); during a zoom-out the
    /// closing range decides.
    static func followsCursor(_ cursor: SegmentCursor) -> Bool {
        if let segment = cursor.segment {
            return segment.tracking == .followCursor
        }
        guard let prev = cursor.prevSegment else { return false }
        if let next = cursor.nextSegment, next.start - prev.end <= ZoomEngine.holdThroughGap {
            return prev.tracking == .followCursor || next.tracking == .followCursor
        }
        return prev.tracking == .followCursor
    }

    /// Mean smoothed cursor position over the upcoming lead window.
    func leadTarget(at time: TimeInterval) -> Point2D {
        var sumX = 0.0
        var sumY = 0.0
        for index in 0...Self.leadSamples {
            let sample = smoother.interpolate(
                at: time + Self.leadWindow * Double(index) / Double(Self.leadSamples)
            )
            sumX += sample.x
            sumY += sample.y
        }
        let count = Double(Self.leadSamples + 1)
        return Point2D(x: sumX / count, y: sumY / count)
    }

    func segmentCursor(at time: TimeInterval, ranges: [ZoomRange]) -> SegmentCursor {
        if let index = ranges.firstIndex(where: { time >= $0.start && time < $0.end }) {
            return SegmentCursor(
                time: time,
                segment: ranges[index],
                prevSegment: index > 0 ? ranges[index - 1] : nil,
                nextSegment: index + 1 < ranges.count ? ranges[index + 1] : nil
            )
        }
        var prev: ZoomRange?
        var next: ZoomRange?
        for range in ranges {
            if range.end <= time {
                prev = range
            } else if range.start > time {
                next = range
                break
            }
        }
        return SegmentCursor(time: time, segment: nil, prevSegment: prev, nextSegment: next)
    }

    func interpolatedZoom(
        cursor: SegmentCursor,
        cursorCenter: Point2D?,
        ranges: [ZoomRange]
    ) -> InterpolatedZoom {
        computeInterpolatedZoom(
            cursor: cursor,
            cursorCenter: cursorCenter,
            ranges: ranges,
            easeIn: { SpringEasing.easeIn($0, config: easing.zoomSpring) },
            easeOut: { SpringEasing.easeOut($0, config: easing.zoomSpring) }
        )
    }

    func computeInterpolatedZoom(
        cursor: SegmentCursor,
        cursorCenter: Point2D?,
        ranges _: [ZoomRange],
        easeIn: (Double) -> Double,
        easeOut: (Double) -> Double
    ) -> InterpolatedZoom {
        let def = SegmentBounds.unit
        let time = cursor.time
        let seg = cursor.segment
        let prev = cursor.prevSegment

        if seg == nil, prev == nil {
            return InterpolatedZoom(t: 0, bounds: def)
        }

        if let prev, seg == nil {
            if let next = cursor.nextSegment, next.start - prev.end <= ZoomEngine.holdThroughGap {
                let gap = max(next.start - prev.end, 1e-12)
                let u = clamp01((time - prev.end) / gap)
                let pFocus = zoomFocus(prev, cursorCenter: cursorCenter)
                let nFocus = zoomFocus(next, cursorCenter: cursorCenter)
                let prevBounds = segmentBounds(amount: prev.amount, cx: pFocus.x, cy: pFocus.y)
                let nextBounds = segmentBounds(amount: next.amount, cx: nFocus.x, cy: nFocus.y)
                return InterpolatedZoom(t: 1, bounds: lerpBounds(prevBounds, nextBounds, u))
            }
            let zoomT = easeOut(clamp01((time - prev.end) / easing.zoomOutDuration))
            let focus = zoomFocus(prev, cursorCenter: cursorCenter)
            let prevBounds = segmentBounds(amount: prev.amount, cx: focus.x, cy: focus.y)
            return InterpolatedZoom(t: 1 - zoomT, bounds: lerpBounds(prevBounds, def, zoomT))
        }

        if prev == nil, let seg {
            let t = easeIn(clamp01((time - seg.start) / easing.zoomInDuration))
            let focus = zoomFocus(seg, cursorCenter: cursorCenter)
            let segBounds = segmentBounds(amount: seg.amount, cx: focus.x, cy: focus.y)
            return InterpolatedZoom(t: t, bounds: lerpBounds(def, segBounds, t))
        }

        guard let prev, let seg else {
            return InterpolatedZoom(t: 0, bounds: def)
        }

        let pFocus = zoomFocus(prev, cursorCenter: cursorCenter)
        let sFocus = zoomFocus(seg, cursorCenter: cursorCenter)
        let prevBounds = segmentBounds(amount: prev.amount, cx: pFocus.x, cy: pFocus.y)
        let segBounds = segmentBounds(amount: seg.amount, cx: sFocus.x, cy: sFocus.y)
        let zoomT = easeIn(clamp01((time - seg.start) / easing.zoomInDuration))

        if seg.start == prev.end {
            return InterpolatedZoom(t: 1, bounds: lerpBounds(prevBounds, segBounds, zoomT))
        }

        if seg.start - prev.end <= ZoomEngine.holdThroughGap {
            return InterpolatedZoom(t: 1, bounds: segBounds)
        }

        return InterpolatedZoom(t: zoomT, bounds: lerpBounds(def, segBounds, zoomT))
    }

    func zoomFocus(_ range: ZoomRange, cursorCenter: Point2D?) -> Point2D {
        switch range.tracking {
        case .fixed: range.anchor
        case .followCursor: cursorCenter ?? range.anchor
        }
    }

    func segmentBounds(amount: Double, cx: Double, cy: Double) -> SegmentBounds {
        let amount = max(amount, 1)
        let half = 0.5 / amount
        let clampedCx = min(1 - half, max(half, cx))
        let clampedCy = min(1 - half, max(half, cy))
        let tlX = -amount * clampedCx + 0.5
        let tlY = -amount * clampedCy + 0.5
        return SegmentBounds(tlX: tlX, tlY: tlY, brX: tlX + amount, brY: tlY + amount)
    }

    func lerpBounds(_ a: SegmentBounds, _ b: SegmentBounds, _ t: Double) -> SegmentBounds {
        let u = 1 - t
        return SegmentBounds(
            tlX: a.tlX * u + b.tlX * t,
            tlY: a.tlY * u + b.tlY * t,
            brX: a.brX * u + b.brX * t,
            brY: a.brY * u + b.brY * t
        )
    }

    func boundsToCrop(_ b: SegmentBounds) -> CGRect {
        let zoom = b.brX - b.tlX
        if zoom <= 0 { return .uvUnit }
        return CGRect(x: -b.tlX / zoom, y: -b.tlY / zoom, width: 1 / zoom, height: 1 / zoom)
    }
}

// MARK: - Bake cache

private final class BakeCache: @unchecked Sendable {
    private static let dt: TimeInterval = 1.0 / 60.0

    private let lock = NSLock()
    private var ranges: [ZoomRange] = []
    private var easing: ZoomEasingPreset = .smooth
    private var times: [TimeInterval] = []
    private var crops: [CGRect] = []
    private var baked = false

    func matches(_ current: [ZoomRange], easing: ZoomEasingPreset) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return baked && ranges == current && self.easing == easing && !crops.isEmpty
    }

    func crop(at time: TimeInterval) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        guard baked, !crops.isEmpty, times.count == crops.count else { return nil }
        if time <= times[0] { return crops[0] }
        if time >= times[times.count - 1] { return crops[times.count - 1] }

        var lo = 0
        var hi = times.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time {
                lo = mid
            } else {
                hi = mid
            }
        }
        let span = max(times[hi] - times[lo], 1e-12)
        let t = (time - times[lo]) / span
        return lerpRect(crops[lo], crops[hi], t)
    }

    func rebuildIfNeeded(
        ranges: [ZoomRange],
        smoother: CursorSmoother,
        duration: TimeInterval,
        easing: ZoomEasingPreset,
        viewportSpring: SpringConfig
    ) {
        lock.lock()
        if baked, self.ranges == ranges, self.easing == easing {
            lock.unlock()
            return
        }
        lock.unlock()
        rebuild(
            ranges: ranges,
            smoother: smoother,
            duration: duration,
            easing: easing,
            viewportSpring: viewportSpring
        )
    }

    func rebuild(
        ranges: [ZoomRange],
        smoother: CursorSmoother,
        duration: TimeInterval,
        easing: ZoomEasingPreset,
        viewportSpring: SpringConfig
    ) {
        guard !smoother.isEmpty, !ranges.isEmpty, duration > 0 else {
            lock.lock()
            self.ranges = ranges
            self.easing = easing
            times = []
            crops = []
            baked = false
            lock.unlock()
            return
        }

        let evaluator = ZoomEvaluator(
            ranges: ranges,
            smoother: smoother,
            easing: easing,
            viewportSpring: viewportSpring
        )
        var state = ZoomEvaluator.PlaybackState.initial

        var t: TimeInterval = 0
        let end = duration + 1e-9
        let capacity = Int(end / Self.dt) + 2
        var localTimes: [TimeInterval] = []
        var localCrops: [CGRect] = []
        localTimes.reserveCapacity(capacity)
        localCrops.reserveCapacity(capacity)
        while t <= end {
            localTimes.append(t)
            localCrops.append(clampUV(evaluator.evaluateSequential(at: t, state: &state)))
            t += Self.dt
        }

        lock.lock()
        self.ranges = ranges
        self.easing = easing
        self.times = localTimes
        self.crops = localCrops
        self.baked = true
        lock.unlock()
    }
}

private func lerpRect(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let u = 1 - t
    return CGRect(
        x: a.origin.x * u + b.origin.x * t,
        y: a.origin.y * u + b.origin.y * t,
        width: a.width * u + b.width * t,
        height: a.height * u + b.height * t
    )
}
