import XCTest

/// 真实服务器验证：确认安装页会解析 GitHub 最新稳定发布（失败时回退并在界面说明）。
/// 默认跳过；模拟器里需已有已保存凭证的服务器记录，并设置 `PI_IOS_LIVE_RELEASE_INSTALL=1`。
final class ServerInstallLatestUITests: XCTestCase {
    private let timeout: TimeInterval = 20 * 60

    func testInstallsLatestStableReleaseOnRealServer() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PI_IOS_LIVE_RELEASE_INSTALL"] == "1",
            "设置 PI_IOS_LIVE_RELEASE_INSTALL=1 才运行真实服务器安装"
        )
        let app = XCUIApplication()
        app.launch()

        openSettings(app)
        let hostRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "134.185.91.116")
        ).firstMatch
        guard hostRow.waitForExistence(timeout: 15) else {
            throw XCTSkip("模拟器里没有已保存的真实服务器记录")
        }
        hostRow.tap()

        let installRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "安装或修复 PI-adaptor")
        ).firstMatch
        scrollUntilHittable(app, installRow)
        XCTAssertTrue(installRow.waitForExistence(timeout: 10), "找不到安装入口")
        installRow.tap()
        XCTAssertTrue(app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 10))

        let policy = app.staticTexts["installHost.releasePolicy"]
        XCTAssertTrue(policy.waitForExistence(timeout: 10), "安装页应说明自动匹配最新发布")
        XCTAssertTrue(policy.label.contains("最新稳定发布"), policy.label)
        XCTAssertTrue(policy.label.contains("回退"), policy.label)

        let start = app.buttons["开始安装"]
        scrollUntilHittable(app, start)
        XCTAssertTrue(start.waitForExistence(timeout: 10), "找不到开始安装按钮")
        start.tap()

        // 解析完成后界面必须显示本次目标版本与来源。
        let resolved = app.staticTexts["installHost.resolvedRelease"]
        XCTAssertTrue(resolved.waitForExistence(timeout: 120), "未显示解析到的目标版本")
        XCTAssertTrue(resolved.label.contains("0.0.1"), resolved.label)
        if resolved.label.contains("GitHub 最新稳定发布") {
            print("LIVE_RELEASE_SOURCE=latest label=\(resolved.label)")
        } else {
            // 代理出口的 GitHub API 配额用尽时走回退；记录后继续验证真机安装。
            print("LIVE_RELEASE_SOURCE=fallback label=\(resolved.label)")
            XCTAssertTrue(
                app.descendants(matching: .any)["installHost.fallbackNotice"].waitForExistence(timeout: 10),
                "回退时必须显示原因横幅"
            )
        }

        let success = app.staticTexts["安装与设备验证完成"]
        let failure = app.staticTexts["安装未完成"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if success.exists { return }
            if failure.exists {
                let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
                XCTFail("真实服务器安装失败：\n\(texts)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTFail("等待安装结果超时")
    }

    private func openSettings(_ app: XCUIApplication) {
        if app.navigationBars["设置"].exists { return }
        if !app.buttons["设置"].exists, app.buttons["打开侧边栏"].exists {
            app.buttons["打开侧边栏"].tap()
        }
        let settings = app.buttons["设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "找不到设置入口")
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
    }

    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp()
        }
    }
}
