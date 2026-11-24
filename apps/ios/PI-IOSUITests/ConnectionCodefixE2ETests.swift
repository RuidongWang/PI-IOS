import XCTest

/// 端到端验证 2026-10-31 连接链路修复单中「真实主机」的可执行条目：
/// AC-08（RACP 握手 + `item.delta` 流式 + `turn.completed` 清除运行态）、
/// AC-09（运行中 `turn/interrupt` 中止并清除运行态）。
///
/// 前提：模拟器已配对的真实 PI-adaptor 处于在线状态（与 `LiveChatUITests` 相同）。
/// 默认跳过；显式设置 `PI_IOS_CODE_FIX_E2E=1` 才运行，避免污染常规测试运行。
final class ConnectionCodefixE2ETests: XCTestCase {
    private var app: XCUIApplication!

    private let marker = "PI-E2E-\(UUID().uuidString.prefix(8))"

    /// 门禁必须在 `launch()` 之前：应用启动会读取真实状态并自动连接已配对 host，
    /// 放到测试方法里再跳过已经产生了真实网络访问。
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["PI_IOS_CODE_FIX_E2E"] == "1" else {
            throw XCTSkip("Set PI_IOS_CODE_FIX_E2E=1 to run the live connection E2E.")
        }
        app = XCUIApplication()
        app.launchEnvironment["PI_IOS_UI_TEST_TURN_OUTCOME"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) { return }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    private func openLiveSession() {
        showRoot("项目")
        let session = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.session."))
            .firstMatch
        for _ in 0..<4 where !session.exists { app.swipeUp() }
        XCTAssertTrue(session.waitForExistence(timeout: 15), "必须在项目页看到至少一条会话")
        session.tap()
        // 打开会话后先等会话页就绪；失败时留下屏幕与元素快照，便于区分「隧道未建立」与「定位器失效」。
        if !composerField().waitForExistence(timeout: 40) {
            attach("08-open-session-failed")
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(25)
                .map { "\($0.label)" }
                .joined(separator: " | ")
            XCTFail("会话页未出现指令输入框。屏幕文本：\(texts)")
        }
    }

