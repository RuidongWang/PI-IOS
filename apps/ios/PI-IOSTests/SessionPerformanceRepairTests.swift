import Combine
import Foundation
import XCTest
import PIiOSCore
import PIiOSNet
@testable import PI_IOS

@MainActor
final class SessionPerformanceRepairTests: XCTestCase {
    func testReopeningReadOnlySessionDoesNotReuseItsOldAttachment() async throws {
        let session = SessionController()
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = "native"
        snapshot.summary = try JSONDecoder().decode(
            RACPSessionSummary.self,
            from: Data(#"{"id":"native","readOnlyReason":"append_unverified"}"#.utf8)
        )
        session.configureUITestSnapshots(["native": snapshot])
        await session.attach(sessionId: "native")
        XCTAssertEqual(session.sendAdmission, .blockedReadOnly)

        snapshot.summary?.readOnlyReason = nil
        session.configureUITestSnapshots(["native": snapshot])
        await session.attach(sessionId: "native")
        XCTAssertEqual(session.sendAdmission, .start)
    }

    func testPrepareSameDestinationDoesNotInvalidateSelectionTwice() {
        let session = SessionController()
        session.prepareToOpen(sessionId: "a")
        let generation = session.attachmentSelectionGeneration
        session.prepareToOpen(sessionId: "a")
        XCTAssertEqual(session.attachmentSelectionGeneration, generation)
        session.prepareToOpen(sessionId: "b")
        XCTAssertGreaterThan(session.attachmentSelectionGeneration, generation)
    }

    func testSameTargetSharesAttachEvenWhileOutgoingFlushIsPaused() async {
        let session = SessionController()
        session.bind(client: makeClient(), online: true)
        let entered = expectation(description: "outgoing flush")
        let gate = PerformanceAsyncGate()
        var calls = 0
        session.onSessionWillChange = {
            calls += 1
            entered.fulfill()
            await gate.wait()
        }
        let first = Task { await session.attach(sessionId: "a") }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { await session.attach(sessionId: "a") }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        session.prepareToOpen(sessionId: "b")
        gate.release()
        await first.value
        await second.value
        XCTAssertEqual(session.openingSessionID, "b")
        XCTAssertNil(session.lastError)
        XCTAssertTrue(session.isAttaching)
    }

    func testRefreshBurstSharesReadAndAwaitsOneFollowUpWithoutPublishingIdenticalView() async {
        let session = SessionController()
        session.bind(client: makeClient(), online: true)
        let gate = PerformanceAsyncGate()
        let entered = expectation(description: "first read")
        var reads = 0
        session.beforeRefreshReadForTesting = {
            reads += 1
            if reads == 1 { entered.fulfill(); await gate.wait() }
        }
        var publications = 0
        let subscription = session.$view.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let first = Task { await session.refreshView() }
        await fulfillment(of: [entered], timeout: 2)
        var completed = 0
        let burst = (0..<20).map { _ in Task { await session.refreshView(); completed += 1 } }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(completed, 0)
        gate.release()
        await first.value
        for task in burst { await task.value }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(completed, 20)
        XCTAssertEqual(publications, 0)
    }

    func testRefreshCannotOverwriteNewSelectionAfterPausedRead() async {
        let session = SessionController()
        session.bind(client: makeClient(), online: true)
        let gate = PerformanceAsyncGate()
        let entered = expectation(description: "read")
        session.beforeRefreshReadForTesting = { entered.fulfill(); await gate.wait() }
        let refresh = Task { await session.refreshView() }
        await fulfillment(of: [entered], timeout: 2)
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = "new"
        session.bind(client: nil, online: true)
        session.configureUITestSnapshots(["new": snapshot])
        await session.attach(sessionId: "new")
        gate.release()
        await refresh.value
        XCTAssertEqual(session.view.sessionId, "new")
        let generation = session.attachmentSelectionGeneration
        session.prepareToOpen(sessionId: "new")
        await session.attach(sessionId: "new")
        XCTAssertEqual(session.attachmentSelectionGeneration, generation)
        XCTAssertNil(session.openingSessionID)
        session.bind(client: makeClient(), online: true)
        session.prepareToOpen(sessionId: "new")
        XCTAssertEqual(session.openingSessionID, "new", "a new connection must attach again")
    }

    func testDebounceHasTrailingQuietPeriodAndOneSecondMaximum() {
        var debounce = CacheWriteDebounce()
        let start = ContinuousClock.now
        XCTAssertEqual(debounce.delay(now: start), .milliseconds(400))
        XCTAssertEqual(debounce.delay(now: start.advanced(by: .milliseconds(300))), .milliseconds(400))
        XCTAssertEqual(debounce.delay(now: start.advanced(by: .milliseconds(800))), .milliseconds(200))
        XCTAssertEqual(debounce.delay(now: start.advanced(by: .milliseconds(1100))), .zero)
        debounce.reset()
        XCTAssertEqual(debounce.delay(now: start.advanced(by: .seconds(2))), .milliseconds(400))
    }

    func testCleanDisconnectBypassesBlockedHydrationButAcceptedMutationDoesNot() async throws {
        for dirty in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: directory.appendingPathComponent("cache.sqlite"),
                beforeHydratePublish: { entered.signal(); release.wait() })
            defer { release.signal(); try? FileManager.default.removeItem(at: directory) }
            let signalled = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
            XCTAssertTrue(signalled)
            let model = ConnectionModel(cacheStoreOverride: store)
            // AppModel applies persisted retention settings during startup.
            model.updateOfflineCacheLimit(200)
            model.updateOfflineCacheLimit(100)
            XCTAssertFalse(store.hasPendingMutations)
            if dirty { store.removeHost(UUID()); XCTAssertTrue(store.hasPendingMutations) }
            var finished = false
            let disconnect = Task { await model.disconnect(); finished = true }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(finished, !dirty)
            release.signal()
            await disconnect.value
            _ = await store.flush()
        }
    }

    func testFailedSQLiteDeleteIsRetriedAgainstDurableSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: url)
        await store.waitUntilReady()
        let host = UUID(), client = UUID()
        let lease = OfflineSessionCacheWriteLease(clientID: client, connectionGeneration: 1, hostID: host, sessionID: "keep")
        store.updateContext(clientID: client, generation: 1, hostID: host, sessionID: "keep", active: true)
        let seed = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.worker.submit(seed, mutation: { snapshot in
            snapshot.entries.append(.init(id: "deleted", sessionId: "delete", hostID: host, text: "old", createdAt: Date()))
        })
        _ = await store.flush()
        store.worker.beforeWriteForTesting = { throw CocoaError(.fileWriteUnknown) }
        store.removeSessions(hostID: host, sessionIDs: ["delete"])
        let failed = await store.flush()
        guard case .failed = failed else { return XCTFail("injected deletion must fail") }
        XCTAssertTrue(store.hasPendingMutations)
        XCTAssertNil(store.cachedSession(hostID: host, sessionID: "delete"))
        store.worker.beforeWriteForTesting = nil
        let retry = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.saveDraft(sessionID: "keep", hostID: host, text: "saved", idempotencyKey: "stable", permit: retry)
        _ = await store.flush()
        let disk = try OfflineSessionCacheSQLite(url: url).loadSnapshot()
        XCTAssertTrue(disk.entries.isEmpty)
        XCTAssertEqual(disk.drafts.first?.text, "saved")
        let status = store.status.revision
        let previous = store.loadSnapshot()
        let same = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.saveDraft(sessionID: "keep", hostID: host, text: "saved", idempotencyKey: "stable", permit: same)
        _ = await store.flush()
        XCTAssertEqual(store.loadSnapshot(), previous)
        XCTAssertEqual(store.status.revision, status)
    }
    func testCursorAdvanceDoesNotRewriteUnchangedMessagesAndIdenticalSessionIsNoOp() async throws {
        let store = SessionCacheStore(offlineCacheLimit: 200, inMemory: .init())
        let host = UUID(), client = UUID()
        let lease = OfflineSessionCacheWriteLease(clientID: client, connectionGeneration: 1, hostID: host, sessionID: "session")
        store.updateContext(clientID: client, generation: 1, hostID: host, sessionID: "session", active: true)
        var view = RACPSessionView.empty
        view.sessionId = "session"
        view.cursor = RACPCursor(epoch: "epoch", sequence: 1)
        view.items = [RACPItem(id: "user", payload: .object(["role": .string("user"), "text": .string("question")])),
                      RACPItem(id: "reply", payload: .object(["role": .string("assistant"), "text": .string("answer")]))]
        func save(_ value: RACPSessionView) async throws {
            let input = SessionCacheStore.SessionInput(view: value, summary: nil, mode: "agent", permission: "ask",
                modelID: nil, providerID: nil, hostID: host, sessionID: "session")
            let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
            let result = await store.saveSession(input, permit: permit)
            guard case .committed = result else { return XCTFail("session save must commit") }
        }
        try await save(view)
        let first = store.loadSnapshot()
        let revision = store.status.revision
        try await save(view)
        XCTAssertEqual(store.loadSnapshot(), first)
        XCTAssertEqual(store.status.revision, revision)
        view.cursor = RACPCursor(epoch: "epoch", sequence: 2)
        try await save(view)
        XCTAssertEqual(store.loadSnapshot().entries, first.entries)
        XCTAssertEqual(store.loadSnapshot().cursors.first?.sequence, 2)
        view.items[1] = RACPItem(id: "reply", payload: .object(["role": .string("assistant"), "text": .string("new answer")]))
        try await save(view)
        let entries = store.loadSnapshot().entries
        XCTAssertEqual(entries.first(where: { $0.id == "user" }), first.entries.first(where: { $0.id == "user" }))
        XCTAssertEqual(entries.first(where: { $0.id == "reply" })?.sequence, 2)
        XCTAssertEqual(entries.first(where: { $0.id == "reply" })?.text, "new answer")
    }

    func testOptimisticUserEchoAppearsImmediatelyAndIsReplacedByServerItem() {
        let old = item("old-user", role: "user", text: "hello", turn: nil)
        var pending = [echo(id: "local-user-turn1", session: "s", turn: "turn1", text: "hello",
                             baseline: ["old-user"])]

        var merged = SessionController.mergePendingUserEchoes(&pending, into: [old], sessionID: "s")
        XCTAssertEqual(merged.map(\.id), ["old-user", "local-user-turn1"])
        XCTAssertEqual(merged.last?.role, "user")
        XCTAssertEqual(merged.last?.text, "hello")
        XCTAssertEqual(merged.last?.turnId, "turn1")
        // An identical message from before this send must not hide the new one.
        XCTAssertEqual(pending.count, 1)

        let server = item("srv-user", role: "user", text: "hello", turn: "turn1")
        merged = SessionController.mergePendingUserEchoes(&pending, into: [old, server], sessionID: "s")
        XCTAssertEqual(merged.map(\.id), ["old-user", "srv-user"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testOptimisticEchoMatchesServerUserMessageWithoutTurnID() {
        var pending = [echo(id: "local-user-1", session: "s", turn: "turn1", text: "hello",
                             baseline: ["old-user"])]
        let server = item("srv-user", role: "user", text: " hello ", turn: nil)
        let merged = SessionController.mergePendingUserEchoes(&pending, into: [server], sessionID: "s")
        XCTAssertEqual(merged.map(\.id), ["srv-user"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testQueuedOrCanceledTurnDoesNotCreateTranscriptEcho() {
        XCTAssertFalse(SessionController.shouldEchoSend(status: "queued", queued: true))
        XCTAssertFalse(SessionController.shouldEchoSend(status: nil, queued: true))
        XCTAssertFalse(SessionController.shouldEchoSend(status: "canceled", queued: false))
        XCTAssertFalse(SessionController.shouldEchoSend(status: "failed", queued: false))
        XCTAssertTrue(SessionController.shouldEchoSend(status: "running", queued: false))
    }

    func testOptimisticEchoIsSessionScopedAndDoesNotDuplicateOnRefresh() {
        var pending = [echo(id: "local-user-1", session: "a", turn: "turn1", text: "hello",
                             baseline: [])]
        let other = SessionController.mergePendingUserEchoes(&pending, into: [], sessionID: "b")
        XCTAssertTrue(other.isEmpty)
        XCTAssertEqual(pending.count, 1)

        var first = SessionController.mergePendingUserEchoes(&pending, into: [], sessionID: "a")
        first = SessionController.mergePendingUserEchoes(&pending, into: first, sessionID: "a")
        XCTAssertEqual(first.map(\.id), ["local-user-1"])
        XCTAssertEqual(pending.count, 1)
    }

    func testOptimisticEchoStaysBeforeAssistantItemAlreadyStreaming() {
        let old = item("old-user", role: "user", text: "hello", turn: nil)
        let streaming = item("active-assistant", role: "assistant", text: "working", turn: "turn1")
        var pending = [echo(id: "local-user-turn1", session: "s", turn: "turn1", text: "hello",
                             baseline: ["old-user"], anchor: "old-user")]
        let merged = SessionController.mergePendingUserEchoes(
            &pending, into: [old, streaming], sessionID: "s"
        )
        XCTAssertEqual(merged.map(\.id), ["old-user", "local-user-turn1", "active-assistant"])
    }

    private func echo(id: String, session: String, turn: String, text: String,
                      baseline: Set<String>, anchor: String? = nil) -> SessionController.PendingUserEcho {
        .init(id: id, sessionID: session, turnID: turn, text: text,
              baselineItemIDs: baseline, anchorItemID: anchor)
    }

    private func item(_ id: String, role: String, text: String, turn: String?) -> RACPItem {
        var payload: [String: JSONValue] = ["role": .string(role), "text": .string(text)]
        if let turn { payload["turnId"] = .string(turn) }
        return RACPItem(id: id, payload: .object(payload))
    }


    private func makeClient() -> RACPClient {
        RACPClient(configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil), confirmer: PerformanceRejectHost())
    }
}

@MainActor
private final class PerformanceAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func release() { let pending = continuations; continuations = []; for continuation in pending { continuation.resume() } }
}

private struct PerformanceRejectHost: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation { .reject }
}
