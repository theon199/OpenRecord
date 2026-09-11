import Foundation

/// Local deterministic analysis for privacy candidates.  All values that may
/// contain plaintext are accepted only as transient input; the returned
/// `PrivacyFinding` values contain categories, fingerprints, and geometry.
public struct PrivacyFirewallAnalyzer: Sendable {
    public static let analyzerVersion = "privacy-firewall-1"

    public var textObservations: [PrivacyTextObservation]
    public var semanticSignals: [PrivacySemanticSignal]
    public var windowSignals: [PrivacyWindowSignal]
    public var notificationSignals: [PrivacyNotificationSignal]
    public var accountSignals: [PrivacyAccountSignal]
    public var sensitiveTerms: [String]
    public var configuration: PrivacyAnalyzerConfiguration

    public init(
        textObservations: [PrivacyTextObservation] = [],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notificationSignals: [PrivacyNotificationSignal] = [],
        accountSignals: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        configuration: PrivacyAnalyzerConfiguration = .default
    ) {
        self.textObservations = textObservations
        self.semanticSignals = semanticSignals
        self.windowSignals = windowSignals
        self.notificationSignals = notificationSignals
        self.accountSignals = accountSignals
        self.sensitiveTerms = Self.normalizedTerms(sensitiveTerms)
        self.configuration = configuration
    }

    /// Labels retained by callers for source compatibility with early v4.2
    /// experiments. They all describe the same deterministic analyzer.
    public init(
        ocrObservations: [PrivacyTextObservation] = [],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notifications: [PrivacyNotificationSignal] = [],
        accounts: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = [],
        configuration: PrivacyAnalyzerConfiguration = .default
    ) {
        self.init(
            textObservations: ocrObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notifications,
            accountSignals: accounts,
            sensitiveTerms: sensitiveTerms,
            configuration: configuration
        )
    }

    /// Runs all configured deterministic detectors and returns stable ordering
    /// by source time, category, and fingerprint digest.
    public func analyze() -> [PrivacyFinding] {
        var hits: [Hit] = []
        let detectorCategories: [PrivacyCategory] = [
            .apiKey, .commonToken, .email, .internalURL, .notification,
            .accountIdentifier, .sensitiveTerm,
        ] + (configuration.detectFaces ? [.face] : [])
            + (configuration.detectNames ? [.name] : [])

        for observation in textObservations {
            let value = observation.text
            guard !value.isEmpty else { continue }
            let rect = resolvedRect(
                observation.rect,
                coordinateSpace: observation.coordinateSpace,
                t: observation.t,
                windowID: observation.windowID
            )
            let base = TextContext(
                id: observation.id,
                t: observation.t,
                duration: observation.duration,
                rect: rect,
                confidence: observation.confidence,
                source: observation.source,
                windowID: observation.windowID
            )

            appendMatches(
                detector: .apiKey,
                pattern: Self.apiKeyPattern,
                in: value,
                context: base,
                to: &hits
            )
            appendMatches(
                detector: .commonToken,
                pattern: Self.commonTokenPattern,
                in: value,
                context: base,
                to: &hits,
                filter: Self.isCommonToken
            )
            appendMatches(
                detector: .email,
                pattern: Self.emailPattern,
                in: value,
                context: base,
                to: &hits
            )
            appendMatches(
                detector: .internalURL,
                pattern: Self.urlPattern,
                in: value,
                context: base,
                to: &hits,
                filter: Self.isInternalURL
            )
            for term in sensitiveTerms {
                appendMatches(
                    detector: .sensitiveTerm,
                    pattern: NSRegularExpression.escapedPattern(for: term),
                    in: value,
                    context: base,
                    to: &hits,
                    options: [.caseInsensitive]
                )
            }
        }

        for signal in semanticSignals {
            let rect = signal.rect.map {
                resolvedRect($0, coordinateSpace: .normalizedCanvas, t: signal.t, windowID: signal.windowID)
            }
            let base = TextContext(
                id: signal.id,
                t: signal.t,
                duration: signal.duration,
                rect: rect ?? Rect2D.unit,
                confidence: signal.confidence,
                source: .semantic,
                windowID: signal.windowID
            )
            switch signal.kind {
            case .text, .sensitiveText:
                if let value = signal.value, !value.isEmpty {
                    appendTextDetectors(value, context: base, to: &hits)
                    if signal.kind == .sensitiveText {
                        hits.append(makeHit(category: .sensitiveTerm, value: value, context: base))
                    }
                }
            case .accountIdentifier:
                hits.append(makeHit(
                    category: .accountIdentifier,
                    value: signal.value ?? signal.id.rawValue,
                    context: base
                ))
            case .notification:
                hits.append(makeHit(
                    category: .notification,
                    value: signal.value ?? signal.id.rawValue,
                    context: base
                ))
            case .face:
                if configuration.detectFaces {
                    hits.append(makeHit(category: .face, value: "face|" + signal.id.rawValue, context: base))
                }
            case .name:
                if configuration.detectNames {
                    hits.append(makeHit(
                        category: .name,
                        value: signal.value ?? ("name|" + signal.id.rawValue),
                        context: base
                    ))
                }
            }
        }

        for signal in notificationSignals {
            let context = TextContext(
                id: signal.id,
                t: signal.t,
                duration: signal.duration,
                rect: resolvedRect(signal.rect, coordinateSpace: .normalizedCanvas, t: signal.t, windowID: signal.windowID),
                confidence: signal.confidence,
                source: .notification,
                windowID: signal.windowID
            )
            hits.append(makeHit(
                category: .notification,
                value: signal.title ?? signal.id.rawValue,
                context: context
            ))
        }

        for signal in accountSignals {
            let context = TextContext(
                id: signal.id,
                t: signal.t,
                duration: signal.duration,
                rect: resolvedRect(signal.rect, coordinateSpace: .normalizedCanvas, t: signal.t, windowID: signal.windowID),
                confidence: signal.confidence,
                source: .accountSignal,
                windowID: signal.windowID
            )
            hits.append(makeHit(
                category: .accountIdentifier,
                value: signal.identifier ?? signal.id.rawValue,
                context: context
            ))
        }

        return makeFindings(hits: deduplicated(hits), detectorsRun: detectorCategories)
    }

