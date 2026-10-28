import Foundation

/// A read of the rendered detection page. Times use JavaScript milliseconds since epoch.
/// The caller must bind each read to the navigation it initiated; a new read of an old DOM
/// is not a new network check.
public struct DetectionSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var url: String
    public var timeOrigin: Double
    public var collectedAt: Double
    public var readyState: String
    public var browserTimezone: String
    public var ipv6Warning: Bool
    public var raw: [String: String]
    public var sourceFailures: [String]
    public var score: Double?
    public var chinaIP: String?
    public var cloudflareIP: String?
    public var claudeIP: String?
    public var country: String?
    public var residential: Bool?
    public var regionSupported: Bool?
    public var vpn: Bool?
    public var proxy: Bool?
    public var tor: Bool?
    public var crawler: Bool?
    public var abuser: Bool?
    public var dnsSafe: Bool?
    public var webrtcSafe: Bool?
    public var timezoneConsistent: Bool?
    public var claudeReachable: Bool?
    public var anthropicReachable: Bool?
    public var serviceHealthy: Bool?

    public init(url: String = "https://ip.net.coffee/claude/", timeOrigin: Double,
                collectedAt: Double, readyState: String = "complete",
                browserTimezone: String = "America/New_York", ipv6Warning: Bool = false,
                raw: [String: String] = [:], sourceFailures: [String] = [],
                score: Double? = nil, chinaIP: String? = nil, cloudflareIP: String? = nil,
                claudeIP: String? = nil, country: String? = nil, residential: Bool? = nil,
                regionSupported: Bool? = nil, vpn: Bool? = nil, proxy: Bool? = nil,
                tor: Bool? = nil, crawler: Bool? = nil, abuser: Bool? = nil,
                dnsSafe: Bool? = nil, webrtcSafe: Bool? = nil, timezoneConsistent: Bool? = nil,
                claudeReachable: Bool? = nil, anthropicReachable: Bool? = nil,
                serviceHealthy: Bool? = nil) {
        schemaVersion = 1
        self.url = url; self.timeOrigin = timeOrigin; self.collectedAt = collectedAt
        self.readyState = readyState; self.browserTimezone = browserTimezone
        self.ipv6Warning = ipv6Warning; self.raw = raw; self.sourceFailures = sourceFailures
        self.score = score; self.chinaIP = chinaIP; self.cloudflareIP = cloudflareIP
        self.claudeIP = claudeIP; self.country = country; self.residential = residential
        self.regionSupported = regionSupported; self.vpn = vpn; self.proxy = proxy
        self.tor = tor; self.crawler = crawler; self.abuser = abuser; self.dnsSafe = dnsSafe
        self.webrtcSafe = webrtcSafe; self.timezoneConsistent = timezoneConsistent
        self.claudeReachable = claudeReachable; self.anthropicReachable = anthropicReachable
        self.serviceHealthy = serviceHealthy
    }

    public var missingRequiredFields: [String] {
        var missing: [String] = []
        let fields: [(String, Bool)] = [
            ("评分", score == nil), ("中国出口 IP", chinaIP?.isEmpty != false),
            ("Cloudflare 出口 IP", cloudflareIP?.isEmpty != false),
            ("Claude 出口 IP", claudeIP?.isEmpty != false),
            ("地区", country?.isEmpty != false), ("住宅属性", residential == nil),
            ("支持地区", regionSupported == nil), ("VPN 检测", vpn == nil),
            ("Proxy 检测", proxy == nil), ("Tor 检测", tor == nil),
            ("Crawler 检测", crawler == nil), ("滥用记录", abuser == nil),
            ("DNS 检测", dnsSafe == nil), ("WebRTC 检测", webrtcSafe == nil),
            ("时区一致性", timezoneConsistent == nil),
            ("claude.ai 可用性", claudeReachable == nil),
            ("anthropic.com 可用性", anthropicReachable == nil)
        ]
        for (name, absent) in fields where absent { missing.append(name) }
        return missing
    }

    /// Safe to use while waiting for the page's remaining checks. Missing values alone
    /// are not explicit failures; the caller still applies its overall timeout.
    public var explicitFailures: [String] {
        var result = sourceFailures
        if ipv6Warning { result.append("检测页面报告 IPv6 环境异常") }
        if let score, !score.isFinite || score <= 90 || score > 100 {
            result.append("评分不在允许范围内")
        }
        let positiveChecks: [(String, Bool?)] = [
            ("住宅属性", residential), ("支持地区", regionSupported), ("DNS 检测", dnsSafe),
            ("WebRTC 检测", webrtcSafe), ("时区一致性", timezoneConsistent),
            ("claude.ai 可用性", claudeReachable),
            ("anthropic.com 可用性", anthropicReachable)
        ]
        let negativeChecks: [(String, Bool?)] = [
            ("VPN", vpn), ("Proxy", proxy), ("Tor", tor), ("Crawler", crawler), ("滥用记录", abuser)
        ]
        for (label, flag) in positiveChecks where flag == false { result.append("\(label)不符合要求") }
        for (label, flag) in negativeChecks where flag == true { result.append("检测到\(label)异常") }
        return Array(Set(result)).sorted()
    }

    public var serviceStatusWarning:String? {
        if serviceHealthy == true { return nil }
        if serviceHealthy == false {
            let detail=String((raw["serviceStatus"] ?? "服务异常").prefix(60))
            return "Claude 全局服务告警：\(detail)，仅作提示"
        }
        return "Claude 全局服务状态暂未获取或无法识别，仅作提示"
    }
}

