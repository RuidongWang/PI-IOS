import Foundation

/// 通知授权的时机与文案策略（U10）。
///
/// 现有 `LocalNotificationAuthorizationPolicy` 只管「系统状态允许不允许请求」；
/// 这个类型管「**什么时候**值得打扰用户」，两者语义分开，互不覆盖。
///
/// 设计要点：
/// - 首次启动不弹系统授权（那时用户还不知道通知用来做什么）；
/// - 只有至少有过一个可继续的会话（`hasResumableWork`）并且还没解释过，才展示解释；
/// - 用户明确选择「启用」后，才真正调系统授权；
/// - 已经决定过（允许/拒绝）就不再打扰，改用设置页里的权限展示与系统设置跳转。
public enum NotificationPromptPolicy {
    /// 用户是否明确选择过「启用提醒」。App 侧用 `@AppStorage` 读写。
    public static let userEnabledDefaultsKey = "piios.notifications.userEnabled"
    /// 是否已经解释过一次（点过「启用」或「稍后」），避免反复弹解释。
    public static let explainedDefaultsKey = "piios.notifications.explained"

    /// quiet-v2：解释卡只留一行。用户只需要知道「要不要开」，
    /// 不需要知道通知的实现方式（R1 / R9）。
    public static let explanationTitle = "离开期间的更新提醒"

    /// 一次判定的输入。全部来自现有的只读状态，不引入新的持久化契约。
    public struct Context: Equatable, Sendable {
        public var status: LocalNotificationAuthorizationStatus
        public var userEnabled: Bool
        public var explained: Bool
        /// 是否已经有过可继续的会话（例如本机记录过最近会话）。
        public var hasResumableWork: Bool

        public init(
            status: LocalNotificationAuthorizationStatus,
            userEnabled: Bool,
            explained: Bool,
            hasResumableWork: Bool
        ) {
            self.status = status
            self.userEnabled = userEnabled
            self.explained = explained
            self.hasResumableWork = hasResumableWork
        }
    }

    public enum Decision: Equatable, Sendable {
        /// 什么都不展示。
        case hidden
        /// 展示解释（启用 / 稍后），不弹系统授权。
        case explain
        /// 用户已经明确启用，可以弹系统授权。
        case requestAuthorization
    }

    public static func decision(_ context: Context) -> Decision {
        switch context.status {
        case .notDetermined:
            if context.userEnabled { return .requestAuthorization }
            guard context.hasResumableWork, !context.explained else { return .hidden }
            return .explain
        case .denied, .authorized, .provisional, .ephemeral:
            // 系统层已经有结论：不再弹任何东西，交给设置页展示状态。
            return .hidden
        }
    }

    /// 设置页「通知」分组里那一行可执行的动作。
    public enum SettingsAction: Equatable, Sendable {
        case requestAuthorization
        case openSystemSettings
        case none
    }

    public static func settingsAction(
        status: LocalNotificationAuthorizationStatus
    ) -> SettingsAction {
        switch status {
        case .notDetermined:
            return .requestAuthorization
        case .denied:
            // 被拒绝后 App 内不能再弹系统框，只能引导去系统设置。
            return .openSystemSettings
        case .authorized, .provisional, .ephemeral:
            return .none
        }
    }

    public static func statusText(_ status: LocalNotificationAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "未询问"
        case .denied:
            return "已拒绝"
        case .authorized:
            return "已允许"
        case .provisional:
            return "临时允许"
        case .ephemeral:
            return "仅本次允许"
        }
    }
}
