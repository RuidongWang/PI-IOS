import XCTest

final class InstallRecoveryUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    // 这三条接管了主回归套件里的 INS-02/03/04：同一夹具、同一失败页，
    // 不再在主套件重复启动三次 App。独有断言已合并到这里。

    func testDownloadFailureOffersDownloadRetryAndProxyHint() {
        openInstallFailure("download-twice")
        XCTAssertTrue(app.staticTexts["installHost.proxyHint"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["安装失败详情见下方「故障分类」。"]
                .waitForExistence(timeout: 5),
            "关闭弹框后就近保留失败入口"
        )
        XCTAssertTrue(anyElement("download-failed").exists, "下载失败分类")
        XCTAssertTrue(
            app.staticTexts["UI fixture：下载在 42% 中断。"].waitForExistence(timeout: 5),
            "关闭弹框不得清除页面上的故障详情"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "已连续失败 2 次"))
                .firstMatch
                .exists,
            "连续失败提示"
        )
        XCTAssertEqual(app.buttons["installHost.start"].label, "重试下载")
        XCTAssertTrue(app.buttons["installHost.back"].exists)
        app.buttons["installHost.back"].tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.alerts["安装未完成"].waitForExistence(timeout: 1),
            "关闭失败弹框后离开页面不得再次弹出同一失败"
        )
    }

    func testPairFailureOffersPairOnlyRecoveryCopy() {
        openInstallFailure("pair-expired")
        XCTAssertTrue(anyElement("pair-failed").exists, "配对失败分类")
        XCTAssertTrue(
            app.staticTexts["配对失败后服务器已恢复原状态；重试会重新启动配对。"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.buttons["installHost.start"].label, "重新配对")
        XCTAssertTrue(app.buttons["installHost.back"].exists)
    }

    func testSudoFailureOffersInlineReauthorization() {
        openInstallFailure("sudo-failure")
        XCTAssertTrue(anyElement("unit-failed").exists, "unit 失败分类")
        XCTAssertTrue(app.secureTextFields["installHost.sudoCredential"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["installHost.retrySudo"].exists)
        XCTAssertFalse(app.buttons["installHost.retrySudo"].isEnabled, "空密码禁用重新授权")
        XCTAssertTrue(app.buttons["installHost.back"].exists)
        XCTAssertFalse(app.buttons["installHost.start"].isEnabled, "unit-failed 主按钮禁用")
    }

    /// 失败分类行在不同布局里可能是 Text / Button / otherElement，按标识或标签兜底查找。
    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func openInstallFailure(_ failure: String) {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "offline-two-hosts"
        app.launchEnvironment["PI_IOS_INSTALL_FIXTURE_FAILURE"] = failure
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        if app.buttons["sidebar.close"].waitForExistence(timeout: 5) {
            app.buttons["sidebar.close"].tap()
            XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
        }
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))

        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture PI-adaptor B")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5))

        let install = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "安装或修复 PI-adaptor")
        ).firstMatch
        for _ in 0..<8 where !install.isHittable { app.swipeUp() }
        XCTAssertTrue(install.isHittable)
        install.tap()
        XCTAssertTrue(app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["安装未完成"].waitForExistence(timeout: 5))
        app.alerts["安装未完成"].buttons["知道了"].tap()
        XCTAssertTrue(app.alerts["安装未完成"].waitForNonExistence(timeout: 5))
    }
}
