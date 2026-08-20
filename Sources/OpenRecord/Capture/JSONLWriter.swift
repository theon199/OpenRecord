import Foundation

/// Appends compact JSON objects plus a newline. Not pretty-printed.
final class JSONLWriter<Sample: Encodable>: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var writeError: Error?

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
        do {
            var data = try ProjectJSON.jsonlEncoder.encode(sample)
            data.append(0x0A)
            lock.lock()
            defer { lock.unlock() }
            try handle.write(contentsOf: data)
        } catch {
            lock.lock()
            writeError = error
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}
