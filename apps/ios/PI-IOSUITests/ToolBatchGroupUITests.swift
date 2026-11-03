import XCTest

/// 批量工具调用折叠：连续 6 次工具调用汇总为一条默认折叠的分组，
/// 展开后逐条显示紧凑工具行，再点单条查看完整结果；最终回复不受折叠影响。
final class ToolBatchGroupUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-tool-batch"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testBatchToolsStartCollapsedAndExpandOnDemand() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let group = app.descendants(matching: .any)["toolGroup.batch_tool_1.toggle"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        XCTAssertEqual(group.value as? String, "collapsed", "分组默认必须折叠")

        XCTAssertTrue(app.staticTexts["6 次工具调用"].exists, "折叠行要给出数量提示")
        XCTAssertTrue(app.staticTexts["bash ×6"].exists, "折叠行要给出工具名汇总")
        XCTAssertTrue(app.staticTexts["已完成"].exists, "折叠行要给出组状态")

        let child = app.descendants(matching: .any)["toolCard.batch_tool_1.toggle"]
        XCTAssertFalse(child.exists, "折叠时不应渲染组内工具行")
        XCTAssertTrue(app.staticTexts["以下是 CPU 分析："].exists, "最终回复必须保持展开")
        snapshot("tool-batch-collapsed")

        group.tap()
        XCTAssertTrue(child.waitForExistence(timeout: 2), "展开分组后应看到组内工具行")
        snapshot("tool-batch-expanded")

        child.tap()
        let preview = app.staticTexts["toolCard.batch_tool_1.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        XCTAssertEqual(preview.label, "batch-output-1")

        group.tap()
        XCTAssertTrue(child.waitForNonExistence(timeout: 2), "再次点击分组应整体收起")
        XCTAssertEqual(group.value as? String, "collapsed")
        XCTAssertTrue(app.staticTexts["以下是 CPU 分析："].exists)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
