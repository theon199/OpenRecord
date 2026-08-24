@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProjectThumbnail {
    static func generateIfNeeded(in projectURL: URL) async throws -> URL? {
        let fm = FileManager.default
        let destination = ProjectLayout.thumbnailURL(in: projectURL)
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        let videoURL = ProjectLayout.displayVideoURL(in: projectURL)
        guard fm.fileExists(atPath: videoURL.path) else { return nil }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return nil }
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let targetTime: CMTime
        if durationSeconds.isFinite, durationSeconds > 0 {
            targetTime = CMTime(
                seconds: durationSeconds / 2,
                preferredTimescale: duration.timescale > 0 ? duration.timescale : 600
            )
        } else {
            targetTime = .zero
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let image: CGImage
        do {
            image = try await generator.image(at: targetTime).image
        } catch where targetTime != .zero {
            image = try await generator.image(at: .zero).image
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".thumb-\(UUID().uuidString).jpg",
            isDirectory: false
        )
        guard let imageDestination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw OpenRecordError.io("Could not create the project thumbnail encoder")
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary
        CGImageDestinationAddImage(imageDestination, image, properties)
        guard CGImageDestinationFinalize(imageDestination) else {
            try? fm.removeItem(at: temporary)
            throw OpenRecordError.io("Could not encode the project thumbnail")
        }

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw OpenRecordError.io(
                "Could not save the project thumbnail: \(error.localizedDescription)"
            )
        }
        return destination
    }
}
