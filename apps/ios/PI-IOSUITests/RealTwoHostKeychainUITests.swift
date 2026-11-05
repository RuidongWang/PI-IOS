import XCTest

final class RealTwoHostKeychainUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 这台用例会真实配对、连接两台 host；必须先过显式门禁再启动，
    /// 否则默认跑全量套件时应用会读取真实状态并自动连接已配对 host。
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["PI_IOS_TWO_HOST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set PI_IOS_TWO_HOST_KEYCHAIN=1 for the real two-host keychain run.")
        }
        app = XCUIApplication()
        app.launch()
    }

    func testPairTwoRealHostsAndReconnectEachScopedToken() throws {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["PI_IOS_HOST_B_PAIRING_TOKEN"] ?? ""
        let hostAName = environment["PI_IOS_HOST_A_NAME"] ?? "嗷嗷"
        let hostBName = environment["PI_IOS_HOST_B_NAME"] ?? "QA PI-adaptor B"

        showRoot("设置")
        let hostBRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", hostBName))
            .firstMatch
        let hostARow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", hostAName))
            .firstMatch
        guard hostBRow.waitForExistence(timeout: 10), hostARow.exists else {
            throw XCTSkip(
                "Configure both real PI-adaptor records and set PI_IOS_HOST_B_PAIRING_TOKEN for the two-PI-adaptor keychain run."
            )
        }
        openHost(hostBName)

        // 生产占位符是 `ppt2.…`（v2 令牌）。写死旧 `ppt1.…` 会让未配对 host
        // 永远走「已经配对」分支，首次配对路径反而没人覆盖。
        let field = app.secureTextFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS %@ OR label CONTAINS %@", "ppt2", "ppt2")
        ).firstMatch
        if field.waitForExistence(timeout: 8) {
            guard !token.isEmpty else {
                throw XCTSkip("Provide PI_IOS_HOST_B_PAIRING_TOKEN for the first real two-PI-adaptor pairing run.")
            }
            UIPasteboard.general.string = token
            addTeardownBlock { UIPasteboard.general.string = nil }
            field.tap()
            field.press(forDuration: 1)
            let paste = app.menuItems["粘贴"].firstMatch
            if paste.waitForExistence(timeout: 2) {
                paste.tap()
            } else {
                app.menuItems["Paste"].firstMatch.tap()
            }
            UIPasteboard.general.string = nil

            let pair = app.buttons["配对并连接"]
            XCTAssertTrue(pair.waitForExistence(timeout: 5))
            pair.tap()
            XCTAssertTrue(
                app.staticTexts["配对成功；设备令牌已保存"].waitForExistence(timeout: 40),
                "PI-adaptor B must pair and persist its scoped device token."
            )
        } else {
            XCTAssertTrue(
                app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10),
                "An already-paired PI-adaptor B must expose its persisted token."
            )
        }
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "PI-adaptor B must reconnect with its newly persisted token."
        )

        backToServerList()
        openHost(hostAName)
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        connectPiHost()
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "PI-adaptor A must keep its own token and reconnect independently."
        )

        backToServerList()
        openHost(hostBName)
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        connectPiHost()
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "PI-adaptor B must reconnect again without borrowing PI-adaptor A's token."
        )
    }

    private func connectPiHost() {
        let connect = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "连接 PI-adaptor"))
            .firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
    }

    private func openHost(_ name: String) {
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 10))
    }

    private func backToServerList() {
        let nav = app.navigationBars["服务器"]
        let back = nav.buttons.firstMatch
        if back.exists {
            back.tap()
        } else {
            app.swipeRight()
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }
}
