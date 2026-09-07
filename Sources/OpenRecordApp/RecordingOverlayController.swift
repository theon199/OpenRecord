import AppKit
import AVFoundation
import OpenRecord
import SwiftUI

@MainActor
@Observable
final class RecordingHUDSnapshot {
    var previewSession: AVCaptureSession?
    var mirrored = true
    var showsCamera = false
    var collapsed = false
    var countdownRemaining: Int?
    var elapsed: TimeInterval = 0
    var isRecording = false
    var isMuted = false
    var cameraDiameter: CGFloat = 180
}

@MainActor
final class RecordingOverlayController {
    let snapshot = RecordingHUDSnapshot()

    private var panel: NSPanel?
    private var hosting: NSHostingController<RecordingHUDView>?
    private var cameraCenter = CGPoint(x: 240, y: 180)
    private var cameraDiameter: CGFloat = 180
    private var dragStartCenter: CGPoint?
    private var resizeStartDiameter: CGFloat?
    private var clampBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onToggleCollapsed: (() -> Void)?
    var onLayoutCommitted: (() -> Void)?

    var currentCameraFrame: CGRect {
        RecordingHUDLayout.cameraFrame(center: cameraCenter, diameter: cameraDiameter)
    }

    var isVisible: Bool { panel != nil }

    func present(clampBounds: CGRect, showsCamera: Bool) {
        self.clampBounds = clampBounds
        snapshot.showsCamera = showsCamera
        if panel == nil {
            restorePlacement(in: clampBounds)
            buildPanel()
        }
        applyCameraFrame(currentCameraFrame, commit: false)
        orderFront()
    }

