import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// TCC permissions required before `CaptureSession.start`.
public enum CapturePermissionKind: String, Sendable, CaseIterable, Hashable {
    case screenRecording
    case microphone
    case accessibility
    case camera

    /// The only permission required merely to enumerate/start a screen target.
    /// Optional capture features add their own permissions through
    /// `CapturePermissions.requiredPermissions(for:)`.
    public static let requiredForScreenCapture: [CapturePermissionKind] = [
        .screenRecording,
    ]
}

/// The complete set of capture choices for one recording.
///
/// Defaults intentionally preserve OpenRecord's pre-v4 behavior: microphone,
/// system audio, cursor/focus telemetry, and keyboard shortcuts are enabled;
/// semantic target capture and webcam capture remain opt-in.
public struct CaptureRequest: Codable, Sendable, Equatable, Hashable {
    public var capturesMicrophone: Bool
    public var capturesSystemAudio: Bool
    public var capturesCursorTelemetry: Bool
    public var capturesKeyboardShortcuts: Bool
    /// Capture privacy-filtered Accessibility interaction metadata in its own
    /// stream. This is deliberately independent from cursor telemetry because
    /// semantic evidence is useful even when pointer paths are disabled.
    public var capturesSemanticTargets: Bool
    public var capturesWebcam: Bool

    public init(
        capturesMicrophone: Bool = true,
        capturesSystemAudio: Bool = true,
        capturesCursorTelemetry: Bool = true,
        capturesKeyboardShortcuts: Bool = true,
        capturesWebcam: Bool = false,
        capturesSemanticTargets: Bool = false
    ) {
        self.capturesMicrophone = capturesMicrophone
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesCursorTelemetry = capturesCursorTelemetry
        self.capturesKeyboardShortcuts = capturesKeyboardShortcuts
        self.capturesSemanticTargets = capturesSemanticTargets
        self.capturesWebcam = capturesWebcam
    }

    public static let `default` = CaptureRequest()

    private enum CodingKeys: String, CodingKey {
        case capturesMicrophone
        case capturesSystemAudio
        case capturesCursorTelemetry
        case capturesKeyboardShortcuts
        case capturesSemanticTargets
        case capturesWebcam
    }

    /// Keep decoding v1-v7 request payloads lossless. In particular, a
    /// missing semantic key must never opt a legacy recording into AX capture.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capturesMicrophone: try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? true,
            capturesSystemAudio: try container.decodeIfPresent(Bool.self, forKey: .capturesSystemAudio) ?? true,
            capturesCursorTelemetry: try container.decodeIfPresent(Bool.self, forKey: .capturesCursorTelemetry) ?? true,
            capturesKeyboardShortcuts: try container.decodeIfPresent(Bool.self, forKey: .capturesKeyboardShortcuts) ?? true,
            capturesWebcam: try container.decodeIfPresent(Bool.self, forKey: .capturesWebcam) ?? false,
            capturesSemanticTargets: try container.decodeIfPresent(Bool.self, forKey: .capturesSemanticTargets) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturesMicrophone, forKey: .capturesMicrophone)
        try container.encode(capturesSystemAudio, forKey: .capturesSystemAudio)
        try container.encode(capturesCursorTelemetry, forKey: .capturesCursorTelemetry)
        try container.encode(capturesKeyboardShortcuts, forKey: .capturesKeyboardShortcuts)
        try container.encode(capturesSemanticTargets, forKey: .capturesSemanticTargets)
        try container.encode(capturesWebcam, forKey: .capturesWebcam)
    }

    public var requiresAccessibility: Bool {
        capturesCursorTelemetry || capturesKeyboardShortcuts || capturesSemanticTargets
    }
}

/// Alternate name used by recording setup clients.
public typealias RecordingOptions = CaptureRequest

/// Thrown when a required capture permission is missing. The UI should offer
/// `CapturePermissions.openSystemSettings(for:)`.
public struct CapturePermissionError: Error, LocalizedError, Sendable, Equatable {
    public var kind: CapturePermissionKind
    public var message: String

