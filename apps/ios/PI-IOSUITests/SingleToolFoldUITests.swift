import XCTest

/// 单次工具调用与轮次生命周期内的折叠：
/// 最终回复之前的所有工具调用（一次或多次）和中间过程都合并成一条可折叠分组，
/// 最终回复始终留在分组之外可见。
///
/// quiet-v2：折叠行的数量/工具名/状态改由 identifier 定位，文案可继续收敛。
final class SingleToolFoldUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testSingleToolCallStartsCollapsedAndFinalReplyStaysVisible() {
        launch("online-single-tool-turn")

        let group = app.descendants(matching: .any)["toolGroup.single_tool.toggle"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertEqual(group.value as? String, "collapsed", "单次工具调用也必须默认折叠")
        XCTAssertEqual(app.staticTexts["toolGroup.single_tool.title"].label, "1 次工具调用")
        XCTAssertEqual(app.staticTexts["toolGroup.single_tool.status"].label, "已完成")
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.agentMessage.single_final"].exists,
            "最终回复必须留在分组之外"
        )

        let child = app.descendants(matching: .any)["toolCard.single_tool.toggle"]
        XCTAssertFalse(child.exists, "折叠时不应渲染组内工具行")

        group.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 2), "展开分组后应看到工具行")
        XCTAssertEqual(app.staticTexts["toolCard.single_tool.title"].label, "bash")
        child.tap()
        XCTAssertEqual(app.staticTexts["toolCard.single_tool.preview"].label, "single-output")

        group.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 2), "再次点击分组应整体收起")
        XCTAssertEqual(group.value as? String, "collapsed")
        XCTAssertTrue(app.descendants(matching: .any)["conversation.agentMessage.single_final"].exists)
    }

    func testRunningTurnStaysFoldableBeforeFinalReplyArrives() {
        launch("online-running-tool-turn")

        let group = app.descendants(matching: .any)["toolGroup.running_tool.toggle"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertEqual(group.value as? String, "collapsed", "运行中的轮次也必须能折叠")
        XCTAssertEqual(app.staticTexts["toolGroup.running_tool.title"].label, "1 次工具调用")
        XCTAssertEqual(
            app.staticTexts["toolGroup.running_tool.status"].label,
            "运行中",
            "折叠行要表达执行进度"
        )

        group.tap()
        let child = app.descendants(matching: .any)["toolCard.running_tool.toggle"]
        XCTAssertTrue(child.waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["toolCard.running_tool.status"].label, "运行中")
        child.tap()

        let emptyBody = app.staticTexts["toolCard.running_tool.emptyBody"]
        XCTAssertTrue(emptyBody.waitForExistence(timeout: 2))
        XCTAssertEqual(emptyBody.label, "执行中")

        group.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 2), "收起分组时组内状态不影响折叠")
        XCTAssertEqual(group.value as? String, "collapsed")
    }

    func testInterleavedMessagesAndToolsFoldIntoOneGroup() {
        launch("online-interleaved-tool-turn")

        let group = app.descendants(matching: .any)["toolGroup.inter_tool_1.toggle"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertEqual(group.value as? String, "collapsed")
        XCTAssertEqual(
            app.staticTexts["toolGroup.inter_tool_1.title"].label,
            "2 次工具调用",
            "同一轮内被消息隔开的调用要合成一组"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.agentMessage.inter_final"].exists,
            "最终回复必须可见"
        )

        let intermediate = app.staticTexts["toolGroup.message.inter_message"]
        XCTAssertFalse(intermediate.exists, "折叠时中间过程消息不应渲染")

        group.tap()
        XCTAssertTrue(intermediate.waitForExistence(timeout: 2), "展开后应看到工具之间的过渡消息")
        XCTAssertEqual(intermediate.label, "磁盘看完了，接着看内存。")
        XCTAssertTrue(app.descendants(matching: .any)["toolCard.inter_tool_1.toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["toolCard.inter_tool_2.toggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["conversation.agentMessage.inter_final"].exists)

        group.tap()
        XCTAssertTrue(intermediate.waitForNonExistence(timeout: 2))
        XCTAssertEqual(group.value as? String, "collapsed")
    }

    private func launch(_ scenario: String) {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
    }
}
