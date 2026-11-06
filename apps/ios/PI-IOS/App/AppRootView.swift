import SwiftUI
import PIiOSCore

/// 三个根页 + 左上 ≡ 抽屉侧边栏（information-architecture.md §2/§3，不做底部标签栏）。
/// 根页切换只换根，不压栈；抽屉是浮层，关闭后回到原屏。
struct AppRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase

    /// U10：用户是否明确选择过「启用提醒」，以及是否已经解释过一次。
    @AppStorage(NotificationPromptPolicy.userEnabledDefaultsKey)
    private var notificationsEnabled = false
    @AppStorage(NotificationPromptPolicy.explainedDefaultsKey)
    private var notificationsExplained = false
    @State private var notificationStatus: LocalNotificationAuthorizationStatus = .notDetermined
    @State private var showingNotificationPrompt = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            rootContent

            if model.isSidebarOpen {
                scrim
                SidebarView()
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.isSidebarOpen)
        .overlay(alignment: .top) {
            VStack(spacing: PISpacing.s8) {
                toastLayer
                notificationPromptBanner
            }
        }
        // 指纹核对 / 指纹变化浮层放在根视图（DEF-R4-004）：它可能在任意页面由
        // 后台重连触发，不能只在服务器页或安装页可见时才呈现。
        .sheet(item: $connection.hostKeyPrompt) { prompt in
            HostKeyConfirmSheet(prompt: prompt) { confirmation in
                connection.respondHostKey(confirmation, operationID: prompt.operationID)
            }
        }
        .piMessageAlert(title: "本机设置读取异常", message: Binding(
            get: { model.loadWarning },
            set: { if $0 == nil { model.dismissLoadWarning() } }
        ))
        .piMessageAlert(title: "本机记录未能写入", message: Binding(
            get: { model.saveError },
            set: { if $0 == nil { model.dismissSaveError() } }
        ))
        .task(id: model.toast?.id) {
            guard model.toast != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 2_600_000_000)
            } catch {
                // 被取消说明有新的 toast 替换了旧的：直接返回，不能关掉新的那个。
                return
            }
            model.dismissToast()
        }
        .task {
            guard !model.usesUITestFixture else { return }
            // U10：启动只建立通知代理，**不**在这里请求系统授权。
            // 权限在「有可继续的会话」且用户看过解释并主动启用后才请求。
            LocalNotificationCoordinator.shared.bootstrap()
            await refreshNotificationStatus()
        }
        .onChange(of: model.lastSessionId) { _, _ in
            // 首次有可继续的会话时，才是解释「离开期间更新提醒」的合适时机。
            evaluateNotificationPrompt()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.captureBackgroundBaseline()
                model.flushPersistentState()
                Task { await model.connection.flushPendingCacheWrites() }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.resumeFromBackground()
                guard model.hasPendingForegroundResume else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch model.root {
        case .projects:
            ProjectsScreen()
        case .conversation:
            ConversationScreen(session: model.connection.session)
        case .settings:
            SettingsScreen()
        }
    }

    private var scrim: some View {
        PIColor.scrim
            .ignoresSafeArea()
            .transition(.opacity)
            .onTapGesture { model.closeSidebar() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("关闭侧边栏")
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            PIToastView(toast: toast)
                .padding(.top, PISpacing.s8)
                .transition(.opacity)
                .onTapGesture { model.dismissToast() }
        }
    }

    // MARK: - 通知授权说明（U10）

    /// 解释卡只在「有可继续的会话 + 系统还没决定 + 用户没启用也没选稍后」时出现；
    /// 点「启用提醒」才真正弹系统授权，点「稍后」不再打扰。
    @ViewBuilder
    private var notificationPromptBanner: some View {
        if showingNotificationPrompt {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                Text(NotificationPromptPolicy.explanationTitle)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                Text(NotificationPromptPolicy.explanationBody)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(NotificationPromptPolicy.explanationDetail)
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: PISpacing.s8) {
                    PISecondaryButton(title: "稍后") {
                        deferNotificationPrompt()
                    }
                    .accessibilityIdentifier("notifications.later")
                    PIPrimaryButton(title: "启用提醒") {
                        enableNotifications()
                    }
                    .accessibilityIdentifier("notifications.enable")
                }
            }
            .padding(PISpacing.s16)
            .background(
                PIColor.surface,
                in: RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
            .shadow(color: PIColor.floatingShadow.opacity(0.5), radius: 14, y: 5)
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s8)
            .accessibilityIdentifier("notifications.prompt")
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await LocalNotificationCoordinator.shared.authorizationStatus()
        evaluateNotificationPrompt()
    }

    private func evaluateNotificationPrompt() {
        guard !model.usesUITestFixture else {
            showingNotificationPrompt = false
            return
        }
        let decision = NotificationPromptPolicy.decision(
            NotificationPromptPolicy.Context(
                status: notificationStatus,
                userEnabled: notificationsEnabled,
                explained: notificationsExplained,
                hasResumableWork: model.lastSessionId != nil
            )
        )
        showingNotificationPrompt = decision == .explain
    }

    private func enableNotifications() {
        notificationsEnabled = true
        notificationsExplained = true
        showingNotificationPrompt = false
        Task {
            await LocalNotificationCoordinator.shared.requestAuthorization()
            await refreshNotificationStatus()
        }
    }

    private func deferNotificationPrompt() {
        notificationsExplained = true
        showingNotificationPrompt = false
    }
}
