import XCTest

final class InstallRecoveryUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testDownloadFailureOffersDownloadRetryAndProxyHint() {
        openInstallFailure("download-twice")
        XCTAssertTrue(app.staticTexts["installHost.proxyHint"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["installHost.start"].label, "重试下载")
        XCTAssertTrue(app.buttons["installHost.back"].exists)
    }

    func testPairFailureOffersPairOnlyRecoveryCopy() {
        openInstallFailure("pair-expired")
        XCTAssertTrue(
            app.staticTexts["配对失败后服务器已恢复原状态；重试会重新启动配对。"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.buttons["installHost.start"].label, "重新配对")
        XCTAssertTrue(app.buttons["installHost.back"].exists)
    }

    func testSudoFailureOffersInlineReauthorization() {
        openInstallFailure("sudo-failure")
        XCTAssertTrue(app.secureTextFields["installHost.sudoCredential"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["installHost.retrySudo"].exists)
        XCTAssertTrue(app.buttons["installHost.back"].exists)
        XCTAssertFalse(app.buttons["installHost.start"].isEnabled)
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
