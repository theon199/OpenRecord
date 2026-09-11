import CryptoKit
import Foundation

// MARK: - Privacy vocabulary

/// The deterministic classes of private material recognized by the Privacy
/// Firewall.  The enum is deliberately about *what was observed*, not the
/// observed value itself.  Values are represented only by a fingerprint in
/// persisted findings.
public enum PrivacyCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case apiKey = "api-key"
    case commonToken = "common-token"
    case email
    case internalURL = "internal-url"
    case notification
    case accountIdentifier = "account-identifier"
    case sensitiveTerm = "sensitive-term"
    case face
    case name

    /// Compatibility spelling for callers that use the shorter detector name.
    public static var token: Self { .commonToken }
    public static var apiKeys: Self { .apiKey }
    public static var commonTokens: Self { .commonToken }
    public static var userConfiguredTerm: Self { .sensitiveTerm }
    public static var account: Self { .accountIdentifier }
    public static var url: Self { .internalURL }
}

public typealias PrivacyFindingCategory = PrivacyCategory
public typealias PrivacyDetector = PrivacyCategory
public typealias PrivacyDetectorKind = PrivacyCategory

/// Human-review confidence is kept separate from the detector's raw score so
/// the encoded contract stays stable if detector scoring changes.
public enum PrivacyConfidence: String, Codable, CaseIterable, Sendable, Hashable {
    case low
    case medium
    case high

    public var score: Double {
        switch self {
        case .low: 0.35
        case .medium: 0.65
        case .high: 0.9
        }
    }

    public static func from(score: Double) -> Self {
        guard score.isFinite else { return .low }
        if score >= 0.8 { return .high }
        if score >= 0.5 { return .medium }
        return .low
    }

    public static var possible: Self { .low }
    public static var probable: Self { .medium }
    public static var certain: Self { .high }
}

/// Review lifecycle for a possible privacy finding.  `.verified` means a
/// second scan found the same category/fingerprint in rendered output; it is
/// not a claim that the entire source bundle is sanitized.
public enum PrivacyFindingState: String, Codable, CaseIterable, Sendable, Hashable {
    case pending
    case accepted
    case rejected
    case stale
    case verified

    public var isAcceptedMask: Bool {
        self == .accepted || self == .verified
    }

    public static var possible: Self { .pending }
    public static var confirmed: Self { .accepted }
    public static var invalid: Self { .rejected }
}

public typealias PrivacyReviewState = PrivacyFindingState
public typealias PrivacyFindingStatus = PrivacyFindingState

public enum PrivacyObservationSource: String, Codable, CaseIterable, Sendable, Hashable {
    case ocr
    case accessibility
    case semantic
    case notification
    case accountSignal = "account-signal"
    case userConfigured = "user-configured"
    case faceDetector = "face-detector"
    case nameDetector = "name-detector"
    case renderedOutput = "rendered-output"
}

public enum PrivacyCoordinateSpace: String, Codable, CaseIterable, Sendable, Hashable {
    case normalizedCanvas = "normalized-canvas"
    case normalizedWindow = "normalized-window"
    case pixels
    case renderedOutput = "rendered-output"
}

// MARK: - Ephemeral detector input

