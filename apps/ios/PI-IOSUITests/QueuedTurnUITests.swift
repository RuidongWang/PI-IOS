import XCTest

/// U-queue：会话排队区的可见性（AC-13.1 / AC-13.2）。
///
/// 夹具 `online-queued-turns` 让 S1 处于运行中，并带两条排队指令：
/// 一条有正文、一条只有附件数。断言队列区、正文/附件数回退、取消按钮可见；
/// 输入框为空且 turn 运行时发送按钮应变为中止按钮。
///
/// quiet-v2：排队数量同时常驻在状态条（`conversation.queuedNotice`），
/// 卡片上不再写「当前 turn 结束后自动开始」这类行为解释。
final class QueuedTurnUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-queued-turns"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testQueuedTurnsShowTextAttachmentFallbackCancelAndQueueHint() {
        app.buttons["sidebar.session.S1"].tap()

        XCTAssertTrue(
            app.staticTexts["conversation.queueHeader"].waitForExistence(timeout: 8),
            "排队区标题必须常驻"
        )
        // 现行设计：区块标题只标识待发送内容，数量由常驻状态条表达。
        XCTAssertEqual(app.staticTexts["conversation.queueHeader"].label, "待发送")

        // 排队数量在常驻状态条里也要能一眼看到，不依赖滚动位置。
        XCTAssertTrue(app.staticTexts["conversation.queuedNotice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["conversation.queuedNotice"].label.contains("2"))

        // 缺正文时显示附件数，而不是裸 turn id。
        let textRow = app.staticTexts["conversation.queuedTurnText.turn-queued-1"]
        XCTAssertTrue(textRow.waitForExistence(timeout: 5))
        XCTAssertEqual(textRow.label, "检查磁盘使用率")

        let attachmentRow = app.staticTexts["conversation.queuedTurnText.turn-queued-2"]
        XCTAssertTrue(attachmentRow.exists)
        XCTAssertTrue(attachmentRow.label.contains("2 张图片"))
        XCTAssertFalse(attachmentRow.label.contains("turn-queued-2"))

        // 两条排队项都可以取消。
        XCTAssertTrue(app.buttons["conversation.cancelQueued.turn-queued-1"].exists)
        XCTAssertTrue(app.buttons["conversation.cancelQueued.turn-queued-2"].exists)

        // 输入框为空 + turn 运行中：发送按钮变为中止按钮。
        XCTAssertTrue(
            app.buttons["conversation.interrupt"].waitForExistence(timeout: 5),
            "空输入且有 turn 运行时必须显示中止按钮"
        )
        XCTAssertFalse(app.buttons["conversation.send"].exists)
        XCTAssertFalse(app.staticTexts["conversation.queueHint"].exists)
        XCTAssertFalse(app.staticTexts["当前 turn 运行中，发送将排队"].exists)
        XCTAssertFalse(app.staticTexts["当前 turn 结束后自动开始"].exists, "行为解释不得再出现在卡片上")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "conversation-queued-turns"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
