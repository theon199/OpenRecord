import Foundation

/// The edit-decision operations which remove source material from a project.
///
/// Keeping the operation as an enum (rather than using a boolean on
/// `EditDecision`) leaves room for additive decisions in a later schema while
/// keeping the format-v4 wire representation explicit.
public enum EditDecisionKind: String, Codable, Sendable, Hashable {
    case exclude
}

/// A source-timed edit decision. Ranges use half-open `[start, end)`
/// semantics, just like the other timeline edits.
public struct EditDecision: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var kind: EditDecisionKind

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        kind: EditDecisionKind = .exclude
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        kind = try container.decode(EditDecisionKind.self, forKey: .kind)
    }
}

/// One contiguous source span in the output. A slice never crosses either an
/// exclusion or a speed-segment boundary.
public struct ProjectTimeSlice: Equatable, Sendable {
    public var sourceID: String
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval
    public var outputStart: TimeInterval
    public var outputEnd: TimeInterval
    public var rate: Double
    public var speedSegmentID: UUID?
    public var seamTransition: SeamTransition
    public var transitionDuration: TimeInterval
    public var audioMode: SeamAudioMode

    public init(
        sourceID: String = MediaSource.primaryID,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        outputStart: TimeInterval,
        outputEnd: TimeInterval,
        rate: Double,
        speedSegmentID: UUID? = nil,
        seamTransition: SeamTransition = .cut,
        transitionDuration: TimeInterval = 0,
        audioMode: SeamAudioMode = .sourceAudio
    ) {
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.outputStart = outputStart
        self.outputEnd = outputEnd
        self.rate = rate
        self.speedSegmentID = speedSegmentID
        self.seamTransition = seamTransition
        self.transitionDuration = transitionDuration
        self.audioMode = audioMode
    }

    public var sourceDuration: TimeInterval { sourceEnd - sourceStart }
    public var outputDuration: TimeInterval { outputEnd - outputStart }
}

/// The single source/output clock used by preview and export.
///
/// Edit decisions are applied first (removing source spans and rippling the
/// result), then speed segments are applied to every retained span. All lower
/// level effect and media APIs can consequently continue to consume source
/// time while callers use one deterministic output clock.
public struct ProjectTimeMapper: Sendable {
    /// Reject only effectively empty ranges. Frame-rate-specific snapping
    /// belongs in editing tools; the persisted timing model must retain valid
    /// short cuts from high-frame-rate recordings.
    public static let minimumDecisionDuration: TimeInterval = 0.000_1

    public let sourceStart: TimeInterval
    public let sourceEnd: TimeInterval
    public let editDecisions: [EditDecision]
    public let slices: [ProjectTimeSlice]
    public let outputDuration: TimeInterval
    public let mediaSources: [MediaSource]
    public let timelineSpans: [TimelineSpan]

