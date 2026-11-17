import XCTest

final class ExtensionsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app.terminate() }

    func testSessionLoadedFailureDetailAndToolAvailability() {
        launch("extensions-loaded")
        openSessionExtensions()
        let browser = app.buttons["extensions.entry.browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 8))
        XCTAssertTrue(browser.label.contains("已加载"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "会话扩展加载结果"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let helper = app.buttons["extensions.entry.helper"]
        XCTAssertTrue(helper.label.contains("加载失败"))
        helper.tap()
        XCTAssertTrue(app.navigationBars["扩展详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "缺少依赖")).firstMatch.exists)
        let copy = app.buttons["extensions.copyDiagnostics"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.label.contains("已复制"))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        browser.tap()
        XCTAssertTrue(app.staticTexts["browser_search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["采样时未启用"].exists)
        XCTAssertTrue(app.staticTexts["尚未接入手机调用"].exists)
    }

    func testSettingsInventoryAndCopyPath() {
        launch("extensions-loaded")
        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.root.settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        let entry = app.buttons["settings.extensions"]
        scrollTo(entry)
        entry.tap()
        XCTAssertTrue(app.navigationBars["扩展"].waitForExistence(timeout: 5))
        let browser = app.buttons["extensions.entry.browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 8))
        browser.tap()
        let copy = app.buttons["extensions.copyPath"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.label.contains("已复制入口路径"))
        XCTAssertFalse(app.switches.firstMatch.exists, "V1 is read-only")
    }

    func testDisabledEmptyInventoryIsDistinctFromUnsupportedHost() {
        launch("extensions-empty")
        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.root.settings"].tap()
        let entry = app.buttons["settings.extensions"]
        scrollTo(entry)
        entry.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "此服务器未启用用户扩展加载")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "尚未配置用户扩展")).firstMatch.exists)
        XCTAssertFalse(app.buttons["extensions.entry.browser"].exists)
    }

    func testOldHostHasExplicitUnsupportedState() {
        launch("extensions-unsupported")
        openSessionExtensions()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "此服务器版本不支持查看扩展")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["extensions.entry.browser"].exists)
    }

    func testUnrunSessionIsNotZeroLoaded() {
        launch("extensions-never-run")
        openSessionExtensions()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "首次运行后可查看加载结果")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["extensions.entry.browser"].exists)
    }

    func testOfflineConfigurationRemainsReadableWithHistoricalLabel() {
        launch("extensions-offline")
        openSessionExtensions()
        XCTAssertTrue(app.buttons["extensions.entry.browser"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "上次读取的数据")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["上次记录的加载结果"].exists)
        XCTAssertFalse(app.buttons["extensions.listRetry"].exists)
    }

    func testReadFailureProvidesRetryWithoutFalseEmptyState() {
        launch("extensions-error")
        openSessionExtensions()
        let retry = app.buttons["extensions.listRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["extensions.entry.browser"].exists)
    }

    private func launch(_ scenario: String) {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sidebar = app.buttons["打开侧边栏"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        if !app.buttons["sidebar.close"].exists { sidebar.tap() }
        let session = app.buttons[scenario == "extensions-offline" ? "sidebar.cachedSession.S1" : "sidebar.session.S1"]
        XCTAssertTrue(session.waitForExistence(timeout: 8))
        session.tap()
        XCTAssertTrue(app.buttons["composer.modelChip"].waitForExistence(timeout: 8))
    }

    private func openSessionExtensions() {
        let menu = app.buttons["会话操作"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["会话配置"].tap()
        let entry = app.buttons["conversation.config.extensions"]
        scrollTo(entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["会话扩展"].waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
}
