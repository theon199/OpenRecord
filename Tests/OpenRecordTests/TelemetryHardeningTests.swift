import Foundation
import Testing
@testable import OpenRecord

private enum TelemetryHardeningFixtures {
    static func temporaryURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenRecordTelemetry-" + name + ".jsonl"
        )
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

@Test
func telemetryRecordsKeepLegacyDefaultsAndClickCoordinates() throws {
    let legacyCursor = try ProjectJSON.decoder.decode(
        CursorSample.self,
        from: Data(#"{"t":1,"x":2,"y":3}"#.utf8)
    )
    let legacyClick = try ProjectJSON.decoder.decode(
        ClickSample.self,
        from: Data(#"{"t":1,"button":"left","down":true}"#.utf8)
    )
    #expect(legacyCursor.sequence == nil)
    #expect(legacyClick.sequence == nil)
    #expect(legacyClick.x == nil)
    #expect(legacyClick.y == nil)

    let click = ClickSample(t: 2, button: .right, down: false, x: 101.5, y: 202.25, sequence: 4)
    let decoded = try ProjectJSON.decoder.decode(
        ClickSample.self,
        from: ProjectJSON.jsonlEncoder.encode(click)
    )
    #expect(decoded == click)
}

@Test
func jsonlWriterAssignsContiguousSequencesUnderConcurrentCallbacks() throws {
    let url = TelemetryHardeningFixtures.temporaryURL("writer")
    defer { TelemetryHardeningFixtures.remove(url) }
    let writer = try JSONLWriter<CursorSample>(url: url)
    let count = 256
    DispatchQueue.concurrentPerform(iterations: count) { index in
        writer.write(CursorSample(t: Double(index), x: Double(index), y: 0))
    }
    writer.close()

    let samples = try ProjectJSON.decodeJSONL(CursorSample.self, from: url)
    let sequences = samples.compactMap(\.sequence).sorted()
    #expect(samples.count == count)
    #expect(sequences == Array(0..<UInt64(count)))
}

@Test
func streamingJSONLReportsBytesTimestampsAndIgnoresBlanks() throws {
    let url = TelemetryHardeningFixtures.temporaryURL("stream")
    defer { TelemetryHardeningFixtures.remove(url) }
    let body = "\n {\"t\":1,\"x\":2,\"y\":3,\"sequence\":0} \n\n{\"t\":4,\"x\":5,\"y\":6,\"sequence\":1}\n"
    try Data(body.utf8).write(to: url)

    var values: [CursorSample] = []
    let report = try ProjectJSON.streamJSONL(CursorSample.self, from: url, chunkSize: 2) {
        values.append($0)
    }
    #expect(values.count == 2)
    #expect(values.map(\.sequence) == [0, 1])
    #expect(report.recordCount == 2)
    #expect(report.byteCount == Int64(body.utf8.count))
    #expect(report.firstTimestamp == 1)
    #expect(report.lastTimestamp == 4)
    #expect(report.sequenceQuality == .complete)
    #expect(!report.truncatedFinalLine)
}

@Test
func malformedInteriorLineThrowsButMalformedFinalTailIsReported() throws {
    let interiorURL = TelemetryHardeningFixtures.temporaryURL("interior")
    defer { TelemetryHardeningFixtures.remove(interiorURL) }
    try Data("{\"t\":1,\"x\":2,\"y\":3}\n{bad}\n".utf8).write(to: interiorURL)
    var threw = false
    do {
        _ = try ProjectJSON.decodeJSONL(CursorSample.self, from: interiorURL)
    } catch {
        threw = true
    }
    #expect(threw)

    let finalURL = TelemetryHardeningFixtures.temporaryURL("final")
    defer { TelemetryHardeningFixtures.remove(finalURL) }
    try Data("{\"t\":1,\"x\":2,\"y\":3}\n{\"t\":2".utf8).write(to: finalURL)
    var values: [CursorSample] = []
    let report = try ProjectJSON.streamJSONL(CursorSample.self, from: finalURL, chunkSize: 1) {
        values.append($0)
    }
    #expect(values.count == 1)
    #expect(report.recordCount == 1)
    #expect(report.truncatedFinalLine)
}

@Test
func captureDiagnosticsNormalizesAndMergesLossIntervalsAndDecodesLegacy() throws {
    let diagnostics = CaptureDiagnostics(
        referenceDuration: 10,
        driftTolerance: 0.1,
        tracks: [],
        lossIntervals: [
            CaptureLossInterval(stream: .mouse, start: -2, end: 1, reason: .writerFailure),
            CaptureLossInterval(stream: .mouse, start: 1, end: 2, reason: .writerFailure),
            CaptureLossInterval(stream: .mouse, start: 4, end: 5, reason: .permissionLost),
            CaptureLossInterval(stream: .typing, start: 3, end: 3, reason: .truncated),
        ]
    )
    #expect(diagnostics.lossIntervals.count == 2)
    #expect(diagnostics.lossIntervals[0] == CaptureLossInterval(
        stream: .mouse, start: 0, end: 2, reason: .writerFailure
    ))
    #expect(diagnostics.lossIntervals[1].reason == .permissionLost)

    let legacy = Data("""
    {
      "referenceDuration":10,
      "driftTolerance":0.1,
      "tracks":[]
    }
    """.utf8)
    let decoded = try ProjectJSON.decoder.decode(CaptureDiagnostics.self, from: legacy)
    #expect(decoded.lossIntervals.isEmpty)
}

