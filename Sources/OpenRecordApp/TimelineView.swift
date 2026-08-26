import AppKit
import OpenRecord
import SwiftUI

struct TimelineView: View {
    @Bindable var session: EditorSession
    @State private var drag: TimelineDrag?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: session.togglePlay) {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(!session.hasVideo)
                .help("Play / Pause  Space")

                Text(Timecode.string(session.playhead))
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                Text("/")
                    .foregroundStyle(.tertiary)
                Text(Timecode.string(session.timelineDuration))
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
                if !session.document.editDecisions.isEmpty {
                    Text("Output \(Timecode.string(session.outputPlayhead)) / \(Timecode.string(session.outputDuration))")
                        .font(.system(.caption2, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(String(format: "%.2g×", session.currentPlaybackRate))
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(
                        session.currentPlaybackRate == 1 ? Color.secondary : Color.orange
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.06), in: Capsule())

                Spacer()

                Menu("Add") {
                    Button("Zoom") { session.addZoomAtPlayhead() }
                        .disabled(!session.canAddZoomAtPlayhead)
                    Button("Speed Region") { session.addSpeedAtPlayhead() }
                        .disabled(!session.canAddSpeedAtPlayhead)
                    Button("Caption") { session.addCaptionAtPlayhead() }
                    Menu("Annotation") {
                        Button("Text Callout") { session.addAnnotationAtPlayhead(kind: .text) }
                        Button("Arrow") { session.addAnnotationAtPlayhead(kind: .arrow) }
                        Button("Spotlight") { session.addAnnotationAtPlayhead(kind: .spotlight) }
                    }
                    Divider()
                    Button("Import Captions…") { session.importCaptionsPanel() }
                }
                Button("Delete") {
                    session.deleteSelectedTimelineItem()
                }
                .disabled(
                    session.selectedZoomID == nil
                        && session.selectedSpeedID == nil
                        && session.selectedCaptionID == nil
                        && session.selectedAnnotationID == nil
                )
                .help("Delete  ⌫")
            }
            .controlSize(.small)

            GeometryReader { geo in
                timeline(size: geo.size)
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func timeline(size: CGSize) -> some View {
        let duration = session.timelineDuration
        let trimIn = session.document.trimIn
        let trimOut = session.effectiveTrimOut

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            ticks(width: size.width, duration: duration)

            trimShade(from: 0, to: trimIn, width: size.width, height: size.height)
            trimShade(from: trimOut, to: duration, width: size.width, height: size.height)

            ForEach(session.document.editDecisions) { decision in
                cutShade(decision, width: size.width, height: size.height)
            }

            ForEach(session.document.zoomRanges) { range in
                zoomBlock(range, width: size.width, height: size.height)
            }

            ForEach(session.document.speedSegments) { segment in
                speedBlock(segment, width: size.width, height: size.height)
            }

            ForEach(session.document.captions) { cue in
                captionBlock(cue, width: size.width)
            }

            ForEach(session.document.annotations) { annotation in
                annotationBlock(annotation, width: size.width)
            }

            playhead(width: size.width, height: size.height)

            trimHandle(time: trimIn, width: size.width, height: size.height)
            trimHandle(time: trimOut, width: size.width, height: size.height)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(width: size.width, height: size.height, duration: duration))
        .onHover { hovering in
            if !hovering {
                NSCursor.arrow.set()
            }
        }
    }

    private func ticks(width: CGFloat, duration: TimeInterval) -> some View {
        let step: TimeInterval = duration > 60 ? 10 : (duration > 20 ? 5 : 1)
        let count = Int(duration / step)
        return ZStack(alignment: .topLeading) {
            ForEach(0...max(count, 0), id: \.self) { index in
                let time = TimeInterval(index) * step
                if time <= duration {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 7)
                        .offset(x: xPosition(time, width: width))
                    Text(Timecode.compact(time))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .offset(x: xPosition(time, width: width) + 3, y: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func zoomBlock(_ range: ZoomRange, width: CGFloat, height: CGFloat) -> some View {
        let x0 = xPosition(range.start, width: width)
        let x1 = xPosition(range.end, width: width)
        let selected = range.id == session.selectedZoomID
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 0.72 : 0.38))
            .overlay(alignment: .leading) {
                Capsule().fill(.white.opacity(0.7)).frame(width: 3, height: 18)
            }
            .overlay(alignment: .trailing) {
                Capsule().fill(.white.opacity(0.7)).frame(width: 3, height: 18)
            }
            .overlay {
                Text(String(format: "%.1f×", range.amount))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: max(x1 - x0, 8), height: 20)
            .offset(x: x0, y: 61)
    }

    private func speedBlock(_ segment: SpeedSegment, width: CGFloat, height: CGFloat) -> some View {
        let x0 = xPosition(segment.start, width: width)
        let x1 = xPosition(segment.end, width: width)
        let selected = segment.id == session.selectedSpeedID
        let color: Color = segment.rate < 1 ? .blue : .orange
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color.opacity(selected ? 0.88 : 0.55))
            .overlay(alignment: .leading) {
                Capsule().fill(.white.opacity(0.75)).frame(width: 2, height: 11)
            }
            .overlay(alignment: .trailing) {
                Capsule().fill(.white.opacity(0.75)).frame(width: 2, height: 11)
            }
            .overlay {
                Text(String(format: "%.2g×", segment.rate))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.white.opacity(0.85), lineWidth: 1)
                }
            }
            .frame(width: max(x1 - x0, 8), height: 14)
            .offset(x: x0, y: height - 18)
    }

    private func captionBlock(_ cue: CaptionCue, width: CGFloat) -> some View {
        let x0 = xPosition(cue.start, width: width)
        let x1 = xPosition(cue.end, width: width)
        let selected = cue.id == session.selectedCaptionID
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.purple.opacity(selected ? 0.88 : 0.52))
            .overlay {
                Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            }
            .frame(width: max(x1 - x0, 8), height: 16)
            .offset(x: x0, y: 22)
    }

    private func annotationBlock(_ annotation: Annotation, width: CGFloat) -> some View {
        let x0 = xPosition(annotation.start, width: width)
        let x1 = xPosition(annotation.end, width: width)
        let selected = annotation.id == session.selectedAnnotationID
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.green.opacity(selected ? 0.88 : 0.52))
            .overlay {
                Text(annotation.kind.rawValue.capitalized)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: max(x1 - x0, 8), height: 16)
            .offset(x: x0, y: 42)
    }

    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let x = xPosition(session.playhead, width: width)
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: height)
            .offset(x: x)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: x - 3, y: -1)
            }
            .allowsHitTesting(false)
    }

    private func trimHandle(time: TimeInterval, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.55))
            .frame(width: 3, height: height)
            .offset(x: xPosition(time, width: width))
            .allowsHitTesting(false)
    }

    private func trimShade(from start: TimeInterval, to end: TimeInterval, width: CGFloat, height: CGFloat) -> some View {
        let x0 = xPosition(start, width: width)
        let x1 = xPosition(end, width: width)
        return Rectangle()
            .fill(Color.black.opacity(0.28))
            .frame(width: max(x1 - x0, 0), height: height)
            .offset(x: x0)
            .allowsHitTesting(false)
    }

    private func cutShade(
        _ decision: EditDecision,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let x0 = xPosition(decision.start, width: width)
        let x1 = xPosition(decision.end, width: width)
        return Rectangle()
            .fill(Color.red.opacity(0.16))
            .overlay(alignment: .top) {
                Text("CUT")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.top, 2)
            }
            .frame(width: max(x1 - x0, 1), height: height)
            .offset(x: x0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func dragGesture(
        width: CGFloat,
        height: CGFloat,
        duration: TimeInterval
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = timeAt(value.location.x, width: width, duration: duration)
                if drag == nil {
                    drag = hit(
                        at: value.location,
                        width: width,
                        height: height,
                        duration: duration
                    )
                    if let actionName = drag?.undoActionName {
                        session.beginDocumentEdit(actionName: actionName)
                    }
                    if case .zoomBody(let id, _, _, _) = drag {
                        session.selectZoom(id)
                    }
                    if case .zoomStart(let id) = drag {
                        session.selectZoom(id)
                    }
                    if case .zoomEnd(let id) = drag {
                        session.selectZoom(id)
                    }
                    if case .speedBody(let id, _, _, _) = drag {
                        session.selectSpeed(id)
                    }
                    if case .captionBody(let id, _, _, _) = drag {
                        session.selectCaption(id)
                    }
                    if case .captionStart(let id) = drag { session.selectCaption(id) }
                    if case .captionEnd(let id) = drag { session.selectCaption(id) }
                    if case .annotationBody(let id, _, _, _) = drag {
                        session.selectAnnotation(id)
                    }
                    if case .annotationStart(let id) = drag { session.selectAnnotation(id) }
                    if case .annotationEnd(let id) = drag { session.selectAnnotation(id) }
                    if case .speedStart(let id) = drag {
                        session.selectSpeed(id)
                    }
                    if case .speedEnd(let id) = drag {
                        session.selectSpeed(id)
                    }
                }
                apply(drag: drag, time: time)
            }
            .onEnded { _ in
                session.endDocumentEdit()
                drag = nil
                NSCursor.arrow.set()
            }
    }

    private func apply(drag: TimelineDrag?, time: TimeInterval) {
        switch drag {
        case .playhead, .none:
            session.seek(to: time)
        case .trimIn:
            session.setTrimIn(time)
            session.seek(to: session.document.trimIn)
        case .trimOut:
            session.setTrimOut(time)
            session.seek(to: session.effectiveTrimOut)
        case .zoomStart(let id):
            guard var range = session.document.zoomRanges.first(where: { $0.id == id }) else { return }
            let (lower, upper) = session.zoomNeighborBounds(excluding: id)
            guard let edited = TimelineRangeEditing.resizingStart(
                TimelineEditRange(start: range.start, end: range.end),
                to: time,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: ZoomInsertion.minimumDuration
            ) else { return }
            range.start = edited.start
            range.end = edited.end
            session.replaceZoom(range)
        case .zoomEnd(let id):
            guard var range = session.document.zoomRanges.first(where: { $0.id == id }) else { return }
            let (lower, upper) = session.zoomNeighborBounds(excluding: id)
            guard let edited = TimelineRangeEditing.resizingEnd(
                TimelineEditRange(start: range.start, end: range.end),
                to: time,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: ZoomInsertion.minimumDuration
            ) else { return }
            range.start = edited.start
            range.end = edited.end
            session.replaceZoom(range)
        case .zoomBody(let id, let originalStart, let originalEnd, let grab):
            let (lower, upper) = session.zoomNeighborBounds(excluding: id, referenceStart: originalStart)
            guard var range = session.document.zoomRanges.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.moving(
                TimelineEditRange(start: originalStart, end: originalEnd),
                toStart: time - grab,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: ZoomInsertion.minimumDuration
            ) else { return }
            range.start = edited.start
            range.end = edited.end
            session.replaceZoom(range)
        case .speedStart(let id):
            guard var segment = session.document.speedSegments.first(where: { $0.id == id })
            else { return }
            let (lower, upper) = session.speedNeighborBounds(excluding: id)
            guard let edited = TimelineRangeEditing.resizingStart(
                TimelineEditRange(start: segment.start, end: segment.end),
                to: time,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: SpeedTimeline.minimumSegmentDuration
            ) else { return }
            segment.start = edited.start
            segment.end = edited.end
            session.replaceSpeedSegment(segment)
        case .speedEnd(let id):
            guard var segment = session.document.speedSegments.first(where: { $0.id == id })
            else { return }
            let (lower, upper) = session.speedNeighborBounds(excluding: id)
            guard let edited = TimelineRangeEditing.resizingEnd(
                TimelineEditRange(start: segment.start, end: segment.end),
                to: time,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: SpeedTimeline.minimumSegmentDuration
            ) else { return }
            segment.start = edited.start
            segment.end = edited.end
            session.replaceSpeedSegment(segment)
        case .speedBody(let id, let originalStart, let originalEnd, let grab):
            let (lower, upper) = session.speedNeighborBounds(
                excluding: id,
                referenceStart: originalStart
            )
            guard var segment = session.document.speedSegments.first(where: { $0.id == id })
            else { return }
            guard let edited = TimelineRangeEditing.moving(
                TimelineEditRange(start: originalStart, end: originalEnd),
                toStart: time - grab,
                lowerBound: max(0, lower),
                upperBound: min(session.timelineDuration, upper),
                minimumDuration: SpeedTimeline.minimumSegmentDuration
            ) else { return }
            segment.start = edited.start
            segment.end = edited.end
            session.replaceSpeedSegment(segment)
        case .captionStart(let id):
            guard var cue = session.document.captions.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.resizingStart(
                TimelineEditRange(start: cue.start, end: cue.end),
                to: time,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            cue.start = edited.start
            cue.end = edited.end
            session.replaceCaption(cue)
        case .captionEnd(let id):
            guard var cue = session.document.captions.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.resizingEnd(
                TimelineEditRange(start: cue.start, end: cue.end),
                to: time,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            cue.start = edited.start
            cue.end = edited.end
            session.replaceCaption(cue)
        case .captionBody(let id, let originalStart, let originalEnd, let grab):
            guard var cue = session.document.captions.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.moving(
                TimelineEditRange(start: originalStart, end: originalEnd),
                toStart: time - grab,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            cue.start = edited.start
            cue.end = edited.end
            session.replaceCaption(cue)
        case .annotationStart(let id):
            guard var annotation = session.document.annotations.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.resizingStart(
                TimelineEditRange(start: annotation.start, end: annotation.end),
                to: time,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            annotation.start = edited.start
            annotation.end = edited.end
            session.replaceAnnotation(annotation)
        case .annotationEnd(let id):
            guard var annotation = session.document.annotations.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.resizingEnd(
                TimelineEditRange(start: annotation.start, end: annotation.end),
                to: time,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            annotation.start = edited.start
            annotation.end = edited.end
            session.replaceAnnotation(annotation)
        case .annotationBody(let id, let originalStart, let originalEnd, let grab):
            guard var annotation = session.document.annotations.first(where: { $0.id == id }) else { return }
            guard let edited = TimelineRangeEditing.moving(
                TimelineEditRange(start: originalStart, end: originalEnd),
                toStart: time - grab,
                lowerBound: 0,
                upperBound: session.timelineDuration,
                minimumDuration: TimelineRangeEditing.minimumOverlayDuration
            ) else { return }
            annotation.start = edited.start
            annotation.end = edited.end
            session.replaceAnnotation(annotation)
        }
    }

    private func hit(
        at point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        duration: TimeInterval
    ) -> TimelineDrag {
        let x = point.x
        let handle: CGFloat = 7
        let time = timeAt(x, width: width, duration: duration)
        let handleTime = TimeInterval(handle / max(width, 1)) * duration
        let minimumVisibleTime = TimeInterval(8 / max(width, 1)) * duration

        func rangeHit(_ ranges: [TimelineHitRange]) -> TimelineRangeHit? {
            TimelineHitTesting.hit(
                at: time,
                ranges: ranges,
                handleTolerance: handleTime,
                minimumVisibleDuration: minimumVisibleTime
            )
        }

        if point.y >= height - 26 {
            let items = session.document.speedSegments.map {
                TimelineHitRange(id: $0.id, start: $0.start, end: $0.end)
            }
            if let hit = rangeHit(items),
               let segment = session.document.speedSegments.first(where: { $0.id == hit.id })
            {
                switch hit {
                case .start(let id): return .speedStart(id)
                case .end(let id): return .speedEnd(id)
                case .body(let id, let grab):
                    return .speedBody(id, start: segment.start, end: segment.end, grab: grab)
                }
            }
        }

        if point.y >= 40, point.y < 60 {
            let items = session.document.annotations.map {
                TimelineHitRange(id: $0.id, start: $0.start, end: $0.end)
            }
            if let hit = rangeHit(items),
               let annotation = session.document.annotations.first(where: { $0.id == hit.id })
            {
                switch hit {
                case .start(let id): return .annotationStart(id)
                case .end(let id): return .annotationEnd(id)
                case .body(let id, let grab):
                    return .annotationBody(id, start: annotation.start, end: annotation.end, grab: grab)
                }
            }
        }

        if point.y >= 18, point.y < 38 {
            let items = session.document.captions.map {
                TimelineHitRange(id: $0.id, start: $0.start, end: $0.end)
            }
            if let hit = rangeHit(items),
               let cue = session.document.captions.first(where: { $0.id == hit.id })
            {
                switch hit {
                case .start(let id): return .captionStart(id)
                case .end(let id): return .captionEnd(id)
                case .body(let id, let grab):
                    return .captionBody(id, start: cue.start, end: cue.end, grab: grab)
                }
            }
        }

        if point.y >= 58, point.y < 84 {
            let items = session.document.zoomRanges.map {
                TimelineHitRange(id: $0.id, start: $0.start, end: $0.end)
            }
            if let hit = rangeHit(items),
               let range = session.document.zoomRanges.first(where: { $0.id == hit.id })
            {
                switch hit {
                case .start(let id): return .zoomStart(id)
                case .end(let id): return .zoomEnd(id)
                case .body(let id, let grab):
                    return .zoomBody(id, start: range.start, end: range.end, grab: grab)
                }
            }
        }

        // Track items win within their lanes so a range can still be selected
        // when it touches a trim boundary. Elsewhere, choose the nearest trim
        // handle deterministically when their hit regions overlap.
        let trimInX = xPosition(session.document.trimIn, width: width)
        let trimOutX = xPosition(session.effectiveTrimOut, width: width)
        let trimInDistance = abs(x - trimInX)
        let trimOutDistance = abs(x - trimOutX)
        if min(trimInDistance, trimOutDistance) <= handle {
            return trimInDistance <= trimOutDistance ? .trimIn : .trimOut
        }
        return .playhead
    }

    private func xPosition(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat(time / session.timelineDuration) * width
    }

    private func timeAt(_ x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        min(max(TimeInterval(x / max(width, 1)) * duration, 0), duration)
    }
}

private enum TimelineDrag {
    case playhead
    case trimIn
    case trimOut
    case zoomStart(UUID)
    case zoomEnd(UUID)
    case zoomBody(UUID, start: TimeInterval, end: TimeInterval, grab: TimeInterval)
    case speedStart(UUID)
    case speedEnd(UUID)
    case speedBody(UUID, start: TimeInterval, end: TimeInterval, grab: TimeInterval)
    case captionStart(UUID)
    case captionEnd(UUID)
    case captionBody(UUID, start: TimeInterval, end: TimeInterval, grab: TimeInterval)
    case annotationStart(UUID)
    case annotationEnd(UUID)
    case annotationBody(UUID, start: TimeInterval, end: TimeInterval, grab: TimeInterval)

    var undoActionName: String? {
        switch self {
        case .playhead:
            nil
        case .trimIn, .trimOut:
            "Adjust Trim"
        case .zoomStart, .zoomEnd, .zoomBody:
            "Adjust Zoom"
        case .speedStart, .speedEnd, .speedBody:
            "Adjust Speed Region"
        case .captionStart, .captionEnd, .captionBody:
            "Adjust Caption"
        case .annotationStart, .annotationEnd, .annotationBody:
            "Adjust Annotation"
        }
    }
}
