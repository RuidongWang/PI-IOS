import XCTest
import CryptoKit

/// Stability regression for the real SwiftUI conversation path:
/// 1,500 mixed items must stay fully reachable under LazyVStack, and a scrolled
/// reading position must restore to the same row with a bounded pixel offset.
final class StabilityHistoryUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testLongHistoryReachabilityLazyMountingAndReadingRestore() {
        relaunchStability(start: "oldest", controls: false)
        openSession("S1", fromConversation: false)

        let debug = waitForDebugState()
        XCTAssertEqual(debug.items, 1_500, "模型层必须保留完整 1,500 条历史")
        XCTAssertGreaterThan(debug.activeAnchors, 0, "真实 SwiftUI 路径应挂载可见行")
        XCTAssertLessThan(debug.activeAnchors, 750, "LazyVStack 不得把 1,500 行全部同时挂载")
        XCTAssertEqual(itemIdentity, expectedIdentity(), "完整有序 ID 摘要须与 1,500 条夹具一致")

        let first = app.staticTexts["Stability user 0001"]
        XCTAssertTrue(scroll(toward: first, targetTurn: 1), "最旧条目必须可到达；\(debugState().raw)")
        XCTAssertTrue(first.isHittable, "最旧条目必须可到达")

        // Seed just before the middle through the same persisted reading-position
        // entry used by real sessions, then actually scroll to the target. Walking
        // hundreds of fixed inertial swipes tests a screen-height assumption and
        // can pass over the target forever after overshooting it.
        relaunchStability(start: "before-middle")
        openSession("S1", fromConversation: false)
        XCTAssertTrue(waitForCondition(timeout: 10) {
            self.debugState().topItem == "stability-0246-user" && abs(self.debugState().y) <= 8
        })
        let middle = app.staticTexts["Stability final 0248"]
        XCTAssertTrue(scroll(toward: middle, targetTurn: 248), "中部条目必须可到达；\(debugState().raw)")
        XCTAssertTrue(middle.isHittable, "中部条目必须可到达")

        let savedTop = waitForStableTop()
        XCTAssertFalse(savedTop.isEmpty)

        openSession("S2")
        XCTAssertTrue(app.staticTexts["Fixture history for S2"].waitForExistence(timeout: 5))
        openSession("S1")

        let restored = waitForCondition(timeout: 10) {
            let state = self.debugState()
            return state.topItem == savedTop && abs(state.y) <= 8
        }
        XCTAssertTrue(
            restored,
            "返回会话必须恢复到同一行且误差≤8pt；saved=\(savedTop), debug=\(debugState().raw)"
        )
        XCTAssertTrue(middle.waitForExistence(timeout: 3), "恢复目标附近的行必须进入虚拟化窗口")

