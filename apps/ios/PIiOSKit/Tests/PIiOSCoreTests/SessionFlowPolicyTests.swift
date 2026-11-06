import Foundation
import XCTest
@testable import PIiOSCore

/// 会话流程的纯策略测试：排队快照合并（AC-13.1）、回答草稿（U06）、发送意图（U11）。
final class SessionFlowPolicyTests: XCTestCase {
    private func snapshot(
        queuedTurns: [JSONValue],
        sequence: Int = 10
    ) -> RACPSnapshot {
        RACPSnapshot(
            cursor: RACPCursor(epoch: "ep_flow", sequence: sequence),
            revision: 1,
            queuedTurns: queuedTurns
        )
    }

    // MARK: - 排队快照合并（AC-13.1）

    func testQueuedTurnParseReadsTextAndAttachmentCount() {
        let parsed = QueuedTurn.parse([
            .object(["id": .string("turn_q1"), "text": .string("  补充磁盘检查  "), "attachmentCount": .number(2)]),
            .object(["id": .string("turn_q2"), "input": .object(["text": .string("嵌套正文")])]),
            .object(["id": .string("turn_q3"), "text": .string("   "), "attachmentCount": .number(3)]),
        ])

        XCTAssertEqual(parsed.map(\.id), ["turn_q1", "turn_q2", "turn_q3"])
        XCTAssertEqual(parsed[0].text, "补充磁盘检查")
        XCTAssertEqual(parsed[0].attachmentCount, 2)
        XCTAssertEqual(parsed[1].text, "嵌套正文")
        XCTAssertNil(parsed[2].text, "纯空白正文按缺省处理")
        XCTAssertEqual(parsed[2].attachmentCount, 3)
    }

    func testQueuedTurnDisplayTextNeverFallsBackToBareIdentifier() {
        XCTAssertEqual(QueuedTurn(id: "turn_1", text: "看看内存").displayText, "看看内存")
        XCTAssertEqual(QueuedTurn(id: "turn_2", attachmentCount: 2).displayText, "2 张图片")
        let bare = QueuedTurn(id: "turn_3")
        XCTAssertFalse(bare.displayText.isEmpty)
        XCTAssertFalse(bare.displayText.contains("turn_3"), "缺正文时不得显示裸 id")
    }

    func testQueueSnapshotMergePreservesLocalTextAndAttachmentCount() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(snapshot(queuedTurns: []), replayComplete: true)
        // 发送排队后的即时本地反馈：RACPClient 在 startTurn 返回时记录正文。
        viewModel.recordQueuedTurn(id: "turn_q1", text: "补充磁盘检查", attachmentCount: 2)

        // 服务端快照还没有 text/attachmentCount（旧版本 PI-adaptor 或字段缺失）。
        viewModel.applySnapshot(
            snapshot(queuedTurns: [.object(["id": .string("turn_q1")])], sequence: 11),
            replayComplete: true
        )

