import Foundation

public enum CaptureStopReason: Sendable, Equatable {
    case manual
    case applicationTermination
    case unexpected(String)
}

public enum CaptureSessionState: String, Sendable, Equatable {
    case idle
    case starting
    case recording
    case stopping
    case finalized
}

public enum CaptureEvent: Sendable, Equatable {
    case started(URL)
    case stopRequested(CaptureStopReason)
    case stoppedUnexpectedly(String)
    case finalized(CaptureStopResult)
    case finalizationFailed(String)
}

public struct CaptureStopResult: Sendable, Equatable {
    public var projectURL: URL
    public var reason: CaptureStopReason
    public var health: CaptureHealth
    public var hasUsableVideo: Bool
    public var finalizationError: String?

    public init(
        projectURL: URL,
        reason: CaptureStopReason,
        health: CaptureHealth,
        hasUsableVideo: Bool,
        finalizationError: String? = nil
    ) {
        self.projectURL = projectURL
        self.reason = reason
        self.health = health
        self.hasUsableVideo = hasUsableVideo
        self.finalizationError = finalizationError
    }
}
