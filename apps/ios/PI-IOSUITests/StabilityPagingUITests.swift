import XCTest

/// H4 paging checks against the real SwiftUI conversation path.
/// The current page and first earlier page start inside a tool turn; only the
/// second earlier page supplies the user boundary. The UI must publish 43 → 48
/// atomically and merge all three tools without moving the original viewport.
final class StabilityPagingUITests: XCTestCase {
    private let app = XCUIApplication()
    private let initialItemCount = 43
    private let pagedItemCount = 48

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "stability-paging"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testPrependPreservesOriginalItemAcrossPageBoundary() {
        openAtPagingBoundary()

        revealLoadEarlier()
        let groupBefore = element("toolGroup.paging-tool-2.toggle")
        let finalBefore = finalText
        XCTAssertTrue(groupBefore.waitForExistence(timeout: 5))
        XCTAssertTrue(finalBefore.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["toolGroup.paging-tool-2.title"].label, "2 次工具调用")

        let groupYBefore = groupBefore.frame.minY
        let finalYBefore = finalBefore.frame.minY
        let loadButton = app.buttons["conversation.loadEarlierHistory"]
        XCTAssertTrue(loadButton.isEnabled)
        XCTAssertTrue(loadButton.isHittable)
        loadButton.tap()
        XCTAssertTrue(
            waitForCondition(timeout: 3) { !loadButton.isEnabled },
            "the first delayed page must expose the loading state"
        )

        // The first page has arrived, while the boundary page is still delayed.
        // Neither its tool-only partial turn nor a 44-item intermediate view may publish.
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        XCTAssertEqual(itemCount, initialItemCount, "tool-only page must remain staged")
        XCTAssertFalse(element("toolGroup.paging-tool-1.toggle").exists, "半轮工具组不得提前出现")
        XCTAssertFalse(app.staticTexts["Paging boundary user 01"].exists, "任务起点必须随整批原子出现")
        XCTAssertEqual(groupBefore.frame.minY, groupYBefore, accuracy: 8, "补页前原阅读锚点不得移动")
        XCTAssertEqual(finalBefore.frame.minY, finalYBefore, accuracy: 8, "补页前原回复位置不得移动")

        var observedCounts: Set<Int> = [itemCount]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, itemCount != pagedItemCount {
            observedCounts.insert(itemCount)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        observedCounts.insert(itemCount)
        XCTAssertEqual(itemCount, pagedItemCount, "boundary page must complete the fixture prepend")
        XCTAssertEqual(
            observedCounts,
            Set([initialItemCount, pagedItemCount]),
            "visible items must jump 43 → 48 atomically, never exposing 44…47"
        )
        let groupAfter = element("toolGroup.paging-tool-1.toggle")
        XCTAssertTrue(groupAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["toolGroup.paging-tool-1.title"].label,
            "3 次工具调用",
            "items from both pages must render as one tool group"
        )
        _ = waitForCondition(timeout: 10) {
            guard groupAfter.exists, self.finalText.exists else { return false }
            return abs(groupAfter.frame.minY - groupYBefore) <= 8
                && abs(self.finalText.frame.minY - finalYBefore) <= 8
        }
        let groupYAfter = groupAfter.exists ? groupAfter.frame.minY : .greatestFiniteMagnitude
        let finalYAfter = finalText.exists ? finalText.frame.minY : .greatestFiniteMagnitude
        let preserved = abs(groupYAfter - groupYBefore) <= 8
            && abs(finalYAfter - finalYBefore) <= 8
        XCTAssertTrue(
            preserved,
            "prepend must keep the original row and relative viewport within 8pt; "
                + "groupY=\(groupYBefore)->\(groupYAfter), "
                + "finalY=\(finalYBefore)->\(finalYAfter)"
        )
        XCTAssertTrue(
            app.buttons["conversation.scrollToLatest"].exists,
            "prepending history must not switch the reader to bottom-follow"
        )
        XCTAssertFalse(newestItem.isHittable, "prepend must not jump to bottom")

        // The original item inside the old page is now a member of the merged group.
        groupAfter.tap()
        XCTAssertTrue(
            element("toolCard.paging-tool-2.toggle").waitForExistence(timeout: 5),
            "the original current-page item must be present in the merged group"
        )
    }

    func testUserScrollDuringLoadCancelsWithoutSnapBackOrBottomJump() {
        openAtPagingBoundary()

        revealLoadEarlier()
        let loadButton = app.buttons["conversation.loadEarlierHistory"]
        XCTAssertTrue(loadButton.isEnabled)
        XCTAssertTrue(loadButton.isHittable)
        loadButton.tap()
        XCTAssertTrue(
            waitForCondition(timeout: 3) { !loadButton.isEnabled },
            "the delayed fixture page must expose the loading state before the drag"
        )

        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<5 {
            // Keep the drag short: overshooting to the newest message would make
            // the bottom-follow assertions ambiguous.
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let scrolledTop = stableTop(prefix: "paging-newer-", timeout: 6)
        XCTAssertFalse(scrolledTop.isEmpty, "user drag must move toward newer messages")
        XCTAssertNotEqual(scrolledTop, "paging-tool-2")

        // The top probe may be partially clipped by the header; pick the first
        // fully hit-testable row among the next few so the post-load check is stable.
        var userItem = app.staticTexts["conversation.userMessage.\(scrolledTop)"]
        var userItemID = scrolledTop
        if !userItem.isHittable, let number = Int(scrolledTop.suffix(2)) {
            for offset in 1...3 {
                let candidateID = String(format: "paging-newer-%02d", min(number + offset, 40))
                let candidate = app.staticTexts["conversation.userMessage.\(candidateID)"]
                if candidate.exists && candidate.isHittable {
                    userItem = candidate
                    userItemID = candidateID
                    break
                }
            }
        }
        XCTAssertTrue(userItem.exists, "the row at the dragged-to position must be a real item")
        XCTAssertTrue(userItem.isHittable, "userItem=\(userItemID)")

        XCTAssertTrue(
            waitForCondition(timeout: 12) { self.itemCount == self.pagedItemCount },
            "the in-flight pages still complete after the user cancels the visual restore"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let group = element("toolGroup.paging-tool-1.toggle")
        if group.exists {
            XCTAssertLessThan(
                group.frame.minY,
                -8,
                "cancelled paging must not snap the anchor back to the viewport top"
            )
            XCTAssertFalse(group.isHittable, "cancelled paging must not bring the old anchor back")
        }
        XCTAssertTrue(userItem.isHittable, "the user's scrolled-to content must stay visible")
        XCTAssertFalse(newestItem.isHittable, "cancelled paging must not jump to the newest message")
        XCTAssertTrue(
            app.buttons["conversation.scrollToLatest"].exists,
            "the reader must remain in non-bottom-follow mode"
        )
    }

    // MARK: - Helpers

    private var topVisibleItem: String {
        app.staticTexts["conversation.debugTopVisibleItem"].label
    }

    private var itemCount: Int {
        let label = app.staticTexts["conversation.debugRestorationState"].label
        guard let range = label.range(of: "items=") else { return -1 }
        return Int(label[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    private var finalText: XCUIElement {
        element("conversation.agentMessage.paging-final-1")
    }

    private var newestItem: XCUIElement {
        app.staticTexts["conversation.userMessage.paging-newer-40"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openAtPagingBoundary() {
        openSession("S1", fromConversation: false)
        XCTAssertTrue(waitForCondition(timeout: 10) {
            self.topVisibleItem == "paging-tool-2" && self.itemCount == self.initialItemCount
        }, "fixture must open at the cross-page tool group")
        // Let the restore task finish its confirmation tail before touching the
        // load button; the button is disabled while isRestoringReadingPosition.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
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

    private func revealLoadEarlier() {
        let button = app.buttons["conversation.loadEarlierHistory"]
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if button.exists && button.isEnabled && button.isHittable {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                return
            }
            // A full swipe can overshoot the short control strip and push the
            // measured group off screen. Use a short controlled drag instead.
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.isHittable, "load-earlier control must be reachable at the page top")
    }

    private func stableTop(prefix: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            let current = topVisibleItem
            if current != last {
                last = current
                stableSince = Date()
            } else if current.hasPrefix(prefix),
                      Date().timeIntervalSince(stableSince) >= 0.6 {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return last.hasPrefix(prefix) ? last : ""
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
