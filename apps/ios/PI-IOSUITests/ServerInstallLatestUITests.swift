import XCTest

/// 真实安装需要已保存 SSH 凭证的隔离 Host，默认验证 GitHub 最新兼容发布。
/// 用 `PI_IOS_EXPECTED_RELEASE_SOURCE=fallback` 单独验证内置回退。
final class ServerInstallLatestUITests: XCTestCase {
    private let timeout: TimeInterval = 20 * 60

    func testInstallsLatestStableReleaseOnRealServer() throws {
        try install(expectedSource: .latest)
    }

    func testInstallsBundledFallbackOnRealServer() throws {
        try install(expectedSource: .fallback)
    }

    private enum ReleaseSource: String {
        case latest, fallback
    }

    private func install(expectedSource: ReleaseSource) throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["PI_IOS_LIVE_RELEASE_INSTALL"] == "1",
            "设置 PI_IOS_LIVE_RELEASE_INSTALL=1 才运行真实服务器安装"
        )
        let configuredHost = environment["PI_IOS_EXPECTED_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedHost = configuredHost, !expectedHost.isEmpty else {
            throw XCTSkip("设置 PI_IOS_EXPECTED_HOST 为已配置的隔离测试服务器地址")
        }
        let configuredSource = try XCTUnwrap(
            ReleaseSource(rawValue: environment["PI_IOS_EXPECTED_RELEASE_SOURCE"] ?? "latest"),
            "PI_IOS_EXPECTED_RELEASE_SOURCE 必须是 latest 或 fallback"
        )
        try XCTSkipUnless(configuredSource == expectedSource, "本次选定安装来源为 \(configuredSource.rawValue)")
        let expectedVersion = try XCTUnwrap(
            environment["PI_IOS_EXPECTED_RELEASE_VERSION"]
                ?? (Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            "无法读取 UI 测试构建的版本号"
        )
        XCTAssertFalse(expectedVersion.isEmpty, "期望发布版本不能为空")

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }

        openSettings(app)
        let hostRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "settings.server.", "@\(expectedHost):"
        ))
        XCTAssertTrue(hostRows.firstMatch.waitForExistence(timeout: 15), "模拟器里没有指定的服务器记录")
        XCTAssertEqual(hostRows.count, 1, "指定的服务器地址必须唯一匹配一条记录")
        hostRows.firstMatch.tap()
        let address = app.textFields["servers.host"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        XCTAssertEqual(address.value as? String, expectedHost, "必须在指定的隔离服务器上执行")

        let installRow = app.buttons["servers.install"]
        scrollUntilHittable(app, installRow)
        XCTAssertTrue(installRow.waitForExistence(timeout: 10), "找不到安装入口")
        installRow.tap()
        XCTAssertTrue(app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 10))

        let start = app.buttons["installHost.start"]
        scrollUntilHittable(app, start)
        XCTAssertTrue(start.isHittable && start.isEnabled, "开始安装按钮应可使用")
        start.tap()

        let resolved = app.staticTexts["installHost.resolvedRelease"]
        XCTAssertTrue(resolved.waitForExistence(timeout: 120), "未显示解析到的目标版本")
        let fields = resolved.label.components(separatedBy: " · ")
        XCTAssertEqual(fields.count, 2, "发布状态行应包含版本与来源")
        XCTAssertEqual(fields.first, "PI-adaptor \(expectedVersion)", "目标版本必须完整匹配")
        let source = try XCTUnwrap(fields.last)
        let fallbackNotice = app.descendants(matching: .any)["installHost.fallbackNotice"]
        switch expectedSource {
        case .latest:
            XCTAssertEqual(source, "最新兼容发布")
            XCTAssertFalse(fallbackNotice.exists)
        case .fallback:
            XCTAssertTrue(source.hasPrefix("内置版本（") && source.hasSuffix("）") && source != "内置版本（）", source)
            XCTAssertTrue(
                fallbackNotice.waitForExistence(timeout: 10),
                "回退时必须显示原因横幅"
            )
        }
        print("LIVE_RELEASE_SOURCE=\(expectedSource.rawValue) label=\(resolved.label)")

        let success = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "安装完成")).firstMatch
        let failure = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "安装未完成")).firstMatch
        let warning = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "安装完成，有提示", "已配对，直连未通过"
        )).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if failure.exists || warning.exists {
                XCTFail("真实服务器安装未通过：\n\(dumpTexts(app))")
                return
            }
            if success.exists { return }
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
    /// 失败时打印可见文案与按钮状态：安装链路按步骤推进，失败定位主要靠这里。
    private func dumpTexts(_ app: XCUIApplication) -> String {
        var lines: [String] = []
        for element in app.staticTexts.allElementsBoundByIndex where !element.label.isEmpty {
            lines.append("T: \(element.label)")
        }
        for element in app.buttons.allElementsBoundByIndex {
            lines.append("B: \(element.label) hittable=\(element.isHittable) enabled=\(element.isEnabled)")
        }
        return lines.joined(separator: "\n")
    }
}
