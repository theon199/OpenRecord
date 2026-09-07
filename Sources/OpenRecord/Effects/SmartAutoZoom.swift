import Foundation

/// Additional controls used by the v3 smart zoom generator.
///
/// `AutoZoomConfig` remains the compatibility configuration for the original
/// activity-island generator. Smart zooms deliberately have their own config so
/// regenerating a project can be introduced without changing the old presets.
public struct SmartAutoZoomConfig: Sendable, Hashable {
    public var base: AutoZoomConfig
    /// Minimum continuous dwell time before a still cursor is considered a
    /// target. Set `requireDwellEngagement` for workflows that classify only
    /// post-motion/post-click dwells as targets.
    public var minDwell: TimeInterval
    /// A still cursor counts as an intentional target only for this long. Past
    /// it the dwell is idle time: the range holds briefly and eases back out,
    /// and any later motion, click or typing opens a fresh range.
    public var maxDwell: TimeInterval
    /// Extra hold allowed after the cursor has stopped moving. Typing keeps its
    /// own reading hold; clicks, dwells and transit ease out once this grace
    /// elapses so a long idle pause does not stay zoomed in.
    public var idleZoomOut: TimeInterval
    /// Minimum time between the end of a dwell and the next activity island.
    public var dwellPadding: TimeInterval
    /// Speeds above this value are treated as transit when an island is too
    /// short to be useful. Units are capture points per second.
    public var transitVelocity: Double
    /// Minimum useful span for a transit island. Clicks and dwells bypass this
    /// filter because they represent intentional targets.
    public var minTransitDuration: TimeInterval
    /// Nearby interactions are clustered in UV space to keep the camera from
    /// oscillating between adjacent controls.
    public var clusterRadius: Double
    /// Small ranges are discarded after clustering.
    public var minUsefulDuration: TimeInterval
    /// Keep anchor centers away from canvas edges. This is intentionally
    /// conservative because crop clamping alone can put the cursor on an edge.
    public var edgeSafeInset: Double
    /// Retained for configuration compatibility. Generated ranges now follow
    /// the cursor regardless of motion length; only typing bursts whose
    /// pointer stays in frame receive a fixed anchor.
    public var followCursorDuration: TimeInterval
    /// When true, only post-motion/post-click dwells are targets. This is the
    /// compatibility switch used by callers that still treat a long reading
    /// pause as silence; v3 defaults to using dwell as an intentional signal.
    public var requireDwellEngagement: Bool
    /// Hold time after typing finishes so viewers have time to read the text.
    public var typingHold: TimeInterval
    /// Lead-in time before the first keystroke of a typing burst.
    public var typingLeadIn: TimeInterval
    /// Minimum sustained duration for pure cursor motion to trigger a zoom.
    /// Casual pointer sweeps shorter than this without a click or dwell are dropped.
    public var minMotionEngagement: TimeInterval
    /// Whether hold time scales proportionally with engagement duration.
    public var dynamicHoldScaling: Bool

    public init(
        base: AutoZoomConfig = .default,
        minDwell: TimeInterval = 0.75,
        maxDwell: TimeInterval = 1.6,
        idleZoomOut: TimeInterval = 0.45,
        dwellPadding: TimeInterval = 0.2,
        transitVelocity: Double = 1_400,
        minTransitDuration: TimeInterval = 0.28,
        clusterRadius: Double = 0.085,
        minUsefulDuration: TimeInterval = 0.35,
        edgeSafeInset: Double = 0.14,
        followCursorDuration: TimeInterval = 1.8,
        requireDwellEngagement: Bool = false,
        typingHold: TimeInterval = 2.0,
        typingLeadIn: TimeInterval = 0.25,
        minMotionEngagement: TimeInterval = 0.6,
        dynamicHoldScaling: Bool = true
    ) {
        self.base = base
        self.minDwell = max(0, minDwell)
        self.maxDwell = max(self.minDwell, maxDwell)
        self.idleZoomOut = max(0, idleZoomOut)
        self.dwellPadding = max(0, dwellPadding)
        self.transitVelocity = max(0, transitVelocity)
        self.minTransitDuration = max(0, minTransitDuration)
        self.clusterRadius = max(0, clusterRadius)
        self.minUsefulDuration = max(0, minUsefulDuration)
        self.edgeSafeInset = min(0.49, max(0, edgeSafeInset))
        self.followCursorDuration = max(0, followCursorDuration)
        self.requireDwellEngagement = requireDwellEngagement
        self.typingHold = max(0, typingHold)
        self.typingLeadIn = max(0, typingLeadIn)
        self.minMotionEngagement = max(0, minMotionEngagement)
        self.dynamicHoldScaling = dynamicHoldScaling
    }

