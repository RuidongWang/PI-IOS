import XCTest

/// 置顶顺序必须在未打开任何会话的初始活动顺序下验证。
/// 主回归的 SID-01 已打开 S1，会改变后续活动排序，因此这里保持独立夹具启动。
final class SidebarPinUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-two-sessions"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.project.fixture-online-project"].waitForExistence(timeout: 5))
        assertOrder("S2", before: "S1")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testPinControlsKeepInsertionOrderAndUnpinRestoresActivityOrder() {
        XCTAssertEqual(pin("S1").label, "置顶会话")
        XCTAssertEqual(pin("S2").label, "置顶会话")

        pin("S1").tap()
        XCTAssertEqual(pin("S1").label, "取消置顶")
        assertOrder("S1", before: "S2")

        pin("S2").tap()
        XCTAssertEqual(pin("S2").label, "取消置顶")
        assertOrder("S1", before: "S2")

        pin("S1").tap()
        XCTAssertEqual(pin("S1").label, "置顶会话")
        assertOrder("S2", before: "S1")
        pin("S2").tap()
        XCTAssertEqual(pin("S2").label, "置顶会话")
        assertOrder("S2", before: "S1")
    }

    private func row(_ id: String) -> XCUIElement { app.buttons["sidebar.session.\(id)"] }
    private func pin(_ id: String) -> XCUIElement { app.buttons["sidebar.pin.\(id)"] }

    private func assertOrder(_ first: String, before second: String, file: StaticString = #filePath, line: UInt = #line) {
        let upper = row(first)
        let lower = row(second)
        XCTAssertTrue(upper.exists, file: file, line: line)
        XCTAssertTrue(lower.exists, file: file, line: line)
        XCTAssertLessThan(upper.frame.midY, lower.frame.midY, "Expected \(first) above \(second)", file: file, line: line)
    }
}
