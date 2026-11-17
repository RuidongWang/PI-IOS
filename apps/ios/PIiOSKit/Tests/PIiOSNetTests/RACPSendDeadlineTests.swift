import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

/// Request deadlines must cover the send phase before a JSON-RPC waiter exists,
/// and an abandoned write must close only the generation that owned that write.
final class RACPSendDeadlineTests: XCTestCase {
    func testStalledSendHonorsDeadlineAndAbandonsExactlyOnce() async throws {
        let gate = UncooperativeSendGate()
        let abandoned = LockedCounter()
        let box = PendingRequest.testing(method: "turn/start")
        let started = ContinuousClock.now
        let call = Task {
            try await box.wait(
                timeout: 0.25,
                method: "turn/start",
                send: { try await gate.send() },
                abandonSend: { abandoned.increment() }
            )
        }

        await fulfillment(of: [gate.started], timeout: 2)
        do {
            _ = try await call.value
            XCTFail("stalled send must not wait forever")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("turn/start"))
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertEqual(abandoned.value, 1)
        gate.release()
    }

    func testCancellationDuringStalledSendAbandonsOnce() async throws {
        let gate = UncooperativeSendGate()
        let abandoned = LockedCounter()
        let box = PendingRequest.testing(method: "turn/start")
        let started = ContinuousClock.now
        let call = Task {
            try await box.wait(
                timeout: 5,
                method: "turn/start",
                send: { try await gate.send() },
                abandonSend: { abandoned.increment() }
            )
        }

        await fulfillment(of: [gate.started], timeout: 2)
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("cancellation must resume the waiter")
        } catch is CancellationError {
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertEqual(abandoned.value, 1)
        gate.release()
    }

    func testResponseTimeoutAfterSuccessfulSendDoesNotAbandonSocket() async throws {
        let abandoned = LockedCounter()
        let box = PendingRequest.testing(method: "connection/ping")
        let started = ContinuousClock.now
        do {
            _ = try await box.wait(
                timeout: 0.2,
                method: "connection/ping",
                send: { try await Task.sleep(for: .milliseconds(40)) },
                abandonSend: { abandoned.increment() }
            )
            XCTFail("no response should time out")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("connection/ping"))
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertEqual(abandoned.value, 0, "ordinary response timeout must not close a healthy socket")
    }

