import Foundation

/// Period where the cursor is treated as idle (near-zero motion, no recent click).
public struct SilenceZone: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}

/// Knobs for silence detection and auto-zoom segment generation.
public struct AutoZoomConfig: Sendable, Hashable {
    /// Minimum idle stretch to count as a pause (default 1.6s).
    public var minSilence: TimeInterval
    /// Drop active islands shorter than this.
    public var minActiveDuration: TimeInterval
    /// Magnification written onto generated `ZoomRange`s.
    public var zoomAmount: Double
    /// Cursor displacement (capture points) below which motion is "still".
    public var stillDisplacementPoints: Double
    /// Treat a click as activity this far before the down event.
    public var clickPaddingBefore: TimeInterval
    /// Treat a click as activity this far after the down event.
    public var clickPaddingAfter: TimeInterval
    /// Merge active islands separated by less than this gap.
    public var mergeGap: TimeInterval
    /// After merge, stretch each island to at least this duration, then re-merge overlaps.
    public var minZoomHold: TimeInterval

    public init(
        minSilence: TimeInterval = 1.6,
        minActiveDuration: TimeInterval = 0.35,
        zoomAmount: Double = 1.5,
        stillDisplacementPoints: Double = 5,
        clickPaddingBefore: TimeInterval = 0.35,
        clickPaddingAfter: TimeInterval = 1.2,
        mergeGap: TimeInterval = 1.4,
        minZoomHold: TimeInterval = 2.0
    ) {
        self.minSilence = minSilence
        self.minActiveDuration = minActiveDuration
        self.zoomAmount = zoomAmount
        self.stillDisplacementPoints = stillDisplacementPoints
        self.clickPaddingBefore = clickPaddingBefore
        self.clickPaddingAfter = clickPaddingAfter
        self.mergeGap = mergeGap
        self.minZoomHold = minZoomHold
    }

    public static let `default` = AutoZoomConfig()
}

public extension AutoZoomSensitivity {
    /// Concrete generator settings for each user-facing sensitivity preset.
    /// Normal intentionally preserves the v1/v2.0 behavior.
    var config: AutoZoomConfig {
        switch self {
        case .subtle:
            AutoZoomConfig(
                minSilence: 2.0,
                minActiveDuration: 0.55,
                zoomAmount: 1.35,
                stillDisplacementPoints: 10,
                clickPaddingBefore: 0.25,
                clickPaddingAfter: 1.0,
                mergeGap: 1.1,
                minZoomHold: 1.8
            )
        case .normal:
            .default
        case .aggressive:
            AutoZoomConfig(
                minSilence: 1.2,
                minActiveDuration: 0.2,
                zoomAmount: 1.7,
                stillDisplacementPoints: 2.5,
                clickPaddingBefore: 0.45,
                clickPaddingAfter: 1.4,
                mergeGap: 1.6,
                minZoomHold: 2.2
            )
        }
    }
}

/// Click/activity → `ZoomRange` generation. Call after capture stop; editor stores the result.
public enum AutoZoom: Sendable {
    /// Idle stretches from cursor displacement, with click windows punched out as activity.
    public static func detectSilenceZones(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        duration: TimeInterval? = nil,
        config: AutoZoomConfig = .default,
        displayBounds: Rect2D = .unit,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [SilenceZone] {
        let filteredSamples = visibleSamples(samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
        let filteredClicks = visibleClicks(clicks, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
        let end = timelineEnd(samples: filteredSamples, clicks: filteredClicks, duration: duration)
        let active = activityIntervals(
            samples: samples,
            clicks: filteredClicks,
            duration: end,
            config: config,
            displayBounds: displayBounds,
            targetGeometry: targetGeometry
        )
        return complement(active, from: 0, to: end, minDuration: config.minSilence)
    }

    /// Zoom segments covering non-silent (moving / clicking) regions.
    ///
    /// Anchors are the first click in the island, or cursor UV at island start if there is no click.
    public static func generateRanges(
        samples: [CursorSample],
        clicks: [ClickSample] = [],
        duration: TimeInterval,
        displayBounds: Rect2D,
        config: AutoZoomConfig = .default,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [ZoomRange] {
        let end = max(0, duration)
        let visible = visibleSamples(samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
        let visibleClickEvents = visibleClicks(clicks, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
        let active = expandToMinHold(
            activityIntervals(
                samples: samples,
                clicks: visibleClickEvents,
                duration: end,
                config: config,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            )
                .filter { $0.end - $0.start >= config.minActiveDuration },
            minHold: config.minZoomHold,
            duration: end
        )

        let sortedSamples = visible.sorted { $0.t < $1.t }
        let downs = visibleClickEvents.filter(\.down).sorted { $0.t < $1.t }
        let amount = max(config.zoomAmount, 1)

        return active.map { island in
            let anchor = anchorUV(
                start: island.start,
                end: island.end,
                samples: sortedSamples,
                clicks: downs,
                displayBounds: displayBounds,
                targetGeometry: targetGeometry
            )
            // Keep generated viewport centers away from the canvas edge. This
            // is intentionally applied after interpolation so sparse legacy
            // telemetry receives the same safety treatment as v3 telemetry.
            let safeAnchor = Point2D(
                x: min(0.86, max(0.14, anchor.x)),
                y: min(0.86, max(0.14, anchor.y))
            )
            return ZoomRange(
                start: island.start,
                end: island.end,
                amount: amount,
                anchor: safeAnchor,
                tracking: .followCursor,
                source: .automatic
            )
        }
    }

    // MARK: - Activity

    struct Interval {
        var start: TimeInterval
        var end: TimeInterval
    }

    static func timelineEnd(
        samples: [CursorSample],
        clicks: [ClickSample],
        duration: TimeInterval?
    ) -> TimeInterval {
        var end = duration ?? 0
        if let last = samples.map(\.t).max() {
            end = max(end, last)
        }
        if let last = clicks.map(\.t).max() {
            end = max(end, last)
        }
        return max(end, 0)
    }

    static func activityIntervals(
        samples: [CursorSample],
        clicks: [ClickSample],
        duration: TimeInterval,
        config: AutoZoomConfig,
        displayBounds: Rect2D = .unit,
        targetGeometry: [TargetGeometrySample] = []
    ) -> [Interval] {
        var raw: [Interval] = []
        let sorted = samples.sorted { $0.t < $1.t }

        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let a = sorted[i - 1]
                let b = sorted[i]
                guard CursorSmoother.isVisible(
                    a,
                    at: a.t,
                    geometry: targetGeometry,
                    fallback: displayBounds
                ), CursorSmoother.isVisible(
                    b,
                    at: b.t,
                    geometry: targetGeometry,
                    fallback: displayBounds
                ) else { continue }
                let dist: Double
                if targetGeometry.isEmpty {
                    // Preserve v1's capture-point interpretation when no
                    // geometry sidecar is present.
                    dist = hypot(b.x - a.x, b.y - a.y)
                } else {
                    let auv = normalized(a, displayBounds: displayBounds, targetGeometry: targetGeometry)
                    let buv = normalized(b, displayBounds: displayBounds, targetGeometry: targetGeometry)
                    dist = hypot(
                        (buv.x - auv.x) * displayBounds.width,
                        (buv.y - auv.y) * displayBounds.height
                    )
                }
                if dist >= config.stillDisplacementPoints {
                    raw.append(Interval(start: a.t, end: b.t))
                }
            }
        }

        for click in clicks where click.down {
            raw.append(
                Interval(
                    start: click.t - config.clickPaddingBefore,
                    end: click.t + config.clickPaddingAfter
                )
            )
        }

        return merge(
            raw.map { Interval(start: max(0, $0.start), end: min(duration, $0.end)) }
                .filter { $0.end > $0.start },
            gap: config.mergeGap
        )
    }

    /// Apply the same target/visibility policy used by CursorSmoother. Keeping
    /// this at the edge of auto-zoom prevents off-target desktop motion from
    /// generating zoom ranges.
    static func visibleSamples(
        _ samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [CursorSample] {
        samples.filter {
            CursorSmoother.isVisible(
                $0,
                at: $0.t,
                geometry: targetGeometry,
                fallback: displayBounds
            )
        }
    }

    static func visibleClicks(
        _ clicks: [ClickSample],
        samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> [ClickSample] {
        guard !clicks.isEmpty else { return [] }
        // A click is in-target when the nearest cursor sample at that time is
        // visible. For sparse legacy telemetry, retain clicks when no sample
        // exists rather than silently changing the old behavior.
        let sorted = samples.sorted { $0.t < $1.t }
        return clicks.filter { click in
            guard let sample = nearestSample(at: click.t, samples: sorted) else {
                return targetGeometry.isEmpty
            }
            return CursorSmoother.isVisible(
                sample,
                at: click.t,
                geometry: targetGeometry,
                fallback: displayBounds
            )
        }
    }

    private static func nearestSample(at time: TimeInterval, samples: [CursorSample]) -> CursorSample? {
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

    /// Stretch short islands to `minHold` (extend end, then start), then merge overlaps.
    static func expandToMinHold(
        _ intervals: [Interval],
        minHold: TimeInterval,
        duration: TimeInterval
    ) -> [Interval] {
        guard minHold > 0 else { return intervals }
        let expanded = intervals.map { interval -> Interval in
            let span = interval.end - interval.start
            if span >= minHold { return interval }
            var start = interval.start
            var end = interval.end
            let needed = minHold - span
            let extendAfter = min(needed, max(0, duration - end))
            end += extendAfter
            let stillNeeded = minHold - (end - start)
            if stillNeeded > 0 {
                start = max(0, start - stillNeeded)
            }
            return Interval(start: start, end: end)
        }
        return merge(expanded, gap: 0)
    }

    static func merge(_ intervals: [Interval], gap: TimeInterval) -> [Interval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var out: [Interval] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end + gap {
                current.end = max(current.end, next.end)
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    static func complement(
        _ active: [Interval],
        from: TimeInterval,
        to: TimeInterval,
        minDuration: TimeInterval
    ) -> [SilenceZone] {
        guard to > from else { return [] }
        var cursor = from
        var zones: [SilenceZone] = []
        for island in active {
            if island.start > cursor {
                let zone = SilenceZone(start: cursor, end: island.start)
                if zone.duration >= minDuration {
                    zones.append(zone)
                }
            }
            cursor = max(cursor, island.end)
        }
        if cursor < to {
            let zone = SilenceZone(start: cursor, end: to)
            if zone.duration >= minDuration {
                zones.append(zone)
            }
        }
        return zones
    }

    static func anchorUV(
        start: TimeInterval,
        end: TimeInterval,
        samples: [CursorSample],
        clicks: [ClickSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample] = []
    ) -> Point2D {
        if let click = clicks.first(where: { $0.t >= start && $0.t <= end }) {
            return nearestUV(at: click.t, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
                ?? Point2D(x: 0.5, y: 0.5)
        }
        return nearestUV(at: start, samples: samples, displayBounds: displayBounds, targetGeometry: targetGeometry)
            ?? Point2D(x: 0.5, y: 0.5)
    }

    static func nearestUV(
        at time: TimeInterval,
        samples: [CursorSample],
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample] = []
    ) -> Point2D? {
        guard !samples.isEmpty else { return nil }
        if time <= samples[0].t {
            let bounds = geometry(at: samples[0].t, samples: targetGeometry, fallback: displayBounds)
            return CursorSmoother.uv(samples[0], displayBounds: bounds)
        }
        if time >= samples[samples.count - 1].t {
            let bounds = geometry(at: samples[samples.count - 1].t, samples: targetGeometry, fallback: displayBounds)
            return CursorSmoother.uv(samples[samples.count - 1], displayBounds: bounds)
        }

        var lo = 0
        var hi = samples.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t <= time {
                lo = mid
            } else {
                hi = mid
            }
        }

        let a = samples[lo]
        let b = samples[hi]
        let span = max(b.t - a.t, 1e-12)
        let t = (time - a.t) / span
        let x = a.x + (b.x - a.x) * t
        let y = a.y + (b.y - a.y) * t
        let bounds = geometry(at: time, samples: targetGeometry, fallback: displayBounds)
        return CursorSmoother.uv(x: x, y: y, displayBounds: bounds)
    }

    private static func geometry(
        at time: TimeInterval,
        samples: [TargetGeometrySample],
        fallback: Rect2D
    ) -> Rect2D {
        guard !samples.isEmpty else { return fallback }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return fallback }
        let sample = samples[lo - 1]
        return sample.available ? sample.bounds : fallback
    }

    private static func normalized(
        _ sample: CursorSample,
        displayBounds: Rect2D,
        targetGeometry: [TargetGeometrySample]
    ) -> Point2D {
        let bounds = geometry(at: sample.t, samples: targetGeometry, fallback: displayBounds)
        return CursorSmoother.uv(sample, displayBounds: bounds)
    }
}
