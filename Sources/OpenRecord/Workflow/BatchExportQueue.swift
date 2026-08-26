import Foundation

/// The lifecycle state of one project in a batch export.
public enum BatchExportJobStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

/// Shorter compatibility spelling for callers that do not need the job prefix.
public typealias BatchExportStatus = BatchExportJobStatus

/// The immutable inputs and mutable execution snapshot for one batch export.
///
/// The queue owns lifecycle transitions. Keeping a job as a value type makes
/// snapshots safe to pass between an actor/UI and an export worker without
/// coupling this domain model to the exporter itself.
public struct BatchExportJob: Identifiable, Codable, Sendable, Hashable {
    public typealias Status = BatchExportJobStatus

    public let id: UUID
    public let projectURL: URL
    public let outputURL: URL
    public var settings: VideoExportSettings
    public fileprivate(set) var status: BatchExportJobStatus
    public fileprivate(set) var progress: Double
    public fileprivate(set) var attemptCount: Int
    public fileprivate(set) var lastError: String?

    public init(
        id: UUID = UUID(),
        projectURL: URL,
        outputURL: URL,
        settings: VideoExportSettings = .default,
        status: BatchExportJobStatus = .queued,
        progress: Double = 0,
        attemptCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.projectURL = projectURL
        self.outputURL = outputURL
        self.settings = settings
        self.status = status
        self.progress = Self.normalizedProgress(progress, status: status)
        self.attemptCount = max(0, attemptCount)
        self.lastError = lastError
    }

    /// Alias used by export call sites that already call this value an export
    /// settings object.
    public var exportSettings: VideoExportSettings {
        get { settings }
        set { settings = newValue }
    }

    public var state: BatchExportJobStatus { status }
    public var error: String? { lastError }

    private static func normalizedProgress(_ value: Double, status: BatchExportJobStatus) -> Double {
        if status == .succeeded { return 1 }
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    fileprivate mutating func begin() {
        status = .running
        if attemptCount == 0 { attemptCount = 1 }
        progress = min(1, max(0, progress.isFinite ? progress : 0))
        lastError = nil
    }

    fileprivate mutating func updateProgress(_ value: Double) {
        guard value.isFinite else { return }
        // Export callbacks can arrive out of order. Never make a visible
        // progress bar move backwards because of one stale callback.
        progress = max(progress, min(1, max(0, value)))
    }

    fileprivate mutating func succeed() {
        status = .succeeded
        progress = 1
        lastError = nil
    }

    fileprivate mutating func fail(_ error: String?) {
        status = .failed
        lastError = error?.isEmpty == true ? nil : error
    }

    fileprivate mutating func cancel() {
        status = .cancelled
    }

    fileprivate mutating func retry() {
        status = .queued
        progress = 0
        attemptCount = max(0, attemptCount) + 1
        lastError = nil
    }
}

/// Inputs used when adding a selected project to a queue.
public struct BatchExportSelection: Sendable, Hashable {
    public let projectURL: URL
    public let outputURL: URL
    public let settings: VideoExportSettings

    public init(
        projectURL: URL,
        outputURL: URL,
        settings: VideoExportSettings = .default
    ) {
        self.projectURL = projectURL
        self.outputURL = outputURL
        self.settings = settings
    }
}

public typealias BatchExportProjectSelection = BatchExportSelection

/// A deterministic, exporter-agnostic queue for project exports.
///
/// At most one job can be running. This type only models state; execution,
/// cancellation of the worker, and persistence of snapshots belong to the
/// caller (typically an actor or the application model).
public struct BatchExportQueue: Codable, Sendable, Hashable {
    public private(set) var jobs: [BatchExportJob]

    private enum CodingKeys: String, CodingKey {
        case jobs
    }

