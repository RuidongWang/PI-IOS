import XCTest
import UIKit

/// 设置 → 运行日志：入口、开关/等级/时间格式/导出/清空元素与单选态（AC-L1/L2/L3/L5/L7）。
///
/// 依赖 `empty-state` 夹具：不连真实服务器，且空夹具没有主机，按 LandingRule
/// 直接落在设置根页（与 `UIRegressionSuiteTests.testG01EmptyState` 同一前提）。
final class LogModuleUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "empty-state"
        app.launchEnvironment["PI_IOS_UI_CLIPBOARD_PROBE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        UIPasteboard.general.string = nil
        app.terminate()
    }

    func testLogsSettingsEntryAndSelections() {
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15), "空夹具首屏为设置")

        // 入口：设置页「日志」分组，副标题显示启用状态与当前等级。
        let entry = app.buttons["settings.logs"]
        scrollUntilHittable(entry)
        XCTAssertTrue(entry.exists, "设置页必须有「运行日志」入口")
        XCTAssertTrue(entry.label.contains("记录中"), "入口副标题应显示记录中与等级：\(entry.label)")
        entry.tap()

        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 8), "进入运行日志页")

        let capacityNotice = app.descendants(matching: .any)
            .matching(identifier: "logs.capacityNotice")
            .firstMatch
        scrollUntilHittable(capacityNotice)
        XCTAssertTrue(capacityNotice.waitForExistence(timeout: 5), "必须说明容量轮转而非条数截断")
        XCTAssertEqual(capacityNotice.label, "日志不按条数截断；较早记录可能因容量轮转被淘汰。")

        // 开关：默认开启（PILogConfiguration.default）。
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "logs.toggleEnabled")
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "日志开关")

        // 等级：默认「信息」选中；点「警告」后选中态转移到警告。
        let info = option("logs.level.info")
        scrollUntilHittable(info)
        XCTAssertTrue(info.exists, "信息等级行")
        XCTAssertTrue(info.isSelected, "默认等级为信息")

        let warn = option("logs.level.warn")
        scrollUntilHittable(warn)
        XCTAssertTrue(warn.exists, "警告等级行")
        XCTAssertTrue(option("logs.level.debug").exists, "调试等级行")
        warn.tap()
        XCTAssertTrue(waitUntilSelected(warn), "点「警告」后应为选中态")
        XCTAssertFalse(info.isSelected, "等级选中态应唯一")

        // 时间格式：默认「完整时间」；点「仅时间」后选中。
        let dateTime = option("logs.timeFormat.date_time")
        let timeOnly = option("logs.timeFormat.time_only")
        scrollUntilHittable(timeOnly)
        XCTAssertTrue(dateTime.exists, "完整时间行")
        XCTAssertTrue(option("logs.timeFormat.iso8601").exists, "ISO 8601 行")
        XCTAssertTrue(option("logs.timeFormat.epoch_millis").exists, "毫秒时间戳行")
        XCTAssertTrue(timeOnly.exists, "仅时间行")
        XCTAssertTrue(dateTime.isSelected, "默认时间格式为完整时间")
        timeOnly.tap()
        XCTAssertTrue(waitUntilSelected(timeOnly), "点「仅时间」后应为选中态")
        XCTAssertFalse(dateTime.isSelected, "时间格式选中态应唯一")

        // 导出与清空：元素必须存在（本用例不触发系统分享面板与清空确认）。
        let export = app.buttons["logs.export"]
        scrollUntilHittable(export)
        XCTAssertTrue(export.exists, "导出日志按钮")

        // PIDangerRow 的标识可能落在合并后的整行元素上，用任意类型匹配更稳。
        let clear = app.descendants(matching: .any)
            .matching(identifier: "logs.clear")
            .firstMatch
        scrollUntilHittable(clear)
        XCTAssertTrue(clear.exists, "清空日志行")
    }

    /// 导出必须真的弹出系统分享面板；清空必须二次确认且可取消（AC-L5/L7）。
    func testExportPresentsShareSheetAndClearRequiresConfirmation() {
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15), "空夹具首屏为设置")
        let entry = app.buttons["settings.logs"]
        scrollUntilHittable(entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "设置页必须有「运行日志」入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 8), "进入运行日志页")

        let export = app.buttons["logs.export"]
        scrollUntilHittable(export)
        XCTAssertTrue(export.waitForExistence(timeout: 5), "导出日志按钮")
        export.tap()

        // iOS 的分享面板在 iPhone 上以 sheet 呈现；不同系统版本的容器标识不同，
        // 这里用「ActivityListView」与任意 sheet 双条件等待，避免把系统差异当产品缺陷。
        let activityList = app.otherElements["ActivityListView"].firstMatch
        let anySheet = app.sheets.firstMatch
        let appeared = activityList.waitForExistence(timeout: 15)
            || anySheet.waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "导出后必须弹出系统分享面板")

        // iOS 27 模拟器有时不会处理远程分享视图的关闭按钮。外层 sheet 也支持下拖关闭。
        let shareClose = app.buttons["header.closeButton"].firstMatch
        let shareCloseByLabel = app.buttons["关闭"].firstMatch
        if shareClose.waitForExistence(timeout: 10) {
            shareClose.tap()
        } else if shareCloseByLabel.waitForExistence(timeout: 3) {
            shareCloseByLabel.tap()
        }
        if !activityList.waitForNonExistence(timeout: 3) || anySheet.exists {
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.09))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.75))
            top.press(forDuration: 0.05, thenDragTo: bottom)
        }
        XCTAssertTrue(activityList.waitForNonExistence(timeout: 8), "分享面板应能关闭")
        XCTAssertTrue(anySheet.waitForNonExistence(timeout: 4), "外层面板应已关闭")
        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 8), "关闭分享面板后回到日志页")

        // 清空：先取消，页面仍在；不清空是 AC-L7 的一部分。
        let clear = app.buttons["logs.clear"].firstMatch
        scrollUntilHittable(clear)
        XCTAssertTrue(clear.exists, "清空日志行")
        clear.tap()
        let confirm = app.staticTexts["清空日志？"].waitForExistence(timeout: 5)
            || app.sheets.firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(confirm, "清空必须二次确认")
        if app.buttons["取消"].firstMatch.exists {
            app.buttons["取消"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).tap()
        }
        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 5), "取消清空后仍在日志页")
    }

    /// 关闭后保留历史，重新开启后继续追加，确认清空才回到空态。
    func testLoggingDisableReenableAndConfirmedClear() {
        openLogsPage()
        // 先清空历史，让「记录条数」在本用例内可确定地增长，避免模拟器残留记录
        // 影响追加判断；当前列表不再按 50 条截断。
        clearAllLogs()

        // 夹具默认开启、等级 info；切换时间格式会写一条「日志时间格式=…」，制造本次运行的记录。
        let timeOnly = option("logs.timeFormat.time_only")
        scrollUntilHittable(timeOnly)
        XCTAssertTrue(timeOnly.exists, "仅时间行")
        timeOnly.tap()
        XCTAssertTrue(waitUntilSelected(timeOnly), "点「仅时间」后应为选中态")

        let preview = app.descendants(matching: .any)
            .matching(identifier: "logs.preview")
            .firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "切换时间格式后预览应有记录")

        // 关闭日志。
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "logs.toggleEnabled")
            .firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "日志开关")
        scrollUntilHittable(toggle)
        toggle.tap()
        XCTAssertTrue(waitForToggleValue(toggle, expected: "0"), "关闭后开关应为关")

        // 提示出现；预览仍然存在（走非空分支），说明历史没有被内存覆盖掉。
        let notice = app.descendants(matching: .any)
            .matching(identifier: "logs.disabledNotice")
            .firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 8), "关闭日志后应显示「已关闭」提示")
        XCTAssertTrue(preview.exists, "关闭日志后已有记录必须仍在预览中")

        // 关闭期间不再新增：连续两个刷新周期条数稳定，且大于 0（历史仍在）。
        let stableCount = waitForStableRecordCount()
        XCTAssertNotNil(stableCount, "应读到记录条数")
        XCTAssertGreaterThan(stableCount ?? 0, 0, "关闭日志不能把已有记录清空")

        goBack()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "关闭后回到设置")
        let closedEntry = app.buttons["settings.logs"]
        scrollUntilHittable(closedEntry)
        XCTAssertTrue(waitUntilLabelContains(closedEntry, "已关闭"), "设置页副标题应显示已关闭")
        closedEntry.tap()
        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 8), "再次进入运行日志页")
        XCTAssertTrue(waitForToggleValue(toggle, expected: "0"), "重新进入后开关仍为关")

        // 重新开启：提示消失，且继续追加记录，历史仍在。
        scrollUntilHittable(toggle)
        toggle.tap()
        XCTAssertTrue(waitForToggleValue(toggle, expected: "1"), "重新开启后开关应为开")
        XCTAssertTrue(notice.waitForNonExistence(timeout: 8), "重新开启后关闭提示应消失")
        XCTAssertTrue(
            waitUntilRecordCountGreaterThan(stableCount ?? 0, timeout: 10),
            "重新开启后应继续记录（条数增加），而不是清空重来"
        )
        XCTAssertTrue(preview.exists, "重新开启后历史记录仍在预览中")
        clearAllLogs()
    }

    /// 只通过真实设置动作制造 54 条记录，验证预览与复制都不受旧 50 条上限影响。
    /// 剪贴板必须与完整导出一致，不能用 toast 代替全文断言。
    func testCopyAllLogsBeyondFiftyContainsFullExport() {
        openLogsPage()
        clearAllLogs()

        let timeOnly = option("logs.timeFormat.time_only")
        let iso8601 = option("logs.timeFormat.iso8601")
        scrollUntilHittable(timeOnly)
        scrollUntilHittable(iso8601)
        XCTAssertTrue(timeOnly.exists && iso8601.exists, "两种时间格式行")
        for _ in 0..<27 {
            for format in [timeOnly, iso8601] {
                format.tap()
                XCTAssertTrue(waitUntilSelected(format), "每次格式切换都必须真实生效")
            }
        }
        XCTAssertTrue(
            waitUntilRecordCount(54, timeout: 10),
            "54 次设置变更必须全部反映到预览，不能在 51...53 条时提前采样"
        )
        guard let visibleCount = recordCount() else {
            return XCTFail("读取日志计数失败")
        }

        UIPasteboard.general.string = nil
        let copyAll = app.descendants(matching: .any)
            .matching(identifier: "logs.copyAll")
            .firstMatch
        scrollUntilHittable(copyAll)
        XCTAssertTrue(copyAll.exists, "导出分组必须有「复制全部日志」按钮")
        copyAll.tap()

        let toast = app.staticTexts["日志已复制"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 12), "复制全部日志后应出现「日志已复制」提示")
        guard let exported = waitForClipboard(matches: { $0.hasPrefix("PI-IOS 运行日志\n") }) else {
            return XCTFail("复制全部日志必须写入系统剪贴板")
        }

        let countPrefix = "记录条数："
        guard let countLine = exported.components(separatedBy: .newlines).first(where: {
            $0.hasPrefix(countPrefix)
        }), let exportedCount = Int(countLine.dropFirst(countPrefix.count)) else {
            return XCTFail("导出文本缺少记录条数元信息")
        }
        if exportedCount != visibleCount {
            let diagnostic = "visible=\(visibleCount) exported=\(exportedCount)\n\(exported)"
            try? diagnostic.write(
                to: URL(fileURLWithPath: "/tmp/pi-ios-log-count-mismatch.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        XCTAssertEqual(exportedCount, visibleCount, "导出条数必须与页面当前全部保留记录一致")
        XCTAssertGreaterThan(exportedCount, 50, "导出不得停在旧 50 条上限")
        XCTAssertEqual(
            exported.components(separatedBy: "日志时间格式=time_only").count - 1,
            27,
            "27 条 time_only 变更必须全部保留"
        )
        XCTAssertEqual(
            exported.components(separatedBy: "日志时间格式=iso8601").count - 1,
            27,
            "27 条 iso8601 变更必须全部保留"
        )
    }

    // MARK: - Helpers

    /// 空夹具首屏 → 设置根页 → 运行日志页。
    private func openLogsPage() {
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15), "空夹具首屏为设置")
        let entry = app.buttons["settings.logs"]
        scrollUntilHittable(entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "设置页必须有「运行日志」入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["运行日志"].waitForExistence(timeout: 8), "进入运行日志页")
    }

    /// 通过 UI 清空日志（二次确认），让用例对「记录条数」有确定预期。
    private func clearAllLogs() {
        let clear = app.buttons["logs.clear"].firstMatch
        scrollUntilHittable(clear)
        XCTAssertTrue(clear.exists, "清空日志行")
        clear.tap()
        let confirm = app.buttons["清空"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "清空二次确认的确认按钮")
        confirm.tap()
        let empty = app.descendants(matching: .any)
            .matching(identifier: "logs.emptyState")
            .firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 8), "清空日志后应回到空态")
    }

    private func waitForClipboard(
        timeout: TimeInterval = 5,
        matches: @escaping (String) -> Bool
    ) -> String? {
        var matched: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let value = self.app.descendants(matching: .any)["uitest.clipboard.contents"].label
                guard matches(value) else { return false }
                matched = value
                return true
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { return nil }
        return matched
    }

    /// 读取「N 条」里的 N（标签形如「3 条」）。
    private func recordCount() -> Int? {
        let countText = app.descendants(matching: .any)
            .matching(identifier: "logs.countText")
            .firstMatch
        guard countText.exists else { return nil }
        return Int(countText.label.prefix { $0.isNumber })
    }

    /// 等条数连续两个刷新周期（预览每秒刷新一次）不变，返回稳定值。
    private func waitForStableRecordCount(timeout: TimeInterval = 8) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var current = recordCount()
        var stableSince = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let next = recordCount()
            if next != current {
                current = next
                stableSince = Date()
            } else if current != nil, Date().timeIntervalSince(stableSince) >= 2.5 {
                return current
            }
        }
        return current
    }

    private func waitUntilRecordCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordCount() == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return recordCount() == expected
    }

    private func waitUntilRecordCountGreaterThan(_ baseline: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let count = recordCount(), count > baseline { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (recordCount() ?? 0) > baseline
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists {
            back.tap()
        } else {
            app.swipeRight()
        }
    }

    /// 开关值随系统版本可能是 "0"/"1" 或本地化文本，两种形态都接受。
    private func waitForToggleValue(_ element: XCUIElement, expected: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (element.value as? String) ?? ""
            if value == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ((element.value as? String) ?? "") == expected
    }

    private func waitUntilLabelContains(_ element: XCUIElement, _ needle: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.exists && element.label.contains(needle)
    }

    /// 行内单选控件：`PIOptionRow` 的可访问性标识落在内部按钮上。
    private func option(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    /// XCTest may report controls behind the navigation bar as hittable. Require
    /// the row to be inside the visible content area before accepting a tap.
    private func scrollUntilHittable(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            let bounds = window.frame
            let navigationBar = app.navigationBars.firstMatch
            let top = navigationBar.exists ? max(bounds.minY + 20, navigationBar.frame.maxY + 8) : bounds.minY + 20
            let tabBar = app.tabBars.firstMatch
            let bottom = tabBar.exists ? min(bounds.maxY - 20, tabBar.frame.minY - 8) : bounds.maxY - 20
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists, !frame.isEmpty,
               frame.minY >= visible.minY, frame.maxY <= visible.maxY,
               visible.contains(CGPoint(x: frame.midX, y: frame.midY)),
               element.isHittable { return }

            // The inset log preview is a separate ScrollView. Drag at the page
            // margin so the outer page moves even when the preview fills it.
            let scrollDown = exists && frame.midY < visible.midY
            let upper = window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: 8, dy: visible.minY - bounds.minY + visible.height * 0.25))
            let lower = window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: 8, dy: visible.minY - bounds.minY + visible.height * 0.75))
            if scrollDown { upper.press(forDuration: 0.05, thenDragTo: lower) }
            else { lower.press(forDuration: 0.05, thenDragTo: upper) }
        }
        XCTFail("控件未进入导航栏下方的可见区域：\(element.identifier)", file: file, line: line)
    }

    /// 选中态由 SwiftUI 的 selected trait 提供，点击后等一个短暂的渲染窗口。
    private func waitUntilSelected(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isSelected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.exists && element.isSelected
    }
}
