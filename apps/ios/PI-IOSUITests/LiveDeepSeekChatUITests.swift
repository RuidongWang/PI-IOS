import XCTest

final class LiveDeepSeekChatUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 门禁必须在 `launch()` 之前：应用启动会读取真实状态并自动连接已配对 host，
    /// 放到测试方法里再跳过已经产生了真实网络访问。
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["PI_IOS_DEEPSEEK_CHAT"] == "1" else {
            throw XCTSkip("Set PI_IOS_DEEPSEEK_CHAT=1 after importing the rotated DeepSeek key.")
        }
        app = XCUIApplication()
        app.launch()
    }

    func testLiveDeepSeekChatWithRotatedKey() throws {
        showRoot("项目")
        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rev "))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        let modelChip = app.buttons["composer.modelChip"]
        XCTAssertTrue(modelChip.waitForExistence(timeout: 15))
        modelChip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 10))

        // Which model to pick is provider-specific: DeepSeek official exposes
        // `deepseek-chat`, an older self-hosted provider exposed a different id.
        // Default to the official id; override with PI_IOS_DEEPSEEK_MODEL.
        let modelName =
            ProcessInfo.processInfo.environment["PI_IOS_DEEPSEEK_MODEL"] ?? "deepseek-chat"
        let model = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", modelName))
            .firstMatch
        XCTAssertTrue(
            model.waitForExistence(timeout: 10),
            "The DeepSeek provider must expose a model matching \"\(modelName)\" (set PI_IOS_DEEPSEEK_MODEL to change)."
        )
        model.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForNonExistence(timeout: 10))

        // The marker is unique per run so a previous run's history cannot satisfy the
        // assertion, and the reply query excludes the user bubble (which contains the
        // whole prompt). Previously a `CONTAINS` over any static text matched the user's
        // own message even when no assistant reply ever arrived.
        let marker = "LIVE-DEEPSEEK-KEY-OK-\(UUID().uuidString.prefix(8))"
        let prompt = "Reply with exactly \(marker)"
        // Prefer the stable identifier: the composer's accessibility type flips
        // between TextField/TextView, so a label-only query is flaky.
        let composer = app.textFields["conversation.composer"].exists
            ? app.textFields["conversation.composer"]
            : app.textFields["给 Agent 的指令"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["发送"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", prompt))
                .firstMatch
                .waitForExistence(timeout: 10),
            "The typed prompt must appear in the conversation before waiting for a reply."
        )
        let reply = app.staticTexts
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND NOT (label CONTAINS %@)",
                    marker,
                    "Reply with exactly"
                )
            )
            .firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 90),
            "The rotated DeepSeek key must produce a real assistant response."
        )
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }
}
