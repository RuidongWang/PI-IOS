import XCTest
@testable import PIiOSCore
@testable import PIiOSNet

final class RACPExtensionEventsTests: XCTestCase {
    func testQueriesUseReadOnlyWireAndExtensionEventsAreAcknowledged() async throws {
        let socket = ExtensionRecordingSocket()
        let client = RACPClient(testingSocket: socket, subscriptionId: "sub", subscribedSessionId: "s")
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        let inventory: RACPExtensionInventory = try await client.request(
            .extensionList, params: .object([:]), timeout: 2)
        let result: RACPSessionExtensions = try await client.request(
            .sessionExtensions, params: .object(["sessionId": .string("s")]), timeout: 2)
        XCTAssertEqual(inventory.hostId, "h")
        XCTAssertNil(result.latestAttempt)
        XCTAssertEqual(socket.params("extension/list"), .object([:]))
        XCTAssertEqual(socket.params("session/extensions"), .object(["sessionId": .string("s")]))
        let notification: JSONValue = .object([
            "jsonrpc": .string("2.0"), "method": .string("events/event"),
            "params": .object(["event": try makeEvent(sequence: 41).payload])
        ])
        await client.receiveForTesting(try JSONEncoder().encode(notification))
        await fulfillment(of: [socket.ack], timeout: 3)
        XCTAssertEqual(socket.params("events/ack")?.value(at: ["sequence"])?.intValue, 41)
        XCTAssertEqual(socket.params("events/ack")?.value(at: ["subscriptionId"])?.stringValue, "sub")
        await socket.close()
        await pump.value
    }

    func testExtensionEventRoutesOnlyToItsSessionAndAdvancesLegacyReducerCursor() throws {
        let event = try makeEvent(sequence: 41)
        XCTAssertEqual(RACPEventRouter.route(event, currentSessionID: "s"), .session(event))
        XCTAssertEqual(RACPEventRouter.route(event, currentSessionID: "other"), .ignored)
        var reducer = SessionViewModel()
        _ = reducer.applyEvents([event])
        XCTAssertEqual(reducer.cursor, RACPCursor(epoch: "ep", sequence: 41))
        XCTAssertTrue(reducer.items.isEmpty, "extension state must never become a chat item")
        XCTAssertEqual(event.extensionSnapshot?.id, "snapshot")
        _ = reducer.applyEvents([try makeEvent(sequence: 42)])
        XCTAssertEqual(reducer.cursor?.sequence, 42, "unknown additive events must not freeze ACK progress")
    }

    func testDuplicateExtensionEventDoesNotAppendMessagesOrRegressCursor() throws {
        var reducer = SessionViewModel()
        _ = reducer.applyEvents([try makeEvent(sequence: 42)])
        _ = reducer.applyEvents([try makeEvent(sequence: 41), try makeEvent(sequence: 42)])
        XCTAssertEqual(reducer.cursor?.sequence, 42)
        XCTAssertTrue(reducer.items.isEmpty)
    }

    private func makeEvent(sequence: Int) throws -> RACPEvent {
        try RACPEvent.decoded(from: .object([
            "scope": .string("session"), "kind": .string("session.extensions.updated"), "sessionId": .string("s"),
            "turnId": .string("t"), "epoch": .string("ep"), "sequence": .number(Double(sequence)),
            "payload": .object([
                "id": .string("snapshot"), "hostId": .string("h"), "sessionId": .string("s"), "turnId": .string("t"),
                "configRevision": .string("c"), "revision": .number(1), "startedAt": .string("2026-11-12T12:00:00Z"),
                "completedAt": .null, "phase": .string("ready"), "entries": .array([]), "diagnostics": .array([])
            ])
        ]))
    }
}

private final class ExtensionRecordingSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let ack = XCTestExpectation(description: "extension event ACK")
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var requests: [String: JSONValue] = [:]

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func params(_ method: String) -> JSONValue? { lock.withLock { requests[method] } }

    func send(text: String) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard let method = request.value(at: ["method"])?.stringValue,
              let id = request.value(at: ["id"]) else { return }
        let first = lock.withLock {
            let first = requests[method] == nil
            requests[method] = request.value(at: ["params"])
            return first
        }
        let result: JSONValue
        if method == "extension/list" {
            result = .object(["hostId": .string("h"), "configRevision": .string("c"), "userLoadingEnabled": .bool(false),
                              "capturedAt": .string("2026-11-12T12:00:00Z"), "entries": .array([])])
        } else if method == "session/extensions" {
            result = .object(["hostId": .string("h"), "sessionId": .string("s"), "configRevision": .string("c"),
                              "userLoadingEnabled": .bool(false), "runningTurnId": .null, "latestAttempt": .null, "previousCompleted": .null])
        } else {
            result = .object([:])
        }
        continuation.yield(try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])))
        if method == "events/ack", first { ack.fulfill() }
    }

    func close() async { continuation.finish() }
    func waitUntilClosed() async { await Task.yield() }
}
