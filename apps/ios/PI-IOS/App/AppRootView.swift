import SwiftUI
import UIKit
import PIiOSCore

/// 三个根页 + 左上 ≡ 抽屉侧边栏（information-architecture.md §2/§3，不做底部标签栏）。
/// 根页切换只换根，不压栈；抽屉是浮层，关闭后回到原屏。
struct AppRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// U10：用户是否明确选择过「启用提醒」，以及是否已经解释过一次。
    @AppStorage(NotificationPromptPolicy.userEnabledDefaultsKey)
    private var notificationsEnabled = false
    @AppStorage(NotificationPromptPolicy.explainedDefaultsKey)
    private var notificationsExplained = false
    @State private var notificationStatus: LocalNotificationAuthorizationStatus = .notDetermined
    @State private var showingNotificationPrompt = false
    @State private var backgroundFlush: BackgroundFlushLease?

    var body: some View {
        ZStack(alignment: .topLeading) {
            rootContent

            if model.isSidebarOpen {
                scrim
                SidebarView()
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? UIScreen.main.bounds.width : PIMetrics.sidebarWidth)
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
#if DEBUG
        .overlay(alignment: .bottomLeading) {
            // UI-test runners are background processes on recent iOS releases and
            // may be denied pasteboard reads. Read the real pasteboard in the app
            // process only for the explicit test probe; never included in release.
            if ProcessInfo.processInfo.environment["PI_IOS_UI_CLIPBOARD_PROBE"] == "1" {
                UIClipboardProbe()
            }
        }
#endif
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
            // 卡顿监测只在真正可见时运行；前后台切换各记一条，便于对齐日志时间轴。
            model.updateLogSceneActive(phase == .active)
            switch phase {
            case .active:
                PILog.info("App", "回到前台")
            case .background:
                PILog.info("App", "进入后台")
            case .inactive:
                break
            @unknown default:
                break
            }
            if phase == .background {
                model.captureBackgroundBaseline()
                backgroundFlush?.cancelAndFinish()
                let lease = BackgroundFlushLease(name: "PI-IOS persistence")
                backgroundFlush = lease
                lease.start(
                    work: {
                        await model.flushForBackground()
                        await model.flushLogsForBackground()
                    },
                    completion: {
                        // Only the newest, still-active lease may publish its
                        // completion to the view; a cancelled/expired lease's
                        // already queued IO is not rolled back.
                        guard self.backgroundFlush?.version == lease.version else { return }
                        self.backgroundFlush = nil
                    }
                )
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

    /// 解释卡只在「有可继续的会话 + 系统还没决定 + 用户没启用也没选稍后」时出现。
    ///
    /// quiet-v2：一行话 + 两个动作。原来三行（标题/正文/细节）是把产品文档搬进 UI，
    /// 用户只需要知道「要不要开」，不需要知道通知的实现方式。
    @ViewBuilder
    private var notificationPromptBanner: some View {
        if showingNotificationPrompt {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                Text(NotificationPromptPolicy.explanationTitle)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
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
            .shadow(color: PIColor.floatingShadow, radius: 14, y: 5)
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

#if DEBUG
/// Read-only, in-process clipboard evidence for UI tests. The one-pixel view is
/// non-interactive and exists only when the explicit launch environment opts in.
private struct UIClipboardProbe: View {
    @State private var text = "<empty>"
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .accessibilityIdentifier("uitest.clipboard.contents")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .onReceive(timer) { _ in
                let raw = UIPasteboard.general.string ?? ""
                let current = raw.isEmpty ? "<empty>" : raw
                guard current != text else { return }
                text = current
            }
    }
}
#endif

/// Owns one UIKit background-task assertion and ends it exactly once, whether
/// the ordered flushes finish or the system invokes the expiration handler.
/// The assertion is acquired in `init`, before the persistence `Task` starts.
@MainActor
final class BackgroundFlushLease {
    /// Monotonic lease version used to gate completion-visible work.
    private static var nextVersion: UInt64 = 0
    let version: UInt64
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var task: Task<Void, Never>?
    private var ended = false
    private let endAssertion: (UIBackgroundTaskIdentifier) -> Void

    init(name: String,
         begin: ((_ expiration: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier)? = nil,
         end: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        BackgroundFlushLease.nextVersion &+= 1
        version = BackgroundFlushLease.nextVersion
        endAssertion = end ?? { UIApplication.shared.endBackgroundTask($0) }
        let expiration: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        identifier = begin?(expiration)
            ?? UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    /// Current means not ended by `cancelAndFinish`/`expire` and not cancelled.
    var isActive: Bool { !ended && !Task.isCancelled }

    func start(
        work: @escaping @MainActor () async -> Void,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard !ended, task == nil else { return }
        task = Task { @MainActor [self] in
            defer { finish() }
            guard isActive else { return }
            await work()
            // Physical IO may already be committed; cancellation only suppresses
            // completion-visible state, never pretends the write was undone.
            guard isActive else { return }
            completion()
        }
    }

    func cancelAndFinish() {
        task?.cancel()
        finish()
    }

    private func expire() {
        task?.cancel()
        finish()
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        task = nil
        let identifier = self.identifier
        self.identifier = .invalid
        guard identifier != .invalid else { return }
        endAssertion(identifier)
    }
}