/// Text observed by OCR or an adapter.  This type intentionally contains the
/// transient plaintext required for local matching.  It must never be written
/// to an analysis sidecar; `PrivacyFinding` contains only a fingerprint.
public struct PrivacyTextObservation: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var rect: Rect2D
    public var confidence: Double
    public var source: PrivacyObservationSource
    public var coordinateSpace: PrivacyCoordinateSpace
    public var windowID: String?

    public init(
        id: AnalysisEvidenceID = PrivacyTextObservation.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        text: String,
        rect: Rect2D,
        confidence: Double = 1,
        source: PrivacyObservationSource = .ocr,
        coordinateSpace: PrivacyCoordinateSpace = .normalizedCanvas,
        windowID: String? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.source = source
        self.coordinateSpace = coordinateSpace
        self.windowID = windowID
    }

    public init(
        id: AnalysisEvidenceID = PrivacyTextObservation.makeID(),
        timestamp: TimeInterval,
        duration: TimeInterval = 0,
        text: String,
        rect: Rect2D,
        confidence: Double = 1,
        source: PrivacyObservationSource = .ocr,
        coordinateSpace: PrivacyCoordinateSpace = .normalizedCanvas,
        windowID: String? = nil
    ) {
        self.init(
            id: id,
            t: timestamp,
            duration: duration,
            text: text,
            rect: rect,
            confidence: confidence,
            source: source,
            coordinateSpace: coordinateSpace,
            windowID: windowID
        )
    }

    public var bounds: Rect2D {
        get { rect }
        set { rect = newValue }
    }

    public var sourceTime: TimeInterval { t }

    public var timestamp: TimeInterval {
        get { t }
        set { t = newValue }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-text-" + UUID().uuidString.lowercased())
    }
}

public enum PrivacySemanticSignalKind: String, Codable, CaseIterable, Sendable, Hashable {
    case text
    case sensitiveText = "sensitive-text"
    case accountIdentifier = "account-identifier"
    case notification
    case face
    case name
}

/// Privacy-relevant semantic metadata. `value` is transient adapter input and
/// is deliberately not copied into findings.
public struct PrivacySemanticSignal: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var kind: PrivacySemanticSignalKind
    public var value: String?
    public var rect: Rect2D?
    public var confidence: Double
    public var windowID: String?

    public init(
        id: AnalysisEvidenceID = PrivacySemanticSignal.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        kind: PrivacySemanticSignalKind,
        value: String? = nil,
        rect: Rect2D? = nil,
        confidence: Double = 1,
        windowID: String? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.kind = kind
        self.value = value
        self.rect = rect
        self.confidence = confidence
        self.windowID = windowID
    }

    public var bounds: Rect2D? {
        get { rect }
        set { rect = newValue }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-semantic-" + UUID().uuidString.lowercased())
    }
}

/// A transient window/crop transform used to follow a finding as a window is
/// moved, scrolled, or modestly zoomed. `offset` and `scrollOffset` are in
/// normalized canvas units; the resulting rectangle is clamped to the canvas.
public struct PrivacyWindowSignal: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var windowID: String?
    public var offset: Point2D
    public var scrollOffset: Point2D
    public var scale: Double
    public var confidence: Double

    public init(
        id: AnalysisEvidenceID = PrivacyWindowSignal.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        windowID: String? = nil,
        offset: Point2D = Point2D(x: 0, y: 0),
        scrollOffset: Point2D = Point2D(x: 0, y: 0),
        scale: Double = 1,
        confidence: Double = 1
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.windowID = windowID
        self.offset = offset
        self.scrollOffset = scrollOffset
        self.scale = scale
        self.confidence = confidence
    }

    /// Convenience spelling for a window movement without a separate scroll.
    public init(
        t: TimeInterval,
        duration: TimeInterval = 0,
        windowID: String? = nil,
        translation: Point2D,
        scale: Double = 1,
        confidence: Double = 1
    ) {
        self.init(
            t: t,
            duration: duration,
            windowID: windowID,
            offset: translation,
            scrollOffset: Point2D(x: 0, y: 0),
            scale: scale,
            confidence: confidence
        )
    }

    public var translation: Point2D {
        get { offset }
        set { offset = newValue }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-window-" + UUID().uuidString.lowercased())
    }
}

public struct PrivacyNotificationSignal: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var rect: Rect2D
    public var title: String?
    public var confidence: Double
    public var windowID: String?

    public init(
        id: AnalysisEvidenceID = PrivacyNotificationSignal.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        rect: Rect2D,
        title: String? = nil,
        confidence: Double = 0.9,
        windowID: String? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.rect = rect
        self.title = title
        self.confidence = confidence
        self.windowID = windowID
    }

    public var bounds: Rect2D {
        get { rect }
        set { rect = newValue }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-notification-" + UUID().uuidString.lowercased())
    }
}

