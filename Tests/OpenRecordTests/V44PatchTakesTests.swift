import Foundation
@testable import OpenRecord
import Testing

@Suite("v4.4 Patch Takes and Multi-Source Timeline")
struct V44PatchTakesTests {

    @Test("Format v8 document round-trips mediaSources and timelineSpans losslessly")
    func documentRoundTripWithMediaSourcesAndTimelineSpans() throws {
        let spanID = UUID()
        let sourceID = "take_rec_01"
        let source = MediaSource(
            id: sourceID,
            relativePath: "recording/takes/\(sourceID)",
            timingOrigin: 0.5,
            trackOffsets: ["mic": 0.02],
            width: 1920,
            height: 1080,
            duration: 4.5,
            label: "Take 1"
        )
        let span = TimelineSpan(
            id: spanID,
            sourceID: sourceID,
            sourceStart: 0.5,
            sourceEnd: 3.5,
            seamTransition: .crossDissolve,
            transitionDuration: 0.25,
            audioMode: .sourceAudio
        )
        let doc = ProjectDocument(
            mediaSources: [MediaSource.primary(duration: 10.0), source],
            timelineSpans: [span]
        )

        let encoded = try ProjectJSON.encoder.encode(doc)
        let decoded = try ProjectJSON.decoder.decode(ProjectDocument.self, from: encoded)

        #expect(decoded.formatVersion == 8)
        #expect(decoded.mediaSources.count == 2)
        #expect(decoded.mediaSources[0].isPrimary)
        #expect(decoded.mediaSources[1].id == sourceID)
        #expect(decoded.mediaSources[1].relativePath == "recording/takes/\(sourceID)")
        #expect(decoded.mediaSources[1].duration == 4.5)
        #expect(decoded.timelineSpans.count == 1)
        #expect(decoded.timelineSpans[0].id == spanID)
        #expect(decoded.timelineSpans[0].sourceID == sourceID)
        #expect(decoded.timelineSpans[0].sourceStart == 0.5)
        #expect(decoded.timelineSpans[0].sourceEnd == 3.5)
        #expect(decoded.timelineSpans[0].seamTransition == .crossDissolve)
        #expect(decoded.timelineSpans[0].transitionDuration == 0.25)
        #expect(decoded.timelineSpans[0].audioMode == .sourceAudio)
        #expect(decoded.referencedSourceIDs.contains(sourceID))
        #expect(decoded.referencedSourceIDs.contains(MediaSource.primaryID))
    }

    @Test("Legacy format documents decode missing mediaSources and timelineSpans as empty")
    func legacyDocumentsDefaultToEmptySourcesAndSpans() throws {
        let legacyJSON = """
        {
            "formatVersion": 8,
            "trimIn": 0,
            "canvas": { "aspect": "16:9", "scale": 1 },
            "cursorSprites": [],
            "keyboardOverlay": { "enabled": false },
            "webcamOverlay": { "enabled": false },
            "autoZoomSensitivity": "normal",
            "zoomEasing": "smooth",
            "speedSegments": [],
            "muteAudioWhenSpedUp": false,
            "audioCleanup": {},
            "captions": [],
            "annotations": [],
            "redactions": [],
            "drawings": [],
            "deviceFrame": { "preset": "none" },
            "videoExportSettings": { "resolution": "1080p", "frameRate": "auto" },
            "editDecisions": [],
            "transcript": [],
            "cursorEffects": [],
            "defaultCaptionStyle": { "position": "bottom" },
            "storyBeats": []
        }
        """
        let decoded = try ProjectJSON.decoder.decode(ProjectDocument.self, from: Data(legacyJSON.utf8))
        #expect(decoded.mediaSources.isEmpty)
        #expect(decoded.timelineSpans.isEmpty)
        #expect(decoded.referencedSourceIDs == [MediaSource.primaryID])
    }

