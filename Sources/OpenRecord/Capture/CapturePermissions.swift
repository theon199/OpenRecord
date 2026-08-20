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
}

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
        }
    }

    /// Screen Recording, Microphone, and Accessibility. Throws rather than
    /// continuing without cursor telemetry or media.
    public static func ensureGranted() async throws {
        for kind in CapturePermissionKind.allCases {
            if isGranted(kind) {
                continue
            }
            _ = await request(kind)
            if !isGranted(kind) {
                throw CapturePermissionError(kind: kind, message: denialMessage(for: kind))
            }
        }
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
        }
    }

    public static func denialMessage(for kind: CapturePermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Screen Recording permission is required. Enable OpenRecord in System Settings → Privacy & Security → Screen Recording, then try again."
        case .microphone:
            return "Microphone permission is required. Enable OpenRecord in System Settings → Privacy & Security → Microphone, then try again."
        case .accessibility:
            return "Accessibility permission is required to record the cursor. Enable OpenRecord in System Settings → Privacy & Security → Accessibility, then try again. Recording cannot continue without cursor telemetry."
        }
    }
}
