import Foundation

/// Crash/termination-safe metadata updates for an in-progress capture bundle.
public enum CaptureRecovery {
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
