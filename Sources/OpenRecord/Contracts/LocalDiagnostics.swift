import Foundation

/// Broad, local-only categories used when describing the last failure in a
/// diagnostics snapshot.  The category deliberately does not carry an error
/// message, which keeps copied diagnostics free of project or system details.
public enum LocalDiagnosticsErrorCategory: String, Sendable, Equatable {
    case none
    case projectContent
    case projectSave
    case export
    case telemetry
    case permissions
    case capture
    case unknown
}

/// A deterministic, privacy-safe snapshot suitable for a local "Copy
/// Diagnostics" action.  It contains technical metadata and capture health,
/// but never accepts project names, paths, device identifiers, or content.
public struct LocalDiagnosticsSnapshot: Sendable, Equatable {
    private let renderedText: String

    public init(
        appVersion: String,
        appBuild: String? = nil,
        operatingSystem: String,
        architecture: String,
        projectFormatVersion: Int,
        captureHealth: CaptureHealth? = nil,
        captureDiagnostics: CaptureDiagnostics? = nil,
        captureTiming: CaptureTiming? = nil,
        trackPresence: [CaptureTrackKind: Bool] = [:],
        trackDurations: [CaptureTrackKind: TimeInterval] = [:],
        exportSettings: VideoExportSettings = .default,
        lastErrorCategory: LocalDiagnosticsErrorCategory = .none
    ) {
        var lines: [String] = [
            "OpenRecord.Diagnostics.v1",
            "appVersion=\(Self.safeField(appVersion))",
            "appBuild=\(appBuild.map(Self.safeField) ?? Self.unknown)",
            "operatingSystem=\(Self.safeField(operatingSystem))",
            "architecture=\(Self.safeField(architecture))",
            "projectFormatVersion=\(projectFormatVersion)"
        ]

        if let captureHealth {
            let warnings = captureHealth.warnings
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            lines.append("captureHealth.state=\(captureHealth.state.rawValue)")
            lines.append("captureHealth.warnings=\(warnings.isEmpty ? Self.none : warnings)")
        } else {
            lines.append("captureHealth.state=\(Self.unknown)")
            lines.append("captureHealth.warnings=\(Self.unknown)")
        }

        for track in CaptureTrackKind.allCases {
            let diagnostic = captureDiagnostics?.diagnostic(for: track)
            let duration = diagnostic?.duration ?? trackDurations[track]
            let presence = Self.presence(
                for: track,
                diagnostic: diagnostic,
                explicit: trackPresence,
                duration: duration
            )
            let status = Self.status(
                for: track,
                diagnostic: diagnostic,
                presence: presence,
                hasDiagnostics: captureDiagnostics != nil
            )
            lines.append("track.\(track.rawValue).presence=\(presence.map(Self.bool) ?? Self.unknown)")
            lines.append("track.\(track.rawValue).status=\(status)")
            lines.append("track.\(track.rawValue).duration=\(Self.number(duration))")

            // A legacy timing offset is deliberately considered only when no
            // diagnostics object exists. A partial diagnostics object must not
            // silently mix old and new clocks.
            let initialOffset: TimeInterval?
            if let diagnostic {
                initialOffset = diagnostic.initialOffset
            } else if captureDiagnostics == nil {
                initialOffset = Self.legacyOffset(for: track, timing: captureTiming)
            } else {
                initialOffset = nil
            }
            lines.append("track.\(track.rawValue).initialOffset=\(Self.number(initialOffset))")
            lines.append("track.\(track.rawValue).endDrift=\(Self.number(diagnostic?.endDrift))")
            lines.append("track.\(track.rawValue).correction=\(Self.correction(diagnostic?.correction))")
        }

        lines.append("export.codec=\(exportSettings.codec.rawValue)")
        lines.append("export.resolution=\(exportSettings.resolution.rawValue)")
        lines.append("lastErrorCategory=\(lastErrorCategory.rawValue)")
        renderedText = lines.joined(separator: "\n")
    }

    /// The copyable line-oriented diagnostics text.
    public var text: String { renderedText }

    private static let unknown = "unknown"
    private static let none = "none"

    private static func presence(
        for track: CaptureTrackKind,
        diagnostic: CaptureTrackDiagnostic?,
        explicit: [CaptureTrackKind: Bool],
        duration: TimeInterval?
    ) -> Bool? {
        if let diagnostic {
            switch diagnostic.status {
            case .complete, .truncated:
                return true
            case .missing, .notRequested:
                return false
            }
        }
        if let explicitValue = explicit[track] { return explicitValue }
        guard let duration, duration.isFinite else { return nil }
        return duration > 0
    }

    private static func status(
        for track: CaptureTrackKind,
        diagnostic: CaptureTrackDiagnostic?,
        presence: Bool?,
        hasDiagnostics: Bool
    ) -> String {
        if let diagnostic { return diagnostic.status.rawValue }
        if let presence { return presence ? CaptureTrackStatus.complete.rawValue : CaptureTrackStatus.missing.rawValue }
        if !hasDiagnostics, track == .displayVideo { return CaptureTrackStatus.complete.rawValue }
        return unknown
    }

    private static func legacyOffset(
        for track: CaptureTrackKind,
        timing: CaptureTiming?
    ) -> TimeInterval? {
        switch track {
        case .displayVideo:
            return 0
        case .systemAudio:
            return timing?.systemAudioOffset
        case .microphone:
            return timing?.microphoneOffset
        case .webcam:
            return timing?.webcamOffset
        }
    }

    private static func correction(_ correction: CaptureTrackCorrection?) -> String {
        guard let correction else { return none }
        return "sourceDuration=\(number(correction.sourceDuration));timelineDuration=\(number(correction.timelineDuration));sourceRate=\(number(correction.sourceRate))"
    }

    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    private static func number(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite else { return unknown }
        return number(value)
    }

    private static func number(_ value: TimeInterval) -> String {
        guard value.isFinite else { return unknown }
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if rounded == 0 { return "0" }
        var result = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }

    private static func safeField(_ value: String) -> String {
        // Keep metadata on one line even if a caller supplies malformed text.
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0...0x1F, 0x7F...0x9F:
                return "?"
            default:
                return String(scalar)
            }
        }.joined()
    }
}
