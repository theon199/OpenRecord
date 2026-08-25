import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Dispatch
import Foundation
import Testing
@testable import OpenRecord

enum ExportFramePipelineTests {
    static func run() throws {
        try boundedQueuePreservesOrderAndCapacity()
        try cancellationWakesBlockedProducer()
        try softwareFallbackRendersReferenceFrame()
    }

    static func boundedQueuePreservesOrderAndCapacity() throws {
        let queue = ExportBoundedQueue<Int>(capacity: 2)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for value in 0..<24 {
                    try queue.append(value)
                }
                queue.finish()
            } catch {
                queue.finish(throwing: error)
            }
            finished.signal()
        }

        var received: [Int] = []
        while let value = try queue.next() {
            received.append(value)
        }
        guard finished.wait(timeout: .now() + 2) == .success,
              received == Array(0..<24),
              queue.maximumObservedCount <= 2
        else {
            throw OpenRecordError.io(
                "bounded export queue lost order, exceeded capacity, or failed to finish"
            )
        }
    }

    static func cancellationWakesBlockedProducer() throws {
        let queue = ExportBoundedQueue<Int>(capacity: 1)
        try queue.append(1)
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            _ = try? queue.append(2)
            stopped.signal()
        }
        guard started.wait(timeout: .now() + 1) == .success else {
            throw OpenRecordError.io("bounded export queue producer did not start")
        }
        queue.cancel()
        guard stopped.wait(timeout: .now() + 1) == .success else {
            throw OpenRecordError.io("cancellation did not wake the blocked frame producer")
        }
        do {
            _ = try queue.next()
            throw OpenRecordError.io("cancelled export queue still returned a frame")
        } catch is CancellationError {
            // Expected.
        }
        guard queue.bufferedCount == 0 else {
            throw OpenRecordError.io("cancelled export queue retained prepared frames")
        }
    }

    static func softwareFallbackRendersReferenceFrame() throws {
        let renderContext = ExportMediaIO.makeCIContext(preference: .softwareOnly)
        guard renderContext.backend == .softwareCoreImage else {
            throw OpenRecordError.io("software compositor fallback was not selected")
        }

        let width = 64
        let height = 36
        let canvas = CanvasSettings(
            background: .solid(RGBAColor(r: 0, g: 0, b: 0)),
            padding: 0,
            cornerRadius: 0,
            cursorScale: 1,
            aspectWidth: 16,
            aspectHeight: 9
        )
        let layout = ExportCanvasLayout(
            width: width,
            height: height,
            videoRect: CGRect(x: 0, y: 0, width: width, height: height),
            cornerRadius: 0,
            padding: 0
        )
        let compositor = ExportCompositor(
            context: renderContext.context,
            colorSpace: renderContext.colorSpace,
            canvas: canvas,
            keyboardOverlay: .disabled,
            webcamOverlay: .disabled,
            webcamMirror: false,
            layout: layout,
            sourceWidth: width,
            sourceHeight: height,
            displayScale: 1,
            cursorImage: nil,
            cursorSprite: nil
        )
        let buffer = try ExportMediaIO.makePixelBuffer(width: width, height: height)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        compositor.render(
            source: red,
            webcam: nil,
            cropUV: CGRect(x: 0, y: 0, width: 1, height: 1),
            cursorUV: nil,
            cursorVelocity: nil,
            clicking: false,
            clickAge: nil,
            keyboardState: KeyboardOverlayState(),
            into: buffer
        )

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw OpenRecordError.io("software compositor produced no pixel bytes")
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.assumingMemoryBound(to: UInt8.self)
            .advanced(by: (height / 2) * row + (width / 2) * 4)
        // kCVPixelFormatType_32BGRA
        guard pixel[2] >= 240, pixel[1] <= 12, pixel[0] <= 12, pixel[3] >= 240 else {
            throw OpenRecordError.io("software compositor fallback changed reference pixels")
        }
    }
}

@Test
func exportFramePipeline() throws {
    try ExportFramePipelineTests.run()
}

#if compiler(>=6.2)
@section("__DATA,__mod_init_func")
@used
let openRecordExportFramePipelineTestsModInit: @convention(c) () -> Void = {
    OpenRecordRunExportFramePipelineTests()
}

@_cdecl("OpenRecordRunExportFramePipelineTests")
func OpenRecordRunExportFramePipelineTests() {
    do {
        try ExportFramePipelineTests.run()
        fputs("OpenRecordTests: export frame pipeline tests passed\n", stderr)
        fflush(stderr)
    } catch {
        fputs("OpenRecordTests: export frame pipeline tests failed: \(error)\n", stderr)
        abort()
    }
}
#endif
