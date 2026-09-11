import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import OpenRecord

@Test
func semanticCaptureRequestDefaultsAndPermissions() throws {
    let defaults = CaptureRequest.default
    #expect(!defaults.capturesSemanticTargets)

    let semanticOnly = CaptureRequest(
        capturesMicrophone: false,
        capturesSystemAudio: false,
        capturesCursorTelemetry: false,
        capturesKeyboardShortcuts: false,
        capturesWebcam: false,
        capturesSemanticTargets: true
    )
    #expect(semanticOnly.requiresAccessibility)
    #expect(CapturePermissions.requiredPermissions(for: semanticOnly) == [.screenRecording, .accessibility])

    let legacyJSON = """
    {
      "capturesMicrophone": false,
      "capturesSystemAudio": true,
      "capturesCursorTelemetry": false,
      "capturesKeyboardShortcuts": false,
      "capturesWebcam": false
    }
    """.data(using: .utf8)!
    let legacy = try ProjectJSON.decoder.decode(CaptureRequest.self, from: legacyJSON)
    #expect(!legacy.capturesSemanticTargets)
    #expect(!legacy.requiresAccessibility)

    let encoded = try ProjectJSON.encoder.encode(semanticOnly)
    let decoded = try ProjectJSON.decoder.decode(CaptureRequest.self, from: encoded)
    #expect(decoded == semanticOnly)
}

@Test
func semanticCapturePrivacyPolicyRejectsPrivateLabelsAndValues() {
    #expect(SemanticPrivacyFilter.sanitizeCapturedLabel("Save", role: "AXButton") == "Save")
    #expect(SemanticPrivacyFilter.sanitizeCapturedLabel("  Save   As  ", role: "AXMenuItem") == "Save As")
    #expect(SemanticPrivacyFilter.sanitizeCapturedLabel("typed secret", role: "AXTextField") == nil)
    #expect(SemanticPrivacyFilter.sanitizeCapturedLabel("password", role: "AXSecureTextField", isSecure: true) == nil)
    #expect(SemanticPrivacyFilter.sanitizeCapturedLabel("person@example.com", role: "AXButton") == nil)

    let normalized = SemanticEventSample(
        t: -1,
        kind: .activate,
        role: "AXButton",
        label: "Save",
        bounds: Rect2D(x: -0.2, y: 0.8, width: 2, height: 0.4),
        confidence: 4,
        source: .accessibility
    ).normalized
    #expect(normalized.t == 0)
    #expect(normalized.label == "Save")
    #expect(normalized.bounds == Rect2D(x: 0, y: 0.8, width: 1, height: 0.2))
    #expect(normalized.confidence == 1)
}

@Test
func semanticCaptureGeometryAndShortcutHelpersArePure() {
    let target = Rect2D(x: 100, y: 50, width: 1_000, height: 500)
    let bounds = CursorMonitor.normalizedTargetRelativeBounds(
        elementFrame: CGRect(x: 600, y: 300, width: 100, height: 50),
        targetBounds: target
    )
    #expect(bounds == Rect2D(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
    #expect(CursorMonitor.normalizedTargetRelativeBounds(
        elementFrame: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
        targetBounds: target
    ) == nil)

    #expect(CursorMonitor.isStoryBeatMarker(
        keyCode: UInt16(kVK_ANSI_M),
        modifiers: [.control, .option, .command]
    ))
    #expect(!CursorMonitor.isStoryBeatMarker(
        keyCode: UInt16(kVK_ANSI_M),
        modifiers: [.control, .option, .command, .shift]
    ))
    #expect(CursorMonitor.semanticShortcutLabel(
        keyCode: UInt16(kVK_ANSI_C), modifiers: [.command]
    ) == "Copy")
}

@Test
func semanticCaptureJSONLSequenceAndDegradation() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("openrecord-semantic-(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try JSONLWriter<SemanticEventSample>(url: url)
    writer.write(CursorMonitor.genericSemanticClickSample(
        t: 2.5,
        location: CGPoint(x: 20, y: 30),
        targetBounds: Rect2D.unit,
        reason: .accessibilityUnavailable
    ))
    writer.write(SemanticEventSample(
        t: 3,
        kind: .storyBeat,
        confidence: 1,
        source: .userMarker
    ))
    writer.close()

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
    let samples = try lines.map {
        try ProjectJSON.decoder.decode(SemanticEventSample.self, from: Data($0.utf8))
    }
    #expect(samples.map(\.sequence) == [0, 1])
    #expect(samples[0].kind == .genericClick)
    #expect(samples[0].degradationReason == .accessibilityUnavailable)
    #expect(samples[0].label == nil)
    #expect(samples[1].kind == .storyBeat)
    #expect(samples[1].source == .userMarker)

    let serialized = try String(contentsOf: url, encoding: .utf8)
    #expect(!serialized.contains("secret"))
    #expect(!serialized.contains("typed"))
}
