import AppKit
import ApplicationServices
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
    private var typingWriter: JSONLWriter<TypingSample>?
    private var targetWriter: JSONLWriter<TargetGeometrySample>?
    private var semanticWriter: JSONLWriter<SemanticEventSample>?
    private let stateLock = NSLock()
    private var cachedTextBoxTime: TimeInterval = -1
    private var cachedTextBox: (point: CGPoint, size: CGSize)?
    private var recordingStart: CFTimeInterval?
    private var lastMoveTime: TimeInterval = -1
    private var lastLocation: CGPoint?
    private var targetBounds: CGRect?
    private var targetAvailable = true
    private var targetKind: CaptureTarget?
    private var targetVisible = false
    private var occlusionWindows: [CaptureWindowSnapshot] = []
    private var pendingGeometry: TargetGeometrySample?
    private var pressedKeys: [UInt16: PressedKey] = [:]
    private(set) var closeWarnings = Set<CaptureWarningCode>()
    var onTargetUnavailable: (@Sendable () -> Void)?

    func start(mouseURL: URL, clicksURL: URL) throws {
        try start(mouseURL: mouseURL, clicksURL: clicksURL, target: nil, initialBounds: nil, targetURL: nil)
    }

    func start(
        mouseURL: URL,
        clicksURL: URL,
        target: CaptureTarget?,
        initialBounds: Rect2D?,
        targetURL: URL?,
        keysURL: URL? = nil,
        typingURL: URL? = nil,
        semanticURL: URL? = nil
    ) throws {
        mouseWriter = try JSONLWriter(url: mouseURL)
        clickWriter = try JSONLWriter(url: clicksURL)
        if let keysURL { keyWriter = try JSONLWriter(url: keysURL) }
        if let typingURL { typingWriter = try JSONLWriter(url: typingURL) }
        if let targetURL { targetWriter = try JSONLWriter(url: targetURL) }
        // Semantic evidence is advisory. A failure to create this optional
        // stream must not prevent the display, cursor, or keyboard streams
        // from continuing to capture.
        if let semanticURL {
            semanticWriter = try? JSONLWriter(url: semanticURL)
        }
        pressedKeys.removeAll()
        closeWarnings.removeAll()
        stateLock.lock()
        targetKind = target
        targetBounds = initialBounds?.cgRect
        targetAvailable = initialBounds != nil || target == nil
        targetVisible = false
        occlusionWindows = []
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
            pollWindowGeometry()
            let timer = DispatchSource.makeTimerSource(queue: geometryQueue)
            timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.pollWindowGeometry() }
            geometryTimer = timer
            timer.resume()
        }
    }

    func setRecordingStart(_ time: CFTimeInterval) {
        stateLock.lock()
        recordingStart = time
        lastMoveTime = -1
        cachedTextBoxTime = -1
        cachedTextBox = nil
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
        cachedTextBoxTime = -1
        cachedTextBox = nil
        stateLock.unlock()
    }

    func closeFiles() throws {
        mouseWriter?.close(); clickWriter?.close(); keyWriter?.close(); typingWriter?.close(); targetWriter?.close(); semanticWriter?.close()
        let mouseError = mouseWriter?.writeError
        let clickError = clickWriter?.writeError
        let keyError = keyWriter?.writeError
        let typingError = typingWriter?.writeError
        let targetError = targetWriter?.writeError
        // Semantic write errors intentionally remain advisory and are not
        // returned from this method. Display finalization must not be coupled
        // to a best-effort analysis stream.
        mouseWriter = nil; clickWriter = nil; keyWriter = nil; typingWriter = nil; targetWriter = nil; semanticWriter = nil
        if mouseError != nil { closeWarnings.insert(.truncatedMouseTelemetry) }
        if clickError != nil { closeWarnings.insert(.truncatedClickTelemetry) }
        if keyError != nil { closeWarnings.insert(.truncatedKeyboardTelemetry) }
        if typingError != nil { closeWarnings.insert(.truncatedTypingTelemetry) }
        if targetError != nil { closeWarnings.insert(.truncatedTargetGeometry) }
        if let mouseError { throw mouseError }
        if let clickError { throw clickError }
        if let keyError { throw keyError }
        if let typingError { throw typingError }
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
            clickWriter?.write(ClickSample(
                t: t,
                button: Self.button(type: type, event: event),
                down: down,
                x: Double(location.x),
                y: Double(location.y)
            ))
            if down { writeSemanticActivation(t: t, location: location) }
            writeMove(t: t, location: location, force: true)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard updateVisibility(t: t, location: location) else { return }
            writeMove(t: t, location: location, force: false)
        default: break
        }
    }

    private func handleKeyboard(type: CGEventType, event: CGEvent) {
        guard keyWriter != nil || typingWriter != nil || semanticWriter != nil else { return }
        stateLock.lock(); let start = recordingStart; stateLock.unlock()
        guard let start else { return }
        let t = CACurrentMediaTime() - start
        guard t >= 0 else { return }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(from: event.flags)
        let isDown = type == .keyDown
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // This marker is intentionally handled before secure-input handling:
        // it contains no text or application metadata and remains available
        // as a user-authored story beat even while another app owns the secure
        // input session.
        let isMarker = isDown && !isAutorepeat && Self.isStoryBeatMarker(
            keyCode: keyCode,
            modifiers: modifiers
        )
        if isMarker {
            semanticWriter?.write(SemanticEventSample(
                t: t,
                kind: .storyBeat,
                confidence: 1,
                source: .userMarker
            ))
        }

        if IsSecureEventInputEnabled() {
            stateLock.lock()
            pressedKeys.removeAll()
            stateLock.unlock()
            if keyWriter != nil { closeWarnings.insert(.keyboardSecureInputGap) }
            return
        }

        if isDown, !isAutorepeat, semanticWriter != nil, !isMarker,
           Self.isSafeShortcut(keyCode: keyCode, modifiers: modifiers) {
            // Only fixed, known action names are persisted. Unknown shortcut
            // keys still produce a useful kind/source event without copying a
            // layout-dependent or user-authored character into the semantic
            // stream.
            semanticWriter?.write(SemanticEventSample(
                t: t,
                kind: .shortcut,
                label: Self.semanticShortcutLabel(keyCode: keyCode, modifiers: modifiers),
                confidence: 0.8,
                source: .telemetry
            ))
        }

        if isDown, let typingWriter {
            recordTypingIfApplicable(t: t, keyCode: keyCode, modifiers: modifiers, writer: typingWriter)
        }

        guard keyWriter != nil else { return }
        let rawLabel: String
        if let special = KeyboardCapturePolicy.specialKeyLabel(keyCode: keyCode) {
            rawLabel = special
        } else if keyWriter != nil {
            // The ordinary character representation is needed only for the
            // existing keyboard stream's allowlist. Semantic-only capture
            // never asks AppKit for typed characters.
            rawLabel = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        } else {
            rawLabel = ""
        }
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

    private func writeSemanticActivation(t: TimeInterval, location: CGPoint) {
        guard semanticWriter != nil else { return }
        stateLock.lock()
        let bounds = targetBounds
        stateLock.unlock()
        semanticWriter?.write(Self.semanticActivationSample(
            t: t,
            location: location,
            targetBounds: bounds.map { Rect2D($0) }
        ))
    }

    /// Resolve only the small, allowlisted static-control surface. This
    /// function deliberately never reads a control's value, selected text, or
    /// document content. Position and size are geometry, not UI values.
    private static func semanticActivationSample(
        t: TimeInterval,
        location: CGPoint,
        targetBounds: Rect2D?
    ) -> SemanticEventSample {
        let fallback = { (reason: SemanticDegradationReason) in
            Self.genericSemanticClickSample(
                t: t,
                location: location,
                targetBounds: targetBounds,
                reason: reason
            )
        }

        guard AXIsProcessTrusted() else { return fallback(.accessibilityUnavailable) }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        ) == .success,
        let element
        else { return fallback(.elementUnavailable) }

        let role = stringAttribute(kAXRoleAttribute, from: element).flatMap(SemanticPrivacyFilter.sanitizeRole)
        guard let role else { return fallback(.elementUnavailable) }
        let bundleID = bundleIdentifier(for: element)
        let bounds = elementBounds(for: element, targetBounds: targetBounds)

        // Secure controls receive no title or description query at all. That
        // makes the no-private-content guarantee hold even if an accessibility
        // provider exposes a surprising label on a password control.
        if SemanticPrivacyFilter.isSecureRole(role) {
            return SemanticEventSample(
                t: t,
                kind: .genericClick,
                applicationBundleID: bundleID,
                role: role,
                bounds: bounds,
                confidence: 0,
                source: .accessibility,
                degradationReason: .secureField
            ).normalized
        }

        // The policy permits labels only for static controls. Do not even ask
        // AX for title/description on text fields or unknown roles.
        guard staticControlRoles.contains(role) else {
            return SemanticEventSample(
                t: t,
                kind: .genericClick,
                applicationBundleID: bundleID,
                role: role,
                bounds: bounds,
                confidence: 0,
                source: .accessibility,
                degradationReason: .elementUnavailable
            ).normalized
        }

        let title = stringAttribute(kAXTitleAttribute, from: element)
        let description = stringAttribute(kAXDescriptionAttribute, from: element)
        let label = SemanticPrivacyFilter.sanitizeCapturedLabel(title, role: role)
            ?? SemanticPrivacyFilter.sanitizeCapturedLabel(description, role: role)
        guard label != nil else {
            return SemanticEventSample(
                t: t,
                kind: .genericClick,
                applicationBundleID: bundleID,
                role: role,
                bounds: bounds,
                confidence: 0,
                source: .accessibility,
                degradationReason: .labelFiltered
            ).normalized
        }
        return SemanticEventSample(
            t: t,
            kind: .activate,
            applicationBundleID: bundleID,
            role: role,
            label: label,
            bounds: bounds,
            confidence: 0.94,
            source: .accessibility
        ).normalized
    }

    /// Pure fallback construction is kept separate from AX so it can be
    /// exercised without TCC. A click coordinate is not repeated as semantic
    /// bounds: unavailable controls must not imply a guessed target rectangle.
    static func genericSemanticClickSample(
        t: TimeInterval,
        location: CGPoint,
        targetBounds: Rect2D?,
        reason: SemanticDegradationReason
    ) -> SemanticEventSample {
        _ = location
        _ = targetBounds
        return SemanticEventSample(
            t: t,
            kind: .genericClick,
            bounds: nil,
            confidence: 0,
            source: .telemetry,
            degradationReason: reason
        ).normalized
    }

    /// Convert an accessibility element's global Quartz frame into target
    /// relative top-left coordinates, clamping to the documented 0...1 range.
    static func normalizedTargetRelativeBounds(
        elementFrame: CGRect,
        targetBounds: Rect2D
    ) -> Rect2D? {
        let target = targetBounds.cgRect
        guard target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0,
              elementFrame.minX.isFinite, elementFrame.minY.isFinite,
              elementFrame.width.isFinite, elementFrame.height.isFinite,
              elementFrame.width >= 0, elementFrame.height >= 0
        else { return nil }
        return SemanticPrivacyFilter.normalizedBounds(Rect2D(
            x: (elementFrame.minX - target.minX) / target.width,
            y: (elementFrame.minY - target.minY) / target.height,
            width: elementFrame.width / target.width,
            height: elementFrame.height / target.height
        ))
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bundleIdentifier(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return SemanticPrivacyFilter.sanitizeBundleID(
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        )
    }

    private static func elementBounds(for element: AXUIElement, targetBounds: Rect2D?) -> Rect2D? {
        guard let targetBounds else { return nil }
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position,
              let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }

        // AXPosition/AXSize are documented AXValue geometry attributes. They
        // are intentionally separate from the control's content value.
        let positionAX = position as! AXValue
        let sizeAX = size as! AXValue

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &point),
              AXValueGetValue(sizeAX, .cgSize, &dimensions)
        else { return nil }
        return normalizedTargetRelativeBounds(
            elementFrame: CGRect(origin: point, size: dimensions),
            targetBounds: targetBounds
        )
    }

    private static let staticControlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXDisclosureTriangle", "AXLink", "AXMenuItem",
        "AXPopUpButton", "AXRadioButton", "AXSegmentedControl", "AXTabGroup",
        "AXToolbar", "button", "checkbox", "link", "menu-item", "radio-button",
        "tab", "toolbar-item",
    ]

    private static func isSafeShortcut(keyCode: UInt16, modifiers: [KeyModifier]) -> Bool {
        guard !KeyboardCapturePolicy.isModifierKey(keyCode: keyCode) else { return false }
        return KeyboardCapturePolicy.isSafeSpecialKey(keyCode: keyCode)
            || modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
    }

    static func isStoryBeatMarker(keyCode: UInt16, modifiers: [KeyModifier]) -> Bool {
        keyCode == UInt16(kVK_ANSI_M)
            && modifiers.contains(.control)
            && modifiers.contains(.option)
            && modifiers.contains(.command)
            && !modifiers.contains(.shift)
    }

    /// These labels are fixed product vocabulary, never derived from the
    /// keyboard layout or the user's typed character stream.
    static func semanticShortcutLabel(keyCode: UInt16, modifiers: [KeyModifier]) -> String? {
        switch keyCode {
        case UInt16(kVK_ANSI_A): return "Select All"
        case UInt16(kVK_ANSI_S): return "Save"
        case UInt16(kVK_ANSI_Z): return modifiers.contains(.shift) ? "Redo" : "Undo"
        case UInt16(kVK_ANSI_X): return "Cut"
        case UInt16(kVK_ANSI_C): return "Copy"
        case UInt16(kVK_ANSI_V): return "Paste"
        case UInt16(kVK_ANSI_P): return "Print"
        case UInt16(kVK_ANSI_Q): return "Quit"
        case UInt16(kVK_ANSI_W): return "Close Window"
        default: return nil
        }
    }

    private func recordTypingIfApplicable(
        t: TimeInterval,
        keyCode: UInt16,
        modifiers: [KeyModifier],
        writer: JSONLWriter<TypingSample>
    ) {
        // Skip pure modifier keys (Shift, Ctrl, Opt, Cmd, Fn, CapsLock)
        guard !KeyboardCapturePolicy.isModifierKey(keyCode: keyCode) else { return }

        // Skip non-editing app navigation shortcuts (e.g. Cmd+Q, Cmd+W, Cmd+Tab)
        if modifiers.contains(.command) {
            // Carbon keycodes for common text editing shortcuts: A=0, Z=6, X=7, C=8, V=9
            let isEditShortcut = [0, 6, 7, 8, 9].contains(Int(keyCode))
            guard isEditShortcut else { return }
        }

        let box = resolveFocusedTextBox(at: t)
        stateLock.lock()
        let fallback = lastLocation
        stateLock.unlock()

        if let box {
            writer.write(TypingSample(
                t: t,
                x: Double(box.point.x),
                y: Double(box.point.y),
                width: Double(box.size.width),
                height: Double(box.size.height)
            ))
        } else if let fallback {
            writer.write(TypingSample(
                t: t,
                x: Double(fallback.x),
                y: Double(fallback.y)
            ))
        }
    }

    private func resolveFocusedTextBox(at t: TimeInterval) -> (point: CGPoint, size: CGSize)? {
        stateLock.lock()
        if cachedTextBoxTime >= 0, t - cachedTextBoxTime < 0.35, let cached = cachedTextBox {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let fresh = queryFocusedTextBox()
        stateLock.lock()
        cachedTextBoxTime = t
        cachedTextBox = fresh
        stateLock.unlock()
        return fresh
    }

    private func queryFocusedTextBox() -> (point: CGPoint, size: CGSize)? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppVal: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppVal) == .success,
              let focusedApp = focusedAppVal else { return nil }
        var focusedUIVal: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedUIVal) == .success,
              let element = focusedUIVal else { return nil }

        var posVal: AnyObject?
        var sizeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let posAX = posVal, let sizeAX = sizeVal else { return nil }

        var pt = CGPoint.zero
        var sz = CGSize.zero
        if AXValueGetValue(posAX as! AXValue, .cgPoint, &pt),
           AXValueGetValue(sizeAX as! AXValue, .cgSize, &sz),
           sz.width > 0, sz.height > 0 {
            return (pt, sz)
        }
        return nil
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
        CapturePointerPolicy.isVisible(
            location: location,
            target: targetKind,
            bounds: targetBounds,
            available: targetAvailable,
            windowsFrontToBack: occlusionWindows
        )
    }

    private func pollWindowGeometry() {
        guard case .window(let windowID) = targetKind else { return }
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]]
        let snapshots = CaptureWindowList.snapshots(from: info)
        var bounds = snapshots.first { $0.id == windowID && $0.onScreen }.flatMap { snapshot -> CGRect? in
            guard snapshot.bounds.width > 1, snapshot.bounds.height > 1 else { return nil }
            return snapshot.bounds.cgRect
        }
        if bounds == nil {
            bounds = Self.windowBounds(for: windowID)
        }
        stateLock.lock()
        let changed = bounds != targetBounds || (bounds != nil) != targetAvailable
        targetBounds = bounds
        targetAvailable = bounds != nil
        occlusionWindows = snapshots
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

    private static func windowBounds(for windowID: UInt32) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, CGWindowID(windowID)) as? [[CFString: Any]]
        guard let entry = info?.first(where: { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value == windowID }),
              (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true,
              let rawBounds = entry[kCGWindowBounds]
        else { return nil }
        var rect = CGRect.zero
        if CGRectMakeWithDictionaryRepresentation(rawBounds as! CFDictionary, &rect), rect.width > 1, rect.height > 1 {
            return rect
        }
        return nil
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