    /// One-shot API useful for a rendered-output pass or an adapter that does
    /// not want to retain detector inputs in an analyzer value.
    public func analyze(
        textObservations: [PrivacyTextObservation],
        semanticSignals: [PrivacySemanticSignal] = [],
        windowSignals: [PrivacyWindowSignal] = [],
        notificationSignals: [PrivacyNotificationSignal] = [],
        accountSignals: [PrivacyAccountSignal] = [],
        sensitiveTerms: [String] = []
    ) -> [PrivacyFinding] {
        Self(
            textObservations: textObservations,
            semanticSignals: semanticSignals,
            windowSignals: windowSignals,
            notificationSignals: notificationSignals,
            accountSignals: accountSignals,
            sensitiveTerms: sensitiveTerms,
            configuration: configuration
        ).analyze()
    }

    public func findings() -> [PrivacyFinding] { analyze() }

    /// Applies a review decision without mutating the original analysis.
    public func accepting(_ findings: [PrivacyFinding]) -> [PrivacyFinding] {
        findings.map { $0.accepted() }
    }

    public func rejecting(_ findings: [PrivacyFinding]) -> [PrivacyFinding] {
        findings.map { $0.rejected() }
    }

    public func makeReport(
        findings: [PrivacyFinding],
        renderedOutput: PrivacyRenderedOutputVerificationInput? = nil,
        warnings: [String] = []
    ) -> PrivacyReport {
        let possible = findings.filter { $0.state == .pending }.count
        let accepted = findings.filter(\.isAccepted).count
        let rejected = findings.filter { $0.state == .rejected }.count
        let stale = findings.filter { $0.state == .stale }.count
        let sourceCoverage = coverage(for: findings, renderedOutput: false)

        var verification = PrivacyVerificationSummary(
            scanned: false,
            possibleFindingCount: possible,
            acceptedMaskCount: accepted,
            detectorCoverage: sourceCoverage
        )
        var reportWarnings = warnings
        if let renderedOutput {
            let verifier = PrivacyFirewallAnalyzer(
                textObservations: renderedOutput.observations,
                sensitiveTerms: sensitiveTerms,
                configuration: configuration
            )
            let outputFindings = verifier.analyze()
            let unresolvedAccepted = findings.filter { finding in
                finding.isAccepted && outputFindings.contains { output in
                    output.category == finding.category
                        && output.fingerprint == finding.fingerprint
                        && Self.rangesOverlap(finding.start, finding.end, output.start, output.end)
                }
            }.count
            let verified = max(accepted - unresolvedAccepted, 0)
            let outputCoverage = verifier.coverage(for: outputFindings, renderedOutput: true)
            verification = PrivacyVerificationSummary(
                scanned: true,
                possibleFindingCount: possible,
                acceptedMaskCount: accepted,
                verifiedMaskCount: min(accepted, verified),
                outputFindingCount: outputFindings.count,
                sampledTimestamps: renderedOutput.sampledTimestamps,
                outputFindingTimestamps: outputFindings.map(\.start),
                detectorCoverage: sourceCoverage.merging(outputCoverage)
            )
            if unresolvedAccepted > 0 {
                reportWarnings.append(
                    "Rendered-output scan still detected \(unresolvedAccepted) accepted sensitive item\(unresolvedAccepted == 1 ? "" : "s")."
                )
            }
        } else {
            reportWarnings.append("Rendered-output verification was not run.")
        }
        reportWarnings.append("The editable source bundle still contains original media.")
        return PrivacyReport(
            possibleFindingCount: possible,
            acceptedMaskCount: accepted,
            rejectedFindingCount: rejected,
            staleFindingCount: stale,
            verifiedMaskCount: verification.verifiedMaskCount,
            detectorCoverage: verification.detectorCoverage,
            verification: verification,
            warnings: Self.stableUnique(reportWarnings)
        )
    }

