import Darwin
import Foundation
import Testing
import OpenRecord

enum ProjectDocumentJSONRoundTrip {
    static func run() throws {
        guard CanvasSettings.default.cursorScale == 0.5,
              CanvasSettings.cursorScaleRange.lowerBound == 0.1,
              CanvasSettings.default.cursorMotionBlur == .default,
              ProjectDocument().webcamOverlay == .disabled,
              ProjectDocument().speedSegments.isEmpty,
              ProjectDocument().audioCleanup == .default
        else {
            throw OpenRecordError.io("Canvas cursor defaults are incorrect")
        }

        let sprite = CursorSprite(
            id: "arrow",
            hotspot: Point2D(x: 4, y: 2),
            pngRelativePath: "recording/cursors/arrow.png",
            standardSize: Size2D(width: 32, height: 32)
        )
        let zoom = ZoomRange(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            start: 1.25,
            end: 3.5,
            amount: 2,
            anchor: Point2D(x: 0.5, y: 0.25)
        )
        let original = ProjectDocument(
            formatVersion: ProjectDocument.currentFormatVersion,
            trimIn: 0.5,
            trimOut: 12,
            zoomRanges: [zoom],
            canvas: CanvasSettings(
                background: .linearGradient(
                    start: RGBAColor(r: 0.25, g: 0.5, b: 0.75, a: 1),
                    end: RGBAColor(r: 0.75, g: 0.25, b: 0.5, a: 1),
                    startPoint: Point2D(x: 0, y: 0),
                    endPoint: Point2D(x: 1, y: 1)
                ),
                padding: 40,
                cornerRadius: 12,
                cursorScale: 1.5,
                aspectWidth: 16,
                aspectHeight: 9,
                cursorMotionBlur: CursorMotionBlurSettings(enabled: true, amount: 0.85)
            ),
            cursorSprites: [sprite],
            keyboardOverlay: KeyboardOverlaySettings(
                enabled: true,
                position: .bottomLeft,
                fadeDelay: 1.2,
                maxVisibleKeys: 4
            ),
            webcamOverlay: WebcamOverlaySettings(
                enabled: true,
                shape: .roundedRectangle,
                position: Point2D(x: 0.2, y: 0.3),
                size: 0.24,
                borderWidth: 6,
                shadow: false
            ),
            stylePresetID: "custom-demo",
            autoZoomSensitivity: .aggressive,
            zoomEasing: .cinematic,
            speedSegments: [
                SpeedSegment(
                    id: UUID(uuidString: "87654321-4321-4321-4321-cba987654321")!,
                    start: 2,
                    end: 6,
                    rate: 2.5
                )
            ],
            muteAudioWhenSpedUp: true,
            audioCleanup: AudioCleanupSettings(
                microphoneGain: 1.25,
                systemGain: 0.7,
                noiseGateEnabled: true,
                noiseGateThresholdDB: -38,
                normalizeEnabled: true,
                deClickEnabled: true
            )
        )

        let data = try ProjectJSON.encoder.encode(original)
        let decoded = try ProjectJSON.decoder.decode(ProjectDocument.self, from: data)
        guard decoded == original else {
            throw OpenRecordError.io("ProjectDocument JSON round-trip produced a different value")
        }

        try assertLegacyV1Migration()
        try assertCanvasPresetsPreserveFormatAndCursorChoices()
        try assertUndoHistoryCoalescesContinuousEdits()
    }

