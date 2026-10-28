import Foundation

public enum FlowStep: Int, CaseIterable, Codable { case proxy, timezone, website, editor }
public enum FlowPhase: String, Codable { case idle, checking, guarding, blocked }
public struct GuardFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
@MainActor public protocol WorkflowDriver: AnyObject {
    func prepareProxy() async throws
    func prepareTimezone() async throws
    func inspectWebsite() async throws
    func armAndOpenEditor() async throws
    func didEnterGuarding() async
    func closeEditors(reason: String) async throws
}
public extension WorkflowDriver {
    func didEnterGuarding() async {}
}
@MainActor public final class Workflow {
    public private(set) var phase: FlowPhase = .idle
    public private(set) var completed: [FlowStep] = []
    public private(set) var activeStep: FlowStep?
    public private(set) var failure: String?
    public var onChange: (() -> Void)?
    private var generation = UUID()
    private let driver: WorkflowDriver
    public init(driver: WorkflowDriver) { self.driver = driver }
    public func start() async {
        guard !Task.isCancelled else { return }
        guard phase != .checking && phase != .guarding else { return }
        let token = UUID(); generation = token
        completed = []; failure = nil; phase = .checking; onChange?()
        do {
            for step in FlowStep.allCases {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                activeStep = step; onChange?()
                switch step {
                case .proxy: try await driver.prepareProxy()
                case .timezone: try await driver.prepareTimezone()
                case .website: try await driver.inspectWebsite()
                case .editor: try await driver.armAndOpenEditor()
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                completed.append(step); onChange?()
            }
            activeStep = nil; phase = .guarding; onChange?()
            try Task.checkCancellation()
            guard generation == token, phase == .guarding else { return }
            await driver.didEnterGuarding()
        } catch {
            guard generation == token else { return }
            await trip(error.localizedDescription)
        }
    }
    public func trip(_ reason: String) async {
        // Invalidate before suspension; a late browser response cannot grant a new permit.
        generation = UUID(); phase = .blocked; activeStep = nil; failure = reason; onChange?()
        do { try await driver.closeEditors(reason: reason) }
        catch { failure = reason + "；退出核验失败：" + error.localizedDescription }
        onChange?()
    }
    public func finish() async {
        generation = UUID(); activeStep = nil
        do {
            try await driver.closeEditors(reason: "结束使用")
            phase = .idle; completed = []; failure = nil
        } catch { phase = .blocked; failure = "结束使用时退出失败：" + error.localizedDescription }
        onChange?()
    }
}

public struct ProcessRecord: Equatable {
    public var pid: Int32
    public var parent: Int32
    public var uid: UInt32
    public var path: String
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64
    public init(pid: Int32, parent: Int32, uid: UInt32, path: String, startSeconds:UInt64 = 0, startMicroseconds:UInt64 = 0) {
        self.pid = pid; self.parent = parent; self.uid = uid; self.path = path
        self.startSeconds=startSeconds;self.startMicroseconds=startMicroseconds
    }
}
public enum EditorSelection {
    public static func sameProcess(_ expected:ProcessRecord,_ current:ProcessRecord)->Bool {
        expected.pid==current.pid && expected.uid==current.uid && expected.startSeconds>0 &&
        expected.startSeconds==current.startSeconds && expected.startMicroseconds==current.startMicroseconds
    }
    public static func records(_ all: [ProcessRecord], uid: UInt32, appPath: String) -> [ProcessRecord] {
        let prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        var selected = Set(all.filter { $0.uid == uid && $0.path.hasPrefix(prefix) }.map(\.pid))
        var changed = true
        while changed {
            changed = false
            for record in all where record.uid == uid && selected.contains(record.parent) {
                if selected.insert(record.pid).inserted { changed = true }
            }
        }
        return all.filter { selected.contains($0.pid) }
    }
}
public struct Lease: Codable {
    public var nonce: String
    public var parentPID: Int32
    public var armed: Bool
    public var heartbeat: TimeInterval
    public init(nonce: String, parentPID: Int32, armed: Bool, heartbeat: TimeInterval) {
        self.nonce = nonce; self.parentPID = parentPID; self.armed = armed; self.heartbeat = heartbeat
    }
    public func valid(nonce: String, parentPID: Int32, uptime: TimeInterval, maxAge: TimeInterval = 4) -> Bool {
        self.nonce == nonce && self.parentPID == parentPID && heartbeat <= uptime && uptime - heartbeat <= maxAge
    }
}