public struct DetectionVerdict: Codable, Equatable, Sendable {
    public var passed: Bool
    public var reasons: [String]
    public var warnings: [String]
    public init(passed: Bool, reasons: [String], warnings: [String] = []) {
        self.passed = passed; self.reasons = reasons; self.warnings = warnings
    }
}

public struct DetectionRules: Codable, Equatable, Sendable {
    public var expectedIP: String?
    public var minimumScoreExclusive: Double
    public var expectedTimezone: String
    public var maxSnapshotAge: TimeInterval
    public var maxDocumentAge: TimeInterval

    public init(expectedIP: String? = nil, minimumScoreExclusive: Double = 90,
                expectedTimezone: String = "America/New_York",
                maxSnapshotAge: TimeInterval = 15, maxDocumentAge: TimeInterval = 45) {
        self.expectedIP = expectedIP; self.minimumScoreExclusive = minimumScoreExclusive
        self.expectedTimezone = expectedTimezone; self.maxSnapshotAge = maxSnapshotAge
        self.maxDocumentAge = maxDocumentAge
    }

    public func validate(_ snapshot: DetectionSnapshot, expectedTimeOrigin: Double? = nil,
                         now: Date = Date()) -> DetectionVerdict {
        var reasons = snapshot.explicitFailures
        var warnings: [String] = []
        if let warning=snapshot.serviceStatusWarning { warnings.append(warning) }
        let milliseconds = now.timeIntervalSince1970 * 1000
        let url = URLComponents(string: snapshot.url)
        if url?.scheme != "https" || url?.host != "ip.net.coffee" || url?.path != "/claude/" || url?.user != nil || url?.password != nil {
            reasons.append("检测页面地址不正确")
        }
        if snapshot.schemaVersion != 1 { reasons.append("检测数据版本不受支持") }
        if snapshot.readyState != "complete" { reasons.append("检测页面尚未加载完成") }
        if !snapshot.collectedAt.isFinite || snapshot.collectedAt <= 0 ||
            milliseconds - snapshot.collectedAt > maxSnapshotAge * 1000 ||
            snapshot.collectedAt - milliseconds > 5000 {
            reasons.append("检测结果已过期或采集时间无效")
        }
        if !snapshot.timeOrigin.isFinite || snapshot.timeOrigin <= 0 ||
            milliseconds - snapshot.timeOrigin > maxDocumentAge * 1000 ||
            snapshot.timeOrigin - milliseconds > 5000 || snapshot.collectedAt < snapshot.timeOrigin {
            reasons.append("检测页面未刷新或导航时间无效")
        }
        if let expectedTimeOrigin, !expectedTimeOrigin.isFinite || abs(expectedTimeOrigin - snapshot.timeOrigin) > 0.5 {
            reasons.append("检测结果不属于本轮页面导航")
        }
        if !minimumScoreExclusive.isFinite || minimumScoreExclusive < 90 || minimumScoreExclusive >= 100 ||
            !maxSnapshotAge.isFinite || maxSnapshotAge <= 0 || !maxDocumentAge.isFinite || maxDocumentAge <= 0 {
            reasons.append("检测规则配置无效")
        }
        if !snapshot.missingRequiredFields.isEmpty {
            reasons.append("检测结果未完成：" + snapshot.missingRequiredFields.joined(separator: "、"))
        }
        if let score = snapshot.score, !score.isFinite || score <= minimumScoreExclusive || score > 100 {
            reasons.append("评分必须大于 \(minimumScoreExclusive.formatted()) 且不超过 100")
        }
        let ips = [snapshot.chinaIP, snapshot.cloudflareIP, snapshot.claudeIP].compactMap { $0 }
        if ips.contains(where: { !Self.isIPv4($0) }) { reasons.append("出口 IP 不是完整 IPv4 地址") }
        let fixedExits = [snapshot.cloudflareIP, snapshot.claudeIP].compactMap { $0 }
        if fixedExits.count == 2 && Set(fixedExits).count != 1 { reasons.append("Claude 与 Cloudflare 出口 IP 不一致") }
        if let expectedIP, !expectedIP.isEmpty {
            if !Self.isIPv4(expectedIP) { reasons.append("配置中的固定 IP 无效") }
            if fixedExits.contains(where: { $0 != expectedIP }) { reasons.append("Claude 或 Cloudflare 出口 IP 与指定 IP 不一致") }
        }
        if let country = snapshot.country, !["United States", "United States of America", "美国", "美國", "US"].contains(country.trimmingCharacters(in: .whitespacesAndNewlines)) {
            reasons.append("出口地区不是美国")
        }
        if snapshot.browserTimezone != expectedTimezone { reasons.append("浏览器时区不是 \(expectedTimezone)") }
        if let language = snapshot.raw["language"], language.contains("语言不一致") {
            warnings.append("语言不一致，仅作提示")
        }
        if [snapshot.raw["claudeAvailability"], snapshot.raw["anthropicAvailability"]].compactMap({ $0 }).contains(where: { $0.contains("较慢") }) {
            warnings.append("网站连接较慢，但可访问")
        }
        reasons = Array(Set(reasons)).sorted()
        return DetectionVerdict(passed: reasons.isEmpty, reasons: reasons, warnings: warnings)
    }

    public static func isIPv4(_ string: String) -> Bool {
        let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 4 && pieces.allSatisfy { piece in
            !piece.isEmpty && piece.count <= 3 && piece.allSatisfy(\.isASCIIDigit) &&
            (piece.count == 1 || piece.first != "0") && Int(piece).map { $0 <= 255 } == true
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
