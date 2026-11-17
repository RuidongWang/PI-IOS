import XCTest

/// The DEBUG source only supplies attachment/read bytes. Both thumbnail and
/// detail use the real shared loader, validation, ImageIO decode and SwiftUI UI.
final class StabilityAttachmentUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "stability-images"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testThumbnailOriginalDetailCloseAndSessionSwitchDoNotRetainOldDetail() {
        openSession("S1", fromConversation: false)
        let thumbnail = element("conversation.attachment.stability-image-1")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 10), "必须经过生产 loader 生成缩略图")
        XCTAssertTrue(thumbnail.isHittable)
        thumbnail.tap()

        let detail = element("conversation.attachment.detailImage")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "点缩略图后应按需加载详情")
        XCTAssertTrue(detail.isHittable)
        let share = app.buttons["conversation.attachment.shareOriginal"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "仅验证原质量分享入口；系统分享面板另行手工验证")
        let dimensions = app.staticTexts["conversation.attachment.debugDetailContent"].label
        XCTAssertTrue(dimensions.contains("width=2048"), "详情必须从原内容解码，不能直接展示 1024px 缩略图：\(dimensions)")
        XCTAssertTrue(dimensions.contains("height=768"))
        app.buttons["conversation.attachment.closeDetail"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertFalse(share.exists)

        openSession("S2")
        XCTAssertTrue(app.staticTexts["Fixture history for S2"].waitForExistence(timeout: 5))
        XCTAssertFalse(detail.exists, "切换会话后旧原图详情不能残留")
        XCTAssertFalse(share.exists)
        XCTAssertFalse(thumbnail.exists, "另一个会话不能显示旧附件")

        openSession("S1")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 8))
        XCTAssertFalse(detail.exists, "重新进入会话不应自动打开上次详情")
        XCTAssertFalse(share.exists)
        thumbnail.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "关闭后按需重新查看仍然可用")
        XCTAssertTrue(share.exists)
        app.buttons["conversation.attachment.closeDetail"].tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func openSession(_ id: String, fromConversation: Bool = true) {
        if fromConversation { app.buttons["打开侧边栏"].tap() }
        let row = app.buttons["sidebar.session.\(id)"]
        if !row.waitForExistence(timeout: 2), app.buttons["打开侧边栏"].exists {
            app.buttons["打开侧边栏"].tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
    }
}
