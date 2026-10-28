import XCTest
@testable import CCGuardCore

final class DetectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var rules: DetectionRules { DetectionRules(expectedIP:"192.0.2.10") }

    /// Equivalent to the complete reference-page values observed in this session:
    /// slow connections and Chinese-language mismatch are warnings, not failures.
    private func complete() -> DetectionSnapshot {
        DetectionSnapshot(
            timeOrigin: now.timeIntervalSince1970 * 1000 - 3000,
            collectedAt: now.timeIntervalSince1970 * 1000 - 1000,
            raw: ["language": "语言不一致 本地: zh-CN, zh Claude出口所在地常用: en",
                  "claudeAvailability": "较慢 856ms", "anthropicAvailability": "较慢 363ms"],
            score: 100, chinaIP: "192.0.2.10", cloudflareIP: "192.0.2.10",
            claudeIP: "192.0.2.10", country: "United States", residential: true,
            regionSupported: true, vpn: false, proxy: false, tor: false,
            crawler: false, abuser: false, dnsSafe: true, webrtcSafe: true,
            timezoneConsistent: true, claudeReachable: true, anthropicReachable: true,
            serviceHealthy: true)
    }

    private func verdict(_ snapshot: DetectionSnapshot) -> DetectionVerdict {
        rules.validate(snapshot, expectedTimeOrigin: complete().timeOrigin, now: now)
    }

    func testReferencePagePassesWithTwoWarnings() {
        let result = verdict(complete())
        XCTAssertTrue(result.passed, result.reasons.joined(separator: "\n"))
        XCTAssertTrue(complete().missingRequiredFields.isEmpty)
        XCTAssertTrue(complete().explicitFailures.isEmpty)
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testScoreBoundaryIsStrictlyGreaterThan90() {
        for score in [0.0, 89.99, 90, 100.01, Double.infinity, -Double.infinity, Double.nan] {
            var snapshot = complete(); snapshot.score = score
            XCTAssertFalse(verdict(snapshot).passed, "\(score) must fail")
        }
        for score in [90.01, 91, 99.9, 100] {
            var snapshot = complete(); snapshot.score = score
            XCTAssertTrue(verdict(snapshot).passed, "\(score) must pass")
        }
    }

    func testMissingScoreNeverDefaultsToPassingScore() {
        var snapshot = complete(); snapshot.score = nil
        XCTAssertFalse(verdict(snapshot).passed)
        XCTAssertTrue(snapshot.missingRequiredFields.contains("评分"))
    }

    func testEachMissingBooleanCheckFailsClosed() {
        let paths: [WritableKeyPath<DetectionSnapshot, Bool?>] = [
            \.residential, \.regionSupported, \.vpn, \.proxy, \.tor, \.crawler, \.abuser,
            \.dnsSafe, \.webrtcSafe, \.timezoneConsistent, \.claudeReachable,
            \.anthropicReachable
        ]
        for path in paths {
            var snapshot = complete(); snapshot[keyPath: path] = nil
            XCTAssertFalse(verdict(snapshot).passed)
            XCTAssertEqual(snapshot.missingRequiredFields.count, 1)
            XCTAssertTrue(snapshot.explicitFailures.isEmpty, "A pending check must not be mistaken for an explicit failure")
        }
    }

    func testEveryKnownBadCheckIsAnExplicitFailure() {
        let positives: [WritableKeyPath<DetectionSnapshot, Bool?>] = [
            \.residential, \.regionSupported, \.dnsSafe, \.webrtcSafe, \.timezoneConsistent,
            \.claudeReachable, \.anthropicReachable
        ]
        let negatives: [WritableKeyPath<DetectionSnapshot, Bool?>] = [\.vpn, \.proxy, \.tor, \.crawler, \.abuser]
        for path in positives {
            var snapshot = complete(); snapshot[keyPath: path] = false
            XCTAssertFalse(verdict(snapshot).passed)
            XCTAssertFalse(snapshot.explicitFailures.isEmpty)
        }
        for path in negatives {
            var snapshot = complete(); snapshot[keyPath: path] = true
            XCTAssertFalse(verdict(snapshot).passed)
            XCTAssertFalse(snapshot.explicitFailures.isEmpty)
        }
    }

    func testIPMismatchAndChangedExpectedAddressFail() {
        var snapshot = complete(); snapshot.cloudflareIP = "192.0.2.11"
        XCTAssertFalse(verdict(snapshot).passed)
        let changed = DetectionRules(expectedIP: "192.0.2.11")
        XCTAssertFalse(changed.validate(complete(), now: now).passed)
    }
    func testDomesticExitCanDifferUnderSplitRoutingAtStartup() {
        var snapshot=complete();snapshot.chinaIP="198.51.100.20"
        XCTAssertTrue(verdict(snapshot).passed)
        snapshot.chinaIP="203.0.113.30"
        XCTAssertTrue(verdict(snapshot).passed)
    }
    func testDomesticExemptionCannotHideClaudeOrCloudflareChanges() {
        var snapshot=complete();snapshot.chinaIP="198.51.100.20"
        snapshot.claudeIP="192.0.2.11"
        XCTAssertFalse(verdict(snapshot).passed)
        snapshot.claudeIP="192.0.2.10";snapshot.cloudflareIP="192.0.2.11"
        XCTAssertFalse(verdict(snapshot).passed)
    }
    func testFixedExitsMustStillAgreeWhenExpectedIPRuleIsDisabled() {
        var snapshot=complete();snapshot.chinaIP="198.51.100.20";snapshot.cloudflareIP="192.0.2.11"
        XCTAssertFalse(DetectionRules(expectedIP:nil).validate(snapshot,now:now).passed)
    }

    func testAllThreeIPsMayChangeOnlyWhenFixedIPRuleExplicitlyDisabled() {
        var snapshot = complete()
        snapshot.chinaIP = "192.0.2.20"; snapshot.cloudflareIP = "192.0.2.20"; snapshot.claudeIP = "192.0.2.20"
        XCTAssertFalse(verdict(snapshot).passed)
        XCTAssertTrue(DetectionRules(expectedIP: nil).validate(snapshot, now: now).passed)
    }

    func testMissingAndMaskedAndInvalidIPsFail() {
        let invalid = [nil, "", "192.0.***.10", "192.0.2.999", "0192.0.2.10", "::1", "127.0.0.1 extra"]
        for value in invalid {
            var snapshot = complete(); snapshot.chinaIP = value
            XCTAssertFalse(verdict(snapshot).passed)
        }
    }

    func testCountryExactMatchAndUnknownCountry() {
        for country in [nil, "", "未知", "China", "United States Minor Outlying Islands"] {
            var snapshot = complete(); snapshot.country = country
            XCTAssertFalse(verdict(snapshot).passed)
        }
    }

    func testTimezoneMustBeNewYorkAndConsistent() {
        var snapshot = complete(); snapshot.browserTimezone = "America/Los_Angeles"
        XCTAssertFalse(verdict(snapshot).passed)
        snapshot.browserTimezone = "America/New_York"; snapshot.timezoneConsistent = false
        XCTAssertFalse(verdict(snapshot).passed)
    }

    func testIPv6WarningFailsEvenWhenOtherFieldsLookGood() {
        var snapshot = complete(); snapshot.ipv6Warning = true
        XCTAssertFalse(verdict(snapshot).passed)
        XCTAssertFalse(snapshot.explicitFailures.isEmpty)
    }

    func testWrongPageCannotBeAccepted() {
        for url in ["http://ip.net.coffee/claude/", "https://ip.net.coffee.evil.invalid/claude/",
                    "https://ip.net.coffee/", "https://user@ip.net.coffee/claude/"] {
            var snapshot = complete(); snapshot.url = url
            XCTAssertFalse(verdict(snapshot).passed)
        }
    }

    func testOldCollectionFailsDespiteMatchingNavigation() {
        var snapshot = complete(); snapshot.collectedAt = now.timeIntervalSince1970 * 1000 - 16_000
        XCTAssertFalse(verdict(snapshot).passed)
    }

    func testResamplingOldDocumentCannotRenewItForever() {
        var snapshot = complete()
        snapshot.timeOrigin = now.timeIntervalSince1970 * 1000 - 46_000
        snapshot.collectedAt = now.timeIntervalSince1970 * 1000
        XCTAssertFalse(rules.validate(snapshot, expectedTimeOrigin: snapshot.timeOrigin, now: now).passed)
    }

    func testOldNavigationCannotSatisfyNewCheck() {
        let snapshot = complete()
        XCTAssertFalse(rules.validate(snapshot, expectedTimeOrigin: snapshot.timeOrigin + 1000, now: now).passed)
    }

    func testFutureOrInvalidTimesFail() {
        for time in [0.0, -1, Double.infinity, Double.nan, now.timeIntervalSince1970 * 1000 + 6000] {
            var snapshot = complete(); snapshot.collectedAt = time
            XCTAssertFalse(verdict(snapshot).passed)
            snapshot = complete(); snapshot.timeOrigin = time
            XCTAssertFalse(rules.validate(snapshot, now: now).passed)
        }
    }

    func testLoadingDocumentFailsAndSourceFailureIsImmediate() {
        var snapshot = complete(); snapshot.readyState = "loading"
        XCTAssertFalse(verdict(snapshot).passed)
        snapshot = complete(); snapshot.sourceFailures = ["claudeIP 获取失败"]
        XCTAssertFalse(verdict(snapshot).passed)
        XCTAssertTrue(snapshot.explicitFailures.contains("claudeIP 获取失败"))
    }

    func testRulesCannotSilentlyWeakenMinimumBelow90() {
        XCTAssertFalse(DetectionRules(minimumScoreExclusive: 89).validate(complete(), now: now).passed)
        XCTAssertFalse(DetectionRules(maxSnapshotAge: .infinity).validate(complete(), now: now).passed)
        XCTAssertFalse(DetectionRules(maxDocumentAge: 0).validate(complete(), now: now).passed)
    }

    func testCodableRoundTripRetainsUnknownAsUnknown() throws {
        var snapshot = complete(); snapshot.serviceHealthy = nil
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DetectionSnapshot.self, from: encoded)
        XCTAssertEqual(snapshot, decoded)
        XCTAssertTrue(verdict(decoded).passed)
        XCTAssertNil(decoded.serviceHealthy)
        XCTAssertTrue(verdict(decoded).warnings.contains{$0.contains("全局服务状态")})
    }

    func testGlobalServiceFaultsOnlyWarnIncludingMissingStatus() {
        for status in ["轻微故障","重大故障","严重故障","维护中","服务异常"] {
            var snapshot=complete();snapshot.serviceHealthy=false;snapshot.raw["serviceStatus"]=status
            let result=verdict(snapshot)
            XCTAssertTrue(result.passed)
            XCTAssertTrue(snapshot.explicitFailures.isEmpty)
            XCTAssertTrue(result.warnings.contains{$0.contains(status)})
        }
        var snapshot=complete();snapshot.serviceHealthy=nil
        XCTAssertTrue(verdict(snapshot).passed)
        XCTAssertTrue(snapshot.missingRequiredFields.isEmpty)
        XCTAssertNotNil(snapshot.serviceStatusWarning)
        snapshot.serviceHealthy=true
        XCTAssertNil(snapshot.serviceStatusWarning)
    }

    func testServiceWarningCannotHideNetworkAndSecurityFailures() {
        var snapshot=complete();snapshot.serviceHealthy=false;snapshot.raw["serviceStatus"]="轻微故障"
        for field in [\DetectionSnapshot.dnsSafe,\.webrtcSafe,\.claudeReachable,\.anthropicReachable] {
            var missing=snapshot;missing[keyPath:field]=nil
            XCTAssertFalse(verdict(missing).passed)
            var failed=snapshot;failed[keyPath:field]=false
            XCTAssertFalse(verdict(failed).passed)
        }
        snapshot.score=90;XCTAssertFalse(verdict(snapshot).passed)
        snapshot.score=100;snapshot.claudeIP="192.0.2.20";XCTAssertFalse(verdict(snapshot).passed)
    }

    func testSanitizedStartupFixtureDecodesAllRequiredFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let snapshot = try JSONDecoder().decode(DetectionSnapshot.self,
            from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/startup-complete.json")))
        XCTAssertEqual(snapshot.score, 100)
        XCTAssertEqual(snapshot.chinaIP, "192.0.2.10")
        XCTAssertEqual(snapshot.cloudflareIP, snapshot.chinaIP)
        XCTAssertEqual(snapshot.claudeIP, snapshot.chinaIP)
        XCTAssertEqual(snapshot.country, "United States")
        XCTAssertEqual(snapshot.browserTimezone, "America/New_York")
        XCTAssertTrue(snapshot.missingRequiredFields.isEmpty)
        XCTAssertTrue(snapshot.explicitFailures.isEmpty)
        // A saved fixture is historical evidence, not a live authorization.
        let future = Date(timeIntervalSince1970: snapshot.collectedAt / 1000 + 120)
        XCTAssertFalse(rules.validate(snapshot, now: future).passed)
    }
}
