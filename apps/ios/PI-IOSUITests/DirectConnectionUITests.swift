import XCTest

final class DirectConnectionUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testServersShowsRealEndpointPinHostIdAndSSHRoute() {
        openHost(scenario: "online-direct-ssh")
        let endpoint = anyElement("directConnection.endpoint")
        for _ in 0..<6 where !endpoint.isHittable { app.swipeUp() }
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(endpoint.value as? String, "wss://host.example:9443/v1/racp/ws")
        XCTAssertEqual(
            anyElement("directConnection.certificateSHA256").label,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(anyElement("directConnection.hostId").label, "host_fixture_direct")
        XCTAssertTrue(anyElement("directConnection.activeRoute").label.contains("SSH"))
        XCTAssertTrue(anyElement("directConnection.retry").isEnabled)
    }

    func testInstallShowsDirectParametersAndCompleteTrustBeforeSSHOnlyChoice() {
        openInstall(scenario: "online-direct-ssh", directFixture: "confirm")
        XCTAssertEqual(anyElement("installHost.directEndpoint").value as? String, "wss://host.example:9443/v1/racp/ws")
        XCTAssertEqual(anyElement("installHost.directName").value as? String, "host.example")
        XCTAssertEqual(anyElement("installHost.directPort").value as? String, "9443")
        let trustPin = anyElement("installHost.directTrustPin")
        XCTAssertTrue(trustPin.waitForExistence(timeout: 5))
        XCTAssertEqual(trustPin.label, String(repeating: "a", count: 64))
        XCTAssertEqual(anyElement("installHost.directTrustHostId").label, "host_fixture_direct")
        XCTAssertTrue(anyElement("installHost.directAuthorize").exists)
        anyElement("installHost.directSSHOnly").tap()
        XCTAssertTrue(anyElement("installHost.directTrustPin").waitForNonExistence(timeout: 3))
    }

    func testDirectFailureRequiresExplicitSSHOnlyCompletionAndKeepsDiagnostic() {
        openInstall(scenario: "online-direct-ssh", directFixture: "failed")
        XCTAssertTrue(anyElement("installHost.directError").waitForExistence(timeout: 5))
        XCTAssertTrue(anyElement("installHost.completeSSHOnly").exists)
        XCTAssertFalse(app.staticTexts["安装与设备验证完成"].exists)
        let retry = anyElement("installHost.start")
        for _ in 0..<6 where !retry.isHittable { app.swipeUp() }
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "仅重试 Direct 首验，不重新配对")
            ).firstMatch.waitForExistence(timeout: 5),
            "重试只走 Direct 首验，不重新执行安装或配对"
        )
        anyElement("installHost.completeSSHOnly").tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "已明确选择仅使用 SSH")
            ).firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(anyElement("installHost.directError").exists)
    }

    private func openHost(scenario: String) {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
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
            NSPredicate(format: "label CONTAINS %@", "Fixture Lifecycle PI-adaptor")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5))
    }

    private func openInstall(scenario: String, directFixture: String) {
        app.launchEnvironment["PI_IOS_INSTALL_FIXTURE_DIRECT"] = directFixture
        openHost(scenario: scenario)
        let install = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "安装或修复 PI-adaptor")
        ).firstMatch
        for _ in 0..<10 where !install.isHittable { app.swipeUp() }
        XCTAssertTrue(install.isHittable)
        install.tap()
        XCTAssertTrue(app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 5))
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
