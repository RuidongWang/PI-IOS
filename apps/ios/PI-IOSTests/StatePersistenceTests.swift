import Foundation
import XCTest
import UIKit
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

final class StatePersistenceTests: XCTestCase {
    private var root: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateURL = root.appendingPathComponent(StateFile.fileName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testFlushPersistsReadingPositionAndNewerSetting() async throws {
        let model = AppModel(seed: .empty, stateFileURL: stateURL)
        let hostID = UUID()

        model.rememberReadingPosition(
            hostID: hostID,
            sessionID: "session-1",
            lastVisibleItemID: "item-42",
            isNearBottom: false
        )
        let firstSaved = await model.flushPersistentState()
        XCTAssertTrue(firstSaved)
        let first = StateFile.load(from: stateURL)
        XCTAssertEqual(
            first.state.readingPositionsByHost[hostID.uuidString]?["session-1"],
            ConversationReadingPosition(lastVisibleItemID: "item-42", isNearBottom: false)
        )

        model.setOfflineCacheLimit(400)

        let saved = await model.flushPersistentState()
        XCTAssertTrue(saved)
        XCTAssertNil(model.saveError)

        let outcome = StateFile.load(from: stateURL)
        XCTAssertNil(outcome.warning)
        XCTAssertTrue(outcome.canSave)
        XCTAssertEqual(outcome.state.offlineCacheLimit, 400)
        XCTAssertEqual(
            outcome.state.readingPositionsByHost[hostID.uuidString]?["session-1"],
            ConversationReadingPosition(lastVisibleItemID: "item-42", isNearBottom: false)
        )
    }

    @MainActor
    func testFlushReturnsFalseForRealWriteFailureThenRecovers() async throws {
        let model = AppModel(seed: .empty, stateFileURL: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let failed = await model.flushPersistentState()
        XCTAssertFalse(failed)
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let recovered = await model.flushPersistentState()
        XCTAssertTrue(recovered)
        XCTAssertNil(model.saveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testAsyncSaveAndBarrierLeaveLastAcceptedStateOnDisk() async throws {
        let first = PersistedState(
            offlineCacheLimit: 100,
            readingPositionsByHost: ["host-a": ["session-a": ConversationReadingPosition(
                lastVisibleItemID: "first",
                isNearBottom: false
            )]]
        )
        let second = PersistedState(
            offlineCacheLimit: 500,
            readingPositionsByHost: ["host-b": ["session-b": ConversationReadingPosition(
                lastVisibleItemID: "second",
                isNearBottom: true
            )]]
        )

        try await StateFile.saveAsync(first, to: stateURL)
        try await StateFile.saveAsync(second, to: stateURL)
        await StateFile.waitForPendingWrites()

        let outcome = StateFile.load(from: stateURL)
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(outcome.state.offlineCacheLimit, 500)
        XCTAssertNil(outcome.state.readingPositionsByHost["host-a"])
        XCTAssertEqual(
            outcome.state.readingPositionsByHost["host-b"]?["session-b"]?.lastVisibleItemID,
            "second"
        )
        XCTAssertEqual(
            outcome.state.readingPositionsByHost["host-b"]?["session-b"]?.isNearBottom,
            true
        )
    }

    func testExplicitSaveKeepsBoolAndCheckpointConsistency() throws {
        let state = PersistedState(
            offlineCacheLimit: 1_000,
            readingPositionsByHost: ["host": ["session": ConversationReadingPosition(
                lastVisibleItemID: "checkpoint",
                isNearBottom: true
            )]]
        )

        try StateFile.save(state, to: stateURL)

        let outcome = StateFile.load(from: stateURL)
        XCTAssertEqual(outcome.state, state)
        XCTAssertTrue(outcome.canSave)
        XCTAssertNil(outcome.warning)
    }

    func testExplicitSyncSaveThrowsOnDiskFailure() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        XCTAssertThrowsError(try StateFile.save(.empty, to: stateURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    @MainActor
    func testFlushReturnsFalseWhenANewerAcceptedWriteFailsDuringAwait() async throws {
        let model = AppModel(seed: .empty, stateFileURL: stateURL)
        let gate = InterleavedWriteGate()
        StateFile.setBeforeWriteHookForTesting { url in
            try gate.beforeWrite(url)
        }
        defer {
            StateFile.setBeforeWriteHookForTesting(nil)
            gate.releaseFirst()
            gate.releaseSecondFailure()
        }

        let firstFlush = Task { await model.flushPersistentState() }
        let firstEntered = await Task.detached { gate.waitForFirstEntry() }.value
        guard firstEntered else {
            return XCTFail("first flush did not reach the real write")
        }

        let secondFlush = Task { await model.flushPersistentState() }
        try await Task.sleep(for: .milliseconds(80))
        gate.releaseFirst()
        let secondEntered = await Task.detached { gate.waitForSecondEntry() }.value
        guard secondEntered else {
            return XCTFail("newer accepted write did not reach the real write")
        }
        gate.releaseSecondFailure()

        let firstResult = await firstFlush.value
        let secondResult = await secondFlush.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertNotNil(model.saveError)
    }

    @MainActor
    func testCommittedBarrierDoesNotClearNewerFailureAfterBarrier() async throws {
        let model = AppModel(seed: .empty, stateFileURL: stateURL)
        model.afterPersistBarrierHookForTesting = {
            // Real newer accepted write that fails after our barrier committed.
            StateFile.setBeforeWriteHookForTesting { _ in
                throw InjectedAfterBarrierFailure()
            }
            defer { StateFile.setBeforeWriteHookForTesting(nil) }
            model.setOfflineCacheLimit(400)
        }
        defer {
            model.afterPersistBarrierHookForTesting = nil
            StateFile.setBeforeWriteHookForTesting(nil)
        }

        let flushed = await model.flushPersistentState()
        XCTAssertTrue(flushed)
        XCTAssertNotNil(model.saveError)
    }
    @MainActor
    func testHundredReadingPositionRevisionsAndNewerSettingShareOneDiskSequence() async throws {
        let model = AppModel(seed: .empty, stateFileURL: stateURL)
        let hostID = UUID()
        let target = try XCTUnwrap(stateURL)
        let evidence = StateWriteEvidence()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        StateFile.setWriteObserverForTesting { stage, url in
            guard url == target else { return }
            evidence.record(stage)
        }
        StateFile.setBeforeWriteHookForTesting { url in
            guard url == target, evidence.takeFirstGate() else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 8)
        }
        defer {
            StateFile.setBeforeWriteHookForTesting(nil)
            StateFile.setWriteObserverForTesting(nil)
            release.signal()
        }
        model.rememberReadingPosition(hostID: hostID, sessionID: "hundred",
                                      lastVisibleItemID: "position-0", isNearBottom: false)
        var flushes = [Task { await model.flushPersistentState() }]
        let reached = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        guard reached else { return XCTFail("first position write did not reach its real adapter") }
        for revision in 1..<100 {
            // Wait for actual queue admission before changing the UI snapshot
            // again; this proves 100 distinct inputs, rather than 100 copies of
            // the snapshot captured after a loop has already finished.
            for _ in 0..<1_000 where evidence.accepted < revision { await Task.yield() }
            XCTAssertEqual(evidence.accepted, revision)
            model.rememberReadingPosition(hostID: hostID, sessionID: "hundred",
                                          lastVisibleItemID: "position-\(revision)", isNearBottom: false)
            flushes.append(Task { await model.flushPersistentState() })
        }
        for _ in 0..<1_000 where evidence.accepted < 100 { await Task.yield() }
        XCTAssertEqual(evidence.accepted, 100)
        // AC-C1 针对 250ms 热路径写：这部分全部经 saveAsync 入队，不得在主线程执行。
        // 其后的 `setOfflineCacheLimit` 是显式同步提交（契约 §2.3 允许同步桥接），
        // 且 libdispatch 可能在调用线程内联执行 sync 块，故不在本条断言范围内。
        XCTAssertFalse(evidence.sawMainThreadIO)
        release.signal()
        // Explicit settings remain an actual synchronous commit. Its snapshot
        // contains the newest reading position, and is ordered after all older
        // async snapshots already admitted while the first adapter was paused.
        model.setOfflineCacheLimit(500)
        for flush in flushes { let result = await flush.value; XCTAssertTrue(result) }
        let result = await model.flushPersistentState()
        XCTAssertTrue(result)
        let disk = StateFile.load(from: target)
        XCTAssertEqual(evidence.maximumConcurrent, 1)
        XCTAssertGreaterThanOrEqual(evidence.completed, 101)
        XCTAssertEqual(disk.state.offlineCacheLimit, 500)
        XCTAssertEqual(disk.state.readingPositionsByHost[hostID.uuidString]?["hundred"]?.lastVisibleItemID, "position-99")
        XCTAssertEqual(model.readingPosition(hostID: hostID, sessionID: "hundred")?.lastVisibleItemID, "position-99")
        XCTAssertNil(model.saveError)
    }

    /// This is App-layer restart/offline evidence with real SQLite + state JSON.
    /// The disconnected transport is synthetic; it is not an iPhone/SSH test.
    @MainActor
    func testRealStateAndSQLiteRestartRecoverOfflineTablesAndRetention() async throws {
        let cacheURL = root.appendingPathComponent("session-cache.sqlite")
        let target = try XCTUnwrap(stateURL)
        let host = HostRecord(id: UUID(), name: "Persistence restart", host: "localhost", port: 22,
                              username: "restart-\(UUID().uuidString)", authKind: .password,
                              createdAt: Date(), isCurrent: true)
        let sessionID = "restart-session"
        let state = PersistedState(hosts: [host], offlineCacheLimit: 100, lastSessionId: sessionID,
                                   lastSessionByHost: [host.id.uuidString: sessionID],
                                   readingPositionsByHost: [host.id.uuidString: [sessionID: .init(lastVisibleItemID: "item-160-assistant", isNearBottom: false)]])
        weak var releasedOwner: SessionCacheWorker?
        do {
            let store = SessionCacheStore(offlineCacheLimit: 100, fileURL: cacheURL)
            releasedOwner = store.worker
            let synthetic = UITestFixture(state: state, cache: .init(), connectionState: .offline(reason: "synthetic disconnected transport"))
            let connection = ConnectionModel(fixture: synthetic, cacheStoreOverride: store)
            let app = AppModel(seed: state, stateFileURL: target, connectionOverride: connection)
            await connection.waitForOfflineCacheReady()
            let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                      hostID: host.id, sessionID: sessionID)
            store.updateContext(clientID: lease.clientID, generation: 1, hostID: host.id,
                                sessionID: sessionID, active: true)
            let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
            let batch = restartSnapshot(hostID: host.id, sessionID: sessionID)
            let saved = await withCheckedContinuation { continuation in
                store.worker.submit(permit, mutation: { $0 = batch }, completion: { continuation.resume(returning: $0) })
            }
            guard case .committed = saved else { return XCTFail("initial SQLite commit failed") }
            await app.flushForBackground()
            XCTAssertNil(app.saveError)
            XCTAssertNil(connection.offlineCacheLoadError)
            XCTAssertEqual(connection.cachedEntries(sessionId: sessionID).count, 200)
        }
        // Drain short status callbacks, then require a genuinely new disk owner.
        // Reusing the first owner's warm mirror would not prove restart hydrate.
        for _ in 0..<100 where releasedOwner != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(releasedOwner)
        let reopened = SessionCacheStore(offlineCacheLimit: 100, fileURL: cacheURL)
        let offline = UITestFixture(state: .empty, cache: .init(), connectionState: .offline(reason: "synthetic disconnected transport"))
        let connection = ConnectionModel(fixture: offline, cacheStoreOverride: reopened)
        let restarted = AppModel(stateFileURL: target, connectionOverride: connection)
        await connection.waitForOfflineCacheReady()
        XCTAssertFalse(connection.state.isOnline)
        XCTAssertTrue(connection.offlineCacheReady)
        XCTAssertNil(connection.offlineCacheLoadError)
        XCTAssertEqual(restarted.currentHost?.id, host.id)
        XCTAssertEqual(restarted.lastSessionId, sessionID)
        XCTAssertEqual(restarted.offlineCacheLimit, 100)
        XCTAssertEqual(connection.cacheTurnLimit, 100)
        XCTAssertEqual(connection.cacheItemLimit, connection.cacheTurnLimit)
        XCTAssertEqual(restarted.readingPosition(hostID: host.id, sessionID: sessionID)?.lastVisibleItemID, "item-160-assistant")
        let cached = try XCTUnwrap(connection.cachedSession(sessionId: sessionID))
        let expectedIDs = Set((105..<205).flatMap { ["item-\($0)-user", "item-\($0)-assistant"] })
        XCTAssertEqual(Set(cached.entries.map(\.id)), expectedIDs)
        XCTAssertEqual(Set(cached.entries.map(\.turnId)).count, 100)
        XCTAssertEqual(cached.cursor?.sequence, 205)
        XCTAssertEqual(cached.approvals.first?.id, "approval")
        XCTAssertEqual(cached.draft?.idempotencyKey, "pending-key")
        XCTAssertEqual(cached.draft?.text, "pending-draft")
        let disk = try OfflineSessionCacheSQLite(url: cacheURL).loadSnapshot()
        XCTAssertEqual(disk.sessions.first?.title, "Restart title")
        XCTAssertEqual(disk.entries.count, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @MainActor
    func testBackgroundFlushRunsCacheAfterStateFailureAndPreservesKnownFiles() async throws {
        let target = try XCTUnwrap(stateURL)
        try StateFile.save(.empty, to: target)
        let originalStateBytes = try Data(contentsOf: target)
        let hostID = UUID()
        let cacheURL = root.appendingPathComponent("background-cache.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 100, fileURL: cacheURL)
        let connection = ConnectionModel(cacheStoreOverride: store)
        let app = AppModel(seed: .empty, stateFileURL: target, connectionOverride: connection)
        await connection.waitForOfflineCacheReady()
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: "background")
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: lease.sessionID, active: true)
        let permit = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.saveDraft(sessionID: lease.sessionID, hostID: hostID, text: "known-good",
                        idempotencyKey: "key", permit: permit)
        _ = await store.flush()
        let originalCache = try OfflineSessionCacheSQLite(url: cacheURL).loadSnapshot()
        let oldSuccess = store.status
        let events = FlushEventLog()
        let taskID = UUID()
        StateFile.setBeforeWriteHookForTesting { url in
            guard url == target else { return }
            events.append("state.failed")
            throw InjectedAfterBarrierFailure()
        }
        store.worker.beforeWriteForTesting = {
            events.append("cache.failed")
            throw InjectedAfterBarrierFailure()
        }
        app.afterPersistBarrierHookForTesting = {
            XCTAssertEqual(BackgroundFlushTaskMarker.identity, taskID)
            events.append("state.barrier")
        }
        connection.beforeCacheFlushHookForTesting = {
            XCTAssertEqual(BackgroundFlushTaskMarker.identity, taskID)
            events.append("cache.begin")
            // A real deletion is accepted by the second flush, after the state
            // barrier. Its failed transaction must leave the known good disk.
            store.removeHost(hostID)
        }
        defer {
            StateFile.setBeforeWriteHookForTesting(nil)
            store.worker.beforeWriteForTesting = nil
            app.afterPersistBarrierHookForTesting = nil
            connection.beforeCacheFlushHookForTesting = nil
        }
        await BackgroundFlushTaskMarker.$identity.withValue(taskID) { await app.flushForBackground() }
        XCTAssertEqual(events.values, ["state.failed", "state.barrier", "cache.begin", "cache.failed"])
        XCTAssertNotNil(app.saveError)
        XCTAssertNotNil(connection.offlineCacheLoadError)
        connection.applyCacheStatusForTesting(oldSuccess)
        XCTAssertNotNil(connection.offlineCacheLoadError)
        XCTAssertEqual(try Data(contentsOf: target), originalStateBytes)
        XCTAssertEqual(try OfflineSessionCacheSQLite(url: cacheURL).loadSnapshot(), originalCache)
        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: lease.sessionID))
    }

    @MainActor
    func testCancelledBackgroundWriteCannotClearExistingSaveError() async throws {
        let target = try XCTUnwrap(stateURL)
        let model = AppModel(seed: .empty, stateFileURL: target)
        StateFile.setBeforeWriteHookForTesting { url in
            if url == target { throw InjectedAfterBarrierFailure() }
        }
        model.setOfflineCacheLimit(400)
        let existingError = try XCTUnwrap(model.saveError)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        StateFile.setBeforeWriteHookForTesting { url in
            guard url == target else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        defer { StateFile.setBeforeWriteHookForTesting(nil); release.signal() }
        let cancelled = Task { await model.flushPersistentState() }
        let reached = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        guard reached else { return XCTFail("old background state write did not enter its adapter") }
        cancelled.cancel()
        release.signal()
        _ = await cancelled.value
        // Physical success is allowed to finish, but the cancelled background
        // lease no longer owns publication of saveError.
        XCTAssertEqual(model.saveError, existingError)
        XCTAssertEqual(StateFile.load(from: target).state.offlineCacheLimit, 400)
        StateFile.setBeforeWriteHookForTesting(nil)
        let recovered = await model.flushPersistentState()
        XCTAssertTrue(recovered)
        XCTAssertNil(model.saveError)
    }

    @MainActor
    func testRepeatedBackgroundLeasesEndOnceAndSuppressOldCompletion() async throws {
        let oldGate = BackgroundTestGate()
        let oldStarted = expectation(description: "old background task started")
        let newCompleted = expectation(description: "new background task completed")
        var ended: [Int] = []
        var oldCompletion = 0
        var newCompletion = 0
        var duplicateWork = 0
        var expiration: (@Sendable () -> Void)?
        let old = BackgroundFlushLease(name: "old", begin: { callback in
            expiration = callback
            return UIBackgroundTaskIdentifier(rawValue: 101)
        }, end: { ended.append($0.rawValue) })
        old.start(work: {
            oldStarted.fulfill()
            await oldGate.wait()
        }, completion: { oldCompletion += 1 })
        old.start(work: { duplicateWork += 1 })
        await fulfillment(of: [oldStarted], timeout: 2)
        old.cancelAndFinish()
        old.cancelAndFinish()
        expiration?()
        expiration?()
        let newest = BackgroundFlushLease(name: "new", begin: { _ in
            UIBackgroundTaskIdentifier(rawValue: 102)
        }, end: { ended.append($0.rawValue) })
        XCTAssertGreaterThan(newest.version, old.version)
        newest.start(work: {}, completion: { newCompletion += 1; newCompleted.fulfill() })
        await oldGate.open()
        await fulfillment(of: [newCompleted], timeout: 2)
        try await Task.sleep(for: .milliseconds(80))
        newest.cancelAndFinish()
        XCTAssertEqual(oldCompletion, 0)
        XCTAssertEqual(newCompletion, 1)
        XCTAssertEqual(duplicateWork, 0)
        XCTAssertEqual(ended.filter { $0 == 101 }.count, 1)
        XCTAssertEqual(ended.filter { $0 == 102 }.count, 1)
    }

    private func restartSnapshot(hostID: UUID, sessionID: String) -> SessionCacheStore.Snapshot {
        SessionCacheStore.Snapshot(
            sessions: [.init(hostID: hostID, id: sessionID, title: "Restart title", projectID: nil,
                             mode: "agent", permissionMode: "ask", modelID: nil, providerID: nil,
                             epoch: "restart", sequence: 205, updatedAt: Date())],
            entries: (0..<205).flatMap { turn -> [SessionCacheStore.Entry] in
                let roles = ["user", "assistant"]
                return roles.enumerated().map { pair in
                    let role = pair.element
                    let offset = pair.offset
                    return .init(id: "item-\(turn)-\(role)", sessionId: sessionID, hostID: hostID,
                                 text: "text-\(turn)-\(role)",
                                 createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + turn * 2 + offset)),
                                 kind: "message", role: role, toolName: nil, status: "completed",
                                 epoch: "restart", sequence: turn * 2 + offset, turnId: "turn:\(turn)")
                }
            },
            cursors: [.init(hostID: hostID, sessionId: sessionID, epoch: "restart", sequence: 205, updatedAt: Date())],
            approvals: [.init(id: "approval", sessionId: sessionID, hostID: hostID,
                              payload: .object(["id": .string("approval")]), revision: 2,
                              status: "pending", decision: nil, createdAt: Date())],
            drafts: [.init(hostID: hostID, sessionId: sessionID, text: "pending-draft",
                           idempotencyKey: "pending-key", updatedAt: Date())]
        )
    }
}

private enum BackgroundFlushTaskMarker { @TaskLocal static var identity: UUID? }

private actor BackgroundTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private final class FlushEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

private final class StateWriteEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = 0
    private var active = 0
    private var maximum = 0
    private var finished = 0
    private var firstTaken = false
    private var mainIO = false
    func record(_ stage: StateFile.WriteStage) {
        lock.lock(); defer { lock.unlock() }
        switch stage {
        case .enqueued: admitted += 1
        case .began:
            active += 1
            maximum = max(maximum, active)
            mainIO = mainIO || Thread.isMainThread
        case .finished: active -= 1; finished += 1
        }
    }
    func takeFirstGate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !firstTaken else { return false }
        firstTaken = true
        return true
    }
    var accepted: Int { lock.lock(); defer { lock.unlock() }; return admitted }
    var maximumConcurrent: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return finished }
    var sawMainThreadIO: Bool { lock.lock(); defer { lock.unlock() }; return mainIO }
}

private struct InjectedAfterBarrierFailure: LocalizedError {
    var errorDescription: String? { "injected post-barrier write failure" }
}

private final class InterleavedWriteGate: @unchecked Sendable {
    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "injected state write failure" }
    }

    private let firstEntered = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let secondEntered = DispatchSemaphore(value: 0)
    private let secondRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0

    func beforeWrite(_ url: URL) throws {
        lock.lock()
        count += 1
        let ordinal = count
        lock.unlock()

        switch ordinal {
        case 1:
            firstEntered.signal()
            firstRelease.wait()
        case 2:
            secondEntered.signal()
            secondRelease.wait()
            throw InjectedFailure()
        default:
            break
        }
    }

    func waitForFirstEntry() -> Bool {
        firstEntered.wait(timeout: .now() + 2) == .success
    }

    func waitForSecondEntry() -> Bool {
        secondEntered.wait(timeout: .now() + 2) == .success
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func releaseSecondFailure() {
        secondRelease.signal()
    }
}
