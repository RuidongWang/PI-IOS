import XCTest

/// Agent 消息的 Markdown 渲染。
///
/// 夹具 `online-markdown-message` 给出模型最常见的输出形态：`##` 标题、`**粗体**`、
/// 行内代码、管道表格、列表与围栏代码块。纯 `Text` 会把标记原样画在气泡里；
/// 这里断言标记被消化，块级内容仍可读。
final class MarkdownMessageUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-markdown-message"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testAssistantMarkdownRendersBlocksWithoutRawMarkers() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.navigationBars["Fixture S1 Alpha"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["磁盘信息"].waitForExistence(timeout: 5), "标题应去掉 ## 标记")
        XCTAssertTrue(app.staticTexts["磁盘使用情况（df -h）"].exists, "粗体段落应去掉 ** 标记")

        XCTAssertTrue(app.staticTexts["/dev/sda1"].exists, "表格单元格应逐格渲染")
        XCTAssertTrue(app.staticTexts["23%"].exists, "表格数值单元格")
        XCTAssertTrue(textContaining("199.9G"), "列表项正文")
        XCTAssertTrue(app.staticTexts["df -h"].exists, "围栏代码块正文")

        for marker in ["**", "| 文件系统 |", "```"] {
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists,
                "原始 Markdown 标记 \(marker) 不应出现在气泡里"
            )
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "markdown-message"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func textContaining(_ value: String) -> Bool {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
            .exists
    }
}
