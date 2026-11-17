import XCTest

/// 静 v2 视觉验收夹具：**一个测试方法截一屏**，截图随 xcresult 落盘、可复跑。
///
/// 用法：
/// ```bash
/// bash scripts/pi-test.sh PI-IOSUITests/VisualReviewUITests
/// arch -arm64 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///   xcrun xcresulttool export attachments \
///     --path /tmp/pi-uitest.xcresult --output-path .tmp/visual-review
/// ```
///
/// 设计约束：
/// 1. 每条用例自己 `launch()`，不依赖执行顺序、不共享可变状态，可单条复跑
///    （`bash scripts/pi-test.sh PI-IOSUITests/VisualReviewUITests/test07…`）。
/// 2. 只按 accessibilityIdentifier 定位，不认中文文案——本轮文案正在被整体收敛。
/// 3. 找不到 identifier 一律 `XCTSkip` 并打印缺失项：其他域的 identifier 还在变动，
///    视觉夹具是证据工具，不是「谁改名谁红」的回归门禁。
/// 4. 日志里每屏一行，便于 grep：
///    `VISUAL-REVIEW CAPTURED name=…` / `VISUAL-REVIEW SKIP screen=… missing=…`。
final class VisualReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - 01 侧边栏

    func test01SidebarOnlineHosts() throws {
        launch("online-two-hosts")
        try require("sidebar.close", screen: "01-sidebar-online-hosts")
        capture("01-sidebar-online-hosts")
    }

    // MARK: - 02 项目根页

    func test02ProjectsRoot() throws {
        launch("online-project-lifecycle")
        try tap("sidebar.root.projects", screen: "02-projects-root")
        try require("projects.add", screen: "02-projects-root")
        capture("02-projects-root")
    }

    // MARK: - 03 项目详情浮层

    func test03ProjectDetailSheet() throws {
        launch("online-project-lifecycle")
        try tap("sidebar.root.projects", screen: "03-project-detail")
        try require("projects.add", screen: "03-project-detail")
        try tap("projects.row.P1", screen: "03-project-detail")
        try require("projectDetail.name", screen: "03-project-detail")
        capture("03-project-detail")
    }

    // MARK: - 04 设置根页

    func test04SettingsRoot() throws {
        launch("online-two-hosts")
        try tap("sidebar.root.settings", screen: "04-settings-root")
        try require("settings.addServer", screen: "04-settings-root", scrollIfNeeded: true)
        capture("04-settings-root")
    }

    // MARK: - 05 服务器表单

    func test05ServerForm() throws {
        launch("online-two-hosts")
        try tap("sidebar.root.settings", screen: "05-servers-form")
        try tap("settings.addServer", screen: "05-servers-form", scrollIfNeeded: true)
        try require("servers.name", screen: "05-servers-form")
        capture("05-servers-form")
    }

    // MARK: - 06 模型服务列表

    func test06ModelsServices() throws {
        launch("online-model-config")
        try tap("sidebar.root.settings", screen: "06-models-services")
        try tap("settings.models", screen: "06-models-services", scrollIfNeeded: true)
        try require("models.providerRow.prv_alpha", screen: "06-models-services")
        capture("06-models-services")
    }

    // MARK: - 07 模型服务详情

    func test07ModelProviderDetail() throws {
        launch("online-model-config")
        try tap("sidebar.root.settings", screen: "07-model-provider-detail")
        try tap("settings.models", screen: "07-model-provider-detail", scrollIfNeeded: true)
        try tap("models.providerRow.prv_alpha", screen: "07-model-provider-detail")
        // 详情浮层里「状态/密钥/删除」按数据条件出现，取任一即可成屏。
        try requireAny(
            [
                "models.provider.delete",
                "models.provider.keyStatus",
                "models.provider.editService",
                "models.provider.status",
            ],
            screen: "07-model-provider-detail"
        )
        capture("07-model-provider-detail")
    }

    // MARK: - 08 PI-adaptor v2 Provider

    func test08AdaptorV2Provider() throws {
        launch("online-model-update")
        try tap("sidebar.root.settings", screen: "08-adaptor-v2-provider")
        try tap("settings.models", screen: "08-adaptor-v2-provider", scrollIfNeeded: true)
        try tap("models.serverRecords", screen: "08-adaptor-v2-provider", scrollIfNeeded: true)
        // 夹具下这里可能只有「新增 provider」表单，也可能读到真实 provider 列表；
        // 两者取其一即可成屏，缺两者才算 skip。
        try requireAny(
            ["providers.createName", "providers.warning", "providers.edit.Alpha Models"],
            screen: "08-adaptor-v2-provider"
        )
        capture("08-adaptor-v2-provider")
    }

    // MARK: - 09 全局 Skill

    func test09SkillsGlobal() throws {
        launch("online-two-hosts")
        try tap("sidebar.root.settings", screen: "09-skills-global")
        try tap("settings.skills", screen: "09-skills-global", scrollIfNeeded: true)
        try require("skills.ref", screen: "09-skills-global")
        capture("09-skills-global")
    }

    // MARK: - 10 安装 PI-adaptor

    func test10InstallAdaptor() throws {
        launch("online-two-hosts")
        try tap("sidebar.root.settings", screen: "10-install-adaptor")
        try tap("settings.server.0", screen: "10-install-adaptor")
        try tap("servers.install", screen: "10-install-adaptor", scrollIfNeeded: true)
        try require("installHost.target", screen: "10-install-adaptor")
        capture("10-install-adaptor")
    }

    // MARK: - 11 会话页 · 待审批卡

    func test11ConversationApproval() throws {
        launch("online-long-history-pending-approval")
        try tap("sidebar.session.S1", screen: "11-conversation-approval")
        try require("conversation.approval.approval-bash-1", screen: "11-conversation-approval")
        // 审批卡上方的常驻状态条（运行中 / 排队 / 离线）是这一轮的验收重点之一。
        try require("conversation.statusStrip", screen: "11-conversation-approval")
        capture("11-conversation-approval")
    }

    // MARK: - 12 会话页 · 工具卡折叠

    func test12ConversationToolsCollapsed() throws {
        launch("online-tool-batch")
        try tap("sidebar.session.S1", screen: "12-conversation-tools-collapsed")
        try require("toolGroup.batch_tool_1.toggle", screen: "12-conversation-tools-collapsed")
        capture("12-conversation-tools-collapsed")
    }

    // MARK: - 13 会话页 · 工具卡展开

    func test13ConversationToolsExpanded() throws {
        launch("online-tool-batch")
        try tap("sidebar.session.S1", screen: "13-conversation-tools-expanded")
        try tap("toolGroup.batch_tool_1.toggle", screen: "13-conversation-tools-expanded")
        try require("toolCard.batch_tool_1.toggle", screen: "13-conversation-tools-expanded")
        capture("13-conversation-tools-expanded")
    }

    // MARK: - 14 会话页 · Markdown

    func test14ConversationMarkdown() throws {
        launch("online-markdown-message")
        try tap("sidebar.session.S1", screen: "14-conversation-markdown")
        try require("conversation.agentMessage.markdown-message", screen: "14-conversation-markdown")
        capture("14-conversation-markdown")
    }

    // MARK: - 15 设置页 · 四变体颜色证据

    func test15SettingsLightStandard() throws {
        try captureSettingsVariant(appearance: "light", contrast: "standard")
    }

    func test15SettingsDarkStandard() throws {
        try captureSettingsVariant(appearance: "dark", contrast: "standard")
    }

    func test15SettingsLightIncreasedContrast() throws {
        try captureSettingsVariant(appearance: "light", contrast: "increased")
    }

    func test15SettingsDarkIncreasedContrast() throws {
        try captureSettingsVariant(appearance: "dark", contrast: "increased")
    }

    private func captureSettingsVariant(appearance: String, contrast: String) throws {
        if contrast == "increased" {
            throw XCTSkip("当前模拟器未能稳定开启 Increase Contrast；该变体需真机或可用环境手工验收")
        }
        launch("online-two-hosts", appearance: appearance, contrast: contrast)
        try tap("sidebar.root.settings", screen: "15-settings-colors", allowsSkip: false)
        try require("settings.appearance", screen: "15-settings-colors", scrollIfNeeded: true, allowsSkip: false)

        // 通过 App 自己的外观设置再确认一次，避免启动参数或持久化状态造成误标。
        try tap("settings.appearance", screen: "15-settings-colors", scrollIfNeeded: true, allowsSkip: false)
        let title = appearance == "dark" ? "深色" : "浅色"
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "找不到外观选项 \(title)")
        app.buttons[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 3), "找不到外观完成按钮")
        app.buttons["完成"].firstMatch.tap()
        settle()
        XCTAssertFalse(app.buttons["完成"].exists, "外观浮层未退出")
        XCTAssertFalse(app.buttons[title].exists, "外观选项仍在浮层中，未返回设置页")
        let appearanceRow = app.descendants(matching: .any)["settings.appearance"]
        XCTAssertTrue(appearanceRow.staticTexts[title].waitForExistence(timeout: 3), "设置外观行当前值不是 \(title)")
        capture("15-settings-colors")
    }

    // MARK: - 基础设施

    private var variant = "light-standard"

    /// 每次用例独立启动，避免「上一条用例的抽屉/根页」污染这一屏。
    /// 外观由 App 偏好注入；增强对比度由系统辅助功能设置驱动。
    private func launch(_ scenario: String, appearance: String = "light", contrast: String = "standard") {
        variant = contrast == "standard" ? appearance : "\(appearance)-\(contrast)"
        let app = XCUIApplication()
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += ["-pi.appearance", appearance]
        app.launch()
        self.app = app
        settle()
    }

    /// 等一屏稳定：转场动画没走完就截图会截到半截。
    private func settle(_ seconds: TimeInterval = 0.45) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func require(
        _ identifier: String,
        screen: String,
        timeout: TimeInterval = 12,
        scrollIfNeeded: Bool = false,
        allowsSkip: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if !element.waitForExistence(timeout: timeout), scrollIfNeeded {
            for _ in 0..<3 where !element.exists {
                app.scrollViews.firstMatch.swipeUp()
                settle(0.25)
            }
        }
        guard element.exists else {
            if allowsSkip {
                print("VISUAL-REVIEW SKIP screen=\(screen) missing=\(identifier)")
                throw XCTSkip("缺少 identifier「\(identifier)」：\(screen) 无法截图", file: file, line: line)
            }
            XCTFail("缺少 identifier「\(identifier)」：\(screen) 无法截图", file: file, line: line)
            return element
        }
        settle()
        return element
    }

    /// 多个候选 identifier 命中任一即可（用于「列表/空态/表单三选一」这种屏）。
    @discardableResult
    private func requireAny(
        _ identifiers: [String],
        screen: String,
        timeout: TimeInterval = 12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in identifiers {
                let element = app.descendants(matching: .any)[identifier]
                if element.exists {
                    settle()
                    return element
                }
            }
            settle(0.25)
        } while Date() < deadline
        print("VISUAL-REVIEW SKIP screen=\(screen) missing=any(\(identifiers.joined(separator: ", ")))")
        throw XCTSkip(
            "候选 identifier 全部缺失：\(identifiers.joined(separator: ", "))（\(screen)）",
            file: file,
            line: line
        )
    }

    private func tap(
        _ identifier: String,
        screen: String,
        timeout: TimeInterval = 12,
        scrollIfNeeded: Bool = false,
        allowsSkip: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let element = try require(
            identifier,
            screen: screen,
            timeout: timeout,
            scrollIfNeeded: scrollIfNeeded,
            allowsSkip: allowsSkip,
            file: file,
            line: line
        )
        if !element.isHittable, scrollIfNeeded {
            for _ in 0..<3 where !element.isHittable {
                app.scrollViews.firstMatch.swipeUp()
                settle(0.25)
            }
        }
        guard element.isHittable else {
            if allowsSkip {
                print("VISUAL-REVIEW SKIP screen=\(screen) notHittable=\(identifier)")
                throw XCTSkip("「\(identifier)」存在但不可点：\(screen)", file: file, line: line)
            }
            XCTFail("「\(identifier)」存在但不可点：\(screen)", file: file, line: line)
            return
        }
        element.tap()
        settle()
    }

    /// XCTAttachment(image:) + .keepAlways：随 xcresult 一起导出成 PNG。
    private func capture(_ name: String) {
        let attachment = XCTAttachment(image: app.screenshot().image)
        attachment.name = "\(name)-\(variant)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("VISUAL-REVIEW CAPTURED name=\(name) variant=\(variant)")
    }
}
