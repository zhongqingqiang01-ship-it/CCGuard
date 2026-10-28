import XCTest
@testable import CCGuardCore

final class ErrorHistoryTests:XCTestCase {
    func testLegacyErrorImportedWhileSuccessAndMalformedLinesAreIgnored() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session=root.appendingPathComponent("Sessions/example")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        let lines=[
            "{\"time\":\"2026-10-28T05:51:18Z\",\"message\":\"已拦截：Claude 服务状态不符合要求\"}",
            "{\"time\":\"2026-10-28T05:51:19Z\",\"message\":\"所有 VS Code 窗口及关联子进程已退出：检测失败\"}",
            "{unfinished"]
        try lines.joined(separator:"\n").write(to:session.appendingPathComponent("events.jsonl"),atomically:true,encoding:.utf8)
        let result=ErrorHistory.load(root:root)
        XCTAssertEqual(result.entries.count,1)
        XCTAssertEqual(result.entries.first?.level,.error)
        XCTAssertEqual(result.entries.first?.sessionID,"example")
    }

    func testStructuredWarningsStayDistinctFromErrorsAndDuplicatesAreMerged() throws {
        let error=Data("{\"time\":\"2026-10-28T05:51:18Z\",\"message\":\"已拦截：DNS 缺失\"}".utf8)
        let warning=Data("{\"time\":\"2026-10-28T05:51:19.123Z\",\"message\":\"全局服务轻微故障\",\"level\":\"warning\",\"stage\":\"检测网络环境\"}".utf8)
        let first=try XCTUnwrap(HistoryEntry.decode(error,sessionID:"a",sourcePath:"/a"))
        let second=try XCTUnwrap(HistoryEntry.decode(warning,sessionID:"a",sourcePath:"/a"))
        let merged=HistoryEntry.merging([first,second,first])
        XCTAssertEqual(merged.count,2)
        XCTAssertEqual(merged.first?.level,.warning)
        XCTAssertEqual(merged.first?.stage,"检测网络环境")
    }

    func testUnplannedWatchdogStopImportedButNormalRequestedStopIsNotError() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let session=root.appendingPathComponent("Sessions/worker")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        try Data("{\"time\":\"2026-10-28T05:51:18Z\",\"reason\":\"主程序心跳停止\"}".utf8).write(to:session.appendingPathComponent("watchdog-stop.json"))
        XCTAssertEqual(ErrorHistory.load(root:root).entries.count,1)
        try Data("nonce".utf8).write(to:session.appendingPathComponent("stop-request"))
        XCTAssertTrue(ErrorHistory.load(root:root).entries.isEmpty)
    }
}
