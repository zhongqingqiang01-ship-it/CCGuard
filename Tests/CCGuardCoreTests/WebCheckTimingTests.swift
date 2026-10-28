import XCTest
@testable import CCGuardCore

final class WebCheckTimingTests:XCTestCase {
    func testAcceptsUpToOneMinuteAndRejectsUnsupportedOrInvalidValues() throws {
        for seconds in [10.0,20,30,35,45,55,60] {
            XCTAssertEqual(try WebCheckTiming(timeout:seconds).timeout,seconds)
        }
        for seconds in [9.0,60.01,61,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try WebCheckTiming(timeout:seconds))
        }
        XCTAssertEqual(WebCheckTiming.defaultTimeout,20)
    }

    func testSlowCompletePageCanPassAfterFortyFiveSecondsButCannotRenewOldDocument() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var snapshot=try JSONDecoder().decode(DetectionSnapshot.self,from:Data(contentsOf:root.appendingPathComponent("Tests/Fixtures/startup-complete.json")))
        let now=Date(timeIntervalSince1970:1_790_000_000)
        snapshot.collectedAt=now.timeIntervalSince1970*1000
        // A 60-second page load followed by a 15-second exit-path check.
        snapshot.timeOrigin=snapshot.collectedAt-75_000
        let timing=try WebCheckTiming(timeout:60)
        let rules=DetectionRules(maxDocumentAge:timing.documentMaxAge)
        XCTAssertTrue(rules.validate(snapshot,expectedTimeOrigin:snapshot.timeOrigin,now:now).passed)
        XCTAssertFalse(DetectionRules().validate(snapshot,now:now).passed)
        XCTAssertFalse(rules.validate(snapshot,expectedTimeOrigin:snapshot.timeOrigin+1000,now:now).passed)
        snapshot.timeOrigin=snapshot.collectedAt-81_000
        XCTAssertFalse(rules.validate(snapshot,now:now).passed)
    }

    func testLongWaitDoesNotRelaxScoreOrFreshCollectionRequirements() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var snapshot=try JSONDecoder().decode(DetectionSnapshot.self,from:Data(contentsOf:root.appendingPathComponent("Tests/Fixtures/startup-complete.json")))
        let now=Date(timeIntervalSince1970:1_790_000_000)
        snapshot.collectedAt=now.timeIntervalSince1970*1000
        snapshot.timeOrigin=snapshot.collectedAt-60_000
        let timing=try WebCheckTiming(timeout:60)
        let rules=DetectionRules(maxDocumentAge:timing.documentMaxAge)
        snapshot.score=90
        XCTAssertFalse(rules.validate(snapshot,now:now).passed)
        snapshot.score=100;snapshot.collectedAt-=16_000
        XCTAssertFalse(rules.validate(snapshot,now:now).passed)
    }

    func testPermitAllowsSixtySecondRecheckWithoutExpiringAtFortyFive() throws {
        let timing=try WebCheckTiming(timeout:60)
        // Start after the normal 30-second interval, load for 60 seconds,
        // then allow the two official network-path probes to finish.
        let completionAt=30.0+60+18
        XCTAssertLessThan(completionAt,timing.permitMaxAge)
        XCTAssertEqual(timing.permitMaxAge,110)
        XCTAssertGreaterThanOrEqual(110,timing.permitMaxAge)
    }
}