@Test
func telemetryIndexReadsBoundedRangeWithPredecessorAndRejectsStaleSources() throws {
    let sourceURL = TelemetryHardeningFixtures.temporaryURL("indexed")
    let indexURL = TelemetryHardeningFixtures.temporaryURL("indexed-index")
    defer {
        TelemetryHardeningFixtures.remove(sourceURL)
        TelemetryHardeningFixtures.remove(indexURL)
    }
    let body = (0..<5).map {
        "{\"t\":\($0),\"x\":\($0),\"y\":0,\"sequence\":\($0)}\n"
    }.joined()
    try Data(body.utf8).write(to: sourceURL)

    let index = try TelemetryIndex.rebuild(from: sourceURL, recordsPerChunk: 2)
    #expect(index.recordCount == 5)
    #expect(index.lineOffsets.count == 5)
    #expect(index.chunks.count == 3)
    try index.write(to: indexURL)
    #expect(TelemetryIndex.loadIfValid(from: indexURL, sourceURL: sourceURL) != nil)

    let range = try index.readRange(
        CursorSample.self,
        from: sourceURL,
        range: 2..<4,
        includePredecessor: true
    )
    #expect(range.predecessor?.sequence == 1)
    #expect(range.records.compactMap(\.sequence) == [2, 3])
    #expect(range.allRecords.compactMap(\.sequence) == [1, 2, 3])
    #expect(range.report.recordCount == 2)

    try Data((body + " ").utf8).write(to: sourceURL)
    #expect(TelemetryIndex.loadIfValid(from: indexURL, sourceURL: sourceURL) == nil)
}

@Test
func sparseTelemetryIndexSupportsBoundedRangeReadsWithoutMaterializingEntries() throws {
    let sourceURL = TelemetryHardeningFixtures.temporaryURL("sparse-indexed")
    let indexURL = TelemetryHardeningFixtures.temporaryURL("sparse-indexed-index")
    defer {
        TelemetryHardeningFixtures.remove(sourceURL)
        TelemetryHardeningFixtures.remove(indexURL)
    }
    let count = 10
    let body = (0..<count).map {
        "{\"t\":\($0),\"x\":\($0),\"y\":0,\"sequence\":\($0)}\n"
    }.joined()
    try Data(body.utf8).write(to: sourceURL)

    // Rebuild as sparse index
    let sparseIndex = try TelemetryIndex.rebuild(from: sourceURL, recordsPerChunk: 3, sparse: true)
    #expect(sparseIndex.isSparse)
    #expect(sparseIndex.entries.isEmpty)
    #expect(sparseIndex.recordCount == count)
    #expect(sparseIndex.chunks.count == 4)
    #expect(sparseIndex.lineOffsets.count == 4)

    try sparseIndex.write(to: indexURL)
    let loaded = TelemetryIndex.loadIfValid(from: indexURL, sourceURL: sourceURL)
    #expect(loaded != nil)
    #expect(loaded?.isSparse == true)
    #expect(loaded?.entries.isEmpty == true)

    // Test middle range read with predecessor
    let range = try loaded!.readRange(
        CursorSample.self,
        from: sourceURL,
        range: 4..<7,
        includePredecessor: true
    )
    #expect(range.predecessor?.sequence == 3)
    #expect(range.records.compactMap(\.sequence) == [4, 5, 6])
    #expect(range.allRecords.compactMap(\.sequence) == [3, 4, 5, 6])
    #expect(range.report.recordCount == 3)

    // Test start range without predecessor
    let startRange = try loaded!.readRange(
        CursorSample.self,
        from: sourceURL,
        range: 0..<2,
        includePredecessor: false
    )
    #expect(startRange.predecessor == nil)
    #expect(startRange.records.compactMap(\.sequence) == [0, 1])

    // Test end range
    let endRange = try loaded!.readRange(
        CursorSample.self,
        from: sourceURL,
        range: 8..<10,
        includePredecessor: true
    )
    #expect(endRange.predecessor?.sequence == 7)
    #expect(endRange.records.compactMap(\.sequence) == [8, 9])
}
