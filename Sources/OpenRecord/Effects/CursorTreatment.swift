import Foundation

/// The fully-resolved cursor treatment for one source-timeline instant.
///
/// This value is deliberately independent of a renderer. Preview and export
/// use the same state so cursor controls cannot drift between the two paths.
public struct CursorTreatmentState: Sendable, Hashable, Equatable {
    public var visible: Bool
    /// Effective scale, including the canvas base scale when no range applies.
    public var scale: Double
    public var clickEmphasis: Bool
    public var halo: Bool

    public init(
        visible: Bool = true,
        scale: Double = CanvasSettings.default.cursorScale,
        clickEmphasis: Bool = true,
        halo: Bool = false
    ) {
        self.visible = visible
        self.scale = scale
        self.clickEmphasis = clickEmphasis
        self.halo = halo
    }
}

/// Resolves source-timed cursor effect ranges using half-open intervals.
///
/// Ranges are normalized before evaluation. If ranges overlap, the range with
/// the latest start wins; ties are resolved by the stable id, so evaluation is
/// independent of the order in which a caller happened to load the document.
public struct CursorTreatmentEvaluator: Sendable {
    private let ranges: [CursorEffectRange]

    public init(ranges: [CursorEffectRange]) {
        self.ranges = ranges
            .map(\.normalized)
            .filter { $0.end > $0.start }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }
    }

    public func state(
        at sourceTime: TimeInterval,
        baseScale: Double,
        baseClickEmphasis: Bool = true,
        baseHalo: Bool = false
    ) -> CursorTreatmentState {
        let safeBaseScale = Self.clampedScale(baseScale)
        guard sourceTime.isFinite else {
            return CursorTreatmentState(
                scale: safeBaseScale,
                clickEmphasis: baseClickEmphasis,
                halo: baseHalo
            )
        }

        // Intervals are source-authored and half-open: start is included,
        // end is excluded. The sorted pass makes the final match deterministic
        // for both overlapping and equal-start ranges.
        let active = ranges
            .filter { sourceTime >= $0.start && sourceTime < $0.end }
            .max { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }

        guard let active else {
            return CursorTreatmentState(
                scale: safeBaseScale,
                clickEmphasis: baseClickEmphasis,
                halo: baseHalo
            )
        }
        return CursorTreatmentState(
            visible: active.visible,
            scale: Self.clampedScale(active.scale),
            clickEmphasis: active.clickEmphasis,
            halo: active.halo
        )
    }

    private static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return CanvasSettings.default.cursorScale }
        return min(max(value, CursorEffectRange.scaleRange.lowerBound), CursorEffectRange.scaleRange.upperBound)
    }
}
