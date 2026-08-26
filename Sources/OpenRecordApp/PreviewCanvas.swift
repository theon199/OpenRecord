import AppKit
import AVFoundation
import CoreImage
import OpenRecord
import SwiftUI

struct PreviewCanvas: View {
    @Bindable var session: EditorSession
    @State private var anchorDrag: ZoomAnchorDrag?
    @State private var webcamDrag: WebcamOverlayDrag?
    @State private var webcamResize: WebcamOverlayResize?
    @State private var annotationDrag: AnnotationDrag?
    @State private var annotationResize: AnnotationResize?
    @State private var arrowEndpointDrag: ArrowEndpointDrag?
    @State private var redactionDrag: RedactionDrag?
    @State private var redactionResize: RedactionResize?
    @State private var drawingDraftPoints: [Point2D] = []

    var body: some View {
        GeometryReader { geo in
            // The UI playhead is displayed on the source-authored timeline,
            // but every preview track resolves through the same composed
            // output/edit/speed mapper used by export. This canonicalizes cut
            // boundaries before any source-timed telemetry or overlay lookup.
            let sourceTime = session.previewSourceTime
            let liveCrop = session.engine.crop(at: sourceTime)
            let crop = anchorDrag?.cropUV ?? liveCrop
            let cursor = session.engine.interpolateCursor(at: sourceTime)
            let cursorVelocity = session.engine.cursorVelocity(at: sourceTime)
            let clicking = session.engine.isClicking(at: sourceTime)
            let canvas = session.document.canvas
            let cursorTreatment = CursorTreatmentEvaluator(
                ranges: session.document.cursorEffects
            ).state(
                at: sourceTime,
                baseScale: canvas.cursorScale,
                baseClickEmphasis: canvas.cursorClickEmphasis,
                baseHalo: canvas.cursorHalo
            )
            let sourceWidth = session.sourceWidth
            let sourceHeight = session.sourceHeight
            let layout = ExportLayout.canvasLayout(
                canvas: canvas,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                cropUV: crop,
                resolution: session.document.videoExportSettings.resolution
            )
            let outer = ExportLayout.aspectFit(layout.size, in: CGRect(origin: .zero, size: geo.size))
            let viewScale = outer.width / CGFloat(max(layout.width, 1))
            let authoredViewScale = viewScale
                * ExportLayout.authoredContentScale(for: layout.size)
            let cursorMotionBlur = CursorMotionBlurEffect.state(
                velocity: cursorVelocity,
                canvasSize: layout.size,
                settings: canvas.cursorMotionBlur
            )
            let deviceGeometry = DeviceFrameLayout.geometry(
                settings: session.document.deviceFrame,
                contentRect: layout.videoRect
            )
            let video = mapRect(deviceGeometry.screenRect, from: layout.size, into: outer)
            let screenCorner = session.document.deviceFrame.enabled
                ? Double(deviceGeometry.cornerRadius * 0.55)
                : layout.cornerRadius
            let corner = screenCorner * Double(viewScale)
            let clickAge = clicking
                ? ExportLayout.primaryClickAge(at: sourceTime, clicks: session.engine.smoother.clicks)
                : nil
            let keyboardState = session.keyboardTimeline.state(
                at: sourceTime,
                settings: session.document.keyboardOverlay
            )

            ZStack(alignment: .topLeading) {
                canvasFill(canvas.background)
                    .frame(width: outer.width, height: outer.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .position(x: outer.midX, y: outer.midY)

                deviceFrameShell(
                    geometry: deviceGeometry,
                    canvasSize: layout.size,
                    outer: outer,
                    viewScale: viewScale
                )

                videoStack(crop: crop, inner: video, cornerRadius: corner)

                deviceFrameChrome(
                    geometry: deviceGeometry,
                    canvasSize: layout.size,
                    outer: outer,
                    viewScale: viewScale
                )

                if let webcamPlayer = session.webcamPlayer,
                   session.webcamIsVisible(at: sourceTime)
                {
                    webcamOverlay(
                        player: webcamPlayer,
                        canvasSize: layout.size,
                        outer: outer,
                        viewScale: viewScale,
                        mirror: session.meta.webcam?.mirror ?? false
                    )
                }

                if cursorTreatment.visible, let cursor {
                    cursorOverlay(
                        cursor: cursor,
                        clicking: clicking && cursorTreatment.clickEmphasis,
                        clickAge: clickAge,
                        treatment: cursorTreatment,
                        crop: crop,
                            canvasVideo: deviceGeometry.screenRect,
                        viewVideo: video,
                        viewScale: viewScale,
                        sourceWidth: sourceWidth,
                        motionBlur: cursorMotionBlur
                    )
                }

                keyboardOverlay(
                    state: keyboardState,
                    canvasSize: layout.size,
                    canvasPadding: canvas.padding,
                    outer: outer,
                    viewScale: viewScale
                )

                ForEach(session.document.captions.filter { $0.isActive(at: sourceTime) }) { caption in
                    captionOverlay(caption, outer: outer, viewScale: authoredViewScale)
                }

                ForEach(session.document.annotations.filter { $0.isActive(at: sourceTime) }) { annotation in
                    annotationOverlay(
                        annotation,
                        at: sourceTime,
                        outer: outer,
                        viewScale: authoredViewScale
                    )
                }

                ForEach(session.document.drawings.filter { $0.isActive(at: sourceTime) }) { drawing in
                    drawingOverlay(drawing, outer: outer, viewScale: authoredViewScale)
                }

                if !drawingDraftPoints.isEmpty {
                    drawingPath(
                        points: drawingDraftPoints,
                        outer: outer,
                        width: session.drawingWidth * Double(authoredViewScale)
                    )
                    .stroke(
                        session.drawingColor.swiftUIColor.opacity(
                            session.activeDrawingTool == .highlighter ? 0.35 : 1
                        ),
                        style: StrokeStyle(
                            lineWidth: CGFloat(session.drawingWidth) * authoredViewScale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .allowsHitTesting(false)
                }

                ForEach(session.document.redactions.filter { $0.isActive(at: sourceTime) }) { region in
                    redactionOverlay(region, outer: outer, viewScale: viewScale)
                }

                if let zoom = session.selectedZoom {
                    zoomAnchorOverlay(
                        zoom: zoom,
                        crop: crop,
                        video: video
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .gesture(
                drawingGesture(outer: outer),
                including: session.activeDrawingTool == nil ? .subviews : .all
            )
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func captionOverlay(_ caption: CaptionCue, outer: CGRect, viewScale: CGFloat) -> some View {
        let style = caption.style
        let x = outer.minX + CGFloat(caption.style.position.defaultAnchor.x) * outer.width
        let y = outer.minY + CGFloat(caption.style.position.defaultAnchor.y) * outer.height
        let maxWidth = outer.width * CGFloat(style.maxWidth)
        let horizontalPadding = 18 * viewScale
        let verticalPadding = 12 * viewScale
        let textMaxWidth = max(maxWidth - horizontalPadding * 2, 1)
        return Text(caption.text)
            .font(.custom("SF Pro Display", size: style.fontSize * Double(viewScale)))
            .foregroundStyle(style.foreground.swiftUIColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: textMaxWidth)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(style.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 6 * viewScale, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6 * viewScale, style: .continuous)
                    .stroke(caption.id == session.selectedCaptionID ? .white : .clear, lineWidth: 1)
            )
            .position(x: x, y: y)
            .contentShape(Rectangle())
            .onTapGesture { session.selectCaption(caption.id) }
            .accessibilityLabel("Caption \(caption.text)")
    }

    private func annotationOverlay(
        _ annotation: Annotation,
        at time: TimeInterval,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        let presentation = AnnotationAnimationEvaluator.presentation(
            for: annotation,
            at: time
        )
        return annotationContent(annotation, outer: outer, viewScale: viewScale)
            .opacity(presentation.opacity)
            .scaleEffect(presentation.scale)
    }

    @ViewBuilder
    private func annotationContent(
        _ annotation: Annotation,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        let selected = annotation.id == session.selectedAnnotationID
        switch annotation.kind {
        case .text:
            let horizontalPadding = 16 * viewScale
            let verticalPadding = 12 * viewScale
            let maxWidth = outer.width * 0.7
            Text(annotation.text.isEmpty ? "Annotation" : annotation.text)
                .font(.custom("SF Pro Display", size: annotation.fontSize * Double(viewScale)))
                .foregroundStyle(annotation.color.swiftUIColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: max(maxWidth - horizontalPadding * 2, 1))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(annotation.background.swiftUIColor, in: RoundedRectangle(cornerRadius: 5 * viewScale, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5 * viewScale).stroke(selected ? .white : .clear, lineWidth: 1))
                .position(canvasPoint(annotation.position, in: outer))
                .gesture(annotationMoveGesture(annotation, outer: outer))
                .onTapGesture { session.selectAnnotation(annotation.id) }
        case .arrow:
            let start = canvasPoint(annotation.position, in: outer)
            let end = canvasPoint(annotation.endPosition, in: outer)
            arrowOverlay(
                annotation,
                start: start,
                end: end,
                selected: selected,
                outer: outer,
                viewScale: viewScale
            )
        case .spotlight:
            let rect = canvasRect(annotation.rect, in: outer)
            spotlightOverlay(
                annotation,
                rect: rect,
                selected: selected,
                outer: outer,
                viewScale: viewScale
            )
        case .box:
            rectOutlineOverlay(
                annotation,
                rect: canvasRect(annotation.rect, in: outer),
                selected: selected,
                outer: outer,
                viewScale: viewScale
            )
        case .underline:
            lineOverlay(
                annotation,
                start: canvasPoint(annotation.position, in: outer),
                end: canvasPoint(annotation.endPosition, in: outer),
                selected: selected,
                outer: outer,
                viewScale: viewScale,
                label: nil
            )
        case .stepMarker:
            let diameter = max(annotation.fontSize * Double(viewScale) * 1.35, 30 * Double(viewScale))
            Text(annotation.text.isEmpty ? "1" : annotation.text)
                .font(.system(size: annotation.fontSize * Double(viewScale), weight: .bold, design: .rounded))
                .foregroundStyle(annotation.background.swiftUIColor)
                .frame(width: diameter, height: diameter)
                .background(annotation.color.swiftUIColor, in: Circle())
                .overlay(Circle().stroke(selected ? .white : .clear, lineWidth: 1))
                .position(canvasPoint(annotation.position, in: outer))
                .gesture(annotationMoveGesture(annotation, outer: outer))
                .onTapGesture { session.selectAnnotation(annotation.id) }
        case .label:
            lineOverlay(
                annotation,
                start: canvasPoint(annotation.position, in: outer),
                end: canvasPoint(annotation.endPosition, in: outer),
                selected: selected,
                outer: outer,
                viewScale: viewScale,
                label: annotation.text.isEmpty ? "Label" : annotation.text
            )
        }
    }

    private func arrowOverlay(
        _ annotation: Annotation,
        start: CGPoint,
        end: CGPoint,
        selected: Bool,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        let inset = max(16 * viewScale, 10)
        let box = CGRect(
            x: min(start.x, end.x) - inset,
            y: min(start.y, end.y) - inset,
            width: max(abs(end.x - start.x) + inset * 2, inset * 2),
            height: max(abs(end.y - start.y) + inset * 2, inset * 2)
        )
        let localStart = CGPoint(x: start.x - box.minX, y: start.y - box.minY)
        let localEnd = CGPoint(x: end.x - box.minX, y: end.y - box.minY)
        let lineWidth = max(2 * viewScale, annotation.fontSize * viewScale / 18)
        let angle = atan2(localEnd.y - localStart.y, localEnd.x - localStart.x)
        let head = max(12 * viewScale, annotation.fontSize * viewScale * 0.55)
        let left = CGPoint(
            x: localEnd.x - head * cos(angle - .pi / 6),
            y: localEnd.y - head * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: localEnd.x - head * cos(angle + .pi / 6),
            y: localEnd.y - head * sin(angle + .pi / 6)
        )

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(annotationMoveGesture(annotation, outer: outer))
                .onTapGesture { session.selectAnnotation(annotation.id) }

            Path { path in
                path.move(to: localStart)
                path.addLine(to: localEnd)
                path.move(to: localEnd)
                path.addLine(to: left)
                path.move(to: localEnd)
                path.addLine(to: right)
            }
            .stroke(
                annotation.color.swiftUIColor,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .allowsHitTesting(false)

            if selected {
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .position(localStart)
                    .contentShape(Circle().inset(by: -7))
                    .highPriorityGesture(
                        arrowEndpointGesture(
                            annotation,
                            endpoint: .start,
                            outer: outer
                        )
                    )
                    .help("Drag to move the arrow start")
                    .accessibilityLabel("Arrow start point")
                Circle()
                    .fill(annotation.color.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .position(localEnd)
                    .contentShape(Circle().inset(by: -7))
                    .highPriorityGesture(
                        arrowEndpointGesture(
                            annotation,
                            endpoint: .end,
                            outer: outer
                        )
                    )
                    .help("Drag to point the arrow")
                    .accessibilityLabel("Arrow end point")
            }
        }
        .frame(width: box.width, height: box.height)
        .position(x: box.midX, y: box.midY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrow annotation")
    }

    private func spotlightOverlay(
        _ annotation: Annotation,
        rect: CGRect,
        selected: Bool,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(outer)
                path.addRoundedRect(
                    in: rect,
                    cornerSize: CGSize(width: 12 * viewScale, height: 12 * viewScale)
                )
            }
            .fill(
                .black.opacity(annotation.dimAmount),
                style: FillStyle(eoFill: true)
            )
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 12 * viewScale, style: .continuous)
                .fill(.clear)
                .stroke(
                    annotation.color.swiftUIColor,
                    lineWidth: max(2 * viewScale, annotation.fontSize * viewScale / 18)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(annotationMoveGesture(annotation, outer: outer))
                .onTapGesture { session.selectAnnotation(annotation.id) }

            if selected {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .position(x: rect.maxX, y: rect.maxY)
                    .gesture(annotationResizeGesture(annotation, outer: outer))
            }
        }
    }

    private func rectOutlineOverlay(
        _ annotation: Annotation,
        rect: CGRect,
        selected: Bool,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10 * viewScale, style: .continuous)
                .fill(.clear)
                .stroke(
                    annotation.color.swiftUIColor,
                    lineWidth: max(2 * viewScale, annotation.fontSize * viewScale / 18)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(annotationMoveGesture(annotation, outer: outer))
                .onTapGesture { session.selectAnnotation(annotation.id) }
            if selected {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .position(x: rect.maxX, y: rect.maxY)
                    .gesture(annotationResizeGesture(annotation, outer: outer))
            }
        }
    }

    private func lineOverlay(
        _ annotation: Annotation,
        start: CGPoint,
        end: CGPoint,
        selected: Bool,
        outer: CGRect,
        viewScale: CGFloat,
        label: String?
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                annotation.color.swiftUIColor,
                style: StrokeStyle(
                    lineWidth: max(2 * viewScale, annotation.fontSize * viewScale / 18),
                    lineCap: .round
                )
            )
            .contentShape(Rectangle())
            .gesture(annotationMoveGesture(annotation, outer: outer))
            .onTapGesture { session.selectAnnotation(annotation.id) }

            if let label {
                Text(label)
                    .font(.system(size: annotation.fontSize * Double(viewScale)))
                    .foregroundStyle(annotation.color.swiftUIColor)
                    .padding(.horizontal, 12 * viewScale)
                    .padding(.vertical, 8 * viewScale)
                    .background(
                        annotation.background.swiftUIColor,
                        in: RoundedRectangle(cornerRadius: 6 * viewScale)
                    )
                    .position(start)
                    .gesture(annotationMoveGesture(annotation, outer: outer))
                    .onTapGesture { session.selectAnnotation(annotation.id) }
            }

            if selected {
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .position(start)
                    .gesture(arrowEndpointGesture(annotation, endpoint: .start, outer: outer))
                Circle()
                    .fill(annotation.color.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .position(end)
                    .gesture(arrowEndpointGesture(annotation, endpoint: .end, outer: outer))
            }
        }
    }

    @ViewBuilder
    private func deviceFrameShell(
        geometry: DeviceFrameGeometry,
        canvasSize: CGSize,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        if session.document.deviceFrame.enabled {
            let rect = mapRect(geometry.frameRect, from: canvasSize, into: outer)
            let color: Color = session.document.deviceFrame.id == .genericBrowserLight
                ? Color(red: 0.9, green: 0.91, blue: 0.93)
                : Color(red: 0.055, green: 0.06, blue: 0.075)
            RoundedRectangle(
                cornerRadius: geometry.cornerRadius * viewScale,
                style: .continuous
            )
            .fill(color)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .shadow(
                color: session.document.deviceFrame.shadow ? .black.opacity(0.45) : .clear,
                radius: session.document.deviceFrame.shadow ? 12 * viewScale : 0,
                y: session.document.deviceFrame.shadow ? 6 * viewScale : 0
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func deviceFrameChrome(
        geometry: DeviceFrameGeometry,
        canvasSize: CGSize,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        if session.document.deviceFrame.enabled {
            let frame = mapRect(geometry.frameRect, from: canvasSize, into: outer)
            switch session.document.deviceFrame.id {
            case .genericBrowserLight:
                HStack(spacing: max(4 * viewScale, 2)) {
                    Circle().fill(.red.opacity(0.85))
                    Circle().fill(.yellow.opacity(0.9))
                    Circle().fill(.green.opacity(0.85))
                }
                .frame(height: max(geometry.chromeHeight * viewScale * 0.35, 5))
                .position(
                    x: frame.minX + max(geometry.chromeHeight * viewScale, 16),
                    y: frame.minY + geometry.chromeHeight * viewScale / 2
                )
            case .genericLaptopDark:
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: frame.width * 0.16, height: max(2 * viewScale, 1))
                    .position(x: frame.midX, y: frame.maxY - geometry.chromeHeight * viewScale * 0.25)
            case .genericPhoneDark:
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: frame.width * 0.12, height: max(3 * viewScale, 1.5))
                    .position(x: frame.midX, y: frame.minY + max(8 * viewScale, 3))
            case .none:
                EmptyView()
            }
        }
    }

    private func drawingPath(points: [Point2D], outer: CGRect, width: Double) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: canvasPoint(first, in: outer))
        for point in points.dropFirst() {
            path.addLine(to: canvasPoint(point, in: outer))
        }
        return path
    }

    private func drawingOverlay(
        _ drawing: DrawingStroke,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        let selected = drawing.id == session.selectedDrawingID
        let alpha = drawing.tool == .highlighter ? 0.35 : drawing.color.a
        let path = drawingPath(points: drawing.points, outer: outer, width: drawing.width)
        return path
            .stroke(
                drawing.color.swiftUIColor.opacity(alpha),
                style: StrokeStyle(
                    lineWidth: CGFloat(drawing.width) * viewScale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .overlay {
                if selected {
                    path.stroke(.white.opacity(0.8), lineWidth: 1)
                }
            }
            .contentShape(path.stroke(style: StrokeStyle(
                lineWidth: max(18, CGFloat(drawing.width) * viewScale)
            )))
            .onTapGesture { session.selectDrawing(drawing.id) }
    }

    @ViewBuilder
    private func redactionOverlay(
        _ region: RedactionRegion,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        let rect = canvasRect(region.rect, in: outer)
        let selected = region.id == session.selectedRedactionID
        ZStack(alignment: .topLeading) {
            RedactionBackdropFilterView(
                mode: region.mode,
                strength: region.strength,
                cornerRadius: 5 * viewScale
            )
            .frame(width: rect.width, height: rect.height)
            .overlay {
                RoundedRectangle(cornerRadius: 5 * viewScale)
                    .stroke(selected ? Color.white : Color.red.opacity(0.65), lineWidth: selected ? 2 : 1)
            }
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .gesture(redactionMoveGesture(region, outer: outer))
            .onTapGesture { session.selectRedaction(region.id) }

            if selected {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .position(x: rect.maxX, y: rect.maxY)
                    .gesture(redactionResizeGesture(region, outer: outer))
            }
        }
    }

    private func drawingGesture(outer: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard session.activeDrawingTool != nil, outer.width > 1, outer.height > 1 else {
                    return
                }
                let point = Point2D(
                    x: min(max(Double((value.location.x - outer.minX) / outer.width), 0), 1),
                    y: min(max(Double((value.location.y - outer.minY) / outer.height), 0), 1)
                )
                if drawingDraftPoints.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.002 }) != false {
                    drawingDraftPoints.append(point)
                }
            }
            .onEnded { _ in
                guard let tool = session.activeDrawingTool else {
                    drawingDraftPoints.removeAll()
                    return
                }
                _ = session.addDrawingStroke(points: drawingDraftPoints, tool: tool)
                drawingDraftPoints.removeAll()
            }
    }

    private func redactionMoveGesture(_ region: RedactionRegion, outer: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if redactionDrag == nil {
                    session.pause()
                    session.beginDocumentEdit(actionName: "Move Redaction")
                    redactionDrag = RedactionDrag(id: region.id, originalRect: region.rect)
                    session.selectRedaction(region.id)
                }
                guard let drag = redactionDrag, drag.id == region.id else { return }
                let dx = Double(value.translation.width / max(outer.width, 1))
                let dy = Double(value.translation.height / max(outer.height, 1))
                session.updateSelectedRedaction(actionName: "Move Redaction") {
                    $0.rect = Rect2D(
                        x: drag.originalRect.x + dx,
                        y: drag.originalRect.y + dy,
                        width: drag.originalRect.width,
                        height: drag.originalRect.height
                    )
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                redactionDrag = nil
            }
    }

    private func redactionResizeGesture(_ region: RedactionRegion, outer: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if redactionResize == nil {
                    session.pause()
                    session.beginDocumentEdit(actionName: "Resize Redaction")
                    redactionResize = RedactionResize(id: region.id, originalRect: region.rect)
                    session.selectRedaction(region.id)
                }
                guard let resize = redactionResize, resize.id == region.id else { return }
                session.updateSelectedRedaction(actionName: "Resize Redaction") {
                    $0.rect = Rect2D(
                        x: resize.originalRect.x,
                        y: resize.originalRect.y,
                        width: resize.originalRect.width
                            + Double(value.translation.width / max(outer.width, 1)),
                        height: resize.originalRect.height
                            + Double(value.translation.height / max(outer.height, 1))
                    )
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                redactionResize = nil
            }
    }

    private func canvasPoint(_ point: Point2D, in outer: CGRect) -> CGPoint {
        let local = AuthoredVisualLayout.point(point, in: outer.size)
        return CGPoint(x: outer.minX + local.x, y: outer.minY + local.y)
    }

    private func canvasRect(_ rect: Rect2D, in outer: CGRect) -> CGRect {
        let local = AuthoredVisualLayout.rect(rect, in: outer.size)
        return local.offsetBy(dx: outer.minX, dy: outer.minY)
    }

    private func annotationMoveGesture(_ annotation: Annotation, outer: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if annotationDrag == nil {
                    session.pause()
                    session.beginDocumentEdit(actionName: "Move Annotation")
                    annotationDrag = AnnotationDrag(id: annotation.id, originalPosition: annotation.position, originalEndPosition: annotation.endPosition, originalRect: annotation.rect)
                    session.selectAnnotation(annotation.id)
                }
                guard let drag = annotationDrag else { return }
                let dx = Double(value.translation.width / max(outer.width, 1))
                let dy = Double(value.translation.height / max(outer.height, 1))
                session.updateSelectedAnnotation {
                    $0.position = Point2D(x: drag.originalPosition.x + dx, y: drag.originalPosition.y + dy)
                    $0.endPosition = Point2D(x: drag.originalEndPosition.x + dx, y: drag.originalEndPosition.y + dy)
                    $0.rect = Rect2D(x: drag.originalRect.x + dx, y: drag.originalRect.y + dy, width: drag.originalRect.width, height: drag.originalRect.height)
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                annotationDrag = nil
            }
    }

    private func annotationResizeGesture(_ annotation: Annotation, outer: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if annotationResize == nil {
                    session.pause()
                    session.beginDocumentEdit(actionName: "Resize Annotation")
                    annotationResize = AnnotationResize(id: annotation.id, originalRect: annotation.rect)
                    session.selectAnnotation(annotation.id)
                }
                guard let resize = annotationResize else { return }
                let width = resize.originalRect.width + Double(value.translation.width / max(outer.width, 1))
                let height = resize.originalRect.height + Double(value.translation.height / max(outer.height, 1))
                session.updateSelectedAnnotation {
                    $0.rect = Rect2D(x: resize.originalRect.x, y: resize.originalRect.y, width: width, height: height)
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                annotationResize = nil
            }
    }

    private func arrowEndpointGesture(
        _ annotation: Annotation,
        endpoint: ArrowEndpoint,
        outer: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if arrowEndpointDrag == nil {
                    session.pause()
                    session.beginDocumentEdit(
                        actionName: endpoint == .start ? "Move Arrow Start" : "Point Arrow"
                    )
                    arrowEndpointDrag = ArrowEndpointDrag(
                        id: annotation.id,
                        endpoint: endpoint,
                        originalPosition: annotation.position,
                        originalEndPosition: annotation.endPosition
                    )
                    session.selectAnnotation(annotation.id)
                }
                guard let drag = arrowEndpointDrag,
                      drag.id == annotation.id,
                      drag.endpoint == endpoint
                else { return }
                let dx = Double(value.translation.width / max(outer.width, 1))
                let dy = Double(value.translation.height / max(outer.height, 1))
                session.updateSelectedAnnotation {
                    switch endpoint {
                    case .start:
                        $0.position = Point2D(
                            x: drag.originalPosition.x + dx,
                            y: drag.originalPosition.y + dy
                        )
                    case .end:
                        $0.endPosition = Point2D(
                            x: drag.originalEndPosition.x + dx,
                            y: drag.originalEndPosition.y + dy
                        )
                    }
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                arrowEndpointDrag = nil
            }
    }

    @ViewBuilder
    private func webcamOverlay(
        player: AVPlayer,
        canvasSize: CGSize,
        outer: CGRect,
        viewScale: CGFloat,
        mirror: Bool
    ) -> some View {
        let settings = session.document.webcamOverlay
        if let geometry = WebcamOverlayLayout.geometry(
            settings: settings,
            canvasSize: canvasSize,
            sourceAspect: session.webcamAspect
        ) {
            let rect = mapRect(geometry.frame, from: canvasSize, into: outer)
            let radius = geometry.cornerRadius * Double(viewScale)
            let shape = WebcamPreviewShape(kind: settings.shape, cornerRadius: radius)
            let border = WebcamOverlayLayout.borderWidth(
                settings: settings,
                frame: geometry.frame
            ) * viewScale
            let contentSize = CGSize(
                width: max(rect.width - border * 2, 1),
                height: max(rect.height - border * 2, 1)
            )
            let contentShape = WebcamPreviewShape(
                kind: settings.shape,
                cornerRadius: max(radius - Double(border), 0)
            )

            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    shape.fill(settings.borderColor.swiftUIColor)
                    PlayerLayerView(player: player, videoGravity: .resizeAspectFill)
                        .scaleEffect(x: mirror ? -1 : 1, y: 1)
                        .frame(width: contentSize.width, height: contentSize.height)
                        .clipShape(contentShape)
                }
                    .frame(width: rect.width, height: rect.height)
                    .overlay(
                        shape.stroke(
                            Color.accentColor,
                            lineWidth: session.isWebcamSelected ? 2 : 0
                        )
                    )
                    .contentShape(shape)
                    .gesture(
                        webcamMoveGesture(
                            canvasSize: canvasSize,
                            viewScale: viewScale
                        )
                    )
                    .onTapGesture { session.selectWebcam() }
                    .onHover { hovering in
                        if webcamDrag != nil {
                            NSCursor.closedHand.set()
                        } else if hovering {
                            NSCursor.openHand.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }

                if session.isWebcamSelected {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .offset(x: 4, y: 4)
                        .contentShape(Circle().inset(by: -6))
                        .gesture(
                            webcamResizeGesture(
                                canvasSize: canvasSize,
                                viewScale: viewScale
                            )
                        )
                        .help("Drag to resize the webcam overlay")
                        .accessibilityLabel("Resize webcam overlay")
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .shadow(
                color: settings.shadow ? .black.opacity(settings.shadowOpacity) : .clear,
                radius: settings.shadow ? settings.shadowRadius * viewScale : 0,
                y: settings.shadow ? settings.shadowRadius * viewScale * 0.5 : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Webcam overlay")
        }
    }

    private func webcamMoveGesture(
        canvasSize: CGSize,
        viewScale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if webcamDrag == nil {
                    session.pause()
                    session.selectWebcam()
                    session.beginDocumentEdit(actionName: "Move Webcam Overlay")
                    webcamDrag = WebcamOverlayDrag(
                        originalSettings: WebcamOverlayLayout.clampedSettings(
                            session.document.webcamOverlay,
                            canvasSize: canvasSize,
                            sourceAspect: session.webcamAspect
                        )
                    )
                }
                guard let webcamDrag else { return }
                let translation = CGSize(
                    width: value.translation.width / max(viewScale, 0.000_001),
                    height: value.translation.height / max(viewScale, 0.000_001)
                )
                let next = WebcamOverlayLayout.moving(
                    webcamDrag.originalSettings,
                    translation: translation,
                    canvasSize: canvasSize,
                    sourceAspect: session.webcamAspect
                )
                session.updateWebcamOverlay(actionName: "Move Webcam Overlay") {
                    $0 = next
                }
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                session.endDocumentEdit()
                webcamDrag = nil
                NSCursor.openHand.set()
            }
    }

    private func webcamResizeGesture(
        canvasSize: CGSize,
        viewScale: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if webcamResize == nil {
                    session.pause()
                    session.selectWebcam()
                    session.beginDocumentEdit(actionName: "Resize Webcam Overlay")
                    webcamResize = WebcamOverlayResize(
                        originalSettings: WebcamOverlayLayout.clampedSettings(
                            session.document.webcamOverlay,
                            canvasSize: canvasSize,
                            sourceAspect: session.webcamAspect
                        )
                    )
                }
                guard let webcamResize else { return }
                let translation = CGSize(
                    width: value.translation.width / max(viewScale, 0.000_001),
                    height: value.translation.height / max(viewScale, 0.000_001)
                )
                let next = WebcamOverlayLayout.resizing(
                    webcamResize.originalSettings,
                    translation: translation,
                    canvasSize: canvasSize,
                    sourceAspect: session.webcamAspect
                )
                session.updateWebcamOverlay(actionName: "Resize Webcam Overlay") {
                    $0 = next
                }
            }
            .onEnded { _ in
                session.endDocumentEdit()
                webcamResize = nil
            }
    }

    @ViewBuilder
    private func keyboardOverlay(
        state: KeyboardOverlayState,
        canvasSize: CGSize,
        canvasPadding: Double,
        outer: CGRect,
        viewScale: CGFloat
    ) -> some View {
        if let geometry = KeyboardOverlayLayout.geometry(
            for: state,
            settings: session.document.keyboardOverlay,
            canvasSize: canvasSize,
            canvasPadding: canvasPadding
        ) {
            let count = min(state.keys.count, geometry.keyRects.count)
            ForEach(0..<count, id: \.self) { index in
                let key = state.keys[index]
                let rect = mapRect(geometry.keyRects[index], from: canvasSize, into: outer)
                Text(key.label)
                    .font(.system(size: geometry.fontSize * viewScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(width: rect.width, height: rect.height)
                    .background(
                        RoundedRectangle(
                            cornerRadius: geometry.cornerRadius * Double(viewScale),
                            style: .continuous
                        )
                        .fill(.black.opacity(0.88))
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: geometry.cornerRadius * Double(viewScale),
                            style: .continuous
                        )
                        .stroke(.white.opacity(0.24), lineWidth: max(1, viewScale))
                    )
                    .opacity(key.opacity)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Keyboard key \(key.label)")
            }
        }
    }

    private func zoomAnchorOverlay(
        zoom: ZoomRange,
        crop: CGRect,
        video: CGRect
    ) -> some View {
        let point = ExportLayout.mapSourceUVToCanvas(
            zoom.anchor,
            cropUV: crop,
            videoRect: video
        )

        return ZStack {
            Circle()
                .fill(.black.opacity(0.7))
                .frame(width: 28, height: 28)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .fill(.white)
                .frame(width: 4, height: 4)
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
        .position(x: point.x, y: point.y)
        .gesture(anchorGesture(zoom: zoom, crop: crop, video: video))
        .onHover { hovering in
            if anchorDrag != nil {
                NSCursor.closedHand.set()
            } else if hovering {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to move this zoom's focal point")
        .accessibilityLabel("Zoom focal point")
        .accessibilityValue(
            "\(Int((zoom.anchor.x * 100).rounded())) percent horizontal, "
                + "\(Int((zoom.anchor.y * 100).rounded())) percent vertical"
        )
        .accessibilityHint("Drag to change the selected zoom's focal point")
    }

    private func anchorGesture(
        zoom: ZoomRange,
        crop: CGRect,
        video: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if anchorDrag == nil {
                    session.pause()
                    session.beginDocumentEdit(actionName: "Move Zoom Anchor")
                    anchorDrag = ZoomAnchorDrag(
                        zoomID: zoom.id,
                        originalAnchor: zoom.anchor,
                        cropUV: crop,
                        videoRect: video
                    )
                }
                guard let anchorDrag,
                      session.selectedZoomID == anchorDrag.zoomID
                else { return }
                let originalPoint = ExportLayout.mapSourceUVToCanvas(
                    anchorDrag.originalAnchor,
                    cropUV: anchorDrag.cropUV,
                    videoRect: anchorDrag.videoRect
                )
                let draggedPoint = CGPoint(
                    x: originalPoint.x + value.translation.width,
                    y: originalPoint.y + value.translation.height
                )
                let anchor = ExportLayout.mapCanvasPointToSourceUV(
                    draggedPoint,
                    cropUV: anchorDrag.cropUV,
                    videoRect: anchorDrag.videoRect
                )
                session.updateSelectedZoom { $0.anchor = anchor }
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                session.endDocumentEdit(rebuildZoomEngine: true)
                anchorDrag = nil
                NSCursor.openHand.set()
            }
    }

    @ViewBuilder
    private func videoStack(crop: CGRect, inner: CGRect, cornerRadius: Double) -> some View {
        let safeCrop = CGRect(
            x: crop.origin.x,
            y: crop.origin.y,
            width: max(crop.width, 0.02),
            height: max(crop.height, 0.02)
        )
        let videoSize = CGSize(
            width: inner.width / safeCrop.width,
            height: inner.height / safeCrop.height
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack(alignment: .topLeading) {
            if session.hasVideo {
                PlayerLayerView(player: session.player)
                    .frame(width: videoSize.width, height: videoSize.height)
                    .offset(x: -safeCrop.minX * videoSize.width, y: -safeCrop.minY * videoSize.height)
            } else {
                ZStack {
                    Color.black.opacity(0.35)
                    Text("No video yet")
                        .foregroundStyle(.secondary)
                }
                .frame(width: videoSize.width, height: videoSize.height)
            }
        }
        .frame(width: inner.width, height: inner.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .position(x: inner.midX, y: inner.midY)
    }

    @ViewBuilder
    private func cursorOverlay(
        cursor: Point2D,
        clicking: Bool,
        clickAge: TimeInterval?,
        treatment: CursorTreatmentState,
        crop: CGRect,
        canvasVideo: CGRect,
        viewVideo: CGRect,
        viewScale: CGFloat,
        sourceWidth: Int,
        motionBlur: CursorMotionBlurState
    ) -> some View {
        let point = ExportLayout.mapSourceUVToCanvas(
            cursor,
            cropUV: crop,
            videoRect: viewVideo
        )
        let pixelsPerPoint = ExportLayout.canvasPixelsPerPoint(
            displayScale: session.meta.scale,
            sourceWidth: sourceWidth,
            cropUV: crop,
            videoRect: canvasVideo
        )
        let viewPixelsPerPoint = pixelsPerPoint * Double(viewScale)

        ZStack {
            if clicking {
                let ripple = ExportLayout.clickRipple(
                    age: clickAge ?? 0,
                    canvasPixelsPerPoint: pixelsPerPoint,
                    cursorScale: treatment.scale
                )
                Circle()
                    .stroke(.white.opacity(ripple.opacity), lineWidth: 2)
                    .frame(
                        width: ripple.radius * 2 * Double(viewScale),
                        height: ripple.radius * 2 * Double(viewScale)
                    )
            }
            if treatment.halo {
                Circle()
                    .stroke(.white.opacity(0.42), lineWidth: max(1, viewScale))
                    .frame(
                        width: 34 * treatment.scale * viewPixelsPerPoint,
                        height: 34 * treatment.scale * viewPixelsPerPoint
                    )
            }
            Group {
                if let image = session.cursorImage {
                    let sprite = session.cursorSprite
                    let pixelSize = cursorPixelSize(image)
                    let placement = sprite.map {
                        CursorSpriteLayout.placement(
                            sprite: $0,
                            imagePixelSize: pixelSize,
                            cursorScale: treatment.scale,
                            pixelsPerPoint: viewPixelsPerPoint
                        )
                    }
                    let width = placement?.drawSize.width
                        ?? image.size.width * treatment.scale * viewPixelsPerPoint
                    let height = placement?.drawSize.height
                        ?? image.size.height * treatment.scale * viewPixelsPerPoint
                    let hotspot = placement?.hotspot ?? Point2D(x: 1, y: 1)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width, height: height)
                        .offset(
                            x: width / 2 - hotspot.x,
                            y: height / 2 - hotspot.y
                        )
                } else {
                    CursorPointerShape()
                        .fill(.white)
                        .overlay(CursorPointerShape().stroke(.black, lineWidth: 1))
                        .frame(width: 14 * treatment.scale, height: 20 * treatment.scale)
                        .offset(x: 7 * treatment.scale, y: 10 * treatment.scale)
                }
            }
            .blur(radius: CGFloat(motionBlur.previewRadius) * viewScale)
        }
        .position(x: point.x, y: point.y)
        .allowsHitTesting(false)
    }

    private func cursorPixelSize(_ image: NSImage) -> Size2D {
        let bitmap = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { lhs, rhs in lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh }
        return Size2D(
            width: Double(max(bitmap?.pixelsWide ?? Int(image.size.width), 1)),
            height: Double(max(bitmap?.pixelsHigh ?? Int(image.size.height), 1))
        )
    }

    @ViewBuilder
    private func canvasFill(_ background: CanvasBackground) -> some View {
        switch background {
        case .solid(let color):
            color.swiftUIColor
        case .linearGradient(let start, let end, let startPoint, let endPoint):
            LinearGradient(
                colors: [start.swiftUIColor, end.swiftUIColor],
                startPoint: UnitPoint(x: startPoint.x, y: startPoint.y),
                endPoint: UnitPoint(x: endPoint.x, y: endPoint.y)
            )
        }
    }

    private func mapRect(_ rect: CGRect, from canvas: CGSize, into outer: CGRect) -> CGRect {
        let sx = outer.width / max(canvas.width, 1)
        let sy = outer.height / max(canvas.height, 1)
        return CGRect(
            x: outer.minX + rect.origin.x * sx,
            y: outer.minY + rect.origin.y * sy,
            width: rect.width * sx,
            height: rect.height * sy
        )
    }
}

private struct ZoomAnchorDrag {
    var zoomID: UUID
    var originalAnchor: Point2D
    var cropUV: CGRect
    var videoRect: CGRect
}

private struct WebcamOverlayDrag {
    var originalSettings: WebcamOverlaySettings
}

private struct WebcamOverlayResize {
    var originalSettings: WebcamOverlaySettings
}

private struct AnnotationDrag {
    var id: UUID
    var originalPosition: Point2D
    var originalEndPosition: Point2D
    var originalRect: Rect2D
}

private struct AnnotationResize {
    var id: UUID
    var originalRect: Rect2D
}

private enum ArrowEndpoint {
    case start
    case end
}

private struct ArrowEndpointDrag {
    var id: UUID
    var endpoint: ArrowEndpoint
    var originalPosition: Point2D
    var originalEndPosition: Point2D
}

private struct RedactionDrag {
    var id: UUID
    var originalRect: Rect2D
}

private struct RedactionResize {
    var id: UUID
    var originalRect: Rect2D
}

/// A layer-backed preview of the same Core Image effects used by export. The
/// filters sample the already-composed content behind this view, so redaction
/// previews cover source video and every authored overlay beneath them.
private struct RedactionBackdropFilterView: NSViewRepresentable {
    var mode: RedactionMode
    var strength: Double
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> RedactionBackdropNSView {
        let view = RedactionBackdropNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: RedactionBackdropNSView, context: Context) {
        nsView.mode = mode
        nsView.strength = strength
        nsView.cornerRadius = cornerRadius
        nsView.updateFilter()
    }
}

private final class RedactionBackdropNSView: NSView {
    var mode: RedactionMode = .blur
    var strength: Double = 0.55
    var cornerRadius: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = true
        layer?.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateFilter()
    }

    func updateFilter() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        let value = min(max(strength, RedactionRegion.strengthRange.lowerBound), RedactionRegion.strengthRange.upperBound)
        let filter: CIFilter?
        switch mode {
        case .blur:
            filter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputRadiusKey: 3 + value * 27,
            ])
        case .pixelate:
            filter = CIFilter(name: "CIPixellate", parameters: [
                kCIInputScaleKey: 4 + value * 34,
                kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
            ])
        }
        layer.backgroundFilters = filter.map { [$0] } ?? []
    }
}

private struct WebcamPreviewShape: Shape {
    var kind: WebcamOverlayShape
    var cornerRadius: Double

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedRectangle, .squircle:
            return Path(
                roundedRect: rect,
                cornerRadius: min(CGFloat(cornerRadius), min(rect.width, rect.height) / 2)
            )
        }
    }
}

private struct CursorPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.maxY * 0.68))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.maxY * 0.62))
        path.closeSubpath()
        return path
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.player = player
        view.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.videoGravity = videoGravity
    }
}

final class PlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
