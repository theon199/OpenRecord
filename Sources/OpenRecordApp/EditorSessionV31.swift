import Foundation
import OpenRecord

@MainActor
extension EditorSession {
    var selectedRedaction: RedactionRegion? {
        guard let selectedRedactionID else { return nil }
        return document.redactions.first { $0.id == selectedRedactionID }
    }

    var selectedDrawing: DrawingStroke? {
        guard let selectedDrawingID else { return nil }
        return document.drawings.first { $0.id == selectedDrawingID }
    }

    func selectRedaction(_ id: UUID?) {
        applyDocumentSelection(id.map(EditorDocumentSelection.redaction))
    }

    func selectDrawing(_ id: UUID?) {
        applyDocumentSelection(id.map(EditorDocumentSelection.drawing))
    }

    func addRedactionAtPlayhead(mode: RedactionMode = .blur) {
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 3, timelineDuration)
        guard end - start >= TimelineRangeEditing.minimumOverlayDuration else { return }
        let before = document
        let region = RedactionRegion(start: start, end: end, mode: mode).normalized
        document.redactions.append(region)
        document.redactions.sort(by: Self.v31RangeOrder)
        selectRedaction(region.id)
        documentDidChange(from: before, actionName: "Add Redaction")
    }

    func updateSelectedRedaction(
        actionName: String = "Edit Redaction",
        _ body: (inout RedactionRegion) -> Void
    ) {
        guard let selectedRedactionID,
              let index = document.redactions.firstIndex(where: { $0.id == selectedRedactionID })
        else { return }
        let before = document
        body(&document.redactions[index])
        document.redactions[index] = document.redactions[index].normalized
        document.redactions.sort(by: Self.v31RangeOrder)
        documentDidChange(from: before, actionName: actionName)
    }

    func replaceRedaction(_ region: RedactionRegion) {
        guard let index = document.redactions.firstIndex(where: { $0.id == region.id }) else {
            return
        }
        let before = document
        document.redactions[index] = region.normalized
        document.redactions.sort(by: Self.v31RangeOrder)
        documentDidChange(from: before, actionName: "Adjust Redaction")
    }

    func setDrawingMode(_ tool: DrawingTool?) {
        pause()
        activeDrawingTool = tool
        if tool == .highlighter, drawingWidth < 18 {
            drawingWidth = 24
        } else if tool == .pen, drawingWidth > 18 {
            drawingWidth = 8
        }
    }

    @discardableResult
    func addDrawingStroke(points: [Point2D], tool: DrawingTool) -> UUID? {
        guard points.count >= 2 else { return nil }
        let start = min(max(playhead, 0), timelineDuration)
        let end = min(start + 3, timelineDuration)
        guard end - start >= TimelineRangeEditing.minimumOverlayDuration else { return nil }
        let before = document
        let stroke = DrawingStroke(
            start: start,
            end: end,
            tool: tool,
            points: points,
            color: drawingColor,
            width: drawingWidth
        ).normalized
        document.drawings.append(stroke)
        document.drawings.sort(by: Self.v31RangeOrder)
        selectDrawing(stroke.id)
        documentDidChange(from: before, actionName: "Draw Stroke")
        return stroke.id
    }

    func replaceDrawing(_ stroke: DrawingStroke) {
        guard let index = document.drawings.firstIndex(where: { $0.id == stroke.id }) else {
            return
        }
        let before = document
        document.drawings[index] = stroke.normalized
        document.drawings.sort(by: Self.v31RangeOrder)
        documentDidChange(from: before, actionName: "Adjust Drawing")
    }

    func updateSelectedDrawing(
        actionName: String = "Edit Drawing",
        _ body: (inout DrawingStroke) -> Void
    ) {
        guard let selectedDrawingID,
              let index = document.drawings.firstIndex(where: { $0.id == selectedDrawingID })
        else { return }
        let before = document
        body(&document.drawings[index])
        document.drawings[index] = document.drawings[index].normalized
        documentDidChange(from: before, actionName: actionName)
    }

    func updateDeviceFrame(
        actionName: String = "Change Device Frame",
        _ body: (inout DeviceFrameSettings) -> Void
    ) {
        let before = document
        body(&document.deviceFrame)
        document.deviceFrame = document.deviceFrame.normalized
        documentDidChange(from: before, actionName: actionName)
    }

    private static func v31RangeOrder<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool
    where T.ID == UUID {
        func start(_ item: T) -> TimeInterval {
            if let redaction = item as? RedactionRegion { return redaction.start }
            if let drawing = item as? DrawingStroke { return drawing.start }
            return 0
        }
        let left = start(lhs)
        let right = start(rhs)
        return left == right ? lhs.id.uuidString < rhs.id.uuidString : left < right
    }
}
