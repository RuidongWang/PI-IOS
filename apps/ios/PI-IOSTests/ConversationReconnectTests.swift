import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

@MainActor
final class ConversationReconnectTests: XCTestCase {
    func testPreserveViewAcrossSameHostBindKeepsLiveViewAndMarksAttachmentStale() async throws {
        let controller = SessionController(requestKeys: SessionRequestKeyStore(fileURL: nil))
        let firstClient = RACPClient(
            configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil),
            confirmer: ReconnectRejectHost()
        )
        let summary = try makeSummary(id: "sess-1", projectId: "proj-1", title: "Active Session")
        let view = RACPSessionView(
            sessionId: "sess-1",
            summary: summary,
            items: [
                RACPItem(id: "item-1", payload: .object([
                    "id": .string("item-1"),
                    "role": .string("assistant"),
                    "text": .string("Live content")
                ]))
            ],
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            expiredApprovalIds: [],
            cursor: RACPCursor(epoch: "e1", sequence: 1),
            revision: 1,
            replayComplete: true,
            hasMoreHistory: false,
            runningTurnId: nil,
            failedQueueStartID: nil
        )

        controller.bind(client: firstClient, online: true)
        controller.installViewForTesting(view, sessionId: "sess-1", summary: summary)
        controller.draftText = "unsent message"
        XCTAssertTrue(controller.isAttachedCurrent(to: "sess-1"))

        let secondClient = RACPClient(
            configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil),
            confirmer: ReconnectRejectHost()
        )
        controller.bind(client: nil, online: false, preserveView: true)
        XCTAssertEqual(controller.attachedSessionId, "sess-1")
        XCTAssertEqual(controller.view.sessionId, "sess-1")
        XCTAssertEqual(controller.view.items.count, 1)
        XCTAssertEqual(controller.draftText, "unsent message")
        XCTAssertNil(controller.openingSessionID)
        XCTAssertFalse(controller.isAttachedCurrent(to: "sess-1"))

        controller.bind(client: secondClient, online: false, preserveView: true)
        XCTAssertEqual(controller.attachedSessionId, "sess-1")
        XCTAssertEqual(controller.view.sessionId, "sess-1")
        XCTAssertNil(controller.openingSessionID)
        XCTAssertFalse(controller.isAttachedCurrent(to: "sess-1"))

        await firstClient.stop()
        await secondClient.stop()
    }

    func testReconnectSourcesDoNotTriggerOpeningPreviewForSameOrUnboundSession() async {
        let controller = SessionController(requestKeys: SessionRequestKeyStore(fileURL: nil))
        let client = RACPClient(
            configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil),
            confirmer: ReconnectRejectHost()
        )
        controller.bind(client: nil, online: false)

        await controller.attach(sessionId: "sess-cached", source: "connectionRestore")
        XCTAssertNil(controller.openingSessionID)

        controller.prepareToOpen(sessionId: "sess-cached", showPreview: false)
        XCTAssertNil(controller.openingSessionID)

        controller.prepareToOpen(sessionId: "sess-cached", showPreview: true)
        XCTAssertEqual(controller.openingSessionID, "sess-cached")

        controller.bind(client: client, online: false)
        await client.stop()
    }

    func testSetCurrentHostPreservesViewOnSameHostAndClearsOnDifferentHost() async throws {
        let hostA = HostRecord(
            id: UUID(),
            name: "Host A",
            host: "127.0.0.1",
            port: 22,
            username: "user",
            authKind: .password,
            createdAt: Date(),
            isCurrent: true,
            pairedAt: nil
        )
        let hostB = HostRecord(
            id: UUID(),
            name: "Host B",
            host: "127.0.0.2",
            port: 22,
            username: "user",
            authKind: .password,
            createdAt: Date(),
            isCurrent: false,
            pairedAt: nil
        )
        let model = AppModel(seed: PersistedState(hosts: [hostA, hostB]))
        let client = RACPClient(
            configuration: .init(ssh: nil, hostPort: nil, deviceToken: nil),
            confirmer: ReconnectRejectHost()
        )
        model.connection.installConnectionPiecesForTesting(oldClient: client, hostID: hostA.id)
        let summary = try makeSummary(id: "sess-a", projectId: "proj-a", title: "Session A")
        let view = RACPSessionView(
            sessionId: "sess-a",
            summary: summary,
            items: [RACPItem(id: "i1", payload: .object(["id": .string("i1"), "role": .string("user"), "text": .string("hi")]))],
            activeItems: [],
            queuedTurns: [],
            pendingApprovals: [],
            expiredApprovalIds: [],
            cursor: nil,
            revision: 1,
            replayComplete: true,
            hasMoreHistory: false,
            runningTurnId: nil,
            failedQueueStartID: nil
        )
        model.connection.session.installViewForTesting(view, sessionId: "sess-a", summary: summary)

        await model.setCurrentHost(id: hostA.id, waitForOnline: false)
        XCTAssertEqual(model.connection.session.attachedSessionId, "sess-a")
        XCTAssertEqual(model.connection.session.view.sessionId, "sess-a")
        XCTAssertNil(model.connection.session.openingSessionID)

        await model.setCurrentHost(id: hostB.id, waitForOnline: false)
        XCTAssertNil(model.connection.session.attachedSessionId)
        XCTAssertNil(model.connection.session.view.sessionId)

        await client.stop()
    }

    func testOfflineThreadViewEquatableSkipsUnchangedCacheSnapshots() {
        let hostID = UUID()
        let entry = OfflineSessionCacheEntry(
            id: "entry-1",
            sessionId: "sess-1",
            hostID: hostID,
            text: "cached text",
            createdAt: Date(timeIntervalSince1970: 1_704_164_640)
        )
        let snapshot = OfflineCachedSession(entries: [entry], cursor: nil, approvals: [], draft: nil)

        let first = ConversationOfflineThreadView(
            sessionId: "sess-1",
            cached: snapshot,
            offlineCacheReady: true,
            offlineCacheLoadError: nil
        )
        let second = ConversationOfflineThreadView(
            sessionId: "sess-1",
            cached: snapshot,
            offlineCacheReady: true,
            offlineCacheLoadError: nil
        )
        let updated = ConversationOfflineThreadView(
            sessionId: "sess-1",
            cached: OfflineCachedSession(entries: [entry], cursor: nil, approvals: [], draft: OfflineSessionDraft(hostID: hostID, sessionId: "sess-1", text: "draft", idempotencyKey: "k1", updatedAt: Date(timeIntervalSince1970: 1_704_164_640))),
            offlineCacheReady: true,
            offlineCacheLoadError: nil
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, updated)
    }
}

private func makeSummary(id: String, projectId: String, title: String) throws -> RACPSessionSummary {
    let data = Data("{\"id\":\"\(id)\",\"projectId\":\"\(projectId)\",\"title\":\"\(title)\",\"status\":\"idle\"}".utf8)
    return try JSONDecoder().decode(RACPSessionSummary.self, from: data)
}

private struct ReconnectRejectHost: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .reject
    }
}
