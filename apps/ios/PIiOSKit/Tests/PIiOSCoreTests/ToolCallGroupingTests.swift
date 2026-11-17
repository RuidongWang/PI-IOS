import XCTest

@testable import PIiOSCore

final class ToolCallGroupingTests: XCTestCase {
    // MARK: - 分组

    func testConsecutiveToolRunBeforeFinalReplyCollapsesIntoOneGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1", name: "bash"),
            tool("t2", name: "bash"),
            tool("t3", name: "grep"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].id, "u1")
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("最终回复之前的工具调用应合并为一组")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(group.title, "3 次工具调用")
        XCTAssertEqual(group.toolSummary, "bash ×2、grep")
        XCTAssertEqual(group.statusSummary, "已完成")
        XCTAssertEqual(rows[2].id, "final")
    }

    func testSingleToolCallBeforeFinalReplyIsFoldable() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 3)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("单次工具调用也必须能折叠")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1"])
        XCTAssertEqual(group.title, "1 次工具调用")
        XCTAssertEqual(rows[2].id, "final")
    }

    func testRunningTurnIsFoldableBeforeFinalReplyArrives() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1", status: "running"),
        ])

        XCTAssertEqual(rows.count, 2)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("运行中的轮次也必须能折叠")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1"])
        XCTAssertEqual(group.statusSummary, "运行中")
        XCTAssertTrue(group.isRunning)
    }

    func testInterleavedMessagesAndToolsFoldIntoOneTurnGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            message("m1", text: "先看一下磁盘"),
            tool("t1"),
            message("m2", text: "再看内存"),
            tool("t2"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 3)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("同一轮内的所有中间过程应合并成一组")
        }
        XCTAssertEqual(group.items.map(\.id), ["m1", "t1", "m2", "t2"])
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.messageCount, 2)
        XCTAssertEqual(group.title, "2 次工具调用")
        XCTAssertEqual(group.id, "tool-group:turn:u1")
        XCTAssertEqual(rows[2].id, "final")
    }

    func testMessageAfterToolIsNotFinalReplyWhenMoreToolsFollow() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            message("mid"),
            tool("t2"),
        ])

        XCTAssertEqual(rows.count, 2)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("末尾仍是工具调用时，整轮都还是中间过程")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "mid", "t2"])
    }

    func testSeparateToolRunsInsideOneTurnMergeIntoOneGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("a1"), tool("a2"),
            message("mid"),
            tool("b1"), tool("b2"), tool("b3"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 3)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("同一轮内被过渡消息隔开的工具调用应共享一个分组")
        }
        XCTAssertEqual(group.items.map(\.id), ["a1", "a2", "mid", "b1", "b2", "b3"])
    }

    // MARK: - 空行

    /// 回归：Host 在一轮的纯工具步骤里会推正文为空/纯空白的 assistant 条目。
    /// 这类条目在组内只会渲染出「右侧复制按钮 + 一整块空白」，看起来就是一条空行。
    func testBlankIntermediateMessageNeverBecomesAnEmptyRow() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            message("m1", text: ""),
            message("m2", text: "  \n\n "),
            tool("t2"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 3)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("空白中间条目不应阻止工具调用成组")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "t2"])
        XCTAssertEqual(group.messageCount, 0)
    }

    func testBlankTrailingMessageDoesNotBecomeAnEmptyFinalReply() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            message("blank", text: "\n\n"),
        ])

        XCTAssertEqual(rows.map(\.id), ["u1", "tool-group:turn:u1"])
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("空白尾条目不构成最终回复")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1"])
    }

    func testBlankUserMessageStaysVisible() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            user("u2", text: "   "),
            message("final"),
        ])

        XCTAssertEqual(rows.map(\.id), ["u1", "u2", "final"])
    }

    /// 附件是可见内容：正文为空但有附件的条目必须保留，不能被当成空行丢掉。
    func testAttachmentOnlyMessageIsKept() {
        let attachment: [String: JSONValue] = [
            "id": .string("a1"),
            "sessionId": .string("s1"),
            "kind": .string("image"),
            "fileName": .string("shot.png"),
            "mimeType": .string("image/png"),
            "byteLength": .number(12),
            "sha256": .string("abc"),
            "state": .string("ready"),
            "createdAt": .string("2026-11-12T00:00:00Z"),
        ]
        let item = RACPItem(id: "m-attach", payload: .object([
            "id": .string("m-attach"),
            "role": .string("assistant"),
            "text": .string(""),
            "attachments": .array([.object(attachment)]),
        ]))
        XCTAssertFalse(item.isBlankNonToolItem)

        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            item,
            message("final"),
        ])
        XCTAssertEqual(rows.count, 3)
        guard case let .toolGroup(group) = rows[1] else {
            return XCTFail("带附件的中间条目应留在组内")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "m-attach"])
    }

    func testTurnWithoutToolCallsDoesNotCreateGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            message("m1", text: "先说明一下"),
            message("final"),
        ])

        XCTAssertEqual(rows.map(\.id), ["u1", "m1", "final"])
    }

    func testEachTurnGetsItsOwnStableGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            user("u1"),
            tool("t1"),
            message("final1"),
            user("u2"),
            tool("t2"),
            message("final2"),
        ])

        XCTAssertEqual(rows.count, 6)
        guard case .toolGroup = rows[1], case .toolGroup = rows[4] else {
            return XCTFail("每轮都应有一个分组")
        }
        XCTAssertEqual(rows[1].id, "tool-group:turn:u1")
        XCTAssertEqual(rows[4].id, "tool-group:turn:u2")
    }

    func testGroupIDStaysStableFromFirstToolThroughFinalReply() {
        let one = ToolCallGroupingPolicy.rows(for: [user("u1"), tool("t1")])
        let two = ToolCallGroupingPolicy.rows(for: [user("u1"), tool("t1"), tool("t2")])
        let three = ToolCallGroupingPolicy.rows(for: [
            user("u1"), tool("t1"), tool("t2"), message("final"),
        ])
        let resumed = ToolCallGroupingPolicy.rows(for: [
            user("u1"), tool("t1"), tool("t2"), message("final"), tool("t3"),
        ])

        XCTAssertEqual(one[1].id, "tool-group:turn:u1")
        XCTAssertEqual(two[1].id, "tool-group:turn:u1")
        XCTAssertEqual(three[1].id, "tool-group:turn:u1")
        XCTAssertEqual(resumed[1].id, "tool-group:turn:u1")
    }

    func testLeadingHistoryFragmentKeepsLegacyGrouping() {
        // 没有用户消息锚点的历史片段（分页截断）沿用旧规则。
        XCTAssertEqual(
            ToolCallGroupingPolicy.rows(for: [tool("t1")]).map(\.id),
            ["t1"]
        )

        let rows = ToolCallGroupingPolicy.rows(for: [
            tool("a1"), tool("a2"),
            message("mid"),
            tool("b1"), tool("b2"), tool("b3"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].id, "tool-group:a1")
        XCTAssertEqual(rows[2].id, "tool-group:b1")
    }

    func testToolNamesAreCappedAndFallsBackToGenericLabel() {
        let group = ToolCallGroup(items: [
            tool("1", name: "bash"),
            tool("2", name: "grep"),
            tool("3", name: "read"),
            tool("4", name: "write"),
            tool("5", name: nil),
        ])

        XCTAssertEqual(group.toolSummary, "bash、grep、read 等")
    }

    func testGroupStatusPrefersRunningThenFailure() {
        XCTAssertEqual(
            ToolCallGroup(items: [tool("1"), tool("2", status: "running")]).statusSummary,
            "运行中"
        )
        XCTAssertEqual(
            ToolCallGroup(items: [tool("1", status: "failed"), tool("2")]).statusSummary,
            "有失败"
        )
        XCTAssertEqual(
            ToolCallGroup(items: [tool("1", status: "cancelled"), tool("2")]).statusSummary,
            "已取消"
        )
    }

    func testAnchorMapsItemsInsideGroupToFirstItem() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            tool("t1"), tool("t2"), tool("t3"), message("final"),
        ])

        XCTAssertEqual(ToolCallGroupingPolicy.anchorItemID(for: "t2", in: rows), "t1")
        XCTAssertEqual(ToolCallGroupingPolicy.anchorItemID(for: "final", in: rows), "final")
        XCTAssertEqual(ToolCallGroupingPolicy.anchorItemID(for: "missing", in: rows), "missing")
    }

    func testRowIndexMatchesLegacyAnchorForEveryOriginalItem() {
        let items = [
            user("u1"),
            tool("t1"),
            message("m1"),
            tool("t2"),
            message("final1"),
            tool("solo"),
            message("final2"),
            tool("a1"), tool("a2"),
            message("legacy-mid"),
            tool("b1"), tool("b2"),
            message("legacy-final"),
        ]
        let rows = ToolCallGroupingPolicy.rows(for: items)
        let index = ConversationRowIndex(rows: rows)

        XCTAssertEqual(index.indexedItemCount, items.count)
        XCTAssertEqual(index.rows, rows)
        XCTAssertEqual(index.anchors.count, items.count)
        for item in items {
            XCTAssertEqual(
                index.anchorItemID(for: item.id),
                ToolCallGroupingPolicy.anchorItemID(for: item.id, in: rows),
                "item \(item.id) 的锚点必须与旧线性查找一致"
            )
        }
        XCTAssertEqual(index.anchorItemID(for: "missing"), "missing")
    }

    func testRowIndexCoversLargeMixedHistoryInOnePass() {
        for count in [1_000, 5_000, 10_000] {
            let items = mixedHistory(count: count)
            let index = ConversationRowIndex(items: items)

            XCTAssertEqual(index.indexedItemCount, count)
            XCTAssertEqual(index.anchors.count, count)
            XCTAssertEqual(index.rows.reduce(0) { partial, row in
                switch row {
                case .item: return partial + 1
                case let .toolGroup(group): return partial + group.items.count
                }
            }, count)
            for item in items {
                XCTAssertNotNil(index.anchors[item.id], "N=\(count) 时 item \(item.id) 必须有锚点")
            }
        }
    }

    func testRowIndexReplacementDropsStaleAnchors() {
        let first = ConversationRowIndex(items: [
            user("u1"),
            tool("old-tool"),
            message("old-final"),
        ])
        let second = ConversationRowIndex(items: [
            user("u2"),
            tool("new-tool"),
            message("new-final"),
        ])

        XCTAssertNotNil(first.anchors["old-tool"])
        XCTAssertNil(second.anchors["old-tool"])
        XCTAssertEqual(second.anchorItemID(for: "old-tool"), "old-tool")
        XCTAssertEqual(second.anchorItemID(for: "new-tool"), "new-tool")
    }

    func testRowIndexKeepsGroupedAnchorAcrossPagePrepend() {
        let oldPage = [
            tool("page-tool-1"),
            tool("page-tool-2"),
            message("page-final"),
        ]
        let oldRows = ToolCallGroupingPolicy.rows(for: oldPage)
        let oldIndex = ConversationRowIndex(rows: oldRows)
        XCTAssertEqual(oldIndex.anchorItemID(for: "page-tool-2"), "page-tool-1")

        let prepended = mixedHistory(count: 40) + oldPage
        let newIndex = ConversationRowIndex(items: prepended)
        let expectedAnchor = ToolCallGroupingPolicy.anchorItemID(for: "page-tool-2", in: newIndex.rows)
        XCTAssertEqual(
            newIndex.anchorItemID(for: "page-tool-2"),
            expectedAnchor,
            "跨页后旧条目必须映射到重新合并后的当前分组锚点"
        )
        XCTAssertNotEqual(expectedAnchor, "page-tool-1", "前页补入了同一轮工具，行锚点应允许合并变化")
        XCTAssertTrue(newIndex.rows.contains { $0.anchorItemID == expectedAnchor })
    }

    func testToolItemTypeVariantsAreRecognized() throws {
        for type in ["tool", "tool_call", "toolResult"] {
            let item = RACPItem(id: type, payload: .object([
                "id": .string(type),
                "itemType": .string(type),
            ]))
            XCTAssertTrue(item.isToolItem, "\(type) 应识别为工具条目")
        }
    }

    // MARK: - 状态文案

    func testStatusLabelsAreLocalized() {
        XCTAssertEqual(ToolStatusPresentation.label(for: "completed"), "已完成")
        XCTAssertEqual(ToolStatusPresentation.label(for: "running"), "运行中")
        XCTAssertEqual(ToolStatusPresentation.label(for: "failed"), "失败")
        XCTAssertEqual(ToolStatusPresentation.label(for: "cancelled"), "已取消")
        XCTAssertEqual(ToolStatusPresentation.label(for: "custom-state"), "custom-state")
        XCTAssertNil(ToolStatusPresentation.label(for: nil))
    }

    // MARK: - Helpers

    private func tool(
        _ id: String,
        name: String? = "bash",
        status: String? = "completed",
        text: String? = nil
    ) -> RACPItem {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "itemType": .string("tool"),
            "role": .string("tool"),
        ]
        if let name { object["toolName"] = .string(name) }
        if let status { object["status"] = .string(status) }
        if let text { object["text"] = .string(text) }
        return RACPItem(id: id, payload: .object(object))
    }

    private func message(_ id: String, text: String = "done") -> RACPItem {
        RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("assistant"),
            "text": .string(text),
        ]))
    }

    private func mixedHistory(count: Int) -> [RACPItem] {
        var items: [RACPItem] = []
        items.reserveCapacity(count)
        var turn = 0
        while items.count < count {
            let userID = "u-\(turn)"
            let firstToolID = "t-\(turn)-a"
            let midID = "m-\(turn)"
            let secondToolID = "t-\(turn)-b"
            let finalID = "f-\(turn)"
            items.append(user(userID))
            items.append(tool(firstToolID))
            items.append(message(midID, text: "progress \(turn)"))
            items.append(tool(secondToolID))
            items.append(message(finalID, text: "final \(turn)"))
            turn += 1
        }
        return Array(items.prefix(count))
    }

    private func user(_ id: String, text: String = "帮我看看") -> RACPItem {
        RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("user"),
            "text": .string(text),
        ]))
    }
}
