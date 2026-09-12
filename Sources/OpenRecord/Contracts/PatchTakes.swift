import Foundation

/// Seam transition at the boundary between two timeline spans.
public enum SeamTransition: String, Codable, CaseIterable, Sendable, Hashable {
    case cut
    case crossDissolve = "cross-dissolve"
}

/// Audio blending mode at a seam boundary.
public enum SeamAudioMode: String, Codable, CaseIterable, Sendable, Hashable {
    case sourceAudio = "source-audio"
    case crossfade
    case silence
}

/// A media and telemetry source owned by an OpenRecord project.
///
/// Format v8 multi-source timelines represent each distinct recording take
/// with a stable `id` and a bundle-relative folder under `recording/takes/<id>`.
/// The original primary recording is represented as `MediaSource.primaryID` ("primary").
public struct MediaSource: Codable, Sendable, Hashable, Identifiable {
    public static let primaryID = "primary"

    public var id: String
    public var relativePath: String
    public var timingOrigin: TimeInterval
    public var trackOffsets: [String: TimeInterval]
    public var captureHealth: CaptureHealth?
    public var width: Int
    public var height: Int
    public var duration: TimeInterval
    public var label: String?

    public init(
        id: String,
        relativePath: String,
        timingOrigin: TimeInterval = 0,
        trackOffsets: [String: TimeInterval] = [:],
        captureHealth: CaptureHealth? = nil,
        width: Int = 1920,
        height: Int = 1080,
        duration: TimeInterval = 0,
        label: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.timingOrigin = timingOrigin.isFinite ? timingOrigin : 0
        self.trackOffsets = trackOffsets
        self.captureHealth = captureHealth
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.duration = duration.isFinite ? max(duration, 0) : 0
        self.label = label
    }

    public static func primary(
        duration: TimeInterval = 0,
        width: Int = 1920,
        height: Int = 1080,
        captureHealth: CaptureHealth? = nil
    ) -> MediaSource {
        MediaSource(
            id: primaryID,
            relativePath: ProjectLayout.recordingDirectoryName,
            timingOrigin: 0,
            trackOffsets: [:],
            captureHealth: captureHealth,
            width: width,
            height: height,
            duration: duration,
            label: "Primary Capture"
        )
    }

    public var isPrimary: Bool {
        id == Self.primaryID || relativePath == ProjectLayout.recordingDirectoryName
    }

    public var normalized: MediaSource {
        var copy = self
        copy.timingOrigin = copy.timingOrigin.isFinite ? copy.timingOrigin : 0
        copy.width = max(copy.width, 1)
        copy.height = max(copy.height, 1)
        copy.duration = copy.duration.isFinite ? max(copy.duration, 0) : 0
        copy.trackOffsets = copy.trackOffsets.filter { $0.value.isFinite }
        return copy
    }
}

/// An ordered output timeline span referencing a source ID and source-local time interval.
public struct TimelineSpan: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: String
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval
    public var seamTransition: SeamTransition
    public var transitionDuration: TimeInterval
    public var audioMode: SeamAudioMode

    public init(
        id: UUID = UUID(),
        sourceID: String = MediaSource.primaryID,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        seamTransition: SeamTransition = .cut,
        transitionDuration: TimeInterval = 0.2,
        audioMode: SeamAudioMode = .sourceAudio
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.seamTransition = seamTransition
        self.transitionDuration = transitionDuration
        self.audioMode = audioMode
    }

    public var sourceDuration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    public var normalized: TimelineSpan {
        var copy = self
        let s = copy.sourceStart.isFinite ? max(0, copy.sourceStart) : 0
        let e = copy.sourceEnd.isFinite ? max(s, copy.sourceEnd) : s
        copy.sourceStart = s
        copy.sourceEnd = e
        copy.transitionDuration = copy.transitionDuration.isFinite ? min(max(copy.transitionDuration, 0), 2.0) : 0
        return copy
    }
}

/// Lifecycle state for patch take proposals.
public enum PatchProposalState: String, Codable, Sendable, Hashable {
    case pending
    case applied
    case rejected
}