public struct PrivacyAccountSignal: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var identifier: String?
    public var rect: Rect2D
    public var confidence: Double
    public var windowID: String?

    public init(
        id: AnalysisEvidenceID = PrivacyAccountSignal.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        identifier: String? = nil,
        rect: Rect2D,
        confidence: Double = 0.9,
        windowID: String? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.identifier = identifier
        self.rect = rect
        self.confidence = confidence
        self.windowID = windowID
    }

    public init(
        id: AnalysisEvidenceID = PrivacyAccountSignal.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        accountIdentifier: String?,
        rect: Rect2D,
        confidence: Double = 0.9,
        windowID: String? = nil
    ) {
        self.init(
            id: id,
            t: t,
            duration: duration,
            identifier: accountIdentifier,
            rect: rect,
            confidence: confidence,
            windowID: windowID
        )
    }

    public var bounds: Rect2D {
        get { rect }
        set { rect = newValue }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-account-" + UUID().uuidString.lowercased())
    }
}

public typealias PrivacyObservation = PrivacyGeometryObservation
public typealias PrivacyWindowObservation = PrivacyWindowSignal
public typealias PrivacyNotificationObservation = PrivacyNotificationSignal
public typealias PrivacyAccountObservation = PrivacyAccountSignal

/// Configuration for deterministic local detectors. Faces and names are
/// opt-in because they are materially more personal than token/URL patterns.
public struct PrivacyAnalyzerConfiguration: Codable, Sendable, Hashable {
    public var detectFaces: Bool
    public var detectNames: Bool
    public var sourceSize: Size2D?
    public var maximumTrackGap: TimeInterval
    public var frameDuration: TimeInterval

    public init(
        detectFaces: Bool = false,
        detectNames: Bool = false,
        sourceSize: Size2D? = nil,
        maximumTrackGap: TimeInterval = 0.75,
        frameDuration: TimeInterval = 1.0 / 30.0
    ) {
        self.detectFaces = detectFaces
        self.detectNames = detectNames
        self.sourceSize = sourceSize
        self.maximumTrackGap = maximumTrackGap.isFinite
            ? min(max(maximumTrackGap, 0), 30)
            : 0.75
        self.frameDuration = frameDuration.isFinite && frameDuration > 0
            ? min(max(frameDuration, 1.0 / 240.0), 2)
            : 1.0 / 30.0
    }

    public static let `default` = PrivacyAnalyzerConfiguration()
}

public typealias PrivacyFirewallConfiguration = PrivacyAnalyzerConfiguration

// MARK: - Redaction-safe geometry and evidence

/// One source-timed, normalized rectangle.  It contains no text or OCR
/// candidate and is therefore safe to encode into privacy.jsonl.
public struct PrivacyGeometryObservation: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var rect: Rect2D
    public var confidence: Double
    public var source: PrivacyObservationSource
    public var coordinateSpace: PrivacyCoordinateSpace
    public var sequence: UInt64?

    public init(
        id: AnalysisEvidenceID,
        t: TimeInterval,
        duration: TimeInterval = 0,
        rect: Rect2D,
        confidence: Double,
        source: PrivacyObservationSource,
        coordinateSpace: PrivacyCoordinateSpace = .normalizedCanvas,
        sequence: UInt64? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.rect = rect
        self.confidence = confidence
        self.source = source
        self.coordinateSpace = coordinateSpace
        self.sequence = sequence
    }

    public init(
        id: AnalysisEvidenceID,
        timestamp: TimeInterval,
        duration: TimeInterval = 0,
        rect: Rect2D,
        confidence: Double,
        source: PrivacyObservationSource,
        coordinateSpace: PrivacyCoordinateSpace = .normalizedCanvas,
        sequence: UInt64? = nil
    ) {
        self.init(
            id: id,
            t: timestamp,
            duration: duration,
            rect: rect,
            confidence: confidence,
            source: source,
            coordinateSpace: coordinateSpace,
            sequence: sequence
        )
    }

    public var bounds: Rect2D {
        get { rect }
        set { rect = newValue }
    }

    public var sourceTime: TimeInterval { t }
    public var timestamp: TimeInterval {
        get { t }
        set { t = newValue }
    }
    public var endTime: TimeInterval { t + max(duration, 0) }

    public var normalized: Self {
        var value = self
        value.t = t.isFinite ? max(t, 0) : 0
        value.duration = duration.isFinite ? max(duration, 0) : 0
        value.rect = PrivacyGeometry.normalized(rect)
        value.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        return value
    }
}