    public init(
        sourceDuration: TimeInterval,
        trimIn: TimeInterval = 0,
        trimOut: TimeInterval? = nil,
        editDecisions: [EditDecision] = [],
        speedSegments: [SpeedSegment] = [],
        mediaSources: [MediaSource] = [],
        timelineSpans: [TimelineSpan] = []
    ) {
        let duration = sourceDuration.isFinite ? max(sourceDuration, 0) : 0
        // Mapping preserves persisted trim bounds exactly. The editor applies
        // its own minimum interactive trim width before constructing a mapper,
        // while export must not silently lengthen an older short trim.
        let requestedStart = trimIn.isFinite ? trimIn : 0
        let boundedStart = min(max(requestedStart, 0), duration)
        let requestedEnd = (trimOut?.isFinite == true ? trimOut : nil) ?? duration
        sourceStart = boundedStart
        sourceEnd = min(max(requestedEnd, boundedStart), duration)
        self.editDecisions = Self.normalizedDecisions(
            editDecisions,
            sourceDuration: duration
        )
        self.mediaSources = mediaSources
        self.timelineSpans = timelineSpans

        let speed = SpeedTimeline(segments: speedSegments)
        var outputCursor: TimeInterval = 0
        var built: [ProjectTimeSlice] = []

        if !timelineSpans.isEmpty {
            for span in timelineSpans {
                let normSpan = span.normalized
                guard normSpan.sourceEnd > normSpan.sourceStart else { continue }
                if normSpan.sourceID == MediaSource.primaryID {
                    for (subIndex, sub) in speed.slices(sourceStart: normSpan.sourceStart, sourceEnd: normSpan.sourceEnd).enumerated() {
                        let outputStart = outputCursor
                        let outputEnd = outputStart + sub.outputDuration
                        built.append(
                            ProjectTimeSlice(
                                sourceID: normSpan.sourceID,
                                sourceStart: sub.sourceStart,
                                sourceEnd: sub.sourceEnd,
                                outputStart: outputStart,
                                outputEnd: outputEnd,
                                rate: sub.rate,
                                speedSegmentID: sub.segmentID,
                                seamTransition: subIndex == 0 ? normSpan.seamTransition : .cut,
                                transitionDuration: subIndex == 0 ? normSpan.transitionDuration : 0,
                                audioMode: normSpan.audioMode
                            )
                        )
                        outputCursor = outputEnd
                    }
                } else {
                    let outputStart = outputCursor
                    let outputEnd = outputStart + normSpan.sourceDuration
                    built.append(
                        ProjectTimeSlice(
                            sourceID: normSpan.sourceID,
                            sourceStart: normSpan.sourceStart,
                            sourceEnd: normSpan.sourceEnd,
                            outputStart: outputStart,
                            outputEnd: outputEnd,
                            rate: 1.0,
                            speedSegmentID: nil,
                            seamTransition: normSpan.seamTransition,
                            transitionDuration: normSpan.transitionDuration,
                            audioMode: normSpan.audioMode
                        )
                    )
                    outputCursor = outputEnd
                }
            }
        } else {
            var retainedCursor = sourceStart

            func appendRetained(_ start: TimeInterval, _ end: TimeInterval) {
                guard end > start else { return }
                for span in speed.slices(sourceStart: start, sourceEnd: end) {
                    let outputStart = outputCursor
                    let outputEnd = outputStart + span.outputDuration
                    built.append(
                        ProjectTimeSlice(
                            sourceID: MediaSource.primaryID,
                            sourceStart: span.sourceStart,
                            sourceEnd: span.sourceEnd,
                            outputStart: outputStart,
                            outputEnd: outputEnd,
                            rate: span.rate,
                            speedSegmentID: span.segmentID
                        )
                    )
                    outputCursor = outputEnd
                }
            }

            for decision in self.editDecisions where decision.kind == .exclude {
                guard decision.end > sourceStart, decision.start < sourceEnd else { continue }
                let cutStart = min(max(decision.start, sourceStart), sourceEnd)
                let cutEnd = min(max(decision.end, sourceStart), sourceEnd)
                appendRetained(retainedCursor, cutStart)
                retainedCursor = max(retainedCursor, cutEnd)
            }
            appendRetained(retainedCursor, sourceEnd)
        }

        slices = built
        outputDuration = outputCursor
    }

    /// Convenience initializer for callers that already have a project
    /// document. Legacy documents decode the new lane as an empty list.
    public init(project: ProjectDocument, sourceDuration: TimeInterval) {
        self.init(
            sourceDuration: sourceDuration,
            trimIn: project.trimIn,
            trimOut: project.trimOut,
            editDecisions: project.editDecisions,
            speedSegments: project.speedSegments,
            mediaSources: project.mediaSources,
            timelineSpans: project.timelineSpans
        )
    }

