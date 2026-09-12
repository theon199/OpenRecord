import Foundation

/// A normalized, typed region that must remain visible and contained when a
/// responsive variant is rendered.
public struct RenderPlanProtectedRegion: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case redaction
        case webcam
        case caption
        case annotation
    }

    public var kind: Kind
    public var rect: Rect2D
    public var identifier: String?

    public init(kind: Kind, rect: Rect2D, identifier: String? = nil) {
        self.kind = kind
        self.rect = rect
        self.identifier = identifier
    }

    public var isNormalizedAndContained: Bool {
        RenderPlan.isContained(rect)
    }

    public var isContained: Bool { isNormalizedAndContained }
}

/// One ephemeral responsive rendering variant. It deliberately owns a copy
/// of the project document, so constructing a plan never mutates author data.
public struct RenderPlanVariant: Sendable, Hashable {
    public let recipeOutput: PublishOutput
    public let derivedDocument: ProjectDocument
    public let selectedStoryBeat: StoryBeat?
    public let semanticFocusBounds: [Rect2D]
    public let outputDuration: TimeInterval
    public let protectedRegions: [RenderPlanProtectedRegion]
    public let safeArea: Rect2D

    public var output: PublishOutput { recipeOutput }
    public var publishOutput: PublishOutput { recipeOutput }
    public var recipe: PublishOutput { recipeOutput }
    public var document: ProjectDocument { derivedDocument }
    public var storyBeat: StoryBeat? { selectedStoryBeat }
    public var focusBounds: [Rect2D] { semanticFocusBounds }
    public var safeRegions: [RenderPlanProtectedRegion] { protectedRegions }

    public var protectedRegionsAreContained: Bool {
        protectedRegions.allSatisfy(\.isNormalizedAndContained)
            && RenderPlan.isContained(safeArea)
            && protectedRegions.allSatisfy { region in
                region.rect.x >= safeArea.x - 0.000_001
                    && region.rect.y >= safeArea.y - 0.000_001
                    && region.rect.x + region.rect.width <= safeArea.x + safeArea.width + 0.000_001
                    && region.rect.y + region.rect.height <= safeArea.y + safeArea.height + 0.000_001
            }
    }

    public var areProtectedRegionsContained: Bool { protectedRegionsAreContained }
    public var safeAreaIsValid: Bool { protectedRegionsAreContained }

    public init(
        recipeOutput: PublishOutput,
        derivedDocument: ProjectDocument,
        selectedStoryBeat: StoryBeat?,
        semanticFocusBounds: [Rect2D],
        outputDuration: TimeInterval,
        protectedRegions: [RenderPlanProtectedRegion],
        safeArea: Rect2D = .unit
    ) {
        self.recipeOutput = recipeOutput
        self.derivedDocument = derivedDocument
        self.selectedStoryBeat = selectedStoryBeat
        self.semanticFocusBounds = semanticFocusBounds
        self.outputDuration = outputDuration
        self.protectedRegions = protectedRegions
        self.safeArea = safeArea
    }

    /// Throws if an output geometry would escape normalized canvas coordinates.
    @discardableResult
    public func validateProtectedRegions() throws -> Bool {
        guard protectedRegionsAreContained else {
            throw OpenRecordError.io(
                "Render plan protected region escaped the normalized canvas for output \(recipeOutput.name)."
            )
        }
        return true
    }

    public func validateSafeArea() throws {
        try validateProtectedRegions()
    }

    public func validateSafeAreas() throws {
        try validateProtectedRegions()
    }
}

/// An ephemeral, deterministic set of output variants derived from one
/// authored project and one portable publish recipe.
public struct RenderPlan: Sendable, Hashable {
    public static let renderVersion = 1

    public let variants: [RenderPlanVariant]

    public init(
        project: ProjectDocument,
        recipe: PublishRecipe,
        actions: [ActionCandidate] = [],
        sourceDuration: TimeInterval
    ) throws {
        guard sourceDuration.isFinite, sourceDuration >= 0 else {
            throw OpenRecordError.io("Render plan sourceDuration must be finite and non-negative.")
        }
        let validatedRecipe = try recipe.validated()
        let orderedActions = actions
            .map(\.normalized)
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.rawValue < $1.id.rawValue
            }

