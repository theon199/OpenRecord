import Darwin
import Foundation
import OpenRecord
import Testing

enum ProjectMigrationFixtureTests {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "OpenRecordMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let library = ProjectLibrary(rootURL: root)
        try assertVersionedFixturesRoundTrip(library: library, root: root)
        try assertMalformedAndPartialDocumentsFailSafely(library: library, root: root)
        try assertInterruptedSavePreservesValidDocument(library: library, root: root)
        try assertMalformedDocumentCanBeRepaired(library: library, root: root)
        try assertUnsupportedSchemasNeverReplaceBytes(library: library, root: root)
        try assertNestedUnknownFieldsSurviveSave(library: library, root: root)
        try assertLegacyUnknownFieldsRemainReadOnly(library: library, root: root)
        try assertUnknownEnumValuesRemainReadOnly(library: library, root: root)
        try assertMalformedEditDecisionsRemainReadOnly(library: library, root: root)
    }

    private static func assertVersionedFixturesRoundTrip(
        library: ProjectLibrary,
        root: URL
    ) throws {
        for version in 1...ProjectDocument.currentFormatVersion {
            let projectURL = try copyFixtureBundle(
                named: "v\(version).openrecord",
                to: root,
                as: "Fixture V\(version).openrecord"
            )
            let documentURL = ProjectLayout.documentURL(in: projectURL)
            let originalBytes = try Data(contentsOf: documentURL)
            let opened = try library.open(url: projectURL)

            guard opened.document.formatVersion == version else {
                throw OpenRecordError.io(
                    "The v\(version) fixture opened as format \(opened.document.formatVersion)"
                )
            }
            guard try Data(contentsOf: documentURL) == originalBytes else {
                throw OpenRecordError.io("Opening the v\(version) fixture rewrote project.json")
            }

            try assertRepresentativeFields(in: opened.document, version: version)
            let expected = opened.document.upgradedForSave()
            try library.save(document: opened.document, to: projectURL)
            let migrated = try library.open(url: projectURL).document
            guard migrated.formatVersion == ProjectDocument.currentFormatVersion,
                  migrated == expected
            else {
                throw OpenRecordError.io(
                    "The v\(version) fixture did not migrate and round-trip without losing fields"
                )
            }
        }
    }

    private static func assertRepresentativeFields(
        in document: ProjectDocument,
        version: Int
    ) throws {
        switch version {
        case 1:
            guard document.trimIn == 0.5,
                  document.trimOut == 18,
                  document.zoomRanges.first?.id
                    == UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
                  document.zoomRanges.first?.anchor == Point2D(x: 0.25, y: 0.75),
                  document.cursorSprites.first?.id == "legacy-arrow",
                  document.canvas.cursorMotionBlur == .disabled
            else {
                throw OpenRecordError.io("The v1 fixture lost a legacy edit while decoding")
            }
        case 2:
            guard document.trimIn == 1.25,
                  document.keyboardOverlay.enabled,
                  document.keyboardOverlay.position == .bottomLeft,
                  document.webcamOverlay.shape == .roundedRectangle,
                  document.webcamOverlay.size == 0.24,
                  document.stylePresetID == "dark",
                  document.autoZoomSensitivity == .aggressive,
                  document.zoomEasing == .cinematic,
                  document.speedSegments.first?.rate == 2,
                  document.audioCleanup.noiseGateEnabled,
                  document.audioCleanup.microphoneGain == 1.2
            else {
                throw OpenRecordError.io("The v2 fixture lost a v2 edit while decoding")
            }
        case 3:
            guard document.trimIn == 0.75,
                  document.canvas.cursorMotionBlur
                    == CursorMotionBlurSettings(enabled: true, amount: 0.7),
                  document.captions.first?.text == "Fixture caption",
                  document.annotations.first?.text == "Fixture callout",
                  document.videoExportSettings
                    == VideoExportSettings(codec: .hevc, resolution: .p1080)
            else {
                throw OpenRecordError.io("The v3 fixture lost a current document field while decoding")
            }
        case 4:
            guard document.editDecisions.count == 2,
                  document.editDecisions[0].kind == .exclude,
                  document.editDecisions[0].start == 10,
                  document.editDecisions[0].end == 13,
                  document.editDecisions[1].start == 21,
                  document.editDecisions[1].end == 23.5
            else {
                throw OpenRecordError.io("The v4 fixture lost edit decisions while decoding")
            }
        case 5:
            guard document.transcript.count == 2,
                  document.transcript[0].recognizedText == "Let's open the settings panel.",
                  document.transcript[1].displayText == "Open Settings.",
                  document.transcript[1].recognizedText == "Open the preference window.",
                  document.transcript[1].source == .mixed,
                  document.cursorEffects.count == 1,
                  document.cursorEffects[0].clickEmphasis,
                  document.cursorEffects[0].halo,
                  document.zoomRanges.first?.tracking == .fixed,
                  document.zoomRanges.first?.isLocked == true,
                  document.zoomRanges.first?.source == .automatic,
                  document.appliedPresetIDs == ["dark", "tutorial"]
            else {
                throw OpenRecordError.io("The v5 fixture lost smart-editing fields while decoding")
            }
        case 6:
            guard document.redactions.first?.mode == .pixelate,
                  document.drawings.first?.tool == .highlighter,
                  document.annotations.first?.kind == .stepMarker,
                  document.annotations.first?.animation.entrance == .pop,
                  document.deviceFrame.id == .genericLaptopDark,
                  document.webcamOverlay.shape == .squircle,
                  document.webcamOverlay.borderColor == RGBAColor(r: 0.2, g: 0.8, b: 1),
                  document.audioCleanup.compressorEnabled,
                  document.audioCleanup.limiterEnabled,
                  document.audioCleanup.fadeInDuration == 0.4
            else {
                throw OpenRecordError.io("The v6 fixture lost v3.1 visual or audio fields while decoding")
            }
        case 7:
            guard document.projectTemplateID == "built-in-portrait-demo",
                  document.defaultCaptionStyle.fontSize == 52,
                  document.defaultCaptionStyle.maxWidth == 0.82,
                  document.defaultAnnotationStyle?.fontSize == 48,
                  document.canvas.aspectWidth == 9,
                  document.canvas.aspectHeight == 16,
                  document.deviceFrame.id == .genericPhoneDark,
                  document.videoExportSettings
                    == VideoExportSettings(codec: .hevc, resolution: .p1080)
            else {
                throw OpenRecordError.io("The v7 fixture lost v3.2 project-template defaults")
            }
        default:
            throw OpenRecordError.io("Unexpected migration fixture version \(version)")
        }
    }

    private static func assertMalformedAndPartialDocumentsFailSafely(
        library: ProjectLibrary,
        root: URL
    ) throws {
        for fixture in ["malformed-project.json", "partial-project.json"] {
            let projectURL = try copyFixtureBundle(
                named: "v3.openrecord",
                to: root,
                as: "\(fixture).openrecord"
            )
            let documentURL = ProjectLayout.documentURL(in: projectURL)
            let invalidBytes = try Data(contentsOf: fixtureURL(named: fixture))
            try invalidBytes.write(to: documentURL, options: .atomic)

            let message = try openFailureMessage(library: library, projectURL: projectURL)
            guard message.contains("Invalid project.json"),
                  try Data(contentsOf: documentURL) == invalidBytes
            else {
                throw OpenRecordError.io(
                    "\(fixture) was not rejected without changing its on-disk bytes"
                )
            }
        }
    }

    private static func assertInterruptedSavePreservesValidDocument(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v3.openrecord",
            to: root,
            as: "Interrupted Save.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let validBytes = try Data(contentsOf: documentURL)
        let validDocument = try library.open(url: projectURL).document

        let orphan = projectURL.appendingPathComponent(
            ".project.json.tmp-interrupted",
            isDirectory: false
        )
        try Data(#"{"formatVersion":3,"trimIn":"#.utf8).write(to: orphan)
        guard try library.open(url: projectURL).document == validDocument,
              try Data(contentsOf: documentURL) == validBytes
        else {
            throw OpenRecordError.io("An interrupted temporary save hid the valid project document")
        }
        try FileManager.default.removeItem(at: orphan)

        var unencodable = validDocument
        unencodable.trimIn = .nan
        do {
            try library.save(document: unencodable, to: projectURL)
            throw OpenRecordError.io("A non-finite project document was unexpectedly saved")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("Could not encode project.json")
            else {
                throw error
            }
        }

        guard try Data(contentsOf: documentURL) == validBytes,
              try library.open(url: projectURL).document == validDocument
        else {
            throw OpenRecordError.io("A failed save replaced the last valid project document")
        }
        try assertNoAtomicWriteArtifacts(in: projectURL)
    }

    private static func assertMalformedDocumentCanBeRepaired(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v3.openrecord",
            to: root,
            as: "Repair Malformed.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let malformed = try Data(contentsOf: fixtureURL(named: "malformed-project.json"))
        try malformed.write(to: documentURL, options: .atomic)

        let replacement = ProjectDocument(trimIn: 2, trimOut: 14)
        try library.save(document: replacement, to: projectURL)
        guard try library.open(url: projectURL).document == replacement else {
            throw OpenRecordError.io("An atomic save could not repair malformed project.json")
        }
        try assertNoAtomicWriteArtifacts(in: projectURL)
    }

    private static func assertUnsupportedSchemasNeverReplaceBytes(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let cases = [
            (fixture: "future-project.json", expected: "supports up to"),
            (fixture: "unknown-field-project.json", expected: "unsupported fields"),
        ]
        for item in cases {
            let projectURL = try copyFixtureBundle(
                named: "v3.openrecord",
                to: root,
                as: "\(item.fixture).openrecord"
            )
            let documentURL = ProjectLayout.documentURL(in: projectURL)
            let unsupportedBytes = try Data(contentsOf: fixtureURL(named: item.fixture))
            try unsupportedBytes.write(to: documentURL, options: .atomic)

            let message = try openFailureMessage(library: library, projectURL: projectURL)
            guard message.contains(item.expected),
                  try Data(contentsOf: documentURL) == unsupportedBytes
            else {
                throw OpenRecordError.io(
                    "\(item.fixture) did not follow the reject-without-rewrite policy"
                )
            }

            let validCandidate = ProjectDocument(trimIn: 9)
            do {
                try library.save(document: validCandidate, to: projectURL)
                throw OpenRecordError.io("A valid candidate replaced an unsupported project.json")
            } catch let error as OpenRecordError {
                guard case .io(let failure) = error,
                      failure.contains(item.expected)
                else {
                    throw error
                }
            }
            guard try Data(contentsOf: documentURL) == unsupportedBytes else {
                throw OpenRecordError.io("A rejected unsupported-schema save changed project.json")
            }
            try assertNoAtomicWriteArtifacts(in: projectURL)
        }

        let candidateURL = try copyFixtureBundle(
            named: "v3.openrecord",
            to: root,
            as: "Future Candidate.openrecord"
        )
        let candidateDocumentURL = ProjectLayout.documentURL(in: candidateURL)
        let supportedBytes = try Data(contentsOf: candidateDocumentURL)
        var futureCandidate = try library.open(url: candidateURL).document
        futureCandidate.formatVersion = ProjectDocument.currentFormatVersion + 1
        do {
            try library.save(document: futureCandidate, to: candidateURL)
            throw OpenRecordError.io("A future candidate unexpectedly replaced project.json")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("newer than the supported version")
            else {
                throw error
            }
        }
        guard try Data(contentsOf: candidateDocumentURL) == supportedBytes else {
            throw OpenRecordError.io("A rejected future candidate changed project.json")
        }
    }

    private static func assertNestedUnknownFieldsSurviveSave(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v3.openrecord",
            to: root,
            as: "Nested Unknown Fields.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let fixture = try Data(contentsOf: fixtureURL(named: "nested-unknown-project.json"))
        try fixture.write(to: documentURL, options: .atomic)

        var document = try library.open(url: projectURL).document
        document.trimIn = 2.5
        document.webcamOverlay.size = 0.3
        document.captions[0].text = "Edited known caption field"
        document.editDecisions[0].end = 7.5
        try library.save(document: document, to: projectURL)

        let savedData = try Data(contentsOf: documentURL)
        guard let rootObject = try JSONSerialization.jsonObject(with: savedData) as? [String: Any],
              let webcam = rootObject["webcamOverlay"] as? [String: Any],
              let futureShape = webcam["futureShape"] as? [String: Any],
              futureShape["name"] as? String == "squircle",
              webcam["size"] as? Double == 0.3,
              let captions = rootObject["captions"] as? [[String: Any]],
              let firstCaption = captions.first,
              let futureAnimation = firstCaption["futureAnimation"] as? [String: Any],
              futureAnimation["name"] as? String == "bounce",
              firstCaption["text"] as? String == "Edited known caption field",
              let decisions = rootObject["editDecisions"] as? [[String: Any]],
              let firstDecision = decisions.first,
              let futureReason = firstDecision["futureReason"] as? [String: Any],
              futureReason["source"] as? String == "pause-analysis",
              firstDecision["end"] as? Double == 7.5
        else {
            throw OpenRecordError.io("Saving discarded nested unknown fields or current edits")
        }

        let reopened = try library.open(url: projectURL).document
        guard reopened.trimIn == 2.5,
              reopened.webcamOverlay.size == 0.3,
              reopened.captions.first?.text == "Edited known caption field",
              reopened.editDecisions.first?.end == 7.5
        else {
            throw OpenRecordError.io("A nested-field-preserving save did not reopen correctly")
        }
    }

    private static func assertLegacyUnknownFieldsRemainReadOnly(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v1.openrecord",
            to: root,
            as: "Legacy Unknown Fields.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let legacyBytes = try Data(contentsOf: fixtureURL(named: "legacy-unknown-project.json"))
        try legacyBytes.write(to: documentURL, options: .atomic)

        let opened = try library.open(url: projectURL)
        guard opened.document.formatVersion == 1,
              opened.document.trimIn == 0.5,
              try Data(contentsOf: documentURL) == legacyBytes
        else {
            throw OpenRecordError.io("A legacy document with unknown fields did not open read-only")
        }

        do {
            try library.save(document: opened.document, to: projectURL)
            throw OpenRecordError.io("A legacy unknown field was silently discarded on save")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("opened read-only"),
                  message.contains("saving was refused")
            else {
                throw error
            }
        }
        guard try Data(contentsOf: documentURL) == legacyBytes else {
            throw OpenRecordError.io("A rejected legacy migration changed project.json")
        }
    }

    private static func assertUnknownEnumValuesRemainReadOnly(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v3.openrecord",
            to: root,
            as: "Unknown Enum Values.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let unsupportedBytes = try Data(contentsOf: fixtureURL(named: "unknown-enum-project.json"))
        try unsupportedBytes.write(to: documentURL, options: .atomic)

        // Current decoders intentionally provide safe preview defaults for
        // some enum values, but persistence must not replace the raw values.
        let opened = try library.open(url: projectURL)
        guard opened.document.webcamOverlay.shape == .circle,
              opened.document.autoZoomSensitivity == .normal,
              opened.document.videoExportSettings == .default
        else {
            throw OpenRecordError.io("Unsupported enum values did not use safe read-only defaults")
        }

        do {
            try library.save(document: opened.document, to: projectURL)
            throw OpenRecordError.io("Unsupported enum values were silently replaced on save")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("unsupported enum values"),
                  message.contains("webcamOverlay.shape=hexagon"),
                  message.contains("videoExportSettings.codec=av1"),
                  message.contains("defaultCaptionStyle.position=lower-third")
            else {
                throw error
            }
        }
        guard try Data(contentsOf: documentURL) == unsupportedBytes else {
            throw OpenRecordError.io("A rejected unknown-enum save changed project.json")
        }

        let decisionProjectURL = try copyFixtureBundle(
            named: "v4.openrecord",
            to: root,
            as: "Unknown Decision Enum.openrecord"
        )
        let decisionDocumentURL = ProjectLayout.documentURL(in: decisionProjectURL)
        let decisionBytes = try Data(contentsOf: fixtureURL(named: "unknown-decision-enum-project.json"))
        try decisionBytes.write(to: decisionDocumentURL, options: .atomic)
        let decisionOpened = try library.open(url: decisionProjectURL).document
        guard decisionOpened.editDecisions.isEmpty else {
            throw OpenRecordError.io("Unsupported edit-decision kind was not isolated on read")
        }
        do {
            try library.save(document: decisionOpened, to: decisionProjectURL)
            throw OpenRecordError.io("Unsupported edit-decision kind was silently replaced on save")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("unsupported enum values"),
                  message.contains("editDecisions[0].kind=insert")
            else {
                throw error
            }
        }
        guard try Data(contentsOf: decisionDocumentURL) == decisionBytes else {
            throw OpenRecordError.io("A rejected unknown edit-decision kind changed project.json")
        }
    }

    private static func assertMalformedEditDecisionsRemainReadOnly(
        library: ProjectLibrary,
        root: URL
    ) throws {
        let projectURL = try copyFixtureBundle(
            named: "v4.openrecord",
            to: root,
            as: "Malformed Edit Decisions.openrecord"
        )
        let documentURL = ProjectLayout.documentURL(in: projectURL)
        let raw = Data(
            #"{"formatVersion":4,"trimIn":0,"trimOut":10,"editDecisions":[{"id":"11111111-aaaa-bbbb-cccc-111111111111","start":1,"end":2,"kind":"exclude"},{"id":"22222222-aaaa-bbbb-cccc-222222222222","start":"three","end":4,"kind":"exclude"},{"id":"33333333-aaaa-bbbb-cccc-333333333333","start":5,"end":6,"kind":7}]}"#.utf8
        )
        try raw.write(to: documentURL, options: .atomic)

        let opened = try library.open(url: projectURL).document
        guard opened.editDecisions.count == 1,
              opened.editDecisions[0].start == 1,
              opened.editDecisions[0].end == 2
        else {
            throw OpenRecordError.io("A malformed decision hid valid sibling decisions")
        }

        do {
            try library.save(document: opened, to: projectURL)
            throw OpenRecordError.io("Malformed edit decisions were silently discarded on save")
        } catch let error as OpenRecordError {
            guard case .io(let message) = error,
                  message.contains("unsupported enum values"),
                  message.contains("editDecisions[1].start=<missing-or-non-number>"),
                  message.contains("editDecisions[2].kind=<missing-or-non-string>")
            else {
                throw error
            }
        }
        guard try Data(contentsOf: documentURL) == raw else {
            throw OpenRecordError.io("A rejected malformed-decision save changed project.json")
        }
    }

    private static func openFailureMessage(
        library: ProjectLibrary,
        projectURL: URL
    ) throws -> String {
        do {
            _ = try library.open(url: projectURL)
            throw OpenRecordError.io("Invalid project.json unexpectedly opened")
        } catch let error as OpenRecordError {
            if case .io(let message) = error,
               message.contains("unexpectedly opened")
            {
                throw error
            }
            return error.errorDescription ?? error.localizedDescription
        }
    }

    private static func assertNoAtomicWriteArtifacts(in projectURL: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: projectURL.path)
        guard !names.contains(where: { $0.hasPrefix(".project.json.tmp-") }) else {
            throw OpenRecordError.io("Atomic save left a project.json temporary file behind")
        }
    }

    private static func copyFixtureBundle(
        named fixtureName: String,
        to root: URL,
        as destinationName: String
    ) throws -> URL {
        let destination = root.appendingPathComponent(destinationName, isDirectory: true)
        try FileManager.default.copyItem(
            at: fixtureURL(named: fixtureName),
            to: destination
        )
        return destination
    }

    private static func fixtureURL(named name: String) throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw OpenRecordError.io("SwiftPM did not provide migration fixture resources")
        }
        let url = resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ProjectMigration", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenRecordError.io("Missing migration fixture: \(url.path)")
        }
        return url
    }
}

@Test
func projectMigrationFixturesAndSaveIntegrity() throws {
    try ProjectMigrationFixtureTests.run()
}

/// CLT `swift test` does not reliably execute Swift Testing's generated entry
/// point, so this constructor keeps the Phase 1 migration regressions active.
#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordMigrationTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunProjectMigrationFixtureTests()
}

@_cdecl("OpenRecordRunProjectMigrationFixtureTests")
func OpenRecordRunProjectMigrationFixtureTests() {
    do {
        try ProjectMigrationFixtureTests.run()
        fputs("OpenRecordTests: project migration fixture tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: project migration fixture tests failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif
