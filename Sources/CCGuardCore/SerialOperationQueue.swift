import Foundation

/// Actors can reenter at an await. This queue also keeps the whole asynchronous
/// operation exclusive, so one request cannot consume another request's reply.
public actor SerialOperationQueue {
    private var busy=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    public init() {}

    public func run<Value>(_ operation:() async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy=true
        defer {
            if waiters.isEmpty { busy=false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
