import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import QuartzCore

/// Listen-only HID tap which filters cursor activity to the selected target.
final class CursorMonitor: @unchecked Sendable {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var geometryTimer: DispatchSourceTimer?
    private let geometryQueue = DispatchQueue(label: "app.openrecord.desktop.capture.target", qos: .utility)
    private var mouseWriter: JSONLWriter<CursorSample>?
    private var clickWriter: JSONLWriter<ClickSample>?
    private var keyWriter: JSONLWriter<KeySample>?
    private var targetWriter: JSONLWriter<TargetGeometrySample>?
    private let stateLock = NSLock()
    private var recordingStart: CFTimeInterval?
    private var lastMoveTime: TimeInterval = -1
    private var lastLocation: CGPoint?
    private var targetBounds: CGRect?
    private var targetAvailable = true
    private var targetKind: CaptureTarget?
    private var targetVisible = false
    private var pendingGeometry: TargetGeometrySample?
    private var pressedKeys: [UInt16: PressedKey] = [:]
    private(set) var closeWarnings = Set<CaptureWarningCode>()
    var onTargetUnavailable: (@Sendable () -> Void)?

    func start(mouseURL: URL, clicksURL: URL) throws {
        try start(mouseURL: mouseURL, clicksURL: clicksURL, target: nil, initialBounds: nil, targetURL: nil)
    }

    func start(mouseURL: URL, clicksURL: URL, target: CaptureTarget?, initialBounds: Rect2D?, targetURL: URL?, keysURL: URL? = nil) throws {
        mouseWriter = try JSONLWriter(url: mouseURL)
        clickWriter = try JSONLWriter(url: clicksURL)
        if let keysURL { keyWriter = try JSONLWriter(url: keysURL) }
        if let targetURL { targetWriter = try JSONLWriter(url: targetURL) }
        pressedKeys.removeAll()
        closeWarnings.removeAll()
        stateLock.lock()
        targetKind = target
        targetBounds = initialBounds?.cgRect
        targetAvailable = initialBounds != nil || target == nil
        targetVisible = false
        pendingGeometry = initialBounds.map { TargetGeometrySample(t: 0, bounds: $0, available: true) }
        stateLock.unlock()

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: Self.eventMask, callback: openRecordCursorEventTap, userInfo: refcon) else {
            throw CapturePermissionError(kind: .accessibility, message: CapturePermissions.denialMessage(for: .accessibility))
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw OpenRecordError.io("Could not attach the cursor event tap to the run loop.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
        if case .window = target {
            let timer = DispatchSource.makeTimerSource(queue: geometryQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.pollWindowGeometry() }
            geometryTimer = timer
            timer.resume()
        }
    }

    func setRecordingStart(_ time: CFTimeInterval) {
        stateLock.lock()
        recordingStart = time
        lastMoveTime = -1
        pressedKeys.removeAll()
        let geometry = pendingGeometry
        pendingGeometry = nil
        stateLock.unlock()
        if let geometry { targetWriter?.write(TargetGeometrySample(t: 0, bounds: geometry.bounds, available: geometry.available)) }
    }

    func stop() {
        geometryTimer?.setEventHandler {}
        geometryTimer?.cancel()
        geometryTimer = nil
        // Dispatch source cancellation is asynchronous. Drain a geometry poll
        // that may already be running before the JSONL handles are finalized.
        geometryQueue.sync {}
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        runLoopSource = nil
        stateLock.lock()
        pressedKeys.removeAll()
        recordingStart = nil
        stateLock.unlock()
    }

    func closeFiles() throws {
        mouseWriter?.close(); clickWriter?.close(); keyWriter?.close(); targetWriter?.close()
        let mouseError = mouseWriter?.writeError
        let clickError = clickWriter?.writeError
        let keyError = keyWriter?.writeError
        let targetError = targetWriter?.writeError
        mouseWriter = nil; clickWriter = nil; keyWriter = nil; targetWriter = nil
        if mouseError != nil { closeWarnings.insert(.truncatedMouseTelemetry) }
        if clickError != nil { closeWarnings.insert(.truncatedClickTelemetry) }
        if keyError != nil { closeWarnings.insert(.truncatedKeyboardTelemetry) }
        if targetError != nil { closeWarnings.insert(.truncatedTargetGeometry) }
        if let mouseError { throw mouseError }
        if let clickError { throw clickError }
        if let keyError { throw keyError }
        if let targetError { throw targetError }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        if type == .keyDown || type == .keyUp {
            handleKeyboard(type: type, event: event)
            return
        }
        stateLock.lock(); let start = recordingStart; stateLock.unlock()
        guard let start else { return }
        let t = CACurrentMediaTime() - start
        guard t >= 0 else { return }
        let location = event.location
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            guard updateVisibility(t: t, location: location) else { return }
            clickWriter?.write(ClickSample(t: t, button: Self.button(type: type, event: event), down: down))
            writeMove(t: t, location: location, force: true)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard updateVisibility(t: t, location: location) else { return }
            writeMove(t: t, location: location, force: false)
        default: break
        }
    }

