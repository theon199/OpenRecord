import Foundation

/// Quality of the optional per-stream sequence field found while reading a
/// telemetry JSONL file. Legacy streams have no sequence field.
public enum TelemetrySequenceQuality: String, Codable, Sendable, Hashable {
    case unavailable
    case legacy
    case complete
    case missing
    case nonMonotonic = "non-monotonic"
    case duplicate
    case gapped
    case mixed

    public static var valid: Self { .complete }
    public static var strict: Self { .complete }
    public static var monotonic: Self { .complete }
    public static var strictlyMonotonic: Self { .complete }
    public static var absent: Self { .legacy }
    public static var notPresent: Self { .legacy }
    public static var invalid: Self { .mixed }

    public var isMonotonic: Bool {
        switch self {
        case .unavailable, .legacy, .complete, .missing, .gapped:
            return true
        case .nonMonotonic, .duplicate, .mixed:
            return false
        }
    }

    public var isComplete: Bool { self == .complete || self == .legacy }
}

/// Summary returned by streaming JSONL reads.
public struct JSONLReadReport: Codable, Sendable, Hashable {
    public var recordCount: Int
    public var byteCount: Int64
    public var firstTimestamp: TimeInterval?
    public var lastTimestamp: TimeInterval?
    public var truncatedFinalLine: Bool
    public var sequenceQuality: TelemetrySequenceQuality

    public init(
        recordCount: Int = 0,
        byteCount: Int64 = 0,
        firstTimestamp: TimeInterval? = nil,
        lastTimestamp: TimeInterval? = nil,
        truncatedFinalLine: Bool = false,
        sequenceQuality: TelemetrySequenceQuality = .unavailable
    ) {
        self.recordCount = max(recordCount, 0)
        self.byteCount = max(byteCount, 0)
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.truncatedFinalLine = truncatedFinalLine
        self.sequenceQuality = sequenceQuality
    }

    public var count: Int { recordCount }
    public var records: Int { recordCount }
    public var bytesRead: Int64 { byteCount }
    public var bytes: Int64 { byteCount }
    public var firstT: TimeInterval? { firstTimestamp }
    public var lastT: TimeInterval? { lastTimestamp }
    public var isTruncated: Bool { truncatedFinalLine }
    public var sequenceStatus: TelemetrySequenceQuality { sequenceQuality }
}

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

    /// Stream one JSON object per line without loading the source file into
    /// memory. Missing and empty files produce an empty report. Blank lines
    /// are ignored. A malformed terminated/interior line throws; a malformed
    /// unterminated final line is reported as a crash-truncated tail.
    @discardableResult
    public static func streamJSONL<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        chunkSize: Int = 64 * 1024,
        _ receive: (T) throws -> Void
    ) throws -> JSONLReadReport {
        var accumulator = JSONLReadAccumulator()
        let totalBytes = try scanJSONLLines(from: url, chunkSize: chunkSize) { line in
            let value: T
            do {
                value = try decoder.decode(T.self, from: line.data)
            } catch {
                if line.terminated {
                    throw OpenRecordError.io(
                        "Invalid " + url.lastPathComponent + ": " + error.localizedDescription
                    )
                }
                accumulator.truncatedFinalLine = true
                return
            }
            accumulator.add(line: line)
            try receive(value)
        }
        accumulator.byteCount = totalBytes
        return accumulator.report
    }

    /// Callback spelling for clients that prefer an explicit iteration name.
    @discardableResult
    public static func forEachJSONL<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        chunkSize: Int = 64 * 1024,
        _ receive: (T) throws -> Void
    ) throws -> JSONLReadReport {
        try streamJSONL(type, from: url, chunkSize: chunkSize, receive)
    }

    /// Explicitly named alias for clients that distinguish streaming reads
    /// from the array-returning legacy `decodeJSONL` API.
    @discardableResult
    public static func decodeJSONLStreaming<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        chunkSize: Int = 64 * 1024,
        _ receive: (T) throws -> Void
    ) throws -> JSONLReadReport {
        try streamJSONL(type, from: url, chunkSize: chunkSize, receive)
    }

    /// Deliver bounded record chunks while retaining the same tolerant final
    /// line behavior as `streamJSONL`.
    @discardableResult
    public static func decodeJSONLChunks<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        recordsPerChunk: Int = 512,
        chunkSize: Int = 64 * 1024,
        _ receive: ([T]) throws -> Void
    ) throws -> JSONLReadReport {
        let capacity = max(recordsPerChunk, 1)
        var chunk: [T] = []
        chunk.reserveCapacity(capacity)
        let report = try streamJSONL(type, from: url, chunkSize: chunkSize) { value in
            chunk.append(value)
            if chunk.count >= capacity {
                try receive(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try receive(chunk) }
        return report
    }

    /// Decode one JSON object per line. Missing files yield an empty array.
    /// This routes through the bounded-memory reader for legacy callers.
    public static func decodeJSONL<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        var items: [T] = []
        items.reserveCapacity(256)
        try streamJSONL(type, from: url) { items.append($0) }
        return items
    }
}

