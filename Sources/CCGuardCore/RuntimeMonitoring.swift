import Foundation

/// Runtime observations deliberately contain no score, residential, or reputation fields.
public struct RuntimeObservation: Codable, Equatable, Sendable {
    public var roundID: String
    public var collectedAt: Double
    public var chinaIP: String?
    public var cloudflareIP: String?
    public var claudeIP: String?
    public var claudeReachable: Bool?
    public var anthropicReachable: Bool?
    public var dnsSafe: Bool?
    public var webrtcSafe: Bool?
    public var browserTimezone: String?
    public var details: [String: String]
    public init(roundID: String, collectedAt: Double, chinaIP: String? = nil,
                cloudflareIP: String? = nil, claudeIP: String? = nil,
                claudeReachable: Bool? = nil, anthropicReachable: Bool? = nil,
                dnsSafe: Bool? = nil, webrtcSafe: Bool? = nil,
                browserTimezone: String? = nil, details: [String: String] = [:]) {
        self.roundID=roundID;self.collectedAt=collectedAt
        self.chinaIP=chinaIP;self.cloudflareIP=cloudflareIP;self.claudeIP=claudeIP
        self.claudeReachable=claudeReachable;self.anthropicReachable=anthropicReachable
        self.dnsSafe=dnsSafe;self.webrtcSafe=webrtcSafe
        self.browserTimezone=browserTimezone;self.details=details
    }
    public func assess(expectedIP: String, expectedRound: String, now: Date = Date()) -> RuntimeAssessment {
        guard roundID == expectedRound, collectedAt.isFinite,
              now.timeIntervalSince1970*1000-collectedAt >= -5000,
              now.timeIntervalSince1970*1000-collectedAt <= 35_000 else {
            return RuntimeAssessment(unknown: ["后台结果已过期或不属于本轮探测"])
        }
        var failures: [String]=[],unknown: [String]=[]
        for (source,ip) in [(ExitSource.china,chinaIP),(.cloudflare,cloudflareIP),(.claude,claudeIP)] {
            guard let ip,DetectionRules.isIPv4(ip) else { unknown.append(source.title+"暂未获取");continue }
            if source.requiresExpectedIP && ip != expectedIP { failures.append(source.title+"与指定 IP 不一致") }
        }
        for (label,value) in [("DNS",dnsSafe),("WebRTC",webrtcSafe)] {
            if value == false { failures.append(label+"检测到泄露") }
            if value == nil { unknown.append(label+"暂未确认") }
        }
        for (label,value) in [("claude.ai",claudeReachable),("anthropic.com",anthropicReachable)] where value != true {
            unknown.append(label+"暂时不可达")
        }
        if let browserTimezone,!browserTimezone.isEmpty {
            if browserTimezone != "America/New_York" { failures.append("浏览器时区不是纽约") }
        } else { unknown.append("浏览器时区暂未获取") }
        return RuntimeAssessment(failures: failures, unknown: unknown)
    }
}

public struct RuntimeAssessment: Equatable, Sendable {
    public var failures: [String]
    public var unknown: [String]
    public var passed: Bool { failures.isEmpty && unknown.isEmpty }
    public init(failures: [String] = [], unknown: [String] = []) { self.failures=failures;self.unknown=unknown }
    public static func local(accessibility:Bool,vpn:Bool,node:String?,route:String?,timezone:String,expectedNode:String) -> Self {
        var failures:[String]=[],unknown:[String]=[]
        if !accessibility { failures.append("辅助功能权限失效") }
        if !vpn { failures.append("Shadowrocket 已断开") }
        if let node {
            if node != expectedNode && !node.contains("使用节点 "+expectedNode+",") { failures.append("当前节点不是指定节点") }
        } else { unknown.append("节点状态暂未读到") }
        if let route {
            if !route.contains("全局路由") || !route.contains("配置") || route.contains("直连") || route.contains("代理,") {
                failures.append("全局路由不是配置")
            }
        } else { unknown.append("路由状态暂未读到") }
        if timezone != "America/New_York" { failures.append("系统时区不是纽约") }
        return Self(failures:failures,unknown:unknown)
    }
}

public struct RuntimeProbeFailure: LocalizedError {
    public let message: String
    public let confirmed: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, confirmed: Bool = false) { self.message=message;self.confirmed=confirmed }
}

/// Monotonic deadlines cannot be extended by a partial result or repeated retries.
public struct RuntimeMonitorPolicy {
    public static let interval: TimeInterval=30
    public static let retryInterval: TimeInterval=10
    public static let probeTimeout: TimeInterval=30
    public static let maximumSilence: TimeInterval=120
    public private(set) var lastStarted: TimeInterval?
    public private(set) var lastSuccess: TimeInterval?
    public private(set) var unknownSince: TimeInterval?
    public init() {}
    public mutating func begin(now: TimeInterval) { lastStarted=now;lastSuccess=now;unknownSince=nil }
    public mutating func started(now: TimeInterval) { lastStarted=now }
    public mutating func succeeded(now: TimeInterval) { lastSuccess=now;unknownSince=nil }
    public mutating func unavailable(now: TimeInterval) { lastStarted=now;if unknownSince == nil { unknownSince=now } }
    public mutating func markUnknown(now:TimeInterval) { if unknownSince == nil { unknownSince=now } }
    public func expired(now: TimeInterval) -> Bool {
        if let unknownSince,now-unknownSince >= Self.maximumSilence { return true }
        // Includes a stalled task that never manages to report its first failure.
        return lastSuccess.map { now-$0 >= Self.maximumSilence+Self.interval+Self.probeTimeout } ?? false
    }
    public func shouldProbe(now: TimeInterval) -> Bool {
        guard let lastStarted else { return true }
        return now-lastStarted >= (unknownSince == nil ? Self.interval : Self.retryInterval)
    }
    public func retrySecondsRemaining(now: TimeInterval) -> Int {
        guard let unknownSince else { return 0 }
        return max(0,Int(ceil(Self.maximumSilence-(now-unknownSince))))
    }
}

public enum RuntimeProbeParsing {
    public static func traceIP(_ text: String) -> String? {
        let values=text.split(separator:"\n").filter{$0.hasPrefix("ip=")}.map{String($0.dropFirst(3)).trimmingCharacters(in:.whitespacesAndNewlines)}
        guard values.count == 1,DetectionRules.isIPv4(values[0]) else { return nil }
        return values[0]
    }
    public static func chinaIP(_ text: String) -> String? {
        guard let regex=try? NSRegularExpression(pattern:#"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])"#),
              let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let range=Range(match.range,in:text) else { return nil }
        let value=String(text[range]);return DetectionRules.isIPv4(value) ? value : nil
    }
}
