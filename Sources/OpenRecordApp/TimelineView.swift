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

                Spacer()

                Button("Add Zoom") {
                    session.addZoomAtPlayhead()
                }
                .help("Add a zoom at the playhead")
                Button("Delete Zoom") {
                    session.deleteSelectedZoom()
                }
                .disabled(session.selectedZoomID == nil)
                .help("Delete  ⌫")
            }
            .controlSize(.small)

            GeometryReader { geo in
                timeline(size: geo.size)
            }
            .frame(height: 64)
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

            ForEach(session.document.zoomRanges) { range in
                zoomBlock(range, width: size.width, height: size.height)
            }

            playhead(width: size.width, height: size.height)

            trimHandle(time: trimIn, width: size.width, height: size.height)
            trimHandle(time: trimOut, width: size.width, height: size.height)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(width: size.width, duration: duration))
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
            .frame(width: max(x1 - x0, 8), height: 28)
            .offset(x: x0, y: (height - 28) / 2)
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

    private func dragGesture(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = timeAt(value.location.x, width: width, duration: duration)
                if drag == nil {
                    drag = hit(at: value.location.x, width: width, duration: duration)
                    if case .zoomBody(let id, _, _, _) = drag {
                        session.selectedZoomID = id
                    }
                    if case .zoomStart(let id) = drag {
                        session.selectedZoomID = id
                    }
                    if case .zoomEnd(let id) = drag {
                        session.selectedZoomID = id
                    }
                }
                apply(drag: drag, time: time)
            }
            .onEnded { _ in
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
            let (lower, _) = session.zoomNeighborBounds(excluding: id)
            range.start = min(max(time, lower), range.end - 0.12)
            session.replaceZoom(range)
        case .zoomEnd(let id):
            guard var range = session.document.zoomRanges.first(where: { $0.id == id }) else { return }
            let (_, upper) = session.zoomNeighborBounds(excluding: id)
            range.end = max(min(time, upper), range.start + 0.12)
            session.replaceZoom(range)
        case .zoomBody(let id, let originalStart, let originalEnd, let grab):
            let span = originalEnd - originalStart
            let (lower, upper) = session.zoomNeighborBounds(excluding: id, referenceStart: originalStart)
            let lo = max(0, lower)
            let hi = min(session.timelineDuration, upper)
            let maxStart = max(lo, hi - span)
            let start = min(max(time - grab, lo), maxStart)
            guard var range = session.document.zoomRanges.first(where: { $0.id == id }) else { return }
            range.start = start
            range.end = start + span
            session.replaceZoom(range)
        }
    }

    private func hit(at x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimelineDrag {
        let handle: CGFloat = 7
        let trimInX = xPosition(session.document.trimIn, width: width)
        let trimOutX = xPosition(session.effectiveTrimOut, width: width)
        if abs(x - trimInX) <= handle { return .trimIn }
        if abs(x - trimOutX) <= handle { return .trimOut }

        for range in session.document.zoomRanges.reversed() {
            let x0 = xPosition(range.start, width: width)
            let x1 = xPosition(range.end, width: width)
            if abs(x - x0) <= handle { return .zoomStart(range.id) }
            if abs(x - x1) <= handle { return .zoomEnd(range.id) }
            if x >= x0, x <= x1 {
                let t = timeAt(x, width: width, duration: duration)
                return .zoomBody(range.id, start: range.start, end: range.end, grab: t - range.start)
            }
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
}
