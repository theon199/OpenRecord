import Foundation

/// Spring-mass-damper parameters. `tension` is stiffness *k*, `friction` is damping *c*.
///
/// Damping ratio ζ = friction / (2√(tension·mass)). ζ < 1 underdamped, ζ ≈ 1 critical, ζ > 1 overdamped.
///
/// Presets follow the MIT screen-studio-effects / Cap analytical spring model (rewritten, not vendored).
public struct SpringConfig: Sendable, Hashable {
    public var tension: Double
    public var mass: Double
    public var friction: Double

    public init(tension: Double, mass: Double, friction: Double) {
        self.tension = tension
        self.mass = mass
        self.friction = friction
    }

    public var omega0: Double {
        sqrt(max(tension, 0) / max(mass, 0.001))
    }

    public var zeta: Double {
        let m = max(mass, 0.001)
        let k = max(tension, 1e-12)
        return friction / (2 * sqrt(k * m))
    }

    /// Natural cursor follow (slightly bouncy).
    public static let cursorDefault = SpringConfig(tension: 170, mass: 1, friction: 20)
    /// Tight response inside the click-reaction window.
    public static let cursorSnappy = SpringConfig(tension: 700, mass: 1, friction: 30)
    /// Heavier feel while the primary button is held.
    public static let cursorDrag = SpringConfig(tension: 136, mass: 1.2, friction: 26)
    /// Snappy viewport pan.
    public static let viewportFocused = SpringConfig(tension: 300, mass: 6.75, friction: 120)
    /// Cinematic viewport pan.
    public static let viewportSmooth = SpringConfig(tension: 240, mass: 3.375, friction: 80)
    /// Slower, weightier viewport pan for the Cinematic preset.
    public static let viewportCinematic = SpringConfig(tension: 160, mass: 5, friction: 75)
    /// Fast zoom amount response with a small amount of spring character.
    public static let zoomTransitionFast = SpringConfig(tension: 320, mass: 1.5, friction: 35)
    /// Zoom in/out amount easing.
    public static let zoomTransition = SpringConfig(tension: 200, mass: 2.25, friction: 40)
    /// Deliberate, near-critically-damped zoom amount response.
    public static let zoomTransitionCinematic = SpringConfig(tension: 110, mass: 3.5, friction: 39)
}

public extension ZoomEasingPreset {
    var zoomInDuration: TimeInterval {
        switch self {
        case .fast: 0.55
        case .smooth: 0.85
        case .cinematic: 1.25
        }
    }

    var zoomOutDuration: TimeInterval {
        switch self {
        case .fast: 0.8
        case .smooth: 1.35
        case .cinematic: 1.9
        }
    }

    var zoomSpring: SpringConfig {
        switch self {
        case .fast: .zoomTransitionFast
        case .smooth: .zoomTransition
        case .cinematic: .zoomTransitionCinematic
        }
    }

    var viewportSpring: SpringConfig {
        switch self {
        case .fast: .viewportFocused
        case .smooth: .viewportSmooth
        case .cinematic: .viewportCinematic
        }
    }
}

/// 2D spring body in UV space.
public struct SpringState2D: Sendable, Hashable {
    public var posU: Double
    public var posV: Double
    public var velU: Double
    public var velV: Double
    public var targetU: Double
    public var targetV: Double

    public init(
        posU: Double,
        posV: Double,
        velU: Double = 0,
        velV: Double = 0,
        targetU: Double,
        targetV: Double
    ) {
        self.posU = posU
        self.posV = posV
        self.velU = velU
        self.velV = velV
        self.targetU = targetU
        self.targetV = targetV
    }

    public var position: Point2D {
        Point2D(x: posU, y: posV)
    }

    public static func rest(at point: Point2D) -> SpringState2D {
        SpringState2D(
            posU: point.x,
            posV: point.y,
            targetU: point.x,
            targetV: point.y
        )
    }
}

/// Closed-form damped harmonic oscillator. Stable at any timestep; identical for a fixed input.
public enum SpringSolver: Sendable {
    public static let criticalEpsilon = 0.01
    public static let restVelocityThreshold = 0.0001
    public static let restDisplacementThreshold = 0.00001