    func testProgressExtendsIdleButCannotExceedAbsoluteCeiling() async throws {
        let progress = RACPReceiveProgress()
        let abandoned = LockedCounter()
        let feeder = Task {
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                progress.record(bytes: 1)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let box = PendingRequest.testing(method: "session/history")
        let started = ContinuousClock.now
        do {
            _ = try await box.wait(
                timeout: 0.15,
                method: "session/history",
                receiveProgress: progress,
                maximumDuration: 0.55,
                send: { try await Task.yield() },
                abandonSend: { abandoned.increment() }
            )
            XCTFail("absolute ceiling should win")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("session/history"))
        }

        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(0.4))
        XCTAssertLessThan(elapsed, .seconds(1.5))
        XCTAssertEqual(abandoned.value, 0)
        feeder.cancel()
    }

    func testProgressPathStartsResponseIdleAtSendBoundary() async throws {
        let progress = RACPReceiveProgress()
        let box = PendingRequest.testing(method: "session/history")
        let started = ContinuousClock.now
        do {
            _ = try await box.wait(
                timeout: 0.3,
                method: "session/history",
                receiveProgress: progress,
                maximumDuration: 0.9,
                send: { try await Task.sleep(for: .milliseconds(80)) },
                abandonSend: { XCTFail("send completed before its deadline") }
            )
            XCTFail("absolute response deadline should still apply")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("session/history"))
        }

        let elapsed = started.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(0.34))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testProgressCeilingsRemain120And60Seconds() {
        XCTAssertEqual(racpResponseProgressCeiling, 120)
        XCTAssertEqual(racpHeartbeatProgressCeiling, 60)
    }

    func testNetworkDeadlineDoesNotJoinUncooperativeOperation() async throws {
        let gate = UncooperativeSendGate()
        let started = ContinuousClock.now
        do {
            _ = try await withNetworkDeadline(
                seconds: 0.2,
                timeoutError: { DeadlineTestError() }
            ) {
                try await gate.send()
                return 1
            }
            XCTFail("deadline should win even when the operation ignores cancellation")
        } catch is DeadlineTestError {
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        gate.release()
    }

    func testStalledNotificationSendClosesOriginalSocket() async throws {
        let socket = StallingSocket()
        let started = ContinuousClock.now
        let call = Task {
            try await sendRACPMessageWithDeadline(
                "{\"jsonrpc\":\"2.0\"}",
                to: socket,
                timeout: 0.2,
                phase: "RACP 初始化通知"
            )
        }

        await fulfillment(of: [socket.sendStarted], timeout: 2)
        do {
            try await call.value
            XCTFail("stalled notification must time out")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("RACP 初始化通知"))
        }

        await waitUntil { socket.closeCount == 1 }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        socket.releaseSend()
    }

    func testRawRequestWithStalledSendSettlesOnceAndClosesOriginalSocket() async throws {
        let socket = StallingSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: nil,
            subscribedSessionId: nil
        )
        let call = Task { () -> JSONValue in
            try await client.v2Request(
                method: "provider/list",
                params: .object([:]),
                timeout: 0.25
            )
        }

        await fulfillment(of: [socket.sendStarted], timeout: 2)
        do {
            _ = try await call.value
            XCTFail("raw v2 request must honor the send deadline")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("provider/list"))
        }

        await waitUntil { socket.closeCount == 1 }
        let pending = await client.pendingRequestCountForTesting()
        XCTAssertEqual(pending, 0)
        socket.releaseSend()
        await client.stop()
    }

    func testOrdinaryRequestStalledSendAbortsOriginalAndStateStreamRecovers() async throws {
        let original = StallingSocket(scripted: true)
        let replacement = StallingSocket(scripted: true)
        let client = makeReconnectingClient(original: original, replacement: replacement)
        let observed = OnlineGenerationRecorder()
        let statuses = await client.statusStream()
        let observer = Task {
            for await status in statuses {
                if status.phase == .online(.ssh), let generation = status.activeGeneration {
                    observed.record(generation)
                }
            }
            observed.finish()
        }
        await client.start()
        let first = try await waitForOnline(client)
        original.armFault()
        let started = ContinuousClock.now
        let call = Task { () -> JSONValue in
            // Exercise the public ordinary request path, not raw v2 or a box seam.
            try await client.request(.ping, params: EmptyDeadlineParams(), timeout: 0.2)
        }
        await fulfillment(of: [original.sendStarted], timeout: 2)
        do {
            _ = try await call.value
            XCTFail("ordinary request must enforce a deadline around uncooperative send")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("connection/ping"))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1.2))
        let recovered = try await waitForOnline(client, after: first)
        let pending = await client.pendingRequestCountForTesting()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(original.abortCount, 1)
        XCTAssertEqual(original.closeCount, 1)
        XCTAssertEqual(replacement.abortCount, 0, "late old-generation cleanup must never abort replacement")
        XCTAssertEqual(replacement.closeCount, 0)
        await waitUntil { observed.contains(recovered) }
        XCTAssertFalse(observed.finished, "a send failure must not terminate the state stream")
        let pong: JSONValue = try await client.request(
            .ping, params: EmptyDeadlineParams(), timeout: 1
        )
        XCTAssertEqual(pong.value(at: ["ok"])?.boolValue, true)
        await client.stop()
        await observer.value
    }

    func testOrdinaryAndRawSendFailureSettleOnceWithoutPendingLeak() async throws {
        for raw in [false, true] {
            let original = StallingSocket(scripted: true, throwOnFault: true)
            let replacement = StallingSocket(scripted: true)
            let client = makeReconnectingClient(original: original, replacement: replacement)
            await client.start()
            let first = try await waitForOnline(client)
            original.armFault()
            let completions = LockedCounter()
            let call = Task {
                defer { completions.increment() }
                if raw {
                    let _: JSONValue = try await client.v2Request(
                        method: "connection/ping", params: .object([:]), timeout: 1
                    )
                } else {
                    let _: JSONValue = try await client.request(
                        .ping, params: EmptyDeadlineParams(), timeout: 1
                    )
                }
            }
            do {
                try await call.value
                XCTFail("write failure must reach its request waiter")
            } catch let error as RACPClientError {
                XCTAssertEqual(error, .notConnected)
            }
            _ = try await waitForOnline(client, after: first)
            // A response delivered after the write failure cannot revive its waiter.
            await original.deliverLateFaultResponse(to: client)
            let pending = await client.pendingRequestCountForTesting()
            XCTAssertEqual(pending, 0)
            XCTAssertEqual(completions.value, 1)
            XCTAssertEqual(original.abortCount, 1)
            XCTAssertEqual(replacement.abortCount, 0)
            let pong: JSONValue = try await client.request(
                .ping, params: EmptyDeadlineParams(), timeout: 1
            )
            XCTAssertEqual(pong.value(at: ["ok"])?.boolValue, true)
            XCTAssertEqual(replacement.closeCount, 0, "healthy replacement must stay usable")
            await client.stop()
        }
    }

    func testSendFailureAndLateResolutionResumeWaiterExactlyOnce() async throws {
        let box = PendingRequest.testing(method: "turn/start")
        let completed = LockedCounter()
        let abandoned = LockedCounter()
        let started = XCTestExpectation(description: "failed write started")
        let call = Task {
            defer { completed.increment() }
            return try await box.wait(
                timeout: 1,
                method: "turn/start",
                send: {
                    started.fulfill()
                    throw DeadlineTestError()
                },
                abandonSend: { abandoned.increment() }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        do {
            _ = try await call.value
            XCTFail("write error must settle the waiter")
        } catch is DeadlineTestError {}
        box.resolve(.success(.string("late response")))
        box.resolve(.failure(CancellationError()))
        XCTAssertEqual(completed.value, 1)
        XCTAssertEqual(abandoned.value, 1)
    }

    func testOrdinaryResponseTimeoutDoesNotCloseSocket() async throws {
        let socket = SilentSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: nil,
            subscribedSessionId: nil
        )
        let started = ContinuousClock.now
        do {
            try await client.ping(timeout: 0.2)
            XCTFail("ping should time out without a response")
        } catch let error as RACPClientError {
            XCTAssertEqual(error, .timedOut("connection/ping"))
        }

        XCTAssertLessThan(started.duration(to: .now), .seconds(1.5))
        XCTAssertEqual(socket.closeCount, 0, "normal response timeout must keep the socket")
        let pending = await client.pendingRequestCountForTesting()
        XCTAssertEqual(pending, 0)
        await client.stop()
    }

    func testAbandonClosesCapturedGenerationOnly() async throws {
        let oldSocket = SilentSocket()
        let newSocket = SilentSocket()
        let gate = UncooperativeSendGate()
        let oldBox = PendingRequest.testing(method: "turn/start")
        let oldCall = Task {
            try await oldBox.wait(
                timeout: 0.2,
                method: "turn/start",
                send: { try await gate.send() },
                abandonSend: { Task { await oldSocket.close() } }
            )
        }
        await fulfillment(of: [gate.started], timeout: 2)
        do {
            _ = try await oldCall.value
            XCTFail("old generation should time out")
        } catch {}
        await waitUntil { oldSocket.closeCount == 1 }
        XCTAssertEqual(newSocket.closeCount, 0)

        let newBox = PendingRequest.testing(method: "ping")
        do {
            _ = try await newBox.wait(
                timeout: 0.1,
                method: "ping",
                send: { try await Task.yield() },
                abandonSend: { Task { await newSocket.close() } }
            )
            XCTFail("new generation should time out without a response")
        } catch {}
        XCTAssertEqual(newSocket.closeCount, 0, "old-generation cleanup must not close the replacement")
        gate.release()
    }

    func testConcurrentResolutionKeepsFirstResult() async throws {
        let box = PendingRequest.testing(method: "session/get")
        let call = Task {
            try await box.wait(
                timeout: 1,
                method: "session/get",
                send: { try await Task.yield() }
            )
        }
        box.resolve(.success(.string("first")))
        box.resolve(.success(.string("second")))
        let value = try await call.value
        XCTAssertEqual(value.stringValue, "first")
    }

    private func makeReconnectingClient(
        original: StallingSocket,
        replacement: StallingSocket
    ) -> RACPClient {
        RACPClient(
            configuration: RACPConfiguration(
                ssh: SSHConnectionRequest(
                    host: "unused.invalid", port: 22, username: "test",
                    credential: .password("unused"), pinnedHostKey: nil
                ),
                hostPort: 1,
                deviceToken: "test-device-token"
            ),
            connectionFactory: DeadlineConnectionFactory([original, replacement]),
            backoff: ReconnectBackoff(schedule: [0.001], maximumDelay: 0.001)
        )
    }

    private func waitForOnline(
        _ client: RACPClient,
        after generation: UUID? = nil
    ) async throws -> UUID {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let status = await client.connectionStatus()
            if status.phase == .online(.ssh), let active = status.activeGeneration,
               active != generation { return active }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("client did not publish a new online generation")
        throw DeadlineTestError()
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "condition not met before timeout", file: file, line: line)
    }
}

