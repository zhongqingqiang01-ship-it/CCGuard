import Foundation

public struct WebCheckTiming: Equatable {
    public static let allowedTimeout: ClosedRange<TimeInterval> = 10...60
    public static let defaultTimeout: TimeInterval = 20
    public static let recheckInterval: TimeInterval = 30
    // Two official exit probes each have a nine-second process deadline.
    public static let pathProbeAllowance: TimeInterval = 20
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) throws {
        guard timeout.isFinite, Self.allowedTimeout.contains(timeout) else {
            throw GuardFailure("单次网页加载上限须为 10–60 秒")
        }
        self.timeout=timeout
    }
    public var documentMaxAge: TimeInterval { max(45,timeout+Self.pathProbeAllowance) }
    public var permitMaxAge: TimeInterval { Self.recheckInterval+timeout+Self.pathProbeAllowance }
}