    private func handleKeyboard(type: CGEventType, event: CGEvent) {
        guard keyWriter != nil else { return }
        if IsSecureEventInputEnabled() {
            stateLock.lock()
            pressedKeys.removeAll()
            let start = recordingStart
            stateLock.unlock()
            if start != nil, keyWriter != nil { closeWarnings.insert(.keyboardSecureInputGap) }
            return
        }
        stateLock.lock(); let start = recordingStart; stateLock.unlock()
        guard let start else { return }
        let t = CACurrentMediaTime() - start
        guard t >= 0 else { return }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(from: event.flags)
        let isDown = type == .keyDown
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let rawLabel = KeyboardCapturePolicy.specialKeyLabel(keyCode: keyCode)
            ?? NSEvent(cgEvent: event)?.charactersIgnoringModifiers
            ?? ""
        let label = rawLabel.count == 1 ? rawLabel.uppercased() : rawLabel

        if isDown {
            guard !isAutorepeat,
                  KeyboardCapturePolicy.shouldCapture(keyCode: keyCode, modifiers: modifiers, label: label)
            else { return }
            stateLock.lock()
            guard pressedKeys[keyCode] == nil else { stateLock.unlock(); return }
            pressedKeys[keyCode] = PressedKey(label: label, modifiers: modifiers)
            stateLock.unlock()
            keyWriter?.write(KeySample(t: t, key: label, modifiers: modifiers, down: true))
        } else {
            stateLock.lock()
            let pressed = pressedKeys.removeValue(forKey: keyCode)
            stateLock.unlock()
            guard let pressed else { return }
            keyWriter?.write(KeySample(t: t, key: pressed.label, modifiers: pressed.modifiers, down: false))
        }
    }

    private func writeMove(t: TimeInterval, location: CGPoint, force: Bool) {
        stateLock.lock()
        let last = lastMoveTime
        let visible = targetVisible
        lastLocation = location
        if !force, last >= 0, (t - last) < (1.0 / CaptureMediaFormat.mouseSamplesPerSecondCap) { stateLock.unlock(); return }
        lastMoveTime = t
        stateLock.unlock()
        guard visible else { return }
        mouseWriter?.write(CursorSample(t: t, x: Double(location.x), y: Double(location.y), cursorId: CaptureMediaFormat.defaultCursorSpriteID, visible: true))
    }

    @discardableResult
    private func updateVisibility(t: TimeInterval, location: CGPoint) -> Bool {
        stateLock.lock()
        let visible = isInsideTargetLocked(location)
        let changed = visible != targetVisible
        targetVisible = visible; lastLocation = location
        stateLock.unlock()
        if changed { mouseWriter?.write(CursorSample(t: t, x: Double(location.x), y: Double(location.y), cursorId: CaptureMediaFormat.defaultCursorSpriteID, visible: visible)) }
        return visible
    }

    private func isInsideTargetLocked(_ location: CGPoint) -> Bool {
        guard targetKind != nil else { return true }
        return targetAvailable && (targetBounds?.contains(location) ?? false)
    }

    private func pollWindowGeometry() {
        guard case .window(let windowID) = targetKind else { return }
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, CGWindowID(windowID)) as? [[CFString: Any]]
        var bounds: CGRect?
        if let entry = info?.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowID }),
           (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true,
           let rawBounds = entry[kCGWindowBounds]
        {
            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(rawBounds as! CFDictionary, &rect), rect.width > 1, rect.height > 1 { bounds = rect }
        }
        stateLock.lock()
        let changed = bounds != targetBounds || (bounds != nil) != targetAvailable
        targetBounds = bounds; targetAvailable = bounds != nil
        let start = recordingStart
        let t = max(0, start.map { CACurrentMediaTime() - $0 } ?? 0)
        let location = lastLocation
        let oldVisible = targetVisible
        let newVisible = location.map { isInsideTargetLocked($0) } ?? false
        targetVisible = newVisible
        stateLock.unlock()
        guard changed else {
            if oldVisible != newVisible, let location, start != nil { mouseWriter?.write(CursorSample(t: t, x: Double(location.x), y: Double(location.y), cursorId: CaptureMediaFormat.defaultCursorSpriteID, visible: newVisible)) }
            return
        }
        let sample = TargetGeometrySample(t: t, bounds: Rect2D(bounds ?? .zero), available: bounds != nil)
        if start == nil {
            stateLock.lock(); pendingGeometry = sample; stateLock.unlock()
        } else { targetWriter?.write(sample) }
        if bounds == nil { onTargetUnavailable?() }
        if oldVisible != newVisible, let location, start != nil { mouseWriter?.write(CursorSample(t: t, x: Double(location.x), y: Double(location.y), cursorId: CaptureMediaFormat.defaultCursorSpriteID, visible: newVisible)) }
    }

    private static func button(type: CGEventType, event: CGEvent) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp: return event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? .middle : .other
        default: return .other
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> [KeyModifier] {
        var modifiers: [KeyModifier] = []
        if flags.contains(.maskControl) { modifiers.append(.control) }
        if flags.contains(.maskAlternate) { modifiers.append(.option) }
        if flags.contains(.maskShift) { modifiers.append(.shift) }
        if flags.contains(.maskCommand) { modifiers.append(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.append(.function) }
        return modifiers
    }

    private static let eventMask: CGEventMask = {
        [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    private struct PressedKey: Sendable {
        var label: String
        var modifiers: [KeyModifier]
    }
}

private func openRecordCursorEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    _ = proxy
    if let refcon { Unmanaged<CursorMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
