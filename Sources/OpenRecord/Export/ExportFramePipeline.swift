import Foundation

/// A blocking, cancellation-aware queue used to overlap frame preparation
/// with AVAssetWriter backpressure. The queue is intentionally tiny; unlike an
/// AsyncStream buffering policy it never drops frames or grows without bound.
final class ExportBoundedQueue<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var elements: [Element] = []
    private var isFinished = false
    private var terminalError: (any Error)?
    private var maximumCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    var bufferedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return elements.count
    }

    var maximumObservedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumCount
    }

    func append(_ element: Element) throws {
        condition.lock()
        defer { condition.unlock() }

        while elements.count >= capacity, !isFinished, terminalError == nil {
            if Task.isCancelled {
                throw CancellationError()
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        if let terminalError {
            throw terminalError
        }
        guard !isFinished else {
            throw CancellationError()
        }

        elements.append(element)
        maximumCount = max(maximumCount, elements.count)
        condition.broadcast()
    }

    func next() throws -> Element? {
        condition.lock()
        defer { condition.unlock() }

        while elements.isEmpty, !isFinished, terminalError == nil {
            if Task.isCancelled {
                throw CancellationError()
            }
            condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        if let terminalError {
            throw terminalError
        }
        guard !elements.isEmpty else { return nil }

        let element = elements.removeFirst()
        condition.broadcast()
        return element
    }

    func finish(throwing error: (any Error)? = nil) {
        condition.lock()
        if !isFinished, terminalError == nil {
            terminalError = error
            isFinished = error == nil
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Stop both sides promptly and release any prepared pixel buffers that
    /// have not yet reached the writer.
    func cancel() {
        condition.lock()
        elements.removeAll(keepingCapacity: false)
        if terminalError == nil, !isFinished {
            terminalError = CancellationError()
        }
        condition.broadcast()
        condition.unlock()
    }
}
