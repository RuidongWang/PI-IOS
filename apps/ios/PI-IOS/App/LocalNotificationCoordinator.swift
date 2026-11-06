import Foundation
import PIiOSCore
import UserNotifications

/// Foreground-only local notifications for changes accumulated while suspended.
@MainActor
final class LocalNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationCoordinator()

    private var didBootstrap = false
    private var didAttemptAuthorization = false
    private var foregroundTracker = ForegroundNotificationTracker()

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        UNUserNotificationCenter.current().delegate = self
    }

    /// 当前系统通知权限（只读）：不触发任何系统弹层。
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.authorizationStatus(settings.authorizationStatus)
    }

    /// 真正请求系统授权。
    ///
    /// 只在 `NotificationPromptPolicy` 判定「用户已明确启用」之后调用：启动时不再
    /// 无上下文直接弹权限（U10）。既有 `LocalNotificationAuthorizationPolicy` 的语义
    /// 保持不变——系统还没决定、且本进程没请求过，才真正请求。
    @discardableResult
    func requestAuthorization() async -> Bool {
        let status = await authorizationStatus()
        guard LocalNotificationAuthorizationPolicy.shouldRequest(
            status: status,
            alreadyAttempted: didAttemptAuthorization
        ) else {
            return false
        }
        didAttemptAuthorization = true
        return (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        )) ?? false
    }

    /// AppModel 的旧通知路径在自己刷新完基线时会调用这里；只要 AppRootView 已建立
    /// 纯策略 transition，就由完整的 baseline/current 比较接管，避免同一前台发两次。
    func notifyUpdates(count: Int) async {
        guard !foregroundTracker.hasActiveTransition else { return }
        await deliver(count: count, identifier: "foreground-update-\(UUID().uuidString)")
    }

    func beginForegroundTransition(
        id: UUID,
        baseline: BackgroundNotificationBaseline
    ) {
        foregroundTracker.begin(transitionID: id, baseline: baseline)
    }

    func completeForegroundTransition(
        id: UUID,
        current: BackgroundNotificationSnapshot
    ) async {
        let decision = foregroundTracker.resolve(transitionID: id, current: current)
        guard case let .notify(updatedSessionCount, newApprovalCount) = decision else {
            return
        }
        // 同一 transition 使用稳定标识；即使系统层被重复提交，也只保留一条。
        await deliver(
            count: max(updatedSessionCount, newApprovalCount > 0 ? 1 : 0),
            identifier: "foreground-update-\(id.uuidString)"
        )
    }

    private func deliver(count: Int, identifier: String) async {
        guard count > 0 else { return }
        bootstrap()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard LocalNotificationAuthorizationPolicy.canDeliver(
            status: Self.authorizationStatus(settings.authorizationStatus)
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = "PI-IOS 有新的进度"
        content.body = count == 1 ? "有 1 个会话在你离开期间更新" : "有 \(count) 个会话在你离开期间更新"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func authorizationStatus(
        _ status: UNAuthorizationStatus
    ) -> LocalNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .denied
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
