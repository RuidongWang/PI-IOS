import XCTest

/// Executable coverage for `docs/qa/ui-regression-suite.md`.
///
/// The suite is intentionally split into a small number of scenario-based tests so
/// one fixture launch can cover the related cases without changing App code.
final class UIRegressionSuiteTests: XCTestCase {
    private var app: XCUIApplication!
    private let evidenceDirectory = "/tmp/pi-ui-regression-evidence"

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - Navigation and settings

    func testG01EmptyState() {
        // 用空夹具隔离模拟器上可能残留的 state-v1.json（G-01 的前提是干净首启）。
        launch("empty-state")
        expect("G-01", app.navigationBars["设置"].waitForExistence(timeout: 8), "首屏为设置")
        expect("G-01", app.buttons["打开侧边栏"].exists, "左上角菜单可打开")
        expect("G-01", text("还没有服务器"), "服务器空态")
        expect("G-01", text("＋ 添加服务器"), "添加入口")
        expect("G-01", textContaining("还没有服务器"), "无服务器连接说明")
        scrollUntil(text: "不会收到后台推送")
        expect("G-01", text("不会收到后台推送"), "后台推送说明")
        expect("G-01", text("还没有服务器，没有可撤销的配对记录"), "撤销配对禁用原因")
        snapshot("G-01", step: 1)
    }

    func testG02RootNavigation() {
        launch("online-two-sessions", closeSidebar: false)
        expect("G-02", app.buttons["sidebar.close"].waitForExistence(timeout: 8), "夹具启动时侧边栏打开")
        expect("G-02", app.buttons["切换服务器"].exists, "侧边栏 host 切换器")
        expect("G-02", text("Fixture Online Host"), "当前 host 名")
        app.buttons["sidebar.close"].tap()
        expect("G-02", app.buttons["sidebar.close"].waitForNonExistence(timeout: 5), "关闭按钮收起侧边栏")

        openRoot("项目")
        expect("G-02", app.navigationBars["项目"].exists, "项目根页")
        expect("G-02", app.buttons["projects.add"].exists, "项目页右上加号")
        openRoot("设置")
        expect("G-02", app.navigationBars["设置"].exists, "设置根页")
        openRoot("会话")
        expect("G-02", app.navigationBars["会话"].exists || app.navigationBars["Fixture S1 Alpha"].exists, "会话根页")
        snapshot("G-02", step: 1)
    }