    func dismiss() {
        persistPlacement()
        snapshot.previewSession = nil
        if let hosting {
            hosting.view.removeFromSuperview()
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hosting = nil
        dragStartCenter = nil
        resizeStartDiameter = nil
    }

    func setPreviewSession(_ session: AVCaptureSession?) {
        snapshot.previewSession = session
    }

    func update(
        countdownRemaining: Int?,
        elapsed: TimeInterval,
        isRecording: Bool,
        isMuted: Bool,
        collapsed: Bool,
        showsCamera: Bool,
        clampBounds: CGRect
    ) {
        self.clampBounds = clampBounds
        snapshot.countdownRemaining = countdownRemaining
        snapshot.elapsed = elapsed
        snapshot.isRecording = isRecording
        snapshot.isMuted = isMuted
        snapshot.collapsed = collapsed
        snapshot.showsCamera = showsCamera
        applyCameraFrame(currentCameraFrame, commit: false)
    }

    func relayout() {
        applyCameraFrame(currentCameraFrame, commit: false)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: RecordingHUDLayout.windowFrame(
                cameraFrame: currentCameraFrame,
                showsCamera: snapshot.showsCamera,
                collapsed: snapshot.collapsed
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .utilityWindow

        let view = RecordingHUDView(
            snapshot: snapshot,
            onStop: { [weak self] in self?.onStop?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onToggleMute: { [weak self] in self?.onToggleMute?() },
            onToggleCollapsed: { [weak self] in self?.onToggleCollapsed?() },
            onDragChanged: { [weak self] translation in self?.handleDrag(translation) },
            onDragEnded: { [weak self] in self?.endDrag() },
            onResizeChanged: { [weak self] translation in self?.handleResize(translation) },
            onResizeEnded: { [weak self] in self?.endResize() },
            onScrollResize: { [weak self] delta in self?.handleScrollResize(delta) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.safeAreaRegions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.appearance = NSAppearance(named: .vibrantDark)
        hosting.view.autoresizingMask = [.width, .height]
        panel.contentView = hosting.view
        self.panel = panel
        self.hosting = hosting
    }

    private func orderFront() {
        panel?.orderFrontRegardless()
    }

    private func handleDrag(_ translation: CGSize) {
        if dragStartCenter == nil {
            dragStartCenter = cameraCenter
        }
        guard let start = dragStartCenter else { return }
        let proposed = CGPoint(
            x: start.x + translation.width,
            y: start.y - translation.height
        )
        applyCameraFrame(
            RecordingHUDLayout.cameraFrame(center: proposed, diameter: cameraDiameter),
            commit: false
        )
    }

    private func endDrag() {
        dragStartCenter = nil
        applyCameraFrame(currentCameraFrame, commit: true)
    }

    private func handleResize(_ translation: CGSize) {
        if resizeStartDiameter == nil {
            resizeStartDiameter = cameraDiameter
        }
        guard let start = resizeStartDiameter else { return }
        let delta = translation.width + translation.height
        applyCameraFrame(
            RecordingHUDLayout.cameraFrame(center: cameraCenter, diameter: start + delta),
            commit: false
        )
    }

    private func endResize() {
        resizeStartDiameter = nil
        applyCameraFrame(currentCameraFrame, commit: true)
    }

    private func handleScrollResize(_ delta: CGFloat) {
        applyCameraFrame(
            RecordingHUDLayout.cameraFrame(
                center: cameraCenter,
                diameter: cameraDiameter + delta
            ),
            commit: true
        )
    }

    private func applyCameraFrame(_ frame: CGRect, commit: Bool) {
        let clamped = RecordingHUDLayout.clampCameraFrame(frame, to: clampBounds)
        cameraCenter = CGPoint(x: clamped.midX, y: clamped.midY)
        cameraDiameter = clamped.width
        snapshot.cameraDiameter = cameraDiameter
        let windowFrame = RecordingHUDLayout.windowFrame(
            cameraFrame: clamped,
            showsCamera: snapshot.showsCamera,
            collapsed: snapshot.collapsed
        )
        panel?.setFrame(windowFrame, display: true)
        if commit {
            persistPlacement()
            onLayoutCommitted?()
        }
    }

    private func restorePlacement(in bounds: CGRect) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.diameterDefaultsKey) != nil,
           defaults.object(forKey: Self.centerXDefaultsKey) != nil,
           defaults.object(forKey: Self.centerYDefaultsKey) != nil
        {
            let diameter = CGFloat(defaults.double(forKey: Self.diameterDefaultsKey))
            let center = CGPoint(
                x: defaults.double(forKey: Self.centerXDefaultsKey),
                y: defaults.double(forKey: Self.centerYDefaultsKey)
            )
            let restored = RecordingHUDLayout.clampCameraFrame(
                RecordingHUDLayout.cameraFrame(center: center, diameter: diameter),
                to: bounds
            )
            if bounds.insetBy(dx: 24, dy: 24).intersects(restored) {
                cameraCenter = CGPoint(x: restored.midX, y: restored.midY)
                cameraDiameter = restored.width
                snapshot.cameraDiameter = cameraDiameter
                return
            }
        }
        let fallback = RecordingHUDLayout.clampCameraFrame(
            RecordingHUDLayout.defaultCameraFrame(displayBounds: bounds),
            to: bounds
        )
        cameraCenter = CGPoint(x: fallback.midX, y: fallback.midY)
        cameraDiameter = fallback.width
        snapshot.cameraDiameter = cameraDiameter
    }

    private func persistPlacement() {
        let defaults = UserDefaults.standard
        defaults.set(Double(cameraDiameter), forKey: Self.diameterDefaultsKey)
        defaults.set(Double(cameraCenter.x), forKey: Self.centerXDefaultsKey)
        defaults.set(Double(cameraCenter.y), forKey: Self.centerYDefaultsKey)
    }

    private static let diameterDefaultsKey = "OpenRecord.recordingHUD.diameter"
    private static let centerXDefaultsKey = "OpenRecord.recordingHUD.centerX"
    private static let centerYDefaultsKey = "OpenRecord.recordingHUD.centerY"
}
