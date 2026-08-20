import Foundation

public enum OpenRecordError: Error, Sendable, Equatable {
    case unimplemented(String)
    case io(String)
}

extension OpenRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unimplemented(let name):
            return "Unimplemented: \(name)"
        case .io(let message):
            return message
        }
    }
}
