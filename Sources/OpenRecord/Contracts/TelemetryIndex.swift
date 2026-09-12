import CryptoKit
import Foundation

/// Content fingerprint used to reject stale telemetry indexes. The digest is
/// intentionally computed incrementally, so building or validating an index
/// does not duplicate a long JSONL file in memory.
public struct TelemetrySourceFingerprint: Codable, Sendable, Hashable {
    public let byteCount: Int64
    public let algorithm: String
    public let digest: String

    public init(byteCount: Int64, digest: String, algorithm: String = "SHA-256") {
        self.byteCount = max(0, byteCount)
        self.algorithm = algorithm
        self.digest = digest
    }

    public static func make(for url: URL, chunkSize: Int = 64 * 1024) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenRecordError.io("Missing or unreadable " + url.lastPathComponent)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw OpenRecordError.io("Missing or unreadable " + url.lastPathComponent)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        let readSize = max(chunkSize, 1)
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: readSize)
            } catch {
                throw OpenRecordError.io("Could not read " + url.lastPathComponent)
            }
            guard let chunk, !chunk.isEmpty else { break }
            guard Int64.max - byteCount >= Int64(chunk.count) else {
                throw OpenRecordError.io("Telemetry source is too large to fingerprint")
            }
            byteCount += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Self(byteCount: byteCount, digest: digest)
    }

    public func matches(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size == byteCount
        else { return false }
        guard let current = try? Self.make(for: url) else { return false }
        return current == self
    }

    public func matches(sourceURL: URL) -> Bool { matches(sourceURL) }
}

public typealias TelemetryFileFingerprint = TelemetrySourceFingerprint

/// One indexed nonblank JSONL record. `lineStart` always points at the first
/// byte of its source line, and `byteLength` includes that line's terminator.
public struct TelemetryIndexEntry: Codable, Sendable, Hashable {
    public let recordIndex: Int
    public let lineStart: UInt64
    public let byteLength: UInt64
    public let timestamp: TimeInterval?

    public init(
        recordIndex: Int,
        lineStart: UInt64,
        byteLength: UInt64,
        timestamp: TimeInterval? = nil
    ) {
        self.recordIndex = recordIndex
        self.lineStart = lineStart
        self.byteLength = byteLength
        self.timestamp = timestamp
    }

    public var offset: UInt64 { lineStart }
}

/// Summary for one contiguous index chunk.
public struct TelemetryIndexChunk: Codable, Sendable, Hashable {
    public let firstRecordIndex: Int
    public let lineStart: UInt64
    public let recordCount: Int
    public let firstTimestamp: TimeInterval?
    public let lastTimestamp: TimeInterval?

    public init(
        firstRecordIndex: Int,
        lineStart: UInt64,
        recordCount: Int,
        firstTimestamp: TimeInterval? = nil,
        lastTimestamp: TimeInterval? = nil
    ) {
        self.firstRecordIndex = firstRecordIndex
        self.lineStart = lineStart
        self.recordCount = max(0, recordCount)
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
    }

    public var offset: UInt64 { lineStart }
}

/// Result of a bounded indexed read. The predecessor is kept separate from
/// the requested records so callers can seed interpolation without changing
/// their requested range semantics.
public struct TelemetryRangeRead<Record: Decodable> {
    public let records: [Record]
    public let predecessor: Record?
    public let requestedRange: Range<Int>
    public let report: JSONLReadReport

    public init(
        records: [Record],
        predecessor: Record?,
        requestedRange: Range<Int>,
        report: JSONLReadReport
    ) {
        self.records = records
        self.predecessor = predecessor
        self.requestedRange = requestedRange
        self.report = report
    }

    public var allRecords: [Record] {
        guard let predecessor else { return records }
        return [predecessor] + records
    }
}