/// A tracked candidate through scrolling/window motion.  Each observation is
/// retained so a renderer can interpolate or conservatively cover the motion.
public struct PrivacyGeometryTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var observations: [PrivacyGeometryObservation]
    public var state: PrivacyFindingState

    public init(
        id: AnalysisEvidenceID = PrivacyGeometryTrack.makeID(),
        observations: [PrivacyGeometryObservation],
        state: PrivacyFindingState = .pending
    ) {
        self.id = id
        self.observations = observations.map(\.normalized).sorted {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.id.rawValue < $1.id.rawValue
        }
        self.state = state
    }

    public var start: TimeInterval { observations.map(\.t).min() ?? 0 }
    public var end: TimeInterval {
        observations.map(\.endTime).max() ?? start
    }
    public var sourceStart: TimeInterval { start }
    public var sourceEnd: TimeInterval { end }
    public var samples: [PrivacyGeometryObservation] {
        get { observations }
        set { observations = newValue }
    }

    public var normalized: Self {
        Self(id: id, observations: observations, state: state)
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-track-" + UUID().uuidString.lowercased())
    }
}

/// A compact SHA-256 digest.  The original value is intentionally not stored
/// and cannot be recovered from this type.
public struct PrivacyFingerprint: Codable, Sendable, Hashable {
    public static let algorithmName = "SHA-256"
    public let algorithm: String
    public let digest: String

    public init(digest: String, algorithm: String = PrivacyFingerprint.algorithmName) {
        self.algorithm = algorithm
        self.digest = digest.lowercased()
    }

    public init(_ ephemeralValue: String) {
        self.init(value: ephemeralValue)
    }

    public init(value ephemeralValue: String) {
        let hash = SHA256.hash(data: Data(ephemeralValue.utf8))
        self.algorithm = Self.algorithmName
        self.digest = hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ ephemeralValue: String) -> Self {
        Self(value: ephemeralValue)
    }

    public var hexDigest: String { digest }
    public var isWellFormed: Bool {
        algorithm == Self.algorithmName
            && digest.count == 64
            && digest.unicodeScalars.allSatisfy {
                switch $0.value {
                case 48...57, 65...70, 97...102: true
                default: false
                }
            }
    }
}

/// Counts what deterministic detectors actually ran and matched.  A complete
/// list of detector categories is useful in a report without implying that
/// unrecognized material cannot exist.
public struct PrivacyDetectorCoverage: Codable, Sendable, Hashable {
    public var detectorsRun: [PrivacyCategory]
    public var matchedByCategory: [PrivacyCategory: Int]
    public var scannedObservationCount: Int
    public var scannedFrameCount: Int
    public var renderedOutputScanned: Bool

    public init(
        detectorsRun: [PrivacyCategory] = [],
        matchedByCategory: [PrivacyCategory: Int] = [:],
        scannedObservationCount: Int = 0,
        scannedFrameCount: Int = 0,
        renderedOutputScanned: Bool = false
    ) {
        self.detectorsRun = Self.unique(detectorsRun)
        self.matchedByCategory = matchedByCategory.mapValues { max(0, $0) }
        self.scannedObservationCount = max(0, scannedObservationCount)
        self.scannedFrameCount = max(0, scannedFrameCount)
        self.renderedOutputScanned = renderedOutputScanned
    }

