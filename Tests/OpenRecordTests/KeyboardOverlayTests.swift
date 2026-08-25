import CoreGraphics
import CoreImage
import Darwin
import Testing
@testable import OpenRecord

/// Deterministic coverage for the keyboard overlay state machine and the
/// shared geometry/rasterization helpers used by preview and export.
enum KeyboardOverlaySuite {
    private static let canvas = CGSize(width: 1920, height: 1080)

    static func run() throws {
        try disabledSettingsProduceNoStateOrImage()
        try keyDownsOnlyAndStableLabels()
        try fadeDelayAndFadeDurationBoundaries()
        try sameTimeEventsAndMaxVisibleOrdering()
        try geometryUsesSharedCanvasCoordinates()
        try constrainedGeometryStaysNonNegative()
        try rendererPresenceBoundsAndOpacity()
    }

    private static func disabledSettingsProduceNoStateOrImage() throws {
        let timeline = KeyboardOverlayTimeline(samples: [
            KeySample(t: 1, key: "K", modifiers: [.command], down: true),
        ])
        let settings = KeyboardOverlaySettings(enabled: false)
        let state = timeline.state(at: 1, settings: settings)
        guard state.keys.isEmpty,
              KeyboardOverlayLayout.geometry(
                  for: state,
                  settings: settings,
                  canvasSize: canvas,
                  canvasPadding: 48
              ) == nil,
              KeyboardOverlayRenderer.image(
                  state: state,
                  settings: settings,
                  canvasSize: canvas,
                  canvasPadding: 48
              ) == nil
        else {
            throw failure("disabled keyboard settings produced visible overlay content")
        }
    }

    private static func keyDownsOnlyAndStableLabels() throws {
        let timeline = KeyboardOverlayTimeline(samples: [
            KeySample(t: 1, key: "K", modifiers: [.command, .shift], down: true),
            KeySample(t: 1.01, key: "K", modifiers: [.command, .shift], down: false),
            KeySample(t: 1.02, key: "A", modifiers: [
                .control, .option, .shift, .command, .function,
            ], down: true),
        ])
        let settings = KeyboardOverlaySettings(enabled: true, fadeDelay: 0.8)
        let state = timeline.state(at: 1.02, settings: settings)
        guard state.keys.map(\.label) == ["⇧⌘ K", "⌃⌥⇧⌘fn A"],
              state.keys.allSatisfy({ $0.opacity == 1 })
        else {
            throw failure("key-down filtering or display-label ordering changed")
        }
        guard timeline.state(at: 1.01, settings: settings).keys.map(\.label) == ["⇧⌘ K"] else {
            throw failure("key-up event was incorrectly shown as a new key")
        }
    }

    private static func fadeDelayAndFadeDurationBoundaries() throws {
        let timeline = KeyboardOverlayTimeline(samples: [
            KeySample(t: 10, key: "X", down: true),
        ])
        let settings = KeyboardOverlaySettings(enabled: true, fadeDelay: 0.5)
        let fadeDuration = KeyboardOverlayTimeline.fadeDuration

        let atDelay = timeline.state(at: 10.5, settings: settings)
        let beforeFadeEnd = timeline.state(
            at: 10.5 + fadeDuration - 0.000001,
            settings: settings
        )
        let atFadeEnd = timeline.state(at: 10.5 + fadeDuration, settings: settings)
        let afterFadeEnd = timeline.state(at: 10.5 + fadeDuration + 0.000001, settings: settings)
        guard atDelay.keys.count == 1, atDelay.keys[0].opacity == 1,
              beforeFadeEnd.isVisible, beforeFadeEnd.keys[0].opacity > 0,
              !atFadeEnd.isVisible,
              afterFadeEnd.keys.isEmpty
        else {
            throw failure("keyboard fade-delay/fade-duration edges were not half-open")
        }

        // Settings are normalized before use, so an invalid delay still has
        // the documented minimum hold interval.
        let normalized = KeyboardOverlaySettings(enabled: true, fadeDelay: -1)
        guard timeline.state(at: 10.2, settings: normalized).keys.count == 1,
              timeline.state(
                  at: 10.2 + KeyboardOverlayTimeline.fadeDuration - 0.000001,
                  settings: normalized
              ).isVisible,
              !timeline.state(
                  at: 10.2 + KeyboardOverlayTimeline.fadeDuration,
                  settings: normalized
              ).isVisible
        else {
            throw failure("keyboard fade-delay normalization was not applied")
        }
    }

