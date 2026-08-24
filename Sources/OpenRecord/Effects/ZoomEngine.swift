import CoreGraphics
import Foundation

/// Viewport crop and cursor interpolation for a project.
///
/// `crop(at:)` returns a UV rect (origin top-left, 0...1). With no zoom ranges it is the unit rect.
/// Amount eases with an analytical spring (zoom-in faster than zoom-out); with cursor samples the
/// viewport pans using a safe zone and 1s lookahead (jitter cancellation). Short gaps hold zoom
/// and pan between ranges instead of returning to 1×.
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
    /// Seconds for a full zoom-out spring (slower settle).
    public static let zoomOutDuration: TimeInterval = 1.35
    /// If the next range starts within this gap, stay zoomed and pan instead of easing to 1×.
    public static let holdThroughGap: TimeInterval = 2.0
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

    struct PlaybackState {
        var lockedCenter: Point2D?
        var lockedSegStart: TimeInterval?
        var spring: SpringState2D
        var lastTime: TimeInterval?
        var lastRetargetTime: TimeInterval?
    }

    var ranges: [ZoomRange]
    var smoother: CursorSmoother
    var easing: ZoomEasingPreset
    var viewportSpring: SpringConfig

    private static let viewportEdgeThresh = 0.19
    private static let recenterLookahead: TimeInterval = 1
    private static let recenterLookaheadSamples = 10
    private static let recenterAvgWindow: TimeInterval = 0.5
    private static let recenterEpsilon = 0.01
    private static let recenterCooldown: TimeInterval = 0.25

    func evaluateLive(at time: TimeInterval) -> CGRect {
        let sorted = ranges.sorted { $0.start < $1.start }
        let cursor = segmentCursor(at: time, ranges: sorted)
        let center: Point2D?
        if cursor.segment == nil,
           let prev = cursor.prevSegment,
           let next = cursor.nextSegment,
           next.start - prev.end <= ZoomEngine.holdThroughGap
        {
            center = nil
        } else {
            center = (cursor.segment ?? cursor.prevSegment)?.anchor
        }
        let zoom = interpolatedZoom(cursor: cursor, cursorCenter: center, ranges: sorted)
        if let live = smoother.interpolateIfVisible(at: time) {
            return boundsToCrop(ensureCursorVisible(zoom, cursorX: live.x, cursorY: live.y).bounds)
        }
        return boundsToCrop(zoom.bounds)
    }

    func evaluateSequential(at time: TimeInterval, state: inout PlaybackState) -> CGRect {
        let sorted = ranges.sorted { $0.start < $1.start }
        if sorted.isEmpty {
            state.lockedCenter = nil
            state.lockedSegStart = nil
            state.lastTime = nil
            state.lastRetargetTime = nil
            return .uvUnit
        }

        let cursor = segmentCursor(at: time, ranges: sorted)
        if cursor.segment == nil, cursor.prevSegment == nil {
            state.lockedCenter = nil
            state.lockedSegStart = nil
            state.lastTime = nil
            state.lastRetargetTime = nil
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

        let isAuto = !smoother.isEmpty
        let liveCursor: Point2D? = isAuto ? smoother.interpolate(at: time) : nil

        var zoomCenter: Point2D?
        if isAuto {
            let curSegStart = cursor.segment?.start
            if let curSegStart, curSegStart != state.lockedSegStart {
                let lock = liveCursor ?? cursor.segment?.anchor
                state.lockedCenter = lock
                state.lockedSegStart = curSegStart
                state.lastRetargetTime = time
                if let lock {
                    state.spring = SpringState2D.rest(at: lock)
                }
            } else if state.lockedCenter == nil {
                let lock = liveCursor ?? cursor.segment?.anchor
                state.lockedCenter = lock
                state.lastRetargetTime = time
                if let lock {
                    state.spring = SpringState2D.rest(at: lock)
                }
            }
            zoomCenter = state.lockedCenter ?? liveCursor
        } else if let active = cursor.segment ?? cursor.prevSegment {
            zoomCenter = active.anchor
        }

        guard isAuto, let liveCursor else {
            let zoom = interpolatedZoom(cursor: cursor, cursorCenter: zoomCenter, ranges: sorted)
            return boundsToCrop(zoom.bounds)
        }

        let actualZoom = interpolatedZoom(
            cursor: cursor,
            cursorCenter: state.spring.position,
            ranges: sorted
        )
        let z = actualZoom.bounds.brX - actualZoom.bounds.tlX

        if z > 1.001 {
            let vpSize = 1 / z
            let vpLeft = -actualZoom.bounds.tlX / z
            let vpTop = -actualZoom.bounds.tlY / z
            let triggerMargin = vpSize * Self.viewportEdgeThresh

            let inSafe =
                liveCursor.x >= vpLeft + triggerMargin
                && liveCursor.x <= vpLeft + vpSize - triggerMargin
                && liveCursor.y >= vpTop + triggerMargin
                && liveCursor.y <= vpTop + vpSize - triggerMargin

            if !inSafe {
                var cancelRecenter = false
                for i in 1...Self.recenterLookaheadSamples {
                    let futureT =
                        time + (Self.recenterLookahead * Double(i) / Double(Self.recenterLookaheadSamples))
                    guard let fc = smoother.interpolateIfVisible(at: futureT) else { continue }
                    let futureInSafe =
                        fc.x >= vpLeft + triggerMargin
                        && fc.x <= vpLeft + vpSize - triggerMargin
                        && fc.y >= vpTop + triggerMargin
                        && fc.y <= vpTop + vpSize - triggerMargin
                    if futureInSafe {
                        cancelRecenter = true
                        break
                    }
                }

                if !cancelRecenter {
                    var sumU = liveCursor.x
                    var sumV = liveCursor.y
                    let n = Self.recenterLookaheadSamples
                    for i in 1...n {
                        guard let fc = smoother.interpolateIfVisible(
                            at: time + (Self.recenterAvgWindow * Double(i) / Double(n))
                        ) else { continue }
                        sumU += fc.x
                        sumV += fc.y
                    }
                    let target = Point2D(x: sumU / Double(n + 1), y: sumV / Double(n + 1))
                    var tooSoon = false
                    if let last = state.lastRetargetTime, time - last < Self.recenterCooldown {
                        tooSoon = true
                    }
                    var close = false
                    if let current = state.lockedCenter {
                        close = hypot(target.x - current.x, target.y - current.y) < Self.recenterEpsilon
                    }
                    if !tooSoon && !close {
                        state.lockedCenter = target
                        state.spring.targetU = target.x
                        state.spring.targetV = target.y
                        state.lastRetargetTime = time
                    }
                }
            }
        }

        if seekDetected {
            state.spring.posU = state.spring.targetU
            state.spring.posV = state.spring.targetV
            state.spring.velU = 0
            state.spring.velV = 0
        } else {
            SpringSolver.step(&state.spring, dt: dt, config: viewportSpring)
        }

        if z > 1.001 {
            let visualZoom = interpolatedZoom(
                cursor: cursor,
                cursorCenter: state.spring.position,
                ranges: sorted
            )
            return boundsToCrop(visualZoom.bounds)
        }
        return boundsToCrop(actualZoom.bounds)
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
        cursorCenter ?? range.anchor
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

    func ensureCursorVisible(
        _ zoom: InterpolatedZoom,
        cursorX: Double,
        cursorY: Double
    ) -> InterpolatedZoom {
        let currentZoom = zoom.bounds.brX - zoom.bounds.tlX
        if currentZoom <= 1.001 { return zoom }

        let viewportSize = 1 / currentZoom
        let viewportLeft = -zoom.bounds.tlX / currentZoom
        let viewportTop = -zoom.bounds.tlY / currentZoom
        let triggerMargin = viewportSize * Self.viewportEdgeThresh

        let inSafeZone =
            cursorX >= viewportLeft + triggerMargin
            && cursorX <= viewportLeft + viewportSize - triggerMargin
            && cursorY >= viewportTop + triggerMargin
            && cursorY <= viewportTop + viewportSize - triggerMargin
        if inSafeZone { return zoom }

        let placeMargin = viewportSize * 0.20
        var newVpLeft = viewportLeft
        var newVpTop = viewportTop

        if cursorX < viewportLeft + triggerMargin {
            newVpLeft = cursorX - placeMargin
        } else if cursorX > viewportLeft + viewportSize - triggerMargin {
            newVpLeft = cursorX - viewportSize + placeMargin
        }
        if cursorY < viewportTop + triggerMargin {
            newVpTop = cursorY - placeMargin
        } else if cursorY > viewportTop + viewportSize - triggerMargin {
            newVpTop = cursorY - viewportSize + placeMargin
        }

        newVpLeft = min(1 - viewportSize, max(0, newVpLeft))
        newVpTop = min(1 - viewportSize, max(0, newVpTop))

        let newTlX = -newVpLeft * currentZoom
        let newTlY = -newVpTop * currentZoom
        return InterpolatedZoom(
            t: zoom.t,
            bounds: SegmentBounds(
                tlX: newTlX,
                tlY: newTlY,
                brX: newTlX + currentZoom,
                brY: newTlY + currentZoom
            )
        )
    }
}

// MARK: - Bake cache

private final class BakeCache: @unchecked Sendable {
    private static let dt: TimeInterval = 1.0 / 60.0

    private var ranges: [ZoomRange] = []
    private var easing: ZoomEasingPreset = .smooth
    private var times: [TimeInterval] = []
    private var crops: [CGRect] = []
    private var baked = false

    func matches(_ current: [ZoomRange], easing: ZoomEasingPreset) -> Bool {
        baked && ranges == current && self.easing == easing && !crops.isEmpty
    }

    func crop(at time: TimeInterval) -> CGRect? {
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
        if baked, self.ranges == ranges, self.easing == easing { return }
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
        self.ranges = ranges
        self.easing = easing
        times = []
        crops = []
        baked = false

        guard !smoother.isEmpty, !ranges.isEmpty, duration > 0 else { return }

        let evaluator = ZoomEvaluator(
            ranges: ranges,
            smoother: smoother,
            easing: easing,
            viewportSpring: viewportSpring
        )
        var state = ZoomEvaluator.PlaybackState(
            lockedCenter: nil,
            lockedSegStart: nil,
            spring: SpringState2D.rest(at: Point2D(x: 0.5, y: 0.5)),
            lastTime: nil,
            lastRetargetTime: nil
        )

        var t: TimeInterval = 0
        let end = duration + 1e-9
        let capacity = Int(end / Self.dt) + 2
        times.reserveCapacity(capacity)
        crops.reserveCapacity(capacity)
        while t <= end {
            times.append(t)
            crops.append(clampUV(evaluator.evaluateSequential(at: t, state: &state)))
            t += Self.dt
        }
        baked = true
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
