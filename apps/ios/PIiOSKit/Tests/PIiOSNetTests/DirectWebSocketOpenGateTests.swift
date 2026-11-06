import Foundation
import XCTest

@testable import PIiOSNet

/// `DirectWebSocketOpenGate` 是 101 升级成功的唯一判据，必须做到：
/// open / 失败 / 取消 三者只有第一个生效；迟到回调、并发结算与取消都不能让等待者悬挂。
final class DirectWebSocketOpenGateTests: XCTestCase {
    func testOpenSettlesWithNegotiatedProtocol() async {
        let gate = DirectWebSocketOpenGate()
        gate.settleOpen(negotiatedProtocol: RACPWebSocket.subprotocol)
        let outcome = await gate.wait()
        XCTAssertEqual(outcome, .opened(negotiatedProtocol: RACPWebSocket.subprotocol))
        XCTAssertTrue(gate.didOpen)
    }

    func testOpenWithoutNegotiatedProtocolIsStillAnObservedOpen() async {
        // 服务端没协商子协议时 delegate 给 nil：open 本身成立，是否可接受由 connect 判 protocol。
        let gate = DirectWebSocketOpenGate()
        gate.settleOpen(negotiatedProtocol: nil)
        let outcome = await gate.wait()
        XCTAssertEqual(outcome, .opened(negotiatedProtocol: nil))
        XCTAssertTrue(gate.didOpen)
    }

    func testWaiterResumesWhenOpenArrivesLater() async throws {
        let gate = DirectWebSocketOpenGate()
        let waiter = Task { await gate.wait() }
        try await Task.sleep(for: .milliseconds(30))
        gate.settleOpen(negotiatedProtocol: RACPWebSocket.subprotocol)
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .opened(negotiatedProtocol: RACPWebSocket.subprotocol))
    }

    func testCloseBeforeOpenSettlesFailureCategory() async {
        // 101 之前收到非 1000 的 close（如 1008 device revoked）：只能失败，不能当成 open。
        let gate = DirectWebSocketOpenGate()
        gate.settleFailure(RACPConnectionError(category: .deviceRevoked))
        let outcome = await gate.wait()
        XCTAssertEqual(outcome, .failed(RACPConnectionError(category: .deviceRevoked)))
        XCTAssertFalse(gate.didOpen)
    }

    func testUnauthorizedUpgradeUsesExistingHTTPStatusMapping() async {
        let gate = DirectWebSocketOpenGate()
        gate.settleFailure(DirectRACPWebSocket.connectionError(forHTTPStatus: 401))
        let outcome = await gate.wait()
        XCTAssertEqual(
            outcome,
            .failed(RACPConnectionError(category: .authentication, httpStatus: 401))
        )
    }

    func testTLSTrustFailureWinsOverLaterTimeout() {
        // 契约 §4.2：已确定的 tlsTrust 不得被后续超时改写成 connectTimeout。
        let state = DirectRACPSessionState()
        state.recordTrustFailure()
        let mapped = DirectRACPWebSocket.map(URLError(.timedOut), task: nil, state: state)
        XCTAssertEqual(mapped.category, .tlsTrust)
    }

    func testCancellationBeforeOpenSettlesCanceledAndNeverHangs() async throws {
        let gate = DirectWebSocketOpenGate()
        let waiter = Task { () -> DirectWebSocketOpenGate.Outcome in
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                // connect 里的取消路径：自己结算闸门，不依赖 URLSession 回调。
                gate.settleCanceled()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .failed(RACPConnectionError(category: .canceled)))
        XCTAssertFalse(gate.didOpen)
    }

    func testLateOpenAfterCancellationDoesNotOverrideSettledOutcome() async {
        let gate = DirectWebSocketOpenGate()
        gate.settleCanceled()
        gate.settleOpen(negotiatedProtocol: RACPWebSocket.subprotocol)
        let outcome = await gate.wait()
        XCTAssertEqual(outcome, .failed(RACPConnectionError(category: .canceled)))
        // 但 open 事实仍要记录，供 delegate 区分 open 前后的 close。
        XCTAssertTrue(gate.didOpen)
    }

    func testConcurrentSettlementsResolveExactlyOnce() async {
        let gate = DirectWebSocketOpenGate()
        let sink = OutcomeSink()
        let waiters = (0..<16).map { _ in
            Task { await sink.append(gate.wait()) }
        }
        let settlers = (0..<32).map { index in
            Task {
                if index.isMultiple(of: 2) {
                    gate.settleOpen(negotiatedProtocol: "proto-\(index)")
                } else {
                    gate.settleFailure(RACPConnectionError(category: .tcp))
                }
            }
        }
        for settler in settlers { await settler.value }
        gate.settleOpen(negotiatedProtocol: RACPWebSocket.subprotocol)
        for waiter in waiters { await waiter.value }
        let outcomes = await sink.values()
        XCTAssertEqual(outcomes.count, 16)
        XCTAssertEqual(Set(outcomes.map(Self.describe)).count, 1, "所有等待者必须拿到同一个终局")
        if case .opened = outcomes[0] {
            XCTAssertTrue(gate.didOpen)
        }
    }

    func testSecondWaitReturnsSameSettledOutcome() async {
        let gate = DirectWebSocketOpenGate()
        gate.settleOpen(negotiatedProtocol: RACPWebSocket.subprotocol)
        let first = await gate.wait()
        let second = await gate.wait()
        XCTAssertEqual(first, second)
    }

    private static func describe(_ outcome: DirectWebSocketOpenGate.Outcome) -> String {
        switch outcome {
        case .opened(let `protocol`): return "opened:\(`protocol` ?? "nil")"
        case .failed(let error): return "failed:\(error.category.rawValue):\(error.httpStatus ?? -1)"
        }
    }
}

private actor OutcomeSink {
    private var storage: [DirectWebSocketOpenGate.Outcome] = []

    func append(_ outcome: DirectWebSocketOpenGate.Outcome) {
        storage.append(outcome)
    }

    func values() -> [DirectWebSocketOpenGate.Outcome] { storage }
}