/// Rebuildable byte-offset index for long telemetry JSONL streams. It has no
/// dependency on ProjectLayout: callers supply any source and index URLs.
public struct TelemetryIndex: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sourceFingerprint: TelemetrySourceFingerprint
    public let recordsPerChunk: Int
    public let entries: [TelemetryIndexEntry]
    public let chunks: [TelemetryIndexChunk]
    public let truncatedFinalLine: Bool

    public init(sourceURL: URL, recordsPerChunk: Int = 512, sparse: Bool = false) throws {
        self = try Self.rebuild(from: sourceURL, recordsPerChunk: recordsPerChunk, sparse: sparse)
    }

    public static func rebuild(
        from sourceURL: URL,
        recordsPerChunk: Int = 512,
        sparse: Bool = false
    ) throws -> Self {
        let fingerprint = try TelemetrySourceFingerprint.make(for: sourceURL)
        let stride = max(recordsPerChunk, 1)
        var entries: [TelemetryIndexEntry] = []
        var chunks: [TelemetryIndexChunk] = []
        var truncatedFinalLine = false

        var currentChunkFirstIndex = 0
        var currentChunkLineStart: UInt64 = 0
        var currentChunkCount = 0
        var currentChunkFirstTimestamp: TimeInterval?
        var currentChunkLastTimestamp: TimeInterval?
        var totalRecords = 0

        try scanJSONLLines(from: sourceURL) { line in
            do {
                let object = try JSONSerialization.jsonObject(with: line.data)
                guard object is [String: Any] else {
                    throw OpenRecordError.io("Telemetry line is not a JSON object")
                }
                var timestamp: TimeInterval?
                if let object = object as? [String: Any], let number = object["t"] as? NSNumber {
                    let value = number.doubleValue
                    if value.isFinite { timestamp = value }
                }

                if !sparse {
                    entries.append(TelemetryIndexEntry(
                        recordIndex: totalRecords,
                        lineStart: line.offset,
                        byteLength: line.byteLength,
                        timestamp: timestamp
                    ))
                }

                if currentChunkCount == 0 {
                    currentChunkFirstIndex = totalRecords
                    currentChunkLineStart = line.offset
                    currentChunkFirstTimestamp = timestamp
                }
                currentChunkCount += 1
                currentChunkLastTimestamp = timestamp

                if currentChunkCount >= stride {
                    chunks.append(TelemetryIndexChunk(
                        firstRecordIndex: currentChunkFirstIndex,
                        lineStart: currentChunkLineStart,
                        recordCount: currentChunkCount,
                        firstTimestamp: currentChunkFirstTimestamp,
                        lastTimestamp: currentChunkLastTimestamp
                    ))
                    currentChunkCount = 0
                    currentChunkFirstTimestamp = nil
                    currentChunkLastTimestamp = nil
                }
                totalRecords += 1
            } catch {
                if line.terminated {
                    throw OpenRecordError.io("Invalid " + sourceURL.lastPathComponent + ": malformed JSON")
                }
                truncatedFinalLine = true
            }
        }

        if currentChunkCount > 0 {
            chunks.append(TelemetryIndexChunk(
                firstRecordIndex: currentChunkFirstIndex,
                lineStart: currentChunkLineStart,
                recordCount: currentChunkCount,
                firstTimestamp: currentChunkFirstTimestamp,
                lastTimestamp: currentChunkLastTimestamp
            ))
        }

        return Self(
            schemaVersion: currentSchemaVersion,
            sourceFingerprint: fingerprint,
            recordsPerChunk: stride,
            entries: entries,
            chunks: chunks,
            truncatedFinalLine: truncatedFinalLine
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceFingerprint
        case recordsPerChunk
        case entries
        case chunks
        case truncatedFinalLine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sourceFingerprint = try container.decode(TelemetrySourceFingerprint.self, forKey: .sourceFingerprint)
        recordsPerChunk = try container.decode(Int.self, forKey: .recordsPerChunk)
        entries = try container.decodeIfPresent([TelemetryIndexEntry].self, forKey: .entries) ?? []
        chunks = try container.decode([TelemetryIndexChunk].self, forKey: .chunks)
        truncatedFinalLine = try container.decodeIfPresent(Bool.self, forKey: .truncatedFinalLine) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encode(recordsPerChunk, forKey: .recordsPerChunk)
        try container.encode(entries, forKey: .entries)
        try container.encode(chunks, forKey: .chunks)
        try container.encode(truncatedFinalLine, forKey: .truncatedFinalLine)
    }

    private init(
        schemaVersion: Int,
        sourceFingerprint: TelemetrySourceFingerprint,
        recordsPerChunk: Int,
        entries: [TelemetryIndexEntry],
        chunks: [TelemetryIndexChunk],
        truncatedFinalLine: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.sourceFingerprint = sourceFingerprint
        self.recordsPerChunk = max(recordsPerChunk, 1)
        self.entries = entries
        self.chunks = chunks
        self.truncatedFinalLine = truncatedFinalLine
    }

    public var recordCount: Int {
        if !entries.isEmpty { return entries.count }
        return chunks.reduce(0) { $0 + $1.recordCount }
    }
    public var lineOffsets: [UInt64] {
        if !entries.isEmpty { return entries.map(\.lineStart) }
        return chunks.map(\.lineStart)
    }
    public var chunkIndex: [TelemetryIndexChunk] { chunks }
    public var sourceSize: Int64 { sourceFingerprint.byteCount }
    public var isSparse: Bool { entries.isEmpty }

    public func isValid(for sourceURL: URL) -> Bool {
        schemaVersion == Self.currentSchemaVersion && sourceFingerprint.matches(sourceURL)
    }

    public func validate(sourceURL: URL) -> Bool { isValid(for: sourceURL) }

    /// Persist an index separately from the project bundle. Callers may ignore
    /// a missing, malformed, or future index and rebuild it later.
    public func write(to indexURL: URL) throws {
        let data = try ProjectJSON.encoder.encode(self)
        try data.write(to: indexURL, options: .atomic)
    }

    public func save(to indexURL: URL) throws { try write(to: indexURL) }

    public static func loadIfValid(
        from indexURL: URL,
        sourceURL: URL
    ) -> Self? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? ProjectJSON.decoder.decode(Self.self, from: data),
              index.isValid(for: sourceURL)
        else { return nil }
        return index
    }

    public static func loadIfValid(
        indexURL: URL,
        for sourceURL: URL
    ) -> Self? {
        loadIfValid(from: indexURL, sourceURL: sourceURL)
    }

    /// Read only the requested records. When enabled, the immediately prior
    /// record is decoded separately as `predecessor`; at most range.count + 1
    /// records are held in memory.
    public func readRange<Record: Decodable>(
        _ type: Record.Type,
        from sourceURL: URL,
        range: Range<Int>,
        includePredecessor: Bool = true
    ) throws -> TelemetryRangeRead<Record> {
        guard schemaVersion == Self.currentSchemaVersion,
              let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = attrs[.size] as? Int64,
              size == sourceFingerprint.byteCount
        else {
            throw OpenRecordError.io("Telemetry index is stale or invalid")
        }
        let total = recordCount
        let lower = max(0, min(range.lowerBound, total))
        let upper = max(lower, min(range.upperBound, total))
        let requested = lower..<upper
        let firstRead = includePredecessor && lower > 0 ? lower - 1 : lower

        guard firstRead < upper else {
            return TelemetryRangeRead(
                records: [],
                predecessor: nil,
                requestedRange: requested,
                report: JSONLReadReport(recordCount: 0, byteCount: 0, sequenceQuality: .unavailable)
            )
        }

        let decoder = ProjectJSON.decoder
        var predecessor: Record?
        var records: [Record] = []
        records.reserveCapacity(requested.count)
        var accumulator = IndexedReadAccumulator()

        if !entries.isEmpty {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: sourceURL)
            } catch {
                throw OpenRecordError.io("Missing or unreadable " + sourceURL.lastPathComponent)
            }
            defer { try? handle.close() }

            for index in firstRead..<upper {
                let entry = entries[index]
                guard entry.byteLength <= UInt64(Int.max) else {
                    throw OpenRecordError.io("Telemetry record is too large to read")
                }
                do {
                    try handle.seek(toOffset: entry.lineStart)
                } catch {
                    throw OpenRecordError.io("Could not seek " + sourceURL.lastPathComponent)
                }
                guard let data = try handle.read(upToCount: Int(entry.byteLength)),
                      data.count == Int(entry.byteLength)
                else {
                    throw OpenRecordError.io("Telemetry source changed during indexed read")
                }
                do {
                    let value = try decoder.decode(Record.self, from: data)
                    if index < lower {
                        predecessor = value
                    } else {
                        records.append(value)
                        accumulator.add(data: data, byteCount: entry.byteLength)
                    }
                } catch {
                    throw OpenRecordError.io(
                        "Invalid " + sourceURL.lastPathComponent + ": " + error.localizedDescription
                    )
                }
            }
        } else {
            // Bounded-memory range read using sparse chunk metadata
            guard let startChunk = chunks.last(where: { $0.firstRecordIndex <= firstRead }) ?? chunks.first else {
                return TelemetryRangeRead(
                    records: [],
                    predecessor: nil,
                    requestedRange: requested,
                    report: JSONLReadReport(recordCount: 0, byteCount: 0, sequenceQuality: .unavailable)
                )
            }

            var currentRecordIndex = startChunk.firstRecordIndex

            do {
                try scanJSONLLines(from: sourceURL, startOffset: startChunk.lineStart) { line in
                    if currentRecordIndex == firstRead && firstRead < lower {
                        predecessor = try decoder.decode(Record.self, from: line.data)
                    } else if currentRecordIndex >= lower && currentRecordIndex < upper {
                        let value = try decoder.decode(Record.self, from: line.data)
                        records.append(value)
                        accumulator.add(data: line.data, byteCount: line.byteLength)
                    }
                    if currentRecordIndex >= upper - 1 {
                        throw TelemetryScanEarlyExit()
                    }
                    currentRecordIndex += 1
                }
            } catch is TelemetryScanEarlyExit {
                // Successfully finished reading requested range
            } catch {
                throw error
            }
        }

        return TelemetryRangeRead(
            records: records,
            predecessor: predecessor,
            requestedRange: requested,
            report: accumulator.report
        )
    }

    public func read<Record: Decodable>(
        _ type: Record.Type,
        from sourceURL: URL,
        range: Range<Int>,
        includePredecessor: Bool = true
    ) throws -> [Record] {
        try readRange(type, from: sourceURL, range: range, includePredecessor: includePredecessor).allRecords
    }

    public func readRecords<Record: Decodable>(
        _ type: Record.Type,
        from sourceURL: URL,
        range: Range<Int>,
        includePredecessor: Bool = true
    ) throws -> [Record] {
        try read(type, from: sourceURL, range: range, includePredecessor: includePredecessor)
    }
}

