import Foundation

/// On-disk layout of a `<name>.openrecord/` bundle.
public enum ProjectLayout: Sendable {
    public static let bundleExtension = "openrecord"
    public static let metaFileName = "meta.json"
    public static let documentFileName = "project.json"
    public static let recordingDirectoryName = "recording"
    public static let displayVideoFileName = "display.mp4"
    public static let microphoneAudioFileName = "mic.m4a"
    public static let systemAudioFileName = "system.m4a"
    public static let mouseFileName = "mouse.jsonl"
    public static let clicksFileName = "clicks.jsonl"
    public static let targetGeometryFileName = "target.jsonl"
    public static let cursorsDirectoryName = "cursors"

    public static func metaURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(metaFileName, isDirectory: false)
    }

    public static func documentURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(documentFileName, isDirectory: false)
    }

    public static func recordingDirectory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(recordingDirectoryName, isDirectory: true)
    }

    public static func displayVideoURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(displayVideoFileName, isDirectory: false)
    }

    public static func microphoneAudioURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(microphoneAudioFileName, isDirectory: false)
    }

    public static func systemAudioURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(systemAudioFileName, isDirectory: false)
    }

    public static func mouseURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(mouseFileName, isDirectory: false)
    }

    public static func clicksURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(clicksFileName, isDirectory: false)
    }

    public static func targetGeometryURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(targetGeometryFileName, isDirectory: false)
    }

    public static func cursorsDirectory(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(cursorsDirectoryName, isDirectory: true)
    }
}
