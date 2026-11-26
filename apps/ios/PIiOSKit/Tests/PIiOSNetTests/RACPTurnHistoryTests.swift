import Foundation
import PIiOSCore
import XCTest
@testable import PIiOSNet

final class RACPTurnHistoryTests: XCTestCase {
    func testAttachStagesMultiplePagesAndSuppressesReplayUntilOneFinalPublication() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("a3", role: "assistant", turnID: "turn-1")], hasMore: true)
        socket.queueHistory(before: "a3", [
            HistoryReply(items: [item("a2", role: "assistant", turnID: "turn-1")], hasMore: true),
        ])
        socket.queueHistory(before: "a2", [
            HistoryReply(items: [
                item("u1", role: "user", turnID: "turn-1"),
                item("a1", role: "assistant", turnID: "turn-1"),
            ], hasMore: false),
        ])
        let historyStarted = XCTestExpectation(description: "initial backfill is waiting")
        socket.pauseHistory(at: 1)
        socket.onHistoryRequest = { call in if call == 1 { historyStarted.fulfill() } }
        socket.onSubscribe = { call, session in
            guard call == 1 else { return }
            socket.enqueue(Self.event(session: session, sequence: 1, itemID: "live"))
        }

        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let attach = Task { try await client.attach(sessionId: "session") }

        await fulfillment(of: [historyStarted], timeout: 2)
        XCTAssertEqual(recorder.sessionChangedCount, 0, "subscribe/replay and the first staged page must not publish")
        socket.releaseHistory(at: 1)
        let included = try await attach.value
        XCTAssertEqual(included, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["u1", "a1", "a2", "a3", "live"])
        XCTAssertEqual(socket.historyRequests.map(\.beforeItemID), ["a3", "a2"])
        XCTAssertFalse(view.hasMoreHistory)
        XCTAssertEqual(recorder.sessionChangedCount, 1)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testAttachHidesIncompleteLeadingTurnWithoutPagingHistory() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [
            item("old-a", role: "assistant"),
            item("old-tool", role: "tool"),
            item("u1", role: "user"),
            item("a1", role: "assistant"),
        ], hasMore: true)
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)

        let included = try await client.attach(sessionId: "session")
        XCTAssertEqual(included, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["u1", "a1"])
        XCTAssertTrue(view.hasMoreHistory)
        XCTAssertTrue(
            socket.historyRequests.isEmpty,
            "attach must not page through the whole session to complete an older turn"
        )
        XCTAssertTrue(ConversationTurnPolicy.hasTaskBoundary(view.items))

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testAttachStopsAtFirstUserInsteadOfWalkingWholeLegacyHistory() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [
            item("a-100", role: "assistant"),
            item("t-99", role: "tool"),
        ], hasMore: true)
        socket.queueHistory(before: "a-100", [
            HistoryReply(items: [
                item("a-98", role: "assistant"),
                item("t-97", role: "tool"),
            ], hasMore: true),
        ])
        socket.queueHistory(before: "a-98", [
            HistoryReply(items: [
                item("a-96", role: "assistant"),
                item("u-last", role: "user"),
                item("a-95", role: "assistant"),
            ], hasMore: true),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)

        let included = try await client.attach(sessionId: "session")
        XCTAssertEqual(included, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        let view = await client.sessionView()
        XCTAssertEqual(
            socket.historyRequests.map(\.beforeItemID),
            ["a-100", "a-98"],
            "must stop after the first user anchor instead of walking legacy history to the session start"
        )
        XCTAssertEqual(view.items.first?.id, "u-last")
        XCTAssertEqual(view.items.map(\.id), ["u-last", "a-95", "a-98", "t-97", "a-100", "t-99"])
        XCTAssertTrue(view.hasMoreHistory)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testCoalescingSkipsOldQueuedSignalAndNeverReadsCandidateHalfTurn() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("a2", role: "assistant", turnID: "turn-1")], hasMore: true)
        socket.queueHistory(before: "a2", [
            HistoryReply(items: [item("u1", role: "user", turnID: "turn-1")], hasMore: false),
        ])
        let historyStarted = XCTestExpectation(description: "candidate is staged")
        socket.pauseHistory(at: 1)
        socket.onHistoryRequest = { call in if call == 1 { historyStarted.fulfill() } }

        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        await client.enableSessionChangeCoalescing()
        let stream = await client.stream()
        await client.emitUpdateForTesting(.sessionChanged) // old attachment's queued receipt
        let attach = Task { try await client.attach(sessionId: "session") }
        await fulfillment(of: [historyStarted], timeout: 2)

        let visible = VisibleTurnRecorder()
        let collector = Task {
            for await update in stream {
                guard case .sessionChanged = update else { continue }
                guard let receipt = await client.beginSessionChangeConsumption() else {
                    visible.recordSkippedQueuedSignal()
                    continue
                }
                let view = await client.sessionView()
                visible.record(view.items.map(\.id))
                await client.finishSessionChangeConsumption(receipt)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(visible.skippedQueuedSignals, 1, "the old key must be revoked, not consumed as candidate data")
        XCTAssertEqual(visible.snapshots, [])

        socket.releaseHistory(at: 1)
        let included = try await attach.value
        XCTAssertEqual(included, true)
        await waitUntil { visible.snapshots.count == 1 }
        XCTAssertEqual(visible.snapshots, [["u1", "a2"]])

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testBackfillFailureInvalidatesCandidateBlocksLateFramesAndAllowsFreshAttach() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("partial", role: "assistant", turnID: "turn-1")], hasMore: true)
        socket.queueAttach("session", items: [item("fresh-user", role: "user")], hasMore: false)
        socket.queueHistory(before: "partial", [
            HistoryReply(items: [], hasMore: true, errorCode: "SERVER_INTERNAL"),
        ])
        socket.onSubscribe = { call, session in
            guard call == 1 else { return }
            socket.enqueue(Self.event(session: session, sequence: 1, itemID: "replay-half"))
        }
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)

        do {
            _ = try await client.attach(sessionId: "session")
            XCTFail("initial backfill failure must escape attach")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        var view = await client.sessionView()
        XCTAssertNil(view.sessionId)
        XCTAssertNil(view.summary)
        XCTAssertNil(view.cursor)
        XCTAssertEqual(view.items, [])
        XCTAssertFalse(view.hasMoreHistory)

        socket.enqueue(Self.event(session: "session", sequence: 2, itemID: "late-live"))
        try await Task.sleep(for: .milliseconds(50))
        view = await client.sessionView()
        XCTAssertEqual(view.items, [])
        XCTAssertEqual(recorder.sessionChangedCount, 0)

        let freshIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(freshIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["fresh-user"])
        XCTAssertEqual(view.sessionId, "session")
        XCTAssertEqual(recorder.sessionChangedCount, 1)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testOldSubscribeFailureCannotClearNewCandidatePublicationSuspension() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("old", items: [item("old-user", role: "user")], hasMore: false)
        socket.queueAttach("new", items: [item("new-a", role: "assistant", turnID: "new-turn")], hasMore: true)
        socket.queueHistory(before: "new-a", [
            HistoryReply(items: [item("new-u", role: "user", turnID: "new-turn")], hasMore: false),
        ])
        let oldSubscribe = XCTestExpectation(description: "old subscribe is pending")
        socket.pauseSubscribe(session: "old")
        socket.onSubscribeRequest = { session in if session == "old" { oldSubscribe.fulfill() } }
        let newBackfill = XCTestExpectation(description: "new candidate is backfilling")
        socket.pauseHistory(at: 1)
        socket.onHistoryRequest = { call in if call == 1 { newBackfill.fulfill() } }

        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let oldAttach = Task { try await client.attach(sessionId: "old") }
        await fulfillment(of: [oldSubscribe], timeout: 2)
        let newAttach = Task { try await client.attach(sessionId: "new") }
        await fulfillment(of: [newBackfill], timeout: 2)

        socket.releaseSubscribe(session: "old", errorCode: "SERVER_INTERNAL")
        let oldIncluded = try await oldAttach.value
        XCTAssertNil(oldIncluded, "the superseded attach must not invalidate its replacement")
        socket.enqueue(Self.event(session: "new", sequence: 1, itemID: "new-live"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.sessionChangedCount, 0, "old defer/error cleanup must not clear the new publication token")

        socket.releaseHistory(at: 1)
        let newIncluded = try await newAttach.value
        XCTAssertEqual(newIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        let view = await client.sessionView()
        XCTAssertEqual(view.sessionId, "new")
        XCTAssertEqual(view.items.map(\.id), ["new-u", "new-a", "new-live"])

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testManualHistoryPublishesOnceAndFailedLaterPageLeavesNoPartialTurn() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("current-u", role: "user")], hasMore: true)
        socket.queueHistory(before: "current-u", [
            HistoryReply(items: [item("old-a2", role: "assistant", turnID: "old-turn")], hasMore: true),
        ])
        socket.queueHistory(before: "old-a2", [
            HistoryReply(items: [item("old-u", role: "user", turnID: "old-turn")], hasMore: true),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let initialIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(initialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        let inserted = try await client.loadEarlierHistory(limit: 1_000)
        XCTAssertEqual(inserted, 2)
        await waitUntil { recorder.sessionChangedCount == 2 }
        var view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["old-u", "old-a2", "current-u"])
        XCTAssertTrue(socket.historyRequests.allSatisfy { $0.limit == 200 })

        // Reconfigure the same earliest boundary so a later request fails after one
        // successfully staged page; neither that page nor an event may leak out.
        socket.queueHistory(before: "old-u", [
            HistoryReply(items: [item("older-a", role: "assistant", turnID: "older-turn")], hasMore: true),
        ])
        socket.queueHistory(before: "older-a", [
            HistoryReply(items: [], hasMore: true, errorCode: "SERVER_INTERNAL"),
        ])
        do {
            _ = try await client.loadEarlierHistory()
            XCTFail("the later page failure must escape")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["old-u", "old-a2", "current-u"])
        XCTAssertTrue(view.hasMoreHistory)
        XCTAssertEqual(recorder.sessionChangedCount, 2)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testManualHistoryWithNilTurnIDPagesPastNonUserPrefixAndTrimsOnlyIncompletePrefix() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("current-u", role: "user"), item("current-a", role: "assistant")], hasMore: true)
        socket.queueHistory(before: "current-u", [
            HistoryReply(items: [item("old-t2", role: "tool"), item("old-a2", role: "assistant")], hasMore: true),
        ])
        socket.queueHistory(before: "old-t2", [
            HistoryReply(items: [item("older-a0", role: "assistant"), item("old-u", role: "user"), item("old-a1", role: "assistant")], hasMore: true),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let initialIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(initialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        let inserted = try await client.loadEarlierHistory()
        XCTAssertEqual(inserted, 4)
        await waitUntil { recorder.sessionChangedCount == 2 }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["old-u", "old-a1", "old-t2", "old-a2", "current-u", "current-a"])
        XCTAssertEqual(socket.historyRequests.map(\.beforeItemID), ["current-u", "old-t2"])
        XCTAssertTrue(view.hasMoreHistory)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testManualHistoryKeepsLeadingNonUserItemsWhenSessionStartIsReached() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("current-u", role: "user")], hasMore: true)
        socket.queueHistory(before: "current-u", [
            HistoryReply(items: [item("initial-system", role: "system"), item("initial-a", role: "assistant")], hasMore: false),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let initialIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(initialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        let inserted = try await client.loadEarlierHistory()
        XCTAssertEqual(inserted, 2)
        await waitUntil { recorder.sessionChangedCount == 2 }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["initial-system", "initial-a", "current-u"])
        XCTAssertFalse(view.hasMoreHistory)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testDuplicatePageFailsWithoutPrependOrPublication() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("current-u", role: "user")], hasMore: true)
        socket.queueHistory(before: "current-u", [
            HistoryReply(items: [item("current-u", role: "user")], hasMore: true),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let initialIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(initialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        do {
            _ = try await client.loadEarlierHistory()
            XCTFail("a non-advancing page must fail rather than loop")
        } catch let error as RACPClientError {
            guard case .malformedFrame = error else { return XCTFail("unexpected error: \(error)") }
        }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["current-u"])
        XCTAssertTrue(view.hasMoreHistory)
        XCTAssertEqual(recorder.sessionChangedCount, 1)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testLateHistoryResponseAfterSessionSwitchIsCancelledWithoutTouchingNewSnapshot() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("old", items: [item("old-current", role: "user")], hasMore: true)
        socket.queueAttach("new", items: [item("new-user", role: "user")], hasMore: false)
        socket.queueHistory(before: "old-current", [
            HistoryReply(items: [item("old-earlier", role: "user")], hasMore: false),
        ])
        let historyStarted = XCTestExpectation(description: "old history is pending")
        socket.pauseHistory(at: 1)
        socket.onHistoryRequest = { call in if call == 1 { historyStarted.fulfill() } }
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let oldInitialIncluded = try await client.attach(sessionId: "old")
        XCTAssertEqual(oldInitialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }

        let loading = Task { try await client.loadEarlierHistory() }
        await fulfillment(of: [historyStarted], timeout: 2)
        let newInitialIncluded = try await client.attach(sessionId: "new")
        XCTAssertEqual(newInitialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 2 }
        socket.releaseHistory(at: 1)
        do {
            _ = try await loading.value
            XCTFail("the old history operation must be cancelled")
        } catch is CancellationError {
            // expected
        }
        let view = await client.sessionView()
        XCTAssertEqual(view.sessionId, "new")
        XCTAssertEqual(view.items.map(\.id), ["new-user"])
        XCTAssertEqual(recorder.sessionChangedCount, 2)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testSubscribeFailureAlsoInvalidatesCandidateWithoutPublishing() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("partial", role: "assistant")], hasMore: true)
        socket.subscribeErrors["session"] = "SERVER_INTERNAL"
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)

        do {
            _ = try await client.attach(sessionId: "session")
            XCTFail("subscribe failure must escape attach")
        } catch {
            // Transport classification is owned by subscribeSession; candidate cleanup is asserted below.
        }
        let view = await client.sessionView()
        XCTAssertNil(view.sessionId)
        XCTAssertNil(view.summary)
        XCTAssertEqual(view.items, [])
        XCTAssertEqual(recorder.sessionChangedCount, 0)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testSuccessfulOldReplayDeferCannotClearNewRebuildFlagOrBuffer() async throws {
        try await assertReplayDeferOwnership(oldReplayFails: false)
    }

    func testFailedOldReplayDeferCannotClearNewRebuildFlagOrBuffer() async throws {
        try await assertReplayDeferOwnership(oldReplayFails: true)
    }

    func testReplaySnapshotBackfillsEvenWhenInitialAttachHadNoSnapshot() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttachWithoutSnapshot("session")
        socket.queueAttach(
            "session",
            items: [item("replay-a", role: "assistant", turnID: "turn-replay")],
            hasMore: true,
            revision: 2
        )
        socket.subscribeReplayComplete["session"] = false
        socket.queueHistory(before: "replay-a", [
            HistoryReply(items: [item("replay-u", role: "user", turnID: "turn-replay")], hasMore: false),
        ])
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)

        let included = try await client.attach(sessionId: "session")
        XCTAssertEqual(included, false, "the public result describes the initial attach response")
        await waitUntil { recorder.sessionChangedCount == 1 }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["replay-u", "replay-a"])
        XCTAssertEqual(socket.historyRequests.map(\.beforeItemID), ["replay-a"])
        XCTAssertEqual(recorder.sessionChangedCount, 1)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testEpochRebuildAcceptsReplaySnapshotAfterInitialNilWithoutAbortingSocket() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("initial-u", role: "user")], hasMore: false)
        socket.queueAttachWithoutSnapshot("session")
        socket.queueAttach(
            "session",
            items: [item("rebuilt-u", role: "user")],
            hasMore: false,
            revision: 2,
            epoch: "epoch-rebuilt"
        )
        let replaySnapshot = XCTestExpectation(description: "replay supplied the rebuild snapshot")
        socket.onAttachRequest = { session, call in
            if session == "session", call == 3 { replaySnapshot.fulfill() }
        }
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let initialIncluded = try await client.attach(sessionId: "session")
        XCTAssertEqual(initialIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        socket.subscribeReplayComplete["session"] = false

        // The real receive path returns requiresSnapshotRebuild and invokes
        // rebuildFromSnapshot; it does not call the public attach helper directly.
        socket.enqueue(Self.event(
            session: "session",
            sequence: 1,
            itemID: "epoch-trigger",
            epoch: "epoch-next"
        ))
        await fulfillment(of: [replaySnapshot], timeout: 2)
        await waitUntil { recorder.sessionChangedCount == 2 }

        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["rebuilt-u"])
        XCTAssertEqual(view.cursor?.epoch, "epoch-rebuilt")
        XCTAssertEqual(view.sessionId, "session")
        XCTAssertEqual(socket.abortCallCount, 0, "a replay-applied snapshot is a successful rebuild")
        XCTAssertEqual(socket.closeCallCount, 0)
        XCTAssertEqual(recorder.sessionChangedCount, 2)

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testSameGenerationQueuedReceiptIsRevokedWhenPublicationSuspensionInstalls() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("a", role: "assistant", turnID: "turn")], hasMore: true)
        socket.queueHistory(before: "a", [
            HistoryReply(items: [item("u", role: "user", turnID: "turn")], hasMore: false),
        ])
        let attachStarted = XCTestExpectation(description: "same-generation signal can precede the token")
        let historyStarted = XCTestExpectation(description: "candidate is suspended")
        socket.pauseAttach(session: "session", at: 1)
        socket.pauseHistory(at: 1)
        socket.onAttachRequest = { session, call in
            if session == "session", call == 1 { attachStarted.fulfill() }
        }
        socket.onHistoryRequest = { call in if call == 1 { historyStarted.fulfill() } }
        // Keep the session key unchanged across attach so the queued receipt has
        // exactly the same coalescing key as the candidate.
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: "session")
        let pump = startPump(client: client, socket: socket)
        await client.enableSessionChangeCoalescing()
        let stream = await client.stream()
        if let catchUpReceipt = await client.beginSessionChangeConsumption() {
            await client.finishSessionChangeConsumption(catchUpReceipt)
        }
        let attach = Task { try await client.attach(sessionId: "session") }
        await fulfillment(of: [attachStarted], timeout: 2)
        await client.emitUpdateForTesting(.sessionChanged)
        socket.releaseAttach(session: "session", at: 1)
        await fulfillment(of: [historyStarted], timeout: 2)

        let suspendedReceipt = await client.beginSessionChangeConsumption()
        XCTAssertNil(suspendedReceipt, "publication suspension must make every receipt unreadable")
        socket.releaseHistory(at: 1)
        let included = try await attach.value
        XCTAssertEqual(included, true)

        let visible = VisibleTurnRecorder()
        let collector = Task {
            for await update in stream {
                guard case .sessionChanged = update else { continue }
                guard let receipt = await client.beginSessionChangeConsumption() else { continue }
                let view = await client.sessionView()
                visible.record(view.items.map(\.id))
                await client.finishSessionChangeConsumption(receipt)
            }
        }
        await waitUntil { visible.snapshots.count == 1 }
        XCTAssertEqual(visible.snapshots, [["u", "a"]], "the pre-token receipt must not suppress the final receipt")

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testFinishDuringPublicationSuspensionDoesNotYieldDirtyReceipt() async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("session", items: [item("a", role: "assistant", turnID: "turn")], hasMore: true)
        socket.queueHistory(before: "a", [
            HistoryReply(items: [item("u", role: "user", turnID: "turn")], hasMore: false),
        ])
        let attachStarted = XCTestExpectation(description: "receipt can begin before the token")
        let historyStarted = XCTestExpectation(description: "candidate is suspended")
        socket.pauseAttach(session: "session", at: 1)
        socket.pauseHistory(at: 1)
        socket.onAttachRequest = { session, call in
            if session == "session", call == 1 { attachStarted.fulfill() }
        }
        socket.onHistoryRequest = { call in if call == 1 { historyStarted.fulfill() } }
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: "session")
        let pump = startPump(client: client, socket: socket)
        await client.enableSessionChangeCoalescing()
        if let catchUpReceipt = await client.beginSessionChangeConsumption() {
            await client.finishSessionChangeConsumption(catchUpReceipt)
        }
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let attach = Task { try await client.attach(sessionId: "session") }
        await fulfillment(of: [attachStarted], timeout: 2)

        await client.emitUpdateForTesting(.sessionChanged)
        await waitUntil { recorder.sessionChangedCount == 2 } // enable catch-up + this signal
        let pendingReceipt = await client.beginSessionChangeConsumption()
        let receipt = try XCTUnwrap(pendingReceipt)
        await client.emitUpdateForTesting(.sessionChanged) // marks the consuming receipt dirty
        socket.releaseAttach(session: "session", at: 1)
        await fulfillment(of: [historyStarted], timeout: 2)

        await client.finishSessionChangeConsumption(receipt)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.sessionChangedCount, 2, "finish must not yield while the candidate is suspended")

        socket.releaseHistory(at: 1)
        let included = try await attach.value
        XCTAssertEqual(included, true)
        await waitUntil { recorder.sessionChangedCount == 3 }
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["u", "a"])

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    func testExhaustedInitialSnapshotWithoutTaskBoundaryWarnsAndKeepsOriginalItems() async throws {
        let baseline = Set(PILog.shared.recentRecords().map(\.sequence))
        let socket = TurnHistorySocket()
        socket.queueAttach(
            "session",
            items: [item("orphan-body", role: "assistant", turnID: "orphan-turn")],
            hasMore: false
        )
        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)

        let included = try await client.attach(sessionId: "session", subscribe: false)
        XCTAssertEqual(included, true)
        let view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["orphan-body"])
        let warning = PILog.shared.recentRecords().first {
            !baseline.contains($0.sequence)
                && $0.level == .warn
                && $0.category == "History"
                && $0.message.contains("without task boundary")
        }
        XCTAssertNotNil(warning, "hasMore=false must still diagnose an exhausted history with no task")
        XCTAssertFalse(warning?.message.contains("orphan-body") == true, "diagnostics must not contain item content")

        pump.cancel()
        await client.stop()
    }

    private func assertReplayDeferOwnership(oldReplayFails: Bool) async throws {
        let socket = TurnHistorySocket()
        socket.queueAttach("old", items: [item("old-initial", role: "user")], hasMore: false)
        socket.queueAttach("old", items: [item("old-replay", role: "user")], hasMore: false, revision: 2)
        socket.queueAttach("new", items: [item("new-initial", role: "user")], hasMore: false)
        socket.queueAttach("new", items: [item("new-replay", role: "user")], hasMore: false, revision: 2)
        socket.subscribeReplayComplete["old"] = false
        socket.subscribeReplayComplete["new"] = false
        socket.pauseAttach(session: "old", at: 2)
        socket.pauseAttach(session: "new", at: 2)
        let oldReplay = XCTestExpectation(description: "old replay attach is pending")
        let newReplay = XCTestExpectation(description: "new replay attach is pending")
        socket.onAttachRequest = { session, call in
            if session == "old", call == 2 { oldReplay.fulfill() }
            if session == "new", call == 2 { newReplay.fulfill() }
        }

        let client = RACPClient(testingSocket: socket, subscriptionId: nil, subscribedSessionId: nil)
        let pump = startPump(client: client, socket: socket)
        let recorder = UpdateRecorder()
        let collector = await startCollector(client: client, recorder: recorder)
        let oldAttach = Task { try await client.attach(sessionId: "old") }
        await fulfillment(of: [oldReplay], timeout: 2)
        let newAttach = Task { try await client.attach(sessionId: "new") }
        await fulfillment(of: [newReplay], timeout: 2)

        socket.enqueue(Self.event(session: "new", sequence: 1, itemID: "new-buffered"))
        socket.releaseAttach(
            session: "old",
            at: 2,
            errorCode: oldReplayFails ? "SERVER_INTERNAL" : nil
        )
        if oldReplayFails {
            do {
                _ = try await oldAttach.value
                XCTFail("the old replay failure must escape its own attach")
            } catch {
                // expected; it must not invalidate the new attachment
            }
        } else {
            let oldIncluded = try await oldAttach.value
            XCTAssertNil(oldIncluded)
        }

        // This arrives after the old defer. If that defer cleared the new flag it
        // reduces immediately; if it cleared the new buffer both live items vanish.
        socket.enqueue(Self.event(session: "new", sequence: 2, itemID: "new-after-old-defer"))
        try await Task.sleep(for: .milliseconds(50))
        var view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["new-initial"])
        XCTAssertEqual(recorder.sessionChangedCount, 0)

        socket.releaseAttach(session: "new", at: 2)
        let newIncluded = try await newAttach.value
        XCTAssertEqual(newIncluded, true)
        await waitUntil { recorder.sessionChangedCount == 1 }
        view = await client.sessionView()
        XCTAssertEqual(view.items.map(\.id), ["new-replay", "new-buffered", "new-after-old-defer"])
        XCTAssertEqual(view.sessionId, "new")

        collector.cancel()
        pump.cancel()
        await client.stop()
    }

    private func item(_ id: String, role: String, turnID: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "itemType": "message",
            "role": role,
            "text": id,
        ]
        if let turnID { result["turnId"] = turnID }
        return result
    }

    private static func event(session: String, sequence: Int, itemID: String, epoch: String = "epoch") -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "events/event",
            "params": [
                "event": [
                    "scope": "session",
                    "kind": "item.completed",
                    "epoch": epoch,
                    "sequence": sequence,
                    "sessionId": session,
                    "item": [
                        "id": itemID,
                        "itemType": "message",
                        "role": "assistant",
                        "text": itemID,
                    ],
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func startPump(client: RACPClient, socket: TurnHistorySocket) -> Task<Void, Never> {
        Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }
    }

    private func startCollector(client: RACPClient, recorder: UpdateRecorder) async -> Task<Void, Never> {
        let stream = await client.stream()
        return Task {
            for await update in stream {
                recorder.record(update)
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ update: RACPClientUpdate) {
        guard case .sessionChanged = update else { return }
        lock.withLock { count += 1 }
    }

    var sessionChangedCount: Int {
        lock.withLock { count }
    }
}

private final class VisibleTurnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []
    private var skipped = 0

    func record(_ ids: [String]) { lock.withLock { values.append(ids) } }
    func recordSkippedQueuedSignal() { lock.withLock { skipped += 1 } }
    var snapshots: [[String]] { lock.withLock { values } }
    var skippedQueuedSignals: Int { lock.withLock { skipped } }
}

private struct HistoryReply {
    let items: [[String: Any]]
    let hasMore: Bool
    var errorCode: String? = nil
}

private struct RecordedHistoryRequest {
    let beforeItemID: String?
    let limit: Int
}

private final class TurnHistorySocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var attachResults: [String: [[String: Any]]] = [:]
    private var attachCallCounts: [String: Int] = [:]
    private var pausedAttachRequests: Set<String> = []
    private var attachContinuations: [String: CheckedContinuation<String?, Never>] = [:]
    private var historyResults: [String: [HistoryReply]] = [:]
    private var historyCallCount = 0
    private var pausedHistoryCalls: Set<Int> = []
    private var historyContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pausedSubscriptions: Set<String> = []
    private var subscriptionContinuations: [String: CheckedContinuation<String?, Never>] = [:]
    private var subscribeCallCount = 0
    private var closed = false
    private var closeCalls = 0
    private var abortCalls = 0
    private(set) var historyRequests: [RecordedHistoryRequest] = []
    var closeCallCount: Int { lock.withLock { closeCalls } }
    var abortCallCount: Int { lock.withLock { abortCalls } }
    var subscribeErrors: [String: String] = [:]
    var subscribeReplayComplete: [String: Bool] = [:]
    var onAttachRequest: ((String, Int) -> Void)?
    var onHistoryRequest: ((Int) -> Void)?
    var onSubscribe: ((Int, String) -> Void)?
    var onSubscribeRequest: ((String) -> Void)?

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func queueAttach(
        _ session: String,
        items: [[String: Any]],
        hasMore: Bool,
        activeItems: [[String: Any]] = [],
        revision: Int = 1,
        epoch: String = "epoch"
    ) {
        let snapshot: [String: Any] = [
            "cursor": ["epoch": epoch, "sequence": 0],
            "revision": revision,
            "items": items,
            "activeItems": activeItems,
            "queuedTurns": [],
            "pendingApprovals": [],
            "hasMoreHistory": hasMore,
        ]
        let result: [String: Any] = [
            "session": ["id": session],
            "replayComplete": true,
            "snapshot": snapshot,
        ]
        lock.withLock { attachResults[session, default: []].append(result) }
    }

    func queueAttachWithoutSnapshot(_ session: String) {
        let result: [String: Any] = [
            "session": ["id": session],
            "replayComplete": true,
        ]
        lock.withLock { attachResults[session, default: []].append(result) }
    }

    func pauseAttach(session: String, at call: Int) {
        lock.withLock { pausedAttachRequests.insert(Self.attachRequestKey(session: session, call: call)) }
    }

    func releaseAttach(session: String, at call: Int, errorCode: String? = nil) {
        let key = Self.attachRequestKey(session: session, call: call)
        let continuation = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            pausedAttachRequests.remove(key)
            return attachContinuations.removeValue(forKey: key)
        }
        continuation?.resume(returning: errorCode)
    }

    func queueHistory(before: String?, _ replies: [HistoryReply]) {
        lock.withLock { historyResults[before ?? "<nil>", default: []].append(contentsOf: replies) }
    }

    func pauseHistory(at call: Int) {
        lock.withLock { pausedHistoryCalls.insert(call) }
    }

    func releaseHistory(at call: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            pausedHistoryCalls.remove(call)
            return historyContinuations.removeValue(forKey: call)
        }
        continuation?.resume()
    }

    func pauseSubscribe(session: String) {
        lock.withLock { pausedSubscriptions.insert(session) }
    }

    func releaseSubscribe(session: String, errorCode: String? = nil) {
        let continuation = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            pausedSubscriptions.remove(session)
            return subscriptionContinuations.removeValue(forKey: session)
        }
        continuation?.resume(returning: errorCode)
    }

    func enqueue(_ data: Data) {
        continuation.yield(data)
    }

    func send(text: String) async throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let method = object["method"] as? String,
              let id = object["id"]
        else { return }
        switch method {
        case "session/attach":
            let session = (object["params"] as? [String: Any])?["sessionId"] as? String ?? ""
            let call = lock.withLock { () -> Int in
                let next = (attachCallCounts[session] ?? 0) + 1
                attachCallCounts[session] = next
                return next
            }
            onAttachRequest?(session, call)
            let requestKey = Self.attachRequestKey(session: session, call: call)
            let shouldPause = lock.withLock { pausedAttachRequests.contains(requestKey) }
            if shouldPause {
                let error = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    lock.withLock { attachContinuations[requestKey] = continuation }
                }
                if let error {
                    yieldError(id: id, code: error)
                    return
                }
            }
            let result = lock.withLock { () -> [String: Any] in
                if attachResults[session]?.isEmpty == false {
                    return attachResults[session]!.removeFirst()
                }
                return [
                    "session": ["id": session],
                    "replayComplete": true,
                    "snapshot": [
                        "cursor": ["epoch": "epoch", "sequence": 0],
                        "revision": 1,
                        "items": [],
                        "activeItems": [],
                        "queuedTurns": [],
                        "pendingApprovals": [],
                        "hasMoreHistory": false,
                    ],
                ]
            }
            yieldResult(id: id, result: result)
        case "events/subscribe":
            let session = (object["params"] as? [String: Any])?["sessionId"] as? String ?? ""
            let call = lock.withLock { () -> Int in
                subscribeCallCount += 1
                return subscribeCallCount
            }
            onSubscribeRequest?(session)
            onSubscribe?(call, session)
            var error = lock.withLock { subscribeErrors[session] }
            let shouldPause = lock.withLock { pausedSubscriptions.contains(session) }
            if shouldPause {
                let releasedError = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    lock.withLock { subscriptionContinuations[session] = continuation }
                }
                error = releasedError
            }
            if let error {
                yieldError(id: id, code: error)
            } else {
                yieldResult(id: id, result: [
                    "subscriptionId": "sub-\(call)",
                    "replayComplete": lock.withLock { subscribeReplayComplete[session] ?? true },
                    "starting": ["epoch": "epoch", "sequence": 0],
                ])
            }
        case "session/history":
            let params = object["params"] as? [String: Any]
            let before = params?["beforeItemId"] as? String
            let call = lock.withLock { () -> Int in
                historyCallCount += 1
                historyRequests.append(RecordedHistoryRequest(
                    beforeItemID: before,
                    limit: params?["limit"] as? Int ?? 0
                ))
                return historyCallCount
            }
            onHistoryRequest?(call)
            let shouldPause = lock.withLock { pausedHistoryCalls.contains(call) }
            if shouldPause {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { historyContinuations[call] = continuation }
                }
            }
            let reply = lock.withLock { () -> HistoryReply in
                let key = before ?? "<nil>"
                if historyResults[key]?.isEmpty == false {
                    return historyResults[key]!.removeFirst()
                }
                return HistoryReply(items: [], hasMore: false)
            }
            if let errorCode = reply.errorCode {
                yieldError(id: id, code: errorCode)
            } else {
                yieldResult(id: id, result: ["items": reply.items, "hasMore": reply.hasMore])
            }
        default:
            yieldResult(id: id, result: [:])
        }
    }

    func close() async {
        let shouldFinish = lock.withLock { () -> Bool in
            closeCalls += 1
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldFinish { continuation.finish() }
    }

    func abort(_ termination: RACPSocketTermination) async {
        lock.withLock { abortCalls += 1 }
        await close()
    }

    func waitUntilClosed() async { await Task.yield() }

    private static func attachRequestKey(session: String, call: Int) -> String {
        "\(session)#\(call)"
    }

    private func yieldResult(id: Any, result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "result": result,
        ]) else { return }
        continuation.yield(data)
    }

    private func yieldError(id: Any, code: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": "scripted history failure"],
        ]) else { return }
        continuation.yield(data)
    }
}