/// A proposal for substituting a source interval with a replacement patch take.
public struct PatchTakeProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: String
    public var takeRelativePath: String
    public var targetStart: TimeInterval
    public var targetEnd: TimeInterval
    public var patchStart: TimeInterval
    public var patchEnd: TimeInterval
    public var seamTransition: SeamTransition
    public var transitionDuration: TimeInterval
    public var audioMode: SeamAudioMode
    public var confidence: Double
    public var reasons: [String]
    public var state: PatchProposalState

    public init(
        id: UUID = UUID(),
        sourceID: String,
        takeRelativePath: String,
        targetStart: TimeInterval,
        targetEnd: TimeInterval,
        patchStart: TimeInterval,
        patchEnd: TimeInterval,
        seamTransition: SeamTransition = .cut,
        transitionDuration: TimeInterval = 0.2,
        audioMode: SeamAudioMode = .sourceAudio,
        confidence: Double = 1.0,
        reasons: [String] = [],
        state: PatchProposalState = .pending
    ) {
        self.id = id
        self.sourceID = sourceID
        self.takeRelativePath = takeRelativePath
        self.targetStart = targetStart
        self.targetEnd = targetEnd
        self.patchStart = patchStart
        self.patchEnd = patchEnd
        self.seamTransition = seamTransition
        self.transitionDuration = transitionDuration
        self.audioMode = audioMode
        self.confidence = confidence
        self.reasons = reasons
        self.state = state
    }
}

/// Visual and telemetry guide generated for recording a replacement patch take.
public struct PatchTakeGuide: Sendable, Equatable {
    public var targetStart: TimeInterval
    public var targetEnd: TimeInterval
    public var entryCursorPosition: Point2D?
    public var exitCursorPosition: Point2D?
    public var targetGeometry: Rect2D?
    public var actionTitle: String?
    public var nearbyTranscript: [TranscriptSegment]

    public init(
        targetStart: TimeInterval,
        targetEnd: TimeInterval,
        entryCursorPosition: Point2D? = nil,
        exitCursorPosition: Point2D? = nil,
        targetGeometry: Rect2D? = nil,
        actionTitle: String? = nil,
        nearbyTranscript: [TranscriptSegment] = []
    ) {
        self.targetStart = targetStart
        self.targetEnd = targetEnd
        self.entryCursorPosition = entryCursorPosition
        self.exitCursorPosition = exitCursorPosition
        self.targetGeometry = targetGeometry
        self.actionTitle = actionTitle
        self.nearbyTranscript = nearbyTranscript
    }
}

/// Evaluates alignment between original footage and replacement takes.
public enum PatchTakeAligner: Sendable {
    /// Evaluates seam quality and suggests transition, confidence, and reasons.
    public static func evaluate(
        targetStart: TimeInterval,
        targetEnd: TimeInterval,
        targetCursorEntry: Point2D? = nil,
        targetCursorExit: Point2D? = nil,
        takeStart: TimeInterval,
        takeEnd: TimeInterval,
        takeCursorEntry: Point2D? = nil,
        takeCursorExit: Point2D? = nil,
        targetWindowBounds: Rect2D? = nil,
        takeWindowBounds: Rect2D? = nil
    ) -> (transition: SeamTransition, transitionDuration: TimeInterval, confidence: Double, reasons: [String]) {
        var reasons: [String] = []
        var score: Double = 1.0

        // Proximity at entry
        if let targetEntry = targetCursorEntry, let takeEntry = takeCursorEntry {
            let dx = targetEntry.x - takeEntry.x
            let dy = targetEntry.y - takeEntry.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < 0.08 {
                reasons.append("Cursor entry points match within \(Int(dist * 100))%")
            } else if dist < 0.20 {
                score -= 0.15
                reasons.append("Moderate cursor entry delta (\(Int(dist * 100))%)")
            } else {
                score -= 0.35
                reasons.append("Significant cursor entry jump (\(Int(dist * 100))%)")
            }
        }

        // Proximity at exit
        if let targetExit = targetCursorExit, let takeExit = takeCursorExit {
            let dx = targetExit.x - takeExit.x
            let dy = targetExit.y - takeExit.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < 0.08 {
                reasons.append("Cursor exit points match closely")
            } else if dist < 0.20 {
                score -= 0.15
            } else {
                score -= 0.30
            }
        }

        // Window geometry match
        if let targetBounds = targetWindowBounds, let takeBounds = takeWindowBounds {
            let sizeDiff = abs(targetBounds.width - takeBounds.width) + abs(targetBounds.height - takeBounds.height)
            if sizeDiff < 0.05 {
                reasons.append("Target window geometry aligns")
            } else {
                score -= 0.2
                reasons.append("Target window dimensions differ")
            }
        }

        // Duration comparison
        let targetDuration = max(0.01, targetEnd - targetStart)
        let takeDuration = max(0.01, takeEnd - takeStart)
        let ratio = takeDuration / targetDuration
        if ratio >= 0.7 && ratio <= 1.4 {
            reasons.append("Duration closely matches original segment")
        } else {
            score -= 0.1
            reasons.append("Take duration differs from original (\(String(format: "%.1f", takeDuration))s vs \(String(format: "%.1f", targetDuration))s)")
        }

        let confidence = min(max(score, 0.1), 1.0)
        let transition: SeamTransition = confidence >= 0.75 ? .crossDissolve : .cut
        let transitionDuration: TimeInterval = transition == .crossDissolve ? 0.25 : 0.0

        return (transition, transitionDuration, confidence, reasons)
    }
}

