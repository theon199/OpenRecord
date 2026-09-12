import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OpenRecord

@Suite("Audit Regression Tests")
struct AuditFixTests {
    @Test("PrivacyGeometry.normalized clamps edges without shifting on negative coordinates")
    func privacyGeometryNormalization() {
        let partiallyOffscreen = Rect2D(x: -0.05, y: 0.1, width: 0.15, height: 0.2)
        let normalized = PrivacyGeometry.normalized(partiallyOffscreen)
        #expect(normalized.x == 0.0)
        #expect(abs(normalized.width - 0.10) < 1e-6)
        #expect(normalized.y == 0.1)
        #expect(abs(normalized.height - 0.2) < 1e-6)

        let completelyOffscreen = Rect2D(x: -0.5, y: -0.5, width: 0.2, height: 0.2)
        let offscreenNorm = PrivacyGeometry.normalized(completelyOffscreen)
        #expect(offscreenNorm.width == 0.0)
        #expect(offscreenNorm.height == 0.0)
    }

    @Test("ProjectTimeMapper maps source time across non-monotonic timeline spans")
    func nonMonotonicTimeMapping() {
        // Take 2 (source 50..60) placed first on timeline (0..10),
        // Take 1 (source 10..20) placed second on timeline (10..20).
        let spans = [
            TimelineSpan(sourceID: "take-2", sourceStart: 50, sourceEnd: 60),
            TimelineSpan(sourceID: "take-1", sourceStart: 10, sourceEnd: 20)
        ]
        let mapper = ProjectTimeMapper(sourceDuration: 20.0, timelineSpans: spans)

        // Querying take-1 with source time 15 should map into the second span (output 15.0)
        let output = mapper.outputTime(forSourceTime: 15, sourceID: "take-1")
        #expect(output != nil)
        if let output {
            #expect(abs(output - 15.0) < 1e-6)
        }

        // Querying take-2 with source time 55 should map into the first span (output 5.0)
        let output2 = mapper.outputTime(forSourceTime: 55, sourceID: "take-2")
        #expect(output2 != nil)
        if let output2 {
            #expect(abs(output2 - 5.0) < 1e-6)
        }
    }