    /// Normalizes source ranges deterministically. Duplicate IDs are ignored,
    /// overlapping ranges are trimmed from the later range, and adjacent
    /// ranges remain distinct so their identities survive editing/undo.
    public static func normalizedDecisions(
        _ decisions: [EditDecision],
        sourceDuration: TimeInterval? = nil
    ) -> [EditDecision] {
        let upperBound = sourceDuration.flatMap { value in
            value.isFinite ? max(value, 0) : nil
        }
        var seen = Set<UUID>()
        var previousEnd: TimeInterval = 0
        var result: [EditDecision] = []

        let ordered = decisions.sorted {
            let lhsStart = $0.start.isFinite ? max($0.start, 0) : .infinity
            let rhsStart = $1.start.isFinite ? max($1.start, 0) : .infinity
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            let lhsEnd = $0.end.isFinite ? max($0.end, 0) : .infinity
            let rhsEnd = $1.end.isFinite ? max($1.end, 0) : .infinity
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return $0.id.uuidString < $1.id.uuidString
        }

        for raw in ordered {
            guard raw.start.isFinite, raw.end.isFinite else { continue }
            var start = max(raw.start, 0)
            var end = max(raw.end, 0)
            if let upperBound {
                start = min(start, upperBound)
                end = min(end, upperBound)
            }
            start = max(start, previousEnd)
            guard end - start >= minimumDecisionDuration else { continue }
            guard seen.insert(raw.id).inserted else { continue }

            var normalized = raw
            normalized.start = start
            normalized.end = end
            // The initial v3 editing model has only exclusions. A future
            // operation must never be silently converted into a cut; current
            // enum decoding rejects it.
            result.append(normalized)
            previousEnd = end
        }
        return result
    }

    /// Returns the exact source ID and source time for an output timestamp.
    public func sourceLocation(atOutputTime outputTime: TimeInterval) -> (sourceID: String, sourceTime: TimeInterval) {
        guard let first = slices.first, let last = slices.last else {
            return (MediaSource.primaryID, sourceEnd)
        }
        let requested: TimeInterval
        if outputTime.isNaN || outputTime == -.infinity {
            requested = 0
        } else if outputTime == .infinity {
            requested = outputDuration
        } else {
            requested = outputTime
        }
        let time = min(max(requested, 0), outputDuration)
        if time >= outputDuration { return (last.sourceID, last.sourceEnd) }
        if time <= 0 { return (first.sourceID, first.sourceStart) }
        if let span = slices.first(where: { time < $0.outputEnd }) {
            return (
                span.sourceID,
                min(
                    span.sourceStart + max(time - span.outputStart, 0) * span.rate,
                    span.sourceEnd
                )
            )
        }
        return (last.sourceID, last.sourceEnd)
    }

    /// Maps output time to source ID.
    public func sourceID(atOutputTime outputTime: TimeInterval) -> String {
        sourceLocation(atOutputTime: outputTime).sourceID
    }

    /// Maps output time to source time. Internal boundaries are half-open:
    /// exactly at a boundary the next slice wins, which jumps over cuts.
    public func sourceTime(atOutputTime outputTime: TimeInterval) -> TimeInterval {
        sourceLocation(atOutputTime: outputTime).sourceTime
    }

    /// Returns nil for points inside a cut or outside the trim. The final
    /// retained-slice endpoint is a valid output endpoint even though ranges
    /// are otherwise half-open.
    public func outputTime(
        forSourceTime sourceTime: TimeInterval,
        sourceID: String = MediaSource.primaryID
    ) -> TimeInterval? {
        guard sourceTime.isFinite else { return nil }
        let matching = slices.filter { $0.sourceID == sourceID }
        guard !matching.isEmpty else { return nil }
        if sourceTime == matching.last?.sourceEnd { return matching.last?.outputEnd }
        if timelineSpans.isEmpty {
            guard sourceTime >= sourceStart, sourceTime < sourceEnd else { return nil }
            guard isIncluded(sourceTime: sourceTime, sourceID: sourceID) else { return nil }
        }
        for span in matching {
            if sourceTime >= span.sourceStart && sourceTime < span.sourceEnd {
                return span.outputStart + (sourceTime - span.sourceStart) / span.rate
            }
            if sourceTime == span.sourceEnd {
                return span.outputEnd
            }
        }
        return nil
    }

