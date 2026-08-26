import Foundation
import OpenRecord
import Testing

@Test
func projectTemplateJSONRoundTripIsDeterministicAndMediaFree() throws {
    let template = ProjectTemplate(
        id: "tutorial-v3",
        name: "Tutorial",
        createdAt: Date(timeIntervalSince1970: 1_735_689_600),
        canvas: CanvasSettings(
            background: .solid(RGBAColor(r: 0.1, g: 0.2, b: 0.3)),
            padding: 72,
            cornerRadius: 22,
            aspectWidth: 9,
            aspectHeight: 16
        ),
        aspect: .portrait,
        cursor: CursorStylePreset(scale: 0.8, clickEmphasis: false, halo: true),
        webcam: WebcamOverlaySettings(enabled: true, size: 0.24),
        caption: CaptionStyle(fontSize: 58),
        export: VideoExportSettings(codec: .hevc, resolution: .p2160),
        annotation: AnnotationStylePreset(fontSize: 64),
        deviceFrame: DeviceFrameSettings(id: .genericPhoneDark, scale: 0.9),
        keyboardOverlay: KeyboardOverlaySettings(enabled: true, maxVisibleKeys: 4)
    )

    let first = try ProjectJSON.encoder.encode(template)
    let decoded = try ProjectJSON.decoder.decode(ProjectTemplate.self, from: first)
    let second = try ProjectJSON.encoder.encode(decoded)
    #expect(template == decoded)
    #expect(first == second)

    let wire = String(decoding: first, as: UTF8.self)
    #expect(!wire.contains("openrecord"))
    #expect(!wire.contains("media"))
    #expect(!wire.contains("transcript"))
    #expect(!wire.contains("editDecisions"))
}

@Test
func applyingTemplatePreservesTimedContentAndUpdatesStyles() {
    let cue = CaptionCue(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        start: 1,
        end: 4,
        text: "Keep this caption",
        style: CaptionStyle(fontSize: 20)
    )
    let annotation = Annotation.arrow(start: 2, end: 3)
    let decision = EditDecision(start: 4, end: 5)
    let transcript = TranscriptSegment(
        start: 1,
        end: 2,
        recognizedText: "original",
        editedText: "edited"
    )
    let original = ProjectDocument(
        trimIn: 0.5,
        trimOut: 8,
        captions: [cue],
        annotations: [annotation],
        editDecisions: [decision],
        transcript: [transcript]
    )
    let template = ProjectTemplate(
        id: "portrait",
        name: "Portrait",
        canvas: CanvasSettings(padding: 80),
        aspect: .portrait,
        cursor: CursorStylePreset(scale: 0.9, clickEmphasis: false, halo: true),
        caption: CaptionStyle(fontSize: 60, position: .top),
        annotation: AnnotationStylePreset(fontSize: 72)
    )

    let applied = template.applying(to: original)
    #expect(applied.trimIn == original.trimIn)
    #expect(applied.trimOut == original.trimOut)
    #expect(applied.captions[0].id == cue.id)
    #expect(applied.captions[0].start == cue.start)
    #expect(applied.captions[0].end == cue.end)
    #expect(applied.captions[0].text == cue.text)
    #expect(applied.captions[0].style == template.caption.normalized)
    #expect(applied.annotations[0].id == annotation.id)
    #expect(applied.annotations[0].start == annotation.start)
    #expect(applied.annotations[0].end == annotation.end)
    #expect(applied.annotations[0].fontSize == template.annotation?.fontSize)
    #expect(applied.editDecisions == original.editDecisions)
    #expect(applied.transcript == original.transcript)
    #expect(applied.canvas.aspectWidth == 9)
    #expect(applied.canvas.aspectHeight == 16)
    #expect(applied.canvas.padding == 80)
    #expect(applied.canvas.cursorScale == 0.9)
    #expect(applied.canvas.cursorClickEmphasis == false)
    #expect(applied.canvas.cursorHalo == true)
    #expect(applied.projectTemplateID == template.id)
    #expect(applied.defaultCaptionStyle == template.caption.normalized)
    #expect(applied.defaultAnnotationStyle == template.annotation)
}

@Test
func localProjectTemplateStoreIsPortableAndUsesSafeAtomicFilenames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenRecordTemplateTests-\(UUID().uuidString)", isDirectory: true)
    let importedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenRecordTemplateImportTests-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: importedRoot)
    }

    let sourceStore = LocalProjectTemplateStore(directoryURL: root)
    let template = ProjectTemplate(id: "../My tutorial", name: "My tutorial")
    let saved = try sourceStore.save(template)
    #expect(saved.pathExtension == ProjectTemplate.fileExtension)
    #expect(saved.lastPathComponent == "My-tutorial.\(ProjectTemplate.fileExtension)")
    #expect(try sourceStore.load() == [template])

    let exported = try sourceStore.export(template, to: importedRoot)
    #expect(exported.pathExtension == ProjectTemplate.fileExtension)
    let destinationStore = LocalProjectTemplateStore(directoryURL: importedRoot)
    let imported = try destinationStore.import(from: exported)
    #expect(imported == template)
    #expect(try destinationStore.load() == [template])
}

@Test
func futureProjectTemplateVersionsAreRejectedAndSkippedByStore() throws {
    let template = ProjectTemplate(formatVersion: 2, id: "future", name: "Future")
    do {
        let data = try ProjectJSON.encoder.encode(template)
        _ = try ProjectJSON.decoder.decode(ProjectTemplate.self, from: data)
        Issue.record("Future template version unexpectedly decoded")
    } catch let error as OpenRecordError {
        #expect(error.localizedDescription.contains("format version 2"))
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenRecordFutureTemplateTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalProjectTemplateStore(directoryURL: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try ProjectJSON.encoder.encode(template)
    try data.write(
        to: root.appendingPathComponent("future.\(ProjectTemplate.fileExtension)"),
        options: Data.WritingOptions.atomic
    )
    #expect(try store.load().isEmpty)
    do {
        _ = try store.import(from: root.appendingPathComponent("future.\(ProjectTemplate.fileExtension)"))
        Issue.record("Future template import unexpectedly succeeded")
    } catch let error as OpenRecordError {
        #expect(error.localizedDescription.contains("format version 2"))
    }

    let unknownFieldData = Data(
        #"{"formatVersion":1,"id":"unknown","name":"Unknown","createdAt":"1970-01-01T00:00:00Z","futureMedia":{"path":"secret.mov"}}"#.utf8
    )
    do {
        _ = try ProjectJSON.decoder.decode(ProjectTemplate.self, from: unknownFieldData)
        Issue.record("Current template with an unknown field unexpectedly decoded")
    } catch let error as OpenRecordError {
        #expect(error.localizedDescription.contains("unsupported fields"))
        #expect(error.localizedDescription.contains("futureMedia"))
    }
}
