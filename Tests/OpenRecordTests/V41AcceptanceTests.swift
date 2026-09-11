import Carbon.HIToolbox
import Foundation
@testable import OpenRecord
import Testing

/// A callable acceptance slice keeps the v4.1 privacy and compatibility gates
/// active on Command Line Tools hosts where Swift Testing's generated entry
/// point is not reliably invoked by `swift test`.
enum V41AcceptanceChecks {
    static func run() throws {
        guard !CaptureRequest.default.capturesSemanticTargets else {
            throw OpenRecordError.io("Semantic capture must remain opt-in")
        }
        let legacyRequest = try ProjectJSON.decoder.decode(
            CaptureRequest.self,
            from: Data(#"{"capturesCursorTelemetry":false,"capturesKeyboardShortcuts":false}"#.utf8)
        )
        guard !legacyRequest.capturesSemanticTargets,
              !SemanticPrivacyFilter.persistsOrdinaryTypedText,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "ordinary typed text",
                role: "AXTextField"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "password",
                role: "AXSecureTextField"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "selected text in document",
                role: "AXStaticText"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "control value",
                role: "AXValue"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "Untitled Window",
                role: "AXWindow"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "Settings — /Users/admin/passwords.txt",
                role: "window"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "sk-abcdefghijklmnopqrstuvwxyz012345",
                role: "AXButton"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "user@example.com",
                role: "AXButton"
              ) == nil,
              SemanticPrivacyFilter.sanitizeCapturedLabel(
                "bearer secret-token",
                role: "AXButton"
              ) == nil,
              SemanticPrivacyFilter.sanitizeWindowTitle("/Users/name/doc.txt") == nil,
              CursorMonitor.genericSemanticClickSample(
                t: 1,
                location: .zero,
                targetBounds: nil,
                reason: .elementUnavailable
              ).label == nil,
              CursorMonitor.genericSemanticClickSample(
                t: 1,
                location: .zero,
                targetBounds: nil,
                reason: .elementUnavailable
              ).bounds == nil,
              CursorMonitor.semanticShortcutLabel(
                keyCode: UInt16(kVK_ANSI_C),
                modifiers: [.command]
              ) == "Copy",
              CursorMonitor.semanticShortcutLabel(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: [.command]
              ) == "Select All",
              CursorMonitor.semanticShortcutLabel(
                keyCode: UInt16(kVK_ANSI_K),
                modifiers: [.command]
              ) == nil
        else {
            throw OpenRecordError.io("Semantic privacy defaults regressed")
        }

        let semantic = SemanticEventSample(
            id: try AnalysisEvidenceID("semantic-fixture"),
            t: 1,
            kind: .activate,
            role: "AXButton",
            label: "Save",
            confidence: 0.9,
            source: .accessibility,
            sequence: 3
        )
        let input = ActionMapAnalysisInput(
            semanticEvents: [semantic],
            clicks: [ClickSample(
                t: 1.1,
                button: .left,
                down: true,
                x: 10,
                y: 10,
                sequence: 4
            )],
            typingSamples: [TypingSample(t: 2, x: 10, y: 10, sequence: 0)],
            transcript: [TranscriptSegment(
                start: 0.8,
                end: 1.3,
                recognizedText: "PRIVATE TRANSCRIPT",
                confidence: 1
            )]
        )
        let first = ActionMapAnalyzer(input: input).analyze()
        let second = ActionMapAnalyzer(input: input).analyze()
        let encodedActions = String(
            decoding: try ProjectJSON.encoder.encode(first),
            as: UTF8.self
        )
        guard first == second,
              first.contains(where: {
                $0.label == "Save"
                    && $0.supportingSignals.contains("semantic-click-fusion")
              }),
              first.contains(where: { $0.label == "Text input" }),
              !encodedActions.contains("PRIVATE TRANSCRIPT"),
              !encodedActions.contains("ordinary typed text")
        else {
            throw OpenRecordError.io("ActionMap determinism or privacy regressed")
        }

        let ocr = VisionActionFallback.makeEvidence(
            id: try AnalysisEvidenceID("ocr-fixture"),
            t: 1,
            bounds: .unit,
            label: "ordinary typed text",
            confidence: 0.8
        )
        guard ocr.label == nil, ocr.degradationReason == .labelFiltered else {
            throw OpenRecordError.io("Unclassified OCR text crossed the privacy boundary")
        }

        let beat = StoryBeat(
            start: 8,
            end: 9,
            kind: .chapter,
            title: "Renamed action",
            evidenceIDs: [try AnalysisEvidenceID("action-fixture")],
            isLocked: true
        )
        let document = ProjectDocument(
            trimOut: 20,
            speedSegments: [SpeedSegment(start: 10, end: 14, rate: 2)],
            editDecisions: [EditDecision(start: 4, end: 7)],
            storyBeats: [beat]
        )
        let roundTrip = try ProjectJSON.decoder.decode(
            ProjectDocument.self,
            from: ProjectJSON.encoder.encode(document)
        )
        let mapper = ProjectTimeMapper(project: roundTrip, sourceDuration: 20)
        guard roundTrip.storyBeats == [beat],
              roundTrip.storyBeats[0].isLocked,
              mapper.outputTime(forSourceTime: 8) == 5,
              mapper.outputTime(forSourceTime: 12) == 8
        else {
            throw OpenRecordError.io("Format-v8 story-beat round-trip or mapping regressed")
        }

        // Removing rebuildable analysis/ leaves authored story beats and project edits intact
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordAcceptanceAnalysis-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ProjectLibrary(rootURL: root)
        let projectURL = try library.create(
            name: "Analysis removal fixture",
            meta: ProjectMeta(displayBounds: .unit, scale: 1, captureTarget: .display(id: 1))
        )
        let customBeat = StoryBeat(
            start: 1,
            end: 2,
            title: "Renamed action",
            evidenceIDs: [try AnalysisEvidenceID("action-1")],
            isLocked: true
        )
        try library.save(document: ProjectDocument(storyBeats: [customBeat]), to: projectURL)
        let action = ActionCandidate(
            id: try AnalysisEvidenceID("action-1"),
            start: 1,
            end: 2,
            kind: .click,
            label: "Save",
            confidence: 0.8,
            evidenceSources: [.click],
            evidenceIDs: []
        )
        let payload = try ProjectJSON.jsonlEncoder.encode(action) + Data([0x0A])
        try AnalysisStore(projectURL: projectURL).write(
            manifest: AnalysisManifest(
                analyzerVersion: "test",
                appVersion: "test",
                completionState: .partial,
                sidecars: [.actions: AnalysisSidecarSummary(
                    recordCount: 1,
                    byteCount: Int64(payload.count)
                )]
            ),
            sidecars: [.actions: payload]
        )
        let before = try library.open(url: projectURL).document
        try FileManager.default.removeItem(at: ProjectLayout.analysisDirectory(in: projectURL))
        let after = try library.open(url: projectURL).document
        guard before == after, after.storyBeats == [customBeat] else {
            throw OpenRecordError.io("Removing analysis/ mutated authored story beats or document edits")
        }
    }
}

@Test("v4.1 ActionMap acceptance slice")
func v41ActionMapAcceptanceSlice() throws {
    try V41AcceptanceChecks.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV41AcceptanceModInit: @convention(c) () -> Void = {
    OpenRecordRunV41AcceptanceChecks()
}

@_cdecl("OpenRecordRunV41AcceptanceChecks")
func OpenRecordRunV41AcceptanceChecks() {
    do {
        try V41AcceptanceChecks.run()
        fputs("OpenRecordTests: v4.1 ActionMap acceptance checks passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: v4.1 ActionMap acceptance checks failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif
