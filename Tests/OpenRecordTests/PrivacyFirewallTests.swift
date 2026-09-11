import Foundation
import Testing
@testable import OpenRecord

struct PrivacyFirewallTests {
    @Test
    func deterministicCategoriesAndNoPlaintextInEncodedEvidence() throws {
        let apiSecret = "sk-test-ABC123456789"
        let email = "person@example.com"
        let internalURL = "https://db.internal.example.local/admin"
        let account = "account-48291"
        let sensitive = "Project Ganymede"
        let analyzer = PrivacyFirewallAnalyzer(
            textObservations: [
                PrivacyTextObservation(t: 0, text: apiSecret, rect: Rect2D(x: 0, y: 0, width: 0.2, height: 0.1)),
                PrivacyTextObservation(t: 0.1, text: email, rect: Rect2D(x: 0.8, y: 0.9, width: 0.2, height: 0.1)),
                PrivacyTextObservation(t: 0.2, text: internalURL, rect: Rect2D(x: 0, y: 0.45, width: 1, height: 0.1)),
                PrivacyTextObservation(t: 0.3, text: sensitive, rect: Rect2D(x: 0.2, y: 0.2, width: 0.2, height: 0.1)),
            ],
            notificationSignals: [
                PrivacyNotificationSignal(t: 0.5, rect: Rect2D(x: 0.7, y: 0, width: 0.3, height: 0.2))
            ],
            accountSignals: [
                PrivacyAccountSignal(t: 0.4, identifier: account, rect: Rect2D(x: 0.4, y: 0.4, width: 0.2, height: 0.1))
            ],
            sensitiveTerms: [sensitive]
        )

        let findings = analyzer.analyze()
        let categories: Set<PrivacyCategory> = Set(findings.map { $0.category })
        #expect(categories.contains(.apiKey))
        #expect(categories.contains(.email))
        #expect(categories.contains(.internalURL))
        #expect(categories.contains(.accountIdentifier))
        #expect(categories.contains(.notification))
        #expect(categories.contains(.sensitiveTerm))
        let coverage = analyzer.makeReport(findings: findings).detectorCoverage
        #expect(coverage.scannedObservationCount >= 6)
        #expect(coverage.detectors.contains(.apiKey))
        #expect(coverage.matchedByCategory[.email, default: 0] > 0)

        let sidecar = try ProjectJSON.encoder.encode(findings)
        let report = analyzer.makeReport(findings: findings.map { $0.accepted() })
        let reportData = try ProjectJSON.encoder.encode(report)
        let sidecarText = String(decoding: sidecar, as: UTF8.self)
        let reportText = String(decoding: reportData, as: UTF8.self)
        #expect(!sidecarText.contains(apiSecret))
        #expect(!sidecarText.contains(email))
        #expect(!sidecarText.contains(internalURL))
        #expect(!sidecarText.contains(account))
        #expect(!reportText.contains(apiSecret))
        #expect(!reportText.contains(email))
        #expect(!report.claimsPerfectDetection)
        #expect(report.isSourceSanitized == false)
    }

    @Test
    func zoomedGeometryIsNormalizedAndEdgeRectanglesSurvive() {
        let observation = PrivacyTextObservation(
            t: 2,
            text: "person@example.com",
            rect: Rect2D(x: 180, y: 80, width: 20, height: 20),
            coordinateSpace: .pixels
        )
        let analyzer = PrivacyFirewallAnalyzer(
            textObservations: [observation],
            configuration: PrivacyAnalyzerConfiguration(
                sourceSize: Size2D(width: 200, height: 100)
            )
        )
        let finding = try! #require(analyzer.analyze().first)
        let rect = try! #require(finding.observations.first?.rect)
        #expect(abs(rect.x - 0.9) < 0.0001)
        #expect(abs(rect.y - 0.8) < 0.0001)
        #expect(rect.width > 0)
        #expect(rect.height > 0)
    }

    @Test
    func acceptedGeometryTracksWindowMotionAndBecomesRedactions() throws {
        let secret = "person@example.com"
        let analyzer = PrivacyFirewallAnalyzer(
            textObservations: [
                PrivacyTextObservation(t: 1, text: secret, rect: Rect2D(x: 0.1, y: 0.2, width: 0.25, height: 0.08), windowID: "editor"),
                PrivacyTextObservation(t: 1.1, text: secret, rect: Rect2D(x: 0.1, y: 0.2, width: 0.25, height: 0.08), windowID: "editor"),
                PrivacyTextObservation(t: 1.2, text: secret, rect: Rect2D(x: 0.1, y: 0.2, width: 0.25, height: 0.08), windowID: "editor"),
            ],
            windowSignals: [
                PrivacyWindowSignal(t: 1, windowID: "editor", translation: Point2D(x: 0.05, y: 0)),
                PrivacyWindowSignal(t: 1.1, windowID: "editor", translation: Point2D(x: 0.10, y: 0)),
                PrivacyWindowSignal(t: 1.2, windowID: "editor", translation: Point2D(x: 0.15, y: 0)),
            ]
        )
        let finding = try #require(analyzer.analyze().first)
        #expect(finding.observations.count == 3)
        #expect(finding.observations.last?.rect.x == 0.25)
        let redactions = finding.accepted().redactionRegions()
        #expect(redactions.count == 3)
        #expect(redactions.first?.start == 1)
        #expect((redactions.last?.end ?? 0) > 1.2)
    }