    public static let `default` = SmartAutoZoomConfig()
}

/// Deterministic v3 automatic framing.
///
/// The generator intentionally has no wall-clock state: identical telemetry,
/// geometry and config always produce identical ranges. `AutoZoom` remains the
/// compatibility entry point, while this type is used by v3 regeneration and
/// by clients that want dwell-aware framing.
public enum SmartAutoZoom: Sendable {
    /// Short alias for callers that do not need to distinguish this from the
    /// legacy activity-island implementation.
    public static func generate(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        generateRanges(
            samples: samples,
            clicks: clicks,
            typing: typing,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry
        )
    }

    /// Build ranges from cursor motion, dwell, clicks, typing and target geometry.
    public static func generateRanges(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        let end = max(0, duration)
        guard end > 0 else { return [] }

        let visibleSamples = AutoZoom.visibleSamples(
            samples,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ).sorted { $0.t < $1.t }
        let visibleClicks = AutoZoom.visibleClicks(
            clicks,
            samples: samples,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ).sorted { $0.t < $1.t }
        let downs = visibleClicks.filter(\.down)

        var signals: [Signal] = []
        signals.append(contentsOf: typingSignals(
            typing: typing,
            samples: visibleSamples,
            duration: end,
            config: config,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ))
        signals.append(contentsOf: motionSignals(
            samples: visibleSamples,
            clicks: downs,
            duration: end,
            config: config,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ))
        signals.append(contentsOf: dwellSignals(
            samples: visibleSamples,
            clicks: downs,
            duration: end,
            config: config,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ))
        let merged = mergeSignals(
            signals,
            gap: config.base.mergeGap,
            clusterRadius: config.clusterRadius
        )
        let useful = merged.filter { signal in
            let span = signal.end - signal.start
            guard span >= config.minUsefulDuration else {
                return signal.kind == .click || signal.kind == .dwell || signal.kind == .typing
            }
            // Fast pointer motion is transit, not a useful target. Do not
            // apply this to click/dwell/typing clusters: their intent is explicit.
            if signal.kind == .transit,
               signal.velocity >= config.transitVelocity
            {
                return false
            }
            // Casual pointer movement across the screen without an intentional interaction
            if signal.kind == .transit, span < config.minMotionEngagement {
                return false
            }
            return true
        }
        let held = expandSignals(
            useful,
            minHold: config.base.minZoomHold,
            duration: end,
            config: config,
            samples: visibleSamples,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        )

        return held.enumerated().map { index, signal in
            let anchor = stableAnchor(
                signal: signal,
                samples: visibleSamples,
                clicks: downs,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry,
                config: config
            )
            var range = ZoomRange(
                id: stableID(
                    start: signal.start,
                    end: signal.end,
                    anchor: anchor,
                    salt: index
                ),
                start: signal.start,
                end: signal.end,
                amount: max(1, config.base.zoomAmount),
                anchor: anchor
            )
            // These fields are filled by the v3 ZoomRange contract. Keeping
            // construction in one place makes legacy migration straightforward
            // and prevents accidental manual ranges during regeneration.
            range.source = .automatic
            range.tracking = trackingMode(
                for: signal,
                anchor: anchor,
                amount: range.amount,
                samples: visibleSamples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry,
                config: config
            )
            return range
        }
    }