    public var categories: [PrivacyCategory] { detectorsRun }
    public var detectors: [PrivacyCategory] { detectorsRun }
    public var countsByCategory: [PrivacyCategory: Int] { matchedByCategory }
    public var scannedFrames: Int { scannedFrameCount }
    public var matchedCount: Int { matchedByCategory.values.reduce(0, +) }
    public var coverageRatio: Double {
        guard scannedObservationCount > 0 else { return 0 }
        return min(max(Double(matchedCount) / Double(scannedObservationCount), 0), 1)
    }
    public var coverage: Double { coverageRatio }

    public func merging(_ other: Self) -> Self {
        var counts = matchedByCategory
        for (category, count) in other.matchedByCategory {
            counts[category, default: 0] += count
        }
        return Self(
            detectorsRun: Self.unique(detectorsRun + other.detectorsRun),
            matchedByCategory: counts,
            scannedObservationCount: scannedObservationCount + other.scannedObservationCount,
            scannedFrameCount: scannedFrameCount + other.scannedFrameCount,
            renderedOutputScanned: renderedOutputScanned || other.renderedOutputScanned
        )
    }

    private static func unique(_ values: [PrivacyCategory]) -> [PrivacyCategory] {
        var seen = Set<PrivacyCategory>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// One persisted analysis row.  There is deliberately no plaintext field.
public struct PrivacyFinding: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var category: PrivacyCategory
    public var confidence: PrivacyConfidence
    public var confidenceScore: Double
    public var state: PrivacyFindingState
    public var fingerprint: PrivacyFingerprint
    public var tracks: [PrivacyGeometryTrack]
    public var detectorCoverage: PrivacyDetectorCoverage?

    public init(
        id: AnalysisEvidenceID = PrivacyFinding.makeID(),
        category: PrivacyCategory,
        confidence: PrivacyConfidence,
        confidenceScore: Double? = nil,
        state: PrivacyFindingState = .pending,
        fingerprint: PrivacyFingerprint,
        tracks: [PrivacyGeometryTrack],
        detectorCoverage: PrivacyDetectorCoverage? = nil
    ) {
        self.id = id
        self.category = category
        self.confidence = confidence
        self.confidenceScore = (confidenceScore ?? confidence.score).isFinite
            ? min(max(confidenceScore ?? confidence.score, 0), 1)
            : confidence.score
        self.state = state
        self.fingerprint = fingerprint
        self.tracks = tracks.map(\.normalized)
        self.detectorCoverage = detectorCoverage
    }

    public init(
        id: AnalysisEvidenceID = PrivacyFinding.makeID(),
        category: PrivacyCategory,
        confidence: PrivacyConfidence,
        confidenceScore: Double? = nil,
        state: PrivacyFindingState = .pending,
        fingerprint: PrivacyFingerprint,
        observations: [PrivacyGeometryObservation],
        detectorCoverage: PrivacyDetectorCoverage? = nil
    ) {
        self.init(
            id: id,
            category: category,
            confidence: confidence,
            confidenceScore: confidenceScore,
            state: state,
            fingerprint: fingerprint,
            tracks: [PrivacyGeometryTrack(observations: observations)],
            detectorCoverage: detectorCoverage
        )
    }

    public var observations: [PrivacyGeometryObservation] {
        tracks.flatMap(\.observations)
    }
    public var start: TimeInterval { tracks.map(\.start).min() ?? 0 }
    public var end: TimeInterval { tracks.map(\.end).max() ?? start }
    public var isPossible: Bool { state == .pending || state == .stale }
    public var isAccepted: Bool { state.isAcceptedMask }
    public var reviewState: PrivacyFindingState {
        get { state }
        set { state = newValue }
    }

    public var normalized: Self {
        Self(
            id: id,
            category: category,
            confidence: confidence,
            confidenceScore: confidenceScore,
            state: state,
            fingerprint: fingerprint,
            tracks: tracks,
            detectorCoverage: detectorCoverage
        )
    }

    public func withState(_ newState: PrivacyFindingState) -> Self {
        Self(
            id: id,
            category: category,
            confidence: confidence,
            confidenceScore: confidenceScore,
            state: newState,
            fingerprint: fingerprint,
            tracks: tracks.map { PrivacyGeometryTrack(id: $0.id, observations: $0.observations, state: newState) },
            detectorCoverage: detectorCoverage
        )
    }

    public func accepted() -> Self { withState(.accepted) }
    public func rejected() -> Self { withState(.rejected) }
    public func stale() -> Self { withState(.stale) }

    /// Converts an accepted/verified finding into ordinary source-timed
    /// project redactions. A single-frame result still gets one video-frame of
    /// coverage, so short-lived secrets are not dropped.
    public func redactionRegions(
        mode: RedactionMode = .blur,
        strength: Double = 0.85,
        frameDuration: TimeInterval = 1.0 / 30.0
    ) -> [RedactionRegion] {
        guard isAccepted else { return [] }
        let minimumDuration = frameDuration.isFinite && frameDuration > 0
            ? frameDuration
            : 1.0 / 30.0
        return observations.enumerated().map { index, observation in
            let nextT = observations.dropFirst(index + 1).first?.t
            let end = max(
                observation.endTime,
                nextT ?? observation.t + minimumDuration,
                observation.t + minimumDuration
            )
            return RedactionRegion(
                start: observation.t,
                end: end,
                rect: observation.rect,
                mode: mode,
                strength: strength
            ).normalized
        }
    }

    public var redactions: [RedactionRegion] { redactionRegions() }

    public static func redactionRegions(
        for findings: [PrivacyFinding],
        mode: RedactionMode = .blur,
        strength: Double = 0.85,
        frameDuration: TimeInterval = 1.0 / 30.0
    ) -> [RedactionRegion] {
        findings.flatMap {
            $0.redactionRegions(mode: mode, strength: strength, frameDuration: frameDuration)
        }
    }

    public static func makeID() -> AnalysisEvidenceID {
        try! AnalysisEvidenceID("privacy-finding-" + UUID().uuidString.lowercased())
    }
}

// MARK: - Rendered-output verification and reports

/// OCR observations from a rendered output pass.  This is transient input and
/// is not suitable for a sidecar because it contains `PrivacyTextObservation`
/// values with plaintext.
public struct PrivacyRenderedOutputVerificationInput: Codable, Sendable, Hashable {
    public var observations: [PrivacyTextObservation]
    public var sampledTimestamps: [TimeInterval]
    public var frameCount: Int