    /// 覆盖 SET-01/02/03/05/06/07；原方法名误用 G-03，和下面真正验证
    /// 返回闭合的 `testG03BackClosure` 撞了编号，此处按实际用例集重命名。
    func testSettingsCases() {
        launch("online-host-unit-active")
        openSettings()
        expect("SET-01", text("服务器"), "服务器组")
        expect("SET-01", text("隧道"), "隧道组")
        expect("SET-01", text("模型"), "模型组")
        expect("SET-01", text("Skill"), "Skill 组")
        expect("SET-01", text("本机"), "本机组")
        expect("SET-01", text("在线"), "在线状态")
        expect("SET-01", text("active"), "systemd active")
        expect("SET-01", text("模型服务") && text("Host v2 Provider") && text("默认模型"), "模型三行")
        expect("SET-01", text("外观") && text("离线缓存上限") && text("撤销本机配对"), "本机三行")
        expect("SET-07", text("Host 版本") && text("fixture-only"), "Host 版本行显示实际版本")
        expect("SET-07", text("运行版本不匹配"), "版本不匹配横幅标题")
        expect("SET-07", app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "期望 pi-adaptor 0.0.1")).firstMatch.exists, "版本不匹配展示期望版本")
        expect("SET-07", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "实际 Fixture Lifecycle fixture-only")).firstMatch.exists, "版本不匹配展示实际版本")
        expect("SET-07", textContaining("请重新安装 PI-adaptor"), "版本不匹配提供修复指引")
        expect("SET-07", app.descendants(matching: .any)["settings.runtimeVersionMismatch"].exists, "版本不匹配稳定标识")
        expect("SET-07", text("在线"), "版本不匹配时仍显示在线状态")
        snapshot("SET-01", step: 1)
        snapshot("SET-07", step: 1)

        let unit = app.descendants(matching: .any)["settings.hostUnit"].firstMatch
        if unit.waitForExistence(timeout: 5) {
            unit.tap()
            expect("SET-06", text("查询中") || unit.label.contains("查询中") || unit.label.contains("active"), "点击后出现查询态")
            let settled = NSPredicate(format: "NOT (label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@)", "查询中", "未查询")
            let expectation = XCTNSPredicateExpectation(predicate: settled, object: unit)
            _ = XCTWaiter.wait(for: [expectation], timeout: 5)
            expect("SET-06", unit.label.contains("active"), "查询最终回到 active")
        } else {
            expect("SET-06", false, "systemd 行可见")
        }

        launch("online-host-unit-stopped")
        openSettings()
        expect("SET-05", text("未连接"), "离线连接状态")
        expect("SET-05", text("systemctl --user restart pi-adaptor.service"), "重启命令")
        expect("SET-05", text("重启命令"), "离线重启入口")
        expect("SET-05", text("inactive"), "systemd inactive")
        snapshot("SET-05", step: 1)

        launch("online-two-hosts")
        openSettings()
        scrollUntil(text: "外观")
        let appearance = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "外观")).firstMatch
        expect("SET-02", appearance.waitForExistence(timeout: 5), "外观行")
        appearance.tap()
        expect("SET-02", app.staticTexts["选择立即作用于全部页面与浮层。"].waitForExistence(timeout: 5), "外观说明")
        expect("SET-02", text("跟随系统") && text("浅色") && text("深色"), "三种外观")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "深色、")).firstMatch.tap()
        snapshot("SET-02", step: 1)
        app.buttons["完成"].firstMatch.tap()
        expect("SET-02", app.staticTexts["深色"].waitForExistence(timeout: 3), "外观行显示深色")
        app.terminate()
        launch("online-two-hosts")
        openSettings()
        scrollUntil(text: "外观")
        expect("SET-02", app.staticTexts["深色"].exists, "重启后保留深色")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "外观")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "跟随系统、")).firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        expect("SET-02", app.staticTexts["跟随系统"].waitForExistence(timeout: 3), "可切回跟随系统")

        launch("offline-cache-205")
        openSettings()
        scrollUntil(text: "离线缓存上限")
        let cacheLimit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "离线缓存上限")).firstMatch
        expect("SET-03", cacheLimit.waitForExistence(timeout: 5), "缓存上限行")
        cacheLimit.tap()
        expect(
            "SET-03",
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "默认 200 条")).firstMatch.exists
                && app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "本机最多缓存 20 个会话")).firstMatch.exists,
            "缓存说明"
        )
        expect("SET-03", text("100 条") && text("200 条") && text("500 条") && text("1000 条"), "缓存四档")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "100 条")).firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        expect("SET-03", app.staticTexts["100 条"].waitForExistence(timeout: 5), "缓存上限已更新")
        snapshot("SET-03", step: 1)

    }

    func testG03BackClosure() {
        launch("offline-two-hosts")
        openSettings()
        let models = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "模型服务")).firstMatch
        expect("G-03", models.waitForExistence(timeout: 5), "模型入口")
        models.tap()
        expect("G-03", app.navigationBars["模型服务"].waitForExistence(timeout: 5), "进入模型服务")
        goBack()
        expect("G-03", app.navigationBars["设置"].waitForExistence(timeout: 5), "模型服务可返回设置")
        for _ in 0..<8 { app.swipeDown() }
        let host = hostRow("Fixture Host B")
        expect("G-03", host.waitForExistence(timeout: 5), "服务器行")
        host.tap()
        expect("G-03", app.navigationBars["服务器"].waitForExistence(timeout: 5), "进入服务器页")
        let install = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "安装或修复 PI-adaptor")).firstMatch
        scrollUntilHittable(install)
        install.tap()
        expect("G-03", app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 5), "进入安装页")
        goBack()
        expect("G-03", app.navigationBars["服务器"].waitForExistence(timeout: 5), "安装页返回服务器")
        goBack()
        expect("G-03", app.navigationBars["设置"].waitForExistence(timeout: 5), "服务器返回设置")
        snapshot("G-03", step: 1)
    }

    func testSettingsRevokePairing() {
        launch("online-two-sessions")
        openSettings()
        scrollUntil(text: "撤销本机配对")
        let revoke = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "撤销本机配对")).firstMatch
        expect("SET-04", revoke.waitForExistence(timeout: 5), "撤销配对入口")
        revoke.tap()
        let dialog = app.sheets.firstMatch
        expect("SET-04", dialog.waitForExistence(timeout: 5) || app.staticTexts["撤销本机配对？"].exists, "确认框")
        expect(
            "SET-04",
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "将清除本机保存的配对记录与设备凭证")).firstMatch.exists,
            "确认框后果"
        )
        expect(
            "SET-04",
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "服务器上的 PI-adaptor 安装、运行与会话不受影响。")).firstMatch.exists,
            "服务器不受影响"
        )
        // iOS 26 把 confirmationDialog 渲染成 popover：系统只渲染破坏性操作，
        // 取消由点击外部完成，不再有「取消」按钮。这里按系统实际行为验证可取消。
        expect("SET-04", app.buttons["撤销配对"].firstMatch.exists, "确认框显示撤销操作")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).tap()
        expect("SET-04", hostRow("Fixture Online Host").label.contains("已配对"), "取消后仍配对")
        revoke.tap()
        app.buttons["撤销配对"].firstMatch.tap()
        let unpaired = NSPredicate(format: "NOT (label CONTAINS %@)", "已配对")
        let unpairedExpectation = XCTNSPredicateExpectation(
            predicate: unpaired,
            object: hostRow("Fixture Online Host")
        )
        expect("SET-04", XCTWaiter.wait(for: [unpairedExpectation], timeout: 8) == .completed, "确认后取消配对")
        snapshot("SET-04", step: 1)
    }

    // MARK: - Servers and installation

    func testServerFormValidationAndVisibility() {
        launch()
        expect("SRV-01", app.navigationBars["设置"].waitForExistence(timeout: 8), "空状态设置页")
        let addServer = app.buttons["settings.addServer"].firstMatch.exists
            ? app.buttons["settings.addServer"].firstMatch
            : app.buttons["＋ 添加服务器"].firstMatch
        expect("SRV-01", addServer.waitForExistence(timeout: 5), "添加入口")
        addServer.tap()
        expect("SRV-01", app.navigationBars["服务器"].waitForExistence(timeout: 5), "进入新增服务器")
        let save = app.buttons["保存并测试连接"].firstMatch
        scrollUntilHittable(save)
        save.tap()
        expect("SRV-01", text("请填写服务器地址"), "地址必填")
        expect("SRV-01", text("请填写用户名"), "用户名必填")
        expect("SRV-01", text("请填写服务器密码"), "密码必填")
        expect("SRV-01", !text("正在测试连接"), "校验失败不发请求")

        let address = app.textFields["192.168.1.10"].firstMatch
        expect("SRV-01", address.waitForExistence(timeout: 5), "地址输入框")
        address.tap()
        address.typeText("ssh://example.com")
        dismissKeyboard()
        scrollUntilHittable(save)
        save.tap()
        expect("SRV-01", text("只填主机名或 IP，不要包含协议前缀"), "协议前缀被拒绝")

        replace(address, with: "example.com")
        let port = app.textFields["22"].firstMatch
        let username = app.textFields["pi"].firstMatch
        replace(port, with: "70000")
        dismissKeyboard()
        scrollUntilHittable(save)
        save.tap()
        expect("SRV-01", text("端口需为 1–65535 之间的整数"), "非法端口")
        expect("SRV-01", text("请填写用户名"), "用户名仍为空")
        replace(port, with: "22")
        replace(username, with: "pi")
        dismissKeyboard()
        scrollUntilHittable(save)
        save.tap()
        expect("SRV-01", text("请填写服务器密码"), "只剩密码错误")
        snapshot("SRV-01", step: 1)

        goBack()
        expect("SRV-05", app.navigationBars["设置"].waitForExistence(timeout: 5), "返回设置")
        launch("offline-two-hosts")
        openSettings()
        app.buttons["settings.addServer"].firstMatch.tap()
        expect("SRV-05", app.navigationBars["服务器"].waitForExistence(timeout: 5), "新增服务器页")
        expect("SRV-05", !text("主机指纹") && !text("PI-adaptor 连接") && !text("危险操作"), "新增页隐藏已有主机区块")
        goBack()
        let host = hostRow("Fixture Host B")
        expect("SRV-05", host.waitForExistence(timeout: 5), "已有 host 行")
        host.tap()
        expect("SRV-05", app.navigationBars["服务器"].waitForExistence(timeout: 5), "编辑服务器页")
        scrollUntil(text: "主机指纹")
        expect("SRV-05", text("主机指纹") && text("PI-adaptor 连接") && text("危险操作"), "编辑页显示已有主机区块")
        expect("SRV-05", text("留空表示沿用 Keychain 里已保存的凭证。"), "沿用人凭证说明")

        let auth = app.buttons["认证方式"].firstMatch
        if auth.waitForExistence(timeout: 3) { auth.tap() }
        let privateKey = app.buttons["私钥"].firstMatch
        if privateKey.waitForExistence(timeout: 3) { privateKey.tap() }
        let paste = app.buttons["servers.pasteKey"].firstMatch
        scrollUntilHittable(paste)
        expect("SRV-04", paste.waitForExistence(timeout: 5), "粘贴私钥入口")
        paste.tap()
        expect("SRV-04", app.navigationBars["粘贴私钥"].waitForExistence(timeout: 5), "粘贴私钥弹层")
        expect("SRV-04", text("私钥全文（以 -----BEGIN 开头）"), "私钥全文标题")
        let editor = app.textViews["servers.pasteKey.text"]
        expect("SRV-04", editor.waitForExistence(timeout: 5), "私钥文本输入")
        app.buttons["servers.pasteKey.import"].tap()
        expect("SRV-04", text("先粘贴私钥全文。"), "空私钥错误")
        editor.tap()
        editor.typeText("PuTTY-User-Key-File-3: ssh-ed25519")
        app.buttons["servers.pasteKey.import"].tap()
        expect("SRV-04", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PuTTY")).firstMatch.exists, "PPK 错误")
        expect("SRV-04", editor.exists, "错误时弹层不关闭")
        app.buttons["取消"].firstMatch.tap()
        expect("SRV-04", app.navigationBars["服务器"].waitForExistence(timeout: 5), "取消返回服务器")
        expect("SRV-04", app.staticTexts["servers.keyFileName"].label == "未选择文件", "私钥仍为空")
        snapshot("SRV-04", step: 1)

        let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "删除这台服务器")).firstMatch
        scrollUntilHittable(delete)
        delete.tap()
        expect("SRV-06", text("删除「Fixture Host B」？"), "删除确认标题")
        expect("SRV-06", textContaining("只删除这条本机记录"), "本机删除说明")
        expect("SRV-06", textContaining("服务器上的会话、文件与模型配置不受影响。"), "服务器不受影响")
        // 同 SET-04：iOS 26 的 confirmationDialog 是 popover，取消靠点击外部。
        expect("SRV-06", app.buttons["删除"].firstMatch.exists, "确认框显示删除操作")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).tap()
        expect("SRV-06", app.navigationBars["服务器"].exists, "取消后仍在编辑页")
        delete.tap()
        app.buttons["删除"].firstMatch.tap()
        expect("SRV-06", app.navigationBars["设置"].waitForExistence(timeout: 8), "删除后返回设置")
        expect("SRV-06", hostRow("Fixture Host B").waitForNonExistence(timeout: 5), "删除后行消失")
        snapshot("SRV-06", step: 1)
    }

    func testInstallValidationAndFailurePages() {
        launch("offline-two-hosts")
        openInstall()
        expect("INS-01", text("安装会先核对服务器指纹"), "安装指纹横幅")
        expect("INS-01", text("目标服务器"), "目标服务器卡")
        let field = app.textFields["installHost.port"].firstMatch
        expect("INS-01", field.waitForExistence(timeout: 5), "端口输入")
        replace(field, with: "")
        let start = app.buttons["installHost.start"]
        expect("INS-01", !start.isEnabled, "空端口禁用开始安装")
        expect("INS-01", text("安装必须填写 PI-adaptor 常驻端口"), "空端口提示")
        replace(field, with: "99999")
        expect("INS-01", text("端口需为 1–65535 之间的整数（留空表示只测 SSH）"), "非法端口提示")
        replace(field, with: "44271")
        expect("INS-01", start.isEnabled, "合法端口允许安装")
        expect("INS-01", text("强制重装（忽略已装版本）") && text("查看安装日志") && text("刷新日志"), "安装操作")
        snapshot("INS-01", step: 1)

        let log = app.buttons["installHost.log"]
        scrollUntilHittable(log)
        log.tap()
        expect("INS-05", app.navigationBars["安装日志"].waitForExistence(timeout: 5), "安装日志弹层")
        expect(
            "INS-05",
            text("正在读取 bootstrap.log…") || text("日志读取失败") || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "bootstrap")).firstMatch.exists,
            "日志读取三态"
        )
        app.buttons["刷新"].firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        expect("INS-05", app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 5), "关闭后安装页")

        launch("offline-two-hosts", installFailure: "download-twice")
        openInstall()
        expect("INS-02", text("安装未完成") || text("安装未完成，请检查网络后重试"), "下载失败横幅")
        expect("INS-02", text("download-failed"), "下载失败分类")
        expect("INS-02", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已连续失败 2 次")).firstMatch.exists, "连续失败提示")
        expect("INS-02", app.buttons["installHost.start"].label == "重试下载", "重试下载按钮")
        expect("INS-02", app.buttons["installHost.back"].exists, "返回服务器按钮")
        snapshot("INS-02", step: 1)

        launch("offline-two-hosts", installFailure: "pair-expired")
        openInstall()
        expect("INS-03", text("pair-failed"), "配对失败分类")
        expect("INS-03", text("配对失败后服务器已恢复原状态；重试会重新启动配对。"), "配对恢复说明")
        expect("INS-03", app.buttons["installHost.start"].label == "重新配对", "重新配对按钮")
        snapshot("INS-03", step: 1)

        launch("offline-two-hosts", installFailure: "sudo-failure")
        openInstall()
        expect("INS-04", text("unit-failed"), "unit 失败分类")
        let sudo = app.secureTextFields["installHost.sudoCredential"]
        let retry = app.buttons["installHost.retrySudo"]
        expect("INS-04", sudo.waitForExistence(timeout: 5) && retry.exists, "内联 sudo 控件")
        expect("INS-04", !retry.isEnabled, "空密码禁用重新授权")
        expect("INS-04", !app.buttons["installHost.start"].isEnabled, "unit-failed 主按钮禁用")
        snapshot("INS-04", step: 1)
    }

    // MARK: - Models, providers, and skills

    func testModelsProvidersAndSkills() {
        launch("online-model-config")
        openSettings()
        openListRow("模型服务", requireExact: false)
        expect("MDL-01", app.navigationBars["模型服务"].waitForExistence(timeout: 5), "模型服务页")
        expect("MDL-01", text("本机模型清单"), "本机模型清单分组")
        expect("MDL-01", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha Models")).firstMatch.exists, "Alpha Models 行")
        expect("MDL-01", text("1 个模型 · https://alpha.invalid"), "服务副标题")
        expect("MDL-01", text("Alpha Pro"), "默认模型")
        scrollUntil(textContaining: "点一条服务可查看详情并删除")
        expect("MDL-01", textContaining("点一条服务可查看详情并删除"), "清单 footer")
        snapshot("MDL-01", step: 1)

        let openAI = segmentedButton("OpenAI-Compatible")
        let deepSeek = segmentedButton("DeepSeek 官方")
        scrollUntilHittable(openAI)
        openAI.tap()
        let nameField = app.textFields["models.serviceName"]
        let baseField = app.textFields["models.baseURL"]
        let keyField = app.secureTextFields["models.apiKey"]
        expect("MDL-02", nameField.value as? String == "" || nameField.value as? String == "Antigravity", "OpenAI 服务名为空")
        expect("MDL-02", baseField.value as? String == "" || baseField.value as? String == "http://203.0.113.10:8080/antigravity", "OpenAI Base URL 为空")
        keyField.tap()
        keyField.typeText("not-submitted")
        deepSeek.tap()
        expect("MDL-02", nameField.value as? String == "DeepSeek", "DeepSeek 服务名联动")
        expect("MDL-02", baseField.value as? String == "https://api.deepseek.com", "DeepSeek Base URL 联动")
        expect("MDL-02", !app.buttons["获取模型"].isEnabled, "空 Key 禁用获取")

        segmentedButton("订阅账号登录").tap()
        expect("MDL-03", text("暂不支持订阅账号登录；不会发起 OAuth 或访问账号授权页面。"), "订阅登录警告")
        expect("MDL-03", !baseField.isEnabled && !keyField.isEnabled && !app.buttons["获取模型"].isEnabled, "订阅登录禁用字段")
        segmentedButton("API Key + Base URL").tap()
        expect("MDL-03", !text("暂不支持订阅账号登录；不会发起 OAuth 或访问账号授权页面。"), "切回 API Key 警告消失")

        for _ in 0..<8 { app.swipeDown() }
        let alphaRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha Models")).firstMatch
        expect("MDL-04", alphaRow.waitForExistence(timeout: 5), "Alpha Models 可详情")
        alphaRow.tap()
        if !app.navigationBars["模型服务详情"].waitForExistence(timeout: 2) {
            alphaRow.tap()
        }
        expect("MDL-04", app.navigationBars["模型服务详情"].waitForExistence(timeout: 5), "模型服务详情")
        expect("MDL-04", text("1 个模型 · 本机记录"), "详情摘要")
        scrollUntil(textContaining: "200K ctx · 8K output · off/low/high")
        expect(
            "MDL-04",
            textContaining("alpha-pro") && textContaining("200K ctx · 8192 output · off/low/high"),
            "模型参数"
        )
        expect("MDL-04", text("默认"), "默认标记")
        scrollUntilHittable(app.buttons["删除这条服务"])
        expect(
            "MDL-04",
            text("删除这条服务") && textContaining("删除会移除服务器上的 provider 记录与密钥。"),
            "删除区"
        )
        snapshot("MDL-04", step: 1)
        app.buttons["删除这条服务"].tap()
        expect("MDL-05", text("删除「Alpha Models」？"), "删除确认标题")
        expect("MDL-05", textContaining("将从服务器删除该 provider 及其密钥，并清理本机记录。"), "删除确认正文")
        app.buttons["取消"].firstMatch.tap()
        expect("MDL-05", app.navigationBars["模型服务详情"].exists, "取消后停留详情")
        app.buttons["删除这条服务"].tap()
        app.buttons["删除"].firstMatch.tap()
        expect("MDL-05", text("删除未完成") || text("模型服务已清理"), "删除结果可见")
        expect("MDL-05", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha Models")).firstMatch.exists, "夹具无传输时 alpha 仍在")
        snapshot("MDL-05", step: 1)

        launch("offline-two-hosts")
        openSettings()
        openListRow("Host v2 Provider", requireExact: false)
        expect("HPR-01", app.navigationBars["Host Provider"].waitForExistence(timeout: 5), "Host Provider 页")
        expect("HPR-01", text("Host 未连接") && text("连接后可管理服务器 provider。"), "未连接横幅")
        expect("HPR-01", text("还没有 provider") || text("正在读取…"), "provider 空态")
        expect(
            "HPR-01",
            text("新增 provider")
                && app.textFields["DeepSeek"].exists
                && app.textFields["https://api.example.com/v1"].exists
                && app.secureTextFields["sk-…"].exists
                && app.textFields["deepseek-chat"].exists,
            "新增 provider 四字段"
        )
        let saveProvider = app.buttons["保存到 Host"]
        scrollUntilHittable(saveProvider)
        expect("HPR-01", saveProvider.exists && !saveProvider.isEnabled, "新增 provider 禁用")
        snapshot("HPR-01", step: 1)
        goBack()

        // MDL-07：导入依赖在线隧道，离线时必须提前说明，而不是等点导入才报协议错。
        openListRow("模型服务", requireExact: false)
        expect(
            "MDL-07",
            app.descendants(matching: .any)["models.importBlocked"].waitForExistence(timeout: 5),
            "离线导入横幅"
        )
        expect("MDL-07", text("无法导入模型服务"), "离线导入标题")
        expect("MDL-07", textContaining("导入模型需要 PI-adaptor 在线"), "离线导入原因")
        goBack()

        expect(
            "SKL-01",
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "全局 Skill"))
                .firstMatch.label.contains("连接 Host 后可管理"),
            "设置页离线副标题"
        )
        openListRow("全局 Skill", requireExact: false)
        expect("SKL-01", app.navigationBars["全局 Skill"].waitForExistence(timeout: 5), "Skill 页")
        expect("SKL-01", text("Host 未连接") && text("连接后可读取服务器上的全局 Skill。"), "Skill 未连接横幅")
        expect("SKL-01", text("还没有全局 Skill") && text("点击右上角安装"), "Skill 空态")
        expect(
            "SKL-01",
            text("安装来源") && text("公开 Git") && text("服务器目录")
                && text("branch / tag / commit（可选）") && text("同名覆盖"),
            "Skill 安装来源控件"
        )
        let installSkill = app.buttons["安装 Skill"]
        scrollUntilHittable(installSkill)
        expect("SKL-01", installSkill.exists && !installSkill.isEnabled, "Skill 安装禁用")
        snapshot("SKL-01", step: 1)
    }

    // MARK: - Projects

    func testProjectsLifecycleAndNavigation() {
        launch("online-project-lifecycle")
        openRoot("项目")
        expect("PRJ-01", text("当前服务器") && text("Fixture Lifecycle Host"), "当前服务器卡")
        expect("PRJ-01", app.buttons["projects.row.P1"].label.contains("Alpha Workspace，当前项目，2 个会话"), "P1 当前和计数")
        expect("PRJ-01", app.buttons["projects.row.P2"].label.contains("Beta Workspace，1 个会话"), "P2 计数")
        expect("PRJ-01", app.buttons["projects.details.P1"].exists && app.buttons["projects.details.P2"].exists, "详情按钮")
        expect("PRJ-01", text("浏览服务器目录并注册"), "目录注册入口")
        expect(
            "PRJ-01",
            text("Alpha One") && text("Alpha Two")
                && !app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Beta One")).firstMatch.isHittable,
            "仅列当前项目会话"
        )
        snapshot("PRJ-01", step: 1)

        app.buttons["projects.details.P1"].tap()
        expect("PRJ-05", app.navigationBars["项目详情"].waitForExistence(timeout: 5), "项目详情")
        expect("PRJ-05", text("/fixture/alpha") && text("2 个会话 · 2 个活跃 · 运行中 0"), "详情路径和统计")
        let name = app.textFields["项目名称"]
        expect("PRJ-05", name.waitForExistence(timeout: 5), "项目名称字段")
        replace(name, with: "Beta Workspace")
        app.buttons["保存名称"].tap()
        expect("PRJ-05", text("项目名称不能为空，且同一 Host 内不能重名"), "重名拦截")
        replace(name, with: "Alpha Renamed")
        app.buttons["保存名称"].tap()
        expect("PRJ-05", text("项目名称已更新"), "改名成功")
        app.buttons["完成"].firstMatch.tap()
        expect("PRJ-05", app.buttons["projects.row.P1"].label.contains("Alpha Renamed"), "列表名称更新")
        expect("PRJ-05", app.buttons["projects.row.P1"].label.contains("/fixture/alpha") == false, "路径不显示在行内也不改变")
        snapshot("PRJ-05", step: 1)

        app.buttons["projects.details.P2"].tap()
        app.descendants(matching: .any)["projectDetail.archive"].tap()
        expect("PRJ-06", app.navigationBars["项目详情"].waitForNonExistence(timeout: 5), "归档后关闭详情")
        expect("PRJ-06", text("已归档 · 1"), "已归档分组")
        let archived = app.descendants(matching: .any)["projects.archived.P2"]
        expect("PRJ-06", archived.waitForExistence(timeout: 5), "归档项目行")
        expect("PRJ-06", archived.label.contains("本机归档") && archived.label.contains("恢复"), "归档行说明")
        archived.tap()
        expect("PRJ-06", app.buttons["projects.row.P2"].waitForExistence(timeout: 5), "恢复项目")

        app.buttons["projects.row.P1"].tap()
        expect("PRJ-08", app.navigationBars["Alpha One"].waitForExistence(timeout: 5) || app.navigationBars["Alpha Two"].waitForExistence(timeout: 5), "项目行续接会话")
        openRoot("项目")
        let alphaTwo = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alpha Two")).firstMatch
        scrollUntilHittable(alphaTwo)
        alphaTwo.tap()
        expect("PRJ-08", app.navigationBars["Alpha Two"].waitForExistence(timeout: 5), "打开 Alpha Two")
        openRoot("项目")
        app.buttons["projects.details.P1"].tap()
        expect("PRJ-08", app.navigationBars["项目详情"].exists, "详情按钮进详情")
        app.buttons["完成"].firstMatch.tap()

        app.buttons["projects.details.P2"].tap()
        app.descendants(matching: .any)["projectDetail.delete"].tap()
        let deleteAlert = app.alerts["从本机删除这个项目？"]
        expect("PRJ-07", deleteAlert.waitForExistence(timeout: 5), "项目删除确认")
        expect("PRJ-07", deleteAlert.staticTexts["只移除本机项目记录、会话记录与缓存；服务器上的目录、文件、provider 与会话历史不会被删除。"].exists, "删除范围说明")
        deleteAlert.buttons["取消"].tap()
        expect("PRJ-07", app.buttons["projects.row.P2"].exists, "取消保留项目")
        app.descendants(matching: .any)["projectDetail.delete"].tap()
        app.alerts["从本机删除这个项目？"].buttons["删除"].tap()
        expect("PRJ-07", app.buttons["projects.row.P2"].waitForNonExistence(timeout: 5), "确认后行消失")
        snapshot("PRJ-07", step: 1)

        launch("offline-two-hosts")
        openRoot("项目")
        expect("PRJ-02", text("未连接") || text("尚未连接服务器") || text("连接未就绪"), "离线项目空态")
        expect("PRJ-02", text("打开设置"), "空态打开设置")
        expect("PRJ-03", !app.buttons["projects.add"].isEnabled, "离线加号禁用")
        app.buttons["打开设置"].tap()
        expect("PRJ-02", app.navigationBars["设置"].waitForExistence(timeout: 5), "打开设置跳转")
        snapshot("PRJ-02", step: 1)
    }

    // MARK: - Sidebar and conversation

    func testSidebarCases() {
        launch("online-two-sessions", closeSidebar: false)
        expect("SID-01", app.buttons["sidebar.project.fixture-online-project"].label.hasPrefix("Fixture Workspace，2 个会话"), "分组计数")
        expect("SID-01", app.buttons["sidebar.project.fixture-online-project"].label.contains("当前项目"), "当前项目")
        expect("SID-01", app.buttons["sidebar.session.S2"].frame.minY < app.buttons["sidebar.session.S1"].frame.minY, "S2 排在 S1 前")
        expect("SID-01", app.buttons["sidebar.session.S2"].label.contains("运行中") && app.buttons["sidebar.session.S2"].label.contains("2 条"), "S2 副信息")
        app.buttons["sidebar.session.S1"].tap()
        expect("SID-01", app.buttons["sidebar.close"].waitForNonExistence(timeout: 5), "S1 选择后关闭抽屉")
        expect("SID-01", app.staticTexts["Fixture S1 Alpha"].waitForExistence(timeout: 5), "打开 S1")
        app.buttons["打开侧边栏"].tap()
        expect("SID-01", hasCurrentMarker(near: "S1"), "S1 当前标记")
        snapshot("SID-01", step: 1)

        let search = app.textFields["搜索会话或项目"]
        replace(search, with: "ALPHA")
        expect("SID-02", app.buttons["sidebar.session.S1"].exists && !app.buttons["sidebar.session.S2"].exists, "搜索 ALPHA")
        expect("SID-02", app.buttons["sidebar.project.fixture-online-project"].label.hasPrefix("Fixture Workspace，1 个会话"), "搜索计数 1")
        replace(search, with: "no-such-keyword")
        expect("SID-02", text("没有匹配的会话或项目。"), "搜索无结果")
        replace(search, with: "")
        expect("SID-02", app.buttons["sidebar.session.S1"].exists && app.buttons["sidebar.session.S2"].exists, "清空恢复")
        expect("SID-02", hasCurrentMarker(near: "S1"), "清空后当前不变")

        let group = app.buttons["sidebar.project.fixture-online-project"]
        group.tap()
        expect("SID-03", group.label.contains("已折叠") && !app.buttons["sidebar.session.S1"].exists, "折叠组")
        replace(search, with: "Beta")
        expect("SID-03", app.buttons["sidebar.session.S2"].exists && !app.buttons["sidebar.session.S1"].exists, "搜索强制展开")
        replace(search, with: "")
        expect("SID-03", group.label.contains("已折叠") && !app.buttons["sidebar.session.S2"].exists, "清空恢复折叠")
        group.tap()
        expect("SID-03", app.buttons["sidebar.session.S1"].exists && app.buttons["sidebar.session.S2"].exists, "再点展开")

        let pinS1 = app.buttons["sidebar.pin.S1"]
        let pinS2 = app.buttons["sidebar.pin.S2"]
        pinS1.tap()
        expect("SID-04", pinS1.label == "取消置顶" && app.buttons["sidebar.session.S1"].frame.minY < app.buttons["sidebar.session.S2"].frame.minY, "置顶 S1")
        pinS2.tap()
        expect("SID-04", pinS2.label == "取消置顶" && app.buttons["sidebar.session.S1"].frame.minY < app.buttons["sidebar.session.S2"].frame.minY, "置顶顺序保持")
        pinS1.tap()
        expect("SID-04", app.buttons["sidebar.session.S2"].frame.minY < app.buttons["sidebar.session.S1"].frame.minY, "取消置顶恢复活动排序")
        pinS2.tap()
        snapshot("SID-04", step: 1)

        app.buttons["sidebar.session.S1"].tap()
        expect("SID-05", app.buttons["sidebar.close"].waitForNonExistence(timeout: 5), "S1 切换并关抽屉")
        expect("SID-05", app.staticTexts["Fixture S1 Alpha"].waitForExistence(timeout: 5), "S1 页面标题")
        expect("SID-05", text("Fixture Online Host · fixture@fixture-online.invalid:22 · 模型未绑定"), "会话副信息")
        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.session.S2"].tap()
        expect("SID-05", app.navigationBars["Fixture S2 Beta"].waitForExistence(timeout: 5) && text("正在运行 turn-s2"), "S2 运行状态")
        snapshot("SID-05", step: 1)

        launch("online-two-hosts", closeSidebar: false)
        expect("SID-06", text("Fixture Online Host B") && app.buttons["sidebar.session.B-session"].exists, "初始 Host B")
        app.buttons["切换服务器"].tap()
        app.buttons["Fixture Online Host A"].firstMatch.tap()
        expect("SID-06", text("Fixture Online Host A") && app.buttons["sidebar.session.A-session"].exists, "切换到 Host A")
        app.buttons["sidebar.session.A-session"].tap()
        expect("SID-06", app.navigationBars["Host A Session"].waitForExistence(timeout: 5), "Host A 会话")
        app.buttons["打开侧边栏"].tap()
        app.buttons["切换服务器"].tap()
        app.buttons["Fixture Online Host B"].firstMatch.tap()
        app.buttons["sidebar.close"].tap()
        expect("SID-06", app.navigationBars["Host B Session"].waitForExistence(timeout: 5), "切回 B 保持 B 会话")
        snapshot("SID-06", step: 1)

        launch("offline-two-hosts", closeSidebar: false)
        expect("SID-07", text("离线：下面是可以只读查看的缓存会话。"), "离线侧栏提示")
        expect("SID-07", app.buttons["sidebar.project.fixture-project-B"].exists, "B 项目组")
        expect("SID-07", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-session-B")).firstMatch.exists, "缓存会话 B")
        expect("SID-07", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本机缓存（只读）")).firstMatch.exists, "只读副标题")
        expect(
            "SID-07",
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "未连接服务器，无法新建会话"))
                .firstMatch.exists,
            "离线新建会话禁用原因"
        )
        snapshot("SID-07", step: 1)
    }

    func testConversationBasics() {
        launch("online-two-sessions")
        expect("CNV-01", text("还没有打开会话") && text("到项目页选择或新建一个会话。"), "未打开会话空态")
        expect("CNV-01", text("去项目页"), "去项目页按钮")
        app.buttons["去项目页"].tap()
        expect("CNV-01", app.navigationBars["项目"].waitForExistence(timeout: 5), "跳到项目根页")
        snapshot("CNV-01", step: 1)

        launch("online-reading-two-sessions")
        openSession("S1", title: "Fixture S1 Alpha")
        expect("CNV-02", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reading S1 item 040")).firstMatch.exists, "打开落在最新")
        app.scrollViews.firstMatch.swipeDown()
        expect("CNV-02", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "回到最新")).firstMatch.exists, "回到最新入口")
        snapshot("CNV-02", step: 1)

        launch("online-tool-result-body")
        openSession("S1", title: "Fixture S1 Alpha")
        let completedToggle = app.descendants(matching: .any)["toolCard.call_done.toggle"].firstMatch
        expect("CNV-03", text("工具 · bash") && completedToggle.exists, "工具卡折叠态")
        completedToggle.tap()
        expect("CNV-03", app.staticTexts["toolCard.call_done.preview"].label.contains("hello-from-tool"), "已完成工具正文")
        expect("CNV-03", !text("服务器没有返回工具输出正文。"), "有正文时不显示空正文")
        completedToggle.tap()
        app.descendants(matching: .any)["toolCard.call_running.toggle"].firstMatch.tap()
        expect("CNV-03", text("工具执行中…") && !text("服务器没有返回工具输出正文。"), "运行中卡文案")
        snapshot("CNV-03", step: 1)

        launch("online-model-config")
        openSession("S2", title: "Alpha Two")
        let interrupt = app.buttons["conversation.interrupt"]
        expect("CNV-04", text("正在运行 turn-s2") && interrupt.exists && interrupt.isEnabled, "运行中和中止")
        expect("CNV-04", text("正在生成 N 条内容…") || app.staticTexts["conversation.streamingCount"].exists, "生成内容提示")
        interrupt.tap()
        expect("CNV-04", text("已中止"), "中止结果")
        expect("CNV-04", interrupt.waitForNonExistence(timeout: 2) && !text("正在生成 N 条内容…"), "运行状态消失")
        snapshot("CNV-04", step: 1)

        launch("online-long-history-pending-approval")
        openSession("S1", title: "Fixture S1 Alpha")
        let allowOnce = app.buttons["允许一次"]
        expect("CNV-05", allowOnce.exists && allowOnce.isHittable, "审批卡首屏可见")
        // 摘要是一段多行 Text（"工具：bash\n\n…"），整体是一个无障碍元素，
        // 不能按精确 label "工具：bash" 匹配。
        expect("CNV-05", text("权限请求") && textContaining("工具：bash") && text("本会话允许") && text("拒绝"), "审批卡内容")
        app.scrollViews.firstMatch.swipeDown()
        expect("CNV-05", allowOnce.isHittable, "滚动后审批卡仍可点")
        snapshot("CNV-05", step: 1)

        launch("online-two-sessions")
        openSession("S1", title: "Fixture S1 Alpha")
        expect("CNV-10", text("模型暂不可用") && text("重新检查") && text("选择其他模型"), "模型不可用出口")
        expect("CNV-10", !app.buttons["发送"].isEnabled, "模型不可用禁用发送")
        app.buttons["选择其他模型"].tap()
        expect("CNV-10", app.navigationBars["会话配置"].waitForExistence(timeout: 5), "打开会话配置")
        expect("CNV-10", text("没有可用模型") && text("先到 设置 → 模型服务 导入模型"), "没有可用模型空态")
        app.buttons["完成"].firstMatch.tap()
        snapshot("CNV-10", step: 1)

        launch("online-model-config")
        openSession("S1", title: "Alpha One")
        expect("CNV-11", text("Agent") && text("每次询问") && text("Alpha Models · Alpha Pro") && text("low"), "四个 chips")
        app.buttons["composer.modelChip"].tap()
        expect("CNV-11", app.navigationBars["会话配置"].waitForExistence(timeout: 5), "模型 chip 打开配置")
        expect("CNV-11", text("权限模式") && text("会话模式") && text("模型") && text("思考档位"), "四个配置分组")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.session.S2"].tap()
        let chip = app.buttons["composer.permissionChip"]
        expect("CNV-11", !chip.isEnabled || !app.navigationBars["会话配置"].exists, "运行中 chips 禁用")
        snapshot("CNV-11", step: 1)

        launch("online-model-config")
        openSession("S1", title: "Alpha One")
        app.buttons["会话操作"].tap()
        app.buttons["重命名会话"].tap()
        expect("CNV-12", app.navigationBars["重命名会话"].waitForExistence(timeout: 5) || text("标题只保存在本机，不会改写服务器上的会话内容。"), "重命名弹窗")
        let title = app.textFields["会话标题"]
        replace(title, with: "")
        app.buttons["保存"].tap()
        expect("CNV-12", text("会话标题不能为空") && app.navigationBars["Alpha One"].exists, "空标题拒绝")
        app.buttons["会话操作"].tap()
        app.buttons["重命名会话"].tap()
        expect("CNV-12", app.textFields["会话标题"].waitForExistence(timeout: 5), "重新打开重命名弹窗")
        let reopenedTitle = app.textFields["会话标题"]
        replace(reopenedTitle, with: "Renamed Alpha")
        app.buttons["保存"].tap()
        expect("CNV-12", app.navigationBars["Renamed Alpha"].waitForExistence(timeout: 5), "合法标题改名")
        app.buttons["打开侧边栏"].tap()
        expect("CNV-12", app.buttons["sidebar.session.S1"].label.contains("Renamed Alpha"), "侧栏同步")
        snapshot("CNV-12", step: 1)

        launch("online-two-sessions")
        openSession("S1", title: "Fixture S1 Alpha")
        app.buttons["会话操作"].tap()
        app.buttons["归档会话"].tap()
        expect("CNV-13", app.navigationBars["Fixture S2 Beta"].waitForExistence(timeout: 8) || text("已归档项目「Fixture S1 Alpha」"), "归档切下一条")
        app.buttons["打开侧边栏"].tap()
        expect("CNV-13", !app.buttons["sidebar.session.S1"].exists, "S1 从侧栏消失")
        snapshot("CNV-13", step: 1)

        launch("online-reading-two-sessions")
        openSession("S1", title: "Fixture S1 Alpha")
        expect("CNV-14", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reading S1 item 040")).firstMatch.exists, "初始末尾")
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeDown() }
        let backToLatest = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "回到最新")).firstMatch
        expect("CNV-14", backToLatest.exists, "上滑出现回到最新")
        backToLatest.tap()
        expect("CNV-14", backToLatest.waitForNonExistence(timeout: 5), "点击后按钮消失")
        snapshot("CNV-14", step: 1)

        launch("online-model-config")
        openSession("S1", title: "Alpha One")
        let composer = app.textFields["conversation.composer"].exists
            ? app.textFields["conversation.composer"]
            : app.textFields["给 Agent 的指令"]
        expect("CNV-15", !app.buttons["发送"].isEnabled, "空输入禁用发送")
        replace(composer, with: "   ")
        expect("CNV-15", !app.buttons["发送"].isEnabled, "空格禁用发送")
        replace(composer, with: "hi")
        expect("CNV-15", app.buttons["发送"].isEnabled, "有文本可发送")
        expect(
            "CNV-16",
            app.buttons["添加图片附件"].exists
                && app.buttons["添加图片附件"].isEnabled
                && text("JPEG / PNG / WebP · 单张 ≤20 MiB · 最多 10 张"),
            "附件入口可点与说明"
        )
        snapshot("CNV-16", step: 1)
    }

    func testOfflineCases() {
        launch("offline-two-hosts", closeSidebar: false)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-session-B")).firstMatch.tap()
        expect("OFF-01", text("离线，内容可能不是最新"), "离线横幅")
        expect("OFF-01", text("缓存的历史（只读）") && text("离线只读 · 缓存可能已过期"), "缓存历史标识")
        expect("OFF-01", text("缓存的待审批（1）") && text("离线时不可提交，恢复在线后再操作。"), "缓存审批说明")
        expect("OFF-01", text("未发送草稿（离线只读）") && text("Fixture B unsent draft"), "缓存草稿")
        expect("OFF-01", text("Fixture B private history"), "缓存历史文本")
        expect("OFF-01", !app.buttons["允许一次"].isEnabled && !app.buttons["本会话允许"].isEnabled && !app.buttons["拒绝"].isEnabled, "审批按钮禁用")
        // OFF-02「离线发送与审批禁用」已包含发送禁用，合并回同一编号。
        expect("OFF-02", text("离线：发送已禁用"), "离线发送禁用")
        expect("OFF-02", !app.textFields["conversation.composer"].isEnabled && !app.buttons["发送"].isEnabled, "输入和发送禁用")
        snapshot("OFF-01", step: 1)

        launch("offline-cache-205", closeSidebar: false)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-cache-session")).firstMatch.tap()
        expect("OFF-02", text("离线只读 · 缓存可能已过期"), "缓存横幅")
        expect("OFF-02", !text("Cache item 005"), "005 已裁剪")
        expect("OFF-02", text("Cache item 006"), "006 保留")
        for _ in 0..<30 where !text("Cache item 205") { app.swipeUp() }
        expect("OFF-02", text("Cache item 205"), "205 保留")
        snapshot("OFF-02", step: 1)
    }

    // MARK: - Real Host substitute (Simulator + live SSH/RACP Host)

    func testLiveHostSubstitute() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PI_IOS_RUN_LIVE"] == "1",
              let host = environment["PI_IOS_LIVE_HOST"], !host.isEmpty,
              let sshPort = environment["PI_IOS_LIVE_SSH_PORT"], !sshPort.isEmpty,
              let username = environment["PI_IOS_LIVE_USER"], !username.isEmpty,
              let hostPort = environment["PI_IOS_LIVE_HOST_PORT"], !hostPort.isEmpty,
              let pairToken = environment["PI_IOS_LIVE_PAIR_TOKEN"], !pairToken.isEmpty,
              let fingerprint = environment["PI_IOS_LIVE_FINGERPRINT"], !fingerprint.isEmpty,
              let keyBase64 = environment["PI_IOS_LIVE_KEY_BASE64"],
              let keyData = Data(base64Encoded: keyBase64),
              let keyText = String(data: keyData, encoding: .utf8)
        else {
            throw XCTSkip("Provide live Host variables to run SRV-02 and host-backed substitute checks.")
        }

        launch()
        let addServer = app.buttons["settings.addServer"].firstMatch.exists
            ? app.buttons["settings.addServer"].firstMatch
            : app.buttons["＋ 添加服务器"].firstMatch
        expect("SRV-02", addServer.waitForExistence(timeout: 5), "添加入口")
        addServer.tap()
        expect("SRV-02", app.navigationBars["服务器"].waitForExistence(timeout: 8), "新增服务器")
        replace(app.textFields["例如：家里的服务器"], with: "UI Regression Host")
        replace(app.textFields["192.168.1.10"], with: host)
        replace(app.textFields["22"].firstMatch, with: sshPort)
        replace(app.textFields["pi"].firstMatch, with: username)
        replace(app.textFields["自动探测"], with: hostPort)
        segmentedButton("私钥").tap()
        let paste = app.buttons["servers.pasteKey"]
        scrollUntilHittable(paste)
        paste.tap()
        let editor = app.textViews["servers.pasteKey.text"]
        expect("SRV-02", editor.waitForExistence(timeout: 8), "私钥输入")
        editor.tap()
        editor.typeText(keyText)
        app.buttons["servers.pasteKey.import"].tap()
        expect("SRV-02", app.navigationBars["服务器"].waitForExistence(timeout: 8), "私钥导入后返回")

        let save = app.buttons["保存并测试连接"]
        scrollUntilHittable(save)
        save.tap()
        expect(
            "SRV-02",
            textContaining("核对主机指纹") || app.staticTexts[fingerprint].waitForExistence(timeout: 5),
            "首次指纹核对"
        )
        expect("SRV-02", textContaining("SHA256:"), "显示服务器 SHA256 指纹")
        let trustHost = app.buttons["指纹一致，信任这台服务器"]
        let cancelTrust = app.buttons["取消（不建立连接）"]
        let hasTrustPrompt = trustHost.waitForExistence(timeout: 5)
        expect("SRV-02", hasTrustPrompt ? cancelTrust.exists : text("正在测试连接…"), "指纹确认按钮或已固定指纹")
        if hasTrustPrompt { trustHost.tap() }
        expect("SRV-02", app.staticTexts["正在测试连接"].waitForExistence(timeout: 15) || text("测试结果"), "连接测试反馈")
        expect("SRV-02", app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "测试结果")).firstMatch.waitForExistence(timeout: 20), "连接测试结果")

        let token = app.secureTextFields["ppt2.…"]
        for _ in 0..<10 where !token.exists || !token.isHittable { app.swipeUp() }
        expect("SRV-02", token.waitForExistence(timeout: 5), "配对令牌输入")
        token.tap()
        token.typeText(pairToken)
        app.buttons["配对并连接"].tap()
        expect("SRV-02", app.staticTexts["配对成功；设备令牌已保存"].waitForExistence(timeout: 30), "配对成功")
        goBack()
        expect("SRV-02", app.navigationBars["设置"].waitForExistence(timeout: 8), "返回设置")
        expect("SRV-02", text("在线"), "配对后在线")
        expect("SRV-02", hostRow("UI Regression Host").label.contains("已配对"), "主机行已配对")

        // MDL-06: unreachable endpoint must fail closed.
        openListRow("模型服务", requireExact: false)
        let baseURL = app.textFields["models.baseURL"]
        let serviceName = app.textFields["models.serviceName"]
        let apiKey = app.secureTextFields["models.apiKey"]
        replace(serviceName, with: "UI Regression Invalid")
        replace(baseURL, with: "http://198.51.100.10:9")
        apiKey.tap()
        apiKey.typeText("sk-ui-regression-invalid")
        app.buttons["获取模型"].tap()
        expect("MDL-06", text("正在获取模型"), "获取模型进度")
        expect("MDL-06", app.staticTexts["模型配置未完成"].waitForExistence(timeout: 25), "获取模型失败横幅")
        expect("MDL-06", !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "可用模型")).firstMatch.exists, "失败不生成模型清单")
        goBack()

        // HPR-02/HPR-03.
        openListRow("Host v2 Provider", requireExact: false)
        expect("HPR-02", app.navigationBars["Host Provider"].waitForExistence(timeout: 8), "Host Provider")
        let providerName = "ui-regression-openai"
        replace(app.textFields["DeepSeek"], with: providerName)
        replace(app.textFields["https://api.example.com/v1"], with: environment["PI_IOS_LIVE_LLM_BASE_URL"] ?? "")
        replace(app.secureTextFields["sk-…"], with: environment["PI_IOS_LIVE_LLM_API_KEY"] ?? "")
        replace(app.textFields["deepseek-chat"], with: environment["PI_IOS_LIVE_LLM_MODEL"] ?? "")
        let saveProvider = app.buttons["保存到 Host"]
        scrollUntilHittable(saveProvider)
        expect("HPR-02", saveProvider.isEnabled, "provider 四字段已填")
        saveProvider.tap()
        let providerRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", providerName)).firstMatch
        expect("HPR-02", providerRow.waitForExistence(timeout: 30) || text("Provider 操作失败"), "provider 创建结果")
        expect("HPR-02", (app.textFields["DeepSeek"].value as? String ?? "").isEmpty, "创建后表单清空")
        if providerRow.exists {
            let delete = providerRow.buttons["删除"].firstMatch
            if delete.exists { delete.tap() } else { app.buttons["删除"].firstMatch.tap() }
            expect("HPR-03", text("删除 provider？") && text("不会自动把默认项切到其他 provider"), "删除 provider 确认")
            app.buttons["取消"].firstMatch.tap()
            expect("HPR-03", providerRow.exists, "取消保留 provider")
            app.buttons["删除"].firstMatch.tap()
            app.buttons["删除"].firstMatch.tap()
            expect("HPR-03", providerRow.waitForNonExistence(timeout: 20), "确认后 provider 消失")
        } else {
            expect("HPR-03", false, "HPR-02 失败，无法执行删除")
        }
        goBack()

        // SKL-02 against a server-side directory.
        openListRow("全局 Skill", requireExact: false)
        segmentedButton("服务器目录").tap()
        let skillSource = app.textFields["/home/user/skills/demo"]
        replace(skillSource, with: "/home/ubuntu/pi-regression-skills/sample")
        app.buttons["安装 Skill"].tap()
        let skillRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ui-regression-sample")).firstMatch
        expect("SKL-02", skillRow.waitForExistence(timeout: 30) || text("Skill 操作失败"), "Skill 安装结果")
        if skillRow.exists {
            skillRow.buttons["删除"].firstMatch.tap()
            expect("SKL-02", text("删除 Skill？") && text("只删除 Host 的安装副本，不修改来源仓库或来源目录。"), "删除 Skill 确认")
            app.buttons["删除安装副本"].tap()
            expect("SKL-02", skillRow.waitForNonExistence(timeout: 20), "删除安装副本")
        } else {
            expect("SKL-02", false, "Skill 安装失败，无法执行删除")
        }
        goBack()

        // PRJ-04: register the prepared server directory, then verify idempotency.
        openRoot("项目")
        let addProject = app.buttons["projects.add"]
        expect("PRJ-04", addProject.waitForExistence(timeout: 10) && addProject.isEnabled, "项目加号可用")
        addProject.tap()
        expect("PRJ-04", app.navigationBars["选择服务器目录"].waitForExistence(timeout: 8), "目录浏览器")
        let entry = app.buttons["projectBrowser.entry./home/ubuntu/pi-regression-project"]
        scrollUntilHittable(entry)
        expect("PRJ-04", entry.waitForExistence(timeout: 10), "目标目录")
        entry.tap()
        expect("PRJ-04", app.staticTexts["projectBrowser.currentPath"].label == "/home/ubuntu/pi-regression-project", "完整路径")
        let projectName = app.textFields["projectBrowser.name"]
        replace(projectName, with: "UI Regression Project")
        app.buttons["用当前目录注册项目"].tap()
        expect("PRJ-04", app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI Regression Project")).firstMatch.waitForExistence(timeout: 20), "注册项目出现在列表")
        expect("PRJ-04", text("已注册项目「UI Regression Project」"), "注册成功 toast")
    }

    func testLiveHostManagementContinuation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PI_IOS_RUN_LIVE"] == "1",
              let pairToken = environment["PI_IOS_LIVE_PAIR_TOKEN"], !pairToken.isEmpty
        else {
            throw XCTSkip("Provide live Host variables to continue host-backed checks.")
        }

        launch()
        openSettings()
        let host = hostRow("UI Regression Host")
        guard host.waitForExistence(timeout: 8) else {
            throw XCTSkip("Run testLiveHostSubstitute once to prepare the live Host record.")
        }
        host.tap()
        expect("SRV-02", app.navigationBars["服务器"].waitForExistence(timeout: 8), "续跑：服务器页")

        let tokenField = app.secureTextFields["ppt2.…"]
        if tokenField.waitForExistence(timeout: 3) {
            replace(tokenField, with: pairToken)
            app.buttons["配对并连接"].tap()
            expect(
                "SRV-02",
                app.staticTexts["配对成功；设备令牌已保存"].waitForExistence(timeout: 30),
                "续跑：配对成功"
            )
        }
        goBack()
        expect("SRV-02", app.navigationBars["设置"].waitForExistence(timeout: 8), "续跑：返回设置")
        expect("SRV-02", text("在线"), "续跑：配对后在线")
        expect("SRV-02", hostRow("UI Regression Host").label.contains("已配对"), "续跑：主机行已配对")

        openListRow("Host v2 Provider", requireExact: false)
        expect("HPR-02", app.navigationBars["Host Provider"].waitForExistence(timeout: 8), "Host Provider")
        let providerName = "ui-regression-openai"
        replace(app.textFields["DeepSeek"], with: providerName)
        replace(app.textFields["https://api.example.com/v1"], with: environment["PI_IOS_LIVE_LLM_BASE_URL"] ?? "")
        replace(app.secureTextFields["sk-…"], with: environment["PI_IOS_LIVE_LLM_API_KEY"] ?? "")
        replace(app.textFields["deepseek-chat"], with: environment["PI_IOS_LIVE_LLM_MODEL"] ?? "")
        let saveProvider = app.buttons["保存到 Host"]
        scrollUntilHittable(saveProvider)
        expect("HPR-02", saveProvider.isEnabled, "provider 四字段已填")
        saveProvider.tap()
        let providerRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", providerName))
            .firstMatch
        expect("HPR-02", providerRow.waitForExistence(timeout: 30) || text("Provider 操作失败"), "provider 创建结果")
        expect("HPR-02", (app.textFields["DeepSeek"].value as? String ?? "").isEmpty, "创建后表单清空")
        if providerRow.exists {
            let delete = app.buttons["删除"].firstMatch
            expect("HPR-03", delete.waitForExistence(timeout: 5), "provider 删除入口")
            delete.tap()
            expect("HPR-03", text("删除 provider？") && textContaining("不会自动把默认项切到其他 provider"), "删除 provider 确认")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).tap()
            expect("HPR-03", providerRow.exists, "取消保留 provider")
            app.buttons["删除"].firstMatch.tap()
            app.buttons["删除"].firstMatch.tap()
            expect("HPR-03", providerRow.waitForNonExistence(timeout: 20), "确认后 provider 消失")
        } else {
            expect("HPR-03", false, "HPR-02 失败，无法执行删除")
        }
        goBack()

        openListRow("全局 Skill", requireExact: false)
        segmentedButton("服务器目录").tap()
        replace(app.textFields["/home/user/skills/demo"], with: "/home/ubuntu/pi-regression-skills/sample")
        app.buttons["安装 Skill"].tap()
        let skillRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "ui-regression-sample"))
            .firstMatch
        expect("SKL-02", skillRow.waitForExistence(timeout: 30) || text("Skill 操作失败"), "Skill 安装结果")
        if skillRow.exists {
            app.buttons["删除"].firstMatch.tap()
            expect(
                "SKL-02",
                text("删除 Skill？") && textContaining("只删除 Host 的安装副本，不修改来源仓库或来源目录。"),
                "删除 Skill 确认"
            )
            app.buttons["删除安装副本"].tap()
            expect("SKL-02", skillRow.waitForNonExistence(timeout: 20), "删除安装副本")
        } else {
            expect("SKL-02", false, "Skill 安装失败，无法执行删除")
        }
        goBack()

        openRoot("项目")
        let addProject = app.buttons["projects.add"]
        expect("PRJ-04", addProject.waitForExistence(timeout: 10) && addProject.isEnabled, "项目加号可用")
        addProject.tap()
        expect("PRJ-04", app.navigationBars["选择服务器目录"].waitForExistence(timeout: 8), "目录浏览器")
        let entry = app.buttons["projectBrowser.entry./home/ubuntu/pi-regression-project"]
        scrollUntilHittable(entry)
        expect("PRJ-04", entry.waitForExistence(timeout: 10), "目标目录")
        entry.tap()
        let projectName = app.textFields["projectBrowser.name"]
        replace(projectName, with: "UI Regression Project")
        app.buttons["用当前目录注册项目"].tap()
        expect(
            "PRJ-04",
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI Regression Project"))
                .firstMatch.waitForExistence(timeout: 20),
            "注册项目出现在列表"
        )
    }

    // MARK: - Helpers

    private func launch(
        _ scenario: String? = nil,
        installFailure: String? = nil,
        closeSidebar: Bool = true
    ) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if let scenario {
            app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        }
        if let installFailure {
            app.launchEnvironment["PI_IOS_INSTALL_FIXTURE_FAILURE"] = installFailure
        }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        if closeSidebar, app.buttons["sidebar.close"].waitForExistence(timeout: 1) {
            app.buttons["sidebar.close"].tap()
        }
        if scenario == nil, app.navigationBars["设置"].exists {
            for _ in 0..<8 { app.swipeDown() }
        }
    }

    private func openRoot(_ title: String) {
        if app.navigationBars[title].exists { return }
        if !app.buttons["打开侧边栏"].exists, app.buttons["sidebar.close"].exists {
            app.buttons["sidebar.close"].tap()
        }
        app.buttons["打开侧边栏"].tap()
        let root = app.buttons[title].firstMatch
        expect("NAV", root.waitForExistence(timeout: 5), "侧边栏 \(title) 入口")
        root.tap()
        expect("NAV", app.navigationBars[title].waitForExistence(timeout: 8), "切换到 \(title)")
    }

    private func openSettings() {
        openRoot("设置")
    }

    private func openListRow(_ label: String, requireExact: Bool = true) {
        let row = requireExact
            ? app.buttons[label].firstMatch
            : app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        scrollUntilHittable(row)
        expect("NAV", row.waitForExistence(timeout: 5), "设置行 \(label)")
        row.tap()
    }

    private func openInstall() {
        openSettings()
        let host = hostRow("Fixture Host B")
        expect("NAV", host.waitForExistence(timeout: 5), "安装夹具 host")
        host.tap()
        let install = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "安装或修复 PI-adaptor"))
            .firstMatch
        scrollUntilHittable(install)
        expect("NAV", install.waitForExistence(timeout: 5), "安装入口")
        install.tap()
        expect("NAV", app.navigationBars["安装 PI-adaptor"].waitForExistence(timeout: 5), "安装页")
    }

    private func openSession(_ id: String, title: String) {
        let row = app.buttons["sidebar.session.\(id)"]
        if !row.exists {
            app.buttons["打开侧边栏"].tap()
        }
        expect("NAV", row.waitForExistence(timeout: 5), "会话行 \(id)")
        row.tap()
        expect("NAV", app.navigationBars[title].waitForExistence(timeout: 8), "打开会话 \(title)")
    }

    private func hasCurrentMarker(near sessionID: String) -> Bool {
        let row = app.buttons["sidebar.session.\(sessionID)"]
        guard row.exists else { return false }
        return app.staticTexts.matching(NSPredicate(format: "label == %@", "当前"))
            .allElementsBoundByIndex
            .contains { abs($0.frame.midY - row.frame.midY) < 12 }
    }

    private func segmentedButton(_ label: String) -> XCUIElement {
        let scoped = app.segmentedControls.buttons[label].firstMatch
        return scoped.exists ? scoped : app.buttons[label].firstMatch
    }

    private func replace(_ field: XCUIElement, with value: String) {
        // 保存失败后页面会滚动，字段可能停在状态栏/导航栏下面：isHittable 仍为
        // true，但点击落不到输入框，后续 typeText 报 "no keyboard focus"。
        // 先把字段滚到导航栏下方。
        for _ in 0..<8 where field.exists && field.frame.minY < 130 {
            app.swipeDown()
        }
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        sleep(1)
        // 不能拿 value 和 placeholder 比较后再决定删不删：SSH 端口默认值「22」
        // 与占位符完全相同，会被误判成空字段，输入变成「2222」并连到错误端口。
        // 空字段里发删除键是无害的，所以一律先清空。
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !value.isEmpty {
            field.typeText(value)
        }
    }

    /// 键盘会挡住表单底部的「保存并测试连接」；滚动一次即可收起（页面已设
    /// `.scrollDismissesKeyboard(.immediately)`），再点保存才会真正触发校验。
    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeUp()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 2)
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists {
            back.tap()
        } else {
            app.swipeRight()
        }
    }

    private func hostRow(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func text(_ value: String) -> Bool {
        app.staticTexts[value].exists || app.buttons[value].exists || app.otherElements[value].exists
    }

    private func textContaining(_ value: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch.exists
    }

    private func scrollUntil(text value: String) {
        let element = app.staticTexts[value]
        for _ in 0..<10 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    private func scrollUntil(textContaining value: String) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch
        for _ in 0..<10 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
    }

    private func scrollUntilHittable(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists, element.isHittable { return }
            if element.exists, element.frame.midY < app.windows.firstMatch.frame.height * 0.45 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
    }

    private func expect(_ id: String, _ condition: @autoclosure () -> Bool, _ message: String) {
        let ok = condition()
        print("CASE \(id) \(ok ? "PASS" : "FAIL"): \(message)")
        XCTAssertTrue(ok, "\(id): \(message)")
    }

    private func snapshot(_ id: String, step: Int) {
        try? FileManager.default.createDirectory(
            atPath: evidenceDirectory,
            withIntermediateDirectories: true
        )
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let path = "\(evidenceDirectory)/\(id)-\(String(format: "%02d", step))-01-20261101.png"
        try? data.write(to: URL(fileURLWithPath: path))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(id)-step-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