    private static func sameTimeEventsAndMaxVisibleOrdering() throws {
        let timeline = KeyboardOverlayTimeline(samples: [
            KeySample(t: 2, key: "A", down: true),
            KeySample(t: 2, key: "B", down: true),
            KeySample(t: 2, key: "C", down: true),
            KeySample(t: 2.1, key: "D", down: true),
        ])
        let settings = KeyboardOverlaySettings(enabled: true, maxVisibleKeys: 3)
        guard timeline.state(at: 2, settings: settings).keys.map(\.label) == ["A", "B", "C"],
              timeline.state(at: 2.1, settings: settings).keys.map(\.label) == ["B", "C", "D"]
        else {
            throw failure("same-time events did not retain capture order")
        }
        let limited = KeyboardOverlaySettings(enabled: true, maxVisibleKeys: 1)
        guard timeline.state(at: 2.1, settings: limited).keys.map(\.label) == ["D"] else {
            throw failure("max-visible ordering did not retain the newest key")
        }
    }

    private static func geometryUsesSharedCanvasCoordinates() throws {
        let state = KeyboardOverlayState(keys: [
            KeyboardOverlayKey(id: 1, label: "⌘ K", opacity: 1),
            KeyboardOverlayKey(id: 2, label: "Enter", opacity: 1),
        ])
        var settings = KeyboardOverlaySettings(enabled: true, position: .bottomCenter)
        guard let center = KeyboardOverlayLayout.geometry(
            for: state,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ) else { throw failure("bottom-center geometry was not produced") }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        guard center.bounds.midX == canvas.width / 2,
              center.keyRects.count == state.keys.count,
              center.keyRects.allSatisfy({ canvasRect.contains($0) }),
              center.keyRects.dropFirst().enumerated().allSatisfy({ index, rect in
                  rect.minX >= center.keyRects[index].maxX
              })
        else { throw failure("bottom-center geometry was not centered or contiguous") }

        settings.position = .bottomLeft
        guard let left = KeyboardOverlayLayout.geometry(
            for: state,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ), left.bounds.minX == 48, canvasRect.contains(left.bounds) else {
            throw failure("bottom-left geometry did not honor canvas padding")
        }
    }

    private static func constrainedGeometryStaysNonNegative() throws {
        let state = KeyboardOverlayState(keys: [
            KeyboardOverlayKey(id: 1, label: "A very long key label", opacity: 1),
            KeyboardOverlayKey(id: 2, label: "Another long key", opacity: 0.5),
        ])
        let tinyCanvas = CGSize(width: 140, height: 80)
        for position in [KeyboardOverlayPosition.bottomCenter, .bottomLeft] {
            let settings = KeyboardOverlaySettings(enabled: true, position: position)
            guard let geometry = KeyboardOverlayLayout.geometry(
                for: state,
                settings: settings,
                canvasSize: tinyCanvas,
                canvasPadding: 24
            ), geometry.bounds.minX >= 0, geometry.bounds.minY >= 0,
                  geometry.keyRects.allSatisfy({ $0.minX >= 0 && $0.minY >= 0 })
            else { throw failure("constrained \(String(describing: position)) geometry escaped the origin") }
        }
    }

    private static func rendererPresenceBoundsAndOpacity() throws {
        let settings = KeyboardOverlaySettings(enabled: true)
        let opaque = KeyboardOverlayState(keys: [
            KeyboardOverlayKey(id: 1, label: "⌘ K", opacity: 1),
        ])
        let translucent = KeyboardOverlayState(keys: [
            KeyboardOverlayKey(id: 1, label: "⌘ K", opacity: 0.25),
        ])
        let invisible = KeyboardOverlayState(keys: [
            KeyboardOverlayKey(id: 1, label: "⌘ K", opacity: 0),
        ])
        guard let geometry = KeyboardOverlayLayout.geometry(
            for: opaque,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ), let image = KeyboardOverlayRenderer.image(
            state: opaque,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ), let fadedImage = KeyboardOverlayRenderer.image(
            state: translucent,
            settings: settings,
            canvasSize: canvas,
            canvasPadding: 48
        ), opaque.isVisible, translucent.isVisible, !invisible.isVisible,
              image.extent.width > 1, image.extent.height > 1,
              fadedImage.extent == image.extent,
              image.extent.width <= geometry.bounds.width.rounded(.up),
              image.extent.height <= geometry.bounds.height.rounded(.up),
              KeyboardOverlayRenderer.image(
                  state: invisible,
                  settings: settings,
                  canvasSize: canvas,
                  canvasPadding: 48
              ) == nil
        else { throw failure("keyboard renderer presence/bounds/opacity contract failed") }
    }

    private static func failure(_ message: String) -> OpenRecordError {
        .io("Keyboard overlay regression: " + message)
    }
}

@Test
func keyboardOverlayPhase4() throws {
    try KeyboardOverlaySuite.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordKeyboardOverlayTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunKeyboardOverlayTests()
}

@_cdecl("OpenRecordRunKeyboardOverlayTests")
func OpenRecordRunKeyboardOverlayTests() {
    do {
        try KeyboardOverlaySuite.run()
        fputs("OpenRecordTests: keyboard overlay phase 4 tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: keyboard overlay phase 4 tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