    public init(jobs: [BatchExportJob] = []) {
        var seen = Set<UUID>()
        var normalized: [BatchExportJob] = []
        for var job in jobs where seen.insert(job.id).inserted {
            if job.status == .running {
                // A queue reconstructed from jobs has no corresponding export
                // worker. Requeue interrupted work so a restored snapshot can
                // always make progress instead of remaining stuck as running.
                job.status = .queued
                job.progress = 0
                job.lastError = nil
            }
            normalized.append(job)
        }
        self.jobs = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(jobs: try container.decode([BatchExportJob].self, forKey: .jobs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobs, forKey: .jobs)
    }

    public var isEmpty: Bool { jobs.isEmpty }

    public var currentJob: BatchExportJob? {
        jobs.first(where: { $0.status == .running })
    }

    public var currentJobID: UUID? { currentJob?.id }

    /// Alias useful for list-driven UI code.
    public var items: [BatchExportJob] { jobs }

    @discardableResult
    public mutating func enqueue(_ job: BatchExportJob) -> UUID? {
        guard !jobs.contains(where: { $0.id == job.id }) else { return nil }
        // An externally constructed running job cannot be inserted alongside
        // another running job. Treat it as queued until startNext is called.
        var value = job
        if currentJobID != nil, value.status == .running {
            value.status = .queued
            value.progress = 0
            value.lastError = nil
        }
        jobs.append(value)
        return value.id
    }

    @discardableResult
    public mutating func enqueue(
        projectURL: URL,
        outputURL: URL,
        settings: VideoExportSettings = .default
    ) -> UUID {
        let job = BatchExportJob(projectURL: projectURL, outputURL: outputURL, settings: settings)
        _ = enqueue(job)
        return job.id
    }

    @discardableResult
    public mutating func enqueue(
        projectURL: URL,
        outputURL: URL,
        exportSettings: VideoExportSettings
    ) -> UUID {
        enqueue(projectURL: projectURL, outputURL: outputURL, settings: exportSettings)
    }

    @discardableResult
    public mutating func enqueue(selectedProjects selections: [BatchExportSelection]) -> [UUID] {
        selections.compactMap { enqueue(BatchExportJob(projectURL: $0.projectURL, outputURL: $0.outputURL, settings: $0.settings)) }
    }

    /// Adds selected project URLs using a shared destination folder. The
    /// project bundle's filename becomes the output filename with `.mp4`.
    @discardableResult
    public mutating func enqueue(
        selectedProjects projectURLs: [URL],
        outputDirectory: URL,
        settings: VideoExportSettings = .default
    ) -> [UUID] {
        let selections = projectURLs.map { projectURL in
            let name = projectURL.deletingPathExtension().lastPathComponent
            let outputURL = outputDirectory.appendingPathComponent(name).appendingPathExtension("mp4")
            return BatchExportSelection(projectURL: projectURL, outputURL: outputURL, settings: settings)
        }
        return enqueue(selectedProjects: selections)
    }

    /// Moves jobs using SwiftUI's familiar pre-removal destination semantics.
    @discardableResult
    public mutating func reorder(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        guard !offsets.isEmpty, destination >= 0, destination <= jobs.count,
              offsets.allSatisfy({ $0 >= 0 && $0 < jobs.count }) else { return false }
        let moving = offsets.sorted().map { jobs[$0] }
        let remaining = jobs.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertion = destination - removedBeforeDestination
        guard insertion >= 0, insertion <= remaining.count else { return false }
        jobs = Array(remaining.prefix(insertion)) + moving + Array(remaining.dropFirst(insertion))
        return true
    }

    @discardableResult
    public mutating func move(jobID: UUID, to index: Int) -> Bool {
        guard let source = jobs.firstIndex(where: { $0.id == jobID }) else { return false }
        return reorder(fromOffsets: IndexSet(integer: source), toOffset: index)
    }

    /// Starts the first queued job, if no job is currently running.
    @discardableResult
    public mutating func startNext() -> BatchExportJob? {
        guard currentJobID == nil, let index = jobs.firstIndex(where: { $0.status == .queued }) else { return nil }
        jobs[index].begin()
        return jobs[index]
    }

    public mutating func startNextJob() -> BatchExportJob? { startNext() }
    public mutating func advance() -> BatchExportJob? { startNext() }
    public mutating func advanceToNext() -> BatchExportJob? { startNext() }

    @discardableResult
    public mutating func start(jobID: UUID) -> BatchExportJob? {
        guard currentJobID == nil,
              let index = jobs.firstIndex(where: { $0.id == jobID && $0.status == .queued }) else { return nil }
        jobs[index].begin()
        return jobs[index]
    }

    @discardableResult
    public mutating func updateProgress(for jobID: UUID, progress: Double) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .running else { return false }
        jobs[index].updateProgress(progress)
        return true
    }

    public mutating func updateProgress(jobID: UUID, progress: Double) -> Bool {
        updateProgress(for: jobID, progress: progress)
    }

    @discardableResult
    public mutating func markSucceeded(for jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .running else { return false }
        jobs[index].succeed()
        return true
    }

    public mutating func succeed(jobID: UUID) -> Bool { markSucceeded(for: jobID) }
    public mutating func markSucceeded(jobID: UUID) -> Bool { markSucceeded(for: jobID) }
    public mutating func complete(jobID: UUID) -> Bool { markSucceeded(for: jobID) }

    @discardableResult
    public mutating func markFailed(for jobID: UUID, error: String? = nil) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .running else { return false }
        jobs[index].fail(error)
        return true
    }

    public mutating func fail(jobID: UUID, error: String? = nil) -> Bool {
        markFailed(for: jobID, error: error)
    }

    public mutating func markFailed(jobID: UUID, error: String? = nil) -> Bool {
        markFailed(for: jobID, error: error)
    }

    public mutating func markFailed(for jobID: UUID, error: Error) -> Bool {
        markFailed(for: jobID, error: String(describing: error))
    }

    @discardableResult
    public mutating func cancel(jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].status == .queued || jobs[index].status == .running else { return false }
        jobs[index].cancel()
        return true
    }

    public mutating func cancelAll() {
        for index in jobs.indices where jobs[index].status == .queued || jobs[index].status == .running {
            jobs[index].cancel()
        }
    }

    /// Requeues one failed job and counts the retry as the next attempt.
    @discardableResult
    public mutating func retry(jobID: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .failed else { return false }
        jobs[index].retry()
        return true
    }

    public mutating func retryFailedJob(jobID: UUID) -> Bool { retry(jobID: jobID) }

    @discardableResult
    public mutating func retryFailed() -> [UUID] {
        var retried: [UUID] = []
        for index in jobs.indices where jobs[index].status == .failed {
            jobs[index].retry()
            retried.append(jobs[index].id)
        }
        return retried
    }

    @discardableResult
    public mutating func updateSettings(for jobID: UUID, settings: VideoExportSettings) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].status == .queued else { return false }
        jobs[index].settings = settings
        return true
    }
}