    @Test
    func oneFrameFindingGetsCoverageAndRenderedVerificationIsDistinct() throws {
        let secret = "sk-test-ABC123456789"
        let analyzer = PrivacyFirewallAnalyzer(textObservations: [
            PrivacyTextObservation(t: 4.25, text: secret, rect: Rect2D(x: 0.98, y: 0, width: 0.02, height: 0.08))
        ])
        let finding = try #require(analyzer.analyze().first?.accepted())
        let redaction = try #require(finding.redactionRegions().first)
        #expect(redaction.start == 4.25)
        #expect(redaction.end > redaction.start)

        let rendered = PrivacyRenderedOutputVerificationInput(
            observations: [
                PrivacyTextObservation(
                    t: 4.25,
                    text: secret,
                    rect: Rect2D(x: 0.98, y: 0, width: 0.02, height: 0.08),
                    source: .renderedOutput,
                    coordinateSpace: .renderedOutput
                )
            ],
            sampledTimestamps: [4.25],
            frameCount: 1
        )
        let report = analyzer.makeReport(findings: [finding], renderedOutput: rendered)
        #expect(report.possibleFindingCount == 0)
        #expect(report.acceptedMaskCount == 1)
        #expect(report.verifiedMaskCount == 0)
        #expect(report.verification.scanned)
        #expect(report.verification.outputFindingCount == 1)
        #expect(report.verification.sampledTimestamps == [4.25])
        #expect(report.verification.outputFindingTimestamps == [4.25])
        #expect(report.warnings.contains { $0.contains("still detected 1 accepted sensitive item") })

        let cleared = analyzer.makeReport(
            findings: [finding],
            renderedOutput: PrivacyRenderedOutputVerificationInput(
                observations: [],
                sampledTimestamps: [4.25],
                frameCount: 1
            )
        )
        #expect(cleared.verifiedMaskCount == 1)
        #expect(cleared.verification.outputFindingCount == 0)
    }

    @Test
    func servicePersistsPrivacyOnlyAndPreservesOtherSidecars() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-firewall-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let suggestions = Data("{\"id\":\"suggestion-1\"}\n".utf8)
        try AnalysisStore(projectURL: project).updateSidecars(
            [.suggestions: suggestions],
            analyzerVersion: "fixture",
            appVersion: "fixture"
        )
        let service = PrivacyAnalysisService(projectURL: project, appVersion: "fixture")
        let findings = try service.analyze(textObservations: [
            PrivacyTextObservation(t: 0, text: "person@example.com", rect: Rect2D(x: 0, y: 0, width: 1, height: 0.1))
        ])
        #expect(findings.count == 1)
        #expect(try AnalysisStore(projectURL: project).readSidecar(kind: .suggestions) == suggestions)
        let loaded = try #require(try service.loadFresh())
        #expect(loaded == findings)
    }

    @Test
    func regenerationPreservesReviewDecisionAndMarksObsoleteFindingStale() throws {
        let analyzer = PrivacyFirewallAnalyzer(textObservations: [
            PrivacyTextObservation(t: 0, text: "person@example.com", rect: Rect2D(x: 0, y: 0, width: 0.2, height: 0.1)),
            PrivacyTextObservation(t: 1, text: "https://localhost/admin", rect: Rect2D(x: 0.2, y: 0, width: 0.2, height: 0.1)),
        ])
        let initial = analyzer.analyze()
        let emailCandidate = try #require(initial.first(where: { $0.category == .email }))
        let accepted = emailCandidate.accepted()
        let regenerated = PrivacyFirewallAnalyzer(textObservations: [
            PrivacyTextObservation(t: 2, text: "person@example.com", rect: Rect2D(x: 0.3, y: 0, width: 0.2, height: 0.1)),
        ]).analyze()
        let result = PrivacyAnalysisService.reconcile(regenerated: regenerated, previous: [accepted] + initial.filter { $0.category != .email })
        let email = try #require(result.first(where: { $0.category == .email }))
        #expect(email.state == .accepted)
        #expect(email.id == accepted.id)
        #expect(result.contains { $0.category == .internalURL && $0.state == .stale })
    }
}