    private func ensureModelBound() {
        let send = app.buttons["conversation.send"]
        if send.exists && send.isEnabled { return }
        let chip = app.buttons["composer.modelChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "会话配置入口（模型 chip）必须存在")
        chip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 10))
        let model = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "conversation.config.model."
        )).firstMatch
        let hasModel = model.waitForExistence(timeout: 10)
        attach("05-session-config")
        XCTAssertTrue(hasModel, "本机模型清单必须至少含一个可选模型")
        for _ in 0..<6 where !model.isHittable { app.swipeUp() }
        model.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "当前"), object: model)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, "模型绑定未生效")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForNonExistence(timeout: 10))
    }

    private func send(_ text: String) {
        let interrupt = app.buttons["conversation.interrupt"]
        let streaming = app.staticTexts["conversation.streamingCount"]
        XCTAssertTrue(
            interrupt.waitForNonExistence(timeout: 10) && streaming.waitForNonExistence(timeout: 10),
            "测试会话开始时应空闲"
        )
        let composer = composerField()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        // 草稿会跨启动保留（离线缓存），先清空，保证每次发送的文本唯一可审计。
        let existing = (composer.value as? String) ?? ""
        if !existing.isEmpty && existing != "给 Agent 的指令" {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        composer.typeText(text)
        let typed = (composer.value as? String) ?? ""
        attach("06-typed-draft")
        XCTAssertEqual(typed, text, "提示词应完整进入输入框")

        ensureModelBound()

        let send = app.buttons["conversation.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        attach("07-before-send")
        XCTAssertTrue(send.isEnabled, "在线、已绑定模型且草稿非空时发送必须可用")
        send.tap()
    }
    /// SwiftUI 纵向 `TextField` 在无障碍树里会在 `TextField` / `TextView` 之间摇摆
    ///（`XC_kAXXCAttributeElementType = SwiftUI.VerticalTextView`），只按 textFields 查询会随机失败。
    private func composerField() -> XCUIElement {
        let byID = NSPredicate(format: "identifier == %@", "conversation.composer")
        let identified = app.descendants(matching: .any).matching(byID).firstMatch
        if identified.waitForExistence(timeout: 10) { return identified }
        // 兼容未带 identifier 的旧构建：按占位符/标签在两种类型里各试一次。
        let byHint = NSPredicate(
            format: "placeholderValue == %@ OR label == %@",
            "给 Agent 的指令", "给 Agent 的指令"
        )
        let textView = app.textViews.matching(byHint).firstMatch
        if textView.waitForExistence(timeout: 5) { return textView }
        return app.textFields.matching(byHint).firstMatch
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func terminalTurn(status: String) -> XCUIElement {
        let submitted = app.staticTexts["conversation.debugSubmittedTurn"]
        XCTAssertTrue(submitted.waitForExistence(timeout: 10), "本次发送应取得 turn/start 回执")
        return app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "conversation.debugTerminalTurn", "\(submitted.label):\(status)"
        )).firstMatch
    }

    // MARK: - AC-08

    func testAC08StreamingThenRunStateClearedOnCompletion() throws {
        openLiveSession()

        let streaming = app.staticTexts["conversation.streamingCount"]
        let interrupt = app.buttons["conversation.interrupt"]

        let prompt = "Reply with exactly this code and no punctuation: \(marker)"
        send(prompt)

        // 流式进行中：空输入 + 运行中必须出现中止按钮，或至少出现流式计数
        //（`turn/start` 解码 + 归约生效）。顶部运行文案已移除。
        let running = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            interrupt.exists || streaming.exists
        }, object: nil)
        let sawRunning = XCTWaiter.wait(for: [running], timeout: 90) == .completed
        attach("01-streaming")
        XCTAssertTrue(sawRunning, "发送后应出现中止按钮/流式指示")
        XCTAssertFalse(app.staticTexts["conversation.runningTurn"].exists)

        let userMessage = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "conversation.userMessage.", prompt
        )).firstMatch
        let latest = app.buttons["conversation.scrollToLatest"]
        if latest.exists { latest.tap() }
        XCTAssertTrue(userMessage.waitForExistence(timeout: 10), "应显示本次发送的请求")
        XCTAssertTrue(terminalTurn(status: "completed").waitForExistence(timeout: 180), "同一轮次须收到 Host 的 completed 终态")
        let assistantMessages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "conversation.agentMessage."
        ))
        let label = NSPredicate(format: "label == %@", marker)
        let reply = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            assistantMessages.matching(label).firstMatch.exists || assistantMessages.containing(label).firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reply], timeout: 10), .completed, "Agent 回复须显示本次请求独有的标记")

        let cleared = streaming.waitForNonExistence(timeout: 10)
            && interrupt.waitForNonExistence(timeout: 10)
        attach("02-completed")
        XCTAssertTrue(cleared, "turn 终态后流式计数与中止入口都必须消失")
    }

    // MARK: - AC-09

    func testAC09InterruptStopsTurnAndClearsRunningState() throws {
        openLiveSession()

        send("\(marker) Write about 800 words on the benefits and drawbacks of remote collaboration. Do not use tools.")

        let interrupt = app.buttons["conversation.interrupt"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 90), "运行中必须出现中止入口")
        let interrupted = terminalTurn(status: "interrupted")
        attach("03-running-before-interrupt")
        interrupt.tap()

        XCTAssertTrue(interrupted.waitForExistence(timeout: 30), "被提交的轮次应收到中止终态")
        let terminal = app.staticTexts["已中止"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "中止后必须显示「已中止」终态")
        XCTAssertTrue(app.buttons["conversation.interrupt"].waitForNonExistence(timeout: 30),
                      "中止后运行态与中止入口必须消失")
        XCTAssertFalse(app.staticTexts["conversation.streamingCount"].exists,
                       "中止后不得残留流式计数")
        attach("04-interrupted")
    }
}
