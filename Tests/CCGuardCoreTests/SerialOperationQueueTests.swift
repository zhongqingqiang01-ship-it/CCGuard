import XCTest
@testable import CCGuardCore

private actor ReplyChannel {
    var active=0
    var maximumActive=0
    var nextReply:Int?
    func exchange(_ id:Int) async throws -> Int {
        active += 1;maximumActive=max(maximumActive,active)
        defer { active -= 1 }
        nextReply=id
        try await Task.sleep(nanoseconds:1_000_000)
        return nextReply!
    }
}

final class SerialOperationQueueTests:XCTestCase {
    func testConcurrentRequestsCannotConsumeEachOthersReplies() async throws {
        let queue=SerialOperationQueue();let channel=ReplyChannel()
        try await withThrowingTaskGroup(of:(Int,Int).self) { group in
            for id in 0..<30 {
                group.addTask { (id,try await queue.run { try await channel.exchange(id) }) }
            }
            for try await (sent,received) in group { XCTAssertEqual(sent,received) }
        }
        let maximum=await channel.maximumActive
        XCTAssertEqual(maximum,1)
    }

    func testThrownOperationReleasesQueue() async throws {
        let queue=SerialOperationQueue()
        do {
            _ = try await queue.run { throw GuardFailure("连接失败") }
            XCTFail("Must throw")
        } catch { XCTAssertTrue(error is GuardFailure) }
        let result=try await queue.run { "next request" }
        XCTAssertEqual(result,"next request")
    }

    func testCancelledOperationDoesNotSendAndQueueRemainsUsable() async throws {
        let queue=SerialOperationQueue();let channel=ReplyChannel()
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run { try await channel.exchange(1) }
        }
        do { _ = try await task.value;XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let maximum=await channel.maximumActive
        XCTAssertEqual(maximum,0)
        let result=try await queue.run { try await channel.exchange(2) }
        XCTAssertEqual(result,2)
    }
}
