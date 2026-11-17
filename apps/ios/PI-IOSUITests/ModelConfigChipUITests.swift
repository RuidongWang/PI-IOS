import XCTest

final class ModelConfigChipUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testModelAndThinkingChipsFollowPersistedBinding() {
        relaunch("online-model-config")
        app.buttons["sidebar.session.S1"].tap()
        let modelChip = app.buttons["composer.modelChip"]
        XCTAssertTrue(modelChip.waitForExistence(timeout: 8))
        XCTAssertTrue(modelChip.label.contains("Alpha Pro"))
        let thinkingChip = app.buttons["composer.thinkingChip"]
        XCTAssertTrue(thinkingChip.exists)
        XCTAssertTrue(thinkingChip.label.contains("low"))

        modelChip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alpha Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Beta Basic"].exists)
        XCTAssertTrue(
            app.staticTexts["权限模式"].exists
                && app.staticTexts["会话模式"].exists
                && app.staticTexts["模型"].exists
                && app.staticTexts["思考档位"].exists,
            "会话配置必须保留四个分组"
        )
        XCTAssertTrue(app.descendants(matching: .any)["conversation.config.mode.agent"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["conversation.config.mode.plan"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["conversation.config.mode.goal"].exists,
            "Goal 是审批类型，不能作为 Host 不支持的会话模式展示"
        )
        app.buttons["完成"].tap()

        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.session.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 5))
        // 顶部运行文案已移除；S2 运行中且输入为空时，发送按钮显示为中止按钮。
        XCTAssertTrue(app.buttons["conversation.interrupt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["conversation.runningTurn"].exists)
        XCTAssertFalse(app.staticTexts["conversation.queueHint"].exists)
        XCTAssertTrue(modelChip.waitForExistence(timeout: 5))
        XCTAssertTrue(modelChip.label.contains("Beta Basic"))
        XCTAssertFalse(app.buttons["composer.thinkingChip"].exists, "无档位模型不得显示档位 chip")
        XCTAssertFalse(app.buttons["composer.permissionChip"].exists, "权限 chip 已从输入栏移除")
        XCTAssertFalse(modelChip.isEnabled)
    }
}

// MARK: - 模型域 quiet-v2 回归
//
// 本域的契约是「看得懂靠布局，不靠文案」：footer / hint 必须为 0，
// 文案定位解耦到 accessibilityIdentifier。这里锁的就是这两件事。

extension ModelConfigChipUITests {
    /// 模型服务页：清单与表单都没有 footer/hint，密钥归属只说明一次。
    func testModelsScreenHasNoFooterCopyAndStableIdentifiers() {
        relaunch("online-model-config")
        openModelsScreen()

        XCTAssertTrue(app.staticTexts["本机模型清单"].exists, "清单分组标题仍在")
        XCTAssertFalse(app.staticTexts["还没有模型服务"].exists, "夹具有两个服务，不应出现空态")

        XCTAssertFalse(anyLabelContains("点一条服务可查看详情并删除"), "清单 footer 已删除")
        XCTAssertFalse(anyLabelContains("Base URL 填模型请求根地址"), "表单 footer 已删除")
        XCTAssertFalse(anyLabelContains("四种线路协议"), "协议 hint 已删除")
        XCTAssertFalse(anyLabelContains("用于模型选择器分组"), "服务名称 hint 已删除")

        let apiKeyNote = app.staticTexts["models.apiKeyNote"].label
        XCTAssertTrue(apiKeyNote.contains("只存本机"), "API Key 归属说明仍在填写处")
        XCTAssertTrue(apiKeyNote.contains("不落盘"), "必须说清服务器不持久化")
        XCTAssertFalse(app.buttons["models.fetchModels"].isEnabled, "空 API Key 时禁用获取")
        XCTAssertFalse(app.buttons["models.selectAll"].exists, "未获取模型前不出现发现区控件")

        let row = providerRow("Alpha Models")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "服务行可见")
        XCTAssertTrue(row.label.contains("1 个模型"), "副标题只放状态数据")
        XCTAssertTrue(row.label.contains("https://alpha.invalid"), "副标题带地址")
    }

    /// 模型服务详情：两个动作靠按钮名自解释，不靠 footer。
    func testProviderDetailActionsExplainThemselves() {
        relaunch("online-model-update")
        openModelsScreen()

        let row = providerRow("Alpha Models")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "服务行可见")
        row.tap()
        XCTAssertTrue(app.navigationBars["模型服务详情"].waitForExistence(timeout: 5), "进入详情")

