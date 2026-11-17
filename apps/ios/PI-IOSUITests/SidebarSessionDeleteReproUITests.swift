import XCTest

/// 临时复现用例：侧栏会话删除入口在普通 Dynamic Type 与 AX5 下的可达性。
///
/// 背景：0.0.4(9) 用户报告「会话无法删除」，真机日志没有任何 session/delete
/// 请求或错误。怀疑删除入口在 UI 层就被阻断（左滑不出现操作 / 操作 sheet
/// 关闭与确认 alert 弹出竞态）。本文件只做复现取证，不修改产品代码。
final class SidebarSessionDeleteReproUITests: XCTestCase {
    private var app: XCUIApplication!
    private let evidenceDirectory = "/tmp/pi-sidebar-delete-repro"

    override func setUpWithError() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(
            atPath: evidenceDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - 场景 A：普通 Dynamic Type

    func testA_NormalDynamicTypeSwipeDeleteShowsConfirmationAlert() {
        launch(scenario: "online-two-sessions")
        guard waitForSidebarOpen() else { return }

        let group = app.buttons["sidebar.project.fixture-online-project"]
        guard group.waitForExistence(timeout: 8) else {
            XCTFail("A 前置：项目分组 sidebar.project.fixture-online-project 不存在")
            dumpTree("A-00-no-group")
            return
        }
        let row = app.buttons["sidebar.session.S1"]
        guard row.waitForExistence(timeout: 8) else {
            XCTFail("A 前置：会话行 sidebar.session.S1 不存在")
            dumpTree("A-00-no-row")
            return
        }

        let groupWidth = group.frame.width
        let rowHeight = row.frame.height
        print("A-DIAG groupWidth=\(groupWidth) rowHeight=\(rowHeight) screenWidth=\(app.windows.firstMatch.frame.width) screenHeight=\(app.windows.firstMatch.frame.height)")
        XCTAssertLessThan(groupWidth, 330, "A 前置：应为普通字号（侧栏宽约 320，分组内宽应 <330），实际 \(groupWidth)")
        snapshot("A-00-before-swipe")

        let rowFrameBefore = row.frame
        row.swipeLeft()
        let sidebarStillOpen = app.buttons["sidebar.close"].exists
        let rowStillExists = row.exists
        print("A-DIAG rowFrameBefore=\(rowFrameBefore) sidebarStillOpenAfterSwipe=\(sidebarStillOpen) rowStillExists=\(rowStillExists)")
        snapshot("A-01-after-standard-swipe")
        dumpTree("A-01-after-standard-swipe")

        let deleteButton = app.buttons.matching(identifier: "sidebar.delete.S1").firstMatch
        let archiveButton = app.buttons.matching(identifier: "sidebar.archive.S1").firstMatch
        let revealed = deleteButton.exists
        print("A-DIAG afterStandardSwipe deleteExists=\(revealed) archiveExists=\(archiveButton.exists)")
        XCTAssertTrue(
            revealed,
            "A: 普通字号左滑会话行后应出现「归档/删除」操作，sidebar.delete.S1 未出现（左滑后侧栏仍在=\(sidebarStillOpen)，会话行仍存在=\(rowStillExists)）"
        )
        guard revealed else {
            diagnosticSwipeVariants()
            return
        }
        XCTAssertTrue(archiveButton.exists, "A: 左滑后应同时出现归档按钮 sidebar.archive.S1")

        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3), "A: 点击前 sidebar.delete.S1 应存在")
        deleteButton.tap()
        let alert = deleteConfirmationAlert()
        let appeared = alert.waitForExistence(timeout: 5)
        print("A-DIAG afterDeleteTap alertExists=\(appeared) alertLabel=\(appeared ? alert.label : "<none>")")
        snapshot("A-02-after-delete-tap")
        dumpTree("A-02-after-delete-tap")
        XCTAssertTrue(appeared, "A: 点击行内「删除」后应弹出删除确认 alert（标题以「删除「」开头），5s 内未出现")
        guard appeared else { return }

        XCTAssertTrue(alert.label.hasPrefix("删除「"), "A: 删除确认 alert 标题应以「删除「」开头，实际：\(alert.label)")
        XCTAssertTrue(alert.buttons["取消"].exists, "A: 删除确认 alert 应有「取消」按钮")

