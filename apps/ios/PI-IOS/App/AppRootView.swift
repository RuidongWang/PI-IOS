import SwiftUI
import PIiOSCore

/// 三个根页 + 左上 ≡ 抽屉侧边栏（information-architecture.md §2/§3，不做底部标签栏）。
/// 根页切换只换根，不压栈；抽屉是浮层，关闭后回到原屏。
struct AppRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.scenePhase) private var scenePhase

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
        .overlay(alignment: .top) { toastLayer }
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
            LocalNotificationCoordinator.shared.bootstrap()
            await LocalNotificationCoordinator.shared.requestAuthorizationIfNeeded()
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
}