    @Test("Forward format version rejection preserves forward safety")
    func forwardVersionRejection() throws {
        let futureJSON = """
        {
            "formatVersion": 9,
            "trimIn": 0
        }
        """
        #expect(throws: OpenRecordError.self) {
            try ProjectJSON.decoder.decode(ProjectDocument.self, from: Data(futureJSON.utf8))
        }
    }

    @Test("Single-source project renders and maps identically to pre-patch-take behavior")
    func singleSourceIdentityPreserved() throws {
        let doc = ProjectDocument(
            trimIn: 1.0,
            trimOut: 8.0,
            speedSegments: [
                SpeedSegment(start: 1.0, end: 2.0, rate: 2.0)
            ],
            editDecisions: [
                EditDecision(start: 3.0, end: 5.0)
            ]
        )
        let legacyMapper = ProjectTimeMapper(
            sourceDuration: 10.0,
            trimIn: 1.0,
            trimOut: 8.0,
            editDecisions: doc.editDecisions,
            speedSegments: doc.speedSegments
        )
        let modernMapper = ProjectTimeMapper(project: doc, sourceDuration: 10.0)

        #expect(abs(legacyMapper.outputDuration - modernMapper.outputDuration) < 0.0001)
        #expect(modernMapper.slices.count == legacyMapper.slices.count)

        for t in stride(from: 0.0, through: modernMapper.outputDuration, by: 0.25) {
            let legacySource = legacyMapper.sourceTime(atOutputTime: t)
            let modernLocation = modernMapper.sourceLocation(atOutputTime: t)
            #expect(modernLocation.sourceID == MediaSource.primaryID)
            #expect(abs(modernLocation.sourceTime - legacySource) < 0.0001)
            #expect(abs(modernMapper.sourceTime(atOutputTime: t) - legacySource) < 0.0001)
        }
    }

    @Test("Multi-source timeline maps output time across takes and seam boundaries accurately")
    func multiSourceTimelineMapping() throws {
        let takeID = "take_demo_01"
        let primarySource = MediaSource.primary(duration: 10.0)
        let takeSource = MediaSource(
            id: takeID,
            relativePath: "recording/takes/\(takeID)",
            duration: 3.0
        )
        let spans = [
            TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 0, sourceEnd: 4),
            TimelineSpan(sourceID: takeID, sourceStart: 0.5, sourceEnd: 2.5, seamTransition: .crossDissolve, transitionDuration: 0.3),
            TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 7, sourceEnd: 10)
        ]
        let doc = ProjectDocument(
            mediaSources: [primarySource, takeSource],
            timelineSpans: spans
        )
        let mapper = ProjectTimeMapper(project: doc, sourceDuration: 10.0)

        // Slices:
        // 1. primary: 0..4 (duration 4) -> output 0..4
        // 2. takeID: 0.5..2.5 (duration 2) -> output 4..6
        // 3. primary: 7..10 (duration 3) -> output 6..9
        // Total output duration = 9
        #expect(abs(mapper.outputDuration - 9.0) < 0.0001)

        // Check time within first span (primary)
        let loc1 = mapper.sourceLocation(atOutputTime: 2.0)
        #expect(loc1.sourceID == MediaSource.primaryID)
        #expect(abs(loc1.sourceTime - 2.0) < 0.0001)

        // Check time within second span (takeID)
        let loc2 = mapper.sourceLocation(atOutputTime: 5.0)
        #expect(loc2.sourceID == takeID)
        #expect(abs(loc2.sourceTime - 1.5) < 0.0001) // 0.5 + (5 - 4) = 1.5

        // Check time within third span (primary)
        let loc3 = mapper.sourceLocation(atOutputTime: 7.5)
        #expect(loc3.sourceID == MediaSource.primaryID)
        #expect(abs(loc3.sourceTime - 8.5) < 0.0001) // 7.0 + (7.5 - 6) = 8.5

        // Check reverse output time mapping
        let outTake = mapper.outputTime(forSourceTime: 1.5, sourceID: takeID)
        #expect(outTake != nil)
        #expect(abs((outTake ?? 0) - 5.0) < 0.0001)

        let outPrimary = mapper.outputTime(forSourceTime: 8.5, sourceID: MediaSource.primaryID)
        #expect(outPrimary != nil)
        #expect(abs((outPrimary ?? 0) - 7.5) < 0.0001)

        // Check active seam detection for crossDissolve
        let seam = mapper.activeSeam(atOutputTime: 4.0)
        #expect(seam != nil)
        #expect(seam?.transition == .crossDissolve)
        #expect(seam?.outgoingSourceID == MediaSource.primaryID)
        #expect(seam?.incomingSourceID == takeID)
        #expect(abs((seam?.progress ?? 0) - 0.5) < 0.01)
    }

    @Test("PatchTakeAligner produces high confidence and cross-dissolve for matching seams")
    func patchTakeAlignerMatchingSeam() {
        let eval = PatchTakeAligner.evaluate(
            targetStart: 2.0,
            targetEnd: 5.0,
            targetCursorEntry: Point2D(x: 0.3, y: 0.4),
            targetCursorExit: Point2D(x: 0.6, y: 0.7),
            takeStart: 0.0,
            takeEnd: 3.1,
            takeCursorEntry: Point2D(x: 0.31, y: 0.41),
            takeCursorExit: Point2D(x: 0.61, y: 0.69),
            targetWindowBounds: Rect2D(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            takeWindowBounds: Rect2D(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )

        #expect(eval.confidence >= 0.8)
        #expect(eval.transition == .crossDissolve)
        #expect(eval.transitionDuration > 0)
        #expect(!eval.reasons.isEmpty)
    }

    @Test("PatchTakeAligner produces cut transition when cursor entry jumps significantly")
    func patchTakeAlignerDivergentSeam() {
        let eval = PatchTakeAligner.evaluate(
            targetStart: 2.0,
            targetEnd: 5.0,
            targetCursorEntry: Point2D(x: 0.1, y: 0.1),
            targetCursorExit: Point2D(x: 0.2, y: 0.2),
            takeStart: 0.0,
            takeEnd: 3.0,
            takeCursorEntry: Point2D(x: 0.9, y: 0.9), // far jump
            takeCursorExit: Point2D(x: 0.8, y: 0.8)
        )

        #expect(eval.confidence < 0.75)
        #expect(eval.transition == .cut)
        #expect(eval.transitionDuration == 0)
    }

    @Test("PatchTakeOperations applies replacement take and allows lossless revert")
    func patchTakeOperationsApplyAndRevert() {
        var doc = ProjectDocument(trimIn: 0, trimOut: 10)
        let takeSource = MediaSource(
            id: "take_patch_1",
            relativePath: "recording/takes/take_patch_1",
            duration: 2.5
        )

        // Replace range 3.0..6.0 with take 0..2.5
        doc = PatchTakeOperations.applying(
            targetStart: 3.0,
            targetEnd: 6.0,
            take: takeSource,
            patchStart: 0.0,
            patchEnd: 2.5,
            seamTransition: .crossDissolve,
            transitionDuration: 0.2,
            to: doc,
            primaryDuration: 10.0
        )

        #expect(doc.timelineSpans.count == 3)
        #expect(doc.timelineSpans[0].sourceID == MediaSource.primaryID)
        #expect(doc.timelineSpans[0].sourceStart == 0.0)
        #expect(doc.timelineSpans[0].sourceEnd == 3.0)

        #expect(doc.timelineSpans[1].sourceID == "take_patch_1")
        #expect(doc.timelineSpans[1].sourceStart == 0.0)
        #expect(doc.timelineSpans[1].sourceEnd == 2.5)

        #expect(doc.timelineSpans[2].sourceID == MediaSource.primaryID)
        #expect(doc.timelineSpans[2].sourceStart == 6.0)
        #expect(doc.timelineSpans[2].sourceEnd == 10.0)

        // Reverting the patch take restores the document
        doc = PatchTakeOperations.reverting(
            takeID: "take_patch_1",
            in: doc,
            primaryDuration: 10.0
        )
        #expect(doc.timelineSpans.isEmpty)
        #expect(!doc.mediaSources.contains(where: { $0.id == "take_patch_1" }))
    }

    @Test("Save Copy includes all referenced takes and prunes unreferenced temporary takes")
    func saveCopyPrunesUnreferencedTakes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRecordTakeTest-\(UUID().uuidString)")
        let bundleURL = tempDir.appendingPathComponent("SourceProject.openrecord")
        let destURL = tempDir.appendingPathComponent("CopiedProject.openrecord")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let recordingDir = ProjectLayout.recordingDirectory(in: bundleURL)
        try FileManager.default.createDirectory(at: recordingDir, withIntermediateDirectories: true)

        // Create display.mp4 in primary
        try Data("primary-video".utf8).write(to: ProjectLayout.displayVideoURL(in: bundleURL))
        try Data("{}".utf8).write(to: ProjectLayout.metaURL(in: bundleURL))

        // Create takes directory with take-1 (referenced) and take-orphan (unreferenced)
        let take1Dir = ProjectLayout.takeDirectory(sourceID: "take-1", in: bundleURL)
        let orphanDir = ProjectLayout.takeDirectory(sourceID: "take-orphan", in: bundleURL)
        try FileManager.default.createDirectory(at: take1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try Data("take-1-video".utf8).write(to: ProjectLayout.displayVideoURL(sourceID: "take-1", in: bundleURL))
        try Data("orphan-video".utf8).write(to: ProjectLayout.displayVideoURL(sourceID: "take-orphan", in: bundleURL))

        let doc = ProjectDocument(
            mediaSources: [
                MediaSource.primary(duration: 5.0),
                MediaSource(id: "take-1", relativePath: "recording/takes/take-1", duration: 2.0)
            ],
            timelineSpans: [
                TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 0, sourceEnd: 2),
                TimelineSpan(sourceID: "take-1", sourceStart: 0, sourceEnd: 2)
            ]
        )
        try AtomicFileWrite.writeProjectDocument(doc, to: ProjectLayout.documentURL(in: bundleURL))

        let library = ProjectLibrary(rootURL: tempDir)
        try library.saveCopy(of: bundleURL, document: doc, to: destURL)

        // Verify copied bundle
        let copiedTake1 = ProjectLayout.displayVideoURL(sourceID: "take-1", in: destURL)
        let copiedOrphan = ProjectLayout.displayVideoURL(sourceID: "take-orphan", in: destURL)

        #expect(FileManager.default.fileExists(atPath: copiedTake1.path))
        #expect(!FileManager.default.fileExists(atPath: copiedOrphan.path))
    }

    @Test("Multi-source audio placements respect silence and sourceAudio modes")
    func multiSourceAudioPlacements() {
        let spans = [
            TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 0, sourceEnd: 3, audioMode: .sourceAudio),
            TimelineSpan(sourceID: "take_silent", sourceStart: 0, sourceEnd: 2, audioMode: .silence),
            TimelineSpan(sourceID: "take_with_audio", sourceStart: 0, sourceEnd: 2, audioMode: .sourceAudio),
            TimelineSpan(sourceID: MediaSource.primaryID, sourceStart: 7, sourceEnd: 10, audioMode: .sourceAudio)
        ]
        let mapper = ProjectTimeMapper(
            sourceDuration: 10.0,
            mediaSources: [MediaSource.primary(duration: 10.0)],
            timelineSpans: spans
        )

        // Primary audio placements
        let primaryPlacements = ExportAudioMux.placements(
            timeMapper: mapper,
            sourceOffset: 0,
            sourceTimelineDuration: 10.0,
            sourceMediaDuration: 10.0,
            sourceID: MediaSource.primaryID
        )

        // The silent take (output 3..5) must NOT generate an audio placement
        for p in primaryPlacements {
            let overlapsSilentTake = p.outputStart < 5.0 && (p.outputStart + p.outputDuration) > 3.0
            #expect(!overlapsSilentTake, "Silent take must not have audio placement")
        }

        // Take audio placements
        let takePlacements = ExportAudioMux.placements(
            timeMapper: mapper,
            sourceOffset: 0,
            sourceTimelineDuration: 2.0,
            sourceMediaDuration: 2.0,
            sourceID: "take_with_audio"
        )
        #expect(takePlacements.count == 1)
        #expect(abs(takePlacements[0].outputStart - 5.0) < 0.0001) // Output 5..7
        #expect(abs(takePlacements[0].outputDuration - 2.0) < 0.0001)
    }
}

enum V44PatchTakesSuite {
    static func run() throws {
        let instance = V44PatchTakesTests()
        try instance.documentRoundTripWithMediaSourcesAndTimelineSpans()
        try instance.legacyDocumentsDefaultToEmptySourcesAndSpans()
        try instance.forwardVersionRejection()
        try instance.singleSourceIdentityPreserved()
        try instance.multiSourceTimelineMapping()
        instance.patchTakeAlignerMatchingSeam()
        instance.patchTakeAlignerDivergentSeam()
        instance.patchTakeOperationsApplyAndRevert()
        try instance.saveCopyPrunesUnreferencedTakes()
        instance.multiSourceAudioPlacements()
    }
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV44PatchTakesTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunV44PatchTakesTests()
}

@_cdecl("OpenRecordRunV44PatchTakesTests")
func OpenRecordRunV44PatchTakesTests() {
    do {
        try V44PatchTakesSuite.run()
        fputs("OpenRecordTests: v4.4 Patch Takes tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: v4.4 Patch Takes tests failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif
