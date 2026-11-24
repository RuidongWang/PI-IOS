import XCTest
import UIKit

final class ProjectsLaunchUITests: XCTestCase {
    private var app: XCUIApplication!
    private var expectedHost = ""
    private let expectedProjectName = "pi-test-proj"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    private func launchOnConfiguredHost() throws {
        let configuredHost = ProcessInfo.processInfo.environment["PI_IOS_EXPECTED_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredHost, !configuredHost.isEmpty else {
            throw XCTSkip("Set PI_IOS_EXPECTED_HOST to the QA adaptor before running live project checks.")
        }
        expectedHost = configuredHost
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        showRoot("项目")
        let address = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@\(expectedHost):")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "The current adaptor must match PI_IOS_EXPECTED_HOST.")
    }

    func testProjectsScreenAndAddProjectAffordanceAreDiscoverable() throws {
        try launchOnConfiguredHost()
        openProjectBrowser()

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "projectBrowser.sheet")
            .firstMatch
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 10),
            "Opening the project browser must expose projectBrowser.sheet."
        )
        XCTAssertTrue(
            app.textFields["projectBrowser.name"].waitForExistence(timeout: 5),
            "The add-project sheet must expose its project name field."
        )
        XCTAssertTrue(
            app.buttons["projectBrowser.register"].waitForExistence(timeout: 5),
            "The add-project sheet must expose its register button."
        )

        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    func testEditedProjectNameSurvivesDirectoryNavigation() throws {
        try launchOnConfiguredHost()
        openProjectBrowser()

        let name = app.textFields["projectBrowser.name"]
        let currentPath = app.staticTexts["projectBrowser.currentPath"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "The project browser must show the name field.")
        XCTAssertTrue(currentPath.waitForExistence(timeout: 15), "The project browser must load the current directory.")

        let typedMarker = "E2E-NAME-KEEP"
        let browser = app.collectionViews["projectBrowser.sheet"]
        let window = app.windows.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        for _ in 0..<8 where !window.frame.intersects(name.frame) {
            browser.swipeUp()
        }
        XCTAssertTrue(
            window.frame.intersects(name.frame),
            "The project name field must be reachable by scrolling."
        )
        name.tap()
        name.typeText(" \(typedMarker)")
        XCTAssertTrue(
            (name.value as? String)?.contains(typedMarker) == true,
            "The project name field must accept user text."
        )

        let navigationTarget = app.buttons
            .matching(
                NSPredicate(
                    format: "isEnabled == true AND (identifier == %@ OR identifier BEGINSWITH %@)",
                    "projectBrowser.parent",
                    "projectBrowser.entry."
                )
            )
            .firstMatch
        XCTAssertTrue(navigationTarget.waitForExistence(timeout: 25), "The QA directory must have a navigable entry.")
        for _ in 0..<3 where !navigationTarget.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(
            navigationTarget.isHittable,
            "A directory navigation action must remain reachable."
        )
        let previousPath = currentPath.label
        navigationTarget.tap()

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", previousPath),
            object: currentPath
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 10),
            .completed,
            "Parent navigation must load a different server directory."
        )
        XCTAssertTrue(
            (name.value as? String)?.contains(typedMarker) == true,
            "Directory navigation must not overwrite a name edited by the user."
        )

        app.buttons["取消"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["projectBrowser.sheet"]
                .waitForNonExistence(timeout: 5)
        )
    }

    func testProjectsShowCurrentServerAndCurrentProject() throws {
        try launchOnConfiguredHost()
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", expectedProjectName))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The projects screen must show the current project as a read-only navigation row."
        )
    }

    func testUnreadableChildClearsStaleParentAndDisablesRegistration() throws {
        guard let deniedPath = ProcessInfo.processInfo.environment["PI_IOS_UI_TEST_UNREADABLE_DIRECTORY"],
              deniedPath.hasPrefix("/"), deniedPath != "/" else {
            throw XCTSkip("Provide an existing unreadable child directory on the QA PI-adaptor.")
        }
        try launchOnConfiguredHost()
        openProjectBrowser()
        let currentPath = app.staticTexts["projectBrowser.currentPath"]
        XCTAssertTrue(currentPath.waitForExistence(timeout: 15))
        let registerButton = app.buttons["projectBrowser.register"]
        XCTAssertTrue(registerButton.waitForExistence(timeout: 10))
        let browser = app.collectionViews.firstMatch
        XCTAssertTrue(browser.exists, "The project browser list must remain visible.")
        let containerPath = (deniedPath as NSString).deletingLastPathComponent

        for _ in 0..<20 where currentPath.label != containerPath {
            let previousPath = currentPath.label
            let next: XCUIElement
            if containerPath.hasPrefix(previousPath == "/" ? "/" : previousPath + "/") {
                let remainder = containerPath.dropFirst(previousPath == "/" ? 1 : previousPath.count + 1)
                let component = try XCTUnwrap(remainder.split(separator: "/").first)
                let child = previousPath == "/" ? "/\(component)" : "\(previousPath)/\(component)"
                next = app.buttons["projectBrowser.entry.\(child)"]
                if !next.exists {
                    for _ in 0..<12 where !next.exists {
                        browser.swipeUp()
                    }
                }
            } else {
                next = app.buttons["projectBrowser.parent"]
            }
            XCTAssertTrue(next.waitForExistence(timeout: 5), "The unreadable fixture must be under the QA host's browsable tree.")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            for _ in 0..<10 {
                if next.isHittable, next.frame.maxY < registerButton.frame.minY - 8 { break }
                browser.swipeUp()
            }
            XCTAssertLessThan(
                next.frame.maxY,
                registerButton.frame.minY - 4,
                "Each directory row must be scrolled above the fixed registration footer before tapping."
            )
            next.tap()
            let moved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", previousPath), object: currentPath
            )
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        }
        XCTAssertEqual(currentPath.label, containerPath)
        let child = app.buttons["projectBrowser.entry.\(deniedPath)"]
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: child)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        for _ in 0..<10 {
            if child.isHittable, child.frame.maxY < registerButton.frame.minY - 8 { break }
            browser.swipeUp()
        }
        XCTAssertTrue(child.isHittable, "The unreadable directory row must be tappable, not covered by the toolbar.")
        XCTAssertLessThan(
            child.frame.maxY,
            registerButton.frame.minY - 4,
            "The directory row must be scrolled above the fixed registration footer before tapping."
        )
        child.tap()

        let deadline = Date().addingTimeInterval(10)
        var observedPath = currentPath.label
        while Date() < deadline {
            let pathElement = app.staticTexts["projectBrowser.currentPath"]
            if pathElement.exists {
                observedPath = pathElement.label
            }
            if observedPath == deniedPath { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(
            observedPath,
            deniedPath,
            "Tapping an unreadable directory must keep the attempted path visible. Labels: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.buttons["projectBrowser.retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectBrowser.parent"].exists)
        XCTAssertFalse(app.buttons["projectBrowser.register"].isEnabled)
        app.buttons["取消"].tap()
    }

    func testSettingsShowHostVersionAndSystemdState() throws {
        try launchOnConfiguredHost()
        showRoot("设置")

        let hostVersion = app.descendants(matching: .any)["settings.hostVersion"]
        XCTAssertTrue(hostVersion.waitForExistence(timeout: 15), "The connected adaptor must report its version.")

        let diagnostics = app.buttons["settings.advancedDiagnostics.toggle"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        if diagnostics.value as? String == "collapsed" { diagnostics.tap() }
        let systemd = app.descendants(matching: .any)["settings.hostUnit"]
        XCTAssertTrue(
            systemd.waitForExistence(timeout: 10),
            "Settings must expose the systemd status row."
        )

        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "NOT (label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@)",
                "查询中",
                "未查询"
            ),
            object: systemd
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 20),
            .completed,
            "The systemd row must settle on a real status value. Current label: \(systemd.label)"
        )
        XCTAssertTrue(
            systemd.label.range(
                of: #"\b(active|inactive|failed)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            "The settled systemd row must include a status value. Current label: \(systemd.label)"
        )
        let notifications = app.descendants(matching: .any)["settings.notificationRow"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5), "Notification settings must remain accessible.")
        XCTAssertFalse(app.staticTexts["不会收到后台推送"].exists)
    }

    // 协议预设与 localhost 默认值不依赖真实 Host，由 UIRegressionSuiteTests 的
    // MDL-02/03 在确定性夹具中逐协议覆盖，不在本真实 Host 套件重复执行。

    func testInstallAdaptorScreenIsReachableWithoutStartingInstallation() throws {
        try launchOnConfiguredHost()
        showRoot("设置")

        let host = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "settings.server.", "@\(expectedHost):"
        )).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 8), "The QA adaptor must appear in Settings.")
        host.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 8))

        let install = app.buttons["servers.install"]
        for _ in 0..<6 where !install.isHittable { app.swipeUp() }
        XCTAssertTrue(install.isHittable, "The QA adaptor must expose the install entry.")
        install.tap()

        let installBar = app.navigationBars
            .matching(NSPredicate(format: "identifier CONTAINS %@", "安装"))
            .firstMatch
        XCTAssertTrue(installBar.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.textFields["installHost.port"].waitForExistence(timeout: 5),
            "The installation screen must expose its fixed loopback port."
        )
        XCTAssertTrue(
            app.buttons["installHost.start"].exists,
            "The installation screen must expose the real install action without auto-starting it."
        )
    }

    func testConversationAttachmentIsAvailableAndSidebarSearchIsDiscoverable() throws {
        try launchOnConfiguredHost()

        let session = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.session."))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 8), "The QA project must contain an active session.")
        session.tap()

        let attachment = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "附件"))
            .firstMatch
        XCTAssertTrue(
            attachment.waitForExistence(timeout: 15),
            "An opened conversation must expose the attachment affordance."
        )
        XCTAssertTrue(
            attachment.isEnabled,
            "An online conversation must expose the v2 image attachment picker."
        )
        XCTAssertFalse(
            app.staticTexts["JPEG / PNG / WebP · 单张 ≤20 MiB · 最多 10 张"].exists,
            "The composer no longer shows the attachment limits caption."
        )

        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()

        XCTAssertTrue(
            app.textFields["sidebar.search"].waitForExistence(timeout: 5),
            "The sidebar must expose conversation/project search."
        )
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", expectedProjectName))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The sidebar must show the current project group."
        )
        XCTAssertTrue(app.buttons["sidebar.root.projects"].exists, "The sidebar project root entry must exist.")
        XCTAssertTrue(app.buttons["sidebar.root.settings"].exists, "The sidebar settings root entry must exist.")
    }

    func testLiveProviderImportUsingEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["PI_IOS_LIVE_LLM_BASE_URL"], !baseURL.isEmpty,
              let apiKey = environment["PI_IOS_LIVE_LLM_API_KEY"], !apiKey.isEmpty
        else {
            throw XCTSkip("Provide PI_IOS_LIVE_LLM_BASE_URL and PI_IOS_LIVE_LLM_API_KEY to run the live provider import.")
        }

        try launchOnConfiguredHost()
        showRoot("设置")
        let models = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "模型服务"))
            .firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10))
        models.tap()

        let baseURLField = app.textFields["models.baseURL"]
        XCTAssertTrue(baseURLField.waitForExistence(timeout: 5))
        baseURLField.tap()
        let existingBase = (baseURLField.value as? String) ?? ""
        if !existingBase.isEmpty {
            baseURLField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingBase.count))
        }
        baseURLField.typeText(baseURL)

        let keyField = app.secureTextFields["models.apiKey"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        UIPasteboard.general.string = apiKey
        addTeardownBlock {
            UIPasteboard.general.string = nil
        }
        keyField.tap()
        keyField.press(forDuration: 1)
        let paste = app.menuItems["粘贴"].firstMatch
        if paste.waitForExistence(timeout: 2) {
            paste.tap()
        } else {
            let englishPaste = app.menuItems["Paste"].firstMatch
            XCTAssertTrue(englishPaste.waitForExistence(timeout: 2))
            englishPaste.tap()
        }
        UIPasteboard.general.string = nil

        let fetch = app.buttons["获取模型"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let importButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "导入 "))
            .firstMatch
        XCTAssertTrue(
            importButton.waitForExistence(timeout: 30),
            "The configured endpoint's /models must resolve into importable model rows."
        )
        importButton.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "已导入 "))
                .firstMatch
                .waitForExistence(timeout: 30),
            "RACP provider/create must return a success receipt for the discovered models."
        )
    }

    func testLiveSessionHistoryMatchesHostContent() throws {
        guard let expected = ProcessInfo.processInfo.environment["PI_IOS_LIVE_HISTORY_EXPECTED"],
              !expected.isEmpty
        else {
            throw XCTSkip("Provide PI_IOS_LIVE_HISTORY_EXPECTED for the live history projection probe.")
        }
        try launchOnConfiguredHost()
        let session = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.session."))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", expected))
                .firstMatch
                .waitForExistence(timeout: 20),
            "The conversation must render the same canonical text stored by PI-adaptor."
        )
    }

    private func openProjectBrowser() {
        let addProject = app.buttons["projects.add"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 8), "The add-project control must exist.")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: addProject)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "The QA adaptor must expose a browsable project catalog.")
        addProject.tap()
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }

        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "The root navigation menu must exist.")
        menu.tap()

        let root = app.buttons[Self.sidebarRootIdentifier(for: title)].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), "The \(title) root entry must exist.")
        root.tap()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 10),
            "The \(title) screen must be reachable without mutating server state."
        )
    }

    /// 侧边栏根入口按 identifier 定位（quiet-v2 §7：定位与文案解耦）。
    private static func sidebarRootIdentifier(for title: String) -> String {
        switch title {
        case "会话": return "sidebar.root.conversation"
        case "项目": return "sidebar.root.projects"
        case "设置": return "sidebar.root.settings"
        default: return "sidebar.root.\(title)"
        }
    }
}
