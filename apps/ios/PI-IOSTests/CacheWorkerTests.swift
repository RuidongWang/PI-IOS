import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

final class CacheWorkerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFacadesShareOneOwnerAndSerializeCommits() async throws {
        let fileURL = root.appendingPathComponent("cache.sqlite")
        let hostID = UUID()
        var stores: [SessionCacheStore] = []
        for index in 0..<8 {
            let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
            store.updateContext(
                clientID: UUID(),
                generation: 1,
                hostID: hostID,
                sessionID: "session-\(index)",
                active: true
            )
            stores.append(store)
        }
        let owner = try XCTUnwrap(stores.first)
        await owner.waitUntilReady()
        for store in stores.dropFirst() {
            XCTAssertTrue(store.worker === owner.worker)
        }

        let probe = CommitProbe()
        owner.worker.beforeCommitForTesting = {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.002)
            probe.leave()
        }
        defer { owner.worker.beforeCommitForTesting = nil }

        var tasks: [Task<SessionCacheStore.Outcome, Never>] = []
        for (index, store) in stores.enumerated() {
            let sessionID = "session-\(index)"
            let lease = OfflineSessionCacheWriteLease(
                clientID: UUID(),
                connectionGeneration: 1,
                hostID: hostID,
                sessionID: sessionID
            )
            store.updateContext(
                clientID: lease.clientID,
                generation: lease.connectionGeneration,
                hostID: hostID,
                sessionID: sessionID,
                active: true
            )
            let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
            let input = makeInput(hostID: hostID, sessionID: sessionID, text: "item-\(index)")
            tasks.append(Task { await store.saveSession(input, permit: permit) })
        }
        for task in tasks {
            assertCommitted(await task.value)
        }
        assertCommitted(await owner.flush())

        XCTAssertEqual(probe.maximumConcurrent, 1)
        let snapshot = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(snapshot.entries.count, 8)
        XCTAssertEqual(Set(snapshot.entries.map(\.sessionId)).count, 8)
    }

    func testHundredDraftInputsKeepLatestAcceptedState() async throws {
        let fileURL = root.appendingPathComponent("drafts.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let hostID = UUID()
        let sessionID = "session-draft"
        let clientID = UUID()
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let gate = FirstCommitGate()
        store.worker.beforeCommitForTesting = {
            guard gate.take() else { return }
            entered.signal()
            release.wait()
        }
        defer {
            store.worker.beforeCommitForTesting = nil
            release.signal()
        }

        let firstPermit = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.saveDraft(
            sessionID: sessionID,
            hostID: hostID,
            text: "draft-0",
            idempotencyKey: "key-0",
            permit: firstPermit
        )
        guard waitForSignal(entered) else {
            return XCTFail("first draft commit did not reach the gate")
        }

        for index in 1..<100 {
            let permit = try XCTUnwrap(store.permit(for: lease, draft: true))
            store.saveDraft(
                sessionID: sessionID,
                hostID: hostID,
                text: "draft-\(index)",
                idempotencyKey: "key-\(index)",
                permit: permit
            )
        }
        store.worker.beforeCommitForTesting = nil
        release.signal()
        assertCommitted(await store.flush())

        XCTAssertEqual(store.cachedSession(hostID: hostID, sessionID: sessionID)?.draft?.text, "draft-99")
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertEqual(document.snapshot.drafts.count, 1)
        XCTAssertEqual(document.snapshot.drafts.first?.text, "draft-99")
        XCTAssertEqual(document.snapshot.drafts.first?.idempotencyKey, "key-99")
    }

    func testAbandonedNewerPermitDoesNotSuppressEarlierWrite() async throws {
        let fileURL = root.appendingPathComponent("abandon.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "abandon"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        let accepted = try XCTUnwrap(store.permit(for: lease, draft: false))
        let abandoned = try XCTUnwrap(store.permit(for: lease, draft: false))
        store.abandon(abandoned)

        assertCommitted(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "earlier"),
                permit: accepted
            )
        )
        assertCommitted(await store.flush())
        XCTAssertEqual(
            store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "earlier"
        )
    }

    func testAbandonedNewerPermitCannotReopenCommittedFloor() async throws {
        let fileURL = root.appendingPathComponent("abandon-floor.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "abandon-floor"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        // Order: delayed permit 1, permit 2 commits, permit 3 is abandoned.
        // Submitting permit 1 late must not overwrite the committed state.
        let delayed = try XCTUnwrap(store.permit(for: lease, draft: false))
        let committed = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "committed"),
                permit: committed
            )
        )

        let abandoned = try XCTUnwrap(store.permit(for: lease, draft: false))
        store.abandon(abandoned)

        assertSuperseded(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "late"),
                permit: delayed
            )
        )
        assertCommitted(await store.flush())
        XCTAssertEqual(
            store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "committed"
        )
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertEqual(document.snapshot.entries.first?.text, "committed")
    }

    func testSameSessionIDIsIsolatedByHost() async throws {
        let fileURL = root.appendingPathComponent("host-isolation.json")
        let first = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let second = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await first.waitUntilReady()
        let hostA = UUID()
        let hostB = UUID()
        let sessionID = "shared-name"

        for (store, hostID, text) in [(first, hostA, "host-a"), (second, hostB, "host-b")] {
            let clientID = UUID()
            let lease = OfflineSessionCacheWriteLease(
                clientID: clientID,
                connectionGeneration: 1,
                hostID: hostID,
                sessionID: sessionID
            )
            store.updateContext(
                clientID: clientID,
                generation: 1,
                hostID: hostID,
                sessionID: sessionID,
                active: true
            )
            let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
            assertCommitted(
                await store.saveSession(
                    makeInput(hostID: hostID, sessionID: sessionID, text: text),
                    permit: permit
                )
            )
        }
        assertCommitted(await first.flush())

        XCTAssertEqual(
            first.cachedSession(hostID: hostA, sessionID: sessionID)?.entries.first?.text,
            "host-a"
        )
        XCTAssertEqual(
            second.cachedSession(hostID: hostB, sessionID: sessionID)?.entries.first?.text,
            "host-b"
        )
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertEqual(document.snapshot.entries.count, 2)
        XCTAssertEqual(Set(document.snapshot.entries.compactMap(\.hostID)), Set([hostA, hostB]))
    }

    func testDraftUsesHostLeaseWhileSessionWriteUsesSelection() async throws {
        let fileURL = root.appendingPathComponent("leases.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let clientID = UUID()
        let hostID = UUID()
        let oldSessionID = "old"
        let newSessionID = "new"
        let oldLease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: oldSessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: oldSessionID,
            active: true
        )
        let oldDraftPermit = try XCTUnwrap(store.permit(for: oldLease, draft: true))
        let oldSessionPermit = try XCTUnwrap(store.permit(for: oldLease, draft: false))
        let newDraftPermit = try XCTUnwrap(
            store.permit(
                for: OfflineSessionCacheWriteLease(
                    clientID: clientID,
                    connectionGeneration: 1,
                    hostID: hostID,
                    sessionID: newSessionID
                ),
                draft: true
            )
        )

        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: newSessionID,
            active: true
        )
        store.saveDraft(
            sessionID: oldSessionID,
            hostID: hostID,
            text: "still-mine",
            idempotencyKey: "old-key",
            permit: oldDraftPermit
        )
        let staleSession = await store.saveSession(
            makeInput(hostID: hostID, sessionID: oldSessionID, text: "stale"),
            permit: oldSessionPermit
        )
        assertSuperseded(staleSession)
        assertCommitted(await store.flush())

        let oldSession = store.cachedSession(hostID: hostID, sessionID: oldSessionID)
        XCTAssertEqual(oldSession?.draft?.text, "still-mine")
        XCTAssertTrue(oldSession?.entries.isEmpty == true)

        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: UUID(),
            sessionID: newSessionID,
            active: true
        )
        store.saveDraft(
            sessionID: newSessionID,
            hostID: hostID,
            text: "wrong-host",
            idempotencyKey: "wrong-key",
            permit: newDraftPermit
        )
        assertCommitted(await store.flush())

        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: newSessionID))
    }

    func testDeleteBarrierRejectsWritePausedBeforeCommit() async throws {
        let fileURL = root.appendingPathComponent("delete.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "delete-me"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.worker.beforeCommitForTesting = {
            entered.signal()
            release.wait()
        }
        defer {
            store.worker.beforeCommitForTesting = nil
            release.signal()
        }
        let save = Task {
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "must-not-survive"),
                permit: permit
            )
        }
        guard waitForSignal(entered) else {
            return XCTFail("write did not reach the commit gate")
        }

        store.worker.beforeCommitForTesting = nil
        store.removeSessions(hostID: hostID, sessionIDs: [sessionID])
        release.signal()
        assertSuperseded(await save.value)
        assertCommitted(await store.flush())

        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: sessionID))
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertTrue(document.snapshot.entries.isEmpty)
        XCTAssertTrue(document.snapshot.drafts.isEmpty)

        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: "other",
            active: true
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        XCTAssertNil(store.permit(for: lease, draft: false))
    }

    func testFlushBarrierWaitsForPausedCommit() async throws {
        let fileURL = root.appendingPathComponent("flush.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "flush"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.worker.beforeCommitForTesting = {
            entered.signal()
            release.wait()
        }
        defer {
            store.worker.beforeCommitForTesting = nil
            release.signal()
        }
        let save = Task {
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "flush-me"),
                permit: permit
            )
        }
        guard waitForSignal(entered) else {
            return XCTFail("write did not reach the flush gate")
        }

        let flushed = CompletionFlag()
        let flush = Task {
            let outcome = await store.flush()
            await flushed.complete()
            return outcome
        }
        try await Task.sleep(for: .milliseconds(80))
        let completedBeforeRelease = await flushed.isComplete
        XCTAssertFalse(completedBeforeRelease)

        store.worker.beforeCommitForTesting = nil
        release.signal()
        assertCommitted(await save.value)
        assertCommitted(await flush.value)
        let completedAfterRelease = await flushed.isComplete
        XCTAssertTrue(completedAfterRelease)
    }

    func testCorruptFileStaysUntouchedAndWritesFail() async throws {
        let fileURL = root.appendingPathComponent("corrupt.json")
        let original = Data("{not-json".utf8)
        try original.write(to: fileURL)

        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        XCTAssertTrue(store.status.ready)
        XCTAssertNotNil(store.status.error)

        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "corrupt"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertFailed(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "do-not-overwrite"),
                permit: permit
            )
        )
        assertFailed(await store.flush())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testNewerSameEntityFromAnotherFacadeSupersedesEarlierLateSubmit() async throws {
        let fileURL = root.appendingPathComponent("cross-facade.json")
        let first = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let second = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await first.waitUntilReady()
        XCTAssertTrue(first.worker === second.worker)

        let hostID = UUID()
        let sessionID = "same-session"
        let earlierLease = OfflineSessionCacheWriteLease(
            clientID: UUID(),
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        let laterLease = OfflineSessionCacheWriteLease(
            clientID: UUID(),
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        first.updateContext(
            clientID: earlierLease.clientID,
            generation: earlierLease.connectionGeneration,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        second.updateContext(
            clientID: laterLease.clientID,
            generation: laterLease.connectionGeneration,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        let earlier = try XCTUnwrap(first.permit(for: earlierLease, draft: false))
        let later = try XCTUnwrap(second.permit(for: laterLease, draft: false))
        assertCommitted(
            await second.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "newer"),
                permit: later
            )
        )
        assertSuperseded(
            await first.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "older"),
                permit: earlier
            )
        )
        assertCommitted(await first.flush())

        XCTAssertEqual(
            first.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "newer"
        )
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertEqual(document.snapshot.entries.first?.text, "newer")
    }

    @MainActor
    func testMainActorRemainsResponsiveWhileRealWorkerCommitIsBlocked() async throws {
        let fileURL = root.appendingPathComponent("main-actor-probe.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()

        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "probe"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.worker.beforeCommitForTesting = {
            entered.signal()
            release.wait()
        }
        defer {
            store.worker.beforeCommitForTesting = nil
            release.signal()
        }

        let input = makeInput(hostID: hostID, sessionID: sessionID, text: "slow")
        let save = Task.detached {
            await store.saveSession(input, permit: permit)
        }
        let enteredCommit = await Task.detached {
            entered.wait(timeout: .now() + 2) == .success
        }.value
        guard enteredCommit else {
            return XCTFail("worker did not reach its real commit")
        }

        let probe = MainActorProbe()
        Task { @MainActor in
            await probe.mark()
        }
        try await Task.sleep(for: .milliseconds(80))
        let reachedMainActor = await probe.isMarked
        XCTAssertTrue(reachedMainActor)

        store.worker.beforeCommitForTesting = nil
        release.signal()
        assertCommitted(await save.value)
    }

    func testDeleteWriteFailureKeepsDesiredDeletionUntilAnotherWritePersistsIt() async throws {
        let fileURL = root.appendingPathComponent("delete-failure.json")
        let hostID = UUID()
        let deletedSession = "deleted"
        let survivingSession = "surviving"
        try OfflineSessionCacheFile.save(
            .init(snapshot: SessionCacheStore.Snapshot(entries: [
                makeEntry(hostID: hostID, sessionID: deletedSession, text: "must-not-revive"),
                makeEntry(hostID: hostID, sessionID: survivingSession, text: "old"),
            ])),
            to: fileURL
        )

        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        store.updateContext(
            clientID: UUID(),
            generation: 1,
            hostID: hostID,
            sessionID: deletedSession,
            active: true
        )

        let failFirstWrite = FailFirstWriteGate()
        store.worker.beforeWriteForTesting = { try failFirstWrite.invoke() }
        defer { store.worker.beforeWriteForTesting = nil }

        store.removeSessions(hostID: hostID, sessionIDs: [deletedSession])
        assertFailed(await store.flush())
        XCTAssertNotNil(store.status.error)
        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: deletedSession))
        let failedDocument = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertNotNil(
            failedDocument.snapshot.cachedSession(hostID: hostID, sessionID: deletedSession)
        )

        let lease = OfflineSessionCacheWriteLease(
            clientID: UUID(),
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: survivingSession
        )
        store.updateContext(
            clientID: lease.clientID,
            generation: lease.connectionGeneration,
            hostID: hostID,
            sessionID: survivingSession,
            active: true
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: survivingSession, text: "new"),
                permit: permit
            )
        )
        assertCommitted(await store.flush())
        XCTAssertNil(store.status.error)

        let persisted = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL)).snapshot
        XCTAssertNil(persisted.cachedSession(hostID: hostID, sessionID: deletedSession))
        XCTAssertEqual(
            persisted.cachedSession(hostID: hostID, sessionID: survivingSession)?.entries.first?.text,
            "new"
        )
        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: deletedSession))
    }

    func testHydrateIsAFlushBarrierAndAcceptedDeleteIsNeverPublishedAsReady() async throws {
        let fileURL = root.appendingPathComponent("hydrate-delete.json")
        let hostID = UUID()
        let sessionID = "deleted-during-hydrate"
        try OfflineSessionCacheFile.save(
            .init(snapshot: SessionCacheStore.Snapshot(entries: [
                makeEntry(hostID: hostID, sessionID: sessionID, text: "old-mirror"),
            ])),
            to: fileURL
        )

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let store = SessionCacheStore(
            offlineCacheLimit: 200,
            fileURL: fileURL,
            beforeHydratePublish: {
                entered.signal()
                release.wait()
            }
        )
        defer { release.signal() }

        let probe = DeletedReadyMirrorProbe()
        store.observe { status in
            guard status.ready,
                  store.cachedSession(hostID: hostID, sessionID: sessionID) != nil
            else { return }
            probe.recordDeletedEntityPublished()
        }
        guard waitForSignal(entered) else {
            return XCTFail("hydrate did not reach its publish boundary")
        }

        store.updateContext(
            clientID: UUID(),
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )
        store.removeSessions(hostID: hostID, sessionIDs: [sessionID])

        let flushed = CompletionFlag()
        let flush = Task {
            let outcome = await store.flush()
            await flushed.complete()
            return outcome
        }
        try await Task.sleep(for: .milliseconds(80))
        let completedBeforeRelease = await flushed.isComplete
        XCTAssertFalse(completedBeforeRelease)

        release.signal()
        assertCommitted(await flush.value)
        XCTAssertFalse(probe.didPublishDeletedEntity)
        XCTAssertNil(store.cachedSession(hostID: hostID, sessionID: sessionID))
        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertTrue(document.snapshot.entries.isEmpty)
    }

    func testFlushWaitsForInitialHydrateBarrier() async throws {
        let fileURL = root.appendingPathComponent("hydrate-only.json")
        let hostID = UUID()
        let sessionID = "hydrated"
        try OfflineSessionCacheFile.save(
            .init(snapshot: SessionCacheStore.Snapshot(entries: [
                makeEntry(hostID: hostID, sessionID: sessionID, text: "loaded"),
            ])),
            to: fileURL
        )

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let store = SessionCacheStore(
            offlineCacheLimit: 200,
            fileURL: fileURL,
            beforeHydratePublish: {
                entered.signal()
                release.wait()
            }
        )
        defer { release.signal() }
        guard waitForSignal(entered) else {
            return XCTFail("hydrate did not start")
        }

        let flushed = CompletionFlag()
        let flush = Task {
            let outcome = await store.flush()
            await flushed.complete()
            return outcome
        }
        try await Task.sleep(for: .milliseconds(80))
        let completedBeforeRelease = await flushed.isComplete
        XCTAssertFalse(completedBeforeRelease)

        release.signal()
        assertCommitted(await flush.value)
        XCTAssertTrue(store.status.ready)
        XCTAssertEqual(
            store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "loaded"
        )
    }

    @MainActor
    func testCorruptHydratePublishesReadyFailureWithoutHanging() async throws {
        let fileURL = root.appendingPathComponent("corrupt-ready.json")
        let original = Data("{broken".utf8)
        try original.write(to: fileURL)

        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let model = ConnectionModel(cacheStoreOverride: store)
        await model.waitForOfflineCacheReady()

        XCTAssertTrue(model.offlineCacheReady)
        XCTAssertNotNil(model.offlineCacheLoadError)
        assertFailed(await store.flush())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    @MainActor
    func testConnectionFlushSurfacesCacheFailureAndRecoveryClearsIt() async throws {
        let fileURL = root.appendingPathComponent("connection-flush.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let model = ConnectionModel(cacheStoreOverride: store)
        await model.waitForOfflineCacheReady()

        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "connection"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        let failFirstWrite = FailFirstWriteGate()
        store.worker.beforeWriteForTesting = { try failFirstWrite.invoke() }
        defer { store.worker.beforeWriteForTesting = nil }

        let failedPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertFailed(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "fails"),
                permit: failedPermit
            )
        )
        await model.flushPendingCacheWrites()
        XCTAssertNotNil(model.offlineCacheLoadError)

        let recoveredPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "recovers"),
                permit: recoveredPermit
            )
        )
        await model.flushPendingCacheWrites()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(model.offlineCacheLoadError)
    }

    @MainActor
    func testLateFailureStatusCannotOverwriteNewerRecoveredState() async throws {
        let fileURL = root.appendingPathComponent("connection-late-error.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let model = ConnectionModel(cacheStoreOverride: store)
        await model.waitForOfflineCacheReady()

        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "late-error"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        let failFirstWrite = FailFirstWriteGate()
        store.worker.beforeWriteForTesting = { try failFirstWrite.invoke() }
        defer { store.worker.beforeWriteForTesting = nil }

        let failedPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertFailed(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "fails"),
                permit: failedPermit
            )
        )
        let recoveredPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "newer"),
                permit: recoveredPermit
            )
        )

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(model.offlineCacheLoadError)
        XCTAssertNil(store.status.error)
        XCTAssertEqual(
            store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "newer"
        )
        model.applyCacheStatusForTesting(
            .init(ready: true, error: "late failure from an older revision", revision: 0)
        )
        XCTAssertNil(model.offlineCacheLoadError)
    }

    @MainActor
    func testStaleFlushFailureDoesNotOverwriteRealNewerRecovery() async throws {
        let fileURL = root.appendingPathComponent("connection-real-recovery.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let model = ConnectionModel(cacheStoreOverride: store)
        await model.waitForOfflineCacheReady()

        let clientID = UUID()
        let hostID = UUID()
        let sessionID = "real-recovery"
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: 1,
            hostID: hostID,
            sessionID: sessionID
        )
        store.updateContext(
            clientID: clientID,
            generation: 1,
            hostID: hostID,
            sessionID: sessionID,
            active: true
        )

        let failFirstWrite = FailFirstWriteGate()
        store.worker.beforeWriteForTesting = { try failFirstWrite.invoke() }
        defer { store.worker.beforeWriteForTesting = nil }

        let failedPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertFailed(
            await store.saveSession(
                makeInput(hostID: hostID, sessionID: sessionID, text: "fails"),
                permit: failedPermit
            )
        )

        // Interleave through the real save path: after the flush barrier has
        // captured the failure, publish a newer successful revision.
        model.afterCacheFlushBarrierHookForTesting = {
            guard let recovered = store.permit(for: lease, draft: false) else {
                return XCTFail("recovery permit was not admitted")
            }
            self.assertCommitted(
                await store.saveSession(
                    self.makeInput(hostID: hostID, sessionID: sessionID, text: "newer"),
                    permit: recovered
                )
            )
        }
        defer { model.afterCacheFlushBarrierHookForTesting = nil }

        await model.flushPendingCacheWrites()
        XCTAssertNil(model.offlineCacheLoadError)
        XCTAssertNil(store.status.error)
        XCTAssertEqual(
            store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text,
            "newer"
        )
    }

    /// C1: the cache and draft share one serial disk adapter, so their two
    /// two-second stalls run in sequence; StateFile stalls concurrently on its
    /// own real adapter. All three are outstanding while MainActor probes run.
    @MainActor
    func testCacheDraftAndStateTwoSecondStallsKeepMainActorProgressing() async throws {
        let cacheURL = root.appendingPathComponent("three-way.sqlite")
        let stateURL = root.appendingPathComponent("three-way-state.json")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: cacheURL)
        let connection = ConnectionModel(cacheStoreOverride: store)
        let app = AppModel(seed: .empty, stateFileURL: stateURL, connectionOverride: connection)
        await connection.waitForOfflineCacheReady()
        let hostID = UUID()
        let sessionID = "three-way"
        let client = RACPClient(configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil), confirmer: CacheRejectHost())
        connection.installConnectionPiecesForTesting(oldClient: client, candidate: nil, hostID: hostID)
        let lease = try XCTUnwrap(connection.cacheLeaseForTesting(sessionID: sessionID))
        store.updateContext(clientID: lease.clientID, generation: lease.connectionGeneration,
                            hostID: hostID, sessionID: sessionID, active: true)
        let evidence = BlockingIOEvidence()
        let firstCacheEntered = expectation(description: "real cache adapter entered")
        store.worker.beforeWriteForTesting = {
            let ordinal = evidence.begin("cache-adapter")
            let label = ordinal == 1 ? "cache" : "draft"
            evidence.beginTimed(label)
            if ordinal == 1 { firstCacheEntered.fulfill() }
            Thread.sleep(forTimeInterval: 2)
            evidence.endTimed(label)
            evidence.end("cache-adapter")
        }
        let stateFirst = FirstCommitGate()
        StateFile.setBeforeWriteHookForTesting { url in
            guard url == stateURL, stateFirst.take() else { return }
            evidence.beginTimed("state")
            Thread.sleep(forTimeInterval: 2)
            evidence.endTimed("state")
        }
        defer {
            store.worker.beforeWriteForTesting = nil
            StateFile.setBeforeWriteHookForTesting(nil)
        }
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
        let input = makeInput(hostID: hostID, sessionID: sessionID, text: "cached")
        let cache = Task.detached { await store.saveSession(input, permit: permit) }
        await fulfillment(of: [firstCacheEntered], timeout: 3)
        // This invokes the production ConnectionModel draft debounce/flush path.
        connection.session.onDraftChanged?(sessionID, "latest-draft", "draft-key")
        let draft = Task { await connection.flushPendingCacheWrites() }
        app.rememberReadingPosition(hostID: hostID, sessionID: sessionID,
                                    lastVisibleItemID: "cached-item", isNearBottom: false)
        let state = Task { await app.flushPersistentState() }
        var ticksWhileBlocked = 0
        for _ in 0..<32 {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(Thread.isMainThread)
            if evidence.hasTimedWork { ticksWhileBlocked += 1 }
        }
        assertCommitted(await cache.value)
        await draft.value
        let stateSaved = await state.value
        XCTAssertTrue(stateSaved)
        XCTAssertGreaterThan(ticksWhileBlocked, 20)
        for label in ["cache", "draft", "state"] {
            XCTAssertGreaterThanOrEqual(evidence.duration(label), 2, label)
        }
        XCTAssertFalse(evidence.sawMainThreadIO)
        XCTAssertEqual(evidence.maximum("cache-adapter"), 1)
        XCTAssertEqual(store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.first?.text, "cached")
        XCTAssertEqual(store.cachedSession(hostID: hostID, sessionID: sessionID)?.draft?.text, "latest-draft")
        XCTAssertEqual(StateFile.load(from: stateURL).state.readingPositionsByHost[hostID.uuidString]?[sessionID]?.lastVisibleItemID,
                       "cached-item")
        await client.stop()
    }

    func testHundredCacheRevisionsConvergeAfterFirstReadIsBlocked() async throws {
        let fileURL = root.appendingPathComponent("hundred-cache.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: UUID(), sessionID: "hundred")
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: lease.hostID,
                            sessionID: lease.sessionID, active: true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = FirstCommitGate()
        let probe = CommitProbe()
        store.worker.stageHookForTesting = { stage in
            switch stage {
            case .afterRead:
                probe.enter()
                if first.take() { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            case .finished: probe.leave()
            default: break
            }
        }
        defer { store.worker.stageHookForTesting = nil; release.signal() }
        let firstPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        let firstInput = makeInput(hostID: lease.hostID, sessionID: lease.sessionID, text: "cache-0", revision: 0)
        var saves = [Task.detached { await store.saveSession(firstInput, permit: firstPermit) }]
        let reached = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        guard reached else { return XCTFail("initial cache read did not reach its gate") }
        for revision in 1..<100 {
            let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
            let input = makeInput(hostID: lease.hostID, sessionID: lease.sessionID,
                                  text: "cache-\(revision)", revision: revision)
            saves.append(Task.detached { await store.saveSession(input, permit: permit) })
        }
        release.signal()
        for save in saves { _ = await save.value }
        assertCommitted(await store.flush())
        XCTAssertEqual(probe.maximumConcurrent, 1)
        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(disk.entries.first?.text, "cache-99")
        XCTAssertEqual(disk.entries.first?.sequence, 99)
        XCTAssertEqual(disk.cursors.first?.sequence, 99)
        // 全量快照相等会因 updatedAt 的亚秒精度在“内存原值 vs 落盘再读”之间不同
        // 而误报；这里比较往返后必须保持的业务字段。
        let mirrored = store.loadSnapshot()
        XCTAssertEqual(mirrored.entries.map(\.text), disk.entries.map(\.text))
        XCTAssertEqual(mirrored.entries.map(\.sequence), disk.entries.map(\.sequence))
        XCTAssertEqual(mirrored.entries.map(\.id), disk.entries.map(\.id))
        XCTAssertEqual(mirrored.cursors.map(\.sequence), disk.cursors.map(\.sequence))
        XCTAssertEqual(mirrored.entries.count, disk.entries.count)
    }

    /// C3 is deliberately one facade/store switching its context, rather than
    /// two concurrently active facades that merely happen to use different hosts.
    func testSingleStoreLifecycleMatrixAtReadCommitAndPublishBoundaries() async throws {
        for action in CacheLifecycleChange.allCases {
            for stage in [SessionCacheWorker.TestStage.afterRead, .beforeWrite, .beforePublish] {
                try await runLifecycleCase(action, stage: stage)
            }
        }
    }

    private func runLifecycleCase(_ action: CacheLifecycleChange, stage: SessionCacheWorker.TestStage) async throws {
        let fileURL = root.appendingPathComponent("matrix-\(action)-\(stage).sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let hostA = UUID()
        let hostB = UUID()
        let sessionID = "same-session"
        let original = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                     hostID: hostA, sessionID: sessionID)
        store.updateContext(clientID: original.clientID, generation: 1, hostID: hostA,
                            sessionID: sessionID, active: true)
        let seed = try XCTUnwrap(store.permit(for: original, draft: false))
        assertCommitted(await store.saveSession(makeInput(hostID: hostA, sessionID: sessionID, text: "baseline"), permit: seed))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = FirstCommitGate()
        store.worker.stageHookForTesting = { reached in
            if reached == stage, first.take() { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        defer { store.worker.stageHookForTesting = nil; release.signal(); store.observe { _ in } }
        let oldPermit = try XCTUnwrap(store.permit(for: original, draft: false))
        let oldInput = makeInput(hostID: hostA, sessionID: sessionID, text: "obsolete")
        let old = Task.detached { await store.saveSession(oldInput, permit: oldPermit) }
        let reached = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        guard reached else { return XCTFail("\(action)/\(stage) did not reach the gate") }
        let targetHost: UUID
        let targetSession: String
        let nextClient: UUID
        switch action {
        case .hostSwitch:
            targetHost = hostB; targetSession = sessionID; nextClient = UUID()
        case .sessionDelete:
            store.removeSessions(hostID: hostA, sessionIDs: [sessionID])
            targetHost = hostA; targetSession = "survivor"; nextClient = original.clientID
        case .leaseRebuild:
            store.updateContext(clientID: original.clientID, generation: 1, hostID: hostA,
                                sessionID: sessionID, active: false)
            targetHost = hostA; targetSession = sessionID; nextClient = UUID()
        }
        let next = OfflineSessionCacheWriteLease(clientID: nextClient, connectionGeneration: 2,
                                                 hostID: targetHost, sessionID: targetSession)
        store.updateContext(clientID: next.clientID, generation: 2, hostID: targetHost,
                            sessionID: targetSession, active: true)
        let publication = DeletedReadyMirrorProbe()
        store.observe { status in
            if status.ready, store.cachedSession(hostID: targetHost, sessionID: targetSession)?.entries.first?.text == "obsolete" {
                publication.recordDeletedEntityPublished()
            }
        }
        let freshPermit = try XCTUnwrap(store.permit(for: next, draft: false))
        let freshInput = makeInput(hostID: targetHost, sessionID: targetSession, text: "fresh", revision: 2)
        let fresh = Task.detached { await store.saveSession(freshInput, permit: freshPermit) }
        release.signal()
        assertSuperseded(await old.value)
        assertCommitted(await fresh.value)
        assertCommitted(await store.flush())
        XCTAssertFalse(publication.didPublishDeletedEntity, "\(action)/\(stage)")
        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(disk.cachedSession(hostID: targetHost, sessionID: targetSession)?.entries.first?.text, "fresh")
        XCTAssertEqual(store.cachedSession(hostID: targetHost, sessionID: targetSession)?.entries.first?.text, "fresh")
        switch action {
        case .hostSwitch:
            // At beforePublish the old A write already committed before the
            // switch. It may remain as A's history; it must never become B's.
            XCTAssertEqual(disk.cachedSession(hostID: hostA, sessionID: sessionID)?.entries.first?.text,
                           stage == .beforePublish ? "obsolete" : "baseline")
        case .sessionDelete:
            XCTAssertNil(disk.cachedSession(hostID: hostA, sessionID: sessionID))
            XCTAssertNil(store.cachedSession(hostID: hostA, sessionID: sessionID))
            XCTAssertNil(store.permit(for: original, draft: true))
        case .leaseRebuild:
            XCTAssertNil(store.permit(for: original, draft: false))
            XCTAssertEqual(disk.entries.filter { $0.sessionId == sessionID }.count, 1)
        }
    }

    @MainActor
    func testNormalDisconnectFlushesOutgoingDraftBeforeRevokingLease() async throws {
        let fileURL = root.appendingPathComponent("outgoing.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let connection = ConnectionModel(cacheStoreOverride: store)
        await connection.waitForOfflineCacheReady()
        let client = RACPClient(configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil), confirmer: CacheRejectHost())
        let hostID = UUID()
        connection.installConnectionPiecesForTesting(oldClient: client, candidate: nil, hostID: hostID)
        connection.session.onDraftChanged?("outgoing", "last-valid-draft", "outgoing-key")
        await connection.disconnect()
        XCTAssertNil(connection.activeClient)
        XCTAssertFalse(connection.state.isOnline)
        XCTAssertNil(connection.cacheLeaseForTesting(sessionID: "outgoing"))
        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(disk.cachedSession(hostID: hostID, sessionID: "outgoing")?.draft?.text, "last-valid-draft")
    }

    @MainActor
    func testOlderSuccessfulCacheFlushCannotClearNewerRealFailure() async throws {
        let fileURL = root.appendingPathComponent("late-success.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        let connection = ConnectionModel(cacheStoreOverride: store)
        await connection.waitForOfflineCacheReady()
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: UUID(), sessionID: "late-success")
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: lease.hostID,
                            sessionID: lease.sessionID, active: true)
        let initial = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(makeInput(hostID: lease.hostID, sessionID: lease.sessionID, text: "known-good"), permit: initial))
        let oldSuccess = store.status
        connection.afterCacheFlushBarrierHookForTesting = {
            store.worker.beforeWriteForTesting = { throw FailFirstWriteGate.InjectedFailure() }
            guard let permit = store.permit(for: lease, draft: false) else { return XCTFail("failure write was not admitted") }
            self.assertFailed(await store.saveSession(self.makeInput(hostID: lease.hostID, sessionID: lease.sessionID, text: "new-failed-state"), permit: permit))
        }
        defer {
            connection.afterCacheFlushBarrierHookForTesting = nil
            store.worker.beforeWriteForTesting = nil
        }
        await connection.flushPendingCacheWrites()
        XCTAssertNotNil(connection.offlineCacheLoadError)
        connection.applyCacheStatusForTesting(oldSuccess)
        XCTAssertNotNil(connection.offlineCacheLoadError)
        XCTAssertEqual(try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot().entries.first?.text, "known-good")
    }

    func testOrderedProjectionWithoutDatesKeepsTurnAndOrderAfterSQLiteReopen() async throws {
        let fileURL = root.appendingPathComponent("ordered-no-dates.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let hostID = UUID()
        let sessionID = "ordered-no-dates"
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: sessionID)
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: sessionID, active: true)
        let specifications = [
            (id: "user", role: "user", itemType: "message", text: "task"),
            (id: "tool", role: "toolResult", itemType: "tool", text: "tool output"),
            (id: "assistant", role: "assistant", itemType: "message", text: "reply"),
        ]
        let items = specifications.enumerated().map { index, specification in
            RACPItem(id: specification.id, payload: .object([
                "id": .string(specification.id),
                "role": .string(specification.role),
                "itemType": .string(specification.itemType),
                "text": .string(specification.text),
                "sequence": .number(Double(index + 1)),
            ]))
        }
        let view = RACPSessionView(
            sessionId: sessionID,
            summary: nil,
            items: items,
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            pendingInputs: [],
            expiredApprovalIds: [],
            cursor: RACPCursor(epoch: "epoch", sequence: 3),
            revision: 3,
            replayComplete: true,
            hasMoreHistory: false,
            runningTurnId: nil
        )
        let input = SessionCacheStore.SessionInput(
            view: view, summary: nil, mode: "agent", permission: "ask",
            modelID: nil, providerID: nil, hostID: hostID, sessionID: sessionID
        )
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(input, permit: permit))
        assertCommitted(await store.flush())

        // Open a new SQLite adapter and read the persisted rows, not the warm mirror.
        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        let cached = try XCTUnwrap(disk.cachedSession(hostID: hostID, sessionID: sessionID))
        let chronological = cached.entries.reversed()
        XCTAssertEqual(chronological.map(\.id), ["user", "tool", "assistant"])
        XCTAssertEqual(Set(chronological.map(\.turnId)), ["user:user"])
        let dates = chronological.map(\.createdAt)
        for (previous, current) in zip(dates, dates.dropFirst()) {
            XCTAssertLessThan(previous, current, "同批无时间项必须保持严格单调时间顺序")
        }
    }

    func testPrependingWithoutDatesKeepsCurrentTurnAndDatesAtLimitOne() async throws {
        let fileURL = root.appendingPathComponent("prepend-date-anchors.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 1, fileURL: fileURL)
        await store.waitUntilReady()
        let hostID = UUID()
        let sessionID = "prepend-date-anchors"
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: sessionID)
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: sessionID, active: true)
        let current = [
            makeCacheItem(id: "current-user", role: "user", sequence: 3),
            makeCacheItem(id: "current-tool", role: "toolResult", sequence: 4),
            makeCacheItem(id: "current-assistant", role: "assistant", sequence: 5),
        ]
        let initialPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(
            makeInput(hostID: hostID, sessionID: sessionID, items: current, hasMoreHistory: false),
            permit: initialPermit
        ))
        let initialDisk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        let initialDates = Dictionary(uniqueKeysWithValues: initialDisk.entries.map { ($0.id, $0.createdAt) })
        XCTAssertEqual(initialDates.count, 3)

        let earlier = [
            makeCacheItem(id: "earlier-user", role: "user", sequence: 1),
            makeCacheItem(id: "earlier-assistant", role: "assistant", sequence: 2),
        ]
        let prependedPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(
            makeInput(hostID: hostID, sessionID: sessionID, items: earlier + current, hasMoreHistory: true),
            permit: prependedPermit
        ))

        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(Set(disk.entries.map(\.id)), Set(initialDates.keys),
                       "前插旧轮次必须早于当前锚点，limit=1 不能误删当前轮")
        for entry in disk.entries {
            XCTAssertEqual(entry.createdAt, initialDates[entry.id], "已有 current 项日期不得因前插而移动")
        }
    }

    func testCompleteSnapshotSecondSavePreservesFallbackDates() async throws {
        let fileURL = root.appendingPathComponent("repeat-date-anchors.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let hostID = UUID()
        let sessionID = "repeat-date-anchors"
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: sessionID)
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: sessionID, active: true)
        let items = [
            makeCacheItem(id: "user", role: "user", sequence: 1),
            makeCacheItem(id: "tool", role: "toolResult", sequence: 2),
            makeCacheItem(id: "assistant", role: "assistant", sequence: 3),
        ]
        let input = makeInput(hostID: hostID, sessionID: sessionID, items: items, hasMoreHistory: false)
        let firstPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(input, permit: firstPermit))
        let first = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        let firstDates = Dictionary(uniqueKeysWithValues: first.entries.map { ($0.id, $0.createdAt) })

        let secondPermit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(input, permit: secondPermit))
        let second = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        XCTAssertEqual(second.entries.count, 3)
        for entry in second.entries {
            XCTAssertEqual(entry.createdAt, firstDates[entry.id],
                           "hasMore=false 只禁止合并旧 entries，不得丢弃 existingDates")
        }
        let chronological = second.entries.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        XCTAssertEqual(chronological, ["user", "tool", "assistant"])
    }

    func testFallbackDatesInterpolateAroundOriginalAnchorsForOfflineOrder() async throws {
        let fileURL = root.appendingPathComponent("interpolated-date-anchors.sqlite")
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let hostID = UUID()
        let sessionID = "interpolated-date-anchors"
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: sessionID)
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: sessionID, active: true)
        let firstAnchor = Date(timeIntervalSince1970: 1_700_000_000)
        let secondAnchor = firstAnchor.addingTimeInterval(0.000_003)
        let items = [
            makeCacheItem(id: "before", role: "user", sequence: 1),
            makeCacheItem(id: "first-anchor", role: "user", createdAt: firstAnchor, sequence: 2),
            makeCacheItem(id: "between-1", role: "toolResult", sequence: 3),
            makeCacheItem(id: "between-2", role: "assistant", sequence: 4),
            makeCacheItem(id: "second-anchor", role: "user", createdAt: secondAnchor, sequence: 5),
            makeCacheItem(id: "after", role: "assistant", sequence: 6),
        ]
        let permit = try XCTUnwrap(store.permit(for: lease, draft: false))
        assertCommitted(await store.saveSession(
            makeInput(hostID: hostID, sessionID: sessionID, items: items, hasMoreHistory: false),
            permit: permit
        ))

        let disk = try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot()
        let cached = try XCTUnwrap(disk.cachedSession(hostID: hostID, sessionID: sessionID))
        let chronological = cached.entries.reversed()
        XCTAssertEqual(chronological.map(\.id), items.map(\.id), "离线重开必须恢复 view.items 旧→新顺序")
        let dates = Dictionary(uniqueKeysWithValues: chronological.map { ($0.id, $0.createdAt) })
        let accuracy = 0.000_000_1
        XCTAssertEqual(dates["before"]?.timeIntervalSince1970 ?? 0,
                       firstAnchor.addingTimeInterval(-0.000_001).timeIntervalSince1970, accuracy: accuracy)
        XCTAssertEqual(dates["first-anchor"]?.timeIntervalSince1970 ?? 0,
                       firstAnchor.timeIntervalSince1970, accuracy: accuracy)
        XCTAssertEqual(dates["between-1"]?.timeIntervalSince1970 ?? 0,
                       firstAnchor.addingTimeInterval(0.000_001).timeIntervalSince1970, accuracy: accuracy)
        XCTAssertEqual(dates["between-2"]?.timeIntervalSince1970 ?? 0,
                       firstAnchor.addingTimeInterval(0.000_002).timeIntervalSince1970, accuracy: accuracy)
        XCTAssertEqual(dates["second-anchor"]?.timeIntervalSince1970 ?? 0,
                       secondAnchor.timeIntervalSince1970, accuracy: accuracy)
        XCTAssertEqual(dates["after"]?.timeIntervalSince1970 ?? 0,
                       secondAnchor.addingTimeInterval(0.000_001).timeIntervalSince1970, accuracy: accuracy)
    }

    func testShrinkLimitPrunesWholeTurnsAndKeepsOtherSessionTables() async throws {
        let hostID = UUID()
        let sessionID = "turn-shrink"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<3).flatMap { turn -> [SessionCacheStore.Entry] in
            let roles = ["user", "assistant"]
            return roles.enumerated().map { pair in
                let role = pair.element
                let offset = pair.offset
                return SessionCacheStore.Entry(
                    id: "turn-\(turn)-\(role)", sessionId: sessionID, hostID: hostID,
                    text: "\(turn)-\(role)", createdAt: base.addingTimeInterval(Double(turn * 10 + offset)),
                    kind: "message", role: role, status: turn == 2 ? "streaming" : "completed",
                    epoch: "epoch", sequence: turn * 10 + offset, turnId: "turn:\(turn)"
                )
            }
        }
        let snapshot = SessionCacheStore.Snapshot(
            entries: entries,
            cursors: [.init(hostID: hostID, sessionId: sessionID, epoch: "epoch", sequence: 22, updatedAt: base)],
            approvals: [.init(id: "approval", sessionId: sessionID, hostID: hostID,
                              payload: .object(["id": .string("approval")]), revision: 1,
                              status: "pending", decision: nil, createdAt: base)],
            drafts: [.init(hostID: hostID, sessionId: sessionID, text: "draft",
                           idempotencyKey: "draft-key", updatedAt: base)]
        )
        let store = SessionCacheStore(offlineCacheLimit: 2, inMemory: snapshot)
        XCTAssertEqual(store.cachedSession(hostID: hostID, sessionID: sessionID)?.entries.count, 4)

        store.withOfflineCacheLimit(1)
        assertCommitted(await store.flush())

        let cached = try XCTUnwrap(store.cachedSession(hostID: hostID, sessionID: sessionID))
        XCTAssertEqual(Set(cached.entries.map(\.id)), ["turn-2-user", "turn-2-assistant"])
        XCTAssertEqual(cached.cursor?.sequence, 22)
        XCTAssertEqual(cached.approvals.map(\.id), ["approval"])
        XCTAssertEqual(cached.draft?.text, "draft")
        XCTAssertEqual(store.turnLimit, 1)
        XCTAssertEqual(store.itemLimit, store.turnLimit)
    }

    func testSuccessfulCommitWritesBackLegacyTurnProjection() async throws {
        let fileURL = root.appendingPathComponent("legacy-projection.json")
        let hostID = UUID()
        let sessionID = "legacy-projection"
        try OfflineSessionCacheFile.save(
            .init(snapshot: .init(entries: [makeEntry(hostID: hostID, sessionID: sessionID, text: "legacy")])),
            to: fileURL
        )
        let store = SessionCacheStore(offlineCacheLimit: 200, fileURL: fileURL)
        await store.waitUntilReady()
        let lease = OfflineSessionCacheWriteLease(clientID: UUID(), connectionGeneration: 1,
                                                  hostID: hostID, sessionID: sessionID)
        store.updateContext(clientID: lease.clientID, generation: 1, hostID: hostID,
                            sessionID: sessionID, active: true)
        let permit = try XCTUnwrap(store.permit(for: lease, draft: true))
        store.saveDraft(sessionID: sessionID, hostID: hostID, text: "draft",
                        idempotencyKey: "key", permit: permit)
        assertCommitted(await store.flush())

        let document = try XCTUnwrap(OfflineSessionCacheFile.load(from: fileURL))
        XCTAssertEqual(document.version, 3)
        XCTAssertEqual(document.entries.first?.turnId, "legacy:item-\(sessionID)")
    }

    private func makeCacheItem(
        id: String,
        role: String,
        createdAt: Date? = nil,
        sequence: Int
    ) -> RACPItem {
        var payload: [String: JSONValue] = [
            "id": .string(id),
            "role": .string(role),
            "itemType": .string(role == "toolResult" ? "tool" : "message"),
            "text": .string(id),
            "sequence": .number(Double(sequence)),
        ]
        if let createdAt { payload["createdAt"] = .number(createdAt.timeIntervalSince1970) }
        return RACPItem(id: id, payload: .object(payload))
    }

    private func makeInput(
        hostID: UUID,
        sessionID: String,
        items: [RACPItem],
        hasMoreHistory: Bool
    ) -> SessionCacheStore.SessionInput {
        let view = RACPSessionView(
            sessionId: sessionID,
            summary: nil,
            items: items,
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            pendingInputs: [],
            expiredApprovalIds: [],
            cursor: RACPCursor(epoch: "epoch", sequence: items.count),
            revision: items.count,
            replayComplete: true,
            hasMoreHistory: hasMoreHistory,
            runningTurnId: nil
        )
        return SessionCacheStore.SessionInput(
            view: view, summary: nil, mode: "agent", permission: "ask",
            modelID: nil, providerID: nil, hostID: hostID, sessionID: sessionID
        )
    }

    private func makeInput(
        hostID: UUID,
        sessionID: String,
        text: String,
        revision: Int = 1
    ) -> SessionCacheStore.SessionInput {
        let itemID = "item-\(sessionID)"
        let payload: JSONValue = .object([
            "id": .string(itemID),
            "text": .string(text),
            "createdAt": .number(1_700_000_000),
            "sequence": .number(Double(revision)),
        ])
        let view = RACPSessionView(
            sessionId: sessionID,
            summary: nil,
            items: [RACPItem(id: itemID, payload: payload)],
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            pendingInputs: [],
            expiredApprovalIds: [],
            cursor: RACPCursor(epoch: "epoch", sequence: revision),
            revision: revision,
            replayComplete: true,
            hasMoreHistory: false,
            runningTurnId: nil
        )
        return SessionCacheStore.SessionInput(
            view: view,
            summary: nil,
            mode: "agent",
            permission: "ask",
            modelID: nil,
            providerID: nil,
            hostID: hostID,
            sessionID: sessionID
        )
    }

    private func makeEntry(hostID: UUID, sessionID: String, text: String) -> SessionCacheStore.Entry {
        SessionCacheStore.Entry(
            id: "item-\(sessionID)",
            sessionId: sessionID,
            hostID: hostID,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "message",
            role: "assistant",
            toolName: nil,
            status: nil,
            epoch: "epoch",
            sequence: 1
        )
    }

    /// `DispatchSemaphore.wait` is unavailable directly from async contexts.
    private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double = 2) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    private func assertCommitted(
        _ outcome: SessionCacheStore.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .committed:
            break
        case .superseded:
            XCTFail("expected committed, got superseded", file: file, line: line)
        case .failed(let error):
            XCTFail("expected committed, got \(error)", file: file, line: line)
        }
    }

    private func assertSuperseded(
        _ outcome: SessionCacheStore.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .superseded:
            break
        case .committed:
            XCTFail("expected superseded, got committed", file: file, line: line)
        case .failed(let error):
            XCTFail("expected superseded, got \(error)", file: file, line: line)
        }
    }

    private func assertFailed(
        _ outcome: SessionCacheStore.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case .failed(_):
            break
        case .committed, .superseded:
            XCTFail("expected failed", file: file, line: line)
        }
    }
}

