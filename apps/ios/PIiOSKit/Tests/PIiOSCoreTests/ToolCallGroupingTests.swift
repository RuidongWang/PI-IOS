import XCTest

@testable import PIiOSCore

final class ToolCallGroupingTests: XCTestCase {
    // MARK: - 分组

    func testConsecutiveToolRunBeforeFinalReplyCollapsesIntoOneGroup() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            tool("t1", name: "bash"),
            tool("t2", name: "bash"),
            tool("t3", name: "grep"),
            message("final"),
        ])

        XCTAssertEqual(rows.count, 2)
        guard case let .toolGroup(group) = rows[0] else {
            return XCTFail("连续工具调用应合并为一组")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(group.title, "3 次工具调用")
        XCTAssertEqual(group.toolSummary, "bash ×2、grep")
        XCTAssertEqual(group.statusSummary, "已完成")
        XCTAssertEqual(rows[1].id, "final")
    }

    func testTrailingToolRunStaysExpandedWhileTurnIsStillStreaming() {
        // 本轮仍在进行：后面还没有最终回复，逐条展示执行进度，不做分组。
        let rows = ToolCallGroupingPolicy.rows(for: [
            message("user"),
            tool("t1", status: "running"),
            tool("t2", status: "running"),
        ])

        XCTAssertEqual(rows.map(\.id), ["user", "t1", "t2"])
        XCTAssertFalse(rows.dropFirst().contains { row in
            if case .toolGroup = row { return true }
            return false
        })
    }

    func testSingleToolCallIsNeverGrouped() {
        let rows = ToolCallGroupingPolicy.rows(for: [
            tool("t1"),
            message("final"),
        ])

        XCTAssertEqual(rows.map(\.id), ["t1", "final"])
    }

    func testSeparateToolRunsBecomeSeparateGroups() {
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

    func testGroupIDStaysStableWhenMoreToolsStreamIn() {
        let before = ToolCallGroupingPolicy.rows(for: [tool("t1"), tool("t2"), message("final")])
        let after = ToolCallGroupingPolicy.rows(for: [tool("t1"), tool("t2"), tool("t3"), message("final")])

        XCTAssertEqual(before[0].id, after[0].id)
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

    private func message(_ id: String) -> RACPItem {
        RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("assistant"),
            "text": .string("done"),
        ]))
    }
}
