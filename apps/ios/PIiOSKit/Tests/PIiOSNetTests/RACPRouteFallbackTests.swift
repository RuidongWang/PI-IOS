import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class RACPRouteFallbackTests: XCTestCase {
    func testBootstrapDeviceIdentityUsesAuthenticatedPingHostID() async throws {
        let socket = ScriptedSocket()
        socket.pingHostID = "host_1"
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: nil,
            subscribedSessionId: nil
        )
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        let identity = try await client.verifyDeviceIdentityForTesting()
        pump.cancel()
        XCTAssertEqual(identity.adaptorHostId, "host_1")
        XCTAssertEqual(identity.serverInfo.hostId, "initialize-untrusted")
        await client.stop()
    }

    func testPromotionFenceBlocksBusinessWriteButKeepsReadOnlyPing() async throws {
        let socket = ScriptedSocket()
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        await client.setPromotionFenced(true)
        let status = await client.connectionStatus()
        XCTAssertTrue(status.promotionFenced)
        do {
            _ = try await client.startTurn(
                sessionId: "session_1",
                text: "blocked",
                admission: nil,
                idempotencyKey: "turn_key"
            )
            XCTFail("fence 期间不得发送业务写")
        } catch {}
        try await client.ping()
        XCTAssertFalse(socket.methods.contains("turn/start"))
        XCTAssertTrue(socket.methods.contains("connection/ping"))
        await client.setPromotionFenced(false)
        await client.stop()
        pump.cancel()
    }

    func testRecoveryContextAppliesSnapshotAndFinalReplayUsesC1Cursor() async throws {
        let socket = ScriptedSocket()
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let summary = try JSONDecoder().decode(
            RACPSessionSummary.self,
            from: Data("{\"id\":\"session_1\"}".utf8)
        )
        let snapshot = RACPSnapshot(
            cursor: RACPCursor(epoch: "epoch_1", sequence: 7),
            revision: 3,
            items: [],
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            pendingInputs: [],
            hasMoreHistory: false
        )
        let context = RACPRecoveryContext(
            hostCursor: RACPCursor(epoch: "epoch_1", sequence: 7),
            sessionId: "session_1",
            sessionSummary: summary,
            snapshot: snapshot,
            replayComplete: true
        )
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        let view = try await client.restoreRecoveryContext(context)
        pump.cancel()
        XCTAssertEqual(view.cursor, snapshot.cursor)
        XCTAssertEqual(view.summary, summary)
        XCTAssertEqual(socket.subscriptionAfterCursors, ["epoch_1:7", "epoch_1:7"])
        await client.stop()
    }

    func testProviderDiscoveryErrorPreservesUpstreamHTTPStatus() async throws {
        let socket = ScriptedSocket()
        socket.discoveryUpstreamStatus = 429
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = Task {
            for await data in socket.inbound { await client.receiveForTesting(data) }
        }
        do {
            let _: JSONValue = try await client.v2Request(
                method: RACPV2Method.providerDiscover.rawValue,
                params: .object([:])
            )
            XCTFail("应返回上游错误")
        } catch let error as RACPProviderDiscoveryError {
            XCTAssertEqual(error.code, "UPSTREAM_UNAVAILABLE")
            XCTAssertEqual(error.upstreamStatus, 429)
        }
        await client.stop()
        pump.cancel()
    }

    func testDefaultDirectBudgetIsEightSeconds() {
        XCTAssertEqual(RACPConnectionBudgets.default.directConnect, 8)
        XCTAssertEqual(RACPConnectionBudgets.default.sshConnect, 20)
        XCTAssertEqual(RACPConnectionBudgets.default.restore, 30)
    }

    func testIncompleteHostReplayLoadsDirectorySnapshotBeforeOnline() async throws {
        let socket = ScriptedSocket()
        socket.hostReplayComplete = false
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: socket, route: .direct))])
        let client = makeClient(factory: factory)
        await client.start()
        _ = try await waitForStatus(client) { $0.phase == .online(.direct) }
        let subscribeIndex = try XCTUnwrap(socket.methods.firstIndex(of: "events/subscribe"))
        let projectsIndex = try XCTUnwrap(socket.methods.firstIndex(of: "project/list"))
        let sessionsIndex = try XCTUnwrap(socket.methods.firstIndex(of: "session/list"))
        XCTAssertLessThan(subscribeIndex, projectsIndex)
        XCTAssertLessThan(projectsIndex, sessionsIndex)
        await client.stop()
    }

    func testDirectSuccessRestoresBeforeOnlineAndNeverCallsSSHFactory() async throws {
        let socket = ScriptedSocket()
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: socket, route: .direct))])
        let client = makeClient(factory: factory)
        await client.start()

        let status = try await waitForStatus(client) { $0.phase == .online(.direct) }
        XCTAssertEqual(status.activeRoute, .direct)
        XCTAssertEqual(factory.routes(), [.direct])
        XCTAssertTrue(socket.methods.contains("connection/ping"))
        XCTAssertTrue(socket.methods.contains("events/subscribe"))
        XCTAssertLessThan(
            try XCTUnwrap(socket.methods.firstIndex(of: "connection/ping")),
            try XCTUnwrap(socket.methods.firstIndex(of: "events/subscribe"))
        )
        XCTAssertNil(status.directFailure)
        XCTAssertNil(status.sshFailure)

        await client.stop()
        XCTAssertEqual(socket.closeCount, 1)
    }

    func testDirectTransportFailureFallsBackExactlyOnce() async throws {
        let ssh = ScriptedSocket()
        let factory = ScriptedFactory(results: [
            .failure(RACPConnectionError(category: .tcp)),
            .success(RACPConnection(socket: ssh, route: .ssh)),
        ])
        let client = makeClient(factory: factory)
        await client.start()

        let status = try await waitForStatus(client) { $0.phase == .online(.ssh) }
        XCTAssertEqual(factory.routes(), [.direct, .ssh])
        XCTAssertEqual(status.directFailure?.category, .tcp)
        XCTAssertEqual(status.activeRoute, .ssh)
        await client.stop()
    }

    func testTLSAndIdentityFailuresNeverFallBack() async throws {
        let tlsFactory = ScriptedFactory(results: [.failure(RACPConnectionError(category: .tlsTrust))])
        let tlsClient = makeClient(factory: tlsFactory)
        await tlsClient.start()
        let tlsStatus = try await waitForStatus(tlsClient) { $0.phase == .failed }
        XCTAssertEqual(tlsStatus.directFailure?.category, .tlsTrust)
        XCTAssertEqual(tlsFactory.routes(), [.direct])
        await tlsClient.stop()

        let identitySocket = ScriptedSocket()
        identitySocket.pingHostID = "different_host"
        let identityFactory = ScriptedFactory(results: [.success(RACPConnection(socket: identitySocket, route: .direct))])
        let identityClient = makeClient(factory: identityFactory)
        await identityClient.start()
        let identityStatus = try await waitForStatus(identityClient) { $0.phase == .failed }
        XCTAssertEqual(identityStatus.directFailure?.category, .hostIdentity)
        XCTAssertEqual(identityFactory.routes(), [.direct])
        XCTAssertFalse(identitySocket.methods.contains("events/subscribe"))
        await identityClient.stop()
    }

    func testAuthenticationAndRestoreBusinessErrorsNeverFallBackOrPublishOnline() async throws {
        let unauthorized = ScriptedSocket()
        unauthorized.pingErrorCode = "UNAUTHORIZED"
        let authFactory = ScriptedFactory(results: [.success(RACPConnection(socket: unauthorized, route: .direct))])
        let authClient = makeClient(factory: authFactory)
        await authClient.start()
        let authStatus = try await waitForStatus(authClient) { $0.phase == .failed }
        XCTAssertEqual(authStatus.directFailure?.category, .authentication)
        XCTAssertEqual(authFactory.routes(), [.direct])
        await authClient.stop()

        let restore = ScriptedSocket()
        restore.subscribeErrorCode = "INVALID_ARGUMENT"
        let restoreFactory = ScriptedFactory(results: [.success(RACPConnection(socket: restore, route: .direct))])
        let restoreClient = makeClient(factory: restoreFactory)
        await restoreClient.start()
        let restoreStatus = try await waitForStatus(restoreClient) { $0.phase == .failed }
        XCTAssertEqual(restoreStatus.directFailure?.category, .validation)
        XCTAssertEqual(restoreFactory.routes(), [.direct])
        await restoreClient.stop()
    }

    func testDirectBudgetCancelsSocketAndStartsOnlyOneSSHRoute() async throws {
        let stalled = ScriptedSocket()
        stalled.ignorePing = true
        let ssh = ScriptedSocket()
        let factory = ScriptedFactory(results: [
            .success(RACPConnection(socket: stalled, route: .direct)),
            .success(RACPConnection(socket: ssh, route: .ssh)),
        ])
        let budgets = RACPConnectionBudgets(directConnect: 0.05, sshConnect: 1, restore: 1)
        let client = makeClient(factory: factory, budgets: budgets)
        await client.start()

        let status = try await waitForStatus(client) { $0.phase == .online(.ssh) }
        XCTAssertEqual(factory.routes(), [.direct, .ssh])
        XCTAssertEqual(stalled.closeCount, 1)
        // 预算耗尽（尚未得到 tlsTrust/auth/hostIdentity 等确定结论）必须归类 connectTimeout。
        XCTAssertEqual(status.directFailure?.category, .connectTimeout)
        await client.stop()
    }

    /// S3：失败路径的 teardown 必须是有界的。旧 socket 的 `close()` 只要卡住
    /// （NIO 的 `EventLoopFuture.get()` 不响应取消），重连循环也不能被它拖住。
    func testHangingCloseDoesNotBlockSSHFallback() async throws {
        let hanging = ScriptedSocket()
        hanging.hangOnClose = true
        let ssh = ScriptedSocket()
        let factory = ScriptedFactory(results: [
            .success(RACPConnection(socket: hanging, route: .direct)),
            .success(RACPConnection(socket: ssh, route: .ssh)),
        ])
        let client = makeClient(factory: factory)
        await client.start()

        _ = try await waitForStatus(client) { $0.phase == .online(.direct) }
        hanging.terminate(closeCode: 1006, reason: "")

        // 1s 有界关闭 + 立即回退；若 teardown 无限等待，这里会超时失败。
        let status = try await waitForStatus(client, timeout: 3) { $0.phase == .online(.ssh) }
        XCTAssertEqual(factory.routes(), [.direct, .ssh])
        XCTAssertEqual(status.activeRoute, .ssh)
        await client.stop()
    }

    func testSSHBackoffRetriesStayOnSSHWithinSameIntent() async throws {
        let ssh = ScriptedSocket()
        let factory = ScriptedFactory(results: [
            .failure(RACPConnectionError(category: .socketInterrupted)),
            .failure(RACPConnectionError(category: .tcp)),
            .success(RACPConnection(socket: ssh, route: .ssh)),
        ])
        let client = makeClient(
            factory: factory,
            backoff: ReconnectBackoff(schedule: [0.001, 0.001], maximumDelay: 0.001)
        )
        await client.start()

        let status = try await waitForStatus(client) { $0.phase == .online(.ssh) }
        XCTAssertEqual(factory.routes(), [.direct, .ssh, .ssh])
        XCTAssertEqual(status.directFailure?.category, .socketInterrupted)
        await client.stop()
    }

    func testDeviceRevokedCloseEndsWithoutSSHFallback() async throws {
        let direct = ScriptedSocket()
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: direct, route: .direct))])
        let client = makeClient(factory: factory)
        await client.start()
        _ = try await waitForStatus(client) { $0.phase == .online(.direct) }

        direct.terminate(closeCode: 1008, reason: "device revoked")
        let status = try await waitForStatus(client) { $0.phase == .failed }
        XCTAssertEqual(status.directFailure?.category, .deviceRevoked)
        XCTAssertEqual(factory.routes(), [.direct])
        await client.stop()
    }

    func testDirectCapabilityMissingStopsBeforePingAndRestore() async throws {
        let direct = ScriptedSocket()
        direct.directTransportCapability = nil
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: direct, route: .direct))])
        let client = makeClient(factory: factory)
        await client.start()
        let status = try await waitForStatus(client) { $0.phase == .failed }
        XCTAssertEqual(status.directFailure?.category, .protocol)
        XCTAssertEqual(factory.routes(), [.direct])
        XCTAssertFalse(direct.methods.contains("connection/ping"))
        XCTAssertFalse(direct.methods.contains("events/subscribe"))
        await client.stop()
    }

    func testSSHOnlySkipsDirect() async throws {
        let ssh = ScriptedSocket()
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: ssh, route: .ssh))])
        let client = makeClient(factory: factory, preference: .sshOnly)
        await client.start()
        _ = try await waitForStatus(client) { $0.phase == .online(.ssh) }
        XCTAssertEqual(factory.routes(), [.ssh])
        await client.stop()
    }

    func testDirectSuccessNeedsNoSSHConfiguration() async throws {
        let direct = ScriptedSocket()
        let factory = ScriptedFactory(results: [.success(RACPConnection(socket: direct, route: .direct))])
        let client = makeClient(factory: factory, includeSSH: false)
        await client.start()
        _ = try await waitForStatus(client) { $0.phase == .online(.direct) }
        XCTAssertEqual(factory.routes(), [.direct])
        await client.stop()
    }

    func testFallbackWithoutSSHConfigurationKeepsExplicitSSHFailure() async throws {
        let factory = DirectFailLiveSSHFactory()
        let client = makeClient(factory: factory, includeSSH: false)
        await client.start()
        let status = try await waitForStatus(client) { $0.phase == .failed }
        XCTAssertEqual(factory.routes(), [.direct, .ssh])
        XCTAssertEqual(status.directFailure?.category, .tcp)
        XCTAssertEqual(status.sshFailure?.category, .configuration)
        await client.stop()
    }

    private func makeClient(
        factory: any RACPConnectionFactory,
        budgets: RACPConnectionBudgets = .default,
        backoff: ReconnectBackoff = ReconnectBackoff(schedule: [0.001], maximumDelay: 0.001),
        preference: ConnectionPreference = .directPreferred,
        includeSSH: Bool = true
    ) -> RACPClient {
        let ssh = includeSSH ? SSHConnectionRequest(
            host: "unused.invalid",
            port: 22,
            username: "unused",
            credential: .password("unused"),
            pinnedHostKey: nil
        ) : nil
        let configuration = RACPConfiguration(
            ssh: ssh,
            hostPort: includeSSH ? 1 : nil,
            deviceToken: "pdt2.test",
            connectionPreference: preference,
            direct: DirectRACPConfiguration(
                endpoint: URL(string: "wss://localhost:9443/v1/racp/ws")!,
                certificateSHA256: String(repeating: "a", count: 64),
                adaptorHostId: "host_1"
            )
        )
        return RACPClient(
            configuration: configuration,
            connectionFactory: factory,
            budgets: budgets,
            backoff: backoff
        )
    }

    private func waitForStatus(
        _ client: RACPClient,
        timeout: TimeInterval = 2,
        predicate: (ConnectionStatus) -> Bool
    ) async throws -> ConnectionStatus {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var status = await client.connectionStatus()
        while !predicate(status), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            status = await client.connectionStatus()
        }
        XCTAssertTrue(predicate(status), "最后状态：\(status)")
        return status
    }
}

