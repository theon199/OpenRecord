import AppKit
import Carbon.HIToolbox
import OpenRecord
import SwiftUI

extension RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    init(_ color: Color) {
        let ns = NSColor(color)
        let rgb = ns.usingColorSpace(.sRGB) ?? ns
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
}

enum Timecode {
    static func string(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        let tenths = Int((clamped.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    static func compact(_ time: TimeInterval) -> String {
        let clamped = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }
}

enum RecordShortcut {
    static let keyCode = UInt16(kVK_ANSI_R)

    static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ignored: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function, .help]
        return flags.subtracting(ignored) == [.control, .option, .command]
    }
}

struct LibraryItem: Identifiable, Hashable {
    var url: URL
    var name: String
    var modified: Date?

    var id: URL { url }

    static func from(url: URL) -> LibraryItem {
        let name = url.deletingPathExtension().lastPathComponent
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return LibraryItem(url: url, name: name, modified: modified)
    }
}

enum TelemetryLoader {
    static func load(
        from projectURL: URL
    ) throws -> (mouse: [CursorSample], clicks: [ClickSample], keys: [KeySample]) {
        let mouse = try ProjectJSON.decodeJSONL(
            CursorSample.self,
            from: ProjectLayout.mouseURL(in: projectURL)
        )
        let clicks = try ProjectJSON.decodeJSONL(
            ClickSample.self,
            from: ProjectLayout.clicksURL(in: projectURL)
        )
        let keys = try ProjectJSON.decodeJSONL(
            KeySample.self,
            from: ProjectLayout.keysURL(in: projectURL)
        )
        return (mouse, clicks, keys)
    }
}

func aspectFitRect(aspectWidth: CGFloat, aspectHeight: CGFloat, in size: CGSize) -> CGRect {
    let aspect = max(aspectWidth, 0.01) / max(aspectHeight, 0.01)
    let viewAspect = size.width / max(size.height, 0.01)
    if viewAspect > aspect {
        let height = size.height
        let width = height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }
    let width = size.width
    let height = width / aspect
    return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
}
