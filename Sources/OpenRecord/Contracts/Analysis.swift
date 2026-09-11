import Foundation

/// The rebuildable analysis streams stored below a project's `analysis/`
/// directory.  `manifest.json` is deliberately not a stream kind: it is the
/// cache's version and provenance envelope.
public enum AnalysisSidecarKind: String, Codable, CaseIterable, Sendable, Hashable {
    case actions
    case ocr
    case privacy
    case suggestions

    public var fileName: String {
        switch self {
        case .actions: "actions.jsonl"
        case .ocr: "ocr.jsonl"
        case .privacy: "privacy.jsonl"
        case .suggestions: "suggestions.jsonl"
        }
    }

    /// Whether this sidecar is newline-delimited JSON rather than one JSON
    /// document.  The distinction is useful to read-only cache inspection.
    public var isJSONL: Bool {
        true
    }
}

/// Cache computation state.  An in-progress or failed analysis is still
/// useful as a diagnostic cache, but is never authoritative project state.
public enum AnalysisCompletionState: String, Codable, CaseIterable, Sendable, Hashable {
    case inProgress
    case complete
    case partial
    case failed
}

/// Errors specific to constructing the small, value-based analysis contract.
public enum AnalysisContractError: Error, LocalizedError, Sendable, Equatable {
    case invalidEvidenceID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEvidenceID(let message): message
        }
    }
}

/// Opaque stable identifier for a piece of captured evidence.
///
/// The value is intentionally not interpreted by the project model.  It is
/// only constrained to a portable, single path-component alphabet so it can
/// safely be used as a reference in JSON and across machines.
public struct AnalysisEvidenceID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw AnalysisContractError.invalidEvidenceID(
                "Analysis evidence ID must be 1–256 characters of letters, numbers, '.', '_', ':', or '-'."
            )
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256,
              value.first != ".", value.first != "-"
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 58, 95:
                true
            default:
                false
            }
        }
    }
}

/// SHA-256 (or a future explicitly named digest algorithm) for one immutable
/// capture file.  Paths are relative to the containing `.openrecord` bundle.
public struct AnalysisSourceFingerprint: Codable, Sendable, Hashable {
    public let bundleRelativePath: String
    public let byteCount: Int64
    public let algorithm: String
    public let digest: String

    public init(
        bundleRelativePath: String,
        byteCount: Int64,
        algorithm: String = "SHA-256",
        digest: String
    ) {
        self.bundleRelativePath = bundleRelativePath
        self.byteCount = byteCount
        self.algorithm = algorithm
        self.digest = digest
    }

    /// Compatibility alias used by clients that refer to the path simply as
    /// `path`; the encoded contract remains `bundleRelativePath`.
    public var path: String { bundleRelativePath }

    public var isWellFormed: Bool {
        byteCount >= 0
            && !algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !digest.isEmpty
            && digest.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...70, 97...102:
                    true
                default:
                    false
                }
            }
    }
}

/// A compact summary for one analysis stream.  Payload data is never part of
/// this value; it is safe to expose from project inspection commands.
public struct AnalysisSidecarSummary: Codable, Sendable, Hashable {
    public let recordCount: Int
    public let byteCount: Int64?
    public let chunkCount: Int?
    public let indexPath: String?

    public init(
        recordCount: Int,
        byteCount: Int64? = nil,
        chunkCount: Int? = nil,
        indexPath: String? = nil
    ) {
        self.recordCount = max(0, recordCount)
        self.byteCount = byteCount
        self.chunkCount = chunkCount
        self.indexPath = indexPath
    }

    public var count: Int { recordCount }
}

