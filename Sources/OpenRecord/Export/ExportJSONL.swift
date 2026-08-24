import Foundation

/// Compact JSON-lines reader for capture telemetry such as `mouse.jsonl`,
/// `clicks.jsonl`, and `keys.jsonl`.
///
/// Missing or empty files decode as `[]` so export still runs without telemetry
/// (cursor overlay is then skipped).
public enum ExportJSONL: Sendable {
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> [T] {
        try ProjectJSON.decodeJSONL(type, from: url)
    }
}
