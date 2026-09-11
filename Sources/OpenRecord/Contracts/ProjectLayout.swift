import Foundation

/// On-disk layout of a `<name>.openrecord/` bundle.
public enum ProjectLayout: Sendable {
    public static let bundleExtension = "openrecord"
    public static let metaFileName = "meta.json"
    public static let documentFileName = "project.json"
    /// Optional, rebuildable analysis cache.  Analysis never belongs in
    /// `meta.json` or `project.json`; keeping it in its own directory also
    /// lets older readers ignore it safely.
    public static let analysisDirectoryName = "analysis"
    public static let analysisManifestFileName = "manifest.json"
    public static let analysisActionsFileName = "actions.jsonl"
    public static let analysisOCRFileName = "ocr.jsonl"
    public static let analysisPrivacyFileName = "privacy.jsonl"
    public static let analysisSuggestionsFileName = "suggestions.jsonl"
    public static let analysisIndexFileName = "index.json"
    public static let recordingDirectoryName = "recording"
    public static let displayVideoFileName = "display.mp4"
    public static let webcamVideoFileName = "webcam.mp4"
    public static let thumbnailFileName = "thumb.jpg"
    public static let microphoneAudioFileName = "mic.m4a"
    public static let systemAudioFileName = "system.m4a"
    public static let mouseFileName = "mouse.jsonl"
    public static let clicksFileName = "clicks.jsonl"
    public static let keysFileName = "keys.jsonl"
    public static let typingFileName = "typing.jsonl"
    public static let targetGeometryFileName = "target.jsonl"
    public static let cursorsDirectoryName = "cursors"

    public static func metaURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(metaFileName, isDirectory: false)
    }

    public static func documentURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(documentFileName, isDirectory: false)
    }

    public static func analysisDirectory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(analysisDirectoryName, isDirectory: true)
    }

    public static func analysisManifestURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisManifestFileName, isDirectory: false)
    }

    public static func analysisActionsURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisActionsFileName, isDirectory: false)
    }

    public static func analysisOCRURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisOCRFileName, isDirectory: false)
    }

    public static func analysisPrivacyURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisPrivacyFileName, isDirectory: false)
    }

    public static func analysisSuggestionsURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisSuggestionsFileName, isDirectory: false)
    }

    public static func analysisIndexURL(in projectURL: URL) -> URL {
        analysisDirectory(in: projectURL)
            .appendingPathComponent(analysisIndexFileName, isDirectory: false)
    }

    /// Resolves one of the known analysis files without allowing callers to
    /// accidentally construct a path outside the cache directory.
    public static func analysisURL(
        for kind: AnalysisSidecarKind,
        in projectURL: URL
    ) -> URL {
        switch kind {
        case .actions: analysisActionsURL(in: projectURL)
        case .ocr: analysisOCRURL(in: projectURL)
        case .privacy: analysisPrivacyURL(in: projectURL)
        case .suggestions: analysisSuggestionsURL(in: projectURL)
        }
    }

    public static func recordingDirectory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(recordingDirectoryName, isDirectory: true)
    }

    public static func displayVideoURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(displayVideoFileName, isDirectory: false)
    }

    public static func webcamVideoURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(webcamVideoFileName, isDirectory: false)
    }

    public static func thumbnailURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(thumbnailFileName, isDirectory: false)
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

    public static func keysURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(keysFileName, isDirectory: false)
    }

    public static func typingURL(in projectURL: URL) -> URL {
        recordingDirectory(in: projectURL)
            .appendingPathComponent(typingFileName, isDirectory: false)
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