private final class DirectFailLiveSSHFactory: RACPConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRoutes: [ConnectionRoute] = []
    private let live = LiveRACPConnectionFactory()

    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        lock.lock()
        recordedRoutes.append(route)
        lock.unlock()
        if route == .direct { throw RACPConnectionError(category: .tcp) }
        return try await live.makeConnection(
            route: route,
            configuration: configuration,
            confirmer: confirmer,
            suppliedTransport: suppliedTransport
        )
    }

    func routes() -> [ConnectionRoute] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRoutes
    }
}

private final class ScriptedFactory: RACPConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<RACPConnection, Error>]
    private var recordedRoutes: [ConnectionRoute] = []

    init(results: [Result<RACPConnection, Error>]) {
        self.results = results
    }

    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        lock.lock()
        recordedRoutes.append(route)
        guard !results.isEmpty else {
            lock.unlock()
            throw RACPConnectionError(category: .internal)
        }
        let result = results.removeFirst()
        lock.unlock()
        return try result.get()
    }

    func routes() -> [ConnectionRoute] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRoutes
    }
}

private final class ScriptedSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let termination = RACPSocketTerminationState()
    private let lock = NSLock()
    private var closed = false
    private var closeCalls = 0

    var pingHostID = "host_1"
    var pingErrorCode: String?
    var subscribeErrorCode: String?
    var hostReplayComplete = true
    var discoveryUpstreamStatus: Int?
    var directTransportCapability: Bool? = true
    var ignorePing = false
    /// 模拟“关闭永不返回”：NIO 的 EventLoopFuture.get() 不响应 Swift 任务取消。
    var hangOnClose = false
    private(set) var methods: [String] = []
    private(set) var subscriptionAfterCursors: [String] = []

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCalls
    }

    var terminationError: RACPSocketTermination {
        get async { await termination.wait() }
    }

    func send(text: String) async throws {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String
        else { return }
        lock.lock()
        methods.append(method)
        lock.unlock()
        guard let id = object["id"] else { return }
        if method == "connection/ping" {
            if ignorePing { return }
            if let pingErrorCode {
                yieldError(id: id, code: pingErrorCode)
            } else {
                yieldResult(id: id, result: [
                    "ok": true,
                    "pong": true,
                    "serverTime": "2026-11-05T00:00:00.000Z",
                    "hostId": pingHostID,
                ])
            }
            return
        }
        if method == "connection/initialize" {
            var capabilities: [String: Any] = [:]
            if let directTransportCapability {
                capabilities["directTransport"] = directTransportCapability
            }
            yieldResult(id: id, result: [
                "protocolVersion": "1.0",
                "server": ["name": "test", "version": "1", "hostId": "untrusted-initialize-id"],
                "connectionId": "connection_1",
                "principal": ["roles": ["owner"]],
                "capabilities": capabilities,
            ])
            return
        }
        if method == "provider/discover", let discoveryUpstreamStatus {
            yieldError(id: id, code: "UPSTREAM_UNAVAILABLE", upstreamStatus: discoveryUpstreamStatus)
            return
        }
        if method == "events/subscribe" {
            let params = object["params"] as? [String: Any]
            let after = params?["after"] as? [String: Any]
            let cursor = after.map {
                "\($0["epoch"] as? String ?? "?"):\($0["sequence"] as? Int ?? -1)"
            } ?? "nil"
            lock.lock()
            subscriptionAfterCursors.append(cursor)
            lock.unlock()
            if let subscribeErrorCode {
                yieldError(id: id, code: subscribeErrorCode)
            } else {
                yieldResult(id: id, result: [
                    "subscriptionId": "sub_1",
                    "replayComplete": hostReplayComplete,
                    "starting": ["epoch": "epoch_1", "sequence": 0],
                ])
            }
            return
        }
        if method == "project/list" {
            yieldResult(id: id, result: ["projects": []])
            return
        }
        if method == "session/list" {
            yieldResult(id: id, result: ["sessions": []])
            return
        }
        yieldResult(id: id, result: [:])
    }

    func close() async {
        if hangOnClose {
            try? await Task.sleep(for: .seconds(30))
            return
        }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        closeCalls += 1
        lock.unlock()
        continuation.finish()
        termination.finish(RACPSocketTermination(closeCode: 1000, reason: ""))
    }

    func waitUntilClosed() async {
        _ = await terminationError
    }

    func terminate(closeCode: Int, reason: String) {
        continuation.finish()
        termination.finish(RACPSocketTermination(closeCode: closeCode, reason: reason))
    }

    private func yieldResult(id: Any, result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result,
        ]) else { return }
        continuation.yield(data)
    }

    private func yieldError(id: Any, code: String, upstreamStatus: Int? = nil) {
        var details: [String: Any] = ["code": code]
        if let upstreamStatus { details["upstreamStatus"] = upstreamStatus }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": "fixed test error", "data": details],
        ]) else { return }
        continuation.yield(data)
    }
}