// MARK: - Streaming implementation

/// Internal representation shared by the public reader and telemetry index.
/// `data` is trimmed of line whitespace while offsets and lengths describe the
/// original source bytes.
struct JSONLScanLine: Sendable {
    let data: Data
    let offset: UInt64
    let byteLength: UInt64
    let terminated: Bool
}

/// Scan UTF-8 lines using a fixed-size read buffer. This intentionally does
/// not decode JSON; typed readers and the index apply their own validation.
@discardableResult
func scanJSONLLines(
    from url: URL,
    startOffset: UInt64 = 0,
    chunkSize: Int = 64 * 1024,
    _ receive: (JSONLScanLine) throws -> Void
) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw OpenRecordError.io("Missing or unreadable " + url.lastPathComponent)
    }
    defer { try? handle.close() }

    if startOffset > 0 {
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            throw OpenRecordError.io("Could not seek " + url.lastPathComponent)
        }
    }

    let readSize = max(chunkSize, 1)
    var pending = Data()
    pending.reserveCapacity(readSize)
    var pendingOffset: UInt64 = startOffset
    var totalBytes: UInt64 = 0

    while true {
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: readSize)
        } catch {
            throw OpenRecordError.io("Could not read " + url.lastPathComponent)
        }
        guard let chunk, !chunk.isEmpty else { break }
        pending.append(chunk)
        totalBytes += UInt64(chunk.count)

        while let newline = pending.firstIndex(of: 0x0A) {
            let end = Int(newline)
            let raw = Data(pending[pending.startIndex..<newline])
            let lineLength = end + 1
            pending.removeSubrange(
                pending.startIndex..<pending.index(pending.startIndex, offsetBy: lineLength)
            )
            let lineOffset = pendingOffset
            pendingOffset += UInt64(lineLength)
            guard let data = try normalizedJSONLLine(raw, url: url, terminated: true) else { continue }
            try receive(JSONLScanLine(
                data: data,
                offset: lineOffset,
                byteLength: UInt64(lineLength),
                terminated: true
            ))
        }
    }

    if !pending.isEmpty {
        let raw = pending
        pending.removeAll(keepingCapacity: false)
        if let data = try normalizedJSONLLine(raw, url: url, terminated: false) {
            try receive(JSONLScanLine(
                data: data,
                offset: pendingOffset,
                byteLength: UInt64(raw.count),
                terminated: false
            ))
        }
    }
    return Int64(clamping: totalBytes)
}

private func normalizedJSONLLine(
    _ raw: Data,
    url: URL,
    terminated: Bool
) throws -> Data? {
    guard let text = String(data: raw, encoding: .utf8) else {
        if terminated {
            throw OpenRecordError.io("Invalid UTF-8 in " + url.lastPathComponent)
        }
        // Preserve an invalid unterminated tail as a callback line. Typed
        // readers will classify it as a truncated final record.
        return Data()
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let data = trimmed.data(using: .utf8) else {
        if terminated {
            throw OpenRecordError.io("Invalid UTF-8 in " + url.lastPathComponent)
        }
        return Data()
    }
    return data
}

private struct JSONLReadAccumulator {
    var recordCount = 0
    var byteCount: Int64 = 0
    var firstTimestamp: TimeInterval?
    var lastTimestamp: TimeInterval?
    var truncatedFinalLine = false
    var sawSequence = false
    var missingSequence = false
    var nonMonotonic = false
    var duplicate = false
    var gapped = false
    var previousSequence: UInt64?

    mutating func add(line: JSONLScanLine) {
        recordCount += 1
        byteCount += Int64(clamping: line.byteLength)
        guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else {
            return
        }
        if let t = object["t"] as? NSNumber {
            let value = t.doubleValue
            if value.isFinite {
                if firstTimestamp == nil { firstTimestamp = value }
                lastTimestamp = value
            }
        }
        guard let rawSequence = object["sequence"] as? NSNumber else {
            missingSequence = true
            return
        }
        sawSequence = true
        guard rawSequence.int64Value >= 0 else {
            nonMonotonic = true
            return
        }
        let sequence = rawSequence.uint64Value
        if let previousSequence {
            if sequence < previousSequence { nonMonotonic = true }
            if sequence == previousSequence { duplicate = true }
            if previousSequence == UInt64.max || sequence != previousSequence + 1 { gapped = true }
        } else if sequence != 0 {
            gapped = true
        }
        previousSequence = sequence
    }

    var report: JSONLReadReport {
        let quality: TelemetrySequenceQuality
        if recordCount == 0 {
            quality = .unavailable
        } else if !sawSequence {
            quality = .legacy
        } else if missingSequence {
            quality = .mixed
        } else if nonMonotonic {
            quality = .nonMonotonic
        } else if duplicate {
            quality = .duplicate
        } else if gapped {
            quality = .gapped
        } else {
            quality = .complete
        }
        return JSONLReadReport(
            recordCount: recordCount,
            byteCount: byteCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            truncatedFinalLine: truncatedFinalLine,
            sequenceQuality: quality
        )
    }
}