        alert.buttons["取消"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "A: 点「取消」后删除确认 alert 应消失")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "A: 取消删除后会话行应仍然存在")
        snapshot("A-03-after-cancel")
        dumpTree("A-03-after-cancel")
    }

    // MARK: - 场景 C：夹具内确认删除（验证 UI 成功收尾）

    func testC_FixtureConfirmDeleteRemovesRow() {
        launch(scenario: "online-two-sessions")
        guard waitForSidebarOpen() else { return }
        let row = app.buttons["sidebar.session.S1"]
        guard row.waitForExistence(timeout: 8) else {
            XCTFail("C 前置：会话行 sidebar.session.S1 不存在")
            return
        }

        row.swipeLeft()
        let deleteButton = app.buttons.matching(identifier: "sidebar.delete.S1").firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "C: 左滑后应出现删除按钮")
        deleteButton.tap()

        let alert = deleteConfirmationAlert()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "C: 应出现删除确认 alert")
        alert.buttons["删除"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "C: 夹具确认删除后会话行应消失（本机 tombstone）")
        XCTAssertTrue(app.staticTexts["会话已删除"].waitForExistence(timeout: 3), "C: 应显示删除成功 toast")
        snapshot("C-01-after-confirm-delete")
        dumpTree("C-01-after-confirm-delete")
    }

    // MARK: - 场景 B：AX5（accessibility extra extra extra large）

    func testB_AX5SwipeDeleteFromActionSheetShowsConfirmationAlert() {
        // 注意：任务里给的 `-UIPreferredContentSizeCategoryName
        // UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge` 在 Xcode 27 / iOS 27
        // 模拟器上不生效，且会把 App 覆盖回默认字号（实测分组宽仍 288、行高 44）。
        // UIKit 的 AX5 rawValue 实际是 `UICTContentSizeCategoryAccessibilityXXXL`（实测生效）；
        // 也可用官方 `xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large`
        // 设置全局字号后运行本用例（两种方式都验证过）。
        launch(
            scenario: "online-two-sessions",
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        guard waitForSidebarOpen() else { return }

        let group = app.buttons["sidebar.project.fixture-online-project"]
        guard group.waitForExistence(timeout: 8) else {
            XCTFail("B 前置：项目分组 sidebar.project.fixture-online-project 不存在")
            dumpTree("B-00-no-group")
            return
        }
        let row = app.buttons["sidebar.session.S1"]
        guard row.waitForExistence(timeout: 8) else {
            XCTFail("B 前置：会话行 sidebar.session.S1 不存在")
            dumpTree("B-00-no-row")
            return
        }

        let groupWidth = group.frame.width
        let rowHeight = row.frame.height
        print("B-DIAG groupWidth=\(groupWidth) rowHeight=\(rowHeight) screenWidth=\(app.windows.firstMatch.frame.width) screenHeight=\(app.windows.firstMatch.frame.height)")
        snapshot("B-00-before-swipe")
        let ax5Active = groupWidth > 330 || rowHeight > 80
        XCTAssertTrue(
            ax5Active,
            "B 前置：AX5 启动参数未生效（分组宽 \(groupWidth)，行高 \(rowHeight)；期望侧栏全宽/大字号行高）"
        )
        guard ax5Active else { return }

        row.swipeLeft()
        let sidebarStillOpen = app.buttons["sidebar.close"].exists
        let rowStillExists = row.exists
        print("B-DIAG afterStandardSwipe sidebarStillOpen=\(sidebarStillOpen) rowStillExists=\(rowStillExists)")
        snapshot("B-01-after-standard-swipe")
        dumpTree("B-01-after-standard-swipe")

        let sheetNavigationBar = app.navigationBars["会话操作"]
        let sheetDelete = app.buttons.matching(identifier: "sidebar.delete.S1").firstMatch
        let sheetShown = sheetNavigationBar.waitForExistence(timeout: 5)
        let inlineArchive = app.buttons["sidebar.archive.S1"]
        print("B-DIAG afterSwipe sheetShown=\(sheetShown) sheetDeleteExists=\(sheetDelete.exists) inlineArchiveExists=\(inlineArchive.exists)")
        XCTAssertTrue(
            sheetShown,
            "B: AX5 左滑会话行后应出现会话操作 sheet（导航标题「会话操作」），5s 内未出现（侧栏仍在=\(sidebarStillOpen)，会话行仍存在=\(rowStillExists)）"
        )
        guard sheetShown else {
            diagnosticSwipeVariants(ax5: true)
            return
        }
        snapshot("B-01b-action-sheet")
        dumpTree("B-01b-action-sheet")
        XCTAssertTrue(sheetDelete.waitForExistence(timeout: 5), "B: 会话操作 sheet 内应出现删除按钮 sidebar.delete.S1")

        sheetDelete.tap()

        let alert = deleteConfirmationAlert()
        var appeared = false
        var waited: TimeInterval = 0
        while waited < 5 {
            if alert.exists {
                appeared = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        print("B-DIAG afterSheetDeleteTap waited=\(waited)s alertExists=\(appeared) sheetStillExists=\(sheetNavigationBar.exists) sheetDeleteStillExists=\(sheetDelete.exists) alertCount=\(app.alerts.count)")
        snapshot("B-02-after-sheet-delete-tap")
        dumpTree("B-02-after-sheet-delete-tap")
        XCTAssertTrue(
            appeared,
            "B: 点击会话操作 sheet 内「删除」后 5s 内未出现删除确认 alert（疑似 sheet 关闭与 alert 弹出的竞态；sheet 仍在=\(sheetNavigationBar.exists)）"
        )
        guard appeared else { return }

        XCTAssertTrue(alert.label.hasPrefix("删除「"), "B: 删除确认 alert 标题应以「删除「」开头，实际：\(alert.label)")
        XCTAssertTrue(alert.buttons["取消"].exists, "B: 删除确认 alert 应有「取消」按钮")
        alert.buttons["取消"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "B: 点「取消」后删除确认 alert 应消失")
        snapshot("B-03-after-cancel")
        dumpTree("B-03-after-cancel")
    }

    // MARK: - Helpers

    private func launch(scenario: String, extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments += extraArguments
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
    }

    private func waitForSidebarOpen() -> Bool {
        let close = app.buttons["sidebar.close"]
        let ok = close.waitForExistence(timeout: 10)
        if !ok {
            XCTFail("前置：夹具启动后侧边栏未打开（sidebar.close 不存在）")
            dumpTree("00-sidebar-not-open")
        }
        return ok
    }

    private func deleteConfirmationAlert() -> XCUIElement {
        app.alerts.matching(NSPredicate(format: "label BEGINSWITH %@", "删除「")).firstMatch
    }

    /// 仅诊断：用不同手势强度重试左滑，区分「手势识别被 Row Button/ScrollView
    /// 吞掉并误触为点选」与「完全没有手势反馈」。结果只记录，不改变场景断言。
    private func diagnosticSwipeVariants(ax5: Bool = false) {
        attemptSwipeVariant(tag: ax5 ? "B" : "A", name: "slowSwipeLeft") { row in
            row.swipeLeft(velocity: .slow)
        }
        attemptSwipeVariant(tag: ax5 ? "B" : "A", name: "pressDragLeft160") { row in
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: -160, dy: 0))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    private func attemptSwipeVariant(
        tag: String,
        name: String,
        gesture: (XCUIElement) -> Void
    ) {
        launch(scenario: "online-two-sessions")
        guard waitForSidebarOpen() else { return }
        let row = app.buttons["sidebar.session.S1"]
        guard row.waitForExistence(timeout: 8) else {
            print("\(tag)-DIAG variant=\(name) rowMissing")
            return
        }
        gesture(row)
        let sidebarOpen = app.buttons["sidebar.close"].exists
        let deleteExists = app.buttons.matching(identifier: "sidebar.delete.S1").firstMatch.exists
        let sheetExists = app.navigationBars["会话操作"].exists
        print("\(tag)-DIAG variant=\(name) sidebarStillOpen=\(sidebarOpen) deleteExists=\(deleteExists) sheetExists=\(sheetExists) rowHeight=\(row.exists ? String(describing: row.frame.height) : "n/a")")
        snapshot("\(tag)-variant-\(name)")
        dumpTree("\(tag)-variant-\(name)")
    }

    private func snapshot(_ tag: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let pngPath = "\(evidenceDirectory)/\(tag).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: pngPath))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = tag
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SNAPSHOT \(pngPath)")
    }

    /// 打印并落盘当前无障碍树；报告需要「实际看到的 accessibility 元素」。
    private func dumpTree(_ tag: String) {
        let tree = app.debugDescription
        let path = "\(evidenceDirectory)/\(tag)-ax-tree.txt"
        try? tree.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: tree)
        attachment.name = "\(tag)-ax-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("AXTREE \(path) (\(tree.count) chars)")
        print("=== BEGIN AX TREE \(tag) ===")
        print(tree)
        print("=== END AX TREE \(tag) ===")
    }
}