        XCTAssertEqual(
            app.buttons["models.provider.editModel.alpha-mini"].label,
            "编辑模型",
            "编辑按钮自解释"
        )
        XCTAssertEqual(
            app.buttons["models.provider.setDefault.alpha-mini"].label,
            "设为默认",
            "默认按钮自解释"
        )
        XCTAssertFalse(anyLabelContains("只改这一个模型"), "按钮 footer 已删除")
        XCTAssertFalse(anyLabelContains("本机记录"), "摘要不再带实现标签")
        XCTAssertTrue(
            app.descendants(matching: .any)["models.provider.delete"].waitForExistence(timeout: 5),
            "删除入口有稳定 identifier"
        )
    }

    // MARK: - 默认模型

    /// 回归：详情页点「设为默认」后，本机记录必须真的切过去。
    /// 旧实现的详情页本地快照会变，但 `recordImportedProvider` 用本机旧默认覆盖
    /// 了新选择，关闭详情页/回到设置页又显示旧默认（用户看到的「选了没变」）。
    func testSetDefaultModelPersistsIntoLocalCatalog() {
        relaunch("online-model-update")
        openModelsScreen()

        let row = providerRow("Alpha Models")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "服务行可见")
        row.tap()
        XCTAssertTrue(app.navigationBars["模型服务详情"].waitForExistence(timeout: 5), "进入详情")

        let setDefault = app.buttons["models.provider.setDefault.alpha-mini"]
        XCTAssertTrue(setDefault.waitForExistence(timeout: 5), "非默认模型有设为默认按钮")
        setDefault.tap()

        let alert = app.alerts["模型服务已更新"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "设为默认成功提示")
        alert.buttons["知道了"].tap()
        XCTAssertTrue(
            app.buttons["models.provider.setDefault.alpha-pro"].waitForExistence(timeout: 5),
            "详情的本地快照应立即切换默认标记"
        )

        // 关闭详情后重新打开：若本机记录没更新，这里会退回 alpha-pro。
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["模型服务"].waitForExistence(timeout: 5), "回到模型服务页")
        XCTAssertTrue(providerRow("Alpha Models").waitForExistence(timeout: 5))
        providerRow("Alpha Models").tap()
        XCTAssertTrue(app.navigationBars["模型服务详情"].waitForExistence(timeout: 5), "再次进入详情")
        XCTAssertTrue(
            app.buttons["models.provider.setDefault.alpha-pro"].waitForExistence(timeout: 5),
            "重新打开详情后默认仍应是 Alpha Mini（本机记录已更新）"
        )
        XCTAssertFalse(
            app.buttons["models.provider.setDefault.alpha-mini"].exists,
            "Alpha Mini 已不是待选默认项"
        )
        app.buttons["完成"].tap()

        // 设置页「默认模型」一行必须同步显示新选择。
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8), "回到设置页")
        XCTAssertTrue(
            waitForLabelContains(anyLabel: "默认模型", expected: "Alpha Mini"),
            "设置页默认模型应显示新选择"
        )
    }

    private func waitForLabelContains(
        anyLabel needle: String,
        expected: String,
        timeout: TimeInterval = 6
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", needle)
            )
            for index in 0..<rows.count where rows.element(boundBy: index).label.contains(expected) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 回归：编辑「非默认服务」的模型参数不能抢走全局默认。
    /// 旧实现的 `saveSingleModel` 用 `snapshot.defaultModelId ?? merged.id`，
    /// 非默认服务必为 nil，于是只保存一个模型的参数就让该服务变成默认。
    func testEditingModelInNonDefaultProviderDoesNotStealDefault() {
        relaunch("online-model-update")
        openModelsScreen()

        let betaRow = providerRow("Beta Models")
        XCTAssertTrue(betaRow.waitForExistence(timeout: 5), "非默认服务行可见")
        betaRow.tap()
        XCTAssertTrue(app.navigationBars["模型服务详情"].waitForExistence(timeout: 5), "进入 Beta 详情")

        let edit = app.buttons["models.provider.editModel.beta-basic"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Beta 模型可编辑")
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑模型"].waitForExistence(timeout: 5), "进入编辑模型")
        // 不做任何修改，直接保存：仍然是「编辑模型」而不是「选择默认模型」。
        app.buttons["models.provider.saveModel"].tap()

        let alert = app.alerts["模型服务已更新"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "保存成功提示")
        alert.buttons["知道了"].tap()
        app.buttons["完成"].tap()

        // 回到设置页：默认模型必须仍是 Alpha Pro。
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8), "回到设置页")
        XCTAssertTrue(
            waitForLabelContains(anyLabel: "默认模型", expected: "Alpha Pro"),
            "编辑非默认服务的模型后，默认模型应保持 Alpha Pro"
        )
        XCTAssertFalse(
            waitForLabelContains(anyLabel: "默认模型", expected: "Beta Basic", timeout: 1),
            "非默认服务不能因为保存模型参数而变成默认"
        )
    }

    // MARK: - 导航与查询

    private func relaunch(_ scenario: String) {
        app.terminate()
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    /// 会话页 → 侧边栏 → 设置 → 模型服务。
    private func openModelsScreen() {
        if !app.buttons["sidebar.close"].exists {
            app.buttons["打开侧边栏"].tap()
        }
        let settingsRoot = app.buttons["sidebar.root.settings"]
        if settingsRoot.waitForExistence(timeout: 5) {
            settingsRoot.tap()
        } else {
            app.buttons["设置"].firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8), "进入设置")

        let modelsRow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "模型服务"))
            .firstMatch
        for _ in 0..<8 where !modelsRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(modelsRow.waitForExistence(timeout: 5), "设置里有模型服务入口")
        modelsRow.tap()
        XCTAssertTrue(app.navigationBars["模型服务"].waitForExistence(timeout: 5), "进入模型服务")
    }

    private func providerRow(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func anyLabelContains(_ value: String) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", value))
            .firstMatch.exists
    }
}