private struct DeadlineTestError: Error {}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// Mirrors an uncooperative NIO write: completion is independent of task
/// cancellation, so only the outer deadline or a physical close can end it.
private final class UncooperativeSendGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "send started")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var released = false
    private var didStart = false

    func send() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = lock.withLock { () -> (resume: Bool, announce: Bool) in
                if released { return (true, false) }
                self.continuation = continuation
                if !didStart {
                    didStart = true
                    return (false, true)
                }
                return (false, false)
            }
            if outcome.resume {
                continuation.resume()
            } else if outcome.announce {
                started.fulfill()
            }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class StallingSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let sendStarted = XCTestExpectation(description: "socket send started")

    private let continuation: AsyncStream<Data>.Continuation
    private let termination = RACPSocketTerminationState()
    private let gate = UncooperativeSendGate()
    private let lock = NSLock()
    private let scripted: Bool
    private let throwOnFault: Bool
    private var faultArmed = false
    private var faultRequestID: JSONValue?
    private var closeCalls = 0
    private var abortCalls = 0
    private var closed = false

    init(scripted: Bool = false, throwOnFault: Bool = false) {
        self.scripted = scripted
        self.throwOnFault = throwOnFault
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    var closeCount: Int { lock.withLock { closeCalls } }
    var abortCount: Int { lock.withLock { abortCalls } }
    var terminationError: RACPSocketTermination {
        get async { await termination.wait() }
    }

    func armFault() { lock.withLock { faultArmed = true } }

    func send(text: String) async throws {
        let request = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let method = request?.value(at: ["method"])?.stringValue
        let fault = lock.withLock {
            !scripted || (faultArmed && method == "connection/ping")
        }
        if fault {
            lock.withLock { faultRequestID = request?.value(at: ["id"]) }
            sendStarted.fulfill()
            if throwOnFault { throw DeadlineTestError() }
            // Ignores Task.cancel(); only physical abort/close releases the gate.
            try await gate.send()
            return
        }
        guard let id = request?.value(at: ["id"]) else { return }
        let result: JSONValue
        switch method {
        case "connection/initialize":
            result = .object([
                "protocolVersion": .string("1.0"),
                "server": .object(["name": .string("test"), "version": .string("1")]),
                "connectionId": .string("test_connection"),
                "principal": .object(["roles": .array([.string("owner")])]),
            ])
        case "connection/ping":
            result = .object(["ok": .bool(true), "serverTime": .string("2026-11-09T00:00:00Z")])
        case "events/subscribe":
            result = .object([
                "subscriptionId": .string("test_subscription"),
                "replayComplete": .bool(true),
                "starting": .object(["epoch": .string("test_epoch"), "sequence": .number(0)]),
            ])
        case "project/list": result = .object(["projects": .array([])])
        case "session/list": result = .object(["sessions": .array([])])
        default: result = .object([:])
        }
        continuation.yield(try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "result": result,
        ])))
    }

    func deliverLateFaultResponse(to client: RACPClient) async {
        guard let id = lock.withLock({ faultRequestID }),
              let data = try? JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object(["ok": .bool(true)]),
              ])) else { return }
        await client.receiveForTesting(data)
    }

    func releaseSend() { gate.release() }
    func close() async { finish(.localCanceled, abort: false) }
    func abort(_ termination: RACPSocketTermination) async { finish(termination, abort: true) }

    private func finish(_ termination: RACPSocketTermination, abort: Bool) {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            closeCalls += 1
            if abort { abortCalls += 1 }
            return true
        }
        guard shouldClose else { return }
        gate.release()
        continuation.finish()
        self.termination.finish(termination)
    }

    func waitUntilClosed() async { _ = await termination.wait() }
}

private struct EmptyDeadlineParams: Encodable, Sendable {}

private final class DeadlineConnectionFactory: RACPConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [StallingSocket]

    init(_ sockets: [StallingSocket]) { self.sockets = sockets }

    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        let socket = lock.withLock { () -> StallingSocket? in
            sockets.isEmpty ? nil : sockets.removeFirst()
        }
        guard let socket else { throw RACPConnectionError(category: .internal) }
        return RACPConnection(socket: socket, route: route)
    }
}

private final class OnlineGenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: Set<UUID> = []
    private var didFinish = false
    func record(_ generation: UUID) { lock.withLock { _ = generations.insert(generation) } }
    func contains(_ generation: UUID) -> Bool { lock.withLock { generations.contains(generation) } }
    func finish() { lock.withLock { didFinish = true } }
    var finished: Bool { lock.withLock { didFinish } }
}

private final class SilentSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closeCalls = 0
    private var closed = false

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    var closeCount: Int {
        lock.withLock { closeCalls }
    }

    func send(text: String) async throws {}

    func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            closeCalls += 1
            return true
        }
        guard shouldClose else { return }
        continuation.finish()
    }

    func waitUntilClosed() async {
        await Task.yield()
    }
}
