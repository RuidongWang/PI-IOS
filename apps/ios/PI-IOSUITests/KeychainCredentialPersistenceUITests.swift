import XCTest

/// 回归：保存服务器凭证必须真正写进 Keychain。
///
/// 用 `CODE_SIGNING_ALLOWED=NO` 构建的 App 是 linker-signed，没有
/// `application-identifier`，模拟器里的 `SecItemAdd` 会返回 -34018，
/// 表单只能报「凭证写入 Keychain 失败」，用户无法保存任何服务器。
/// 这里走密码认证路径（不涉及私钥材料），确认凭证写入成功后才进入连接测试。
final class KeychainCredentialPersistenceUITests: XCTestCase {
    private let app = XCUIApplication()
    private let accountName = "keychain-ui-\(UUID().uuidString.prefix(8).lowercased())"
    private var attemptedSave = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "empty-state"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        defer { app.terminate() }
        if attemptedSave { deleteCreatedHostIfPresent() }
    }

    func testPasswordCredentialIsPersistedToKeychain() throws {
        openServersScreen()

        replace(app.textFields["servers.name"].firstMatch, with: accountName)
        replace(app.textFields["servers.host"].firstMatch, with: "127.0.0.1")
        replace(app.textFields["servers.port"].firstMatch, with: "1")
        replace(app.textFields["servers.username"].firstMatch, with: accountName)

        let password = app.secureTextFields["servers.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "密码输入框")
        password.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        password.typeText("keychain-regression-password")
        dismissKeyboard()

        attemptedSave = true
        saveAndExpectSSHTest()

        app.buttons["BackButton"].tap()
        XCTAssertTrue(createdHost.waitForExistence(timeout: 5), "服务器记录应可重新打开")
        createdHost.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5))
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertEqual(password.placeholderValue, "留空沿用已保存凭证")
        let reopenedValue = password.value as? String ?? ""
        XCTAssertTrue(reopenedValue.isEmpty || reopenedValue == password.placeholderValue as? String)
        // 新表单的密码为空。能再次进入 SSH 测试，说明表单从 Keychain 取回了凭证。
        saveAndExpectSSHTest()
    }

    private var createdHost: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "settings.server.", accountName
        )).firstMatch
    }

    private func saveAndExpectSSHTest() {
        let saved = app.staticTexts["已保存「\(accountName)」"]
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5))
        let save = app.buttons["servers.saveAndTest"].firstMatch
        scrollUntilHittable(save)
        XCTAssertTrue(save.isHittable)
        save.tap()
        // 只有完成真实 SSH 测试才会显示这条保存提示。Keychain 写入或读取失败会提前返回。
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "测试结果：")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 25), result.exists ? result.label : "应完成 SSH 测试并显示保存提示")
        XCTAssertTrue(result.exists, "应显示本次 SSH 测试结果")
        XCTAssertTrue(saved.waitForNonExistence(timeout: 5), "等待保存提示收起后再返回")
    }

    // MARK: - 导航与操作

    private func openServersScreen() {
        if !app.navigationBars["设置"].waitForExistence(timeout: 3) {
            let menu = app.buttons["打开侧边栏"].firstMatch.exists
                ? app.buttons["打开侧边栏"].firstMatch
                : app.buttons["line.3.horizontal"].firstMatch
            if menu.waitForExistence(timeout: 5) { menu.tap() }
            let settings = app.buttons["设置"].firstMatch
            if settings.waitForExistence(timeout: 5) { settings.tap() }
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8), "设置页")

        let add = app.buttons["settings.addServer"].firstMatch.exists
            ? app.buttons["settings.addServer"].firstMatch
            : app.buttons["添加服务器"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "添加入口")
        add.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5), "新增服务器页")
    }

    private func deleteCreatedHostIfPresent() {
        if app.navigationBars["服务器"].exists { app.buttons["BackButton"].tap() }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        guard createdHost.exists else { return }
        createdHost.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5))
        let delete = app.buttons["servers.delete"].firstMatch
        scrollUntilHittable(delete)
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        let confirm = app.buttons["删除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        XCTAssertFalse(createdHost.exists)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        for _ in 0..<8 where field.exists && field.frame.minY < 130 {
            app.swipeDown()
        }
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
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

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeUp()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 2)
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
}
