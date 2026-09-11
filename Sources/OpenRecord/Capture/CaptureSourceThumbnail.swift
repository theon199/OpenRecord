import AppKit
import Foundation
import ScreenCaptureKit

/// One-shot ScreenCaptureKit stills for the record-source picker.
public enum CaptureSourceThumbnail: Sendable {
    public static let maxLongestEdge = 360

    public static func pixelSize(
        contentWidth: Double,
        contentHeight: Double,
        maxLongestEdge: Int = maxLongestEdge
    ) -> (width: Int, height: Int) {
        let width = max(contentWidth, 1)
        let height = max(contentHeight, 1)
        let longest = max(width, height)
        let scale = min(1, Double(maxLongestEdge) / longest)
        return (
            evenDimension(Int((width * scale).rounded())),
            evenDimension(Int((height * scale).rounded()))
        )
    }

    public static func evenDimension(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }

    public static func image(for target: CaptureTarget) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return nil }
        return await image(for: target, content: content)
    }

    public static func image(
        for target: CaptureTarget,
        content: SCShareableContent
    ) async -> NSImage? {
        guard let cgImage = await cgImage(for: target, content: content) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    static func cgImage(
        for target: CaptureTarget,
        content: SCShareableContent
    ) async -> CGImage? {
        let ownIDs = Set(
            [OpenRecordInfo.bundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0 }
        )
        let excludedApps = content.applications.filter { ownIDs.contains($0.bundleIdentifier) }
        let filter: SCContentFilter
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                return nil
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(id) }) else {
                return nil
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let rect = filter.contentRect
        guard rect.width > 1, rect.height > 1 else { return nil }
        let size = pixelSize(contentWidth: rect.width, contentHeight: rect.height)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.queueDepth = 1
        configuration.pixelFormat = CaptureMediaFormat.videoPixelFormat
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}