    /// Like `outputTime(forSourceTime:)`, but clamps all invalid points to the
    /// nearest output boundary. A point inside a cut maps to the ripple edge.
    public func clampedOutputTime(
        forSourceTime sourceTime: TimeInterval,
        sourceID: String = MediaSource.primaryID
    ) -> TimeInterval {
        if sourceTime.isNaN || sourceTime == -.infinity { return 0 }
        if sourceTime == .infinity { return outputDuration }
        let matching = slices.filter { $0.sourceID == sourceID }
        guard let first = matching.first, let last = matching.last else {
            return sourceTime <= sourceStart ? 0 : outputDuration
        }
        if sourceTime <= first.sourceStart { return first.outputStart }
        if sourceTime >= last.sourceEnd { return last.outputEnd }
        if let output = outputTime(forSourceTime: sourceTime, sourceID: sourceID) { return output }
        for span in matching where sourceTime < span.sourceStart {
            return span.outputStart
        }
        return last.outputEnd
    }

    public func isIncluded(
        sourceTime: TimeInterval,
        sourceID: String = MediaSource.primaryID
    ) -> Bool {
        guard sourceTime.isFinite else { return false }
        if timelineSpans.isEmpty {
            guard sourceTime >= sourceStart, sourceTime < sourceEnd else {
                return false
            }
            return editDecisions.first {
                $0.kind == .exclude && sourceTime >= $0.start && sourceTime < $0.end
            } == nil
        }
        return slices.contains { span in
            span.sourceID == sourceID && sourceTime >= span.sourceStart && sourceTime < span.sourceEnd
        }
    }

    /// Information about a transition seam active at a given output time.
    public struct ActiveSeam: Equatable, Sendable {
        public var outgoingSourceID: String
        public var outgoingSourceTime: TimeInterval
        public var incomingSourceID: String
        public var incomingSourceTime: TimeInterval
        public var transition: SeamTransition
        public var progress: Double

        public init(
            outgoingSourceID: String,
            outgoingSourceTime: TimeInterval,
            incomingSourceID: String,
            incomingSourceTime: TimeInterval,
            transition: SeamTransition,
            progress: Double
        ) {
            self.outgoingSourceID = outgoingSourceID
            self.outgoingSourceTime = outgoingSourceTime
            self.incomingSourceID = incomingSourceID
            self.incomingSourceTime = incomingSourceTime
            self.transition = transition
            self.progress = progress
        }
    }

    /// If outputTime falls within a transition window between two spans, returns the active seam info.
    public func activeSeam(atOutputTime outputTime: TimeInterval) -> ActiveSeam? {
        guard outputTime.isFinite, slices.count > 1 else { return nil }
        for i in 1..<slices.count {
            let outgoing = slices[i - 1]
            let incoming = slices[i]
            guard incoming.seamTransition == .crossDissolve, incoming.transitionDuration > 0 else { continue }
            let seamTime = incoming.outputStart
            let half = incoming.transitionDuration / 2.0
            let windowStart = max(outgoing.outputStart, seamTime - half)
            let windowEnd = min(incoming.outputEnd, seamTime + half)
            if outputTime >= windowStart && outputTime <= windowEnd {
                let duration = max(0.0001, windowEnd - windowStart)
                let progress = min(max((outputTime - windowStart) / duration, 0), 1)
                let outTime = outgoing.sourceEnd - max(0, seamTime - outputTime) * outgoing.rate
                let inTime = incoming.sourceStart + max(0, outputTime - seamTime) * incoming.rate
                return ActiveSeam(
                    outgoingSourceID: outgoing.sourceID,
                    outgoingSourceTime: outTime,
                    incomingSourceID: incoming.sourceID,
                    incomingSourceTime: inTime,
                    transition: .crossDissolve,
                    progress: progress
                )
            }
        }
        return nil
    }
}
