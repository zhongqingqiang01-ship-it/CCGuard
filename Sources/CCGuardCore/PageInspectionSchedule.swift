import Foundation

public struct PageInspectionFailure: LocalizedError {
    public let message: String
    public let mayRefresh: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, mayRefresh: Bool) {
        self.message = message; self.mayRefresh = mayRefresh
    }
}

/// Every attempt is a fresh navigation. A retry never reuses the previous document.
public enum PageInspectionSchedule {
    public enum Progress { case loading, waitingToRefresh }
    public static let minimumLoad: TimeInterval = 10
    public static let refreshDelay: TimeInterval = 10

    @MainActor public static func run<Value>(
        allowRefresh: Bool,
        navigate: () async throws -> Void,
        read: () async throws -> Value,
        progress: (Progress) -> Void = { _ in },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) async throws -> Value {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let started=now()
            try await navigate()
            progress(.loading)
            try await sleep(max(0,minimumLoad-(now()-started)))
            try Task.checkCancellation()
            do { return try await read() }
            catch let failure as PageInspectionFailure where allowRefresh && attempt == 0 && failure.mayRefresh {
                progress(.waitingToRefresh)
                try await sleep(refreshDelay)
                try Task.checkCancellation()
            }
        }
        preconditionFailure("The second attempt must return or throw")
    }
}

extension DetectionSnapshot {
    /// A refresh may resolve missing sources or inconsistent IP/timezone values.
    /// Confirmed risk indicators continue to deny access without a retry.
    public func mayRefreshAfterFailure() -> Bool {
        var withoutTransientFailures = self
        withoutTransientFailures.sourceFailures = []
        withoutTransientFailures.timezoneConsistent = nil
        return withoutTransientFailures.explicitFailures.isEmpty
    }
}
