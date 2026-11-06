import SwiftUI
import UIKit
import PIiOSCore

/// 设置子页路由（information-architecture.md §3：设置 → 服务器 / 安装 PI-adaptor）。
enum SettingsRoute: Hashable {
    case addServer
    case editServer(UUID)
    case installAdaptor(UUID)
    case models
    case adaptorProviders
    case skills
}

/// 触发 systemd 状态刷新的组合键：host 或在线状态任一变化都要重查（DEF-R4-001）。
private struct AdaptorUnitRefreshTrigger: Equatable {
    let hostID: UUID?
    let isOnline: Bool
}

/// S-03 设置（根）。分组：服务器 / 模型 / 本机。
///
/// 本增量可真实使用的部分：主机列表与增删改、外观、离线缓存上限、删除 host 的二次确认。
/// 没有连接层，所以主机状态一律「未配对 · 未连接」，不出现在线标记。
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var appearanceStore: AppearanceStore

    @State private var path: [SettingsRoute] = []
    @State private var showingAppearanceSheet = false
    @State private var showingCacheLimitSheet = false
    @State private var pendingRevokeHostID: UUID?
    @State private var adaptorUnitSnapshot: AdaptorUnitSnapshot?
    @State private var adaptorUnitError: String?
    @State private var isLoadingAdaptorUnit = false
    @State private var adaptorUnitRequestID: UUID?
    @State private var notificationStatus: LocalNotificationAuthorizationStatus = .notDetermined

    private var appearance: AppearanceMode {
        appearanceStore.mode
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    serversSection
                    tunnelSection
                    modelsSection
                    skillsSection
                    notificationSection
                    deviceSection
                    pushNotice
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.top, PISpacing.s8)
                .padding(.bottom, PISpacing.s32)
            }
            .piPageBackground()
            .piRootNavBar("设置", onMenu: model.openSidebar)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .addServer:
                    ServersScreen(hostID: nil) { path.append($0) }
                case .editServer(let hostID):
                    ServersScreen(hostID: hostID) { path.append($0) }
                case .installAdaptor(let hostID):
                    InstallAdaptorScreen(hostID: hostID)
                case .models:
                    ModelsScreen()
                case .adaptorProviders:
                    AdaptorProvidersScreen()
                case .skills:
                    SkillsScreen()
                }
            }
            .sheet(isPresented: $showingAppearanceSheet) {
                AppearanceSheet()
                    .environmentObject(appearanceStore)
            }
            .sheet(isPresented: $showingCacheLimitSheet) {
                CacheLimitSheet(current: model.offlineCacheLimit) { limit in
                    model.setOfflineCacheLimit(limit)
                }
            }
            .confirmationDialog(
                "撤销本机配对？",
                isPresented: revokeDialogBinding,
                titleVisibility: .visible
            ) {
                Button("撤销配对", role: .destructive) {
                    if let hostID = pendingRevokeHostID {
                        Task { await model.revokePairing(hostID: hostID) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清除本机保存的配对记录与设备凭证；服务器上的 PI-adaptor 安装、运行与会话不受影响。")
            }
            // DEF-R4-001：host 切换或隧道回到在线时都重查一次 systemd 状态，
            // 避免停服→恢复后仍展示上一次缓存的 inactive。
            .task(id: AdaptorUnitRefreshTrigger(hostID: model.currentHost?.id, isOnline: connection.state.isOnline)) {
                // systemd 查询走独立 SSH exec，离线时也能查（SET-05 要求离线可读）；
                // 触发键仍含在线状态，保证离线→在线后自动重查（DEF-R4-001）。
                await refreshAdaptorUnitStatus()
            }
            .task {
                // U10：设置页只展示系统通知权限并提供入口，不在进入页面时弹系统授权。
                await refreshNotificationStatus()
            }
        }
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRevokeHostID != nil },
            set: { if !$0 { pendingRevokeHostID = nil } }
        )
    }

    /// 当前服务器的最近一次认证失败分类（U17）。只读现有连接状态，不新增 ConnectionModel 写接口。
    private var currentAuthFailure: PairingAuthFailure {
        guard let host = model.currentHost, connection.currentCatalogHostID == host.id else {
            return .none
        }
        return PairingEntryPolicy.authFailure(from: connection.connectionStatus)
    }

    /// 当前服务器的设备令牌与重新配对入口策略。
    private var currentPairingPolicy: PairingEntryPolicy? {
        guard let host = model.currentHost else { return nil }
        return PairingEntryPolicy(
            hasDeviceToken: KeychainStore.loadDeviceToken(hostID: host.id) != nil,
            isPaired: host.pairedAt != nil,
            authFailure: currentAuthFailure
        )
    }

    // MARK: - 服务器

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "服务器")
            if model.hosts.isEmpty {
                PIEmptyState(
                    title: "还没有服务器",
                    message: "添加服务器后即可安装 PI-adaptor 并配对。",
                    actionTitle: "＋ 添加服务器",
                    action: { path.append(.addServer) },
                    actionIdentifier: "settings.addServer"
                )
            } else {
                PIGroup {
                    let repairPolicy = currentPairingPolicy
                    let showsRepair = repairPolicy?.shouldShowSettingsRepairRow == true
                    ForEach(Array(model.hosts.enumerated()), id: \.element.id) { index, host in
                        serverRow(
                            host,
                            showsDivider: index < model.hosts.count - 1 || showsRepair
                        )
                    }
                    if let current = model.currentHost, let repairPolicy,
                       repairPolicy.shouldShowSettingsRepairRow {
                        PIListRow(
                            title: repairPolicy.settingsRepairTitle,
                            subtitle: repairPolicy.settingsRepairSubtitle,
                            icon: "link",
                            iconTint: PIColor.warning,
                            showsChevron: true,
                            showsDivider: false,
                            action: { path.append(.editServer(current.id)) }
                        )
                        .accessibilityIdentifier("settings.pairingRepair")
                    }
                }
                addServerButton
            }
        }
    }

    private func serverRow(_ host: HostRecord, showsDivider: Bool) -> some View {
        PIListRow(
            title: host.name,
            subtitle: "\(host.address) · \(host.statusText) · \(host.isCurrent ? connection.state.displayText : "未连接")",
            icon: "server.rack",
            iconTint: host.isCurrent ? PIColor.accent : PIColor.text2,
            showsChevron: true,
            showsDivider: showsDivider,
            action: { path.append(.editServer(host.id)) }
        ) {
            if host.isCurrent {
                Text("当前")
                    .font(PIFont.metaSmall.weight(.semibold))
                    .foregroundStyle(PIColor.accent)
                    .padding(.horizontal, PISpacing.s8)
                    .padding(.vertical, 2)
                    .background(PIColor.accentSoft, in: Capsule())
            }
        }
    }

    private var addServerButton: some View {
        Button {
            path.append(.addServer)
        } label: {
            HStack(spacing: PISpacing.s8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .accessibilityHidden(true)
                Text("添加服务器")
                    .font(PIFont.button)
            }
            .foregroundStyle(PIColor.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PIMetrics.minHitTarget)
            .background(PIColor.accentSoft, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                    .strokeBorder(PIColor.accentBorder, lineWidth: PIMetrics.hairline)
            )
        }
        .buttonStyle(PIPressableButtonStyle())
        .accessibilityIdentifier("settings.addServer")
    }

    // MARK: - 隧道（真实状态）

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "隧道")
            if let host = model.currentHost {
                PIGroup(footer: tunnelFooter) {
                    PIListRow(
                        title: "连接状态",
                        subtitle: connection.state.detail,
                        value: connection.state.displayText,
                        icon: "antenna.radiowaves.left.and.right",
                        iconTint: connection.state.isOnline ? PIColor.success : PIColor.warning,
                        isEnabled: false,
                        showsDivider: true
                    )
                    .accessibilityIdentifier("settings.connectionState")
                    if let info = connection.info {
                        PIListRow(
                            title: "PI-adaptor 版本",
                            subtitle: "\(info.serverName) · 协议 \(info.protocolVersion)",
                            value: info.serverVersion,
                            icon: "shippingbox",
                            isEnabled: false,
                            showsDivider: true
                        )
                        .accessibilityIdentifier("settings.hostVersion")
                    }
                    PIListRow(
                        title: "systemd 服务",
                        subtitle: adaptorUnitError,
                        value: isLoadingAdaptorUnit
                            ? "查询中"
                            : adaptorUnitSnapshot?.activeState ?? "未查询",
                        icon: "gearshape.2",
                        isEnabled: true,
                        showsChevron: true,
                        showsDivider: true,
                        action: { Task { await refreshAdaptorUnitStatus() } }
                    )
                    .accessibilityIdentifier("settings.hostUnit")
                    if adaptorUnitSnapshot?.isActive != true || !connection.state.isOnline {
                        PIListRow(
                            title: "重启命令",
                            subtitle: "systemctl --user restart pi-adaptor.service",
                            icon: "terminal",
                            isEnabled: false,
                            showsDivider: true
                        )
                        .accessibilityIdentifier("settings.restartCommand")
                    }
                    if let error = connection.lastError {
                        PIListRow(
                            title: "最近一次错误",
                            subtitle: error,
                            icon: "exclamationmark.triangle",
                            iconTint: PIColor.danger,
                            isEnabled: currentAuthFailure.isFailure,
                            showsChevron: currentAuthFailure.isFailure,
                            showsDivider: true,
                            action: currentAuthFailure.isFailure
                                ? { path.append(.editServer(host.id)) }
                                : nil
                        )
                    }
                    // U17：设备令牌被拒绝时，错误提示就地给出可点的重新配对入口，
                    // 不让用户去猜「撤销配对」是不是恢复路径（撤销仍需服务器确认，语义未改）。
                    if currentPairingPolicy?.isRepairPromoted == true {
                        PIListRow(
                            title: "使用新的一次性令牌重新配对",
                            subtitle: "打开服务器页完成配对；新配对成功前旧设备令牌保留",
                            icon: "arrow.triangle.2.circlepath",
                            iconTint: PIColor.warning,
                            showsChevron: true,
                            showsDivider: true,
                            action: { path.append(.editServer(host.id)) }
                        )
                        .accessibilityIdentifier("settings.pairingRepairRow")
                    }
                    if connection.state.isOnline {
                        PIListRow(
                            title: "刷新项目与会话",
                            icon: "arrow.clockwise",
                            iconTint: PIColor.accent,
                            showsChevron: true,
                            showsDivider: true,
                            action: { Task { await connection.refreshRemote() } }
                        )
                        PIListRow(
                            title: "断开隧道",
                            icon: "bolt.slash",
                            iconTint: PIColor.danger,
                            showsDivider: false,
                            action: { Task { await connection.disconnect() } }
                        )
                    } else {
                        PIListRow(
                            title: "连接",
                            subtitle: connectDisabledReason(host),
                            icon: "bolt",
                            iconTint: PIColor.accent,
                            isEnabled: connectDisabledReason(host) == nil,
                            showsDivider: true,
                            action: { Task { await model.setCurrentHost(id: host.id) } }
                        )
                        PIListRow(
                            title: "断开隧道",
                            icon: "bolt.slash",
                            isEnabled: false,
                            showsDivider: false
                        )
                    }
                }
                if case .offline(let reason) = connection.state, let reason {
                    PIInlineMessage(kind: .warning, text: "未连接：\(reason)")
                }
                if connection.state.isOnline,
                   let info = connection.info,
                   let expected = model.currentHost?.installReceipt?.version,
                   !expected.isEmpty,
                   info.serverName != PIAdaptorRelease.runtimeServerName
                    || !PIAdaptorRelease.versionsMatch(info.serverVersion, expected) {
                    PIInlineMessage(
                        kind: .danger,
                        text: "运行版本不匹配：期望 \(PIAdaptorRelease.runtimeServerName) \(expected)，"
                            + "实际 \(info.serverName) \(info.serverVersion)。请重新安装 PI-adaptor。"
                    )
                    .accessibilityIdentifier("settings.runtimeVersionMismatch")
                }
            } else {
                PIListRow(
                    title: "连接状态",
                    subtitle: "还没有服务器",
                    isEnabled: false,
                    showsDivider: false
                )
            }
        }
    }

    private var tunnelFooter: String {
        "断开后按 1s/2s/4s/8s 自动重连。"
    }

    private func refreshAdaptorUnitStatus() async {
        let requestID = UUID()
        adaptorUnitRequestID = requestID
        guard let host = model.currentHost, host.pairedAt != nil else {
            if adaptorUnitRequestID == requestID {
                adaptorUnitSnapshot = nil
                adaptorUnitError = nil
                isLoadingAdaptorUnit = false
            }
            return
        }
        isLoadingAdaptorUnit = true
        do {
            let snapshot = try await connection.adaptorUnitSnapshot(record: host)
            guard adaptorUnitRequestID == requestID,
                  model.currentHost?.id == host.id
            else { return }
            adaptorUnitSnapshot = snapshot
            adaptorUnitError = nil
            isLoadingAdaptorUnit = false
        } catch {
            guard adaptorUnitRequestID == requestID,
                  model.currentHost?.id == host.id
            else { return }
            adaptorUnitSnapshot = nil
            adaptorUnitError = ConnectionErrorText.describe(error)
            isLoadingAdaptorUnit = false
        }
    }

    /// 连接入口的禁用原因：缺凭证/端口/令牌时直接说明，不做「能点但没反应」。
    private func connectDisabledReason(_ host: HostRecord) -> String? {
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        if KeychainStore.loadCredential(account: account) == nil {
            return "本机没有凭证：先在服务器页「保存并测试连接」"
        }
        if KeychainStore.loadDeviceToken(hostID: host.id) == nil {
            return "本机没有设备令牌：先在服务器页完成 PI-adaptor 配对"
        }
        return nil
    }

    // MARK: - 模型

    private var modelsSection: some View {
        PIGroup(
            "模型",
            footer: "模型清单保存在本机；API Key 只保存在服务器。"
        ) {
            PIListRow(
                title: "模型服务",
                subtitle: model.currentModelProviders.isEmpty
                    ? "尚未导入；进入后可从服务端自动发现模型"
                    : "\(model.currentModelProviders.count) 个服务 · \(model.currentModelProviders.reduce(0) { $0 + $1.models.count }) 个模型",
                icon: "cpu",
                iconTint: PIColor.accent,
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.models) }
            )
            PIListRow(
                title: "PI-adaptor v2 Provider",
                icon: "server.rack",
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.adaptorProviders) }
            )
            PIListRow(
                title: "默认模型",
                value: model.defaultModelLabel,
                icon: "star",
                isEnabled: false,
                showsDivider: false
            )
        }
    }

    private var skillsSection: some View {
        PIGroup("Skill") {
            PIListRow(
                title: "全局 Skill",
                subtitle: connection.state.isOnline ? "安装、更新、删除服务器 Skill" : "连接 PI-adaptor 后可管理",
                icon: "sparkles",
                iconTint: PIColor.accent,
                showsChevron: true,
                showsDivider: false,
                action: { path.append(.skills) }
            )
        }
    }

    // MARK: - 通知（U10）

    private var notificationSection: some View {
        let status = notificationStatus
        let action = NotificationPromptPolicy.settingsAction(status: status)
        return PIGroup(
            "通知",
            footer: "只在回到 App 时提示离开期间的更新；不会收到后台实时推送。"
        ) {
            PIListRow(
                title: "离开期间的更新提醒",
                subtitle: NotificationPromptPolicy.settingsSubtitle(status),
                value: NotificationPromptPolicy.statusText(status),
                icon: "bell",
                isEnabled: action != .none,
                showsChevron: action != .none,
                showsDivider: false,
                action: action == .none ? nil : { performNotificationAction(action) }
            )
            .accessibilityIdentifier("settings.notificationRow")
        }
    }

    private func performNotificationAction(_ action: NotificationPromptPolicy.SettingsAction) {
        switch action {
        case .requestAuthorization:
            Task {
                // 用户在这里主动启用：这是 App 内唯一主动弹系统授权的入口。
                await LocalNotificationCoordinator.shared.requestAuthorization()
                await refreshNotificationStatus()
            }
        case .openSystemSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .none:
            break
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await LocalNotificationCoordinator.shared.authorizationStatus()
    }

    // MARK: - 本机

    private var deviceSection: some View {
        PIGroup("本机") {
            PIListRow(
                title: "外观",
                subtitle: appearance.title,
                icon: "circle.lefthalf.filled",
                showsChevron: true,
                showsDivider: true,
                action: { showingAppearanceSheet = true }
            )
            PIListRow(
                title: "离线缓存上限",
                subtitle: "每会话 \(connection.cacheItemLimit) 条 · 最多 \(PersistedState.maxCachedConversations) 个会话",
                value: "\(model.offlineCacheLimit) 条",
                icon: "internaldrive",
                showsChevron: true,
                showsDivider: true,
                action: { showingCacheLimitSheet = true }
            )
            PIDangerRow(
                title: "撤销本机配对",
                isEnabled: model.isCurrentHostPaired,
                disabledReason: revokeDisabledReason,
                action: { pendingRevokeHostID = model.currentHost?.id }
            )
        }
    }

    private var revokeDisabledReason: String {
        if model.currentHost == nil {
            return "还没有服务器，没有可撤销的配对记录"
        }
        return "当前服务器未配对：配对流程属下一增量，没有可撤销的配对记录"
    }

    // MARK: - 固定说明（AC-16.2）

    private var pushNotice: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            Text("不会收到后台推送")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("打开 App 时才会刷新服务器状态与新消息；启用「离开期间的更新提醒」后，回到 App 时会提示离开期间的变化。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PISpacing.s4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 外观浮层

private struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text("外观")
                    .font(PIFont.display)
                    .foregroundStyle(PIColor.text)
                Text("选择立即作用于全部页面与浮层。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            }
            PIGroup {
                ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    PIOptionRow(
                        title: mode.title,
                        subtitle: mode.detail,
                        isSelected: appearanceStore.mode == mode,
                        showsDivider: index < AppearanceMode.allCases.count - 1
                    ) {
                        appearanceStore.mode = mode
                    }
                }
            }
            Spacer(minLength: 0)
            PIPrimaryButton(title: "完成") { dismiss() }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .piPageBackground()
        // 浮层自身也跟随选择切换（DEF-R4-002）：只靠根视图的 preferredColorScheme
        // 在部分系统版本下不会立即传到已呈现的 sheet。
        .preferredColorScheme(appearanceStore.mode.colorScheme)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
    }
}

// MARK: - 离线缓存上限浮层

private struct CacheLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Int) -> Void
    @State private var selected: Int

    init(current: Int, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        _selected = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text("离线缓存上限")
                    .font(PIFont.display)
                    .foregroundStyle(PIColor.text)
                Text("每个会话最多缓存的条数，默认 \(PersistedState.defaultOfflineCacheLimit) 条；本机最多缓存 \(PersistedState.maxCachedConversations) 个会话。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PIGroup {
                ForEach(Array(PersistedState.offlineCacheLimitOptions.enumerated()), id: \.element) { index, option in
                    PIOptionRow(
                        title: "\(option) 条",
                        isSelected: selected == option,
                        showsDivider: index < PersistedState.offlineCacheLimitOptions.count - 1
                    ) {
                        selected = option
                        onSelect(option)
                    }
                }
            }
            Spacer(minLength: 0)
            PIPrimaryButton(title: "完成") { dismiss() }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .piPageBackground()
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
    }
}
