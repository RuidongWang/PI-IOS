import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class RACPTurnLifecycleTests: XCTestCase {
    func testLateRunningStartResponseDoesNotReviveCompletedTurn() async throws {
        let socket = DeferredTurnSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_1",
            subscribedSessionId: "session_1"
        )
        let pump = Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }
        let start = Task {
            try await client.startTurn(
                sessionId: "session_1",
                text: "a very short task",
                admission: nil,
                idempotencyKey: "turn_fast"
            )
        }
        await fulfillment(of: [socket.startReceived], timeout: 2)

        socket.enqueue(Self.event(
            sequence: 1,
            kind: "turn.started",
            turn: #"{"id":"turn_fast","status":"running"}"#
        ))
        socket.enqueue(Self.event(
            sequence: 2,
            kind: "turn.completed",
            turn: #"{"id":"turn_fast","status":"completed"}"#
        ))
        await fulfillment(of: [socket.completionReduced], timeout: 2)
        var view = await client.sessionView()
        XCTAssertNil(view.runningTurnId)

        socket.finishTurn(status: "running")
        _ = try await start.value
        view = await client.sessionView()
        XCTAssertNil(view.runningTurnId, "迟到的 start 响应不得复活已经完成的 turn")
        XCTAssertTrue(view.activeItems.isEmpty)

        await socket.close()
        pump.cancel()
    }

    func testCompletedResponseDoesNotEraseNextRunningTurn() async throws {
        let socket = DeferredTurnSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_1",
            subscribedSessionId: "session_1"
        )
        let pump = Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }
        let start = Task {
            try await client.startTurn(
                sessionId: "session_1",
                text: "previous queued turn",
                admission: .queue,
                idempotencyKey: "turn_fast"
            )
        }
        await fulfillment(of: [socket.startReceived], timeout: 2)
        socket.enqueue(Self.event(
            sequence: 1,
            kind: "turn.started",
            turn: #"{"id":"turn_next","status":"running"}"#,
            turnID: "turn_next"
        ))
        socket.finishTurn(status: "completed")
        _ = try await start.value

        let view = await client.sessionView()
        XCTAssertEqual(view.runningTurnId, "turn_next", "上一轮完成响应不得清掉已提升的下一轮")
        XCTAssertTrue(view.queuedTurns.isEmpty)

        await socket.close()
        pump.cancel()
    }

    private static func event(sequence: Int, kind: String, turn: String, turnID: String = "turn_fast") -> Data {
        Data("""
        {"jsonrpc":"2.0","method":"events/event","params":{"event":{"scope":"session","kind":"\(kind)","epoch":"epoch_1","sequence":\(sequence),"sessionId":"session_1","turnId":"\(turnID)","payload":{"turn":\(turn)}}}}
        """.utf8)
    }
}

private final class DeferredTurnSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let startReceived = XCTestExpectation(description: "turn/start received without a response")
    let completionReduced = XCTestExpectation(description: "completion event reduced")

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var requestID: Any?
    private var sawCompletion = false

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }


    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func enqueue(_ data: Data) {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let params = object["params"] as? [String: Any],
           let event = params["event"] as? [String: Any],
           event["kind"] as? String == "turn.completed" {
            withLock { sawCompletion = true }
        }
        continuation.yield(data)
    }

    func finishTurn(status: String) {
        let requestID = withLock { () -> Any? in
            defer { self.requestID = nil }
            return self.requestID
        }
        guard let requestID else { return }
        let response = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": requestID,
            "result": ["turn": ["id": "turn_fast", "sessionId": "session_1", "status": status]],
        ])
        continuation.yield(response)
    }

    func send(text: String) async throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = object["method"] as? String
        else { return }
        switch method {
        case "turn/start":
            withLock { requestID = object["id"] }
            startReceived.fulfill()
        case "events/ack":
            let shouldFulfill = withLock { () -> Bool in
                defer { if sawCompletion { sawCompletion = false } }
                return sawCompletion
            }
            if shouldFulfill { completionReduced.fulfill() }
            if let id = object["id"] {
                let response = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": id, "result": [:],
                ])
                continuation.yield(response)
            }
        default:
            break
        }
    }

    func close() async { continuation.finish() }
    func waitUntilClosed() async { await Task.yield() }
}
