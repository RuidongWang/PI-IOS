import XCTest

/// 回归：保存服务器凭证必须真正写进 Keychain。
///
/// 用 `CODE_SIGNING_ALLOWED=NO` 构建的 App 是 linker-signed，没有
/// `application-identifier`，模拟器里的 `SecItemAdd` 会返回 -34018，
/// 表单只能报「凭证写入 Keychain 失败」，用户无法保存任何服务器。
/// 这里走密码认证路径（不涉及私钥材料），确认凭证写入成功后才进入连接测试。
final class KeychainCredentialPersistenceUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testPasswordCredentialIsPersistedToKeychain() throws {
        openServersScreen()

        replace(app.textFields["192.168.1.10"].firstMatch, with: "127.0.0.1")
        replace(app.textFields["22"].firstMatch, with: "1")
        replace(app.textFields["pi"].firstMatch, with: "pi")

        let password = app.secureTextFields["服务器登录密码"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "密码输入框")
        password.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        password.typeText("keychain-regression-password")
        dismissKeyboard()

        let save = app.buttons["保存并测试连接"].firstMatch
        scrollUntilHittable(save)
        save.tap()

        let keychainFailure = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "凭证写入 Keychain 失败")
        ).firstMatch
        XCTAssertFalse(
            keychainFailure.waitForExistence(timeout: 5),
            "凭证必须写入 Keychain；实际提示：\(keychainFailure.label)"
        )

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "测试结果")
            ).firstMatch.waitForExistence(timeout: 25),
            "凭证写入成功后应进入连接测试并给出结果"
        )

        deleteCreatedHost()
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
            : app.buttons["＋ 添加服务器"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "添加入口")
        add.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 5), "新增服务器页")
    }

    /// 保存会先创建本机记录再测连接；测试结束把这条 127.0.0.1 记录删掉，
    /// 避免污染模拟器上已有的服务器列表。
    private func deleteCreatedHost() {
        let delete = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "删除这台服务器")
        ).firstMatch
        scrollUntilHittable(delete)
        guard delete.exists, delete.isHittable else { return }
        delete.tap()
        let confirm = app.buttons["删除"].firstMatch
        guard confirm.waitForExistence(timeout: 5) else { return }
        confirm.tap()
        _ = app.navigationBars["设置"].waitForExistence(timeout: 10)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        for _ in 0..<8 where field.exists && field.frame.minY < 130 {
            app.swipeDown()
        }
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        let current = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !current.isEmpty, current != placeholder || value.isEmpty {
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