public typealias TelemetryChunkIndex = TelemetryIndex
public typealias JSONLIndex = TelemetryIndex

private struct IndexedReadAccumulator {
    var count = 0
    var bytes: Int64 = 0
    var firstTimestamp: TimeInterval?
    var lastTimestamp: TimeInterval?
    var sawSequence = false
    var missingSequence = false
    var nonMonotonic = false
    var duplicate = false
    var gapped = false
    var previousSequence: UInt64?

    mutating func add(data: Data, byteCount: UInt64) {
        count += 1
        bytes += Int64(clamping: byteCount)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let number = object["t"] as? NSNumber, number.doubleValue.isFinite {
            if firstTimestamp == nil { firstTimestamp = number.doubleValue }
            lastTimestamp = number.doubleValue
        }
        guard let number = object["sequence"] as? NSNumber else {
            missingSequence = true
            return
        }
        sawSequence = true
        let sequence = number.uint64Value
        if let previousSequence {
            nonMonotonic = nonMonotonic || sequence < previousSequence
            duplicate = duplicate || sequence == previousSequence
            gapped = gapped || previousSequence == UInt64.max || sequence != previousSequence + 1
        } else {
            gapped = sequence != 0
        }
        previousSequence = sequence
    }

    var report: JSONLReadReport {
        let quality: TelemetrySequenceQuality
        if count == 0 { quality = .unavailable }
        else if !sawSequence { quality = .legacy }
        else if missingSequence { quality = .mixed }
        else if nonMonotonic { quality = .nonMonotonic }
        else if duplicate { quality = .duplicate }
        else if gapped { quality = .gapped }
        else { quality = .complete }
        return JSONLReadReport(
            recordCount: count,
            byteCount: bytes,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            sequenceQuality: quality
        )
    }
}

private struct TelemetryScanEarlyExit: Error {}

