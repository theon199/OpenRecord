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
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw OpenRecordError.io(
                "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
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
                    existingByID[id] = item
                }
            }
            guard !existingByID.isEmpty else { return newArray }
            return newArray.map { newItem in
                guard let object = newItem as? [String: Any],
                      let id = object["id"] as? String,
                      let oldObject = existingByID[id]
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

    private static func unsupportedEnumValues(in root: [String: Any]) -> [String] {
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

        func checkRequiredBool(_ object: [String: Any], _ key: String, at path: String) {
            guard isJSONBool(object[key]) else {
                issues.append("\(path)=<missing-or-non-bool>")
                return
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

        return issues.sorted()
    }
}
