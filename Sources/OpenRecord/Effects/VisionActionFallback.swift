@preconcurrency import AVFoundation
import Foundation
import Vision

/// Privacy boundary for locally recognized OCR evidence.
///
/// The fallback samples frames locally and persists only text-region geometry,
/// confidence, and a fixed degradation reason. Recognized strings are never
/// retained because OCR cannot prove that visible text is a static control
/// label rather than ordinary user-authored text.
public struct VisionActionFallback: Sendable {
    public static let defaultMaximumEvidenceCount = 32

    public let maximumEvidenceCount: Int

    public init(maximumEvidenceCount: Int = VisionActionFallback.defaultMaximumEvidenceCount) {
        self.maximumEvidenceCount = max(0, maximumEvidenceCount)
    }

    public func filter(_ evidence: [ActionOCREvidence]) -> [ActionOCREvidence] {
        Self.filtered(evidence, maximumCount: maximumEvidenceCount)
    }

    /// Samples a bounded set of capture-clock timestamps and asks Vision only
    /// for text-region geometry. Recognized strings are never requested or
    /// persisted because an OCR engine cannot reliably distinguish a static
    /// control label from ordinary text the user just typed.
    public func analyze(
        videoURL: URL,
        timestamps: [TimeInterval]
    ) async throws -> [ActionOCREvidence] {
        guard maximumEvidenceCount > 0,
              FileManager.default.fileExists(atPath: videoURL.path)
        else { return [] }

        let sampleTimes = Self.boundedSampleTimes(
            timestamps,
            maximumCount: maximumEvidenceCount
        )
        guard !sampleTimes.isEmpty else { return [] }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 900)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        var evidence: [ActionOCREvidence] = []
        for (frameIndex, time) in sampleTimes.enumerated() {
            if evidence.count >= maximumEvidenceCount { break }
            try Task.checkCancellation()
            let image = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            ).image
            let observations = try Self.textRegions(in: image)
            for (regionIndex, observation) in observations.enumerated() {
                guard evidence.count < maximumEvidenceCount else { break }
                let id = try AnalysisEvidenceID(
                    "ocr-frame-\(frameIndex)-region-\(regionIndex)"
                )
                let box = observation.boundingBox
                evidence.append(ActionOCREvidence(
                    id: id,
                    t: time,
                    bounds: Rect2D(
                        x: box.minX,
                        y: 1 - box.maxY,
                        width: box.width,
                        height: box.height
                    ),
                    label: nil,
                    confidence: Double(observation.confidence),
                    degradationReason: .labelFiltered
                ))
            }
        }
        return filter(evidence)
    }

    public static func filtered(
        _ evidence: [ActionOCREvidence],
        maximumCount: Int = VisionActionFallback.defaultMaximumEvidenceCount
    ) -> [ActionOCREvidence] {
        let limit = max(0, maximumCount)
        guard limit > 0 else { return [] }

        // Sorting by time and the opaque evidence reference keeps Vision's
        // detector order from affecting an analysis cache. The label is never
        // consulted while choosing the bounded subset.
        var seen = Set<AnalysisEvidenceID>()
        return evidence
            .map(sanitized)
            .sorted {
                if $0.t != $1.t { return $0.t < $1.t }
                return $0.id.rawValue < $1.id.rawValue
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Makes one safe OCR row from an untrusted Vision label. This overload is
    /// useful for adapters that produce raw strings without retaining them in
    /// the on-disk evidence model.
    public static func makeEvidence(
        id: AnalysisEvidenceID,
        t: TimeInterval,
        bounds: Rect2D,
        label: String?,
        confidence: Double
    ) -> ActionOCREvidence {
        sanitized(ActionOCREvidence(
            id: id,
            t: t,
            bounds: bounds,
            label: label,
            confidence: confidence
        ))
    }

    private static func sanitized(_ input: ActionOCREvidence) -> ActionOCREvidence {
        var output = input
        output.t = input.t.isFinite ? max(input.t, 0) : 0
        output.bounds = SemanticPrivacyFilter.normalizedBounds(input.bounds)
        output.confidence = input.confidence.isFinite
            ? min(max(input.confidence, 0), 1)
            : 0

        // OCR has no trustworthy semantic role. Even apparently harmless text
        // may be ordinary text typed into an editor, so raw OCR strings never
        // cross this persistence boundary. Accessibility remains the only
        // source for allowlisted static-control labels.
        output.label = nil
        output.degradationReason = .labelFiltered
        return output
    }

    private static func boundedSampleTimes(
        _ timestamps: [TimeInterval],
        maximumCount: Int
    ) -> [TimeInterval] {
        var seen = Set<Int64>()
        return timestamps
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
            .filter { seen.insert(Int64(($0 * 1_000).rounded())).inserted }
            .prefix(max(0, maximumCount))
            .map { $0 }
    }

    private static func textRegions(in image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).sorted {
            let lhs = $0.boundingBox
            let rhs = $1.boundingBox
            if lhs.minY != rhs.minY { return lhs.minY > rhs.minY }
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
    }
}
