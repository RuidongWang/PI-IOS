import XCTest

final class LiveChatUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 门禁必须在 `launch()` 之前：应用启动会读取真实状态并自动连接已配对 host，
    /// 放到测试方法里再跳过已经产生了真实网络访问。
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["PI_IOS_LIVE_CHAT"] == "1" else {
            throw XCTSkip("Set PI_IOS_LIVE_CHAT=1 after importing a provider whose key works.")
        }
        app = XCUIApplication()
        app.launch()
    }

    func testLiveChatRoundTrip() throws {
        showRoot("项目")
        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rev "))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        if session.waitForExistence(timeout: 10) {
            session.tap()
        } else {
            // 0.0.4 起「新建会话」直接进入会话页：服务器上没有历史会话时用它作为聊天对象，
            // 顺便覆盖首条指令后 AI 生成标题的新链路。
            let create = app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", "新建会话"))
                .firstMatch
            for _ in 0..<4 where !create.exists {
                app.swipeUp()
            }
            XCTAssertTrue(create.waitForExistence(timeout: 10), "项目页必须能新建会话")
            create.tap()
        }

        let modelChip = app.buttons["composer.modelChip"]
        XCTAssertTrue(modelChip.waitForExistence(timeout: 15))
        modelChip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 10))

        // 模型由已导入的 provider 决定：默认取环境里的 PI_IOS_LIVE_LLM_MODEL。
        let modelName = ProcessInfo.processInfo.environment["PI_IOS_LIVE_LLM_MODEL"] ?? ""
        let model = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", modelName))
            .firstMatch
        XCTAssertTrue(
            model.waitForExistence(timeout: 10),
            "The imported provider must expose a model matching \"\(modelName)\" (set PI_IOS_LIVE_LLM_MODEL)."
        )
        model.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForNonExistence(timeout: 10))

        // The marker is unique per run so a previous run's history cannot satisfy the
        // assertion, and the reply query excludes the user bubble (which contains the
        // whole prompt). Previously a `CONTAINS` over any static text matched the user's
        // own message even when no assistant reply ever arrived.
        let marker = "LIVE-CHAT-KEY-OK-\(UUID().uuidString.prefix(8))"
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
            "The imported provider key must produce a real assistant response."
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