    public init(
        observations: [PrivacyTextObservation] = [],
        sampledTimestamps: [TimeInterval] = [],
        frameCount: Int = 0
    ) {
        self.observations = observations
        self.sampledTimestamps = sampledTimestamps
        self.frameCount = max(frameCount, 0)
    }

    public var scannedFrameCount: Int { frameCount }
}

public typealias RenderedOutputVerificationInput = PrivacyRenderedOutputVerificationInput

public struct PrivacyVerificationSummary: Codable, Sendable, Hashable {
    public var scanned: Bool
    public var possibleFindingCount: Int
    public var acceptedMaskCount: Int
    public var verifiedMaskCount: Int
    public var outputFindingCount: Int
    /// Output-timeline positions inspected by the local rendered-output pass.
    public var sampledTimestamps: [TimeInterval]
    /// Output-timeline positions where a detector still found sensitive content.
    public var outputFindingTimestamps: [TimeInterval]
    public var detectorCoverage: PrivacyDetectorCoverage

    public init(
        scanned: Bool = false,
        possibleFindingCount: Int = 0,
        acceptedMaskCount: Int = 0,
        verifiedMaskCount: Int = 0,
        outputFindingCount: Int = 0,
        sampledTimestamps: [TimeInterval] = [],
        outputFindingTimestamps: [TimeInterval] = [],
        detectorCoverage: PrivacyDetectorCoverage = PrivacyDetectorCoverage()
    ) {
        self.scanned = scanned
        self.possibleFindingCount = max(0, possibleFindingCount)
        self.acceptedMaskCount = max(0, acceptedMaskCount)
        self.verifiedMaskCount = max(0, verifiedMaskCount)
        self.outputFindingCount = max(0, outputFindingCount)
        self.sampledTimestamps = Self.normalizedTimes(sampledTimestamps)
        self.outputFindingTimestamps = Self.normalizedTimes(outputFindingTimestamps)
        self.detectorCoverage = detectorCoverage
    }

