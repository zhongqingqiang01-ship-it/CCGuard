import XCTest
@testable import CCGuardCore

@MainActor final class PageInspectionScheduleTests: XCTestCase {
    func testFastPageCannotPassBeforeTenSeconds() async throws {
        var time=0.0
        var navigations:[Double]=[]
        let value=try await PageInspectionSchedule.run(allowRefresh:true, navigate:{
            navigations.append(time)
        },read:{
            XCTAssertGreaterThanOrEqual(time-navigations.last!,10)
            return "complete"
        },now:{ time },sleep:{ time += $0 })
        XCTAssertEqual(value,"complete")
        XCTAssertEqual(navigations,[0])
        XCTAssertEqual(time,10)
    }

    func testIncompletePageWaitsTenSecondsThenFreshNavigationAndWaitsAgain() async throws {
        var time=0.0, attempts=0
        var navigations:[Double]=[], reads:[Double]=[]
        let value=try await PageInspectionSchedule.run(allowRefresh:true,navigate:{
            attempts += 1; navigations.append(time)
        },read:{
            reads.append(time)
            if attempts==1 { throw PageInspectionFailure("缺少评分",mayRefresh:true) }
            return "complete"
        },now:{ time },sleep:{ time += $0 })
        XCTAssertEqual(value,"complete")
        XCTAssertEqual(navigations,[0,20])
        XCTAssertEqual(reads,[10,30])
    }

    func testSecondFailureStopsWithoutThirdNavigation() async {
        var navigations=0
        do {
            _ = try await PageInspectionSchedule.run(allowRefresh:true,navigate:{ navigations += 1 },read:{
                throw PageInspectionFailure("IP 不一致",mayRefresh:true)
            },now:{ 0 },sleep:{ _ in })
            XCTFail("Repeated mismatch must fail closed")
        } catch { XCTAssertEqual((error as? PageInspectionFailure)?.message,"IP 不一致") }
        XCTAssertEqual(navigations,2)
    }

    func testConfirmedRiskDoesNotRefreshAndMonitoringDoesNotRetry() async {
        for (allowRefresh,mayRefresh) in [(true,false),(false,true)] {
            var navigations=0
            var waits:[Double]=[]
            do {
                _ = try await PageInspectionSchedule.run(allowRefresh:allowRefresh,navigate:{ navigations += 1 },read:{
                    throw PageInspectionFailure("未通过",mayRefresh:mayRefresh)
                },now:{ 0 },sleep:{ waits.append($0) })
                XCTFail("Failure must deny access")
            } catch { XCTAssertTrue(error is PageInspectionFailure) }
            XCTAssertEqual(navigations,1)
            XCTAssertEqual(waits,[10])
        }
    }

    func testCancellationDuringLoadOrRetryNeverNavigatesAgain() async {
        for cancelOnWait in [1,2] {
            var navigations=0,waits=0,reads=0
            let task=Task { @MainActor in
                try await PageInspectionSchedule.run(allowRefresh:true,navigate:{ navigations += 1 },read:{
                    reads += 1
                    throw PageInspectionFailure("尚未完成",mayRefresh:true)
                },now:{ 0 },sleep:{ _ in
                    waits += 1
                    if waits==cancelOnWait {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            }
            do { _ = try await task.value; XCTFail("Must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(navigations,1)
            XCTAssertEqual(reads,cancelOnWait==1 ? 0 : 1)
        }
    }

    func testTransientFailureCannotHideConfirmedRisk() {
        var snapshot=DetectionSnapshot(timeOrigin:1,collectedAt:1,sourceFailures:["获取失败"],timezoneConsistent:false)
        XCTAssertTrue(snapshot.mayRefreshAfterFailure())
        snapshot.score=90
        XCTAssertFalse(snapshot.mayRefreshAfterFailure())
        snapshot.score=100; snapshot.proxy=true
        XCTAssertFalse(snapshot.mayRefreshAfterFailure())
        snapshot.proxy=false; snapshot.dnsSafe=false
        XCTAssertFalse(snapshot.mayRefreshAfterFailure())
    }
    func testNavigationTimeCountsTowardMinimumWaitInsteadOfAddingAnotherTenSeconds() async throws {
        var time=0.0
        var waits:[Double]=[]
        let readAt=try await PageInspectionSchedule.run(allowRefresh:false,navigate:{
            time += 20
        },read:{ time },now:{ time },sleep:{ waits.append($0);time += $0 })
        XCTAssertEqual(readAt,20)
        XCTAssertEqual(waits,[0])
    }
}
