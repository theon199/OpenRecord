import Foundation
import OpenRecord
import Testing

@Test
func localPresetRoundTripsAndAppliesPortableValues() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "OpenRecordPresetTests-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalPresetStore(directoryURL: root)
    let preset = EditorStylePreset(
        id: "my/tutorial preset",
        name: "My Tutorial",
        caption: CaptionStyle(fontSize: 58),
        cursor: CursorStylePreset(scale: 0.8, clickEmphasis: false, halo: true),
        export: VideoExportSettings(codec: .hevc, resolution: .p2160)
    )
    let saved = try store.save(preset)
    #expect(saved.lastPathComponent == "my-tutorial-preset.json")
    #expect(try store.load() == [preset])

    let cue = CaptionCue(start: 0, end: 2, text: "Hello")
    let effect = CursorEffectRange(start: 0, end: 2)
    let applied = preset.applying(to: ProjectDocument(captions: [cue], cursorEffects: [effect]))
    #expect(applied.captions[0].style.fontSize == 58)
    #expect(applied.canvas.cursorScale == 0.8)
    #expect(applied.canvas.cursorClickEmphasis == false)
    #expect(applied.canvas.cursorHalo == true)
    #expect(applied.cursorEffects[0].clickEmphasis == false)
    #expect(applied.cursorEffects[0].halo == true)
    #expect(applied.videoExportSettings.resolution == .p2160)
    #expect(applied.appliedPresetIDs == [preset.id])
}

@Test
func presetApplicationLeavesUnspecifiedFamiliesUntouched() {
    let annotation = Annotation.arrow(start: 1, end: 2)
    let original = ProjectDocument(
        webcamOverlay: WebcamOverlaySettings(enabled: true, size: 0.3),
        annotations: [annotation]
    )
    let preset = EditorStylePreset(id: "export-only", name: "Export", export: .default)
    let applied = preset.applying(to: original)
    #expect(applied.webcamOverlay == original.webcamOverlay)
    #expect(applied.annotations == original.annotations)
}