    private static func normalizedTimes(_ values: [TimeInterval]) -> [TimeInterval] {
        Array(Set(values.filter(\.isFinite).map { max($0, 0) })).sorted()
    }
}

/// Local, redaction-safe review output. It reports what was observed and what
/// was accepted/verified, with an explicit best-effort disclaimer. It never
/// claims that all private material was detected or that the source is safe.
public struct PrivacyReport: Codable, Sendable, Hashable {
    public static let schemaVersion = 1
    public static let bestEffortDisclaimer =
        "Privacy detection is local and best effort; this report does not claim perfect detection or sanitize the source bundle."

    public var schema: Int
    public var createdAt: Date
    public var possibleFindingCount: Int
    public var acceptedMaskCount: Int
    public var rejectedFindingCount: Int
    public var staleFindingCount: Int
    public var verifiedMaskCount: Int
    public var detectorCoverage: PrivacyDetectorCoverage
    public var verification: PrivacyVerificationSummary
    public var warnings: [String]
    public var disclaimer: String

    public init(
        createdAt: Date = Date(),
        possibleFindingCount: Int,
        acceptedMaskCount: Int,
        rejectedFindingCount: Int = 0,
        staleFindingCount: Int = 0,
        verifiedMaskCount: Int = 0,
        detectorCoverage: PrivacyDetectorCoverage,
        verification: PrivacyVerificationSummary = PrivacyVerificationSummary(),
        warnings: [String] = []
    ) {
        self.schema = Self.schemaVersion
        self.createdAt = createdAt
        self.possibleFindingCount = max(0, possibleFindingCount)
        self.acceptedMaskCount = max(0, acceptedMaskCount)
        self.rejectedFindingCount = max(0, rejectedFindingCount)
        self.staleFindingCount = max(0, staleFindingCount)
        self.verifiedMaskCount = max(0, verifiedMaskCount)
        self.detectorCoverage = detectorCoverage
        self.verification = verification
        self.warnings = warnings
        self.disclaimer = Self.bestEffortDisclaimer
    }

    public var possibleFindings: Int { possibleFindingCount }
    public var possibleCount: Int { possibleFindingCount }
    public var verifiedAcceptedMaskCount: Int { verifiedMaskCount }
    public var verifiedCount: Int { verifiedMaskCount }
    public var isSourceSanitized: Bool { false }
    public var claimsPerfectDetection: Bool { false }
}

public typealias LocalPrivacyReport = PrivacyReport
public typealias PrivacyAnalysisReport = PrivacyReport

// MARK: - Geometry helpers

enum PrivacyGeometry {
    static func normalized(_ raw: Rect2D) -> Rect2D {
        let x = finite(raw.x) ? min(max(raw.x, 0), 1) : 0
        let y = finite(raw.y) ? min(max(raw.y, 0), 1) : 0
        let width = finite(raw.width) ? min(max(raw.width, 0), 1 - x) : 0
        let height = finite(raw.height) ? min(max(raw.height, 0), 1 - y) : 0
        return Rect2D(x: x, y: y, width: width, height: height)
    }

    static func apply(
        _ raw: Rect2D,
        scale: Double,
        offset: Point2D,
        scrollOffset: Point2D
    ) -> Rect2D {
        let safeScale = finite(scale) ? min(max(scale, 0.25), 8) : 1
        return normalized(Rect2D(
            x: raw.x * safeScale + offset.x - scrollOffset.x,
            y: raw.y * safeScale + offset.y - scrollOffset.y,
            width: raw.width * safeScale,
            height: raw.height * safeScale
        ))
    }

    static func finite(_ value: Double) -> Bool { value.isFinite }
}
