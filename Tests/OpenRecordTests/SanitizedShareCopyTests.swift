import Foundation
import OpenRecord
import Testing

struct SanitizedShareCopyTests {
    @Test
    func derivativeContainsOnlyTheAllowlistAndReplacesSourceDisplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let summary = SanitizedSharePrivacySummary(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            detectorCoverage: ["ocr", "accessibility"],
            detectedCategories: ["email"],
            findingCount: 1,
            notes: ["best-effort"]
        )
        let result = try fixture.service.create(
            sourceProjectURL: fixture.source,
            renderedDisplayURL: fixture.safeRender,
            sourceMeta: fixture.meta,
            sourceDocument: fixture.editedDocument,
            privacyReport: summary,
            destinationURL: fixture.destination
        )

        #expect(result.destinationURL == fixture.destination.standardizedFileURL)
        #expect(result.includedPaths == SanitizedShareCopyService.includedPaths)
        #expect(result.sourceBundleSanitized == false)
        #expect(result.detectionGuaranteedPerfect == false)
        #expect(result.fingerprints.keys.contains("recording/display.mp4"))
        #expect(result.fingerprints.keys.contains("privacy-report.json"))

        let outputFiles = try fixture.files(in: fixture.destination)
        #expect(outputFiles == [
            "meta.json",
            "privacy-report.json",
            "project.json",
            "recording/display.mp4",
        ])
        #expect(try Data(contentsOf: fixture.destinationDisplay) == fixture.safeBytes)
        #expect(try Data(contentsOf: fixture.sourceDisplay) == fixture.originalBytes)

        let outputMeta = try ProjectJSON.decoder.decode(
            ProjectMeta.self,
            from: Data(contentsOf: fixture.destinationMeta)
        )
        #expect(outputMeta.displayBounds == fixture.meta.displayBounds)
        #expect(outputMeta.scale == fixture.meta.scale)
        #expect(outputMeta.captureTarget == .display(id: 0))
        #expect(outputMeta.captureTiming == nil)
        #expect(outputMeta.captureHealth == nil)
        #expect(outputMeta.captureDiagnostics == nil)
        #expect(outputMeta.webcam == nil)

        let outputDocument = try ProjectJSON.decoder.decode(
            ProjectDocument.self,
            from: Data(contentsOf: fixture.destinationDocument)
        )
        #expect(outputDocument == ProjectDocument())
        let independentlyOpened = try ProjectLibrary(rootURL: fixture.root).open(url: fixture.destination)
        #expect(independentlyOpened.meta == outputMeta)
        #expect(independentlyOpened.document == outputDocument)
        #expect(FileManager.default.fileExists(atPath: fixture.destinationDisplay.path))

        let reportObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.destinationReport)
        ) as? [String: Any]
        #expect(reportObject?["sourceBundleSanitized"] as? Bool == false)
        #expect(reportObject?["detectionGuaranteedPerfect"] as? Bool == false)
        #expect(reportObject?["includedPaths"] as? [String] == SanitizedShareCopyService.includedPaths)
        #expect((reportObject?["excludedPaths"] as? [String])?.contains("analysis/**") == true)
        #expect((reportObject?["privacyReport"] as? [String: Any])?["findingCount"] as? Int == 1)
        #expect((reportObject?["sha256"] as? [String: String])?["recording/display.mp4"] != nil)
        #expect((reportObject?["disclaimer"] as? String)?.contains("not sanitized") == true)
    }

    @Test
    func sourceMediaAndForbiddenPathsNeverAppearInDerivative() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let report = PrivacyReport(
            possibleFindingCount: 2,
            acceptedMaskCount: 1,
            verifiedMaskCount: 1,
            detectorCoverage: PrivacyDetectorCoverage()
        )
        _ = try fixture.service.install(
            sourceProjectURL: fixture.source,
            renderedDisplayURL: fixture.safeRender,
            sourceMeta: fixture.meta,
            sourceDocument: fixture.editedDocument,
            privacyReport: report,
            destinationURL: fixture.destination
        )

        let outputFiles = try fixture.files(in: fixture.destination)
        for excluded in SanitizedShareCopyService.excludedPaths {
            let literal = excluded.hasSuffix("/**")
                ? String(excluded.dropLast(3))
                : excluded
            #expect(!outputFiles.contains(where: { $0 == literal || $0.hasPrefix(literal + "/") }))
        }
        #expect(!outputFiles.contains("recording/display-original.mp4"))
        #expect(!outputFiles.contains("recording/mic.m4a"))
        #expect(!outputFiles.contains("recording/cursors/cursor.json"))
    }

    @Test
    func failedStagingPreservesExistingDestinationAndCleansSiblingStage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let marker = fixture.destination.appendingPathComponent("old.txt")
        try Data("old destination".utf8).write(to: marker)

        struct ThrowingReport: Encodable, Sendable {
            func encode(to encoder: Encoder) throws {
                throw OpenRecordError.io("intentional report failure")
            }
        }

        #expect(throws: OpenRecordError.self) {
            _ = try fixture.service.create(
                sourceProjectURL: fixture.source,
                renderedDisplayURL: fixture.safeRender,
                sourceMeta: fixture.meta,
                sourceDocument: fixture.editedDocument,
                privacyReport: ThrowingReport(),
                destinationURL: fixture.destination
            )
        }
        #expect(try Data(contentsOf: marker) == Data("old destination".utf8))

        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        )
        #expect(!siblings.contains(where: { $0.lastPathComponent.contains(".staging-") }))
    }

    @Test
    func unsafePathsAreRejectedBeforeInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: OpenRecordError.self) {
            _ = try fixture.service.create(
                sourceProjectURL: fixture.source,
                renderedDisplayURL: fixture.sourceDisplay,
                sourceMeta: fixture.meta,
                sourceDocument: fixture.editedDocument,
                privacyReport: SanitizedSharePrivacySummary(),
                destinationURL: fixture.destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))

        let symlink = fixture.root.appendingPathComponent("safe-link.mp4")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.safeRender)
        #expect(throws: OpenRecordError.self) {
            _ = try fixture.service.create(
                sourceProjectURL: fixture.source,
                renderedDisplayURL: symlink,
                sourceMeta: fixture.meta,
                sourceDocument: fixture.editedDocument,
                privacyReport: SanitizedSharePrivacySummary(),
                destinationURL: fixture.destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let safeRender: URL
        let destination: URL
        let originalBytes = Data("ORIGINAL-DISPLAY-MEDIA".utf8)
        let safeBytes = Data("RENDERED-SAFE-DISPLAY-MEDIA".utf8)
        let service = SanitizedShareCopyService()
        let meta: ProjectMeta
        let editedDocument: ProjectDocument

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("OpenRecordSanitizedShare-" + UUID().uuidString, isDirectory: true)
            source = root.appendingPathComponent("source.openrecord", isDirectory: true)
            safeRender = root.appendingPathComponent("rendered-safe.mp4", isDirectory: false)
            destination = root.appendingPathComponent("share.openrecord", isDirectory: true)
            meta = ProjectMeta(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "test",
                displayBounds: Rect2D(x: 0, y: 24, width: 1920, height: 1080),
                scale: 2,
                captureTarget: .window(id: 42),
                captureTiming: CaptureTiming(systemAudioOffset: 0.2, microphoneOffset: 0.3),
                webcam: WebcamCaptureInfo(deviceID: "private-camera")
            )
            editedDocument = ProjectDocument(
                trimIn: 3,
                trimOut: 9,
                zoomRanges: [
                    ZoomRange(
                        start: 1,
                        end: 2,
                        amount: 1.8,
                        anchor: Point2D(x: 0.5, y: 0.5)
                    )
                ]
            )

            try fm.createDirectory(at: ProjectLayout.recordingDirectory(in: source), withIntermediateDirectories: true)
            try fm.createDirectory(at: ProjectLayout.cursorsDirectory(in: source), withIntermediateDirectories: true)
            try fm.createDirectory(at: ProjectLayout.analysisDirectory(in: source), withIntermediateDirectories: true)
            try originalBytes.write(to: ProjectLayout.displayVideoURL(in: source))
            try Data("webcam".utf8).write(to: ProjectLayout.webcamVideoURL(in: source))
            try Data("mic".utf8).write(to: ProjectLayout.microphoneAudioURL(in: source))
            try Data("system".utf8).write(to: ProjectLayout.systemAudioURL(in: source))
            try Data("thumb".utf8).write(to: ProjectLayout.thumbnailURL(in: source))
            try Data("cursor".utf8).write(to: ProjectLayout.cursorsDirectory(in: source).appendingPathComponent("cursor.json"))
            try Data("analysis".utf8).write(to: ProjectLayout.analysisDirectory(in: source).appendingPathComponent("ocr.jsonl"))
            try safeBytes.write(to: safeRender)
        }

        func files(in directory: URL) throws -> [String] {
            let fm = FileManager.default
            let urls = try fm.subpathsOfDirectory(atPath: directory.path)
            return urls.filter { path in
                var isDirectory = ObjCBool(false)
                return fm.fileExists(
                    atPath: directory.appendingPathComponent(path).path,
                    isDirectory: &isDirectory
                ) && !isDirectory.boolValue
            }.sorted()
        }

        var sourceDisplay: URL { ProjectLayout.displayVideoURL(in: source) }
        var destinationMeta: URL { ProjectLayout.metaURL(in: destination) }
        var destinationDocument: URL { ProjectLayout.documentURL(in: destination) }
        var destinationDisplay: URL { ProjectLayout.displayVideoURL(in: destination) }
        var destinationReport: URL {
            destination.appendingPathComponent("privacy-report.json", isDirectory: false)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
