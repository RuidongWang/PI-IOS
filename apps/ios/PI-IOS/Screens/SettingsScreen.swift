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
    case extensions
    case logs
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
    @State private var adaptorUnitHostID: UUID?
    @State private var notificationStatus: LocalNotificationAuthorizationStatus = .notDetermined
    /// 仅控制视图内诊断折叠；真实查询与错误来源保持不变。
    @State private var showsAdvancedDiagnostics = false
    @State private var lastDiagnosticSignature = ""

    private var appearance: AppearanceMode {
        appearanceStore.mode
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    tunnelSection
                    serversSection
                    modelsSection
                    skillsSection
                    notificationSection
                    logsSection
                    deviceSection
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.top, PISpacing.s8)
                .padding(.bottom, PISpacing.s32)
            }
            .piPageBackground()
            // 跨页面深链：别人（会话页的恢复入口）可以直接把用户送到子页，
            // 而不是丢到设置根页让他自己再找一次。
            //
            // 深链可能在本页创建之前就已设置：onChange 不会因初值触发，这里兜底消费一次。
            // consumePendingSettingsRoute() 会清空，两处都必须先取后判空，不能重复 append。
            .task {
                if let route = model.consumePendingSettingsRoute() {
                    path.append(route)
                }
            }
            .onChange(of: model.pendingSettingsRoute) { _, route in
                guard let route else { return }
                _ = model.consumePendingSettingsRoute()
                path.append(route)
            }
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
                case .extensions:
                    ExtensionsScreen(catalog: connection.extensions)
                case .logs:
                    LogsScreen()
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
                // R7：只说后果（会失去什么），不写「服务器不受影响」这类安抚。
                Text("将清除本机的配对记录与设备凭证。")
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
            .task { syncAdvancedDiagnostics() }
            .onChange(of: diagnosticSignature) { _, _ in
                syncAdvancedDiagnostics()
            }
        }
    }

    /// 版本不匹配只说「期望什么、实际什么」；怎么做由同一屏的按钮承担。
    private func runtimeMismatchDetail(serverName: String, serverVersion: String) -> String {
        "期望 \(PIAdaptorRelease.runtimeServerName) \(AdaptorRuntimeVersionPolicy.bundledVersion)，"
            + "实际 \(serverName) \(serverVersion)"
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
                // R5：空态 = 一句话 + 一个动作。
                PIEmptyState(
                    title: "还没有服务器",
                    actionTitle: "添加服务器",
                    action: { path.append(.addServer) },
                    actionIdentifier: "settings.addServer"
                )
            } else {
                PIGroup {
                    ForEach(Array(model.hosts.enumerated()), id: \.element.id) { index, host in
                        serverRow(host, showsDivider: index < model.hosts.count - 1)
                            .accessibilityIdentifier("settings.server.\(index)")
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
            Label("添加服务器", systemImage: "plus")
                .font(PIFont.button)
        }
        .buttonStyle(PISecondaryButtonStyle())
        .accessibilityIdentifier("settings.addServer")
    }

    // MARK: - 隧道（真实状态）

    /// quiet-v2 §6.1：顶部一张连接状态卡（服务器名 · 状态点 · 版本），下面一组动作。
    /// 「按 1s/2s/4s/8s 自动重连」这类解释删除：重连是连接层的状态，不是文案。
    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "当前连接")
            if let host = model.currentHost {
                connectionCard(host)
                PIGroup {
                    if connection.state.isOnline {
                        PIListRow(
                            title: "刷新",
                            icon: "arrow.clockwise",
                            iconTint: PIColor.accent,
                            showsChevron: true,
                            showsDivider: true,
                            action: { Task { await connection.refreshRemote() } }
                        )
                        .accessibilityIdentifier("settings.refresh")
                        PIListRow(
                            title: "断开",
                            icon: "bolt.slash",
                            iconTint: PIColor.text2,
                            showsDivider: false,
                            action: { Task { await connection.disconnect() } }
                        )
                        .accessibilityIdentifier("settings.disconnect")
                    } else {
                        PIListRow(
                            title: "连接",
                            subtitle: connectDisabledReason(host),
                            icon: "bolt",
                            iconTint: PIColor.accent,
                            isEnabled: connectDisabledReason(host) == nil,
                            showsDivider: false,
                            action: { Task { await model.setCurrentHost(id: host.id) } }
                        )
                        .accessibilityIdentifier("settings.connect")
                    }
                }
                advancedDiagnostics(host)
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

    /// 诊断仍在设置根页内，只折叠展示，不改变查询、修复或重装动作。
    private func advancedDiagnostics(_ host: HostRecord) -> some View {
        let showsRestart = adaptorUnitSnapshot?.isActive != true || !connection.state.isOnline
        let hasLastError = connection.lastError != nil
        let hasMismatch = hasRuntimeVersionMismatch
        let showsRepair = currentPairingPolicy?.shouldShowSettingsRepairRow == true

        return PIGroup {
            Button {
                withAnimation(PIMotion.standard) { showsAdvancedDiagnostics.toggle() }
            } label: {
                HStack(spacing: PISpacing.s12) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(PIColor.text2)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text("高级诊断")
                        .font(PIFont.listTitle)
                        .foregroundStyle(PIColor.text)
                    Spacer(minLength: PISpacing.s8)
                    Text(hasActiveDiagnosticIssue ? "需要处理" : "systemd 与日志")
                        .font(PIFont.caption)
                        .foregroundStyle(hasActiveDiagnosticIssue ? PIColor.warning : PIColor.text2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PIColor.text2)
                        .rotationEffect(.degrees(showsAdvancedDiagnostics ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.advancedDiagnostics.toggle")
            .accessibilityValue(showsAdvancedDiagnostics ? "expanded" : "collapsed")

            if showsAdvancedDiagnostics {
                PIRowDivider()
                if showsRepair, let repairPolicy = currentPairingPolicy {
                    PIListRow(
                        title: repairPolicy.settingsRepairTitle,
                        subtitle: repairPolicy.settingsRepairSubtitle,
                        icon: "link",
                        iconTint: PIColor.warning,
                        showsChevron: true,
                        showsDivider: true,
                        action: { path.append(.editServer(host.id)) }
                    )
                    .accessibilityIdentifier("settings.pairingRepair")
                }
                PIListRow(
                    title: "systemd 服务",
                    subtitle: adaptorUnitError,
                    value: isLoadingAdaptorUnit
                        ? "查询中"
                        : adaptorUnitSnapshot?.activeState ?? "未查询",
                    icon: "gearshape.2",
                    showsChevron: true,
                    showsDivider: showsRestart || hasLastError || hasMismatch,
                    action: { Task { await refreshAdaptorUnitStatus() } }
                )
                .accessibilityIdentifier("settings.hostUnit")
                if showsRestart {
                    restartCommandRow
                    if hasLastError || hasMismatch { PIRowDivider(leadingInset: 0) }
                }
                if let error = connection.lastError {
                    PIListRow(
                        title: "最近错误",
                        subtitle: error,
                        icon: "exclamationmark.triangle",
                        iconTint: PIColor.danger,
                        isEnabled: currentAuthFailure.isFailure,
                        showsChevron: currentAuthFailure.isFailure,
                        showsDivider: hasMismatch,
                        action: currentAuthFailure.isFailure
                            ? { path.append(.editServer(host.id)) }
                            : nil
                    )
                    .accessibilityIdentifier("settings.lastError")
                }
                if hasMismatch, let info = connection.info {
                    PIListRow(
                        title: "运行版本不匹配",
                        subtitle: runtimeMismatchDetail(
                            serverName: info.serverName,
                            serverVersion: info.serverVersion
                        ),
                        icon: "exclamationmark.octagon",
                        iconTint: PIColor.danger,
                        showsChevron: true,
                        showsDivider: false,
                        action: { path.append(.installAdaptor(host.id)) }
                    ) {
                        Text("重新安装")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.accent)
                    }
                    .accessibilityIdentifier("settings.runtimeVersionMismatch")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.advancedDiagnostics")
    }

    /// 身份与连接是主信息，版本为次信息；状态色只交给状态点。
    private func connectionCard(_ host: HostRecord) -> some View {
        PICard {
            HStack(alignment: .center, spacing: PISpacing.s8) {
                Circle()
                    .fill(connection.state.bannerKind.tint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text(host.name)
                        .font(PIFont.listTitle.weight(.semibold))
                        .foregroundStyle(PIColor.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(connection.state.displayText)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                }
                Spacer(minLength: PISpacing.s8)
                if let info = connection.info {
                    Text("v\(info.serverVersion)")
                        .font(PIFont.metaMono)
                        .foregroundStyle(PIColor.text2)
                        .lineLimit(1)
                        .accessibilityIdentifier("settings.hostVersion")
                }
            }
            if let detail = connection.state.detail {
                Text(detail)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.connectionState")
    }

    private var hasRuntimeVersionMismatch: Bool {
        guard connection.state.isOnline, let info = connection.info else { return false }
        return !AdaptorRuntimeVersionPolicy.isCompatible(
            serverName: info.serverName,
            serverVersion: info.serverVersion
        )
    }

    /// 用 Host + 异常类别作为签名：新异常自动展开，清空后收起；持续异常时允许用户手动折叠。
    private var diagnosticFlags: [String] {
        var flags: [String] = []
        if currentPairingPolicy?.shouldShowSettingsRepairRow == true { flags.append("pairing") }
        if connection.lastError != nil { flags.append("connection") }
        if adaptorUnitError != nil { flags.append("unit-error") }
        if let adaptorUnitSnapshot, !adaptorUnitSnapshot.isActive { flags.append("unit-inactive") }
        if hasRuntimeVersionMismatch { flags.append("version") }
        return flags
    }

    private var hasActiveDiagnosticIssue: Bool { !diagnosticFlags.isEmpty }

    private var diagnosticSignature: String {
        let host = model.currentHost?.id.uuidString ?? "none"
        return "\(host)|\(diagnosticFlags.joined(separator: ","))"
    }

    private func syncAdvancedDiagnostics() {
        guard diagnosticSignature != lastDiagnosticSignature else { return }
        lastDiagnosticSignature = diagnosticSignature
        showsAdvancedDiagnostics = hasActiveDiagnosticIssue
    }

    /// 重启命令：服务没在跑、或当前不在线时才出现（R8：这是用户要照着输入的数据）。
    private var restartCommandRow: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            Text("重启命令")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text2)
            Text("systemctl --user restart pi-adaptor.service")
                .font(PIFont.metaMono)
                .foregroundStyle(PIColor.text)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.restartCommand")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
    }

    private func refreshAdaptorUnitStatus() async {
        let requestID = UUID()
        adaptorUnitRequestID = requestID
        guard let host = model.currentHost, host.pairedAt != nil else {
            if adaptorUnitRequestID == requestID {
                adaptorUnitSnapshot = nil
                adaptorUnitError = nil
                adaptorUnitHostID = nil
                isLoadingAdaptorUnit = false
            }
            return
        }
        if adaptorUnitHostID != host.id {
            // 新 Host 查询返回前不得短暂展示旧 Host 的错误或 inactive 状态。
            adaptorUnitSnapshot = nil
            adaptorUnitError = nil
            adaptorUnitHostID = host.id
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
            return "本机没有凭证：先在服务器页保存凭证"
        }
        if KeychainStore.loadDeviceToken(hostID: host.id) == nil {
            return "本机没有设备令牌：先在服务器页完成配对"
        }
        return nil
    }

    // MARK: - 模型

    private var modelsSection: some View {
        PIGroup("模型") {
            // quiet-v2 §0.2 第 2 条：「模型服务」是这一域唯一的一级入口。
            // v2 provider 记录是它的内部能力，入口收进 ModelsScreen 底部
            // （`models.serverRecords`），设置页不再并列两个名词。
            PIListRow(
                title: "模型服务",
                subtitle: model.currentModelProviders.isEmpty
                    ? "0 个服务"
                    : "\(model.currentModelProviders.count) 个服务 · \(model.currentModelProviders.reduce(0) { $0 + $1.models.count }) 个模型",
                icon: "cpu",
                iconTint: PIColor.accent,
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.models) }
            )
            .accessibilityIdentifier("settings.models")
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
        PIGroup("能力与扩展") {
            PIListRow(
                title: "全局 Skill",
                icon: "sparkles",
                iconTint: PIColor.accent,
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.skills) }
            )
            .accessibilityIdentifier("settings.skills")
            PIListRow(
                title: "扩展",
                icon: "puzzlepiece.extension",
                showsChevron: true,
                showsDivider: false,
                action: { path.append(.extensions) }
            )
            .accessibilityIdentifier("settings.extensions")
        }
    }

    // MARK: - 通知（U10）

    private var notificationSection: some View {
        let status = notificationStatus
        let action = NotificationPromptPolicy.settingsAction(status: status)
        return PIGroup("通知") {
            PIListRow(
                title: "更新提醒",
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

    // MARK: - 日志

    /// 副标题只说当前状态（记录中 · 等级 / 已关闭），不复述「运行日志是什么」。
    private var logsSection: some View {
        PIGroup("日志") {
            PIListRow(
                title: "运行日志",
                subtitle: model.logConfiguration.isEnabled
                    ? "记录中 · \(model.logConfiguration.level.title)"
                    : "已关闭",
                icon: "doc.text.magnifyingglass",
                showsChevron: true,
                showsDivider: false,
                action: { path.append(.logs) }
            )
            .accessibilityIdentifier("settings.logs")
        }
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
            .accessibilityIdentifier("settings.appearance")
            PIListRow(
                title: "离线缓存上限",
                value: "\(model.offlineCacheLimit) 轮",
                icon: "internaldrive",
                showsChevron: true,
                showsDivider: true,
                action: { showingCacheLimitSheet = true }
            )
            .accessibilityIdentifier("settings.cacheLimit")
            PIDangerRow(
                title: "撤销本机配对",
                isEnabled: model.isCurrentHostPaired,
                disabledReason: revokeDisabledReason,
                action: { pendingRevokeHostID = model.currentHost?.id }
            )
            .accessibilityIdentifier("settings.revokePairing")
        }
    }

    private var revokeDisabledReason: String {
        if model.currentHost == nil {
            return "还没有服务器"
        }
        return "当前服务器未配对"
    }
}

// MARK: - 外观浮层

private struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            Text("外观")
                .font(PIFont.display)
                .foregroundStyle(PIColor.text)
            PIGroup {
                ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    PIOptionRow(
                        title: mode.title,
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
            Text("离线缓存上限")
                .font(PIFont.display)
                .foregroundStyle(PIColor.text)
            PIGroup {
                ForEach(Array(PersistedState.offlineCacheLimitOptions.enumerated()), id: \.element) { index, option in
                    PIOptionRow(
                        title: "\(option) 轮",
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