    /// Exact 1D solution. Returns displacement and velocity relative to the target after `t` seconds.
    public static func solve1D(
        displacement: Double,
        velocity: Double,
        time t: Double,
        omega0: Double,
        zeta: Double
    ) -> (displacement: Double, velocity: Double) {
        if t <= 0 {
            return (displacement, velocity)
        }

        if zeta < 1 - criticalEpsilon {
            let omegaD = omega0 * sqrt(max(0, 1 - zeta * zeta))
            let decay = exp(-zeta * omega0 * t)
            let cosT = cos(omegaD * t)
            let sinT = sin(omegaD * t)
            let a = displacement
            let b = (velocity + displacement * zeta * omega0) / max(omegaD, 1e-4)
            let newDisp = decay * (a * cosT + b * sinT)
            let newVel =
                decay
                * ((b * omegaD - a * zeta * omega0) * cosT
                    - (a * omegaD + b * zeta * omega0) * sinT)
            return (newDisp, newVel)
        }

        if zeta > 1 + criticalEpsilon {
            let sq = sqrt(max(0, zeta * zeta - 1))
            let s1 = -omega0 * (zeta - sq)
            let s2 = -omega0 * (zeta + sq)
            let denom = s1 - s2
            if abs(denom) < 1e-10 {
                let sAvg = 0.5 * (s1 + s2)
                let decay = exp(sAvg * t)
                let newDisp = decay * (displacement + (velocity - displacement * sAvg) * t)
                let newVel =
                    decay
                    * ((velocity - displacement * sAvg)
                        + sAvg * (displacement + (velocity - displacement * sAvg) * t))
                return (newDisp, newVel)
            }
            let c1 = (velocity - displacement * s2) / denom
            let c2 = displacement - c1
            let e1 = exp(s1 * t)
            let e2 = exp(s2 * t)
            return (c1 * e1 + c2 * e2, c1 * s1 * e1 + c2 * s2 * e2)
        }

        let decay = exp(-omega0 * t)
        let a = displacement
        let b = velocity + displacement * omega0
        return (decay * (a + b * t), decay * (b - omega0 * (a + b * t)))
    }

    /// Advance `state` by `dt` seconds toward its target. Snaps to rest below displacement/velocity thresholds.
    public static func step(_ state: inout SpringState2D, dt: TimeInterval, config: SpringConfig) {
        guard dt > 0 else { return }

        let omega0 = config.omega0
        let zeta = config.zeta
        let ndU = solve1D(
            displacement: state.posU - state.targetU,
            velocity: state.velU,
            time: dt,
            omega0: omega0,
            zeta: zeta
        )
        let ndV = solve1D(
            displacement: state.posV - state.targetV,
            velocity: state.velV,
            time: dt,
            omega0: omega0,
            zeta: zeta
        )

        state.posU = state.targetU + ndU.displacement
        state.posV = state.targetV + ndV.displacement
        state.velU = ndU.velocity
        state.velV = ndV.velocity

        let dispMag = hypot(ndU.displacement, ndV.displacement)
        let velMag = hypot(ndU.velocity, ndV.velocity)
        if dispMag < restDisplacementThreshold, velMag < restVelocityThreshold {
            state.posU = state.targetU
            state.posV = state.targetV
            state.velU = 0
            state.velV = 0
        }
    }

    /// Step from rest at `from` toward `to` over `elapsed` seconds.
    public static func settle(
        from: Point2D,
        to: Point2D,
        elapsed: TimeInterval,
        config: SpringConfig
    ) -> Point2D {
        var state = SpringState2D.rest(at: from)
        state.targetU = to.x
        state.targetV = to.y
        step(&state, dt: max(0, elapsed), config: config)
        return state.position
    }
}

enum SpringEasing {
    static func easeIn(_ t: Double, config: SpringConfig = .zoomTransition) -> Double {
        clampedEase(t, omega0: config.omega0, zeta: config.zeta)
    }

    static func easeOut(_ t: Double, config: SpringConfig = .zoomTransition) -> Double {
        clampedEase(t, omega0: config.omega0 * 0.9, zeta: config.zeta * 1.15)
    }

    private static func clampedEase(_ t: Double, omega0: Double, zeta: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        if zeta < 1 {
            let omegaD = omega0 * sqrt(max(0, 1 - zeta * zeta))
            let decay = exp(-zeta * omega0 * t)
            return 1 - decay * (cos(omegaD * t) + (zeta * omega0 / max(omegaD, 1e-4)) * sin(omegaD * t))
        }
        let decay = exp(-omega0 * t)
        return 1 - decay * (1 + omega0 * t)
    }
}
