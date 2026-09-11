import Foundation

/// Atomically replaces selected rebuildable analysis streams while preserving
/// every other well-formed v1 stream. An analyzer owns only the sidecars it
/// supplies; ActionMap, First Cut, and Privacy Firewall can therefore refresh
/// independently without discarding one another's local evidence.
public extension AnalysisStore {
    func updateSidecars(
        _ updates: [AnalysisSidecarKind: Data],
        analyzerVersion: String,
        appVersion: String,
        fingerprints: [AnalysisSourceFingerprint]? = nil,
        warnings: [String] = []
    ) throws {
        var sidecars: [AnalysisSidecarKind: Data] = [:]
        var summaries: [AnalysisSidecarKind: AnalysisSidecarSummary] = [:]
        let previousManifest = try? readManifest()

        for kind in AnalysisSidecarKind.allCases where updates[kind] == nil {
            guard let data = try? readSidecar(kind: kind), Self.isWellFormedJSONL(data) else {
                continue
            }
            sidecars[kind] = data
            summaries[kind] = Self.summary(for: data)
        }
        for (kind, data) in updates {
            guard Self.isWellFormedJSONL(data) else {
                throw AnalysisStoreError.invalidSidecar("Invalid \(kind.fileName)")
            }
            sidecars[kind] = data
            summaries[kind] = Self.summary(for: data)
        }

        let indexURL = ProjectLayout.analysisIndexURL(in: projectURL)
        let index = try? Data(contentsOf: indexURL)
        let mergedWarnings = Self.stableUnique((previousManifest?.warnings ?? []) + warnings)
        let manifest = AnalysisManifest(
            analyzerVersion: String(analyzerVersion.prefix(128)),
            appVersion: appVersion,
            fingerprints: fingerprints ?? previousManifest?.fingerprints ?? [],
            locale: previousManifest?.locale,
            modelRevision: previousManifest?.modelRevision,
            apiRevision: previousManifest?.apiRevision,
            completionState: .complete,
            warnings: mergedWarnings,
            sidecars: summaries
        )
        try write(manifest: manifest, sidecars: sidecars, index: index)
    }

    private static func summary(for data: Data) -> AnalysisSidecarSummary {
        let count = data.split(separator: 0x0A).reduce(into: 0) { result, line in
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                result += 1
            }
        }
        return AnalysisSidecarSummary(
            recordCount: count,
            byteCount: Int64(data.count),
            chunkCount: count == 0 ? 0 : 1,
            indexPath: ProjectLayout.analysisDirectoryName + "/" + ProjectLayout.analysisIndexFileName
        )
    }

    private static func isWellFormedJSONL(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let bytes = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes),
                  object is [String: Any]
            else { return false }
        }
        return true
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