/// Versioned envelope for all analysis produced from a project's immutable
/// capture evidence.
public struct AnalysisManifest: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1
    public static let currentVersion = currentSchemaVersion

    public let schemaVersion: Int
    public let analyzerVersion: String
    public let appVersion: String
    public let fingerprints: [AnalysisSourceFingerprint]
    public let locale: String?
    public let modelRevision: String?
    public let apiRevision: String?
    public let completionState: AnalysisCompletionState
    public let warnings: [String]
    public let sidecars: [AnalysisSidecarKind: AnalysisSidecarSummary]

    public init(
        schemaVersion: Int = AnalysisManifest.currentSchemaVersion,
        analyzerVersion: String,
        appVersion: String,
        fingerprints: [AnalysisSourceFingerprint] = [],
        locale: String? = nil,
        modelRevision: String? = nil,
        apiRevision: String? = nil,
        completionState: AnalysisCompletionState,
        warnings: [String] = [],
        sidecars: [AnalysisSidecarKind: AnalysisSidecarSummary] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.analyzerVersion = analyzerVersion
        self.appVersion = appVersion
        self.fingerprints = fingerprints
        self.locale = locale
        self.modelRevision = modelRevision
        self.apiRevision = apiRevision
        self.completionState = completionState
        self.warnings = warnings
        self.sidecars = sidecars
    }

    /// Label-compatible initializer matching the terminology used by the
    /// architecture plan.  Both spellings encode the same v1 manifest.
    public init(
        schemaVersion: Int = AnalysisManifest.currentSchemaVersion,
        analyzerVersion: String,
        appVersion: String,
        sourceFingerprints: [AnalysisSourceFingerprint],
        locale: String? = nil,
        modelRevision: String? = nil,
        apiRevision: String? = nil,
        completionState: AnalysisCompletionState,
        recoverableWarnings: [String] = [],
        sidecarSummaries: [AnalysisSidecarKind: AnalysisSidecarSummary] = [:]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            analyzerVersion: analyzerVersion,
            appVersion: appVersion,
            fingerprints: sourceFingerprints,
            locale: locale,
            modelRevision: modelRevision,
            apiRevision: apiRevision,
            completionState: completionState,
            warnings: recoverableWarnings,
            sidecars: sidecarSummaries
        )
    }

    /// Compatibility spelling for clients that call the field simply
    /// `completion` in their analyzer configuration.
    public init(
        schemaVersion: Int = AnalysisManifest.currentSchemaVersion,
        analyzerVersion: String,
        appVersion: String,
        fingerprints: [AnalysisSourceFingerprint] = [],
        locale: String? = nil,
        modelRevision: String? = nil,
        apiRevision: String? = nil,
        completion: AnalysisCompletionState,
        warnings: [String] = [],
        sidecarSummaries: [AnalysisSidecarKind: AnalysisSidecarSummary] = [:]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            analyzerVersion: analyzerVersion,
            appVersion: appVersion,
            fingerprints: fingerprints,
            locale: locale,
            modelRevision: modelRevision,
            apiRevision: apiRevision,
            completionState: completion,
            warnings: warnings,
            sidecars: sidecarSummaries
        )
    }

    /// More descriptive aliases retained as source-compatible conveniences.
    public var sourceFingerprints: [AnalysisSourceFingerprint] { fingerprints }
    public var sidecarSummaries: [AnalysisSidecarKind: AnalysisSidecarSummary] { sidecars }
    public var recoverableWarnings: [String] { warnings }
    public var state: AnalysisCompletionState { completionState }
    public var completion: AnalysisCompletionState { completionState }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case analyzerVersion
        case appVersion
        case fingerprints
        case sourceFingerprints
        case locale
        case modelRevision
        case apiRevision
        case completionState
        case warnings
        case sidecars
        case sidecarSummaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        analyzerVersion = try container.decode(String.self, forKey: .analyzerVersion)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        fingerprints = try container.decodeIfPresent([AnalysisSourceFingerprint].self, forKey: .fingerprints)
            ?? container.decodeIfPresent([AnalysisSourceFingerprint].self, forKey: .sourceFingerprints)
            ?? []
        locale = try container.decodeIfPresent(String.self, forKey: .locale)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        apiRevision = try container.decodeIfPresent(String.self, forKey: .apiRevision)
        completionState = try container.decode(AnalysisCompletionState.self, forKey: .completionState)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        sidecars = try container.decodeIfPresent(
            [AnalysisSidecarKind: AnalysisSidecarSummary].self,
            forKey: .sidecars
        ) ?? container.decodeIfPresent(
            [AnalysisSidecarKind: AnalysisSidecarSummary].self,
            forKey: .sidecarSummaries
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(analyzerVersion, forKey: .analyzerVersion)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(fingerprints, forKey: .fingerprints)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(modelRevision, forKey: .modelRevision)
        try container.encodeIfPresent(apiRevision, forKey: .apiRevision)
        try container.encode(completionState, forKey: .completionState)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(sidecars, forKey: .sidecars)
    }
}

/// Read-only analysis cache status reported by project inspection.
public enum AnalysisAvailability: String, Codable, CaseIterable, Sendable, Hashable {
    case missing
    case fresh
    case stale
    case partial
    case malformed
    case future
}

public typealias AnalysisStatus = AnalysisAvailability
public typealias AnalysisFreshness = AnalysisAvailability
public typealias AnalysisCacheStatus = AnalysisAvailability
public typealias AnalysisAvailabilityStatus = AnalysisAvailability
public typealias AnalysisFreshnessStatus = AnalysisAvailability

/// Privacy-safe summary used by automation and CLI output.  It contains no
/// recognized text, action labels, OCR, or suggestion payload.
public struct AnalysisInspectionSummary: Codable, Sendable, Equatable, Hashable {
    public let status: AnalysisAvailability
    public let recordCounts: [AnalysisSidecarKind: Int]
    public let warnings: [String]
    public let schemaVersion: Int?

    public init(
        status: AnalysisAvailability,
        recordCounts: [AnalysisSidecarKind: Int] = [:],
        warnings: [String] = [],
        schemaVersion: Int? = nil
    ) {
        self.status = status
        self.recordCounts = recordCounts
        self.warnings = warnings
        self.schemaVersion = schemaVersion
    }

    public var availability: AnalysisAvailability { status }
    public var freshness: AnalysisAvailability { status }
    public var analysisStatus: AnalysisAvailability { status }
    public var sidecarRecordCounts: [AnalysisSidecarKind: Int] { recordCounts }
}

public typealias AnalysisInspection = AnalysisInspectionSummary
