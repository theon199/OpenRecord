import Foundation
import Testing
@testable import OpenRecord

@Test("batch queue enqueues only selected projects with per-job settings")
func batchQueueSelectionAndSettings() {
    let first = URL(fileURLWithPath: "/tmp/first.openrecord")
    let second = URL(fileURLWithPath: "/tmp/second.openrecord")
    let output = URL(fileURLWithPath: "/tmp/exports")
    let h264 = VideoExportSettings(codec: .h264, resolution: .p720)
    let proRes = VideoExportSettings(codec: .proRes422, resolution: .source)

    var queue = BatchExportQueue()
    let ids = queue.enqueue(selectedProjects: [
        BatchExportSelection(projectURL: first, outputURL: output.appendingPathComponent("first.mp4"), settings: h264),
        BatchExportSelection(projectURL: second, outputURL: output.appendingPathComponent("second.mp4"), settings: proRes),
    ])

    #expect(ids.count == 2)
    #expect(queue.jobs.map(\.projectURL) == [first, second])
    #expect(queue.jobs[0].settings == h264)
    #expect(queue.jobs[1].settings == proRes)
    #expect(queue.jobs[0].id != queue.jobs[1].id)
}

@Test("batch queue safely reorders jobs")
func batchQueueReordering() {
    var queue = BatchExportQueue()
    let urls = (1...3).map { URL(fileURLWithPath: "/tmp/\($0).openrecord") }
    for url in urls { _ = queue.enqueue(projectURL: url, outputURL: url.appendingPathExtension("mp4")) }

    let reordered = queue.reorder(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(reordered)
    #expect(queue.jobs.map(\.projectURL) == [urls[2], urls[0], urls[1]])
    let invalidSource = queue.reorder(fromOffsets: IndexSet(integer: 99), toOffset: 0)
    let invalidDestination = queue.reorder(fromOffsets: IndexSet(integer: 0), toOffset: 99)
    #expect(!invalidSource)
    #expect(!invalidDestination)
}

@Test("a failed job does not prevent the next job from starting")
func batchQueueFailureContinues() {
    var queue = BatchExportQueue()
    let first = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/fail.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/fail.mp4"))
    let second = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/next.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/next.mp4"))

    let startedFirst = queue.startNext()
    #expect(startedFirst?.id == first)
    let failedFirst = queue.markFailed(for: first, error: "encoder failed")
    #expect(failedFirst)
    #expect(queue.jobs.first(where: { $0.id == first })?.lastError == "encoder failed")
    let startedSecond = queue.startNext()
    #expect(startedSecond?.id == second)
    #expect(queue.jobs.first(where: { $0.id == first })?.status == .failed)
    #expect(queue.jobs.first(where: { $0.id == second })?.status == .running)
}

@Test("retry increments attempts and leaves successful jobs unchanged")
func batchQueueRetry() {
    var queue = BatchExportQueue()
    let failed = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/retry.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/retry.mp4"))
    let successful = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/success.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/success.mp4"))

    let startedFailed = queue.startNext()
    #expect(startedFailed?.id == failed)
    let markedFailed = queue.markFailed(for: failed, error: "temporary")
    #expect(markedFailed)
    let startedSuccessful = queue.startNext()
    #expect(startedSuccessful?.id == successful)
    let markedSuccessful = queue.markSucceeded(for: successful)
    #expect(markedSuccessful)
    let before = queue.jobs.first(where: { $0.id == successful })

    let didRetry = queue.retry(jobID: failed)
    #expect(didRetry)
    let retried = queue.jobs.first(where: { $0.id == failed })
    #expect(retried?.status == .queued)
    #expect(retried?.attemptCount == 2)
    #expect(retried?.progress == 0)
    #expect(retried?.lastError == nil)
    #expect(queue.jobs.first(where: { $0.id == successful }) == before)
    let retriedSuccess = queue.retry(jobID: successful)
    #expect(!retriedSuccess)
}

@Test("batch queue normalizes progress and ignores invalid transitions")
func batchQueueProgressAndTransitions() {
    var queue = BatchExportQueue()
    let id = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/progress.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/progress.mp4"))

    let progressBeforeStart = queue.updateProgress(for: id, progress: 0.5)
    #expect(!progressBeforeStart)
    let started = queue.startNext()
    #expect(started?.attemptCount == 1)
    let clampedProgress = queue.updateProgress(for: id, progress: 5)
    #expect(clampedProgress)
    #expect(queue.jobs[0].progress == 1)
    let ignoredNaN = queue.updateProgress(for: id, progress: .nan)
    #expect(ignoredNaN)
    #expect(queue.jobs[0].progress == 1)
    let succeeded = queue.markSucceeded(for: id)
    let lateFailure = queue.markFailed(for: id, error: "late failure")
    let lateCancel = queue.cancel(jobID: id)
    #expect(succeeded)
    #expect(!lateFailure)
    #expect(!lateCancel)
}

@Test("batch queue cancels pending and running jobs")
func batchQueueCancellation() {
    var queue = BatchExportQueue()
    let first = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/running.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/running.mp4"))
    let second = queue.enqueue(projectURL: URL(fileURLWithPath: "/tmp/pending.openrecord"), outputURL: URL(fileURLWithPath: "/tmp/pending.mp4"))

    let started = queue.startNext()
    #expect(started?.id == first)
    let cancelledFirst = queue.cancel(jobID: first)
    #expect(cancelledFirst)
    #expect(queue.jobs[0].status == .cancelled)
    let cancelledSecond = queue.cancel(jobID: second)
    #expect(cancelledSecond)
    #expect(queue.jobs[1].status == .cancelled)
    let next = queue.startNext()
    #expect(next == nil)
    queue.cancelAll()
    #expect(queue.jobs.allSatisfy { $0.status == .cancelled })
}

@Test("restored running batch jobs are requeued")
func batchQueueRestoresInterruptedJobs() throws {
    var queue = BatchExportQueue()
    let id = queue.enqueue(
        projectURL: URL(fileURLWithPath: "/tmp/interrupted.openrecord"),
        outputURL: URL(fileURLWithPath: "/tmp/interrupted.mp4")
    )
    let started = queue.startNext()
    #expect(started?.id == id)
    _ = queue.updateProgress(for: id, progress: 0.75)

    let snapshot = try JSONEncoder().encode(queue)
    var restored = try JSONDecoder().decode(BatchExportQueue.self, from: snapshot)
    #expect(restored.jobs[0].status == .queued)
    #expect(restored.jobs[0].progress == 0)
    #expect(restored.currentJobID == nil)

    let restarted = restored.startNext()
    #expect(restarted?.id == id)
    #expect(restarted?.status == .running)
}