    public func report(
        findings: [PrivacyFinding],
        renderedOutput: PrivacyRenderedOutputVerificationInput? = nil
    ) -> PrivacyReport {
        makeReport(findings: findings, renderedOutput: renderedOutput)
    }

    // MARK: Detector implementation

    private struct TextContext: Sendable {
        let id: AnalysisEvidenceID
        let t: TimeInterval
        let duration: TimeInterval
        let rect: Rect2D
        let confidence: Double
        let source: PrivacyObservationSource
        let windowID: String?
    }

    private struct Hit: Sendable {
        let category: PrivacyCategory
        let value: String
        let context: TextContext
    }

    private static let apiKeyPattern = #"(?i)\b(?:sk|pk|rk|ghp|gho|ghu|ghs|github_pat|xox[baprs])-[A-Za-z0-9_\-]{8,}\b|\b(?:api[_-]?key|secret|token|password)\s*[:=]\s*[\"']?[A-Za-z0-9_\-]{8,}"#
    private static let commonTokenPattern = #"(?i)\bBearer\s+[A-Za-z0-9._\-]{16,}\b|\b[A-Za-z0-9][A-Za-z0-9_\-]{23,}\b|\beyJ[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#
    private static let emailPattern = #"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#
    private static let urlPattern = #"\bhttps?://[^\s<>\"']+"#

    private func appendTextDetectors(_ value: String, context: TextContext, to hits: inout [Hit]) {
        appendMatches(detector: .apiKey, pattern: Self.apiKeyPattern, in: value, context: context, to: &hits)
        appendMatches(
            detector: .commonToken,
            pattern: Self.commonTokenPattern,
            in: value,
            context: context,
            to: &hits,
            filter: Self.isCommonToken
        )
        appendMatches(detector: .email, pattern: Self.emailPattern, in: value, context: context, to: &hits)
        appendMatches(
            detector: .internalURL,
            pattern: Self.urlPattern,
            in: value,
            context: context,
            to: &hits,
            filter: Self.isInternalURL
        )
        for term in sensitiveTerms {
            appendMatches(
                detector: .sensitiveTerm,
                pattern: NSRegularExpression.escapedPattern(for: term),
                in: value,
                context: context,
                to: &hits,
                options: [.caseInsensitive]
            )
        }
    }

    private func appendMatches(
        detector: PrivacyCategory,
        pattern: String,
        in value: String,
        context: TextContext,
        to hits: inout [Hit],
        options: NSRegularExpression.Options = [.caseInsensitive],
        filter: ((String) -> Bool)? = nil
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in expression.matches(in: value, options: [], range: fullRange) {
            guard let range = Range(match.range, in: value) else { continue }
            let matched = String(value[range])
            guard !matched.isEmpty, filter?(matched) ?? true else { continue }
            var category = detector
            if detector == .apiKey {
                let lower = matched.lowercased()
                if lower.hasPrefix("token") || lower.hasPrefix("password") || lower.hasPrefix("secret") {
                    category = .commonToken
                }
            }
            hits.append(makeHit(category: category, value: Self.fingerprintValue(matched), context: context))
        }
    }

    private func makeHit(category: PrivacyCategory, value: String, context: TextContext) -> Hit {
        Hit(category: category, value: value, context: context)
    }