        let merged = QueuedTurn.parse(viewModel.queuedTurns)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "补充磁盘检查")
        XCTAssertEqual(merged[0].attachmentCount, 2)
        XCTAssertEqual(merged[0].displayText, "补充磁盘检查")
    }

    func testQueueSnapshotServerTextWinsAndMissingTurnsAreDropped() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(snapshot(queuedTurns: []), replayComplete: true)
        viewModel.recordQueuedTurn(id: "turn_q1", text: "本地正文")
        viewModel.recordQueuedTurn(id: "turn_q2", text: "本地旧项")

        viewModel.applySnapshot(
            snapshot(queuedTurns: [
                .object(["id": .string("turn_q1"), "text": .string("服务端正文")]),
            ], sequence: 12),
            replayComplete: true
        )

        let merged = QueuedTurn.parse(viewModel.queuedTurns)
        XCTAssertEqual(merged.map(\.id), ["turn_q1"], "不在快照里的排队项必须丢弃")
        XCTAssertEqual(merged[0].text, "服务端正文", "服务端给了正文时以服务端为准")
    }

    // MARK: - 回答草稿（U06）

    func testAnswerDraftScopeIsolatesHostSessionAndInput() {
        let base = AnswerDraftScope(hostID: "host-a", sessionID: "s1", inputID: "in_1")
        XCTAssertEqual(base, AnswerDraftScope(hostID: "host-a", sessionID: "s1", inputID: "in_1"))
        XCTAssertNotEqual(base.storageKey, AnswerDraftScope(hostID: "host-b", sessionID: "s1", inputID: "in_1").storageKey)
        XCTAssertNotEqual(base.storageKey, AnswerDraftScope(hostID: "host-a", sessionID: "s2", inputID: "in_1").storageKey)
        XCTAssertNotEqual(base.storageKey, AnswerDraftScope(hostID: "host-a", sessionID: "s1", inputID: "in_2").storageKey)
        // 分隔符不会让不同作用域撞键。
        XCTAssertNotEqual(
            AnswerDraftScope(hostID: "a\u{1F}b", sessionID: "c", inputID: "d").storageKey,
            AnswerDraftScope(hostID: "a", sessionID: "b\u{1F}c", inputID: "d").storageKey
        )
    }

    func testAnswerOutcomeOnlyClearsDraftOnSuccessOrDefinitiveFailure() {
        XCTAssertTrue(InputAnswerOutcome.submitted.clearsDraft)
        XCTAssertTrue(InputAnswerOutcome.noLongerActionable(reason: "版本冲突").clearsDraft)
        XCTAssertTrue(InputAnswerOutcome.stale(reason: "其他端已回答").clearsDraft)
        XCTAssertFalse(InputAnswerOutcome.failed(reason: "超时").clearsDraft)
    }

    func testAnswerFailureTriageKeepsDraftForRetryableErrors() {
        XCTAssertEqual(
            AnswerDraftPolicy.outcomeAfterFailure(serverCode: nil, cardStillPending: true, reason: "网络超时"),
            .failed(reason: "网络超时")
        )
        XCTAssertEqual(
            AnswerDraftPolicy.outcomeAfterFailure(serverCode: .notFound, cardStillPending: true, reason: "服务器未找到"),
            .noLongerActionable(
                reason: "该提问已失效：\(ConnectionFailureClassifier.userMessage(forRACPCode: .notFound))"
            )
        )
        XCTAssertEqual(
            AnswerDraftPolicy.outcomeAfterFailure(serverCode: nil, cardStillPending: false, reason: "刷新后卡片消失"),
            .stale(reason: "该提问已由其他端处理：刷新后卡片消失")
        )
        // 明确失效优先于「仍在快照里」的暂时状态。
        XCTAssertEqual(
            AnswerDraftPolicy.outcomeAfterFailure(serverCode: .approvalExpired, cardStillPending: false, reason: "过期"),
            .stale(reason: "该提问已由其他端处理：过期")
        )
    }

    // MARK: - 发送意图冻结（U11）

    private func intent(
        hostID: String = "host-a",
        sessionID: String = "s1",
        bindingKey: String = "prv\u{1F}model\u{1F}low",
        draftText: String = "检查磁盘",
        attachmentIDs: [String] = ["att_1"],
        selectionGeneration: Int = 3
    ) -> SendIntent {
        SendIntent(
            hostID: hostID,
            sessionID: sessionID,
            bindingKey: bindingKey,
            draftText: draftText,
            attachmentIDs: attachmentIDs,
            selectionGeneration: selectionGeneration
        )
    }

    func testSendIntentMatchesUnchangedState() {
        let frozen = intent()
        XCTAssertTrue(frozen.matches(
            hostID: "host-a",
            sessionID: "s1",
            bindingKey: frozen.bindingKey,
            draftText: "检查磁盘",
            attachmentIDs: ["att_1"],
            selectionGeneration: 3
        ))
        // 附件顺序无关。
        XCTAssertTrue(intent(attachmentIDs: ["att_1", "att_2"]).matches(
            hostID: "host-a",
            sessionID: "s1",
            bindingKey: frozen.bindingKey,
            draftText: "检查磁盘",
            attachmentIDs: ["att_2", "att_1"],
            selectionGeneration: 3
        ))
        XCTAssertTrue(frozen.isSameSession(hostID: "host-a", sessionID: "s1"))
        XCTAssertFalse(frozen.isSameSession(hostID: "host-a", sessionID: "s2"))
    }

    func testSendIntentRejectsAnyChangedTargetOrDraftPart() {
        let frozen = intent()
        let current = (
            hostID: "host-a",
            sessionID: "s1",
            bindingKey: frozen.bindingKey,
            draftText: "检查磁盘",
            attachmentIDs: ["att_1"],
            selectionGeneration: 3
        )

        XCTAssertFalse(frozen.matches(
            hostID: "host-b", sessionID: current.sessionID, bindingKey: current.bindingKey,
            draftText: current.draftText, attachmentIDs: current.attachmentIDs,
            selectionGeneration: current.selectionGeneration
        ))
        XCTAssertFalse(frozen.matches(
            hostID: current.hostID, sessionID: "s2", bindingKey: current.bindingKey,
            draftText: current.draftText, attachmentIDs: current.attachmentIDs,
            selectionGeneration: current.selectionGeneration
        ))
        XCTAssertFalse(frozen.matches(
            hostID: current.hostID, sessionID: current.sessionID, bindingKey: "prv\u{1F}other\u{1F}low",
            draftText: current.draftText, attachmentIDs: current.attachmentIDs,
            selectionGeneration: current.selectionGeneration
        ))
        XCTAssertFalse(frozen.matches(
            hostID: current.hostID, sessionID: current.sessionID, bindingKey: current.bindingKey,
            draftText: "检查内存", attachmentIDs: current.attachmentIDs,
            selectionGeneration: current.selectionGeneration
        ))
        XCTAssertFalse(frozen.matches(
            hostID: current.hostID, sessionID: current.sessionID, bindingKey: current.bindingKey,
            draftText: current.draftText, attachmentIDs: [],
            selectionGeneration: current.selectionGeneration
        ))
        XCTAssertFalse(frozen.matches(
            hostID: current.hostID, sessionID: current.sessionID, bindingKey: current.bindingKey,
            draftText: current.draftText, attachmentIDs: current.attachmentIDs,
            selectionGeneration: 4
        ))
    }
}