    public init(kind: CapturePermissionKind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Query, request, and deep-link to System Settings for capture permissions.
public enum CapturePermissions: Sendable {
    public static func isGranted(_ kind: CapturePermissionKind) -> Bool {
        switch kind {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .microphone:
            return AVAudioApplication.shared.recordPermission == .granted
        case .accessibility:
            return AXIsProcessTrusted()
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    /// Prompts when the OS still allows it. Previously denied TCC entries usually
    /// stay denied until the user flips the switch in System Settings.
    @discardableResult
    public static func request(_ kind: CapturePermissionKind) async -> Bool {
        switch kind {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() {
                return true
            }
            // ScreenCaptureKit presents the system prompt; CGRequestScreenCaptureAccess is deprecated.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return CGPreflightScreenCaptureAccess()
        case .microphone:
            if AVAudioApplication.shared.recordPermission == .granted {
                return true
            }
            return await AVAudioApplication.requestRecordPermission()
        case .accessibility:
            if AXIsProcessTrusted() {
                return true
            }
            // Literal matches `kAXTrustedCheckOptionPrompt` (a mutable CF global, not Sendable).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                return true
            }
            return await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    /// Permissions needed by the selected capture features, in a stable order.
    /// System audio has no separate TCC permission.
    public static func requiredPermissions(
        for request: CaptureRequest
    ) -> [CapturePermissionKind] {
        var kinds: [CapturePermissionKind] = [.screenRecording]
        if request.capturesMicrophone { kinds.append(.microphone) }
        if request.requiresAccessibility { kinds.append(.accessibility) }
        if request.capturesWebcam { kinds.append(.camera) }
        return kinds
    }

    /// Require only the permissions selected for this capture request.
    public static func ensureGranted(for request: CaptureRequest) async throws {
        for kind in requiredPermissions(for: request) {
            if isGranted(kind) {
                continue
            }
            _ = await Self.request(kind)
            if !isGranted(kind) {
                throw CapturePermissionError(kind: kind, message: denialMessage(for: kind))
            }
        }
    }

    /// Label-compatible spelling for callers that name the value `request`.
    public static func ensureGranted(request: CaptureRequest) async throws {
        try await ensureGranted(for: request)
    }

    /// Compatibility entry point for older callers. New capture setup should
    /// pass an explicit `CaptureRequest` instead.
    public static func ensureGranted(includeCamera: Bool = false) async throws {
        var request = CaptureRequest.default
        request.capturesWebcam = includeCamera
        try await ensureGranted(for: request)
    }

    public static func openSystemSettings(for kind: CapturePermissionKind) {
        NSWorkspace.shared.open(settingsURL(for: kind))
    }

    /// Deep link used by the UI and unit tests. Works on macOS 15 Settings too.
    public static func settingsURL(for kind: CapturePermissionKind) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor(for: kind))")!
    }

    public static func settingsAnchor(for kind: CapturePermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Privacy_ScreenCapture"
        case .microphone:
            return "Privacy_Microphone"
        case .accessibility:
            return "Privacy_Accessibility"
        case .camera:
            return "Privacy_Camera"
        }
    }

    public static func denialMessage(for kind: CapturePermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Screen Recording permission is required. Enable OpenRecord in System Settings → Privacy & Security → Screen Recording, then try again."
        case .microphone:
            return "Microphone permission is required. Enable OpenRecord in System Settings → Privacy & Security → Microphone, then try again."
        case .accessibility:
            return "Accessibility permission is required for the selected cursor, keyboard, or semantic target telemetry. Enable OpenRecord in System Settings → Privacy & Security → Accessibility, then try again."
        case .camera:
            return "Camera permission is required when webcam recording is enabled. Enable OpenRecord in System Settings → Privacy & Security → Camera, then try again."
        }
    }
}