    @Test("MicrophoneRecorder.silentBuffer zeroes out PCM channel data")
    func microphoneSilentBufferZeroing() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)
        else {
            return
        }
        buffer.frameLength = 1024
        if let channels = buffer.floatChannelData {
            for c in 0..<2 {
                for i in 0..<1024 {
                    channels[c][i] = Float.random(in: -1.0...1.0)
                }
            }
        }
        let silent = MicrophoneRecorder.silentBuffer(matching: buffer)
        #expect(silent.frameLength == 1024)
        if let channels = silent.floatChannelData {
            for c in 0..<2 {
                for i in 0..<1024 {
                    #expect(channels[c][i] == 0.0)
                }
            }
        }
    }

    @Test("RecordingHUDLayout allowedDiameterRange handles NaN bounds gracefully")
    func recordingHUDLayoutNaNBounds() {
        let nanBounds = CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat.nan)
        let range = RecordingHUDLayout.allowedDiameterRange(displayBounds: nanBounds)
        #expect(range.lowerBound <= range.upperBound)
        #expect(range.lowerBound.isFinite)
        #expect(range.upperBound.isFinite)
    }

    @Test("SpeedTimeline normalizedSegments does not trap on NaN values")
    func speedTimelineNaNTolerance() {
        let segments = [
            SpeedSegment(start: Double.nan, end: 5.0, rate: 2.0),
            SpeedSegment(start: 1.0, end: Double.nan, rate: 1.5),
            SpeedSegment(start: 2.0, end: 4.0, rate: 1.5)
        ]
        let result = SpeedTimeline.normalizedSegments(segments, sourceDuration: 10.0)
        #expect(!result.isEmpty)
        for seg in result {
            #expect(seg.start.isFinite)
            #expect(seg.end.isFinite)
        }
    }

    @Test("SpringConfig zeta handles negative friction safely")
    func springNegativeFriction() {
        let config = SpringConfig(tension: 100, mass: 1, friction: -10)
        #expect(config.zeta >= 0)
        #expect(config.zeta.isFinite)
    }

    @Test("ProjectLayout sanitizes path traversal attempts in take directory")
    func projectLayoutPathTraversalSanitization() {
        let projectURL = URL(fileURLWithPath: "/tmp/fake.openrecord")
        let escapedID = "../../etc/passwd"
        let takeDir = ProjectLayout.takeDirectory(sourceID: escapedID, in: projectURL)
        #expect(!takeDir.path.contains(".."))
        #expect(takeDir.lastPathComponent == "take-invalid")
    }

    @Test("ZoomInsertion proposal handles NaN playhead without NaN output")
    func zoomInsertionNaNPlayhead() {
        let result = ZoomInsertion.proposal(
            at: Double.nan,
            timelineDuration: 10.0,
            ranges: []
        )
        if case .create(let start, let end) = result {
            #expect(start.isFinite)
            #expect(end.isFinite)
            #expect(start >= 0)
            #expect(end <= 10.0)
        }
    }

    @Test("PatchTakeOperations reverting restores primary media without gaps in multi-take project")
    func multiTakeRevertRestoresPrimaryMedia() {
        let doc = ProjectDocument(
            mediaSources: [
                MediaSource.primary(duration: 10.0),
                MediaSource(id: "take-1", relativePath: "recording/takes/take-1", duration: 3.0),
                MediaSource(id: "take-2", relativePath: "recording/takes/take-2", duration: 2.0)
            ],
            timelineSpans: [
                TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 0, sourceEnd: 3),
                TimelineSpan(sourceID: "take-1", sourceStart: 0, sourceEnd: 2.5),
                TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 6, sourceEnd: 8),
                TimelineSpan(sourceID: "take-2", sourceStart: 0, sourceEnd: 2.0),
                TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 9, sourceEnd: 10)
            ]
        )

        // Revert take-1; primary interval 3..<6 should be restored and coalesced with 0..<3 and 6..<8
        let reverted = PatchTakeOperations.reverting(takeID: "take-1", in: doc, primaryDuration: 10.0)
        #expect(!reverted.mediaSources.contains { $0.id == "take-1" })
        #expect(reverted.mediaSources.contains { $0.id == "take-2" })
        #expect(!reverted.timelineSpans.contains { $0.sourceID == "take-1" })

        // Check that the restored primary span was coalesced into 0..<8
        let primarySpans = reverted.timelineSpans.filter { $0.sourceID == MediaSource.primaryID }
        #expect(primarySpans.count == 2)
        #expect(primarySpans[0].sourceStart == 0.0)
        #expect(primarySpans[0].sourceEnd == 8.0)
    }

    @Test("ProjectDocumentHistory redo preserves redo stack without transaction interference")
    func historyRedoPreservesStack() {
        var history = ProjectDocumentHistory(limit: 10)
        let doc0 = ProjectDocument(trimIn: 0.0)
        let doc1 = ProjectDocument(trimIn: 1.0)
        let doc2 = ProjectDocument(trimIn: 2.0)

        history.record(before: doc0, after: doc1, actionName: "Edit 1")
        history.record(before: doc1, after: doc2, actionName: "Edit 2")

        let undone = history.undo(currentDocument: doc2)
        #expect(undone?.trimIn == 1.0)
        #expect(history.canRedo)

        // Redo should successfully restore doc2
        let redone = history.redo(currentDocument: doc1)
        #expect(redone?.trimIn == 2.0)
        #expect(history.canUndo)
    }

    @Test("SilenceAnalyzer does not clip speech when retained breathing room exceeds pause capacity")
    func silenceBreathingRoomPreserved() {
        // A short pause of 0.4s: with 0.2s breathing room, 0.4 - 2*0.2 = 0s cut (< minimumPause / 3)
        let samples = [
            AudioLevelSample(timestamp: 0.0, decibels: -10),
            AudioLevelSample(timestamp: 0.5, decibels: -60),
            AudioLevelSample(timestamp: 0.9, decibels: -10)
        ]
        let suggestions = SilenceAnalyzer.detect(
            samples: samples,
            options: SilenceAnalysisOptions(minimumPause: 0.3, retainedBreathingRoom: 0.2)
        )
        // Since breathing room leaves < minimumPause/3, it should be rejected rather than clipping speech
        #expect(suggestions.isEmpty)
    }

    @Test("ProjectDocumentPersistence validates unsupported enum values in timelineSpans")
    func persistenceValidationTimelineSpans() {
        let invalidSpanJSON: [String: Any] = [
            "timelineSpans": [
                [
                    "id": UUID().uuidString,
                    "sourceID": "primary",
                    "sourceStart": 0.0,
                    "sourceEnd": 5.0,
                    "seamTransition": "unsupported-transition-type",
                    "audioMode": "unsupported-audio-mode"
                ]
            ]
        ]
        let issues = AtomicFileWrite.unsupportedEnumValues(in: invalidSpanJSON)
        #expect(issues.contains { $0.contains("timelineSpans[0].seamTransition") })
        #expect(issues.contains { $0.contains("timelineSpans[0].audioMode") })
    }

    @Test("DeviceFrameGeometry conforms to Hashable for frame caching")
    func deviceFrameGeometryHashable() {
        let g1 = DeviceFrameGeometry(frameRect: CGRect(x: 0, y: 0, width: 100, height: 100), screenRect: CGRect(x: 10, y: 10, width: 80, height: 80), cornerRadius: 8)
        let g2 = DeviceFrameGeometry(frameRect: CGRect(x: 0, y: 0, width: 100, height: 100), screenRect: CGRect(x: 10, y: 10, width: 80, height: 80), cornerRadius: 8)
        let g3 = DeviceFrameGeometry(frameRect: CGRect(x: 0, y: 0, width: 100, height: 100), screenRect: CGRect(x: 10, y: 10, width: 80, height: 80), cornerRadius: 12)
        #expect(g1 == g2)
        #expect(g1.hashValue == g2.hashValue)
        #expect(g1 != g3)
    }
}