private enum CacheLifecycleChange: CaseIterable { case hostSwitch, sessionDelete, leaseRebuild }

private struct CacheRejectHost: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation { .reject }
}

private final class BlockingIOEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var active: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private var starts: [String: TimeInterval] = [:]
    private var durations: [String: TimeInterval] = [:]
    private var mainThread = false

    func begin(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[name, default: 0] += 1
        active[name, default: 0] += 1
        peak[name] = max(peak[name] ?? 0, active[name] ?? 0)
        return counts[name] ?? 0
    }
    func end(_ name: String) { lock.lock(); active[name, default: 0] -= 1; lock.unlock() }
    func beginTimed(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        mainThread = mainThread || Thread.isMainThread
        starts[name] = ProcessInfo.processInfo.systemUptime
    }
    func endTimed(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        durations[name] = ProcessInfo.processInfo.systemUptime - (starts.removeValue(forKey: name) ?? 0)
    }
    var hasTimedWork: Bool { lock.lock(); defer { lock.unlock() }; return !starts.isEmpty }
    var sawMainThreadIO: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func duration(_ name: String) -> TimeInterval { lock.lock(); defer { lock.unlock() }; return durations[name] ?? 0 }
    func maximum(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return peak[name] ?? 0 }
}

private final class CommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    func enter() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var maximumConcurrent: Int {
        lock.lock(); defer { lock.unlock() }
        return maximum
    }
}

private final class FirstCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}

private actor CompletionFlag {
    private var completed = false

    func complete() {
        completed = true
    }

    var isComplete: Bool { completed }
}

private actor MainActorProbe {
    private var marked = false

    func mark() {
        marked = true
    }

    var isMarked: Bool { marked }
}

private final class FailFirstWriteGate: @unchecked Sendable {
    struct InjectedFailure: LocalizedError {
        var errorDescription: String? { "injected cache write failure" }
    }

    private let lock = NSLock()
    private var failed = false

    func invoke() throws {
        lock.lock()
        let shouldFail = !failed
        failed = true
        lock.unlock()
        if shouldFail {
            throw InjectedFailure()
        }
    }
}

private final class DeletedReadyMirrorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var published = false

    func recordDeletedEntityPublished() {
        lock.lock(); published = true; lock.unlock()
    }

    var didPublishDeletedEntity: Bool {
        lock.lock(); defer { lock.unlock() }
        return published
    }
}
