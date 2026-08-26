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
                allowed: ["circle", "rounded-rectangle"]
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
                    allowed: ["text", "arrow", "spotlight"]
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
                    guard let number = decision[field] as? NSNumber,
                          !(number is Bool),
                          number.doubleValue.isFinite
                    else {
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

        return issues.sorted()
    }
}
