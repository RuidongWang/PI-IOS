import XCTest

/// 大工具结果：默认折叠、展开后走有界预览，截断提示给出原始体积与预览体积。
///
/// quiet-v2：定位走 identifier，正文与提示文案可独立演进。
final class LargeToolResultUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-large-tool-result"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testLargeToolResultStartsCollapsedAndUsesBoundedPreview() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let toggle = app.descendants(matching: .any)["toolCard.large-tool.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["toolCard.large-tool.title"].exists)

        let preview = app.staticTexts["toolCard.large-tool.preview"]
        XCTAssertFalse(preview.exists, "工具结果必须默认折叠，不能首帧布局完整正文")

        toggle.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["toolCard.large-tool.body"].exists)

        let notice = app.staticTexts["toolCard.large-tool.truncation"]
        XCTAssertTrue(notice.waitForExistence(timeout: 2))
        XCTAssertTrue(notice.label.contains("4.0 MB"))
        XCTAssertTrue(notice.label.contains("32.0 KB"))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "large-tool-result-expanded"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