    private func makeFindings(hits: [Hit], detectorsRun: [PrivacyCategory]) -> [PrivacyFinding] {
        struct Group {
            let category: PrivacyCategory
            let fingerprint: PrivacyFingerprint
            var hits: [Hit]
        }
        var groups: [Group] = []
        let sortedHits = hits.sorted {
            if $0.context.t != $1.context.t { return $0.context.t < $1.context.t }
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.value < $1.value
        }
        for hit in sortedHits {
            let fingerprint = PrivacyFingerprint(value: hit.value)
            let match = groups.firstIndex { group in
                group.category == hit.category
                    && group.fingerprint == fingerprint
                    && hit.context.t - (group.hits.last?.context.t ?? hit.context.t)
                        <= configuration.maximumTrackGap
            }
            if let match {
                groups[match].hits.append(hit)
            } else {
                groups.append(Group(category: hit.category, fingerprint: fingerprint, hits: [hit]))
            }
        }

        return groups.map { group in
            let observations = group.hits.enumerated().map { index, hit in
                PrivacyGeometryObservation(
                    id: hit.context.id,
                    t: hit.context.t,
                    duration: hit.context.duration,
                    rect: hit.context.rect,
                    confidence: hit.context.confidence,
                    source: hit.context.source,
                    coordinateSpace: .normalizedCanvas,
                    sequence: UInt64(index)
                )
            }
            let score = group.hits.map { $0.context.confidence }.reduce(0, +) / Double(max(group.hits.count, 1))
            return PrivacyFinding(
                category: group.category,
                confidence: PrivacyConfidence.from(score: score),
                confidenceScore: score,
                fingerprint: group.fingerprint,
                tracks: [PrivacyGeometryTrack(observations: observations)]
            )
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.fingerprint.digest < $1.fingerprint.digest
        }
    }

    private func coverage(for findings: [PrivacyFinding], renderedOutput: Bool) -> PrivacyDetectorCoverage {
        let inputCount = textObservations.count + semanticSignals.count
            + notificationSignals.count + accountSignals.count
        let inputFrames = Set(
            (textObservations.map(\.t)
                + semanticSignals.map(\.t)
                + notificationSignals.map(\.t)
                + accountSignals.map(\.t))
                .map { Int(($0 / configuration.frameDuration).rounded()) }
        ).count
        var counts: [PrivacyCategory: Int] = [:]
        for finding in findings {
            counts[finding.category, default: 0] += 1
        }
        return PrivacyDetectorCoverage(
            detectorsRun: configuredDetectorCategories,
            matchedByCategory: counts,
            scannedObservationCount: inputCount,
            scannedFrameCount: inputFrames,
            renderedOutputScanned: renderedOutput
        )
    }

    private var configuredDetectorCategories: [PrivacyCategory] {
        [
            .apiKey, .commonToken, .email, .internalURL, .notification,
            .accountIdentifier, .sensitiveTerm,
        ] + (configuration.detectFaces ? [.face] : [])
            + (configuration.detectNames ? [.name] : [])
    }

    private func resolvedRect(
        _ raw: Rect2D,
        coordinateSpace: PrivacyCoordinateSpace,
        t: TimeInterval,
        windowID: String?
    ) -> Rect2D {
        var rect = raw
        if coordinateSpace == .pixels, let sourceSize = configuration.sourceSize,
           sourceSize.width > 0, sourceSize.height > 0
        {
            rect = Rect2D(
                x: raw.x / sourceSize.width,
                y: raw.y / sourceSize.height,
                width: raw.width / sourceSize.width,
                height: raw.height / sourceSize.height
            )
        }
        let transform = windowSignals
            .filter { signal in
                (signal.windowID == nil || signal.windowID == windowID)
                    && signal.t <= t
                    && (signal.duration <= 0 || t <= signal.t + signal.duration)
            }
            .sorted { $0.t > $1.t }
            .first
        guard let transform else { return PrivacyGeometry.normalized(rect) }
        return PrivacyGeometry.apply(
            rect,
            scale: transform.scale,
            offset: transform.offset,
            scrollOffset: transform.scrollOffset
        )
    }

    private static func isCommonToken(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        return hasDigit && hasLetter
    }

    private static func isInternalURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".corp") {
            return true
        }
        let pieces = host.split(separator: ".").compactMap { Int($0) }
        guard pieces.count == 4 else { return false }
        if pieces[0] == 10 || pieces[0] == 127 || (pieces[0] == 192 && pieces[1] == 168) { return true }
        return pieces[0] == 172 && (16...31).contains(pieces[1])
    }

    private static func fingerprintValue(_ matched: String) -> String {
        guard let separator = matched.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return matched
        }
        let value = matched[matched.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        return value.isEmpty ? matched : value
    }

    private static func normalizedTerms(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func rangesOverlap(
        _ lhsStart: TimeInterval,
        _ lhsEnd: TimeInterval,
        _ rhsStart: TimeInterval,
        _ rhsEnd: TimeInterval
    ) -> Bool {
        let leftEnd = max(lhsEnd, lhsStart + 1.0 / 30.0)
        let rightEnd = max(rhsEnd, rhsStart + 1.0 / 30.0)
        return lhsStart < rightEnd && rhsStart < leftEnd
    }

    private func deduplicated(_ hits: [Hit]) -> [Hit] {
        var seen = Set<String>()
        return hits.filter { hit in
            let key = [
                hit.category.rawValue,
                hit.context.id.rawValue,
                hit.context.t.description,
                hit.value,
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
