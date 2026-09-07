import CoreMedia
import Foundation

/// Maps AVCapture timestamps onto the host clock used by ScreenCaptureKit and
/// the microphone. Camera clocks can lead the host by a second or more; writing
/// those raw PTS values against the display origin makes the webcam overlay
/// lag the screen and mic during preview and export.
enum CaptureHostTimestamp: Sendable {
    /// Capture PTS may lead the host clock by a few milliseconds of jitter.
    /// Anything larger is treated as an unsynchronized session clock.
    static let futureSlop: TimeInterval = 0.25

    static func alignedPresentationTime(
        sampleTime: CMTime,
        captureClock: CMClock?,
        hostClock: CMClock,
        hostNow: CMTime
    ) -> CMTime {
        let converted: CMTime
        if let captureClock {
            converted = CMSyncConvertTime(sampleTime, from: captureClock, to: hostClock)
        } else {
            converted = sampleTime
        }
        guard converted.isNumeric else {
            return hostNow.isNumeric ? hostNow : sampleTime
        }
        guard hostNow.isNumeric else { return converted }
        let lead = CMTimeGetSeconds(CMTimeSubtract(converted, hostNow))
        if lead.isFinite, lead > futureSlop {
            return hostNow
        }
        return converted
    }

    static func replacingPresentationTime(
        _ sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard presentationTime.isNumeric else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr else { return nil }
        return copy
    }

    /// Pending camera frames are in capture order. The opener is the latest
    /// sample at or before the display origin, or the earliest sample after it
    /// when the camera is still catching up. Later post-origin frames follow.
    static func openingFrameSelection(
        times: [TimeInterval],
        origin: TimeInterval
    ) -> (opener: Int, followUp: [Int])? {
        guard origin.isFinite else { return nil }
        let valid = times.enumerated().filter { $0.element.isFinite }
        guard let opener = valid.last(where: { $0.element <= origin })?.offset
                ?? valid.first?.offset
        else {
            return nil
        }
        let followUp = valid.compactMap { item -> Int? in
            guard item.offset != opener, item.element > origin else { return nil }
            return item.offset
        }
        return (opener, followUp)
    }
}