    /// Regenerate automatic ranges while preserving explicitly locked/manual
    /// ranges. Preserved ranges are treated as obstacles; generated ranges are
    /// clipped around them and then re-expanded to the requested hold time when
    /// there is room. Input and output ordering are deterministic.
    public static func regenerateRanges(
        existing: [ZoomRange],
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = [],
        preserveLockedAndManual: Bool = true
    ) -> [ZoomRange] {
        let generated = generateRanges(
            samples: samples,
            clicks: clicks,
            typing: typing,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry
        )
        guard preserveLockedAndManual else {
            return generated.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        }

        let preserved = existing.filter { $0.isLocked || $0.source == .manual }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        guard !preserved.isEmpty else { return generated }

        var clipped: [ZoomRange] = []
        for candidate in generated {
            var pieces: [(TimeInterval, TimeInterval)] = [(candidate.start, candidate.end)]
            for obstacle in preserved {
                var next: [(TimeInterval, TimeInterval)] = []
                for piece in pieces {
                    if obstacle.end <= piece.0 || obstacle.start >= piece.1 {
                        next.append(piece)
                    } else {
                        if piece.0 < obstacle.start { next.append((piece.0, obstacle.start)) }
                        if obstacle.end < piece.1 { next.append((obstacle.end, piece.1)) }
                    }
                }
                pieces = next
            }
            for (start, end) in pieces where end - start >= config.minUsefulDuration {
                var piece = candidate
                piece.id = stableID(
                    start: start,
                    end: end,
                    anchor: candidate.anchor,
                    salt: Int(truncatingIfNeeded: candidate.start.bitPattern)
                )
                piece.start = start
                piece.end = end
                clipped.append(piece)
            }
        }
        return (preserved + clipped).sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
    }

    public static func regenerate(
        existing: [ZoomRange],
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = [],
        preserveLockedAndManual: Bool = true
    ) -> [ZoomRange] {
        regenerateRanges(
            existing: existing,
            samples: samples,
            clicks: clicks,
            typing: typing,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry,
            preserveLockedAndManual: preserveLockedAndManual
        )
    }

    // MARK: Signals

    private enum SignalKind: Int {
        case transit = 0
        case dwell = 1
        case click = 2
        case typing = 3
    }

    private struct Signal {
        var start: TimeInterval
        var end: TimeInterval
        var anchorTime: TimeInterval
        var kind: SignalKind
        var velocity: Double
        var anchor: Point2D?
        /// Set when signals with anchors farther apart than the cluster radius
        /// were folded into one range. Such a range spans more than one place
        /// on screen, so the camera must follow the cursor rather than pin the
        /// strongest signal's anchor.
        var mixedAnchors = false
    }

