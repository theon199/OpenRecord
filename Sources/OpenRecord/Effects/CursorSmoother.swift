import Foundation

/// Precomputed spring-smoothed cursor path in UV space (origin top-left).
///
/// Pipeline: raw points → UV → jitter (shake) filter → short EMA → densify gaps → analytical spring.
/// Sample at any time with `interpolate(at:)` (binary search + one spring step).
public struct CursorSmoother: Sendable {
    public struct Sample: Sendable, Hashable {
        public var time: TimeInterval
        public var position: Point2D
        public var velocity: Point2D
        public var target: Point2D
        /// `false` marks a telemetry sample captured while the pointer was outside
        /// the selected target. Legacy samples are treated as visible.
        public var visible: Bool
    }

    public let displayBounds: Rect2D
    public let samples: [Sample]
    public let clicks: [ClickSample]
    public let targetGeometry: [TargetGeometrySample]
    private let rawSamples: [CursorSample]
    /// Primary-button edges only, in time order, so preview/export click
    /// lookups are binary searches instead of scanning the full click list.
    private let primaryClicks: [ClickSample]

    public var isEmpty: Bool { samples.isEmpty }

    public init(
        samples raw: [CursorSample],
        clicks: [ClickSample] = [],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample] = []
    ) {
        self.displayBounds = displayBounds
        let sortedGeometry = targetGeometry.sorted { $0.t < $1.t }
        let sortedRaw = raw.sorted { $0.t < $1.t }
        self.clicks = Self.filterClicks(
            clicks.sorted { $0.t < $1.t },
            samples: sortedRaw,
            geometry: sortedGeometry,
            fallback: displayBounds
        )
        self.primaryClicks = self.clicks.filter {
            $0.button == .left || $0.button == .other
        }
        self.targetGeometry = sortedGeometry
        self.rawSamples = sortedRaw

        // Normalize against the target bounds at each sample rather than the
        // display bounds. This is what keeps a captured window stable while it
        // moves around the desktop. A missing target sidecar preserves v1's
        // display-bounds behavior.
        let moves = sortedRaw.map { sample in
            let bounds = Self.geometry(at: sample.t, samples: sortedGeometry, fallback: displayBounds)
            return Move(
                time: sample.t,
                uv: CursorSmoother.uv(x: sample.x, y: sample.y, displayBounds: bounds),
                visible: Self.isVisible(sample, at: sample.t, geometry: sortedGeometry, fallback: displayBounds)
            )
        }
        // Off-target movement must not influence the spring or auto-zoom. Keep
        // visibility in rawSamples so interpolateIfVisible can hide the overlay
        // throughout an off-target interval.
        let visibleMoves = moves.filter(\.visible)

        let filtered = Self.filterShake(visibleMoves, displayBounds: displayBounds)
        let smoothed = Self.smoothEMA(filtered)
        let dense = Self.densify(smoothed)
        self.samples = Self.simulate(moves: dense, clicks: self.clicks)
    }

    /// Convert capture-space points to UV 0...1 (origin top-left), clamped.
    public static func uv(x: Double, y: Double, displayBounds: Rect2D) -> Point2D {
        let w = max(displayBounds.width, 1e-9)
        let h = max(displayBounds.height, 1e-9)
        return Point2D(
            x: Self.clamp01((x - displayBounds.x) / w),
            y: Self.clamp01((y - displayBounds.y) / h)
        )
    }

    public static func uv(_ sample: CursorSample, displayBounds: Rect2D) -> Point2D {
        uv(x: sample.x, y: sample.y, displayBounds: displayBounds)
    }

    /// Whether the pointer is on-screen and inside the selected target at time.
    /// This is public so auto-zoom can apply the exact same filtering as the
    /// preview/export cursor path.
    public static func isVisible(
        _ sample: CursorSample,
        at time: TimeInterval,
        geometry: [TargetGeometrySample],
        fallback: Rect2D
    ) -> Bool {
        guard sample.isVisible else { return false }
        // `visible` and target geometry were both optional v1.0.1 additions.
        // With no geometry sidecar, preserve v1's contract exactly: a missing
        // visibility flag means visible, without introducing bounds filtering.
        guard !geometry.isEmpty else { return true }
        let bounds = Self.geometry(at: time, samples: geometry, fallback: fallback)
        guard let current = Self.geometrySample(at: time, samples: geometry) else {
            return Self.contains(sample.x, sample.y, in: bounds)
        }
        return current.available && Self.contains(sample.x, sample.y, in: bounds)
    }

    /// Interpolate the cursor, returning nil during hidden/off-target periods.
    public func interpolateIfVisible(at time: TimeInterval) -> Point2D? {
        guard !samples.isEmpty else { return nil }
        guard let raw = latestRawSample(at: time),
              Self.isVisible(raw, at: time, geometry: targetGeometry, fallback: displayBounds)
        else { return nil }
        return interpolate(at: time)
    }

    /// Spring-smoothed velocity in UV units per second. Returns nil whenever
    /// the cursor itself is hidden so preview and export gate motion blur with
    /// the same visibility rule.
    public func velocityIfVisible(at time: TimeInterval) -> Point2D? {
        guard isVisible(at: time) else { return nil }
        return velocity(at: time)
    }

    /// Whether a cursor overlay should be shown at time.
    public func isVisible(at time: TimeInterval) -> Bool {
        guard let raw = latestRawSample(at: time) else { return false }
        return Self.isVisible(raw, at: time, geometry: targetGeometry, fallback: displayBounds)
    }

    private func latestRawSample(at time: TimeInterval) -> CursorSample? {
        guard !rawSamples.isEmpty else { return nil }
        guard time >= rawSamples[0].t else { return nil }
        var lo = 0
        var hi = rawSamples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rawSamples[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        return rawSamples[max(0, lo - 1)]
    }

    private static func filterClicks(
        _ clicks: [ClickSample],
        samples: [CursorSample],
        geometry: [TargetGeometrySample],
        fallback: Rect2D
    ) -> [ClickSample] {
        guard !samples.isEmpty else { return clicks }
        return clicks.filter { click in
            var lo = 0
            var hi = samples.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if samples[mid].t <= click.t { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return geometry.isEmpty }
            let sample = samples[lo - 1]
            return isVisible(sample, at: click.t, geometry: geometry, fallback: fallback)
        }
    }

    private static func geometrySample(
        at time: TimeInterval,
        samples: [TargetGeometrySample]
    ) -> TargetGeometrySample? {
        guard !samples.isEmpty else { return nil }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        return samples[lo - 1]
    }

    private static func geometry(
        at time: TimeInterval,
        samples: [TargetGeometrySample],
        fallback: Rect2D
    ) -> Rect2D {
        guard let sample = geometrySample(at: time, samples: samples), sample.available else {
            return fallback
        }
        return sample.bounds
    }

    private static func contains(_ x: Double, _ y: Double, in bounds: Rect2D) -> Bool {
        x >= bounds.x && x <= bounds.x + bounds.width
            && y >= bounds.y && y <= bounds.y + bounds.height
    }

    /// Spring-smoothed cursor UV at `time` seconds from recording start.
    /// Returns the frame center when there is no telemetry.
    public func interpolate(at time: TimeInterval) -> Point2D {
        guard !samples.isEmpty else {
            return Point2D(x: 0.5, y: 0.5)
        }

        let query = time
        if query <= samples[0].time {
            return samples[0].position
        }

        let i = Self.index(in: samples, at: query)
        let sample = samples[i]
        let dt = query - sample.time
        if dt <= 1e-12 {
            return sample.position
        }

        var state = SpringState2D(
            posU: sample.position.x,
            posV: sample.position.y,
            velU: sample.velocity.x,
            velV: sample.velocity.y,
            targetU: sample.target.x,
            targetV: sample.target.y
        )
        SpringSolver.step(&state, dt: dt, config: .cursorDefault)
        return Point2D(
            x: Self.clamp01(state.posU),
            y: Self.clamp01(state.posV)
        )
    }

    /// Spring-smoothed cursor velocity in UV units per second.
    public func velocity(at time: TimeInterval) -> Point2D {
        guard !samples.isEmpty else { return Point2D(x: 0, y: 0) }
        if time <= samples[0].time { return samples[0].velocity }

        let sample = samples[Self.index(in: samples, at: time)]
        let dt = time - sample.time
        if dt <= 1e-12 { return sample.velocity }

        var state = SpringState2D(
            posU: sample.position.x,
            posV: sample.position.y,
            velU: sample.velocity.x,
            velV: sample.velocity.y,
            targetU: sample.target.x,
            targetV: sample.target.y
        )
        SpringSolver.step(&state, dt: dt, config: .cursorDefault)
        return Point2D(x: state.velU, y: state.velV)
    }

    /// Whether the primary button is down at `time` (last click event at or before `time`).
    public func isClicking(at time: TimeInterval) -> Bool {
        clickState(at: time).isDown
    }

    /// Primary-button down flag and, when down, seconds since that press.
    /// Same semantics as `isClicking` plus `ExportLayout.primaryClickAge`.
    public func clickState(at time: TimeInterval) -> (isDown: Bool, age: TimeInterval?) {
        ExportLayout.primaryClickState(at: time, clicks: primaryClicks)
    }

    // MARK: - Shake filter

    private struct Move {
        var time: TimeInterval
        var uv: Point2D
        var visible: Bool = true
    }

    private static let shakeThresholdPoints = 4.0
    private static let shakeWindow: TimeInterval = 0.1
    private static let emaTimeConstant: TimeInterval = 0.03
    private static let frameDt: TimeInterval = 1.0 / 60.0
    private static let gapThreshold: TimeInterval = frameDt * 4
    private static let minTravelForInterp = 0.02
    private static let maxInterpSteps = 120
    private static let clickReactionWindow: TimeInterval = 0.160

    private static func filterShake(_ moves: [Move], displayBounds: Rect2D) -> [Move] {
        guard moves.count >= 3 else { return moves }

        var filtered: [Move] = [moves[0]]
        var i = 1
        while i < moves.count - 1 {
            let prev = filtered[filtered.count - 1]
            let curr = moves[i]
            let next = moves[i + 1]

            if next.time - prev.time > shakeWindow {
                filtered.append(curr)
                i += 1
                continue
            }

            let dxToCurr = curr.uv.x - prev.uv.x
            let dyToCurr = curr.uv.y - prev.uv.y
            let dxToNext = next.uv.x - curr.uv.x
            let dyToNext = next.uv.y - curr.uv.y
            let reversal = dxToCurr * dxToNext + dyToCurr * dyToNext < 0
            let small =
                pointDistance(from: prev.uv, to: curr.uv, displayBounds: displayBounds)
                    < shakeThresholdPoints
                && pointDistance(from: curr.uv, to: next.uv, displayBounds: displayBounds)
                    < shakeThresholdPoints

            if reversal && small {
                i += 1
                continue
            }

            filtered.append(curr)
            i += 1
        }

        if moves.count > 1 {
            filtered.append(moves[moves.count - 1])
        }
        return filtered
    }

    /// First-order low-pass on UV (short EMA) so same-direction jitter does not drive the spring.
    private static func smoothEMA(_ moves: [Move]) -> [Move] {
        guard moves.count >= 2 else { return moves }
        var out: [Move] = [moves[0]]
        var prev = moves[0]
        for i in 1..<moves.count {
            let move = moves[i]
            let dt = max(move.time - prev.time, 1e-6)
            let alpha = 1 - exp(-dt / emaTimeConstant)
            let smoothed = Move(
                time: move.time,
                uv: Point2D(
                    x: clamp01(prev.uv.x + (move.uv.x - prev.uv.x) * alpha),
                    y: clamp01(prev.uv.y + (move.uv.y - prev.uv.y) * alpha)
                )
            )
            out.append(smoothed)
            prev = smoothed
        }
        return out
    }

    private static func pointDistance(from a: Point2D, to b: Point2D, displayBounds: Rect2D) -> Double {
        hypot(
            (b.x - a.x) * displayBounds.width,
            (b.y - a.y) * displayBounds.height
        )
    }

    private static func shouldFill(from: Move, to: Move) -> Bool {
        let dt = max(0, to.time - from.time)
        guard dt >= gapThreshold else { return false }
        return hypot(to.uv.x - from.uv.x, to.uv.y - from.uv.y) >= minTravelForInterp
    }

    private static func densify(_ moves: [Move]) -> [Move] {
        guard moves.count >= 2 else { return moves }
        let needsFill = (1..<moves.count).contains { shouldFill(from: moves[$0 - 1], to: moves[$0]) }
        guard needsFill else { return moves }

        var dense: [Move] = [moves[0]]
        for i in 0..<(moves.count - 1) {
            let from = moves[i]
            let to = moves[i + 1]
            if shouldFill(from: from, to: to) {
                let dt = max(0, to.time - from.time)
                let steps = min(max(2, Int(ceil(dt / frameDt))), maxInterpSteps)
                if steps > 1 {
                    for step in 1..<steps {
                        let t = Double(step) / Double(steps)
                        dense.append(
                            Move(
                                time: from.time + dt * t,
                                uv: Point2D(
                                    x: from.uv.x + (to.uv.x - from.uv.x) * t,
                                    y: from.uv.y + (to.uv.y - from.uv.y) * t
                                )
                            )
                        )
                    }
                }
            }
            dense.append(to)
        }
        return dense
    }

    private static func simulate(moves: [Move], clicks: [ClickSample]) -> [Sample] {
        guard let first = moves.first else { return [] }

        var state = SpringState2D.rest(at: first.uv)
        var config = SpringConfig.cursorDefault
        var samples: [Sample] = []
        var lastTime: TimeInterval = 0
        var nextClick = 0
        var lastClickTime: TimeInterval?
        var primaryDown = false

        func advanceClicks(to time: TimeInterval) {
            while nextClick < clicks.count, clicks[nextClick].t <= time {
                lastClickTime = clicks[nextClick].t
                if clicks[nextClick].button == .left || clicks[nextClick].button == .other {
                    primaryDown = clicks[nextClick].down
                }
                nextClick += 1
            }
        }

        func profile(at time: TimeInterval) -> SpringConfig {
            if let lastClickTime, abs(time - lastClickTime) <= clickReactionWindow {
                return .cursorSnappy
            }
            if primaryDown { return .cursorDrag }
            return .cursorDefault
        }

        if first.time > 0 {
            samples.append(
                Sample(
                    time: 0,
                    position: first.uv,
                    velocity: Point2D(x: 0, y: 0),
                    target: first.uv,
                    visible: true
                )
            )
        }

        for move in moves {
            state.targetU = move.uv.x
            state.targetV = move.uv.y
            advanceClicks(to: move.time)
            config = profile(at: move.time)
            SpringSolver.step(&state, dt: move.time - lastTime, config: config)
            lastTime = move.time
            samples.append(
                Sample(
                    time: move.time,
                    position: Point2D(x: Self.clamp01(state.posU), y: Self.clamp01(state.posV)),
                    velocity: Point2D(x: state.velU, y: state.velV),
                    target: move.uv,
                    visible: move.visible
                )
            )
        }

        return samples
    }

    /// Last sample with `time <= query`, or 0 if all are later.
    private static func index(in samples: [Sample], at query: TimeInterval) -> Int {
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time <= query {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return max(0, lo - 1)
    }

    static func clamp01(_ v: Double) -> Double {
        min(1, max(0, v))
    }
}
