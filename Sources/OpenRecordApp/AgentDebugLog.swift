import AppKit
import Foundation

enum AgentDebugLog {
    private static let path = "/Users/charan/Desktop/OpenRecord/.cursor/debug-344a9a.log"
    private static let sessionId = "344a9a"

    static func write(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "id": "log_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6))",
        ]
        payload["data"] = data
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: json, encoding: .utf8)
        else { return }
        line.append("\n")
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url), let bytes = line.data(using: .utf8) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
    }

    static func windowDump() -> String {
        let items: [[String: Any]] = NSApp.windows.map { window in
            [
                "class": String(describing: type(of: window)),
                "title": window.title,
                "frame": NSStringFromRect(window.frame),
                "visible": window.isVisible,
                "key": window.isKeyWindow,
                "main": window.isMainWindow,
                "canMain": window.canBecomeMain,
                "canKey": window.canBecomeKey,
                "alpha": Double(window.alphaValue),
                "content": window.contentView.map { String(describing: type(of: $0)) } ?? "nil",
                "contentSize": NSStringFromSize(window.contentView?.bounds.size ?? .zero),
                "subviewCount": window.contentView?.subviews.count ?? -1,
                "subviews": window.contentView?.subviews.map { String(describing: type(of: $0)) }.joined(separator: ",") ?? "",
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }
}
