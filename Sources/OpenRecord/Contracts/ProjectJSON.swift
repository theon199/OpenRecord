import Foundation

public enum ProjectJSON: Sendable {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Compact encoder for one JSON value per line (`mouse.jsonl`, `clicks.jsonl`).
    public static var jsonlEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decode one JSON object per line. Missing files yield an empty array.
    public static func decodeJSONL<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OpenRecordError.io("Missing or unreadable \(url.lastPathComponent)")
        }
        if data.isEmpty { return [] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenRecordError.io("Invalid UTF-8 in \(url.lastPathComponent)")
        }

        var items: [T] = []
        items.reserveCapacity(256)
        let decoder = decoder
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            do {
                items.append(try decoder.decode(T.self, from: lineData))
            } catch {
                throw OpenRecordError.io(
                    "Invalid \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return items
    }
}