/// Pure timeline span operations for patch takes.
public enum PatchTakeOperations: Sendable {
    /// Derives output TimelineSpans from single-source trim and edit decisions.
    public static func buildSpans(
        from document: ProjectDocument,
        primaryDuration: TimeInterval
    ) -> [TimelineSpan] {
        let mapper = ProjectTimeMapper(
            sourceDuration: primaryDuration,
            trimIn: document.trimIn,
            trimOut: document.trimOut,
            editDecisions: document.editDecisions,
            speedSegments: []
        )
        return mapper.slices.map { slice in
            TimelineSpan(
                sourceID: MediaSource.primaryID,
                sourceStart: slice.sourceStart,
                sourceEnd: slice.sourceEnd,
                seamTransition: .cut,
                transitionDuration: 0,
                audioMode: .sourceAudio
            )
        }
    }

    /// Replaces a target source range on the timeline with a replacement take span.
    /// Original media sources are preserved completely immutably.
    public static func applying(
        targetStart: TimeInterval,
        targetEnd: TimeInterval,
        take: MediaSource,
        patchStart: TimeInterval,
        patchEnd: TimeInterval,
        seamTransition: SeamTransition = .cut,
        transitionDuration: TimeInterval = 0.2,
        audioMode: SeamAudioMode = .sourceAudio,
        to document: ProjectDocument,
        primaryDuration: TimeInterval
    ) -> ProjectDocument {
        var doc = document
        var spans = doc.timelineSpans
        if spans.isEmpty {
            spans = buildSpans(from: doc, primaryDuration: primaryDuration)
        }

        let targetLo = min(targetStart, targetEnd)
        let targetHi = max(targetStart, targetEnd)
        guard targetHi > targetLo else { return doc }

        var newSpans: [TimelineSpan] = []
        var inserted = false

        for span in spans {
            if span.sourceEnd <= targetLo || span.sourceID != MediaSource.primaryID {
                newSpans.append(span)
                continue
            }
            if span.sourceStart >= targetHi {
                if !inserted {
                    newSpans.append(
                        TimelineSpan(
                            sourceID: take.id,
                            sourceStart: patchStart,
                            sourceEnd: patchEnd,
                            seamTransition: seamTransition,
                            transitionDuration: transitionDuration,
                            audioMode: audioMode
                        )
                    )
                    inserted = true
                }
                newSpans.append(span)
                continue
            }

            if span.sourceStart < targetLo {
                newSpans.append(
                    TimelineSpan(
                        sourceID: span.sourceID,
                        sourceStart: span.sourceStart,
                        sourceEnd: targetLo,
                        seamTransition: span.seamTransition,
                        transitionDuration: span.transitionDuration,
                        audioMode: span.audioMode
                    )
                )
            }

            if !inserted {
                newSpans.append(
                    TimelineSpan(
                        sourceID: take.id,
                        sourceStart: patchStart,
                        sourceEnd: patchEnd,
                        seamTransition: seamTransition,
                        transitionDuration: transitionDuration,
                        audioMode: audioMode
                    )
                )
                inserted = true
            }

            if span.sourceEnd > targetHi {
                newSpans.append(
                    TimelineSpan(
                        sourceID: span.sourceID,
                        sourceStart: targetHi,
                        sourceEnd: span.sourceEnd,
                        seamTransition: .cut,
                        transitionDuration: 0,
                        audioMode: span.audioMode
                    )
                )
            }
        }

        if !inserted {
            newSpans.append(
                TimelineSpan(
                    sourceID: take.id,
                    sourceStart: patchStart,
                    sourceEnd: patchEnd,
                    seamTransition: seamTransition,
                    transitionDuration: transitionDuration,
                    audioMode: audioMode
                )
            )
        }

        doc.timelineSpans = newSpans.filter { $0.sourceEnd > $0.sourceStart }
        if !doc.mediaSources.contains(where: { $0.id == take.id }) {
            doc.mediaSources.append(take)
        }
        if !doc.mediaSources.contains(where: { $0.isPrimary }) {
            doc.mediaSources.insert(MediaSource.primary(duration: primaryDuration), at: 0)
        }
        return doc
    }