    private static func assertLegacyV1Migration() throws {
        let legacyJSON = Data(
            #"{"formatVersion":1,"trimIn":0.25,"zoomRanges":[],"cursorSprites":[]}"#.utf8
        )
        let legacy = try ProjectJSON.decoder.decode(ProjectDocument.self, from: legacyJSON)
        guard legacy.formatVersion == 1,
              legacy.keyboardOverlay == .disabled,
              legacy.stylePresetID == nil,
              legacy.autoZoomSensitivity == .normal,
              legacy.zoomEasing == .smooth,
              legacy.canvas.cursorMotionBlur == .disabled,
              legacy.webcamOverlay == .disabled,
              legacy.speedSegments.isEmpty,
              legacy.muteAudioWhenSpedUp == false,
              legacy.audioCleanup == .default
        else {
            throw OpenRecordError.io("A v1 project did not decode with legacy version and safe defaults")
        }

        let legacyCanvasJSON = Data(
            #"{"formatVersion":1,"canvas":{}}"#.utf8
        )
        let legacyCanvas = try ProjectJSON.decoder.decode(
            ProjectDocument.self,
            from: legacyCanvasJSON
        )
        guard legacyCanvas.canvas.cursorMotionBlur == .disabled else {
            throw OpenRecordError.io("A legacy canvas unexpectedly enabled cursor motion blur")
        }

        let upgraded = legacy.upgradedForSave()
        guard upgraded.formatVersion == 2,
              upgraded.keyboardOverlay == .disabled,
              upgraded.stylePresetID == CanvasPreset.defaultStyle.id,
              upgraded.canvas.cursorMotionBlur == .disabled
        else {
            throw OpenRecordError.io("The first-save migration did not produce the v2 defaults")
        }

        var future = upgraded
        future.formatVersion = 7
        guard future.upgradedForSave().formatVersion == 7 else {
            throw OpenRecordError.io("Saving attempted to downgrade a future project format")
        }

        let unknownPresetJSON = Data(
            #"{"formatVersion":2,"autoZoomSensitivity":"extreme","zoomEasing":"elastic"}"#.utf8
        )
        let unknownPreset = try ProjectJSON.decoder.decode(
            ProjectDocument.self,
            from: unknownPresetJSON
        )
        guard unknownPreset.autoZoomSensitivity == .normal,
              unknownPreset.zoomEasing == .smooth
        else {
            throw OpenRecordError.io("Unknown zoom presets did not fall back to safe defaults")
        }

        var unboundedBlur = ProjectDocument()
        unboundedBlur.canvas.cursorMotionBlur.amount = 3
        guard unboundedBlur.upgradedForSave().canvas.cursorMotionBlur.amount == 1 else {
            throw OpenRecordError.io("Cursor motion blur amount was not normalized on save")
        }

        var unboundedWebcam = ProjectDocument()
        unboundedWebcam.webcamOverlay = WebcamOverlaySettings(
            enabled: true,
            position: Point2D(x: -2, y: 3),
            size: 4,
            borderWidth: -1
        )
        let normalizedWebcam = unboundedWebcam.upgradedForSave().webcamOverlay
        guard normalizedWebcam.position == Point2D(x: 0, y: 1),
              normalizedWebcam.size == WebcamOverlaySettings.sizeRange.upperBound,
              normalizedWebcam.borderWidth == WebcamOverlaySettings.borderWidthRange.lowerBound
        else {
            throw OpenRecordError.io("Webcam overlay settings were not normalized on save")
        }

        var unboundedMedia = ProjectDocument()
        unboundedMedia.speedSegments = [
            SpeedSegment(start: 8, end: 4, rate: 20),
            SpeedSegment(start: 1, end: 3, rate: 0.05),
            SpeedSegment(start: 2, end: 6, rate: 2),
        ]
        unboundedMedia.audioCleanup = AudioCleanupSettings(
            microphoneGain: -1,
            systemGain: 9,
            noiseGateThresholdDB: -100
        )
        let normalizedMedia = unboundedMedia.upgradedForSave()
        guard normalizedMedia.speedSegments.count == 2,
              normalizedMedia.speedSegments[0].start == 1,
              normalizedMedia.speedSegments[0].end == 3,
              normalizedMedia.speedSegments[0].rate == SpeedSegment.rateRange.lowerBound,
              normalizedMedia.speedSegments[1].start == 3,
              normalizedMedia.speedSegments[1].end == 6,
              normalizedMedia.audioCleanup.microphoneGain == 0,
              normalizedMedia.audioCleanup.systemGain == 2,
              normalizedMedia.audioCleanup.noiseGateThresholdDB == -60
        else {
            throw OpenRecordError.io("Speed or audio cleanup settings were not normalized on save")
        }
    }

    private static func assertCanvasPresetsPreserveFormatAndCursorChoices() throws {
        let expectedIDs = ["default", "dark", "light", "minimal"]
        guard CanvasPreset.builtIns.map(\.id) == expectedIDs else {
            throw OpenRecordError.io("Canvas presets are missing or out of order")
        }

        for preset in CanvasPreset.builtIns {
            var canvas = CanvasSettings(
                cursorScale: 0.35,
                aspectWidth: 9,
                aspectHeight: 16,
                cursorMotionBlur: CursorMotionBlurSettings(enabled: true, amount: 0.9)
            )
            preset.apply(to: &canvas)
            guard canvas.background == preset.background,
                  canvas.padding == preset.padding,
                  canvas.cornerRadius == preset.cornerRadius,
                  canvas.cursorScale == 0.35,
                  canvas.cursorMotionBlur == CursorMotionBlurSettings(enabled: true, amount: 0.9),
                  canvas.aspectWidth == 9,
                  canvas.aspectHeight == 16,
                  CanvasPreset.matching(canvas) == preset
            else {
                throw OpenRecordError.io(
                    "Canvas preset \(preset.name) did not apply cleanly or changed independent settings"
                )
            }
        }
    }

    private static func assertUndoHistoryCoalescesContinuousEdits() throws {
        let original = ProjectDocument(trimIn: 0, trimOut: 12)
        var intermediate = original
        intermediate.trimIn = 1
        var edited = original
        edited.trimIn = 2

        var history = ProjectDocumentHistory()
        history.begin(document: original, actionName: "Adjust Trim")
        history.record(before: original, after: intermediate, actionName: "Adjust Trim")
        history.record(before: intermediate, after: edited, actionName: "Adjust Trim")
        history.commit(currentDocument: edited)

        guard history.canUndo,
              !history.canRedo,
              history.undoActionName == "Adjust Trim",
              history.undo(currentDocument: edited) == original,
              !history.canUndo,
              history.canRedo,
              history.redo(currentDocument: original) == edited
        else {
            throw OpenRecordError.io("Continuous document edits did not coalesce into one undo step")
        }

        guard history.undo(currentDocument: edited) == original else {
            throw OpenRecordError.io("Undo history could not restore the original document")
        }
        var divergent = original
        divergent.canvas.padding = 8
        history.record(before: original, after: divergent, actionName: "Change Padding")
        guard !history.canRedo, history.undoActionName == "Change Padding" else {
            throw OpenRecordError.io("A divergent edit did not clear the redo stack")
        }
    }
}

@Test
func projectDocumentJSONRoundTrip() throws {
    try ProjectDocumentJSONRoundTrip.run()
}

/// Mach-O constructor: CLT `swift test` dlopens the bundle without reliably
/// running Swift Testing's `@main`, so the round-trip must run at load.
#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunProjectDocumentJSONRoundTrip()
}

/// Invoked from the Mach-O constructor on test-bundle `dlopen`.
@_cdecl("OpenRecordRunProjectDocumentJSONRoundTrip")
func OpenRecordRunProjectDocumentJSONRoundTrip() {
    do {
        try ProjectDocumentJSONRoundTrip.run()
        fputs("OpenRecordTests: ProjectDocument JSON round-trip passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: ProjectDocument JSON round-trip failed\n", stderr)
        abort()
    }
}
#endif
