import CoreFoundation
import Foundation

/// Same-directory temp file + `replaceItemAt` / `rename` so a crash cannot
/// leave a truncated `meta.json` / `project.json`.
enum AtomicFileWrite {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OpenRecordError.io(
                "Could not create directory \(directory.path): \(error.localizedDescription)"
            )
        }

        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tempURL, options: [.atomic])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(
                    url,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                do {
                    try fm.moveItem(at: tempURL, to: url)
                } catch {
                    _ = try fm.replaceItemAt(
                        url,
                        withItemAt: tempURL,
                        backupItemName: nil,
                        options: []
                    )
                }
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw OpenRecordError.io(
                "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// Atomically replaces or installs a directory destination from a staging area.
    static func installDirectory(
        staging: URL,
        destination: URL,
        fileManager fm: FileManager = .default
    ) throws {
        if fm.fileExists(atPath: destination.path) {
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: backup)
            do {
                try fm.moveItem(at: staging, to: destination)
                try? fm.removeItem(at: backup)
            } catch {
                try? fm.moveItem(at: backup, to: destination)
                throw error
            }
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data: Data
        do {
            data = try ProjectJSON.encoder.encode(value)
        } catch {
            throw OpenRecordError.io(
                "Could not encode \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
        try write(data, to: url)
    }

    /// Encode and atomically install a project document while enforcing the
    /// migration policy against both the in-memory candidate and any existing
    /// on-disk schema. Nested fields unknown to this build are preserved when
    /// the surrounding current-schema document can otherwise be decoded.
    static func writeProjectDocument(_ document: ProjectDocument, to url: URL) throws {
        let validated = try document.validatedForSave()
        let encoded: Data
        do {
            encoded = try ProjectJSON.encoder.encode(validated)
        } catch {
            throw OpenRecordError.io(
                "Could not encode \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }

        let fm = FileManager.default
        let data: Data
        if fm.fileExists(atPath: url.path) {
            let existing: Data
            do {
                existing = try Data(contentsOf: url)
            } catch {
                throw OpenRecordError.io(
                    "Could not inspect existing \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
            data = try ProjectDocumentPersistence.dataForReplacement(
                existing: existing,
                encoded: encoded
            )
        } else {
            data = encoded
        }
        try write(data, to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OpenRecordError.io("Missing or unreadable \(url.lastPathComponent)")
        }
        do {
            return try ProjectJSON.decoder.decode(type, from: data)
        } catch {
            throw OpenRecordError.io(
                "Invalid \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    package static func unsupportedEnumValues(in root: [String: Any]) -> [String] {
        ProjectDocumentPersistence.unsupportedEnumValues(in: root)
    }
}

private enum ProjectDocumentPersistence {
    static func dataForReplacement(existing: Data, encoded: Data) throws -> Data {
        guard let existingRoot = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
        else {
            // Syntactically truncated documents are repairable because there
            // is no parseable schema or unknown data that could be preserved.
            return encoded
        }

        let version = existingRoot["formatVersion"] as? Int ?? 1
        guard version <= ProjectDocument.currentFormatVersion else {
            throw OpenRecordError.io(
                "This project uses format version \(version), but this version of OpenRecord supports up to version \(ProjectDocument.currentFormatVersion). Update OpenRecord before saving it."
            )
        }

        let unknownTopLevelFields = existingRoot.keys
            .filter { !ProjectDocument.supportedTopLevelFieldNames.contains($0) }
            .sorted()
        guard unknownTopLevelFields.isEmpty else {
            let fields = unknownTopLevelFields.joined(separator: ", ")
            if version < ProjectDocument.currentFormatVersion {
                throw OpenRecordError.io(
                    "This legacy format version \(version) project contains unsupported fields: \(fields). It can be opened read-only, but saving was refused to avoid discarding them."
                )
            }
            throw OpenRecordError.io(
                "This project contains unsupported fields for format version \(version): \(fields). Update OpenRecord before saving it."
            )
        }

        let unsupportedEnumValues = unsupportedEnumValues(in: existingRoot)
        guard unsupportedEnumValues.isEmpty else {
            throw OpenRecordError.io(
                "This project contains unsupported enum values or malformed edit decisions: "
                    + unsupportedEnumValues.joined(separator: ", ")
                    + ". It can be opened read-only when possible, but saving was refused to avoid discarding them."
            )
        }

        guard (try? ProjectJSON.decoder.decode(ProjectDocument.self, from: existing)) != nil,
              let encodedRoot = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            // Parseable JSON with malformed known fields is intentionally
            // repairable by replacing it with a validated in-memory document.
            return encoded
        }

        var mergedRoot = encodedRoot
        for (key, newValue) in encodedRoot {
            if let oldValue = existingRoot[key] {
                mergedRoot[key] = mergeNested(
                    existing: oldValue,
                    replacement: newValue,
                    path: [key]
                )
            }
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: mergedRoot,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw OpenRecordError.io(
                "Could not preserve supported project fields: \(error.localizedDescription)"
            )
        }
    }

    private static func mergeNested(
        existing: Any,
        replacement: Any,
        path: [String]
    ) -> Any {
        if let oldObject = existing as? [String: Any],
           let newObject = replacement as? [String: Any]
        {
            // Synthesized enum payloads use a single case key. Changing the
            // canvas background case must replace the old case rather than
            // produce an invalid object containing both enum cases.
            if path == ["canvas", "background"],
               oldObject.count == 1,
               newObject.count == 1,
               oldObject.keys.first != newObject.keys.first
            {
                return newObject
            }

            var result = oldObject
            for (key, newValue) in newObject {
                if let oldValue = oldObject[key] {
                    result[key] = mergeNested(
                        existing: oldValue,
                        replacement: newValue,
                        path: path + [key]
                    )
                } else {
                    result[key] = newValue
                }
            }
            return result
        }

        if let oldArray = existing as? [Any],
           let newArray = replacement as? [Any]
        {
            var existingByID: [String: [String: Any]] = [:]
            for case let item as [String: Any] in oldArray {
                if let id = item["id"] as? String {
                    existingByID[stableIDKey(id)] = item
                }
            }
            guard !existingByID.isEmpty else { return newArray }
            return newArray.map { newItem in
                guard let object = newItem as? [String: Any],
                      let id = object["id"] as? String,
                      let oldObject = existingByID[stableIDKey(id)]
                else {
                    return newItem
                }
                return mergeNested(
                    existing: oldObject,
                    replacement: object,
                    path: path + ["[]"]
                )
            }
        }

        return replacement
    }

    /// Foundation encodes UUID strings using uppercase hex even when the
    /// existing JSON used lowercase. Treat equivalent UUID spellings as the
    /// same stable identity so nested future fields survive the replacement.
    private static func stableIDKey(_ raw: String) -> String {
        UUID(uuidString: raw)?.uuidString.lowercased() ?? raw
    }

    static func unsupportedEnumValues(in root: [String: Any]) -> [String] {
        var issues: [String] = []

        func check(
            _ value: Any?,
            at path: String,
            allowed: Set<String>
        ) {
            guard let rawValue = value as? String,
                  !allowed.contains(rawValue)
            else {
                return
            }
            issues.append("\(path)=\(rawValue)")
        }

        func isJSONBool(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        func finiteNumber(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, !isJSONBool(number) else { return false }
            return number.doubleValue.isFinite
        }

        func checkRequiredBool(_ object: [String: Any], _ key: String, at path: String) {
            guard isJSONBool(object[key]) else {
                issues.append("\(path)=<missing-or-non-bool>")
                return
            }
        }

        check(
            root["autoZoomSensitivity"],
            at: "autoZoomSensitivity",
            allowed: ["subtle", "normal", "aggressive"]
        )
        check(
            root["zoomEasing"],
            at: "zoomEasing",
            allowed: ["fast", "smooth", "cinematic"]
        )

        if let keyboard = root["keyboardOverlay"] as? [String: Any] {
            check(keyboard["style"], at: "keyboardOverlay.style", allowed: ["pill"])
            check(
                keyboard["position"],
                at: "keyboardOverlay.position",
                allowed: ["bottom-center", "bottom-left"]
            )
        }
        if let webcam = root["webcamOverlay"] as? [String: Any] {
            check(
                webcam["shape"],
                at: "webcamOverlay.shape",
                allowed: ["circle", "rounded-rectangle", "squircle"]
            )
        }
        if let deviceFrame = root["deviceFrame"] as? [String: Any] {
            check(
                deviceFrame["id"],
                at: "deviceFrame.id",
                allowed: ["none", "generic-laptop-dark", "generic-phone-dark", "generic-browser-light"]
            )
        }
        if let canvas = root["canvas"] as? [String: Any],
           let background = canvas["background"] as? [String: Any]
        {
            for key in background.keys where !["solid", "linearGradient"].contains(key) {
                issues.append("canvas.background=\(key)")
            }
        }
        if let exportSettings = root["videoExportSettings"] as? [String: Any] {
            check(
                exportSettings["codec"],
                at: "videoExportSettings.codec",
                allowed: ["h264", "hevc", "prores-422"]
            )
            check(
                exportSettings["resolution"],
                at: "videoExportSettings.resolution",
                allowed: ["720p", "1080p", "4k", "source"]
            )
            if let quality = exportSettings["quality"] {
                check(
                    quality,
                    at: "videoExportSettings.quality",
                    allowed: ["compact", "balanced", "high"]
                )
            }
            if let frameRate = exportSettings["frameRate"] {
                check(
                    frameRate,
                    at: "videoExportSettings.frameRate",
                    allowed: ["auto", "60", "50", "30", "25", "24", "15"]
                )
            }
        }
        if let defaultCaptionStyle = root["defaultCaptionStyle"] as? [String: Any] {
            check(
                defaultCaptionStyle["position"],
                at: "defaultCaptionStyle.position",
                allowed: ["top", "center", "bottom"]
            )
        }
        if let captions = root["captions"] as? [[String: Any]] {
            for (index, caption) in captions.enumerated() {
                let style = caption["style"] as? [String: Any]
                check(
                    style?["position"],
                    at: "captions[\(index)].style.position",
                    allowed: ["top", "center", "bottom"]
                )
            }
        }
        if let annotations = root["annotations"] as? [[String: Any]] {
            for (index, annotation) in annotations.enumerated() {
                check(
                    annotation["kind"],
                    at: "annotations[\(index)].kind",
                    allowed: ["text", "arrow", "spotlight", "box", "underline", "step-marker", "label"]
                )
                if let animation = annotation["animation"] as? [String: Any] {
                    check(
                        animation["entrance"],
                        at: "annotations[\(index)].animation.entrance",
                        allowed: ["none", "fade", "pop"]
                    )
                    check(
                        animation["exit"],
                        at: "annotations[\(index)].animation.exit",
                        allowed: ["none", "fade", "pop"]
                    )
                }
            }
        }
        if let redactions = root["redactions"] as? [[String: Any]] {
            for (index, redaction) in redactions.enumerated() {
                check(
                    redaction["mode"],
                    at: "redactions[\(index)].mode",
                    allowed: ["blur", "pixelate"]
                )
            }
        }
        if let drawings = root["drawings"] as? [[String: Any]] {
            for (index, drawing) in drawings.enumerated() {
                check(
                    drawing["tool"],
                    at: "drawings[\(index)].tool",
                    allowed: ["pen", "highlighter"]
                )
            }
        }
        if let rawStoryBeats = root["storyBeats"] {
            guard let storyBeats = rawStoryBeats as? [Any] else {
                issues.append("storyBeats=<non-array>")
                return issues.sorted()
            }
            for (index, rawStoryBeat) in storyBeats.enumerated() {
                guard let storyBeat = rawStoryBeat as? [String: Any] else {
                    issues.append("storyBeats[\(index)]=<non-object>")
                    continue
                }
                let prefix = "storyBeats[\(index)]"
                if let id = storyBeat["id"] as? String, UUID(uuidString: id) != nil {
                    // Stable identity is required for nested-field preservation.
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                for field in ["start", "end"] {
                    guard finiteNumber(storyBeat[field]) else {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                        continue
                    }
                }
                if let kind = storyBeat["kind"] as? String {
                    check(kind, at: "\(prefix).kind", allowed: ["action", "chapter", "step", "marker"])
                } else {
                    issues.append("\(prefix).kind=<missing-or-non-string>")
                }
                if !(storyBeat["title"] is String) {
                    issues.append("\(prefix).title=<missing-or-non-string>")
                }
                checkRequiredBool(storyBeat, "isLocked", at: "\(prefix).isLocked")
                checkRequiredBool(storyBeat, "isSuppressed", at: "\(prefix).isSuppressed")
            }
        }
        if let rawDecisions = root["editDecisions"] {
            guard let decisions = rawDecisions as? [Any] else {
                issues.append("editDecisions=<non-array>")
                return issues.sorted()
            }
            for (index, rawDecision) in decisions.enumerated() {
                guard let decision = rawDecision as? [String: Any] else {
                    issues.append("editDecisions[\(index)]=<non-object>")
                    continue
                }
                let prefix = "editDecisions[\(index)]"
                if let id = decision["id"] as? String,
                   UUID(uuidString: id) != nil
                {
                    // Valid stable identity.
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                for field in ["start", "end"] {
                    guard finiteNumber(decision[field]) else {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                        continue
                    }
                }
                if let kind = decision["kind"] as? String {
                    check(kind, at: "\(prefix).kind", allowed: ["exclude"])
                } else {
                    issues.append("\(prefix).kind=<missing-or-non-string>")
                }
            }
        }
        if let rawSpeeds = root["speedSegments"] {
            guard let speeds = rawSpeeds as? [Any] else {
                issues.append("speedSegments=<non-array>")
                return issues.sorted()
            }
            for (index, rawSpeed) in speeds.enumerated() {
                guard let speed = rawSpeed as? [String: Any] else {
                    issues.append("speedSegments[\(index)]=<non-object>")
                    continue
                }
                let prefix = "speedSegments[\(index)]"
                if let id = speed["id"] as? String, UUID(uuidString: id) != nil {
                    // Valid stable identity
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                for field in ["start", "end", "rate"] {
                    guard finiteNumber(speed[field]) else {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                        continue
                    }
                }
            }
        }
        if let rawSprites = root["cursorSprites"] {
            guard let sprites = rawSprites as? [Any] else {
                issues.append("cursorSprites=<non-array>")
                return issues.sorted()
            }
            for (index, rawSprite) in sprites.enumerated() {
                guard let sprite = rawSprite as? [String: Any] else {
                    issues.append("cursorSprites[\(index)]=<non-object>")
                    continue
                }
                let prefix = "cursorSprites[\(index)]"
                if !(sprite["id"] is String) {
                    issues.append("\(prefix).id=<missing-or-non-string>")
                }
                if !(sprite["pngRelativePath"] is String) {
                    issues.append("\(prefix).pngRelativePath=<missing-or-non-string>")
                }
            }
        }

        if let rawZooms = root["zoomRanges"] {
            guard let zooms = rawZooms as? [Any] else {
                issues.append("zoomRanges=<non-array>")
                return issues.sorted()
            }
            for (index, rawZoom) in zooms.enumerated() {
                guard let zoom = rawZoom as? [String: Any] else {
                    issues.append("zoomRanges[\(index)]=<non-object>")
                    continue
                }
                let prefix = "zoomRanges[\(index)]"
                if let id = zoom["id"] as? String, UUID(uuidString: id) != nil {
                    // Stable identity is required to merge the range safely.
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                for field in ["start", "end", "amount"] {
                    if let number = zoom[field], !finiteNumber(number) {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                    } else if zoom[field] == nil {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                    }
                }
                if let anchor = zoom["anchor"] as? [String: Any] {
                    for field in ["x", "y"] {
                        if let number = anchor[field], !finiteNumber(number) {
                            issues.append("\(prefix).anchor.\(field)=<missing-or-non-number>")
                        } else if anchor[field] == nil {
                            issues.append("\(prefix).anchor.\(field)=<missing-or-non-number>")
                        }
                    }
                } else {
                    issues.append("\(prefix).anchor=<missing-or-non-object>")
                }
                if let tracking = zoom["tracking"] as? String {
                    check(tracking, at: "\(prefix).tracking", allowed: ["fixed", "followCursor"])
                } else if zoom["tracking"] != nil {
                    issues.append("\(prefix).tracking=<missing-or-non-string>")
                }
                if let source = zoom["source"] as? String {
                    check(source, at: "\(prefix).source", allowed: ["manual", "automatic"])
                } else if zoom["source"] != nil {
                    issues.append("\(prefix).source=<missing-or-non-string>")
                }
            }
        }

        if let rawTranscript = root["transcript"] {
            guard let segments = rawTranscript as? [Any] else {
                issues.append("transcript=<non-array>")
                return issues.sorted()
            }
            for (index, rawSegment) in segments.enumerated() {
                guard let segment = rawSegment as? [String: Any] else {
                    issues.append("transcript[\(index)]=<non-object>")
                    continue
                }
                let prefix = "transcript[\(index)]"
                if let rawID = segment["id"] as? String, UUID(uuidString: rawID) != nil {
                    // Stable identity is required to merge the segment safely.
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                if let start = segment["start"], !finiteNumber(start) {
                    issues.append("\(prefix).start=<missing-or-non-number>")
                } else if segment["start"] == nil {
                    issues.append("\(prefix).start=<missing-or-non-number>")
                }
                if let end = segment["end"], !finiteNumber(end) {
                    issues.append("\(prefix).end=<missing-or-non-number>")
                } else if segment["end"] == nil {
                    issues.append("\(prefix).end=<missing-or-non-number>")
                }
                if let recognized = segment["recognizedText"], !(recognized is String) {
                    issues.append("\(prefix).recognizedText=<missing-or-non-string>")
                } else if segment["recognizedText"] == nil {
                    issues.append("\(prefix).recognizedText=<missing-or-non-string>")
                }
                if let edited = segment["editedText"], !(edited is String || edited is NSNull) {
                    issues.append("\(prefix).editedText=<missing-or-non-string>")
                }
                if let confidence = segment["confidence"], !finiteNumber(confidence) {
                    issues.append("\(prefix).confidence=<missing-or-non-number>")
                }
                if let source = segment["source"] as? String {
                    check(source, at: "\(prefix).source", allowed: ["microphone", "systemAudio", "mixed"])
                } else {
                    issues.append("\(prefix).source=<missing-or-non-string>")
                }
            }
        }

        if let rawCursorEffects = root["cursorEffects"] {
            guard let effects = rawCursorEffects as? [Any] else {
                issues.append("cursorEffects=<non-array>")
                return issues.sorted()
            }
            for (index, rawEffect) in effects.enumerated() {
                guard let effect = rawEffect as? [String: Any] else {
                    issues.append("cursorEffects[\(index)]=<non-object>")
                    continue
                }
                let prefix = "cursorEffects[\(index)]"
                if let rawID = effect["id"] as? String, UUID(uuidString: rawID) != nil {
                    // Stable identity is required to merge the effect safely.
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                if let start = effect["start"], !finiteNumber(start) {
                    issues.append("\(prefix).start=<missing-or-non-number>")
                } else if effect["start"] == nil {
                    issues.append("\(prefix).start=<missing-or-non-number>")
                }
                if let end = effect["end"], !finiteNumber(end) {
                    issues.append("\(prefix).end=<missing-or-non-number>")
                } else if effect["end"] == nil {
                    issues.append("\(prefix).end=<missing-or-non-number>")
                }
                if let scale = effect["scale"], !finiteNumber(scale) {
                    issues.append("\(prefix).scale=<missing-or-non-number>")
                } else if effect["scale"] == nil {
                    issues.append("\(prefix).scale=<missing-or-non-number>")
                }
                checkRequiredBool(effect, "visible", at: "\(prefix).visible")
                checkRequiredBool(effect, "clickEmphasis", at: "\(prefix).clickEmphasis")
                checkRequiredBool(effect, "halo", at: "\(prefix).halo")
            }
        }

        if let rawPresetIDs = root["appliedPresetIDs"] {
            guard let presetIDs = rawPresetIDs as? [Any] else {
                issues.append("appliedPresetIDs=<non-array>")
                return issues.sorted()
            }
            for (index, presetID) in presetIDs.enumerated() where !(presetID is String) {
                issues.append("appliedPresetIDs[\(index)]=<non-string>")
            }
        }

        if let rawSpans = root["timelineSpans"] {
            guard let spans = rawSpans as? [Any] else {
                issues.append("timelineSpans=<non-array>")
                return issues.sorted()
            }
            for (index, rawSpan) in spans.enumerated() {
                guard let span = rawSpan as? [String: Any] else {
                    issues.append("timelineSpans[\(index)]=<non-object>")
                    continue
                }
                let prefix = "timelineSpans[\(index)]"
                if let rawID = span["id"] as? String, UUID(uuidString: rawID) != nil {
                    // Valid identity
                } else {
                    issues.append("\(prefix).id=<missing-or-invalid>")
                }
                if !(span["sourceID"] is String) {
                    issues.append("\(prefix).sourceID=<missing-or-non-string>")
                }
                for field in ["sourceStart", "sourceEnd"] {
                    if let number = span[field], !finiteNumber(number) {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                    } else if span[field] == nil {
                        issues.append("\(prefix).\(field)=<missing-or-non-number>")
                    }
                }
                if let seamTransition = span["seamTransition"] {
                    check(seamTransition, at: "\(prefix).seamTransition", allowed: ["cut", "cross-dissolve"])
                }
                if let audioMode = span["audioMode"] {
                    check(audioMode, at: "\(prefix).audioMode", allowed: ["source-audio", "crossfade", "silence"])
                }
            }
        }

        if let rawSources = root["mediaSources"] {
            guard let sources = rawSources as? [Any] else {
                issues.append("mediaSources=<non-array>")
                return issues.sorted()
            }
            for (index, rawSource) in sources.enumerated() {
                guard let source = rawSource as? [String: Any] else {
                    issues.append("mediaSources[\(index)]=<non-object>")
                    continue
                }
                let prefix = "mediaSources[\(index)]"
                if !(source["id"] is String) {
                    issues.append("\(prefix).id=<missing-or-non-string>")
                }
                if !(source["relativePath"] is String) {
                    issues.append("\(prefix).relativePath=<missing-or-non-string>")
                }
                if let health = source["captureHealth"] as? [String: Any] {
                    if let state = health["state"] {
                        check(state, at: "\(prefix).captureHealth.state", allowed: ["complete", "degraded", "failed"])
                    }
                }
            }
        }

        return issues.sorted()
    }
}
