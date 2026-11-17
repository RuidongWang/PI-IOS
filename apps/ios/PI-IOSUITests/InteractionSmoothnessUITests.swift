import XCTest

final class InteractionSmoothnessUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app.terminate() }

    func testDelayedOpenClosesSidebarAndHidesPreviousSessionControls() {
        launch()
        open("S2", fromSidebar: true)
        XCTAssertTrue(app.navigationBars["Fixture S2 Beta"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 1))
        XCTAssertTrue(element("conversation.sessionOpening").exists)
        XCTAssertFalse(element("conversation.composer").exists)
        XCTAssertTrue(element("conversation.previewMessage.preview-S2").exists)
        XCTAssertFalse(element("conversation.agentMessage.reading-S1-040").exists)
        XCTAssertTrue(element("conversation.composer").waitForExistence(timeout: 8))
        XCTAssertFalse(element("conversation.sessionOpening").exists)
    }

    func testFailedOpenKeepsDestinationAndRetrySucceeds() {
        launch(failingSession: "S2")
        open("S2", fromSidebar: true)
        let retry = app.buttons["conversation.retrySessionOpen"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Fixture S2 Beta"].exists)
        XCTAssertTrue(element("conversation.sessionOpenError").exists)
        XCTAssertFalse(element("conversation.composer").exists)
        XCTAssertTrue(element("conversation.previewMessage.preview-S2").exists)
        retry.tap()
        XCTAssertTrue(element("conversation.composer").waitForExistence(timeout: 8))
        XCTAssertFalse(retry.exists)
    }

    func testLatestSelectionWinsWhenOpeningAnotherSession() {
        launch()
        open("S2", fromSidebar: true)
        open("S1")
        XCTAssertTrue(app.navigationBars["Fixture S1 Alpha"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("conversation.composer").waitForExistence(timeout: 8))
        XCTAssertFalse(element("conversation.agentMessage.reading-S2-040").exists)
    }

    func testComposerButtonsHaveAtLeast44PointHitTargets() {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-model-config"
        app.launch()
        if app.buttons["sidebar.close"].waitForExistence(timeout: 3) { app.buttons["sidebar.close"].tap() }
        let send = app.buttons["conversation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let photos = app.buttons["添加图片附件"]
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        XCTAssertGreaterThanOrEqual(photos.frame.width, 44)
        XCTAssertGreaterThanOrEqual(photos.frame.height, 44)
    }

    func testSubmittingShowsProgressAndFailurePreservesDraftForRetry() {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "interaction-submit"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if !app.buttons["sidebar.session.S1"].waitForExistence(timeout: 3) {
            app.buttons["打开侧边栏"].tap()
        }
        app.buttons["sidebar.session.S1"].tap()
        let composer = app.textFields["conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Keep my instruction")
        let send = app.buttons["conversation.send"]
        XCTAssertTrue(waitUntil { send.isEnabled })
        send.tap()
        XCTAssertTrue(element("conversation.submitting").waitForExistence(timeout: 2))
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(send.label, "正在提交")
        XCTAssertTrue(waitUntil { send.isEnabled })
        XCTAssertEqual(composer.value as? String, "Keep my instruction")
        XCTAssertTrue(element("conversation.errorNotice").exists)
        send.tap()
        XCTAssertTrue(element("conversation.submitting").waitForExistence(timeout: 2))
    }

    func testLargeCachedPreviewStartsAt80AndExpandsWithoutDiscardingHistory() {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "interaction-large-preview"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S2"].waitForExistence(timeout: 8))
        open("S2", fromSidebar: true)
        XCTAssertTrue(app.buttons["conversation.retrySessionOpen"].waitForExistence(timeout: 8))
        let more = app.buttons["conversation.loadMoreCachedPreview"]
        XCTAssertTrue(more.exists)
        XCTAssertEqual((more.value as? String)?.replacingOccurrences(of: ",", with: ""), "已显示 80 条，共 3500 条")
        for _ in 0..<12 {
            if more.isHittable { break }
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(waitUntil { (more.value as? String)?.replacingOccurrences(of: ",", with: "") == "已显示 160 条，共 3500 条" })
        XCTAssertTrue(app.navigationBars["Fixture S2 Beta"].exists)
        XCTAssertFalse(element("conversation.composer").exists)
    }

    func testCachedPreviewUsesMessageStylingAndCollapsedToolsAcrossBackground() {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "interaction-cache-render"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S2"].waitForExistence(timeout: 8))
        open("S2", fromSidebar: true)
        XCTAssertTrue(app.buttons["conversation.retrySessionOpen"].waitForExistence(timeout: 8))
        XCTAssertTrue(element("conversation.userMessage.preview-user").exists)
        XCTAssertFalse(app.staticTexts["message（无文本内容）"].exists)
        XCTAssertFalse(element("conversation.previewMessage.preview-empty").exists)
        let group = element("toolGroup.preview-tool.toggle")
        XCTAssertTrue(group.exists)
        XCTAssertEqual(group.value as? String, "collapsed")
        XCTAssertFalse(element("toolCard.preview-tool.preview").exists)
        XCTAssertTrue(app.staticTexts["同步完成"].exists, "Markdown markers must not appear as raw text")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cached preview with collapsed long tool output"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        group.tap()
        let tool = element("toolCard.preview-tool.toggle")
        XCTAssertTrue(tool.waitForExistence(timeout: 3))
        tool.tap()
        XCTAssertTrue(element("toolCard.preview-tool.truncation").waitForExistence(timeout: 3))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["conversation.retrySessionOpen"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }

    private func launch(failingSession: String? = nil) {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "interaction-smoothness"
        if let failingSession { app.launchEnvironment["PI_IOS_UI_FAIL_OPEN"] = failingSession }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S2"].waitForExistence(timeout: 8))
    }

    private func open(_ id: String, fromSidebar: Bool = false) {
        if !fromSidebar { app.buttons["打开侧边栏"].tap() }
        let row = app.buttons["sidebar.session.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
}
