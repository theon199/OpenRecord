import AppKit
import AVFoundation
import OpenRecord
import SwiftUI

struct PreviewCanvas: View {
    @Bindable var session: EditorSession

    var body: some View {
        GeometryReader { geo in
            let crop = session.engine.crop(at: session.playhead)
            let cursor = session.engine.interpolateCursor(at: session.playhead)
            let clicking = session.engine.isClicking(at: session.playhead)
            let canvas = session.document.canvas
            let sourceWidth = session.sourceWidth
            let sourceHeight = session.sourceHeight
            let layout = ExportLayout.canvasLayout(
                canvas: canvas,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                cropUV: crop
            )
            let outer = ExportLayout.aspectFit(layout.size, in: CGRect(origin: .zero, size: geo.size))
            let viewScale = outer.width / CGFloat(max(layout.width, 1))
            let video = mapRect(layout.videoRect, from: layout.size, into: outer)
            let corner = layout.cornerRadius * Double(viewScale)
            let clickAge = clicking
                ? ExportLayout.primaryClickAge(at: session.playhead, clicks: session.engine.smoother.clicks)
                : nil

            ZStack(alignment: .topLeading) {
                canvasFill(canvas.background)
                    .frame(width: outer.width, height: outer.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .position(x: outer.midX, y: outer.midY)

                videoStack(crop: crop, inner: video, cornerRadius: corner)

                if let cursor {
                    cursorOverlay(
                        cursor: cursor,
                        clicking: clicking,
                        clickAge: clickAge,
                        crop: crop,
                        canvasVideo: layout.videoRect,
                        viewVideo: video,
                        viewScale: viewScale,
                        canvas: canvas,
                        sourceWidth: sourceWidth
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        crop: CGRect,
        canvasVideo: CGRect,
        viewVideo: CGRect,
        viewScale: CGFloat,
        canvas: CanvasSettings,
        sourceWidth: Int
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
                    cursorScale: canvas.cursorScale
                )
                Circle()
                    .stroke(.white.opacity(ripple.opacity), lineWidth: 2)
                    .frame(
                        width: ripple.radius * 2 * Double(viewScale),
                        height: ripple.radius * 2 * Double(viewScale)
                    )
            }
            if let image = session.cursorImage {
                let sprite = session.cursorSprite
                let pixelSize = cursorPixelSize(image)
                let placement = sprite.map {
                    CursorSpriteLayout.placement(
                        sprite: $0,
                        imagePixelSize: pixelSize,
                        cursorScale: canvas.cursorScale,
                        pixelsPerPoint: viewPixelsPerPoint
                    )
                }
                let width = placement?.drawSize.width
                    ?? image.size.width * canvas.cursorScale * viewPixelsPerPoint
                let height = placement?.drawSize.height
                    ?? image.size.height * canvas.cursorScale * viewPixelsPerPoint
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
                    .frame(width: 14 * canvas.cursorScale, height: 20 * canvas.cursorScale)
                    .offset(x: 7 * canvas.cursorScale, y: 10 * canvas.cursorScale)
            }
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

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

final class PlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        didSet { playerLayer.player = player }
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