        var built: [RenderPlanVariant] = []
        built.reserveCapacity(validatedRecipe.outputs.count)
        for output in validatedRecipe.outputs {
            let selected = try Self.selectStoryBeat(output.storyBeat, from: project.storyBeats)
            let bounds = Self.semanticBounds(
                output: output,
                selectedStoryBeat: selected,
                document: project,
                actions: orderedActions,
                sourceDuration: sourceDuration
            )
            let document = try Self.derivedDocument(
                from: project,
                output: output,
                selectedStoryBeat: selected,
                sourceDuration: sourceDuration,
                semanticBounds: bounds,
                actions: orderedActions
            )
            let mapper = ProjectTimeMapper(project: document, sourceDuration: sourceDuration)
            let regions = Self.protectedRegions(in: document)
            let variant = RenderPlanVariant(
                recipeOutput: output,
                derivedDocument: document,
                selectedStoryBeat: selected,
                semanticFocusBounds: bounds,
                outputDuration: mapper.outputDuration,
                protectedRegions: regions,
                safeArea: output.safeArea ?? .unit
            )
            try variant.validateProtectedRegions()
            built.append(variant)
        }
        variants = built
    }

    public var renderPlanVersion: Int { Self.renderVersion }

    public var protectedRegionsAreContained: Bool {
        variants.allSatisfy(\.protectedRegionsAreContained)
    }

    public var areProtectedRegionsContained: Bool { protectedRegionsAreContained }

    @discardableResult
    public func validateProtectedRegions() throws -> Bool {
        for variant in variants { try variant.validateProtectedRegions() }
        return true
    }

    public func validateSafeAreas() throws {
        try validateProtectedRegions()
    }
}

