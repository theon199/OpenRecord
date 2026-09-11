import CoreGraphics
import Foundation
import OpenRecord
import Testing

@Test
func capturePointerPolicyUsesBoundsForDisplays() {
    let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let overlapping = CaptureWindowSnapshot(
        id: 99,
        bounds: Rect2D(x: 100, y: 100, width: 400, height: 300)
    )
    #expect(
        CapturePointerPolicy.isVisible(
            location: CGPoint(x: 200, y: 180),
            target: .display(id: 1),
            bounds: bounds,
            available: true,
            windowsFrontToBack: [overlapping]
        )
    )
    #expect(
        !CapturePointerPolicy.isVisible(
            location: CGPoint(x: 2000, y: 10),
            target: .display(id: 1),
            bounds: bounds,
            available: true,
            windowsFrontToBack: [overlapping]
        )
    )
}

@Test
func capturePointerPolicyHidesCursorOnOtherWindows() {
    let captured = CaptureWindowSnapshot(
        id: 1,
        bounds: Rect2D(x: 0, y: 0, width: 400, height: 300)
    )
    let overlapping = CaptureWindowSnapshot(
        id: 2,
        bounds: Rect2D(x: 120, y: 80, width: 180, height: 140)
    )
    let beside = CaptureWindowSnapshot(
        id: 3,
        bounds: Rect2D(x: 520, y: 40, width: 240, height: 180)
    )
    let windows = [overlapping, captured, beside]

    #expect(
        CapturePointerPolicy.isVisible(
            location: CGPoint(x: 40, y: 40),
            target: .window(id: 1),
            bounds: captured.bounds.cgRect,
            available: true,
            windowsFrontToBack: windows
        )
    )
    #expect(
        !CapturePointerPolicy.isVisible(
            location: CGPoint(x: 160, y: 120),
            target: .window(id: 1),
            bounds: captured.bounds.cgRect,
            available: true,
            windowsFrontToBack: windows
        )
    )
    #expect(
        !CapturePointerPolicy.isVisible(
            location: CGPoint(x: 600, y: 80),
            target: .window(id: 1),
            bounds: captured.bounds.cgRect,
            available: true,
            windowsFrontToBack: windows
        )
    )
}

@Test
func capturePointerPolicyFallsBackToBoundsWithoutWindowList() {
    let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
    #expect(
        CapturePointerPolicy.isVisible(
            location: CGPoint(x: 50, y: 40),
            target: .window(id: 7),
            bounds: bounds,
            available: true,
            windowsFrontToBack: []
        )
    )
    #expect(
        !CapturePointerPolicy.isVisible(
            location: CGPoint(x: 50, y: 40),
            target: .window(id: 7),
            bounds: bounds,
            available: false,
            windowsFrontToBack: []
        )
    )
}

@Test
func capturePointerPolicyIgnoresTransparentAndDesktopWindows() {
    let captured = CaptureWindowSnapshot(
        id: 1,
        bounds: Rect2D(x: 0, y: 0, width: 400, height: 300)
    )
    let overlay = CaptureWindowSnapshot(
        id: 8,
        bounds: Rect2D(x: 0, y: 0, width: 400, height: 300),
        alpha: 0,
        layer: 0
    )
    let desktop = CaptureWindowSnapshot(
        id: 9,
        bounds: Rect2D(x: 0, y: 0, width: 400, height: 300),
        layer: -1
    )
    #expect(
        CapturePointerPolicy.isVisible(
            location: CGPoint(x: 20, y: 20),
            target: .window(id: 1),
            bounds: captured.bounds.cgRect,
            available: true,
            windowsFrontToBack: [overlay, desktop, captured]
        )
    )
}

@Test
func captureWindowListParsesFrontToBackSnapshots() {
    let info: [[CFString: Any]] = [
        [
            kCGWindowNumber: 11,
            kCGWindowIsOnscreen: true,
            kCGWindowAlpha: 1.0,
            kCGWindowLayer: 0,
            kCGWindowBounds: [
                "X": 10,
                "Y": 20,
                "Width": 300,
                "Height": 200,
            ],
        ],
        [
            kCGWindowNumber: 12,
            kCGWindowIsOnscreen: true,
            kCGWindowAlpha: 0.8,
            kCGWindowLayer: 0,
            kCGWindowBounds: [
                "X": 0,
                "Y": 0,
                "Width": 800,
                "Height": 600,
            ],
        ],
    ]
    let snapshots = CaptureWindowList.snapshots(from: info)
    #expect(snapshots.count == 2)
    #expect(snapshots[0].id == 11)
    #expect(snapshots[0].bounds == Rect2D(x: 10, y: 20, width: 300, height: 200))
    #expect(snapshots[1].id == 12)
    #expect(snapshots[1].alpha == 0.8)
}

@Test
func captureSourceThumbnailPixelSizeFitsLongestEdge() {
    let landscape = CaptureSourceThumbnail.pixelSize(contentWidth: 1920, contentHeight: 1080)
    #expect(landscape.width == 360)
    #expect(landscape.height == CaptureSourceThumbnail.evenDimension(Int((1080 * (360.0 / 1920)).rounded())))
    #expect(landscape.width.isMultiple(of: 2))
    #expect(landscape.height.isMultiple(of: 2))

    let square = CaptureSourceThumbnail.pixelSize(contentWidth: 80, contentHeight: 80)
    #expect(square.width == 80)
    #expect(square.height == 80)

    #expect(CaptureSourceThumbnail.evenDimension(1) == 2)
    #expect(CaptureSourceThumbnail.evenDimension(3) == 2)
    #expect(CaptureSourceThumbnail.evenDimension(4) == 4)
}
