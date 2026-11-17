import XCTest

/// 工具卡片正文（回归：卡片只显示「服务器没有返回工具输出正文。」）。
///
/// 夹具 `online-tool-result-body` 用契约 §7.2 的真实载荷形状给出两条工具条目：
/// 一条已完成（正文只在 `content.result.content[].text` 里）、一条运行中（尚无输出）。
/// 这里断言它们在真实界面里分别渲染成正文与「执行中」，并确认不再出现旧的空正文断言文案。
///
/// quiet-v2：标题就是工具名（图标已经说明是工具），定位走 identifier。
final class ToolCardBodyUITests: XCTestCase {
    private let app = XCUIApplication()
    /// 旧文案：把「还没输出」说成「服务器没有返回正文」会让用户以为结果丢了。
    private let legacyEmptyBodyNotice = "服务器没有返回工具输出正文。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-tool-result-body"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testCompletedToolCardShowsResultBodyInsteadOfEmptyNotice() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let title = app.staticTexts["toolCard.call_done.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "bash", "标题就是工具名，不再加「工具 · 」前缀")
        XCTAssertEqual(app.staticTexts["toolCard.call_done.status"].label, "已完成")

        let toggle = app.descendants(matching: .any)["toolCard.call_done.toggle"]
        XCTAssertTrue(toggle.exists)
        toggle.tap()

        let preview = app.staticTexts["toolCard.call_done.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        XCTAssertEqual(preview.label, "hello-from-tool")
        XCTAssertFalse(
            app.staticTexts["toolCard.call_done.emptyBody"].exists,
            "有正文时不得再显示空正文提示"
        )
        XCTAssertFalse(app.staticTexts[legacyEmptyBodyNotice].exists)
    }

    func testRunningToolCardSaysRunningInsteadOfEmptyNotice() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let toggle = app.descendants(matching: .any)["toolCard.call_running.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        // 运行中的条目在夹具里没有 status 字段：状态标签不渲染，也不该硬编码「运行中」。
        XCTAssertEqual(app.staticTexts["toolCard.call_running.title"].label, "bash")
        toggle.tap()

        let emptyBody = app.staticTexts["toolCard.call_running.emptyBody"]
        XCTAssertTrue(emptyBody.waitForExistence(timeout: 2))
        XCTAssertEqual(emptyBody.label, "执行中")
        XCTAssertFalse(
            app.staticTexts[legacyEmptyBodyNotice].exists,
            "运行中的工具不能声称服务器没有返回正文"
        )
    }
}
