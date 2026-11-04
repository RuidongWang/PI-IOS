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

    private func user(_ id: String) -> RACPItem {
        RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("user"),
            "text": .string("帮我看看"),
        ]))
    }
}
