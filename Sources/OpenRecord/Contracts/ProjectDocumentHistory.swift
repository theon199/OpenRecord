import Foundation

/// Bounded snapshot history for non-destructive project edits.
///
/// Continuous controls can wrap their mutations in `begin` / `commit` so a
/// drag produces one undo entry instead of one entry per emitted value.
public struct ProjectDocumentHistory: Sendable {
    private struct Entry: Sendable {
        var document: ProjectDocument
        var actionName: String
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var transaction: Entry?
    private let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(limit, 1)
    }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoActionName: String? { undoEntries.last?.actionName }
    public var redoActionName: String? { redoEntries.last?.actionName }
    public var isEditing: Bool { transaction != nil }

    public mutating func begin(document: ProjectDocument, actionName: String) {
        guard transaction == nil else { return }
        transaction = Entry(document: document, actionName: actionName)
    }

    public mutating func commit(currentDocument: ProjectDocument) {
        guard let transaction else { return }
        self.transaction = nil
        record(
            before: transaction.document,
            after: currentDocument,
            actionName: transaction.actionName
        )
    }

    public mutating func record(
        before: ProjectDocument,
        after: ProjectDocument,
        actionName: String
    ) {
        guard transaction == nil, before != after else { return }
        undoEntries.append(Entry(document: before, actionName: actionName))
        if undoEntries.count > limit {
            undoEntries.removeFirst(undoEntries.count - limit)
        }
        redoEntries.removeAll(keepingCapacity: true)
    }

    public mutating func undo(currentDocument: ProjectDocument) -> ProjectDocument? {
        commit(currentDocument: currentDocument)
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(document: currentDocument, actionName: entry.actionName))
        return entry.document
    }

    public mutating func redo(currentDocument: ProjectDocument) -> ProjectDocument? {
        commit(currentDocument: currentDocument)
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(document: currentDocument, actionName: entry.actionName))
        return entry.document
    }

    public mutating func removeAll() {
        undoEntries.removeAll(keepingCapacity: false)
        redoEntries.removeAll(keepingCapacity: false)
        transaction = nil
    }
}
