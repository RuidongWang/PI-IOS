import XCTest

/// U-queue：会话排队区的可见性（AC-13.1 / AC-13.2）。
///
/// 夹具 `online-queued-turns` 让 S1 处于运行中，并带两条排队指令：
/// 一条有正文、一条只有附件数。断言队列区标题、正文/附件数回退、取消按钮
/// 与输入栏的排队短提示都可见。
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

        XCTAssertTrue(app.staticTexts["排队中（2）"].waitForExistence(timeout: 8))

        // SwiftUI 会把卡片内多个 Text 合并成无障碍元素，identifier 不一定出现在
        // staticTexts 查询里；以用户实际看到的正文/附件数作为主断言，identifier 作兜底。
        let textRow = app.staticTexts["conversation.queuedTurnText.turn-queued-1"]
        let textLabel = app.staticTexts["检查磁盘使用率"]
        XCTAssertTrue(textRow.waitForExistence(timeout: 5) || textLabel.waitForExistence(timeout: 5))
        if textRow.exists {
            XCTAssertEqual(textRow.label, "检查磁盘使用率")
        }

        // 缺正文时显示附件数，而不是裸 turn id。
        let attachmentRow = app.staticTexts["conversation.queuedTurnText.turn-queued-2"]
        let attachmentLabel = app.staticTexts["2 张图片"]
        XCTAssertTrue(attachmentRow.exists || attachmentLabel.exists)
        if attachmentRow.exists {
            XCTAssertTrue(attachmentRow.label.contains("2 张图片"))
            XCTAssertFalse(attachmentRow.label.contains("turn-queued-2"))
        }

        // 两条排队项都可以取消；运行中时发送会排队，输入栏上方有一行短提示。
        let cancelOne = app.buttons["conversation.cancelQueued.turn-queued-1"]
        let cancelTwo = app.buttons["conversation.cancelQueued.turn-queued-2"]
        XCTAssertTrue(cancelOne.exists || app.buttons.matching(identifier: "取消").count >= 2)
        XCTAssertTrue(cancelTwo.exists || app.buttons.matching(identifier: "取消").count >= 2)
        let hintByIdentifier = app.staticTexts["conversation.queueHint"]
        let hintByLabel = app.staticTexts["当前 turn 运行中，发送将排队"]
        XCTAssertTrue(hintByIdentifier.exists || hintByLabel.exists)
    }
}
