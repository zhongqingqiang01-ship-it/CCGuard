import XCTest
@testable import CCGuardCore

@MainActor final class FakeDriver: WorkflowDriver {
    var calls: [String] = []
    var fail: String?
    var websiteWait: CheckedContinuation<Void, Error>?
    var delayWebsite = false
    func record(_ key: String) throws { calls.append(key); if fail == key { throw GuardFailure(key + "失败") } }
    func prepareProxy() async throws { try record("proxy") }
    func prepareTimezone() async throws { try record("timezone") }
    func inspectWebsite() async throws {
        try record("website")
        if delayWebsite { try await withCheckedThrowingContinuation { websiteWait = $0 } }
    }
    func armAndOpenEditor() async throws { try record("editor") }
    func didEnterGuarding() async { calls.append("background") }
    func closeEditors(reason: String) async throws { calls.append("close"); if fail == "close" { throw GuardFailure("退出失败") } }
}
final class WorkflowTests: XCTestCase {
    @MainActor func testCancelledQueuedStartCannotReactivateFlow() async {
        let driver=FakeDriver();let flow=Workflow(driver:driver)
        let task=Task { await flow.start() };task.cancel();await task.value
        XCTAssertEqual(flow.phase,.idle);XCTAssertTrue(driver.calls.isEmpty)
    }
    @MainActor func testOrderedSuccessfulFlow() async {
        let driver = FakeDriver(); let flow = Workflow(driver: driver)
        await flow.start()
        XCTAssertEqual(driver.calls, ["proxy", "timezone", "website", "editor", "background"])
        XCTAssertEqual(flow.completed, FlowStep.allCases); XCTAssertEqual(flow.phase, .guarding)
    }
    @MainActor func testEveryFailureStopsRemainingSteps() async {
        for (index, key) in ["proxy", "timezone", "website", "editor"].enumerated() {
            let driver = FakeDriver(); driver.fail = key; let flow = Workflow(driver: driver)
            await flow.start()
            XCTAssertEqual(driver.calls, Array(["proxy", "timezone", "website", "editor"].prefix(index+1)) + ["close"])
            XCTAssertEqual(flow.phase, .blocked)
        }
    }
    @MainActor func testWindowsStayVisibleWhileWebsiteIsPending() async {
        let driver=FakeDriver();driver.delayWebsite=true
        let flow=Workflow(driver:driver)
        let task=Task { await flow.start() }
        while driver.websiteWait == nil { await Task.yield() }
        XCTAssertFalse(driver.calls.contains("background"))
        driver.websiteWait?.resume();await task.value
        XCTAssertEqual(driver.calls.last,"background")
        XCTAssertEqual(driver.calls.filter{$0=="background"}.count,1)
        await flow.start()
        XCTAssertEqual(driver.calls.filter{$0=="background"}.count,1)
    }
    @MainActor func testCancellationAtGuardTransitionCannotMinimizeWindows() async {
        let driver=FakeDriver();let flow=Workflow(driver:driver)
        flow.onChange={
            if flow.phase == .guarding { withUnsafeCurrentTask{$0?.cancel()} }
        }
        let task=Task { await flow.start() };await task.value
        XCTAssertFalse(driver.calls.contains("background"))
        XCTAssertEqual(flow.phase,.blocked)
        XCTAssertEqual(driver.calls.last,"close")
    }
    @MainActor func testLateSuccessAfterTripCannotOpenEditor() async {
        let driver = FakeDriver(); driver.delayWebsite = true; let flow = Workflow(driver: driver)
        let task = Task { await flow.start() }
        while driver.websiteWait == nil { await Task.yield() }
        await flow.trip("本地断连")
        driver.websiteWait?.resume(); await task.value
        XCTAssertFalse(driver.calls.contains("editor")); XCTAssertEqual(flow.phase, .blocked)
    }
    @MainActor func testGuardFailureStopsAndDoesNotRestart() async {
        let driver = FakeDriver(); let flow = Workflow(driver: driver); await flow.start()
        await flow.trip("检测站超时")
        XCTAssertEqual(driver.calls.last, "close"); XCTAssertEqual(flow.phase, .blocked)
        XCTAssertEqual(driver.calls.filter { $0 == "editor" }.count, 1)
    }
    @MainActor func testStopFailureNeverShowsIdle() async {
        let driver = FakeDriver(); let flow = Workflow(driver: driver); await flow.start()
        driver.fail = "close"; await flow.finish(); XCTAssertEqual(flow.phase, .blocked)
    }
    func testProcessSelectionIncludesDescendantsButNotOtherProjectsAppsOrUsers() {
        let rows = [
            ProcessRecord(pid: 1,parent:0,uid:501,path:"/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            ProcessRecord(pid: 2,parent:1,uid:501,path:"/usr/bin/claude"),
            ProcessRecord(pid: 3,parent:2,uid:501,path:"/bin/sh"),
            ProcessRecord(pid: 4,parent:0,uid:501,path:"/Applications/Visual Studio Code.app.bad/run"),
            ProcessRecord(pid: 5,parent:0,uid:502,path:"/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            ProcessRecord(pid: 6,parent:0,uid:501,path:"/usr/bin/claude")]
        XCTAssertEqual(EditorSelection.records(rows, uid:501, appPath:"/Applications/Visual Studio Code.app").map(\.pid), [1,2,3])
    }
    func testLeaseRejectsStaleFutureAndWrongSession() {
        let lease = Lease(nonce:"a",parentPID:10,armed:true,heartbeat:100)
        XCTAssertTrue(lease.valid(nonce:"a",parentPID:10,uptime:102))
        XCTAssertFalse(lease.valid(nonce:"a",parentPID:10,uptime:105))
        XCTAssertFalse(lease.valid(nonce:"a",parentPID:10,uptime:99))
        XCTAssertFalse(lease.valid(nonce:"b",parentPID:10,uptime:102))
    }
    func testPIDReuseCannotAuthorizeTerminatingAnUnrelatedProcess() {
        let expected=ProcessRecord(pid:50,parent:1,uid:501,path:"/old/path",startSeconds:100,startMicroseconds:1)
        XCTAssertTrue(EditorSelection.sameProcess(expected,ProcessRecord(pid:50,parent:1,uid:501,path:"/resolved/alias",startSeconds:100,startMicroseconds:1)))
        XCTAssertFalse(EditorSelection.sameProcess(expected,ProcessRecord(pid:50,parent:1,uid:501,path:"/old/path",startSeconds:101,startMicroseconds:1)))
        XCTAssertFalse(EditorSelection.sameProcess(expected,ProcessRecord(pid:50,parent:1,uid:502,path:"/old/path",startSeconds:100,startMicroseconds:1)))
    }
}
