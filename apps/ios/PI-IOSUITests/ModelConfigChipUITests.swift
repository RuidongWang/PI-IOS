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
    // MARK: - 默认模型

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
}
