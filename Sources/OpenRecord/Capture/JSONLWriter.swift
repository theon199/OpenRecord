import Foundation

/// Appends compact JSON objects plus a newline. Not pretty-printed.
final class JSONLWriter<Sample: TelemetryRecord>: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var writeError: Error?
    private var nextSequence: UInt64 = 0
    private var closed = false

    init(url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw OpenRecordError.io("Could not create \(url.lastPathComponent).")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ sample: Sample) {
        // Sequence allocation, encoding, and the append are one critical
        // section. Capture callbacks arrive from different event sources and
        // must never be able to reorder or duplicate a sequence number.
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            if writeError == nil {
                writeError = OpenRecordError.io("JSONL writer is already closed.")
            }
            return
        }
        guard nextSequence < UInt64.max else {
            if writeError == nil {
                writeError = OpenRecordError.io("JSONL telemetry sequence exhausted.")
            }
            return
        }

        var sequenced = sample
        sequenced.sequence = nextSequence
        // Consume the allocation before encoding. An encoder or file handle
        // can fail after bytes have been partially written; reusing that
        // number on a later successful write would make a recovered stream
        // ambiguous rather than strictly increasing.
        nextSequence += 1
        do {
            var data = try ProjectJSON.jsonlEncoder.encode(sequenced)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            writeError = error
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        do {
            try handle.synchronize()
        } catch {
            if writeError == nil { writeError = error }
        }
        do {
            try handle.close()
        } catch {
            if writeError == nil { writeError = error }
        }
        closed = true
        lock.unlock()
    }
}