    private static func typingSignals(
        typing: [TypingSample],
        samples: [CursorSample],
        duration: TimeInterval,
        config: SmartAutoZoomConfig,
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [Signal] {
        guard !typing.isEmpty else { return [] }
        let sorted = typing.sorted { $0.t < $1.t }

        var bursts: [(start: TimeInterval, end: TimeInterval, sample: TypingSample)] = []
        var cur: (start: TimeInterval, end: TimeInterval, sample: TypingSample)?

        for sample in sorted {
            if let c = cur {
                if sample.t <= c.end + 1.2 {
                    cur = (c.start, sample.t, c.sample)
                } else {
                    bursts.append(c)
                    cur = (sample.t, sample.t, sample)
                }
            } else {
                cur = (sample.t, sample.t, sample)
            }
        }
        if let c = cur { bursts.append(c) }

        return bursts.map { burst in
            let burstStart = max(0, burst.start - config.typingLeadIn)
            let burstEnd = min(duration, burst.end)

            let rawAnchor: Point2D
            if let w = burst.sample.width, let h = burst.sample.height, w > 0, h > 0 {
                let targetX = burst.sample.x + min(w * 0.35, 120)
                let targetY = burst.sample.y + h * 0.5
                rawAnchor = CursorSmoother.uv(x: targetX, y: targetY, displayBounds: displayBounds)
            } else {
                rawAnchor = CursorSmoother.uv(x: burst.sample.x, y: burst.sample.y, displayBounds: displayBounds)
            }

            let safeX = min(1 - config.edgeSafeInset, max(config.edgeSafeInset, rawAnchor.x))
            let safeY = min(1 - config.edgeSafeInset, max(config.edgeSafeInset, rawAnchor.y))
            let anchor = Point2D(x: safeX, y: safeY)

            return Signal(
                start: burstStart,
                end: burstEnd,
                anchorTime: burst.start,
                kind: .typing,
                velocity: 0,
                anchor: anchor
            )
        }
    }

    private static func motionSignals(
        samples: [CursorSample],
        clicks: [ClickSample],
        duration: TimeInterval,
        config: SmartAutoZoomConfig,
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [Signal] {
        guard samples.count >= 2 else { return [] }
        var intervals: [Signal] = []
        for pair in zip(samples, samples.dropFirst()) {
            let a = pair.0
            let b = pair.1
            let dt = b.t - a.t
            guard dt > 0 else { continue }
            let auv = AutoZoom.nearestUV(
                at: a.t,
                samples: samples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            ) ?? .init(x: 0.5, y: 0.5)
            let buv = AutoZoom.nearestUV(
                at: b.t,
                samples: samples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            ) ?? .init(x: 0.5, y: 0.5)
            let dx = (buv.x - auv.x) * displayBounds.width
            let dy = (buv.y - auv.y) * displayBounds.height
            let distance = hypot(dx, dy)
            let velocity = distance / dt
            guard distance >= config.base.stillDisplacementPoints else { continue }
            intervals.append(Signal(
                start: max(0, a.t),
                end: min(duration, b.t),
                anchorTime: a.t,
                kind: .transit,
                velocity: velocity,
                anchor: auv
            ))
        }
        // Clicks break a transit into intentional activity even if the pointer
        // crosses the target at high speed.
        for click in clicks {
            intervals.append(Signal(
                start: max(0, click.t - config.base.clickPaddingBefore),
                end: min(duration, click.t + config.base.clickPaddingAfter),
                anchorTime: click.t,
                kind: .click,
                velocity: 0,
                anchor: AutoZoom.nearestUV(
                    at: click.t,
                    samples: samples,
                    displayBounds: displayBounds,
                    targetGeometry: targetGeometry
                )
            ))
        }
        return intervals
    }

    private static func dwellSignals(
        samples: [CursorSample],
        clicks: [ClickSample],
        duration: TimeInterval,
        config: SmartAutoZoomConfig,
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [Signal] {
        guard config.minDwell > 0, samples.count >= 2 else { return [] }
        var out: [Signal] = []
        var runStart = 0
        for index in 1...samples.count {
            let atEnd = index == samples.count
            let same: Bool
            if atEnd {
                same = false
            } else {
                let a = samples[index - 1]
                let b = samples[index]
                let auv = AutoZoom.nearestUV(at: a.t, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry) ?? .init(x: 0.5, y: 0.5)
                let buv = AutoZoom.nearestUV(at: b.t, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry) ?? .init(x: 0.5, y: 0.5)
                same = hypot(auv.x - buv.x, auv.y - buv.y) <= 0.004
            }
            if same { continue }
            let start = samples[runStart].t
            let fullEnd = samples[index - 1].t
            let span = fullEnd - start
            // Only the first `maxDwell` of a still cursor is a target; the
            // rest is idle time and should let the zoom ease back out.
            let end = min(fullEnd, start + config.maxDwell)
            if span >= config.minDwell {
                let arrivedByMotion = runStart > 0 && samples[runStart - 1].t < start
                let nearbyClick = clicks.contains { abs($0.t - start) <= config.dwellPadding || ($0.t >= start && $0.t <= end) }
                if !config.requireDwellEngagement || arrivedByMotion || nearbyClick {
                    out.append(Signal(
                        start: max(0, start),
                        end: min(duration, end),
                        anchorTime: start + min(config.minDwell, span) * 0.5,
                        kind: .dwell,
                        velocity: 0,
                        anchor: AutoZoom.nearestUV(
                            at: start,
                            samples: samples,
                            displayBounds: displayBounds,
                            targetGeometry: targetGeometry
                        )
                    ))
                }
            }
            runStart = index
        }
        return out
    }

    private static func mergeSignals(
        _ signals: [Signal],
        gap: TimeInterval,
        clusterRadius: Double = .infinity
    ) -> [Signal] {
        let ordered = signals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }
        var result: [Signal] = []
        for next in ordered.dropFirst() {
            let closeInTime = next.start <= current.end + gap
            let closeInSpace = anchorsAreClose(current, next, radius: clusterRadius)
            let sameTransit = current.kind == .transit && next.kind == .transit
            if closeInTime && (sameTransit || closeInSpace) {
                current.end = max(current.end, next.end)
                if next.kind.rawValue > current.kind.rawValue {
                    current.kind = next.kind
                    current.anchorTime = next.anchorTime
                }
                current.velocity = max(current.velocity, next.velocity)
                current.mixedAnchors = current.mixedAnchors || next.mixedAnchors || !closeInSpace
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func expandSignals(
        _ signals: [Signal],
        minHold: TimeInterval,
        duration: TimeInterval,
        config: SmartAutoZoomConfig,
        samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [Signal] {
        guard minHold > 0 else { return signals }
        var result = signals.map { signal -> Signal in
            let activeSpan = signal.end - signal.start
            var value = signal
            let idle = cursorIsIdle(
                after: value.end,
                samples: samples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            )

            if config.dynamicHoldScaling {
                let holdAfter: TimeInterval
                switch signal.kind {
                case .typing:
                    // Reading hold is intentional even when the pointer is still.
                    holdAfter = config.typingHold
                case .click:
                    holdAfter = idle
                        ? config.idleZoomOut
                        : min(config.base.minZoomHold, 1.4)
                case .dwell:
                    holdAfter = config.idleZoomOut
                case .transit:
                    holdAfter = idle
                        ? config.idleZoomOut
                        : min(config.base.minZoomHold, max(1.2, 1.2 + 0.4 * (activeSpan - 0.6)))
                }
                let extendEnd = min(holdAfter, max(0, duration - value.end))
                value.end += extendEnd

                let currentSpan = value.end - value.start
                if currentSpan < minHold {
                    let needed = minHold - currentSpan
                    value.start = max(0, value.start - needed)
                    let stillNeeded = minHold - (value.end - value.start)
                    if stillNeeded > 0 {
                        let extra = (signal.kind == .typing || !idle)
                            ? stillNeeded
                            : min(stillNeeded, config.idleZoomOut)
                        value.end = min(duration, value.end + extra)
                    }
                }
            } else {
                if activeSpan < minHold {
                    let needed = minHold - activeSpan
                    let after = min(needed, max(0, duration - value.end))
                    let extra = (signal.kind == .typing || !idle)
                        ? after
                        : min(after, config.idleZoomOut)
                    value.end += extra
                    let remaining = minHold - (value.end - value.start)
                    if remaining > 0 {
                        value.start = max(0, value.start - remaining)
                    }
                }
            }
            return value
        }
        result.sort { $0.start < $1.start }
        // Hold expansion can make otherwise independent islands overlap. A
        // generated set must remain non-overlapping; preserve the strongest
        // intent (typing > click > dwell > transit) and the first stable anchor.
        guard var current = result.first else { return [] }
        var coalesced: [Signal] = []
        for next in result.dropFirst() {
            if next.start < current.end {
                let close = anchorsAreClose(current, next, radius: config.clusterRadius)
                current.end = max(current.end, next.end)
                if next.kind.rawValue > current.kind.rawValue {
                    current.kind = next.kind
                    current.anchorTime = next.anchorTime
                    current.anchor = next.anchor
                }
                current.velocity = max(current.velocity, next.velocity)
                current.mixedAnchors = current.mixedAnchors || next.mixedAnchors || !close
            } else {
                coalesced.append(current)
                current = next
            }
        }
        coalesced.append(current)
        return coalesced
    }

    private static func stableAnchor(
        signal: Signal,
        samples: [CursorSample],
        clicks: [ClickSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample],
        config: SmartAutoZoomConfig
    ) -> Point2D {
        if signal.kind == .typing, let anchor = signal.anchor {
            return anchor
        }
        let anchorTime = clicks.first(where: { $0.t >= signal.start && $0.t <= signal.end })?.t ?? signal.anchorTime
        let anchor = AutoZoom.nearestUV(
            at: anchorTime,
            samples: samples,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ) ?? .init(x: 0.5, y: 0.5)
        let x = min(1 - config.edgeSafeInset, max(config.edgeSafeInset, anchor.x))
        let y = min(1 - config.edgeSafeInset, max(config.edgeSafeInset, anchor.y))
        return Point2D(x: x, y: y)
    }

    private static func anchorsAreClose(_ a: Signal, _ b: Signal, radius: Double) -> Bool {
        guard let pa = a.anchor, let pb = b.anchor else { return true }
        return hypot(pa.x - pb.x, pa.y - pb.y) <= radius
    }

    /// True when the pointer stays put after `time` — the cue to ease zoom out
    /// instead of holding the last target through a long pause.
    private static func cursorIsIdle(
        after time: TimeInterval,
        samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> Bool {
        guard let origin = AutoZoom.nearestUV(
            at: time,
            samples: samples,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ) else {
            return true
        }
        let later = samples.filter { $0.t > time + 0.04 && $0.t <= time + 0.8 }
        if later.isEmpty { return true }
        return later.allSatisfy { sample in
            let uv = AutoZoom.nearestUV(
                at: sample.t,
                samples: samples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            ) ?? origin
            return hypot(uv.x - origin.x, uv.y - origin.y) <= 0.004
        }
    }

    /// Ranges follow the cursor by default: the follow-cam's deadzone keeps a
    /// still cursor perfectly stable, while a fixed anchor can strand the
    /// viewer looking at a spot the cursor has already left. The only fixed
    /// framing is a typing burst, where the text box (not the pointer) is the
    /// subject, and only when the pointer never leaves that frame.
    private static func trackingMode(
        for signal: Signal,
        anchor: Point2D,
        amount: Double,
        samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample],
        config: SmartAutoZoomConfig
    ) -> ZoomTrackingMode {
        guard signal.kind == .typing, !signal.mixedAnchors else { return .followCursor }
        return fixedAnchorKeepsCursorInFrame(
            anchor: anchor,
            amount: amount,
            samples: samples,
            start: signal.start,
            end: signal.end,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        ) ? .fixed : .followCursor
    }

    /// Whether every visible cursor sample inside `start...end` stays well
    /// inside the viewport a fixed range at `anchor` would show.
    static func fixedAnchorKeepsCursorInFrame(
        anchor: Point2D,
        amount: Double,
        samples: [CursorSample],
        start: TimeInterval,
        end: TimeInterval,
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> Bool {
        let half = 0.5 / max(amount, 1)
        // The engine clamps the center so the viewport stays on the canvas.
        let cx = min(1 - half, max(half, anchor.x))
        let cy = min(1 - half, max(half, anchor.y))
        let reach = half * 0.8
        let times = samples.map(\.t).filter { $0 >= start && $0 <= end } + [start, end]
        for time in times {
            guard let uv = AutoZoom.nearestUV(
                at: time,
                samples: samples,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            ) else { continue }
            if abs(uv.x - cx) > reach || abs(uv.y - cy) > reach {
                return false
            }
        }
        return true
    }

    /// UUID generation must not use UUID() for generated ranges: users often
    /// regenerate several times while tuning sensitivity, and stable IDs make
    /// the operation diffable and undo-friendly. The two FNV-style lanes are
    /// intentionally small but deterministic across processes/platforms.
    private static func stableID(start: TimeInterval, end: TimeInterval, anchor: Point2D, salt: Int) -> UUID {
        let values = [start, end, anchor.x, anchor.y]
        var first: UInt64 = 14_695_981_039_346_656_037 ^ UInt64(bitPattern: Int64(salt))
        let salted = salt &* 31 &+ 7
        var second: UInt64 = 10_995_116_282_111 ^ UInt64(bitPattern: Int64(salted))
        for value in values {
            let bits = value.bitPattern
            first ^= bits
            first = first &* 1_099_511_628_211
            second ^= bits &+ 0x9E37_79B9_7F4A_7C15
            second = second &* 1_099_511_628_211
        }
        let hex = String(format: "%016llx%016llx", first, second)
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(13).prefix(3))-8\(hex.dropFirst(17).prefix(3))-\(hex.dropFirst(20))"
        return UUID(uuidString: uuid) ?? UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    }
}

public extension AutoZoom {
    /// v3 opt-in generator. The original `generateRanges` remains available
    /// for compatibility and deterministic legacy projects.
    static func generateSmartRanges(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        SmartAutoZoom.generateRanges(
            samples: samples,
            clicks: clicks,
            typing: typing,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry
        )
    }

    static func regenerateSmartRanges(
        existing: [ZoomRange],
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        typing: [TypingSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = [],
        preserveLockedAndManual: Bool = true
    ) -> [ZoomRange] {
        SmartAutoZoom.regenerateRanges(
            existing: existing,
            samples: samples,
            clicks: clicks,
            typing: typing,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry,
            preserveLockedAndManual: preserveLockedAndManual
        )
    }
}
