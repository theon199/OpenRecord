import AppKit
import AVFoundation
import OpenRecord
import SwiftUI

struct RecordingHUDView: View {
    @Bindable var snapshot: RecordingHUDSnapshot
    var onStop: () -> Void
    var onCancel: () -> Void
    var onToggleMute: () -> Void
    var onToggleCollapsed: () -> Void
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: () -> Void
    var onResizeChanged: (CGSize) -> Void
    var onResizeEnded: () -> Void
    var onScrollResize: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: RecordingHUDLayout.controlSpacing) {
            if snapshot.showsCamera && !snapshot.collapsed {
                cameraBubble
            }
            controlPill
        }
        .padding(RecordingHUDLayout.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cameraBubble: some View {
        let diameter = snapshot.cameraDiameter
        return ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                WebcamPreviewLayerView(
                    session: snapshot.previewSession,
                    mirrored: snapshot.mirrored,
                    onScrollResize: onScrollResize
                )
                if snapshot.previewSession == nil {
                    Image(systemName: "video.fill")
                        .font(.system(size: max(18, diameter * 0.18), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay {
                Circle().stroke(.white, lineWidth: 3)
            }
            .shadow(color: .black.opacity(0.42), radius: 12, y: 4)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { onDragChanged($0.translation) }
                    .onEnded { _ in onDragEnded() }
            )

            Circle()
                .fill(.white)
                .frame(
                    width: RecordingHUDLayout.resizeHandleSize,
                    height: RecordingHUDLayout.resizeHandleSize
                )
                .overlay {
                    Circle().stroke(.black.opacity(0.25), lineWidth: 1)
                }
                .offset(x: 2, y: 2)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { onResizeChanged($0.translation) }
                        .onEnded { _ in onResizeEnded() }
                )
                .help("Drag to resize the camera")
        }
        .frame(width: diameter, height: diameter)
    }

    private var controlPill: some View {
        HStack(spacing: 8) {
            statusLabel
            Spacer(minLength: 4)
            pillButton(
                systemName: snapshot.isMuted ? "mic.slash.fill" : "mic.fill",
                help: snapshot.isMuted ? "Unmute microphone" : "Mute microphone",
                role: snapshot.isMuted ? .destructive : nil,
                action: onToggleMute
            )
            if snapshot.showsCamera {
                pillButton(
                    systemName: snapshot.collapsed ? "video.fill" : "video.slash.fill",
                    help: snapshot.collapsed ? "Show camera preview" : "Hide camera preview",
                    action: onToggleCollapsed
                )
            }
            if snapshot.countdownRemaining != nil {
                pillButton(
                    systemName: "xmark",
                    help: "Cancel countdown",
                    action: onCancel
                )
            } else {
                pillButton(
                    systemName: "stop.fill",
                    help: "Stop recording",
                    role: .destructive,
                    action: onStop
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(width: RecordingHUDLayout.pillWidth, height: RecordingHUDLayout.pillHeight)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let remaining = snapshot.countdownRemaining {
            Text("\(remaining)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 28)
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(snapshot.isRecording ? .red : .secondary)
                    .frame(width: 7, height: 7)
                Text(Timecode.compact(snapshot.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }

    private func pillButton(
        systemName: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

final class WebcamPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var mirrored = true
    var onScrollResize: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        applyMirroring()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
        onScrollResize?(delta)
    }

    func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else {
            return
        }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

struct WebcamPreviewLayerView: NSViewRepresentable {
    var session: AVCaptureSession?
    var mirrored: Bool
    var onScrollResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> WebcamPreviewNSView {
        let view = WebcamPreviewNSView()
        view.mirrored = mirrored
        view.previewLayer.session = session
        view.onScrollResize = onScrollResize
        view.applyMirroring()
        return view
    }

    func updateNSView(_ view: WebcamPreviewNSView, context: Context) {
        view.mirrored = mirrored
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.onScrollResize = onScrollResize
        view.applyMirroring()
    }
}
