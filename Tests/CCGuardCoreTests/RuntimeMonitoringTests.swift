import XCTest
@testable import CCGuardCore

final class RuntimeMonitoringTests:XCTestCase {
    let expected="192.0.2.10"
    let now=Date(timeIntervalSince1970:1_790_000_000)
    func complete() -> RuntimeObservation {
        RuntimeObservation(roundID:"fresh",collectedAt:now.timeIntervalSince1970*1000,
            chinaIP:expected,cloudflareIP:expected,claudeIP:expected,claudeReachable:true,
            anthropicReachable:true,dnsSafe:true,webrtcSafe:true,browserTimezone:"America/New_York")
    }
    func testRuntimeHasNoReputationRequirementOrFields() throws {
        let snapshot=complete()
        XCTAssertTrue(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).passed)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as? [String:Any])
        for field in ["score","residential","vpn","proxy","tor","crawler","abuser","serviceHealthy"] {
            XCTAssertNil(object[field])
        }
    }
    func testDomesticExitDifferenceAndChangeDoNotRevokeRuntime() {
        var snapshot=complete();snapshot.chinaIP="198.51.100.20"
        XCTAssertTrue(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).passed)
        snapshot.chinaIP="203.0.113.30"
        XCTAssertTrue(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).passed)
    }
    func testSplitRoutingStillRejectsEachFixedExitMismatch() {
        var snapshot=complete();snapshot.chinaIP="198.51.100.20";snapshot.cloudflareIP="192.0.2.11"
        XCTAssertEqual(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).failures.count,1)
        snapshot.cloudflareIP=expected;snapshot.claudeIP="192.0.2.11"
        XCTAssertEqual(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).failures.count,1)
    }
    func testNativeProbeUsesTheSameExitSourcePolicy() {
        XCTAssertFalse(ExitSource.china.requiresExpectedIP)
        XCTAssertTrue(ExitSource.claude.requiresExpectedIP)
        XCTAssertTrue(ExitSource.cloudflare.requiresExpectedIP)
        XCTAssertFalse(ExitSource.anthropic.requiresExpectedIP)
    }
    func testConfirmedMismatchWinsOverSimultaneousUnknowns() {
        var snapshot=complete();snapshot.claudeIP="192.0.2.11";snapshot.dnsSafe=nil;snapshot.anthropicReachable=nil
        let result=snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now)
        XCTAssertFalse(result.failures.isEmpty);XCTAssertFalse(result.unknown.isEmpty)
    }
    func testLeaksAndTimezoneAreConfirmedFailures() {
        var snapshot=complete();snapshot.dnsSafe=false;snapshot.webrtcSafe=false;snapshot.browserTimezone="Asia/Shanghai"
        XCTAssertEqual(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).failures.count,3)
    }
    func testTimeoutAndUnparseableIPAreUnknownNotSafeOrConfirmedRisk() {
        var snapshot=complete();snapshot.claudeIP="bad";snapshot.claudeReachable=false;snapshot.dnsSafe=nil
        let result=snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now)
        XCTAssertFalse(result.passed);XCTAssertTrue(result.failures.isEmpty);XCTAssertEqual(result.unknown.count,3)
    }
    func testOldFutureAndWrongRoundResultsCannotRenewMonitoring() {
        var snapshot=complete()
        XCTAssertFalse(snapshot.assess(expectedIP:expected,expectedRound:"old",now:now).passed)
        for age in [36_000.0,-6000] {
            snapshot.collectedAt=now.timeIntervalSince1970*1000-age
            XCTAssertFalse(snapshot.assess(expectedIP:expected,expectedRound:"fresh",now:now).passed)
        }
    }
    func testRetriesDoNotExtendFirstUnknownDeadline() {
        var policy=RuntimeMonitorPolicy();policy.begin(now:100);policy.started(now:130)
        policy.unavailable(now:140)
        XCTAssertFalse(policy.shouldProbe(now:149));XCTAssertTrue(policy.shouldProbe(now:150))
        policy.started(now:150);policy.unavailable(now:170)
        XCTAssertEqual(policy.unknownSince,140)
        XCTAssertFalse(policy.expired(now:259.99));XCTAssertTrue(policy.expired(now:260))
    }
    func testOnlyCompleteSuccessClearsGraceAndRestoresThirtySecondInterval() {
        var policy=RuntimeMonitorPolicy();policy.begin(now:0);policy.unavailable(now:30)
        policy.started(now:40);policy.succeeded(now:45)
        XCTAssertNil(policy.unknownSince);XCTAssertEqual(policy.lastSuccess,45)
        XCTAssertFalse(policy.shouldProbe(now:69));XCTAssertTrue(policy.shouldProbe(now:70))
    }
    func testStuckProbeEventuallyExpiresEvenWithoutFailureCallback() {
        var policy=RuntimeMonitorPolicy();policy.begin(now:0);policy.started(now:30)
        XCTAssertFalse(policy.expired(now:179));XCTAssertTrue(policy.expired(now:180))
    }
    func testTraceParserRejectsHTMLMissingIPv6DuplicateAndMalformedValues() {
        XCTAssertEqual(RuntimeProbeParsing.traceIP("fl=abc\nip=192.0.2.10\nloc=US\n"),expected)
        for text in ["<html>ip=192.0.2.10</html>","loc=US","ip=::1","ip=192.0.2.999","ip=192.0.2.10\nip=192.0.2.10"] {
            XCTAssertNil(RuntimeProbeParsing.traceIP(text))
        }
    }
    func testChinaParserOnlyAcceptsCompleteIPv4() {
        XCTAssertEqual(RuntimeProbeParsing.chinaIP("您的IP：[192.0.2.10]"),expected)
        for text in ["暂无数据","192.0.2.999","1192.0.2.10","192.0.2.10.1"] { XCTAssertNil(RuntimeProbeParsing.chinaIP(text)) }
    }
    func testUnreadLocalControlsAreUnknownButKnownChangesStillWin() {
        let pending=RuntimeAssessment.local(accessibility:true,vpn:true,node:nil,route:nil,timezone:"America/New_York",expectedNode:"主线")
        XCTAssertTrue(pending.failures.isEmpty);XCTAssertEqual(pending.unknown.count,2)
        let changed=RuntimeAssessment.local(accessibility:true,vpn:true,node:"备用",route:nil,timezone:"America/New_York",expectedNode:"主线")
        XCTAssertEqual(changed.failures.count,1);XCTAssertEqual(changed.unknown.count,1)
    }
    func testRepeatedLocalUnknownDoesNotPostponeExternalRetryOrDeadline() {
        var policy=RuntimeMonitorPolicy();policy.begin(now:0);policy.started(now:30)
        for time in 35...50 { policy.markUnknown(now:Double(time)) }
        XCTAssertEqual(policy.unknownSince,35);XCTAssertTrue(policy.shouldProbe(now:50))
        XCTAssertFalse(policy.expired(now:154));XCTAssertTrue(policy.expired(now:155))
    }
}