        let latest = app.buttons["conversation.scrollToLatest"]
        XCTAssertTrue(latest.exists, "中部阅读应保留回到最新的现有入口")
        latest.tap()
        let last = app.staticTexts["Stability final 0495"]
        XCTAssertTrue(scroll(toward: last, targetTurn: 495), "最新条目必须可到达；\(debugState().raw)")
        XCTAssertTrue(last.isHittable, "最新条目必须可到达")
        XCTAssertEqual(itemIdentity, expectedIdentity(), "首中末访问不能截断模型中的历史")
    }

    func testAppendingWhileReadingMiddleKeepsViewportAndLazyWindow() throws {
        relaunchStability(start: "middle")
        openSession("S1", fromConversation: false)
        let restoredMarker = app.staticTexts["conversation.userMessage.stability-0248-user"]
        XCTAssertTrue(waitForCondition(timeout: 10) {
            let state = self.debugState()
            return state.topItem == "stability-0248-user" && abs(state.y) <= 8
                && restoredMarker.exists && restoredMarker.isHittable
        }, "专用夹具必须先恢复到中部真实行")
        // Exercise user-driven free reading before injecting the message; the
        // saved fixture position only avoids hundreds of setup swipes.
        let scrollView = app.scrollViews.firstMatch
        scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)))
        let topBefore = waitForStableTop()
        let marker = try XCTUnwrap(visibleStabilityMarker(near: topBefore),
                                  "实际拖动后应有可见的真实行；top=\(topBefore),debug=\(debugState().raw)")
        let yBefore = marker.frame.minY
        let mountedBefore = debugState().activeAnchors
        XCTAssertEqual(itemIdentity, expectedIdentity())
        XCTAssertTrue(app.buttons["conversation.scrollToLatest"].exists)

        appendFixtureMessage()
        XCTAssertTrue(waitForCondition(timeout: 8) { self.debugState().items == 1_501 })
        XCTAssertEqual(itemIdentity, expectedIdentity(appended: 1))
        XCTAssertEqual(debugState().topItem, topBefore, "新消息不能抢走中部阅读位置")
        XCTAssertTrue(marker.isHittable)
        XCTAssertLessThanOrEqual(abs(marker.frame.minY - yBefore), 8)
        XCTAssertTrue(app.buttons["conversation.scrollToLatest"].exists)
        let newest = app.descendants(matching: .any)["conversation.agentMessage.stability-live-1"]
        if newest.exists { XCTAssertFalse(newest.isHittable, "中部追加不能跳到底部") }
        assertWindowRemainsBounded(before: mountedBefore)
        assertStableViewport(marker, expectedY: yBefore)
    }

    func testAppendingAtBottomContinuesFollowingNewestMessage() {
        relaunchStability(start: "bottom")
        openSession("S1", fromConversation: false)
        let previousNewest = app.staticTexts["Stability final 0495"]
        XCTAssertTrue(waitForCondition(timeout: 10) {
            previousNewest.exists && previousNewest.isHittable
                && !self.app.buttons["conversation.scrollToLatest"].exists
        }, "先确认底部跟随已就绪")
        let mountedBefore = debugState().activeAnchors
        print("CASE bottom-follow before append: \(bottomFollowDebug)")
        appendFixtureMessage()
        // The identifier belongs to PIMarkdownView's .contain container, not to
        // its StaticText child. Do not filter that container out of the query.
        let newest = app.descendants(matching: .any)["conversation.agentMessage.stability-live-1"]
        let followed = waitForCondition(timeout: 8) {
            self.debugState().items == 1_501 && newest.exists && newest.isHittable
                && !self.app.buttons["conversation.scrollToLatest"].exists
        }
        let followDebug = bottomFollowDebug
        print("CASE bottom-follow after append: \(followDebug),newestExists=\(newest.exists)")
        XCTAssertTrue(followed, "底部追加后真实最新消息应继续贴底；\(followDebug)")
        XCTAssertEqual(itemIdentity, expectedIdentity(appended: 1))
        let viewportBottom = app.scrollViews.firstMatch.frame.maxY
        XCTAssertLessThanOrEqual(newest.frame.maxY, viewportBottom + 8)
        XCTAssertLessThanOrEqual(abs(viewportBottom - newest.frame.maxY), 96)
        assertWindowRemainsBounded(before: mountedBefore)
    }

    func testToolGroupExpansionAndCollapseDoNotLoopOrJumpToBottom() {
        relaunchStability(start: "group")
        openSession("S1", fromConversation: false)
        let group = app.descendants(matching: .any)["toolGroup.stability-0248-tool.toggle"]
        XCTAssertTrue(waitForCondition(timeout: 10) {
            let state = self.debugState()
            return state.topItem == "stability-0248-tool" && abs(state.y) <= 8
                && group.exists && group.isHittable
        }, "先恢复到非底部工具组")
        XCTAssertEqual(group.value as? String, "collapsed")
        XCTAssertEqual(app.staticTexts["toolGroup.stability-0248-tool.title"].label, "2 次工具调用")
        XCTAssertTrue(app.buttons["conversation.scrollToLatest"].exists, "中部工具组必须先满足非底部前提")
        let initialY = group.frame.minY
        group.tap()
        XCTAssertTrue(waitForCondition(timeout: 5) { group.value as? String == "expanded" })
        XCTAssertTrue(app.descendants(matching: .any)["toolCard.stability-0248-tool.toggle"].exists)
        assertStableViewport(group, expectedY: initialY)
        XCTAssertTrue(app.buttons["conversation.scrollToLatest"].exists)

        group.tap()
        XCTAssertTrue(waitForCondition(timeout: 5) { group.value as? String == "collapsed" })
        XCTAssertFalse(app.descendants(matching: .any)["toolCard.stability-0248-tool.toggle"].exists)
        assertStableViewport(group, expectedY: initialY)
        XCTAssertTrue(app.buttons["conversation.scrollToLatest"].exists)
        XCTAssertEqual(itemIdentity, expectedIdentity(), "工具展开收起不能改变完整模型")
    }

    // MARK: - Helpers

    private func relaunchStability(start: String, controls: Bool = true) {
        app.terminate()
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-stability-history"
        // Set both values explicitly so a previous opt-in case cannot influence
        // the next launch through a reused XCUIApplication proxy.
        app.launchEnvironment["PI_IOS_UI_STABILITY_START"] = start
        app.launchEnvironment["PI_IOS_UI_STABILITY_CONTROLS"] = controls ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    /// A drag includes deceleration, so its final row cannot be predicted from
    /// the drag distance. Select an actual fully visible row near the measured
    /// top and keep that same element for the before/after 8pt assertion.
    private func visibleStabilityMarker(near topID: String) -> XCUIElement? {
        let parts = topID.split(separator: "-")
        guard parts.count > 1, let firstTurn = Int(parts[1]), (1...495).contains(firstTurn) else { return nil }
        let viewport = app.scrollViews.firstMatch.frame
        for turn in firstTurn...min(firstTurn + 3, 495) {
            let number = String(format: "%04d", turn)
            let firstTool = turn <= 490 ? "stability-\(number)-tool" : "stability-\(number)-tool-1"
            let candidates = [
                app.staticTexts["conversation.userMessage.stability-\(number)-user"],
                app.staticTexts["Stability final \(number)"],
                app.descendants(matching: .any)["toolGroup.\(firstTool).toggle"],
            ]
            for candidate in candidates where candidate.exists && candidate.isHittable {
                let frame = candidate.frame
                if frame.minY >= viewport.minY + 8, frame.maxY <= viewport.maxY - 8 {
                    return candidate
                }
            }
        }
        return nil
    }

    private var bottomFollowDebug: String {
        let probe = app.staticTexts["conversation.debugBottomFollowState"]
        return probe.exists ? probe.label : "missing bottom-follow probe; \(debugState().raw)"
    }

    private func appendFixtureMessage() {
        app.buttons["会话操作"].tap()
        let append = app.buttons["conversation.fixture.appendMessage"]
        XCTAssertTrue(append.waitForExistence(timeout: 3))
        append.tap()
    }

    private var itemIdentity: String {
        app.staticTexts["conversation.debugItemIdentity"].label
    }

    /// Independently enumerate every original ID, including folded group members.
    private func expectedIdentity(appended: Int = 0) -> String {
        var ids: [String] = []
        for turn in 1...495 {
            let number = String(format: "%04d", turn)
            let prefix = "stability-\(number)"
            ids.append("\(prefix)-user")
            if turn <= 490 {
                ids.append("\(prefix)-tool")
            } else {
                for member in 1...2 {
                    ids.append("\(prefix)-tool-\(member)")
                    ids.append("\(prefix)-mid-\(member)")
                }
            }
            ids.append("\(prefix)-final")
        }
        if appended > 0 {
            ids.append(contentsOf: (1...appended).map { "stability-live-\($0)" })
        }
        return SHA256.hash(data: Data(ids.joined(separator: "\n").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func assertWindowRemainsBounded(before: Int, file: StaticString = #filePath, line: UInt = #line) {
        let after = debugState().activeAnchors
        XCTAssertGreaterThan(before, 0, file: file, line: line)
        XCTAssertGreaterThan(after, 0, file: file, line: line)
        XCTAssertLessThan(before, 750, file: file, line: line)
        XCTAssertLessThan(after, 750, "追加前后都只能挂载有界的可见/预取区域", file: file, line: line)
        XCTAssertLessThan(abs(after - before), 64, "单条追加不能使活跃 anchor 随完整历史规模增长", file: file, line: line)
    }

    private func assertStableViewport(_ item: XCUIElement, expectedY: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) {
        // Observe several settled layout passes so a momentarily aligned frame
        // cannot conceal a delayed restore loop.
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(item.exists && item.isHittable, file: file, line: line)
            XCTAssertLessThanOrEqual(abs(item.frame.minY - expectedY), 8, file: file, line: line)
        }
    }

    private struct DebugState {
        let raw: String
        let topItem: String
        let y: CGFloat
        let activeAnchors: Int
        let items: Int
    }

    private func openSession(_ id: String, fromConversation: Bool = true) {
        if fromConversation {
            app.buttons["打开侧边栏"].tap()
        }
        let row = app.buttons["sidebar.session.\(id)"]
        if !row.waitForExistence(timeout: 2), app.buttons["打开侧边栏"].exists {
            app.buttons["打开侧边栏"].tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
    }

    /// Feedback from the real viewport determines direction. Near the target,
    /// small held drags avoid flinging past it; overshoot reverses direction on
    /// the next iteration. Every caller has a bounded 15s/24-action search.
    @discardableResult
    private func scroll(toward element: XCUIElement, targetTurn: Int) -> Bool {
        let scrollView = app.scrollViews.firstMatch
        let deadline = Date().addingTimeInterval(15)
        for action in 0..<24 {
            if element.exists && element.isHittable { return true }
            guard Date() < deadline else { break }
            let topID = app.staticTexts["conversation.debugTopVisibleItem"].label
            let fields = topID.split(separator: "-")
            guard fields.count > 1, let topTurn = Int(fields[1]) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            let forward: Bool
            let close = abs(topTurn - targetTurn) <= 3
            if close, element.exists {
                forward = element.frame.midY > scrollView.frame.midY
            } else {
                forward = topTurn <= targetTurn
            }
            print("CASE reachability target=\(targetTurn),top=\(topID),action=\(action),forward=\(forward)")
            if close {
                let startY: CGFloat = forward ? 0.65 : 0.35
                let endY: CGFloat = 0.50
                scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                    .press(forDuration: 0.1,
                           thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
            } else if forward {
                scrollView.swipeUp(velocity: .fast)
            } else {
                scrollView.swipeDown(velocity: .fast)
            }
        }
        print("CASE reachability target=\(targetTurn) exhausted: \(debugState().raw)")
        return element.exists && element.isHittable
    }

    private func debugState() -> DebugState {
        let raw = app.staticTexts["conversation.debugRestorationState"].label
        return DebugState(
            raw: raw,
            topItem: app.staticTexts["conversation.debugTopVisibleItem"].label,
            y: value(in: raw, key: "y=").flatMap { Double($0) }.map { CGFloat($0) } ?? .greatestFiniteMagnitude,
            activeAnchors: value(in: raw, key: "active=").flatMap { Int($0) } ?? -1,
            items: integerValue(in: raw, key: "items=") ?? -1
        )
    }

    private func waitForDebugState() -> DebugState {
        _ = waitForCondition(timeout: 8) {
            let state = self.debugState()
            return state.items == 1_500 && state.activeAnchors > 0
        }
        return debugState()
    }

    private func value(in label: String, key: String) -> String? {
        guard let range = label.range(of: key) else { return nil }
        let suffix = label[range.upperBound...]
        return suffix.split(separator: ",", maxSplits: 1).first.map(String.init)
    }

    private func integerValue(in label: String, key: String) -> Int? {
        guard let range = label.range(of: key) else { return nil }
        let token = label[range.upperBound...].prefix { $0.isNumber || $0 == "," || $0 == "-" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        return formatter.number(from: String(token))?.intValue
    }

    private func waitForStableTop() -> String {
        let deadline = Date().addingTimeInterval(8)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            let current = app.staticTexts["conversation.debugTopVisibleItem"].label
            if current != last {
                last = current
                stableSince = Date()
            } else if !current.isEmpty, Date().timeIntervalSince(stableSince) >= 0.8 {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return last
    }

    private func waitForCondition(
        timeout: TimeInterval,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
