import Foundation
import XCTest
@testable import PIiOSCore

final class NotificationPromptPolicyTests: XCTestCase {
    private func context(
        status: LocalNotificationAuthorizationStatus,
        userEnabled: Bool = false,
        explained: Bool = false,
        hasResumableWork: Bool = true
    ) -> NotificationPromptPolicy.Context {
        NotificationPromptPolicy.Context(
            status: status,
            userEnabled: userEnabled,
            explained: explained,
            hasResumableWork: hasResumableWork
        )
    }

    // MARK: - 何时该问

    func testFirstLaunchWithoutSessionDoesNotPrompt() {
        XCTAssertEqual(
            NotificationPromptPolicy.decision(
                context(status: .notDetermined, hasResumableWork: false)
            ),
            .hidden,
            "首次启动还没有可继续的会话时不能弹解释，更不能弹系统授权"
        )
    }

    func testExplainsOnlyOnceBeforeAuthorization() {
        XCTAssertEqual(
            NotificationPromptPolicy.decision(context(status: .notDetermined)),
            .explain
        )
        XCTAssertEqual(
            NotificationPromptPolicy.decision(context(status: .notDetermined, explained: true)),
            .hidden,
            "解释过一次（点了稍后）就不再打扰"
        )
    }

    func testUserChoiceEnablesSystemRequest() {
        XCTAssertEqual(
            NotificationPromptPolicy.decision(context(status: .notDetermined, userEnabled: true)),
            .requestAuthorization
        )
        XCTAssertEqual(
            NotificationPromptPolicy.decision(
                context(status: .notDetermined, userEnabled: true, explained: true)
            ),
            .requestAuthorization,
            "用户明确启用后，即使已经解释过也要继续请求系统授权"
        )
    }

    func testResolvedStatusNeverPromptsAgain() {
        for status: LocalNotificationAuthorizationStatus in [.authorized, .denied, .provisional, .ephemeral] {
            XCTAssertEqual(
                NotificationPromptPolicy.decision(
                    context(status: status, userEnabled: false, explained: false)
                ),
                .hidden,
                "系统已有结论（\(status)）时不能重复询问"
            )
        }
    }

    // MARK: - 设置页动作

    func testSettingsActionFollowsSystemStatus() {
        XCTAssertEqual(
            NotificationPromptPolicy.settingsAction(status: .notDetermined),
            .requestAuthorization
        )
        XCTAssertEqual(
            NotificationPromptPolicy.settingsAction(status: .denied),
            .openSystemSettings,
            "已拒绝时 App 内无法再弹系统框，只能跳系统设置"
        )
        for status: LocalNotificationAuthorizationStatus in [.authorized, .provisional, .ephemeral] {
            XCTAssertEqual(NotificationPromptPolicy.settingsAction(status: status), .none)
        }
    }

    func testStatusTextAndSubtitleCoverEveryStatus() {
        XCTAssertEqual(NotificationPromptPolicy.statusText(.notDetermined), "未询问")
        XCTAssertEqual(NotificationPromptPolicy.statusText(.denied), "已拒绝")
        XCTAssertEqual(NotificationPromptPolicy.statusText(.authorized), "已允许")
        XCTAssertEqual(NotificationPromptPolicy.statusText(.provisional), "临时允许")
        XCTAssertEqual(NotificationPromptPolicy.statusText(.ephemeral), "仅本次允许")

        XCTAssertTrue(
            NotificationPromptPolicy.settingsSubtitle(.denied).contains("系统设置")
        )
        XCTAssertTrue(
            NotificationPromptPolicy.settingsSubtitle(.authorized).contains("回到 App")
        )
    }

    // MARK: - 文案真实性

    func testExplanationDoesNotPromiseBackgroundPush() {
        XCTAssertTrue(NotificationPromptPolicy.explanationBody.contains("回到 App"))
        XCTAssertTrue(NotificationPromptPolicy.explanationDetail.contains("回到 App"))
        XCTAssertTrue(
            NotificationPromptPolicy.explanationDetail.contains("不会在后台实时推送"),
            "必须明确说明不是后台实时推送，不能把本地回前台提示说成推送"
        )
    }

    func testDefaultsKeysAreStable() {
        // App 侧用 @AppStorage 固定这两个 key；改名等于丢失用户选择，测试锁住。
        XCTAssertEqual(
            NotificationPromptPolicy.userEnabledDefaultsKey,
            "piios.notifications.userEnabled"
        )
        XCTAssertEqual(
            NotificationPromptPolicy.explainedDefaultsKey,
            "piios.notifications.explained"
        )
    }
}
