import Foundation
import XCTest
import PIiOSCore
@testable import PI_IOS

@MainActor
final class ExtensionCatalogModelTests: XCTestCase {
    private let host = UUID()

    func testUnsupportedAndOfflineNeverInvokeFetch() async {
        let model = ExtensionCatalogModel()
        var calls = 0
        model.setContext(context(online: true, supported: false))
        await model.refreshSession("s") { calls += 1; return self.result() }
        model.setContext(context(online: false))
        await model.refreshSession("s") { calls += 1; return self.result() }
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.sessionState("s").value)
    }

    func testLateResponseCannotCrossHostOrConnectionGeneration() async {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        let gate = ExtensionTestGate<RACPSessionExtensions>()
        let task = Task { await model.refreshSession("s") { await gate.wait() } }
        await gate.waitUntilEntered()
        model.setContext(context(host: UUID(), generation: 2))
        gate.release(result())
        await task.value
        XCTAssertNil(model.sessionState("s").value)
        model.setContext(context(generation: 3))
        XCTAssertNil(model.sessionState("s").value, "old read must not commit to the previous Host either")
    }

    func testHostsWithSameSessionIDAreIsolatedAndDeletionInvalidatesPendingReads() async {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        await model.refreshSession("s") { self.result(config: "a") }
        let other = UUID()
        model.setContext(context(host: other))
        XCTAssertNil(model.sessionState("s").value)
        await model.refreshSession("s") { self.result(config: "b") }
        model.setContext(context())
        XCTAssertEqual(model.sessionState("s").value?.configRevision, "a")
        model.removeHost(host)
        XCTAssertNil(model.sessionState("s").value)
        model.setContext(context(host: other))
        XCTAssertEqual(model.sessionState("s").value?.configRevision, "b")
        model.removeSessions(["s"], hostID: other)
        XCTAssertNil(model.sessionState("s").value)
    }

    func testOfflineAndReadFailureKeepOldDataWithoutLeakingRawErrors() async {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        await model.refreshSession("s") { self.result() }
        await model.refreshSession("s") { throw NSError(domain: "token=secret", code: 1) }
        guard case let .failed(reason, stale) = model.sessionState("s") else { return XCTFail("expected stale") }
        XCTAssertNotNil(stale)
        XCTAssertFalse(reason.contains("secret"))
        model.setContext(context(online: false))
        XCTAssertNotNil(model.sessionState("s").value)
        XCTAssertNotNil(model.lastRead("s"))
    }

    func testEventDuringQueryForcesFollowUpAndSameSnapshotCannotRegress() async throws {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        let initial = try snapshot(id: "one", revision: 1)
        await model.refreshSession("s") { self.result(snapshot: initial) }
        let gate = ExtensionTestGate<RACPSessionExtensions>()
        var calls = 0
        let task = Task {
            await model.refreshSession("s") {
                calls += 1
                if calls == 1 { return await gate.wait() }
                return self.result(snapshot: try self.snapshot(id: "one", revision: 3))
            }
        }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.observe(try snapshot(id: "one", revision: 2), epoch: "ep", sequence: 2))
        gate.release(result(snapshot: initial))
        await task.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.sessionState("s").value?.latestAttempt?.revision, 3)
        XCTAssertFalse(model.observe(initial, epoch: "ep", sequence: 1))
        XCTAssertEqual(model.sessionState("s").value?.latestAttempt?.revision, 3)
    }

    func testQueuedOldRoundCannotReplaceOrRetireNewAuthoritativeRound() async throws {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        let old = try snapshot(id: "old", revision: 9)
        let next = try snapshot(id: "new", revision: 1)
        var authoritative = result(snapshot: next)
        authoritative.previousCompleted = old
        await model.refreshSession("s") { authoritative }
        XCTAssertTrue(model.observe(old, epoch: "ep", sequence: 20), "different round requires a query")
        XCTAssertEqual(model.sessionState("s").value?.latestAttempt?.id, "new")
        await model.refreshSession("s") { authoritative }
        XCTAssertTrue(model.observe(try snapshot(id: "new", revision: 2), epoch: "ep", sequence: 21))
        XCTAssertEqual(model.sessionState("s").value?.latestAttempt?.revision, 2)
        XCTAssertEqual(model.sessionState("s").value?.previousCompleted?.id, "old")
    }

    func testReadingAndFailedReconnectNeverLabelStaleTurnAsCurrent() async throws {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        let snap = try snapshot(id: "round", revision: 1)
        var current = result(snapshot: snap)
        current.runningTurnId = "round"
        await model.refreshSession("s") { current }
        XCTAssertEqual(model.sessionResultLabel("s"), "本轮加载结果")
        let gate = ExtensionTestGate<RACPSessionExtensions>()
        let pending = Task { await model.refreshSession("s") { await gate.wait() } }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.sessionResultLabel("s"), "上次读取的加载结果")
        gate.release(current)
        await pending.value
        model.setContext(context(generation: 2))
        await model.refreshSession("s") { throw CancellationError() }
        XCTAssertEqual(model.sessionResultLabel("s"), "上次读取的加载结果")
        XCTAssertTrue(model.observe(try snapshot(id: "round", revision: 2), epoch: "new-epoch", sequence: 1))
        XCTAssertEqual(model.sessionResultLabel("s"), "上次读取的加载结果", "event does not validate stale turn identity")
    }

    func testMismatchedIdentityIsAnErrorAndBoundedCacheEvictsOldest() async {
        let model = ExtensionCatalogModel(limit: 1)
        model.setContext(context())
        await model.refreshSession("s") { self.result(session: "wrong") }
        guard case .failed = model.sessionState("s") else { return XCTFail("must reject identity mismatch") }
        await model.refreshSession("s") { self.result() }
        await model.refreshSession("two") { self.result(session: "two") }
        XCTAssertNil(model.sessionState("s").value)
        XCTAssertEqual(model.sessionState("two").value?.sessionId, "two")
    }

    func testReplacingRemoteIdentityClearsSessionOnlyCache() async {
        let model = ExtensionCatalogModel()
        model.setContext(context())
        await model.refreshSession("s") { self.result() }
        model.setContext(.init(hostID: host, generation: 2, remoteHostID: "replacement",
                               online: true, inventorySupported: true, sessionSupported: true))
        XCTAssertNil(model.sessionState("s").value)
    }

    func testFailedInventoryCacheIsBoundedAndDeleteBlocksLateSessionResponse() async {
        let model = ExtensionCatalogModel(limit: 1)
        model.setContext(context())
        await model.refreshInventory { throw CancellationError() }
        let other = UUID()
        model.setContext(context(host: other))
        await model.refreshInventory { throw CancellationError() }
        model.setContext(context())
        if case .idle = model.inventory {} else { XCTFail("failed inventories must also be evicted") }
        let gate = ExtensionTestGate<RACPSessionExtensions>()
        let pending = Task { await model.refreshSession("s") { await gate.wait() } }
        await gate.waitUntilEntered()
        model.removeSessions(["s"], hostID: host)
        gate.release(result())
        await pending.value
        XCTAssertNil(model.sessionState("s").value)
    }

    private func context(host: UUID? = nil, generation: Int = 1, online: Bool = true, supported: Bool = true) -> ExtensionCatalogModel.Context {
        .init(hostID: host ?? self.host, generation: generation, remoteHostID: "h", online: online,
              inventorySupported: supported, sessionSupported: supported)
    }

    private func result(session: String = "s", config: String = "c", snapshot: RACPExtensionSnapshot? = nil) -> RACPSessionExtensions {
        .init(hostId: "h", sessionId: session, configRevision: config, userLoadingEnabled: true,
              runningTurnId: nil, latestAttempt: snapshot, previousCompleted: nil)
    }

    private func snapshot(id: String, revision: Int, phase: String = "ready") throws -> RACPExtensionSnapshot {
        try RACPExtensionSnapshot.decoded(from: .object([
            "id": .string(id), "hostId": .string("h"), "sessionId": .string("s"), "turnId": .string(id),
            "configRevision": .string("c"), "revision": .number(Double(revision)), "phase": .string(phase),
            "startedAt": .string("2026-11-12T12:00:00Z"), "completedAt": .null,
            "entries": .array([]), "diagnostics": .array([])
        ]))
    }
}

@MainActor
private final class ExtensionTestGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async {
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
    }
    func release(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}
