import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class RACPTurnLifecycleTests: XCTestCase {
    func testReadOnlySessionRejectsSendingUntilAValidatedReopen() async throws {
        let socket = DeferredTurnSocket()
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: "session_2")
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        defer { pump.cancel() }
        socket.setReadOnlyReason("append_unverified")
        _ = try await client.attach(sessionId: "session_2", subscribe: false)
        do {
            _ = try await client.startTurn(sessionId: "session_2", text: "draft", admission: nil, idempotencyKey: "draft", timeout: 1)
            XCTFail("A read-only session accepted the draft")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .server(code: .sessionReadOnly, message: "append_unverified"))
        }

        socket.setReadOnlyReason(nil)
        _ = try await client.attach(sessionId: "session_2", subscribe: false)
        let start = Task {
            try await client.startTurn(sessionId: "session_2", text: "draft", admission: nil, idempotencyKey: "draft")
        }
        await fulfillment(of: [socket.startReceived], timeout: 2)
        socket.finishTurn(status: "completed")
        let result = try await start.value
        XCTAssertEqual(result.turn.status, "completed")
        await socket.close()
    }

    func testLateQueuedResponseDoesNotEnterReplacementSession() async throws {
        let socket = DeferredTurnSocket()
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: "session_1")
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        defer { pump.cancel() }
        let start = Task {
            try await client.startTurn(sessionId: "session_1", text: "old draft", admission: .queue, idempotencyKey: "old-attempt")
        }
        await fulfillment(of: [socket.startReceived], timeout: 2)
        _ = try await client.attach(sessionId: "session_2", subscribe: false)
        socket.finishTurn(status: "queued")

        let result = try await start.value
        XCTAssertEqual(result.turn.id, "turn_fast")
        let current = await client.sessionView()
        XCTAssertEqual(current.sessionId, "session_2")
        XCTAssertTrue(current.queuedTurns.isEmpty)
        XCTAssertNil(current.runningTurnId)
        await socket.close()
    }

    func testRetriedQueuedReceiptUsesCurrentUncertainTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("requests.json")
        let request = SessionRequestIdentity(hostID: "host", sessionID: "session_1", action: .turn(text: "draft"))
        let first = try SessionRequestKeyStore(fileURL: file).prepareSubmission(request, admission: .queue)
        let retry = try SessionRequestKeyStore(fileURL: file).prepareSubmission(request)
        XCTAssertFalse(first.isRetry)
        XCTAssertTrue(retry.isRetry)
        XCTAssertEqual(first.attempt, retry.attempt)

        let socket = DeferredTurnSocket(statusForGet: "uncertain")
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: "session_1")
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        defer { pump.cancel() }
        let send = Task {
            try await client.startTurn(
                sessionId: "session_1", text: "draft", admission: retry.attempt.admission,
                idempotencyKey: retry.attempt.idempotencyKey, isRetry: retry.isRetry, timeout: 3
            )
        }
        await fulfillment(of: [socket.startReceived], timeout: 2)
        socket.finishTurn(status: "queued")
        let reconciled = try await send.value

        XCTAssertEqual(reconciled.turn.status, "uncertain")
        let view = await client.sessionView()
        XCTAssertTrue(view.queuedTurns.isEmpty)
        XCTAssertNil(view.runningTurnId)
        await socket.close()
    }

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
    private var readOnlyReason: String?
    private let statusForGet: String?

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }


    init(statusForGet: String? = nil) {
        self.statusForGet = statusForGet
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

    func setReadOnlyReason(_ reason: String?) {
        withLock { readOnlyReason = reason }
    }

    func send(text: String) async throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = object["method"] as? String
        else { return }
        switch method {
        case "turn/start":
            withLock { requestID = object["id"] }
            startReceived.fulfill()
        case "turn/get":
            if let id = object["id"], let statusForGet,
               let params = object["params"] as? [String: Any],
               params["turnId"] as? String == "turn_fast" {
                let response = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["turn": ["id": "turn_fast", "sessionId": "session_1", "status": statusForGet]],
                ])
                continuation.yield(response)
            }
        case "session/attach":
            if let id = object["id"] {
                var summary = ["id": "session_2"]
                summary["readOnlyReason"] = withLock { readOnlyReason }
                let response = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["session": summary, "replayComplete": true],
                ])
                continuation.yield(response)
            }
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
