import Foundation

/// Privacy-filtered semantic evidence captured alongside cursor telemetry.
/// The stream deliberately contains UI control metadata, never element values
/// or ordinary typed characters.
public enum SemanticEventKind: String, Codable, CaseIterable, Sendable, Hashable {
    case activate
    case focus
    case shortcut
    case storyBeat = "story-beat"
    case genericClick = "generic-click"
}

public enum SemanticEventSource: String, Codable, CaseIterable, Sendable, Hashable {
    case accessibility
    case vision
    case telemetry
    case userMarker = "user-marker"
}

/// A reason a semantic event contains less information than requested.  These
/// values make capture degradation visible without storing the unavailable or
/// privacy-filtered content itself.
public enum SemanticDegradationReason: String, Codable, CaseIterable, Sendable, Hashable {
    case accessibilityUnavailable = "accessibility-unavailable"
    case elementUnavailable = "element-unavailable"
    case secureField = "secure-field"
    case labelFiltered = "label-filtered"
    case visionUnavailable = "vision-unavailable"
}

public struct SemanticEventSample: TelemetryRecord, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var duration: TimeInterval
    public var kind: SemanticEventKind
    public var applicationBundleID: String?
    public var role: String?
    public var label: String?
    /// Normalized top-left coordinates in the captured target (0...1).
    public var bounds: Rect2D?
    public var confidence: Double
    public var source: SemanticEventSource
    public var degradationReason: SemanticDegradationReason?
    public var sequence: UInt64?

    public init(
        id: AnalysisEvidenceID = SemanticEventSample.makeID(),
        t: TimeInterval,
        duration: TimeInterval = 0,
        kind: SemanticEventKind,
        applicationBundleID: String? = nil,
        role: String? = nil,
        label: String? = nil,
        bounds: Rect2D? = nil,
        confidence: Double = 1,
        source: SemanticEventSource,
        degradationReason: SemanticDegradationReason? = nil,
        sequence: UInt64? = nil
    ) {
        self.id = id
        self.t = t
        self.duration = duration
        self.kind = kind
        self.applicationBundleID = applicationBundleID
        self.role = role
        self.label = label
        self.bounds = bounds
        self.confidence = confidence
        self.source = source
        self.degradationReason = degradationReason
        self.sequence = sequence
    }

    public var normalized: SemanticEventSample {
        var value = self
        value.t = value.t.isFinite ? max(value.t, 0) : 0
        value.duration = value.duration.isFinite ? max(value.duration, 0) : 0
        value.applicationBundleID = SemanticPrivacyFilter.sanitizeBundleID(value.applicationBundleID)
        value.role = SemanticPrivacyFilter.sanitizeRole(value.role)
        value.label = SemanticPrivacyFilter.sanitizeCapturedLabel(value.label, role: value.role)
        value.bounds = value.bounds.map(SemanticPrivacyFilter.normalizedBounds)
        value.confidence = value.confidence.isFinite ? min(max(value.confidence, 0), 1) : 0
        return value
    }

    public static func makeID() -> AnalysisEvidenceID {
        // The generated value is construction-safe by definition.
        try! AnalysisEvidenceID("semantic-" + UUID().uuidString.lowercased())
    }
}

/// The documented persistence boundary for semantic labels.  Callers must not
/// query AXValue or selected text at all; this filter is a second line of
/// defense for control titles, descriptions, and Vision fallback labels.
public enum SemanticPrivacyFilter: Sendable {
    public static let maximumLabelLength = 80

    private static let labelSafeRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXDisclosureTriangle", "AXLink", "AXMenuItem",
        "AXPopUpButton", "AXRadioButton", "AXSegmentedControl", "AXTabGroup",
        "AXToolbar", "button", "checkbox", "link", "menu-item", "radio-button",
        "tab", "toolbar-item",
    ]

    private static let secureRoles: Set<String> = [
        "AXSecureTextField", "secure-text-field", "password", "password-field",
    ]

    public static func sanitizeBundleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 255,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              })
        else { return nil }
        return value
    }

    public static func sanitizeRole(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = collapsedWhitespace(raw)
        guard !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar.value == 45 || scalar.value == 95
              })
        else { return nil }
        return value
    }

    public static func isSecureRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return secureRoles.contains(role)
    }

    public static func sanitizeCapturedLabel(
        _ raw: String?,
        role: String?,
        isSecure: Bool = false
    ) -> String? {
        guard !isSecure, !isSecureRole(role), let role, labelSafeRoles.contains(role),
              let raw
        else { return nil }
        let value = collapsedWhitespace(raw)
        guard !value.isEmpty, value.count <= maximumLabelLength,
              !containsPrivatePattern(value),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    /// Window titles are higher risk than authored control labels.  Persist
    /// only short, generic-looking titles and reject path-like values.
    public static func sanitizeWindowTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = collapsedWhitespace(raw)
        guard !value.isEmpty, value.count <= 48,
              !containsPrivatePattern(value),
              !value.contains("/"), !value.contains("\\")
        else { return nil }
        return value
    }

    public static func normalizedBounds(_ raw: Rect2D) -> Rect2D {
        let x = raw.x.isFinite ? min(max(raw.x, 0), 1) : 0
        let y = raw.y.isFinite ? min(max(raw.y, 0), 1) : 0
        let width = raw.width.isFinite ? min(max(raw.width, 0), 1 - x) : 0
        let height = raw.height.isFinite ? min(max(raw.height, 0), 1 - y) : 0
        return Rect2D(x: x, y: y, width: width, height: height)
    }

    public static var persistsOrdinaryTypedText: Bool { false }

    private static func collapsedWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func containsPrivatePattern(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("@") || lower.contains("://") || lower.contains("www.")
            || lower.contains("bearer ") || lower.contains("api_key")
            || lower.contains("apikey") || lower.contains("token=")
            || lower.hasPrefix("sk-")
        {
            return true
        }
        var longestRun = 0
        var currentRun = 0
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun >= 24
    }
}

