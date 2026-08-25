import Foundation

/// Crash/termination-safe metadata updates for an in-progress capture bundle.
public enum CaptureRecovery {
    /// Produces a stable final state for both normal and degraded captures.
    /// Secure Input gaps are privacy-preserving and do not by themselves make
    /// an otherwise healthy project "recovered".
    public static func health(
        reason: CaptureStopReason,
        warnings: Set<CaptureWarningCode>
    ) -> CaptureHealth {
        let recoveryWarnings = warnings.subtracting([.keyboardSecureInputGap])
        let recovered = reason != .manual || !recoveryWarnings.isEmpty
        return CaptureHealth(
            state: recovered ? .recovered : .complete,
            warnings: warnings.sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Display media is the sole project-preservation criterion. Optional
    /// track failures must not discard a usable screen recording.
    public static func shouldPreserveProject(hasUsableDisplayVideo: Bool) -> Bool {
        hasUsableDisplayVideo
    }

    /// Marks a bundle as recovered when capture finalization exceeded the
    /// application-termination deadline. The caller owns `projectURL`, so this
    /// intentionally bypasses ordinary library save restrictions while still
    /// performing an atomic same-directory replacement.
    public static func markFinalizationTimedOut(at projectURL: URL) throws {
        let metaURL = ProjectLayout.metaURL(in: projectURL)
        var meta = try AtomicFileWrite.readJSON(ProjectMeta.self, from: metaURL)
        var warnings = Set(meta.captureHealth?.warnings ?? [])
        warnings.insert(.finalizationTimedOut)
        meta.captureHealth = CaptureHealth(
            state: .recovered,
            warnings: warnings.sorted { $0.rawValue < $1.rawValue }
        )
        try AtomicFileWrite.writeJSON(meta, to: metaURL)
    }
}
