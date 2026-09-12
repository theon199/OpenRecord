import Foundation
import OpenRecord
import Testing

@Test("v4.3 recipes reject unknown and unsafe fields")
func v43RecipeStrictSafety() throws {
    let unknown = Data(#"{"formatVersion":1,"outputs":[{"name":"demo","kind":"video","remoteURL":"https://example.invalid"}]}"#.utf8)
    #expect(throws: (any Error).self) {
        try ProjectJSON.decoder.decode(PublishRecipe.self, from: unknown)
    }

    let unsafe = PublishRecipe(outputs: [PublishOutput(
        name: "../demo",
        kind: .video
    )])
    #expect(throws: (any Error).self) {
        try unsafe.validated()
    }

    let duplicate = PublishRecipe(outputs: [
        PublishOutput(name: "Demo", kind: .video),
        PublishOutput(name: "demo", kind: .gif),
    ])
    #expect(throws: (any Error).self) {
        try duplicate.validated()
    }

    #expect(throws: (any Error).self) {
        try PublishRecipe(outputs: [
            PublishOutput(name: "tutorial", kind: .tutorial, codec: .proRes422),
        ]).validated()
    }
}

@Test("v4.3 recipe encoding is stable and round trips")
func v43RecipeRoundTrip() throws {
    let recipe = PublishRecipe(outputs: [
        PublishOutput(
            name: "release-demo",
            kind: .video,
            aspect: .widescreen,
            codec: .hevc,
            resolution: .p1080,
            quality: .high,
            frameRate: .fps30,
            captionDelivery: .both,
            filename: "release-demo.mp4",
            overwrite: .replace,
            screenshots: .poster,
            includeTranscript: true,
            safeArea: Rect2D(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        ),
        PublishOutput(
            name: "guide",
            kind: .markdown,
            aspect: .standard,
            screenshots: .actions
        ),
    ])
    let first = try ProjectJSON.encoder.encode(recipe)
    let decoded = try ProjectJSON.decoder.decode(PublishRecipe.self, from: first)
    let second = try ProjectJSON.encoder.encode(decoded)
    #expect(recipe == decoded)
    #expect(first == second)
    #expect(String(decoding: first, as: UTF8.self).contains("remote") == false)
    #expect(decoded.outputs[0].safeArea == Rect2D(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
    #expect(PublishOutput(name: "master", kind: .video, codec: .proRes422).effectiveFilename == "master.mov")
}

@Test("v4.3 render variants preserve source content and bound story beats")
func v43RenderPlanAspectsAndBounds() throws {
    let beatID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
    let beat = StoryBeat(
        id: beatID,
        start: 8,
        end: 14,
        kind: .step,
        title: "Save theme"
    )
    let sourceDecision = EditDecision(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!,
        start: 2,
        end: 3
    )
    let project = ProjectDocument(
        trimOut: 20,
        editDecisions: [sourceDecision],
        storyBeats: [beat]
    )
    let recipe = PublishRecipe(outputs: [
        PublishOutput(name: "wide", kind: .video, aspect: .widescreen),
        PublishOutput(
            name: "social",
            kind: .video,
            aspect: .portrait,
            storyBeat: "Save theme",
            maxDuration: 4,
            codec: .hevc
        ),
        PublishOutput(name: "preview", kind: .video, aspect: .square),
        PublishOutput(name: "standard", kind: .video, aspect: .standard),
    ])
    let plan = try RenderPlan(project: project, recipe: recipe, sourceDuration: 20)
    #expect(plan.variants.map { $0.recipeOutput.name } == ["wide", "social", "preview", "standard"])
    #expect(plan.variants[0].derivedDocument.editDecisions == project.editDecisions)
    #expect(plan.variants[0].derivedDocument.canvas.aspectWidth == 16)
    #expect(plan.variants[1].derivedDocument.canvas.aspectWidth == 9)
    #expect(plan.variants[1].derivedDocument.canvas.aspectHeight == 16)
    #expect(plan.variants[1].selectedStoryBeat?.id == beatID)
    #expect(plan.variants[1].derivedDocument.trimIn == 8)
    #expect(plan.variants[1].derivedDocument.trimOut ?? 0 <= 14)
    #expect(plan.variants[1].outputDuration <= 4.000_001)
    #expect(plan.variants[2].derivedDocument.canvas.aspectWidth == 1)
    #expect(plan.variants[3].derivedDocument.canvas.aspectHeight == 3)
}

@Test("v4.3 semantic focus and responsive zooms are deterministic")
func v43SemanticFocusDeterminism() throws {
    let actionID = try AnalysisEvidenceID("action-043")
    let action = ActionCandidate(
        id: actionID,
        start: 2,
        end: 3,
        kind: .click,
        label: "Save",
        bounds: Rect2D(x: 0.72, y: 0.30, width: 0.12, height: 0.10),
        confidence: 1,
        evidenceSources: [.semantic],
        evidenceIDs: [actionID]
    )
    let locked = ZoomRange(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000045")!,
        start: 7,
        end: 8,
        amount: 2,
        anchor: Point2D(x: 0.5, y: 0.5),
        isLocked: true
    )
    let project = ProjectDocument(trimOut: 10, zoomRanges: [locked])
    let recipe = PublishRecipe(outputs: [
        PublishOutput(name: "social", kind: .video, aspect: .portrait),
    ])
    let first = try RenderPlan(project: project, recipe: recipe, actions: [action], sourceDuration: 10)
    let second = try RenderPlan(project: project, recipe: recipe, actions: [action], sourceDuration: 10)
    let variant = first.variants[0]
    #expect(variant.semanticFocusBounds == [action.bounds!])
    #expect(variant.derivedDocument.zoomRanges.contains(locked))
    #expect(variant.derivedDocument.zoomRanges == second.variants[0].derivedDocument.zoomRanges)
    #expect(variant.derivedDocument.zoomRanges.contains { !$0.isLocked && $0.source == .automatic })
}

@Test("v4.3 protected regions remain normalized and contained")
func v43ProtectedRegionContainment() throws {
    let project = ProjectDocument(
        trimOut: 8,
        webcamOverlay: WebcamOverlaySettings(
            enabled: true,
            position: Point2D(x: 0.99, y: 0.99),
            size: 0.55
        ),
        captions: [CaptionCue(start: 1, end: 2, text: "Caption")],
        annotations: [Annotation.spotlight(start: 1, end: 2, rect: Rect2D(x: 0.8, y: 0.8, width: 0.8, height: 0.8))],
        redactions: [RedactionRegion(start: 1, end: 2, rect: Rect2D(x: 0.95, y: 0.95, width: 0.8, height: 0.8))]
    )
    let recipe = PublishRecipe(outputs: [
        PublishOutput(name: "portrait", kind: .video, aspect: .portrait),
    ])
    let plan = try RenderPlan(project: project, recipe: recipe, sourceDuration: 8)
    #expect(plan.protectedRegionsAreContained)
    #expect(try plan.validateProtectedRegions())
    #expect(plan.variants[0].derivedDocument.webcamOverlay.position.x < 0.99)
    #expect(plan.variants[0].protectedRegions.contains { $0.kind == RenderPlanProtectedRegion.Kind.redaction })
}

@Test("v4.3 protected region escaping safe area is rejected")
func v43ProtectedRegionEscapesSafeArea() throws {
    let project = ProjectDocument(
        trimOut: 8,
        redactions: [RedactionRegion(start: 1, end: 2, rect: Rect2D(x: 0.02, y: 0.02, width: 0.05, height: 0.05))]
    )
    let recipe = PublishRecipe(outputs: [
        PublishOutput(
            name: "confined",
            kind: .video,
            safeArea: Rect2D(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
    ])
    #expect(throws: (any Error).self) {
        try RenderPlan(project: project, recipe: recipe, sourceDuration: 8)
    }
}

@Test("v4.3 ProRes filename and recipe constraints")
func v43ProResFilenameAndConstraints() throws {
    let proResOutput = PublishOutput(name: "master", kind: .video, codec: .proRes422)
    #expect(proResOutput.effectiveFilename == "master.mov")

    let h264Output = PublishOutput(name: "standard", kind: .video, codec: .h264)
    #expect(h264Output.effectiveFilename == "standard.mp4")

    let tutorialOutput = PublishOutput(name: "guide", kind: .tutorial)
    #expect(tutorialOutput.effectiveFilename == "guide.openrecordweb")

    // manifest.json reserved
    let recipeManifest = PublishRecipe(outputs: [
        PublishOutput(name: "manifest", kind: .video, filename: "manifest.json")
    ])
    #expect(throws: (any Error).self) {
        try recipeManifest.validated()
    }

    // tutorial filename extension
    let badTutorial = PublishRecipe(outputs: [
        PublishOutput(name: "bad", kind: .tutorial, filename: "bad.zip")
    ])
    #expect(throws: (any Error).self) {
        try badTutorial.validated()
    }
}

enum V43RecipeRenderPlanSuite {
    static func run() throws {
        try v43RecipeStrictSafety()
        try v43RecipeRoundTrip()
        try v43RenderPlanAspectsAndBounds()
        try v43SemanticFocusDeterminism()
        try v43ProtectedRegionContainment()
        try v43ProtectedRegionEscapesSafeArea()
        try v43ProResFilenameAndConstraints()
    }
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordV43RecipeRenderPlanTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunV43RecipeRenderPlanTests()
}

@_cdecl("OpenRecordRunV43RecipeRenderPlanTests")
func OpenRecordRunV43RecipeRenderPlanTests() {
    do {
        try V43RecipeRenderPlanSuite.run()
        fputs("OpenRecordTests: v4.3 Recipe and RenderPlan tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs(
            "OpenRecordTests: v4.3 Recipe and RenderPlan tests failed: \(error.localizedDescription)\n",
            stderr
        )
        abort()
    }
}
#endif