public enum ActionCandidateKind: String, Codable, CaseIterable, Sendable, Hashable {
    case click
    case shortcut
    case textInput = "text-input"
    case navigation
    case marker
    case visual
}

public enum ActionEvidenceSource: String, Codable, CaseIterable, Sendable, Hashable {
    case semantic
    case click
    case cursor
    case shortcut
    case typing
    case targetGeometry = "target-geometry"
    case vision
    case transcript
}

/// One rebuildable ActionMap row written to `analysis/actions.jsonl`.
public struct ActionCandidate: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var start: TimeInterval
    public var end: TimeInterval
    public var kind: ActionCandidateKind
    public var label: String
    public var applicationBundleID: String?
    public var role: String?
    public var bounds: Rect2D?
    public var confidence: Double
    public var evidenceSources: [ActionEvidenceSource]
    public var evidenceIDs: [AnalysisEvidenceID]
    public var supportingSignals: [String]

    public init(
        id: AnalysisEvidenceID,
        start: TimeInterval,
        end: TimeInterval,
        kind: ActionCandidateKind,
        label: String,
        applicationBundleID: String? = nil,
        role: String? = nil,
        bounds: Rect2D? = nil,
        confidence: Double,
        evidenceSources: [ActionEvidenceSource],
        evidenceIDs: [AnalysisEvidenceID],
        supportingSignals: [String] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.label = label
        self.applicationBundleID = applicationBundleID
        self.role = role
        self.bounds = bounds
        self.confidence = confidence
        self.evidenceSources = evidenceSources
        self.evidenceIDs = evidenceIDs
        self.supportingSignals = supportingSignals
    }

    public var normalized: ActionCandidate {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start) : value.start
        let title = value.label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.label = String((title.isEmpty ? "Action" : title).prefix(120))
        value.applicationBundleID = SemanticPrivacyFilter.sanitizeBundleID(value.applicationBundleID)
        value.role = SemanticPrivacyFilter.sanitizeRole(value.role)
        value.bounds = value.bounds.map(SemanticPrivacyFilter.normalizedBounds)
        value.confidence = value.confidence.isFinite ? min(max(value.confidence, 0), 1) : 0
        value.evidenceSources = stableUnique(value.evidenceSources)
        value.evidenceIDs = stableUnique(value.evidenceIDs)
        value.supportingSignals = stableUnique(value.supportingSignals.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        }.filter { !$0.isEmpty })
        return value
    }
}

/// Privacy-filtered OCR evidence. `label == nil` records that Vision observed a
/// candidate but the persistence policy rejected its plaintext.
public struct ActionOCREvidence: Codable, Sendable, Hashable, Identifiable {
    public var id: AnalysisEvidenceID
    public var t: TimeInterval
    public var bounds: Rect2D
    public var label: String?
    public var confidence: Double
    public var degradationReason: SemanticDegradationReason?

    public init(
        id: AnalysisEvidenceID,
        t: TimeInterval,
        bounds: Rect2D,
        label: String?,
        confidence: Double,
        degradationReason: SemanticDegradationReason? = nil
    ) {
        self.id = id
        self.t = t
        self.bounds = bounds
        self.label = label
        self.confidence = confidence
        self.degradationReason = degradationReason
    }
}

public enum StoryBeatKind: String, Codable, CaseIterable, Sendable, Hashable {
    case action
    case chapter
    case step
    case marker
}

public struct StoryBeatProvenance: Codable, Sendable, Hashable {
    public var analyzerVersion: String?
    public var confidence: Double?
    public var source: String

    public init(analyzerVersion: String? = nil, confidence: Double? = nil, source: String) {
        self.analyzerVersion = analyzerVersion
        self.confidence = confidence
        self.source = source
    }

    public var normalized: StoryBeatProvenance {
        var value = self
        value.analyzerVersion = value.analyzerVersion.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        }
        if let confidence = value.confidence {
            value.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : nil
        }
        value.source = String(value.source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        return value
    }
}

/// Compact user-authored ActionMap state introduced by project format v8.
/// Evidence payload stays rebuildable in `analysis/`; this value stores stable
/// references and the corrections needed for portable editing.
public struct StoryBeat: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var kind: StoryBeatKind
    public var title: String
    public var applicationBundleID: String?
    public var evidenceIDs: [AnalysisEvidenceID]
    public var isLocked: Bool
    public var isSuppressed: Bool
    public var provenance: StoryBeatProvenance?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        kind: StoryBeatKind = .action,
        title: String,
        applicationBundleID: String? = nil,
        evidenceIDs: [AnalysisEvidenceID] = [],
        isLocked: Bool = false,
        isSuppressed: Bool = false,
        provenance: StoryBeatProvenance? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.title = title
        self.applicationBundleID = applicationBundleID
        self.evidenceIDs = evidenceIDs
        self.isLocked = isLocked
        self.isSuppressed = isSuppressed
        self.provenance = provenance
    }

    public var normalized: StoryBeat {
        var value = self
        value.start = value.start.isFinite ? max(value.start, 0) : 0
        value.end = value.end.isFinite ? max(value.end, value.start) : value.start
        let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.title = String((title.isEmpty ? "Untitled action" : title).prefix(120))
        value.applicationBundleID = SemanticPrivacyFilter.sanitizeBundleID(value.applicationBundleID)
        value.evidenceIDs = stableUnique(value.evidenceIDs)
        value.provenance = value.provenance?.normalized
        return value
    }
}

private func stableUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
    var seen = Set<Value>()
    return values.filter { seen.insert($0).inserted }
}
