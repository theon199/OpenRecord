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
