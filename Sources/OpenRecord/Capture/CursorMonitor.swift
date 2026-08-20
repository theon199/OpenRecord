import CoreGraphics
import Foundation
import QuartzCore

/// HID listen-only tap for cursor path and clicks. Requires Accessibility.
final class CursorMonitor: @unchecked Sendable {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseWriter: JSONLWriter<CursorSample>?
    private var clickWriter: JSONLWriter<ClickSample>?
    private let stateLock = NSLock()
    private var recordingStart: CFTimeInterval?
    private var lastMoveTime: TimeInterval = -1

    func start(mouseURL: URL, clicksURL: URL) throws {
        mouseWriter = try JSONLWriter(url: mouseURL)
        clickWriter = try JSONLWriter(url: clicksURL)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: openRecordCursorEventTap,
            userInfo: refcon
        ) else {
            throw CapturePermissionError(
                kind: .accessibility,
                message: CapturePermissions.denialMessage(for: .accessibility)
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw OpenRecordError.io("Could not attach the cursor event tap to the run loop.")
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.runLoopSource = source
    }

    func setRecordingStart(_ time: CFTimeInterval) {
        stateLock.lock()
        recordingStart = time
        lastMoveTime = -1
        stateLock.unlock()
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        port = nil
        runLoopSource = nil
    }

    func closeFiles() throws {
        let mouseError = mouseWriter?.writeError
        let clickError = clickWriter?.writeError
        mouseWriter?.close()
        clickWriter?.close()
        mouseWriter = nil
        clickWriter = nil
        if let mouseError {
            throw mouseError
        }
        if let clickError {
            throw clickError
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }

        stateLock.lock()
        let start = recordingStart
        stateLock.unlock()
        guard let start else { return }

        let t = CACurrentMediaTime() - start
        guard t >= 0 else { return }

        // `CGEvent.location` is Quartz global points (origin: top-left of the main display).
        let location = event.location
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            clickWriter?.write(
                ClickSample(t: t, button: Self.button(type: type, event: event), down: down)
            )
            writeMove(t: t, location: location, force: true)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            writeMove(t: t, location: location, force: false)
        default:
            break
        }
    }

    private func writeMove(t: TimeInterval, location: CGPoint, force: Bool) {
        stateLock.lock()
        let last = lastMoveTime
        if !force, last >= 0, (t - last) < (1.0 / CaptureMediaFormat.mouseSamplesPerSecondCap) {
            stateLock.unlock()
            return
        }
        lastMoveTime = t
        stateLock.unlock()

        mouseWriter?.write(
            CursorSample(
                t: t,
                x: Double(location.x),
                y: Double(location.y),
                cursorId: CaptureMediaFormat.defaultCursorSpriteID
            )
        )
    }

    private static func button(type: CGEventType, event: CGEvent) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return .left
        case .rightMouseDown, .rightMouseUp:
            return .right
        case .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            if number == 2 { return .middle }
            return .other
        default:
            return .other
        }
    }

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()
}

private func openRecordCursorEventTap(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    _ = proxy
    if let refcon {
        Unmanaged<CursorMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
