import XCTest
import UIKit

/// Agent 消息的 Markdown 渲染。
///
/// 夹具 `online-markdown-message` 给出模型最常见的输出形态：`##` 标题、`**粗体**`、
/// 行内代码、管道表格、列表与围栏代码块。纯 `Text` 会把标记原样画在气泡里；
/// 这里断言标记被消化，块级内容仍可读。
///
/// quiet-v2：消息不再有气泡，Agent 正文直接排在页面上；定位优先走消息 identifier。
final class MarkdownMessageUITests: XCTestCase {
    private let app = XCUIApplication()
    private let originalUserText = "请用 Markdown 展示磁盘信息"
    private let originalMarkdown = """
    ## 磁盘信息

    **磁盘使用情况（df -h）**

    | 文件系统 | 大小 | 使用率 |
    | --- | --- | --- |
    | /dev/sda1 | 194G | 23% |

    - `sda1` — 199.9G 主磁盘
    - 剩余约 **150G** 可用

    ```bash
    df -h
    ```
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-markdown-message"
        app.launchEnvironment["PI_IOS_UI_CLIPBOARD_PROBE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        UIPasteboard.general.string = nil
        app.terminate()
    }

    func testAssistantMarkdownRendersBlocksWithoutRawMarkers() {
        openSession()

        let message = app.descendants(matching: .any)["conversation.agentMessage.markdown-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Agent 消息必须有稳定 identifier")

        XCTAssertTrue(app.staticTexts["磁盘信息"].waitForExistence(timeout: 5), "标题应去掉 ## 标记")
        XCTAssertTrue(app.staticTexts["磁盘使用情况（df -h）"].exists, "粗体段落应去掉 ** 标记")

        XCTAssertTrue(app.staticTexts["/dev/sda1"].exists, "表格单元格应逐格渲染")
        XCTAssertTrue(app.staticTexts["23%"].exists, "表格数值单元格")
        XCTAssertTrue(textContaining("199.9G"), "列表项正文")
        XCTAssertTrue(app.staticTexts["df -h"].exists, "围栏代码块正文")

        for marker in ["**", "| 文件系统 |", "```"] {
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists,
                "原始 Markdown 标记 \(marker) 不应出现在正文里"
            )
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "markdown-message"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 菜单复制必须写入完整原始正文，而不是渲染后的 Markdown 片段；非空正文
    /// 也证明流式/渲染过程不会自动污染剪贴板。
    func testCopyMessageWritesFullOriginalText() {
        openSession()
        UIPasteboard.general.string = nil
        let agentMessage = app.descendants(matching: .any)["conversation.agentMessage.markdown-message"]
        XCTAssertTrue(agentMessage.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForClipboard { $0 == "<empty>" }, "仅渲染消息不得自动复制")

        copyMessage(identifier: "conversation.copyMessage.markdown-message")
        XCTAssertNotNil(waitForClipboard { $0 == self.originalMarkdown }, "必须复制完整 Markdown 原文")

        UIPasteboard.general.string = nil
        let userMessage = app.staticTexts["conversation.userMessage.markdown-user-message"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        copyMessage(identifier: "conversation.copyMessage.markdown-user-message")
        XCTAssertNotNil(waitForClipboard { $0 == self.originalUserText }, "必须复制 user 的非空原始正文")
    }

    /// 无正文不等于 kind、工具名或占位文案。当前若返回非空值，应将实际 UI 表现
    /// 交回 Lead 修 Screen，测试不得把显示 fallback 错认为原始正文。
    func testEmptyToolCopyDoesNotInventRawBody() {
        openSession()
        UIPasteboard.general.string = nil
        let group = app.descendants(matching: .any)["toolGroup.markdown-empty-tool.toggle"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let tool = app.descendants(matching: .any)["toolCard.markdown-empty-tool.toggle"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tool.tap()
        copyMessage(identifier: "conversation.copyMessage.markdown-empty-tool")
        XCTAssertNotNil(
            waitForClipboard { $0 == "<empty>" },
            "无正文工具行不得复制 kind/toolName/占位文案"
        )
    }

    /// 独立复制按钮不得抢占系统长按选择。
    func testUserMessageLongPressPresentsSystemTextSelection() {
        openSession()
        let userMessage = app.staticTexts["conversation.userMessage.markdown-user-message"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        userMessage.press(forDuration: 1.2)
        XCTAssertTrue(waitForSystemSelectionMenu(), "简单长按必须出现系统选择/拷贝菜单")
    }

    func testUserMessageLongPressDragPresentsSystemTextSelection() {
        openSession()
        let userMessage = app.staticTexts["conversation.userMessage.markdown-user-message"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))
        let start = userMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = userMessage.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 1.0, thenDragTo: end)
        XCTAssertTrue(waitForSystemSelectionMenu(), "长按拖动必须出现系统选择/拷贝菜单")
    }

    private func openSession() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.navigationBars["Fixture S1 Alpha"].waitForExistence(timeout: 8))
    }

    private func copyMessage(identifier: String) {
        let copy = app.buttons[identifier]
        XCTAssertTrue(copy.waitForExistence(timeout: 4), "消息必须提供独立“复制消息”按钮")
        copy.tap()
    }

    private func waitForSystemSelectionMenu() -> Bool {
        for label in ["拷贝", "Copy", "复制", "全选", "Select All", "选择", "Select"] {
            let candidate = app.descendants(matching: .any)[label]
            if candidate.waitForExistence(timeout: 0.4) { return true }
        }
        return false
    }

    private func waitForClipboard(
        timeout: TimeInterval = 4,
        matches: @escaping (String) -> Bool
    ) -> String? {
        var matched: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let value = self.app.descendants(matching: .any)["uitest.clipboard.contents"].label
                guard matches(value) else { return false }
                matched = value
                return true
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { return nil }
        return matched
    }

    private func textContaining(_ value: String) -> Bool {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
            .exists
    }
}
