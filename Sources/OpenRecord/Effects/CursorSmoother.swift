import Foundation

/// Precomputed spring-smoothed cursor path in UV space (origin top-left).
///
/// Pipeline: raw points → UV → jitter (shake) filter → densify gaps → analytical spring.
/// Sample at any time with `interpolate(at:)` (binary search + one spring step).
public struct CursorSmoother: Sendable {
    public struct Sample: Sendable, Hashable {
        public var time: TimeInterval
        public var position: Point2D
        public var velocity: Point2D
        public var target: Point2D
    }

    public let displayBounds: Rect2D
    public let samples: [Sample]
    public let clicks: [ClickSample]

    public var isEmpty: Bool { samples.isEmpty }

    public init(
        samples raw: [CursorSample],
        clicks: [ClickSample] = [],
        displayBounds: Rect2D
    ) {
        self.displayBounds = displayBounds
        self.clicks = clicks.sorted { $0.t < $1.t }

        let moves = raw
            .sorted { $0.t < $1.t }
            .map { Move(time: $0.t, uv: CursorSmoother.uv(x: $0.x, y: $0.y, displayBounds: displayBounds)) }

        let filtered = Self.filterShake(moves)
        let dense = Self.densify(filtered)
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

    /// Whether the primary button is down at `time` (last click event at or before `time`).
    public func isClicking(at time: TimeInterval) -> Bool {
        guard !clicks.isEmpty else { return false }
        var down = false
        for click in clicks {
            if click.t > time { break }
            if click.button == .left || click.button == .other {
                down = click.down
            }
        }
        return down
    }

    // MARK: - Shake filter

    private struct Move {
        var time: TimeInterval
        var uv: Point2D
    }

    private static let shakeThresholdUV = 0.015
    private static let shakeWindow: TimeInterval = 0.1
    private static let frameDt: TimeInterval = 1.0 / 60.0
    private static let gapThreshold: TimeInterval = frameDt * 4
    private static let minTravelForInterp = 0.02
    private static let maxInterpSteps = 120
    private static let clickReactionWindow: TimeInterval = 0.160

    private static func filterShake(_ moves: [Move]) -> [Move] {
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
                hypot(dxToCurr, dyToCurr) < shakeThresholdUV
                && hypot(dxToNext, dyToNext) < shakeThresholdUV

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
                    target: first.uv
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
                    target: move.uv
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
