import XCTest

final class ProjectSessionLifecycleUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-project-lifecycle"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testProjectArchiveRestoreAndConfirmedLocalDelete() {
        showRoot("项目")
        XCTAssertTrue(app.buttons["projects.row.P1"].exists)
        XCTAssertTrue(app.buttons["projects.row.P2"].exists)
        // quiet-v2：项目行只有一个点击目标（整行→详情浮层），行上不再并列「详情」按钮。

        app.buttons["projects.row.P1"].tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["projectDetail.archive"].tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForNonExistence(timeout: 5))

        let archived = app.descendants(matching: .any)["projects.archived.P1"]
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        archived.tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].waitForExistence(timeout: 5))
        XCTAssertFalse(archived.exists)

        app.buttons["projects.row.P1"].tap()
        app.descendants(matching: .any)["projectDetail.delete"].tap()
        let alert = app.alerts["删除「Alpha Workspace」？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        // quiet-v2 R7：确认框只说失去什么，不写安抚性保证。
        XCTAssertTrue(alert.staticTexts["本机的项目记录、会话记录与缓存都会清除。"].exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].exists)

        app.descendants(matching: .any)["projectDetail.delete"].tap()
        app.alerts["删除「Alpha Workspace」？"].buttons["删除"].tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projects.row.P2"].exists)

        app.buttons["打开侧边栏"].tap()
        let nextCurrentProject = app.buttons["sidebar.project.P2"]
        XCTAssertTrue(nextCurrentProject.waitForExistence(timeout: 5))
        XCTAssertTrue(nextCurrentProject.label.contains("当前项目"))
    }

    func testSidebarGroupsByProjectAndCrossProjectSelectionMovesContext() {
        let p1 = app.buttons["sidebar.project.P1"]
        let p2 = app.buttons["sidebar.project.P2"]
        XCTAssertTrue(p1.waitForExistence(timeout: 5))
        XCTAssertTrue(p2.exists)
        XCTAssertTrue(p1.label.contains("当前项目"))
        XCTAssertFalse(p2.label.contains("当前项目"))

        let s1 = app.buttons["sidebar.session.S1"]
        let s2 = app.buttons["sidebar.session.S2"]
        let s3 = app.buttons["sidebar.session.S3"]
        XCTAssertTrue(s1.exists && s2.exists && s3.exists)
        XCTAssertLessThan(s2.frame.minY, s1.frame.minY, "组内按最近活动排序")
        XCTAssertLessThan(s1.frame.minY, s3.frame.minY, "会话必须位于各自项目组内")
        XCTAssertFalse(s1.label.contains("provider"))
        XCTAssertFalse(s1.label.contains("P1"))

        s3.tap()
        XCTAssertTrue(app.navigationBars["Beta One"].waitForExistence(timeout: 5))
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(p2.waitForExistence(timeout: 5))
        XCTAssertTrue(p2.label.contains("当前项目"))
        XCTAssertFalse(p1.label.contains("当前项目"))
    }

    func testSessionRenameAndArchiveFallsThroughToNextSession() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.navigationBars["Alpha One"].waitForExistence(timeout: 5))

        renameCurrentSession(to: "Renamed Alpha")
        XCTAssertTrue(app.navigationBars["Renamed Alpha"].waitForExistence(timeout: 5))

        app.buttons["打开侧边栏"].tap()
        let renamedRow = app.buttons["sidebar.session.S1"]
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(renamedRow.label.contains("Renamed Alpha"))
        app.buttons["sidebar.session.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 5))

        app.buttons["会话操作"].tap()
        app.buttons["归档会话"].tap()
        XCTAssertTrue(app.navigationBars["Renamed Alpha"].waitForExistence(timeout: 8))

        app.buttons["打开侧边栏"].tap()
        XCTAssertFalse(app.buttons["sidebar.session.S2"].exists)
        app.buttons["sidebar.root.projects"].tap()
        XCTAssertTrue(app.navigationBars["项目"].waitForExistence(timeout: 5))
        app.buttons["projects.row.P1"].tap()
        XCTAssertTrue(app.buttons["projectDetail.session.S2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectDetail.restoreSession.S2"].exists)
        app.buttons["projectDetail.restoreSession.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 8))
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].exists { return }
        if app.buttons["sidebar.close"].exists {
            app.buttons["sidebar.close"].tap()
            XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
        }
        app.buttons["打开侧边栏"].tap()
        let root = app.buttons[sidebarRootIdentifier(for: title)]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    /// 侧边栏根入口按 identifier 定位（quiet-v2 §7）。
    private func sidebarRootIdentifier(for title: String) -> String {
        switch title {
        case "会话": return "sidebar.root.conversation"
        case "项目": return "sidebar.root.projects"
        case "设置": return "sidebar.root.settings"
        default: return "sidebar.root.\(title)"
        }
    }

    private func renameCurrentSession(to title: String) {
        app.buttons["会话操作"].tap()
        app.buttons["重命名会话"].tap()
        // 重命名是系统 alert：查询必须限定在 alert 内，否则会和页面其它文本框串台。
        let alert = app.alerts["重命名会话"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // 必须等键盘真的起来再输入：alert 刚出现时 tap 可能还没把焦点交给输入框，
        // 之后的 typeText 会静默落到别处，表现为「改了名但标题没变」。
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        let existing = (field.value as? String) ?? ""
        if !existing.isEmpty {
            // 多删几次是安全的：字段空了再按删除不会再产生字符。
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 8))
        }
        field.typeText(title)
        // 输入框在 alert 里偶发吞掉前置删除键：保存前先核对，不一致就整段重来一次。
        if (field.value as? String) != title {
            let current = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 8))
            field.typeText(title)
        }
        // alert 内的 TextField 写回 @State 有延迟：立刻点保存会拿到旧值，
        // 表现为「输入框里是新名字，但保存后标题没变」。
        sleep(1)
        alert.buttons["保存"].tap()
    }
}
