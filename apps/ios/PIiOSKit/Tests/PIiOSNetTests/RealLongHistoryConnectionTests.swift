import CryptoKit
import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

/// Opt-in real-server probe, never part of the offline regression suite.
/// Reads credentials issued to a temporary, read-only adaptor from PI_HISTORY_CREDENTIALS.
final class RealLongHistoryConnectionTests: XCTestCase {
    private struct Credentials: Decodable {
        let deviceToken: String
        let sessionId: String
        let expectedCount: Int
        let expectedIdsSha256: String
    }

    private func configuredClient(
        connectionFactory: (any RACPConnectionFactory)? = nil
    ) throws -> (Credentials, RACPClient) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"],
              let rawPort = env["PI_HOST_PORT"],
              let hostPort = Int(rawPort),
              let credentialsPath = env["PI_HISTORY_CREDENTIALS"] else {
            throw XCTSkip("未配置真实长会话隔离探针")
        }
        let credentials = try JSONDecoder().decode(
            Credentials.self, from: Data(contentsOf: URL(fileURLWithPath: credentialsPath))
        )
        let request = SSHConnectionRequest(
            host: host,
            port: Int(env["PI_SSH_PORT"] ?? "22") ?? 22,
            username: user,
            credential: .privateKey(
                openSSHText: try String(contentsOfFile: keyPath, encoding: .utf8),
                passphrase: nil
            ),
            pinnedHostKey: nil
        )
        let configuration = RACPConfiguration(
            ssh: request, hostPort: hostPort,
            deviceToken: credentials.deviceToken, clientVersion: "0.0.3"
        )
        let client: RACPClient
        if let connectionFactory {
            client = RACPClient(configuration: configuration, connectionFactory: connectionFactory)
        } else if env["PI_HISTORY_TRACE"] == "1" {
            client = RACPClient(
                configuration: configuration,
                connectionFactory: LongHistoryTraceConnectionFactory()
            )
        } else {
            client = RACPClient(configuration: configuration, confirmer: LongHistoryHostKeyConfirmer())
        }
        return (credentials, client)
    }

    func testRealLongHistoryBeforeFixClosesWith1009() async throws {
        let (credentials, client) = try configuredClient()
        guard ProcessInfo.processInfo.environment["PI_HOST_PORT"] == "19451",
              credentials.expectedCount > 100 else {
            throw XCTSkip("仅允许对19451隔离旧版实例执行超限复现")
        }
        ConnectionDiagnostics.shared.clear()
        await client.start()
        do {
            try await waitForOnline(client)
            var attachFailed = false
            do {
                _ = try await client.attach(sessionId: credentials.sessionId)
            } catch {
                attachFailed = true
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if await client.connectionStatus().phase == .failed { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let status = await client.connectionStatus()
            let oversizedFailure = ConnectionDiagnostics.shared.snapshot().contains {
                $0.kind == .failure && $0.closeCode == 1009 && $0.category == .validation
            }
            XCTAssertTrue(attachFailed)
            XCTAssertEqual(status.phase, .failed)
            XCTAssertTrue(oversizedFailure, "旧版长会话应因1009超限关闭而终止")
            guard attachFailed, status.phase == .failed, oversizedFailure else {
                throw LongHistoryProbeError.baselineDidNotReproduce
            }
            print("LONG-HISTORY-BASELINE attachFailed=true close=1009 category=validation final=failed")
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    func testRealLongHistoryAttachesPagesAndStaysOnline() async throws {
        let (credentials, client) = try configuredClient()
        guard ProcessInfo.processInfo.environment["PI_HOST_PORT"] == "19452" else {
            throw XCTSkip("仅允许对19452隔离修复实例执行稳定性验证")
        }
        ConnectionDiagnostics.shared.clear()
        await client.start()
        do {
            try await waitForOnline(client)
            let generation = await client.connectionStatus().activeGeneration
            let included = try await client.attach(sessionId: credentials.sessionId)
            guard included == true else {
                throw LongHistoryProbeError.snapshotMissing
            }
            let initial = await client.sessionView()
            guard !initial.items.isEmpty, credentials.expectedCount > 100 else {
                throw LongHistoryProbeError.longHistoryMissing
            }
            XCTAssertLessThanOrEqual(initial.items.count, 100)
            XCTAssertTrue(initial.hasMoreHistory, "真实长会话必须产生分页快照")
            let initialCursor = initial.cursor
            print("LONG-HISTORY attached items=\(initial.items.count) hasMore=\(initial.hasMoreHistory)")
            var previousCount = initial.items.count
            var pages = 0
            while await client.sessionView().hasMoreHistory {
                pages += 1
                guard pages <= credentials.expectedCount else {
                    throw LongHistoryProbeError.paginationDidNotAdvance
                }
                let inserted = try await client.loadEarlierHistory()
                let view = await client.sessionView()
                guard inserted > 0, view.items.count > previousCount else {
                    throw LongHistoryProbeError.paginationDidNotAdvance
                }
                XCTAssertEqual(view.cursor, initialCursor, "历史分页不得推进实时游标")
                XCTAssertEqual(view.items.count, Set(view.items.map(\.id)).count)
                previousCount = view.items.count
                try await client.ping(timeout: 10)
                print("LONG-HISTORY page=\(pages) inserted=\(inserted) total=\(view.items.count) hasMore=\(view.hasMoreHistory)")
            }
            let complete = await client.sessionView()
            let ids = complete.items.map(\.id).joined(separator: "\n")
            let digest = SHA256.hash(data: Data(ids.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(complete.items.count, credentials.expectedCount)
            XCTAssertEqual(digest, credentials.expectedIdsSha256, "所有历史 id 必须顺序一致且无遗漏")
            XCTAssertFalse(complete.hasMoreHistory)
            guard complete.items.count == credentials.expectedCount,
                  digest == credentials.expectedIdsSha256, !complete.hasMoreHistory else {
                throw LongHistoryProbeError.historyIntegrityMismatch
            }

            // Reattach the same long session, as the App does after restoring its selection.
            // This must replace the view with a bounded snapshot rather than retain old pages.
            _ = try await client.attach(sessionId: credentials.sessionId)
            let reattached = await client.sessionView()
            XCTAssertLessThanOrEqual(reattached.items.count, 100)
            XCTAssertTrue(reattached.hasMoreHistory)
            guard !reattached.items.isEmpty, reattached.items.count <= 100,
                  reattached.hasMoreHistory else {
                throw LongHistoryProbeError.snapshotMissing
            }
            for _ in 0..<12 {
                try await Task.sleep(for: .seconds(5))
                try await client.ping(timeout: 10)
                let status = await client.connectionStatus()
                XCTAssertEqual(status.phase, .online(.ssh))
                XCTAssertEqual(status.activeGeneration, generation, "观察期内不应重新建连")
                guard status.phase == .online(.ssh), status.activeGeneration == generation else {
                    throw LongHistoryProbeError.connectionChanged
                }
            }
            let diagnostics = ConnectionDiagnostics.shared.snapshot()
            XCTAssertFalse(diagnostics.contains { $0.closeCode == 1009 })
            XCTAssertFalse(diagnostics.contains { $0.kind == .failure })
            guard !diagnostics.contains(where: { $0.closeCode == 1009 || $0.kind == .failure }) else {
                throw LongHistoryProbeError.connectionChanged
            }
            print("LONG-HISTORY final=online count=\(complete.items.count) pages=\(pages) observation=60s sameGeneration=true")
            await client.stop()
        } catch {
            for event in ConnectionDiagnostics.shared.snapshot() {
                print("LONG-HISTORY-DIAG kind=\(event.kind.rawValue) category=\(event.category?.rawValue ?? "-") close=\(event.closeCode.map(String.init) ?? "-") phase=\(event.phase ?? "-")")
            }
            await client.stop()
            throw error
        }
    }

    func testRealLongHistoryAutomaticallyRestoresAfterIsolatedRestart() async throws {
        let (credentials, client) = try configuredClient()
        guard ProcessInfo.processInfo.environment["PI_HOST_PORT"] == "19452",
              let markerPath = ProcessInfo.processInfo.environment["PI_HISTORY_RESTART_MARKER"],
              markerPath.hasPrefix("/tmp/pi-ios-history-native.") else {
            throw XCTSkip("自动恢复探针需要19452隔离实例及专用临时重启标记")
        }
        ConnectionDiagnostics.shared.clear()
        await client.start()
        do {
            try await waitForOnline(client)
            let generation = await client.connectionStatus().activeGeneration
            _ = try await client.attach(sessionId: credentials.sessionId)
            let before = await client.sessionView()
            guard let oldCursor = before.cursor,
                  !before.items.isEmpty, before.items.count <= 100, before.hasMoreHistory else {
                throw LongHistoryProbeError.snapshotMissing
            }
            let started = ContinuousClock.now
            try Data("restart-isolated-after\n".utf8).write(
                to: URL(fileURLWithPath: markerPath), options: .atomic
            )
            print("LONG-HISTORY-RECOVERY ready=true")
            var recoveredGeneration: UUID?
            let deadline = ContinuousClock.now + .seconds(45)
            while ContinuousClock.now < deadline {
                let status = await client.connectionStatus()
                if status.phase == .failed { throw LongHistoryProbeError.failedToConnect }
                if status.phase == .online(.ssh),
                   let active = status.activeGeneration, active != generation {
                    recoveredGeneration = active
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let recoveredGeneration else { throw LongHistoryProbeError.onlineTimeout }
            let recovered = await client.sessionView()
            guard recovered.sessionId == credentials.sessionId,
                  let cursor = recovered.cursor, cursor.epoch != oldCursor.epoch,
                  !recovered.items.isEmpty, recovered.items.count <= 100,
                  recovered.hasMoreHistory else {
                throw LongHistoryProbeError.snapshotMissing
            }
            let recoveryMs = ConnectionDiagnostics.milliseconds(since: started)
            print("LONG-HISTORY-RECOVERY online=true recoveryMs=\(recoveryMs) snapshotItems=\(recovered.items.count)")
            var pageCount = 0
            while await client.sessionView().hasMoreHistory {
                pageCount += 1
                guard pageCount <= credentials.expectedCount else {
                    throw LongHistoryProbeError.paginationDidNotAdvance
                }
                let pageStart = ContinuousClock.now
                print("LONG-HISTORY-RECOVERY pageStart=\(pageCount)")
                let inserted = try await client.loadEarlierHistory()
                guard inserted > 0 else { throw LongHistoryProbeError.paginationDidNotAdvance }
                let pageView = await client.sessionView()
                guard pageView.cursor == cursor else {
                    throw LongHistoryProbeError.historyIntegrityMismatch
                }
                try await client.ping(timeout: 10)
                print("LONG-HISTORY-RECOVERY page=\(pageCount) total=\(pageView.items.count) elapsedMs=\(ConnectionDiagnostics.milliseconds(since: pageStart))")
            }
            let complete = await client.sessionView()
            let ids = complete.items.map(\.id)
            let digest = SHA256.hash(data: Data(ids.joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard ids.count == credentials.expectedCount, Set(ids).count == ids.count,
                  digest == credentials.expectedIdsSha256 else {
                throw LongHistoryProbeError.historyIntegrityMismatch
            }
            for _ in 0..<12 {
                try await Task.sleep(for: .seconds(5))
                try await client.ping(timeout: 10)
                let status = await client.connectionStatus()
                guard status.phase == .online(.ssh), status.activeGeneration == recoveredGeneration else {
                    throw LongHistoryProbeError.connectionChanged
                }
            }
            let failures = ConnectionDiagnostics.shared.snapshot().filter { $0.kind == .failure }
            guard failures.count == 1, failures.first?.category == .socketInterrupted,
                  !failures.contains(where: { $0.closeCode == 1009 }) else {
                throw LongHistoryProbeError.connectionChanged
            }
            print("LONG-HISTORY-RECOVERY final=online recoveryMs=\(recoveryMs) cursorRebuilt=true count=\(ids.count) pages=\(pageCount) observation=60s failures=1 expectedInterruption=true")
            await client.stop()
        } catch {
            for event in ConnectionDiagnostics.shared.snapshot() {
                print("LONG-HISTORY-RECOVERY-DIAG kind=\(event.kind.rawValue) category=\(event.category?.rawValue ?? "-") close=\(event.closeCode.map(String.init) ?? "-") phase=\(event.phase ?? "-")")
            }
            await client.stop()
            throw error
        }
    }

    /// Interrupt only the local SSH transport. No remote restart/control writes,
    /// and the factory returns the original socket without a timing wrapper.
    func testRealLongHistoryAutomaticallyRestoresAfterLocalTransportDrop() async throws {
        let factory = LongHistoryDroppableConnectionFactory()
        let (credentials, client) = try configuredClient(connectionFactory: factory)
        guard ProcessInfo.processInfo.environment["PI_HOST_PORT"] == "19452" else {
            throw XCTSkip("仅允许对19452隔离实例执行本机传输中断验证")
        }
        ConnectionDiagnostics.shared.clear()
        await client.start()
        do {
            try await waitForOnline(client)
            let generation = await client.connectionStatus().activeGeneration
            _ = try await client.attach(sessionId: credentials.sessionId)
            let before = await client.sessionView()
            guard let cursor = before.cursor, !before.items.isEmpty,
                  before.items.count <= 100, before.hasMoreHistory else {
                throw LongHistoryProbeError.snapshotMissing
            }
            let started = ContinuousClock.now
            try await factory.dropLocalTransport()
            var recoveredGeneration: UUID?
            let deadline = ContinuousClock.now + .seconds(45)
            while ContinuousClock.now < deadline {
                let status = await client.connectionStatus()
                if status.phase == .failed { throw LongHistoryProbeError.failedToConnect }
                if status.phase == .online(.ssh),
                   let active = status.activeGeneration, active != generation {
                    recoveredGeneration = active
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let recoveredGeneration else { throw LongHistoryProbeError.onlineTimeout }
            let recovered = await client.sessionView()
            guard recovered.sessionId == credentials.sessionId,
                  recovered.cursor == cursor, recovered.hasMoreHistory else {
                throw LongHistoryProbeError.snapshotMissing
            }
            let recoveryMs = ConnectionDiagnostics.milliseconds(since: started)
            print("LONG-HISTORY-LOCAL-RECOVERY online=true recoveryMs=\(recoveryMs) unwrapped=true")
            var pages = 0
            while await client.sessionView().hasMoreHistory {
                pages += 1
                guard pages <= credentials.expectedCount else {
                    throw LongHistoryProbeError.paginationDidNotAdvance
                }
                let pageStarted = ContinuousClock.now
                let inserted = try await client.loadEarlierHistory()
                let view = await client.sessionView()
                guard inserted > 0, view.cursor == cursor else {
                    throw LongHistoryProbeError.historyIntegrityMismatch
                }
                try await client.ping(timeout: 10)
                print("LONG-HISTORY-LOCAL-RECOVERY page=\(pages) total=\(view.items.count) elapsedMs=\(ConnectionDiagnostics.milliseconds(since: pageStarted))")
            }
            let complete = await client.sessionView()
            let ids = complete.items.map(\.id)
            let digest = SHA256.hash(data: Data(ids.joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard ids.count == credentials.expectedCount, Set(ids).count == ids.count,
                  digest == credentials.expectedIdsSha256 else {
                throw LongHistoryProbeError.historyIntegrityMismatch
            }
            for _ in 0..<12 {
                try await Task.sleep(for: .seconds(5))
                try await client.ping(timeout: 10)
                let status = await client.connectionStatus()
                guard status.phase == .online(.ssh), status.activeGeneration == recoveredGeneration else {
                    throw LongHistoryProbeError.connectionChanged
                }
            }
            let failures = ConnectionDiagnostics.shared.snapshot().filter { $0.kind == .failure }
            guard failures.count == 1, failures.first?.category == .socketInterrupted,
                  !failures.contains(where: { $0.closeCode == 1009 }) else {
                throw LongHistoryProbeError.connectionChanged
            }
            print("LONG-HISTORY-LOCAL-RECOVERY final=online count=\(ids.count) pages=\(pages) observation=60s failures=1 expectedInterruption=true unwrapped=true")
            await client.stop()
        } catch {
            for event in ConnectionDiagnostics.shared.snapshot() {
                print("LONG-HISTORY-LOCAL-RECOVERY-DIAG kind=\(event.kind.rawValue) category=\(event.category?.rawValue ?? "-") close=\(event.closeCode.map(String.init) ?? "-") phase=\(event.phase ?? "-")")
            }
            await client.stop()
            throw error
        }
    }

    private func waitForOnline(_ client: RACPClient) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let status = await client.connectionStatus()
            if status.phase == .online(.ssh) { return }
            if status.phase == .failed {
                throw LongHistoryProbeError.failedToConnect
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LongHistoryProbeError.onlineTimeout
    }
}

private final class LongHistoryDroppableConnectionFactory: RACPConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var transport: SSHTransport?

    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        let live = try await LiveRACPConnectionFactory().makeConnection(
            route: route, configuration: configuration,
            confirmer: LongHistoryHostKeyConfirmer(), suppliedTransport: suppliedTransport
        )
        lock.withLock { transport = live.transport }
        return live
    }

    func dropLocalTransport() async throws {
        guard let current = lock.withLock({ transport }) else {
            throw LongHistoryProbeError.failedToConnect
        }
        await current.close()
    }
}

private enum LongHistoryProbeError: Error {
    case failedToConnect
    case onlineTimeout
    case snapshotMissing
    case longHistoryMissing
    case paginationDidNotAdvance
    case historyIntegrityMismatch
    case connectionChanged
    case baselineDidNotReproduce
}

/// Diagnostics-only wrapper around the live Swift SSH/WebSocket connection.
/// Logs only method/id/bytes/timing, never credentials or message bodies.
private struct LongHistoryTraceConnectionFactory: RACPConnectionFactory {
    func makeConnection(
        route: ConnectionRoute,
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        suppliedTransport: SSHTransport?
    ) async throws -> RACPConnection {
        let live = try await LiveRACPConnectionFactory().makeConnection(
            route: route, configuration: configuration,
            confirmer: LongHistoryHostKeyConfirmer(), suppliedTransport: suppliedTransport
        )
        return RACPConnection(
            socket: LongHistoryTraceSocket(base: live.socket),
            route: live.route, transport: live.transport
        )
    }
}

private final class LongHistoryTraceSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let base: any RACPSocket
    private let continuation: AsyncStream<Data>.Continuation
    private let tag = String(UUID().uuidString.prefix(8))
    private var reader: Task<Void, Never>?

    init(base: any RACPSocket) {
        self.base = base
        let stream = AsyncStream<Data>.makeStream()
        inbound = stream.stream
        continuation = stream.continuation
        let sink = continuation
        let tag = tag
        reader = Task { [base] in
            for await data in base.inbound {
                Self.trace(direction: "in", data: data, tag: tag)
                sink.yield(data)
            }
            sink.finish()
        }
    }

    var receiveProgress: RACPReceiveProgress? { base.receiveProgress }
    var terminationError: RACPSocketTermination {
        get async { await base.terminationError }
    }
    func send(text: String) async throws {
        Self.trace(direction: "out", data: Data(text.utf8), tag: tag)
        try await base.send(text: text)
    }
    func close() async { await base.close() }
    func waitUntilClosed() async { await base.waitUntilClosed() }

    private static func trace(direction: String, data: Data, tag: String) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let id = (object?["id"] as? NSNumber)?.stringValue ?? "-"
        let rawMethod = object?["method"] as? String
        let method = rawMethod.flatMap { value in
            RACPMethod.allCases.contains(where: { $0.rawValue == value }) ? value : nil
        } ?? "response"
        print("LONG-HISTORY-TRACE socket=\(tag) direction=\(direction) id=\(id) method=\(method) bytes=\(data.count) at=\(Date().timeIntervalSince1970)")
    }
}

private struct LongHistoryHostKeyConfirmer: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