private extension RenderPlan {
    static func selectStoryBeat(
        _ selector: String?,
        from beats: [StoryBeat]
    ) throws -> StoryBeat? {
        guard let selector else { return nil }
        let cleaned = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw OpenRecordError.io("Render plan storyBeat selector cannot be empty.")
        }
        let matches = beats.filter { beat in
            guard !beat.isSuppressed else { return false }
            return beat.id.uuidString.caseInsensitiveCompare(cleaned) == .orderedSame
                || beat.title.caseInsensitiveCompare(cleaned) == .orderedSame
        }
        guard let selected = matches.sorted(by: storyBeatOrder).first else {
            throw OpenRecordError.io("Render plan storyBeat selector \(cleaned) did not match a project story beat.")
        }
        return selected
    }

    static func storyBeatOrder(_ lhs: StoryBeat, _ rhs: StoryBeat) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func semanticBounds(
        output: PublishOutput,
        selectedStoryBeat: StoryBeat?,
        document: ProjectDocument,
        actions: [ActionCandidate],
        sourceDuration: TimeInterval
    ) -> [Rect2D] {
        let actionFocused = output.aspect == .portrait
            || output.aspect == .square
            || output.screenshots == .actions
            || output.kind == .markdown
            || output.kind == .html
            || output.kind == .tutorial
        guard actionFocused else { return [] }
        let lower = max(document.trimIn.isFinite ? document.trimIn : 0, 0)
        let upper = min(
            (document.trimOut?.isFinite == true ? document.trimOut! : sourceDuration),
            sourceDuration
        )
        return actions.compactMap { action in
            guard let rawBounds = action.bounds else { return nil }
            let normalized = SemanticPrivacyFilter.normalizedBounds(rawBounds)
            guard normalized.width > 0, normalized.height > 0 else { return nil }
            let overlapsStoryBeat: Bool
            if let selectedStoryBeat {
                overlapsStoryBeat = action.end > selectedStoryBeat.start
                    && action.start < selectedStoryBeat.end
            } else {
                overlapsStoryBeat = action.end > lower && action.start < upper
            }
            guard overlapsStoryBeat else { return nil }
            return normalized
        }
    }

    static func derivedDocument(
        from source: ProjectDocument,
        output: PublishOutput,
        selectedStoryBeat: StoryBeat?,
        sourceDuration: TimeInterval,
        semanticBounds: [Rect2D],
        actions: [ActionCandidate]
    ) throws -> ProjectDocument {
        var value: ProjectDocument
        if let templateID = output.templateID {
            guard let template = ProjectTemplate.builtIns.first(where: { $0.id == templateID }) else {
                throw OpenRecordError.io("Render plan references unknown portable template \(templateID).")
            }
            value = template.applying(to: source)
        } else {
            value = source
        }
        output.aspect.apply(to: &value.canvas)
        var export = value.videoExportSettings
        if output.kind == .tutorial {
            export.codec = .h264
        } else if let codec = output.codec {
            export.codec = codec
        }
        if let resolution = output.resolution { export.resolution = resolution }
        if let quality = output.quality { export.quality = quality }
        if let frameRate = output.frameRate { export.frameRate = frameRate }
        value.videoExportSettings = export
        switch output.captionDelivery {
        case .none, .sidecar:
            value.captions = []
        case .burnedIn, .both:
            break
        }

        let sourceStart = min(
            max(source.trimIn.isFinite ? source.trimIn : 0, 0),
            sourceDuration
        )
        let sourceEnd = min(
            max(source.trimOut?.isFinite == true ? source.trimOut! : sourceDuration, sourceStart),
            sourceDuration
        )
        var trimStart = sourceStart
        var trimEnd = sourceEnd
        if let selectedStoryBeat {
            trimStart = min(max(selectedStoryBeat.start, sourceStart), sourceEnd)
            trimEnd = min(max(selectedStoryBeat.end, trimStart), sourceEnd)
        }
        if let maxDuration = output.maxDuration {
            trimEnd = sourceEndForOutputDuration(
                sourceDuration: sourceDuration,
                trimIn: trimStart,
                trimOut: trimEnd,
                maximumOutputDuration: maxDuration,
                source: source
            )
        }
        if selectedStoryBeat != nil || output.maxDuration != nil {
            value.trimIn = trimStart
            value.trimOut = trimEnd
        }

        // Semantic zooms are additive. In particular, authored locked zooms
        // are copied byte-for-byte and never replaced by responsive framing.
        if shouldAddSemanticZooms(output: output), !semanticBounds.isEmpty {
            let range = selectedStoryBeat.map { (start: $0.start, end: $0.end) }
            let generated = generatedZooms(
                bounds: semanticBounds,
                actions: actions,
                sourceDuration: sourceDuration,
                output: output,
                selectedRange: range,
                clipStart: value.trimIn,
                clipEnd: value.trimOut ?? sourceDuration,
                existing: value.zoomRanges
            )
            value.zoomRanges.append(contentsOf: generated)
            value.zoomRanges.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        value.webcamOverlay = clampWebcam(
            value.webcamOverlay,
            aspect: output.aspect,
            safeArea: output.safeArea ?? .unit
        )
        return value
    }

    static func sourceEndForOutputDuration(
        sourceDuration: TimeInterval,
        trimIn: TimeInterval,
        trimOut: TimeInterval,
        maximumOutputDuration: TimeInterval,
        source: ProjectDocument
    ) -> TimeInterval {
        guard trimOut > trimIn else { return trimIn }
        let current = ProjectTimeMapper(
            sourceDuration: sourceDuration,
            trimIn: trimIn,
            trimOut: trimOut,
            editDecisions: source.editDecisions,
            speedSegments: source.speedSegments
        ).outputDuration
        guard current > maximumOutputDuration else { return trimOut }
        var low = trimIn
        var high = trimOut
        // Output duration is monotonic as source end advances. Fixed
        // iterations make the result independent of machine floating-point
        // iteration counts and avoid any clock/date/randomness.
        for _ in 0..<64 {
            let middle = low + (high - low) / 2
            let duration = ProjectTimeMapper(
                sourceDuration: sourceDuration,
                trimIn: trimIn,
                trimOut: middle,
                editDecisions: source.editDecisions,
                speedSegments: source.speedSegments
            ).outputDuration
            if duration > maximumOutputDuration {
                high = middle
            } else {
                low = middle
            }
        }
        return low
    }

    static func shouldAddSemanticZooms(output: PublishOutput) -> Bool {
        output.aspect == .portrait || output.aspect == .square || output.screenshots == .actions
    }

    static func generatedZooms(
        bounds: [Rect2D],
        actions: [ActionCandidate],
        sourceDuration: TimeInterval,
        output: PublishOutput,
        selectedRange: (start: TimeInterval, end: TimeInterval)?,
        clipStart: TimeInterval,
        clipEnd: TimeInterval,
        existing: [ZoomRange]
    ) -> [ZoomRange] {
        // A bounds list is generated from the stable action ordering. Pairing
        // through candidates again would make duplicate bounds ambiguous, so
        // use the first matching candidate for each normalized rect.
        var result: [ZoomRange] = []
        var used = Set<String>()
        for bound in bounds {
            guard let action = actions.first(where: { candidate in
                guard let candidateBounds = candidate.bounds else { return false }
                let normalized = SemanticPrivacyFilter.normalizedBounds(candidateBounds)
                return normalized == bound
                    && !used.contains(candidate.id.rawValue + "|" + output.name)
                    && (selectedRange == nil
                        || (candidate.end > selectedRange!.start && candidate.start < selectedRange!.end))
            }) else { continue }
            let key = action.id.rawValue + "|" + output.name
            guard used.insert(key).inserted else { continue }
            let start = min(max(action.start, max(0, clipStart)), min(sourceDuration, clipEnd))
            let end = min(max(action.end, start), min(sourceDuration, clipEnd))
            guard end > start else { continue }
            let overlapsLocked = existing.contains {
                $0.isLocked && $0.end > start && $0.start < end
            }
            guard !overlapsLocked else { continue }
            let amount = semanticZoomAmount(bound, aspect: output.aspect)
            result.append(ZoomRange(
                id: stableZoomID(key: key, start: start, end: end),
                start: start,
                end: end,
                amount: amount,
                anchor: Point2D(
                    x: bound.x + bound.width / 2,
                    y: bound.y + bound.height / 2
                ),
                tracking: .fixed,
                isLocked: false,
                source: .automatic
            ))
        }
        return result
    }

    static func semanticZoomAmount(_ rect: Rect2D, aspect: PublishAspect) -> Double {
        let margin: Double = aspect == .portrait ? 2.4 : aspect == .square ? 2.2 : 2.0
        let width = max(rect.width * margin, 0.12)
        let height = max(rect.height * margin, 0.12)
        let amount = min(5, max(1.25, min(1 / width, 1 / height)))
        return amount
    }

    static func stableZoomID(key: String, start: TimeInterval, end: TimeInterval) -> UUID {
        let seed = key + "|" + String(format: "%.9f", start) + "|" + String(format: "%.9f", end)
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_951_162_821_1
        for byte in seed.utf8 {
            first ^= UInt64(byte)
            first &*= 1_099_511_628_211
            second ^= UInt64(byte)
            second &*= 2_654_435_761
        }
        let hex = String(format: "%016llx%016llx", first, second)
        let uuidText = String(hex.prefix(8)) + "-"
            + String(hex.dropFirst(8).prefix(4)) + "-4"
            + String(hex.dropFirst(13).prefix(3)) + "-a"
            + String(hex.dropFirst(16).prefix(3)) + "-"
            + String(hex.dropFirst(19).prefix(12))
        return UUID(uuidString: uuidText) ?? UUID(uuidString: "00000000-0000-4000-a000-000000000000")!
    }

    static func clampWebcam(
        _ raw: WebcamOverlaySettings,
        aspect: PublishAspect,
        safeArea: Rect2D
    ) -> WebcamOverlaySettings {
        guard raw.enabled else { return raw }
        var value = raw.normalized
        let ratio = max(aspect.width / aspect.height, 0.000_001)
        let halfWidth: Double
        let halfHeight: Double
        if ratio >= 1 {
            halfWidth = value.size / (2 * ratio)
            halfHeight = value.size / 2
        } else {
            halfWidth = value.size / 2
            halfHeight = value.size * ratio / 2
        }
        let x = value.position.x.isFinite ? value.position.x : 0.5
        let y = value.position.y.isFinite ? value.position.y : 0.5
        let minX = safeArea.x + halfWidth
        let maxX = safeArea.x + safeArea.width - halfWidth
        let minY = safeArea.y + halfHeight
        let maxY = safeArea.y + safeArea.height - halfHeight
        value.position.x = min(max(x, minX), max(maxX, minX))
        value.position.y = min(max(y, minY), max(maxY, minY))
        return value
    }

    static func protectedRegions(in document: ProjectDocument) -> [RenderPlanProtectedRegion] {
        var regions: [RenderPlanProtectedRegion] = []
        for redaction in document.redactions where redaction.end > redaction.start {
            regions.append(RenderPlanProtectedRegion(
                kind: .redaction,
                rect: NormalizedCanvasGeometry.rect(redaction.rect),
                identifier: redaction.id.uuidString
            ))
        }
        if document.webcamOverlay.enabled {
            let webcam = document.webcamOverlay.normalized
            let aspect = max(document.canvas.aspectWidth / max(document.canvas.aspectHeight, 0.000_001), 0.000_001)
            let halfWidth = aspect >= 1 ? webcam.size / (2 * aspect) : webcam.size / 2
            let halfHeight = aspect >= 1 ? webcam.size / 2 : webcam.size * aspect / 2
            regions.append(RenderPlanProtectedRegion(
                kind: .webcam,
                rect: NormalizedCanvasGeometry.rect(Rect2D(
                    x: webcam.position.x - halfWidth,
                    y: webcam.position.y - halfHeight,
                    width: halfWidth * 2,
                    height: halfHeight * 2
                ))
            ))
        }
        for caption in document.captions where caption.end > caption.start {
            let style = caption.style.normalized
            let center = style.position.defaultAnchor
            let captionWidth = min(style.maxWidth, 0.90)
            let captionHeight: Double = 0.08
            let y: Double
            switch style.position {
            case .top:
                y = center.y
            case .center:
                y = center.y - captionHeight / 2
            case .bottom:
                y = min(center.y - captionHeight / 2, 0.90 - captionHeight)
            }
            regions.append(RenderPlanProtectedRegion(
                kind: .caption,
                rect: NormalizedCanvasGeometry.rect(Rect2D(
                    x: min(max(center.x - captionWidth / 2, 0.05), 0.95 - captionWidth),
                    y: max(0.05, min(y, 0.95 - captionHeight)),
                    width: captionWidth,
                    height: captionHeight
                )),
                identifier: caption.id.uuidString
            ))
        }
        for annotation in document.annotations where annotation.end > annotation.start {
            let normalized = annotation.normalized
            let rect: Rect2D
            switch normalized.kind {
            case .spotlight, .box, .underline, .label:
                rect = normalized.rect
            case .arrow:
                let minX = min(normalized.position.x, normalized.endPosition.x)
                let minY = min(normalized.position.y, normalized.endPosition.y)
                rect = Rect2D(
                    x: minX,
                    y: minY,
                    width: max(abs(normalized.endPosition.x - normalized.position.x), 0.02),
                    height: max(abs(normalized.endPosition.y - normalized.position.y), 0.02)
                )
            case .text, .stepMarker:
                rect = Rect2D(
                    x: normalized.position.x - 0.08,
                    y: normalized.position.y - 0.05,
                    width: 0.16,
                    height: 0.10
                )
            }
            regions.append(RenderPlanProtectedRegion(
                kind: .annotation,
                rect: NormalizedCanvasGeometry.rect(rect),
                identifier: normalized.id.uuidString
            ))
        }
        return regions
    }

    static func isContained(_ rect: Rect2D) -> Bool {
        rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height >= 0
            && rect.x >= -0.000_001 && rect.y >= -0.000_001
            && rect.x + rect.width <= 1.000_001
            && rect.y + rect.height <= 1.000_001
    }
}