    /// Reverts a patch take by sourceID, restoring the original primary spans.
    public static func reverting(
        takeID: String,
        in document: ProjectDocument,
        primaryDuration: TimeInterval
    ) -> ProjectDocument {
        var doc = document
        guard !doc.timelineSpans.isEmpty else { return doc }
        let remainingSpans = doc.timelineSpans.filter { $0.sourceID != takeID }
        let hasOtherTakes = remainingSpans.contains { $0.sourceID != MediaSource.primaryID }
        guard hasOtherTakes else {
            doc.timelineSpans = []
            doc.mediaSources.removeAll { $0.id == takeID }
            return doc
        }

        let baseSpans = buildSpans(from: doc, primaryDuration: primaryDuration)
        var newSpans: [TimelineSpan] = []

        for (i, span) in doc.timelineSpans.enumerated() {
            if span.sourceID != takeID {
                newSpans.append(span)
                continue
            }

            // Find preceding primary boundary
            var lo: TimeInterval = 0.0
            for prev in doc.timelineSpans[0..<i].reversed() {
                if prev.sourceID == MediaSource.primaryID {
                    lo = prev.sourceEnd
                    break
                }
            }

            // Find following primary boundary
            var hi: TimeInterval = primaryDuration
            for next in doc.timelineSpans[(i + 1)...] {
                if next.sourceID == MediaSource.primaryID {
                    hi = next.sourceStart
                    break
                }
            }

            if hi > lo {
                for base in baseSpans {
                    let s = max(base.sourceStart, lo)
                    let e = min(base.sourceEnd, hi)
                    if e > s {
                        newSpans.append(
                            TimelineSpan(
                                sourceID: MediaSource.primaryID,
                                sourceStart: s,
                                sourceEnd: e,
                                seamTransition: .cut,
                                transitionDuration: 0,
                                audioMode: .sourceAudio
                            )
                        )
                    }
                }
            }
        }

        // Coalesce adjacent primary spans if contiguous
        var coalesced: [TimelineSpan] = []
        for span in newSpans {
            if let last = coalesced.last,
               last.sourceID == MediaSource.primaryID,
               span.sourceID == MediaSource.primaryID,
               abs(last.sourceEnd - span.sourceStart) < 0.001,
               span.seamTransition == .cut {
                coalesced[coalesced.count - 1].sourceEnd = span.sourceEnd
            } else {
                coalesced.append(span)
            }
        }

        doc.timelineSpans = coalesced
        doc.mediaSources.removeAll { $0.id == takeID }
        return doc
    }
}
