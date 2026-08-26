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
    /// Treat a cluster with mostly stationary samples as a fixed target; use
    /// follow-cursor for longer motion clusters.
    public var followCursorDuration: TimeInterval
    /// When true, only post-motion/post-click dwells are targets. This is the
    /// compatibility switch used by callers that still treat a long reading
    /// pause as silence; v3 defaults to using dwell as an intentional signal.
    public var requireDwellEngagement: Bool

    public init(
        base: AutoZoomConfig = .default,
        minDwell: TimeInterval = 0.75,
        dwellPadding: TimeInterval = 0.2,
        transitVelocity: Double = 2_200,
        minTransitDuration: TimeInterval = 0.28,
        clusterRadius: Double = 0.085,
        minUsefulDuration: TimeInterval = 0.35,
        edgeSafeInset: Double = 0.14,
        followCursorDuration: TimeInterval = 1.8,
        requireDwellEngagement: Bool = false
    ) {
        self.base = base
        self.minDwell = max(0, minDwell)
        self.dwellPadding = max(0, dwellPadding)
        self.transitVelocity = max(0, transitVelocity)
        self.minTransitDuration = max(0, minTransitDuration)
        self.clusterRadius = max(0, clusterRadius)
        self.minUsefulDuration = max(0, minUsefulDuration)
        self.edgeSafeInset = min(0.49, max(0, edgeSafeInset))
        self.followCursorDuration = max(0, followCursorDuration)
        self.requireDwellEngagement = requireDwellEngagement
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
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        generateRanges(
            samples: samples,
            clicks: clicks,
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry
        )
    }

    /// Build ranges from cursor motion, dwell, clicks and target geometry.
    public static func generateRanges(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
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
                return signal.kind == .click || signal.kind == .dwell
            }
            // Fast pointer motion is transit, not a useful target. Do not
            // apply this to click/dwell clusters: their intent is explicit.
            if signal.kind == .transit,
               signal.velocity >= config.transitVelocity
            {
                return false
            }
            return true
        }
        let held = expandSignals(
            useful,
            minHold: config.base.minZoomHold,
            duration: end
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
            range.tracking = trackingMode(for: signal, config: config)
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
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = [],
        preserveLockedAndManual: Bool = true
    ) -> [ZoomRange] {
        let generated = generateRanges(
            samples: samples,
            clicks: clicks,
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
    }

    private struct Signal {
        var start: TimeInterval
        var end: TimeInterval
        var anchorTime: TimeInterval
        var kind: SignalKind
        var velocity: Double
        var anchor: Point2D?
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
            let end = samples[index - 1].t
            let span = end - start
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
            let closeInSpace: Bool
            if let a = current.anchor, let b = next.anchor {
                closeInSpace = hypot(a.x - b.x, a.y - b.y) <= clusterRadius
            } else {
                closeInSpace = true
            }
            let sameTransit = current.kind == .transit && next.kind == .transit
            if closeInTime && (sameTransit || closeInSpace) {
                current.end = max(current.end, next.end)
                if next.kind.rawValue > current.kind.rawValue {
                    current.kind = next.kind
                    current.anchorTime = next.anchorTime
                }
                current.velocity = max(current.velocity, next.velocity)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func expandSignals(_ signals: [Signal], minHold: TimeInterval, duration: TimeInterval) -> [Signal] {
        guard minHold > 0 else { return signals }
        var result = signals.map { signal -> Signal in
            let span = signal.end - signal.start
            guard span < minHold else { return signal }
            var value = signal
            let after = min(minHold - span, max(0, duration - value.end))
            value.end += after
            let remaining = minHold - (value.end - value.start)
            value.start = max(0, value.start - remaining)
            return value
        }
        result.sort { $0.start < $1.start }
        // Hold expansion can make otherwise independent islands overlap. A
        // generated set must remain non-overlapping; preserve the strongest
        // intent (click > dwell > transit) and the first stable anchor.
        guard var current = result.first else { return [] }
        var coalesced: [Signal] = []
        for next in result.dropFirst() {
            if next.start < current.end {
                current.end = max(current.end, next.end)
                if next.kind.rawValue > current.kind.rawValue {
                    current.kind = next.kind
                    current.anchorTime = next.anchorTime
                    current.anchor = next.anchor
                }
                current.velocity = max(current.velocity, next.velocity)
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

    private static func trackingMode(for signal: Signal, config: SmartAutoZoomConfig) -> ZoomTrackingMode {
        signal.kind == .transit && signal.end - signal.start >= config.followCursorDuration ? .followCursor : .fixed
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
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: SmartAutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        SmartAutoZoom.generateRanges(
            samples: samples,
            clicks: clicks,
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
            duration: duration,
            displayBounds: displayBounds,
            config: config,
            targetGeometry: targetGeometry,
            preserveLockedAndManual: preserveLockedAndManual
        )
    }
}
