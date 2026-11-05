import SwiftUI
import PIiOSCore
import PIiOSNet

/// S-06 安装 PI-adaptor。
///
/// 页面只展示 runner 的真实状态文件与事件，不伪造进度。远端安装脚本在
/// `setsid nohup` 子进程里继续运行；本页通过短 exec 轮询，因此锁屏或短暂
/// 离开页面不会把 69 MB 下载绑在单次 SSH exec 上。
struct InstallAdaptorScreen: View {
    let hostID: UUID
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = InstallAdaptorCoordinator()

    @State private var portText = ""
    @State private var didSeedPort = false
    @State private var showingLog = false
    @State private var sudoCredential = ""
    /// 强制重装：忽略已存在的 PI-adaptor install receipt，重新下载并执行验证。
    @State private var forceReinstall = false
    @State private var directEndpoint = ""
    @State private var directName = ""
    @State private var directPortText = "9443"
    @FocusState private var portFocused: Bool

    private var host: HostRecord? {
        model.hosts.first(where: { $0.id == hostID })
    }

    private var portError: String? {
        let text = portText.piTrimmed
        if text.isEmpty {
            return "安装必须填写 PI-adaptor 常驻端口"
        }
        return HostValidator.hostPortError(text)
    }

    private var wantsDirect: Bool {
        !directEndpoint.piTrimmed.isEmpty || !directName.piTrimmed.isEmpty
    }

    private var canonicalDirectEndpoint: String? {
        wantsDirect ? HostValidator.canonicalDirectEndpoint(directEndpoint) : nil
    }

    private var directConfiguration: BootstrapDirectConfiguration? {
        guard wantsDirect, let port = Int(portText.piTrimmed), let directPort = Int(directPortText.piTrimmed) else {
            return nil
        }
        return try? BootstrapDirectConfiguration(
            directName: directName.piTrimmed,
            directPort: directPort,
            loopbackPort: port
        )
    }

    private var directConfigurationError: String? {
        guard wantsDirect else { return nil }
        if canonicalDirectEndpoint == nil {
            return "Direct endpoint 必须是精确的 wss URL，且路径为 /v1/racp/ws"
        }
        if directConfiguration == nil {
            return "请填写纯 DNS/IP directName 与不同于 loopback 的 direct 端口"
        }
        return nil
    }

    private var canStart: Bool {
        host != nil && portError == nil && directConfigurationError == nil && !coordinator.isRunning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                targetCard
                if let host {
                    receiptCard(host)
                    configurationCard
                    statusBanners
                    if coordinator.state != nil {
                        progressCard
                    }
                    failureCard
                    actions
                } else {
                    missingHostCard
                }
                privacyCard
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("安装 PI-adaptor")
        .onAppear(perform: seedPort)
        // 指纹核对浮层统一由 AppRootView 呈现（DEF-R4-004）。
        .sheet(isPresented: $showingLog) {
            InstallAdaptorLogSheet(coordinator: coordinator) {
                await coordinator.loadLog(model: model, connection: connection, hostID: hostID)
            }
        }
        .piMessageAlert(title: "安装未完成", message: Binding(
            get: {
                coordinator.phase == .failed && !coordinator.isFailureAlertDismissed
                    ? coordinator.failureSummary : nil
            },
            set: { if $0 == nil { coordinator.dismissFailure() } }
        ))
        .sheet(
            isPresented: Binding(
                get: { coordinator.pendingDirectTrust != nil },
                set: { if !$0 { coordinator.rejectPendingDirectTrust() } }
            )
        ) {
            if let trust = coordinator.pendingDirectTrust {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: PISpacing.s16) {
                            Text("请逐字核对可信 SSH 提供的完整叶证书 SHA-256 与 adaptor hostId。拒绝不会保存 pin，也不会影响已完成配对。")
                                .fixedSize(horizontal: false, vertical: true)
                            Text(wrappedFingerprint(trust.certificateSHA256))
                                .font(PIFont.codeMono)
                                .textSelection(.enabled)
                                .accessibilityLabel(trust.certificateSHA256)
                                .accessibilityIdentifier("installHost.directTrustPin")
                            Text(trust.hostId)
                                .font(PIFont.codeMono)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("installHost.directTrustHostId")
                            PIPrimaryButton(title: "授权直连") {
                                coordinator.authorizePendingDirectTrust()
                            }
                            .accessibilityIdentifier("installHost.directAuthorize")
                            PISecondaryButton(title: "仅使用 SSH") {
                                coordinator.rejectPendingDirectTrust()
                            }
                            .accessibilityIdentifier("installHost.directSSHOnly")
                        }
                        .padding(PIMetrics.pageMargin)
                    }
                    .navigationTitle("确认 Direct 证书与 hostId")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        switch coordinator.phase {
        case .running:
            PIStatusBanner(
                kind: .info,
                text: "正在安装 PI-adaptor",
                detail: coordinator.activity
            )
            if let notice = coordinator.releaseNotice {
                PIStatusBanner(
                    kind: .warning,
                    text: "未能获取最新稳定发布，已回退内置版本",
                    detail: notice
                )
                .accessibilityIdentifier("installHost.fallbackNotice")
            }
        case .stalled:
            PIStatusBanner(
                kind: .warning,
                text: "安装暂时没有进展",
                detail: (coordinator.stallMessage
                    ?? "这是一个可恢复点。可以查看日志；流程仍会继续轮询到 15 分钟。")
                    + " 最终失败后可重试，服务器会复用已下载分片和有效回执。"
            )
        case .success:
            PIStatusBanner(
                kind: coordinator.postInstallWarning == nil ? .success : .warning,
                text: coordinator.postInstallWarning == nil
                    ? "安装与设备验证完成"
                    : "安装与设备验证完成，但有提示",
                detail: coordinator.activity
            )
            if let directError = coordinator.directError {
                PIInlineMessage(kind: .warning, text: directError)
                    .accessibilityIdentifier("installHost.directError")
            }
            if let notice = coordinator.releaseNotice {
                PIStatusBanner(
                    kind: .warning,
                    text: "本次使用内置回退版本",
                    detail: notice
                )
                .accessibilityIdentifier("installHost.fallbackNotice")
            }
        case .directFailed:
            PIStatusBanner(
                kind: .warning,
                text: "配对已完成，Direct 首验未完成",
                detail: coordinator.directError ?? "Direct 首验失败"
            )
            .accessibilityIdentifier("installHost.directError")
            Text(coordinator.activity)
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("installHost.directRetryActivity")
        case .failed:
            PIInlineMessage(
                kind: .danger,
                text: "安装失败详情见下方「故障分类」。"
            )
        case .idle:
            PIStatusBanner(
                kind: .info,
                text: "安装会先核对服务器指纹",
                detail: "首次连接必须先确认 SSH SHA256 指纹。安装写入该用户的 ~/.pi-adaptor/releases 与 pi-adaptor.service。"
            )
        }
    }

    private var targetCard: some View {
        PICard {
            Text("目标服务器")
                .font(PIFont.metaSmall)
                .tracking(1.1)
                .foregroundStyle(PIColor.text3)
            if let host {
                Text(host.name)
                    .font(PIFont.display)
                    .foregroundStyle(PIColor.text)
                Text("\(host.address) · \(host.statusText)")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            } else {
                Text("这台服务器的记录已不存在")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("可能已在设置里删除。返回服务器列表重新添加。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func receiptCard(_ host: HostRecord) -> some View {
        if let receipt = host.installReceipt {
            PICard {
                Text("上次成功安装")
                    .font(PIFont.metaSmall)
                    .tracking(1.1)
                    .foregroundStyle(PIColor.text3)
                Text("v\(receipt.version) · 端口 \(String(receipt.hostPort))\(receiptSourceSuffix(receipt))")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("完成于 \(receipt.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
            }
        }
    }

    private func wrappedFingerprint(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 16).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: min(16, raw.distance(from: start, to: raw.endIndex)))
            return String(raw[start..<end])
        }.joined(separator: "\n")
    }

    private func receiptSourceSuffix(_ receipt: AdaptorInstallReceipt) -> String {
        switch receipt.releaseSource {
        case .latest:
            return " · 来源：GitHub 最新稳定发布"
        case .fallback:
            return " · 来源：内置回退版本"
        case nil:
            return ""
        }
    }

    private var configurationCard: some View {
        PIGroup(
            "安装参数",
            footer: "服务器本地监听端口（非 SSH 端口），安装成功后自动写回记录。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                PIFormField(
                    label: "PI-adaptor 端口",
                    hint: "建议 44271；不能填 0",
                    error: portError
                ) {
                    TextField("44271", text: $portText)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($portFocused)
                        .accessibilityIdentifier("installHost.port")
                }
                PIFormField(
                    label: "Direct endpoint（可选）",
                    hint: "留空表示仅 SSH；手填后才可在可信 trust 到达后请求授权",
                    error: directConfigurationError
                ) {
                    TextField("wss://host:9443/v1/racp/ws", text: $directEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("installHost.directEndpoint")
                }
                PIFormField(label: "Direct SAN DNS/IP") {
                    TextField("host.example 或 100.64.0.10", text: $directName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("installHost.directName")
                }
                PIFormField(label: "Direct 监听端口", hint: "独立于 loopback 端口") {
                    TextField("9443", text: $directPortText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("installHost.directPort")
                }
                Text("自动安装 GitHub 最新稳定发布；不可用时回退内置版本。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("installHost.releasePolicy")
                if let resolution = coordinator.resolvedRelease {
                    Text("本次目标：PI-adaptor \(resolution.release.version) · \(resolution.source.displayName)")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("installHost.resolvedRelease")
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            PISectionHeader(text: "安装进度")
            if let state = coordinator.state {
                downloadCard(state)
                PIGroup(footer: "步骤来自 ~/.pi-adaptor/.bootstrap/state.json；连接中断后重新进入本页可恢复或重新安装。") {
                    ForEach(Array(InstallStepDescriptor.all.enumerated()), id: \.element.id) { index, step in
                        let state = coordinator.value(for: step.step)
                        PIListRow(
                            title: step.title,
                            subtitle: step.detail,
                            value: state,
                            icon: stepIcon(state).0,
                            iconTint: stepIcon(state).1,
                            isEnabled: false,
                            showsDivider: index < InstallStepDescriptor.all.count - 1
                        )
                    }
                }
                if !coordinator.transitionNotes.isEmpty {
                    PIStatusBanner(
                        kind: .warning,
                        text: "状态推进异常",
                        detail: coordinator.transitionNotes.joined(separator: "\n")
                    )
                }
            }
        }
    }

    private func downloadCard(_ state: BootstrapStateFile) -> some View {
        PICard {
            Text("下载数据")
                .font(PIFont.metaSmall)
                .tracking(1.1)
                .foregroundStyle(PIColor.text3)
            let downloaded = state.artifact?.downloadedBytes ?? 0
            let total = state.artifact?.bytes ?? 0
            Text(coordinator.byteSummary(state: state))
                .font(PIFont.listTitle)
                .foregroundStyle(PIColor.text)
            if total > 0 {
                ProgressView(value: Double(min(downloaded, total)), total: Double(total))
                    .tint(PIColor.accent)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(Int(Double(min(downloaded, total)) / Double(total) * 100))%")
            } else if coordinator.isRunning && state.step == .download {
                ProgressView()
                    .tint(PIColor.accent)
                    .accessibilityLabel("正在下载")
            }
            if let name = state.artifact?.name {
                Text(name)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var failureCard: some View {
        if coordinator.phase == .failed {
            PICard {
                Text("故障分类")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text2)
                Text(coordinator.failureCode?.rawValue ?? "client-error")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PIColor.danger)
                    .textSelection(.enabled)
                if let code = coordinator.failureCode {
                    Text(code.displayMessage)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.failureCode == .pairFailed {
                    Text("配对失败后服务器已恢复原状态；重试会重新启动配对。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if [.downloadFailed, .checksumMismatch].contains(coordinator.failureCode),
                   coordinator.failureCount >= 2 {
                    Text("已连续失败 \(coordinator.failureCount) 次：请检查服务器出网是否经过需要认证的代理，或 GitHub Release 是否可达。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("installHost.proxyHint")
                }
                if let detail = coordinator.failureDetail, !detail.isEmpty {
                    Text(detail)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if coordinator.failureCode == .unitFailed {
                    SecureField("sudo 密码", text: $sudoCredential)
                        .textContentType(.password)
                        .disabled(coordinator.isRunning)
                        .accessibilityIdentifier("installHost.sudoCredential")
                    PISecondaryButton(
                        title: "重新授权并继续",
                        isEnabled: !sudoCredential.isEmpty && !coordinator.isRunning
                    ) {
                        guard let host, let port = Int(portText.piTrimmed) else { return }
                        coordinator.start(
                            host: host,
                            port: port,
                            sudoCredential: sudoCredential,
                            direct: directConfiguration,
                            directEndpoint: canonicalDirectEndpoint,
                            model: model,
                            connection: connection
                        )
                    }
                    .accessibilityIdentifier("installHost.retrySudo")
                }
                Text("重试会复用已下载的分片与有效安装回执。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: PISpacing.s12) {
            if coordinator.phase == .directFailed, let host {
                PIPrimaryButton(
                    title: "仅使用 SSH 完成",
                    isEnabled: true,
                    identifier: "installHost.completeSSHOnly"
                ) {
                    Task {
                        await coordinator.completeDirectWithSSHOnly(
                            host: host,
                            model: model,
                            connection: connection
                        )
                    }
                }
            }
            Toggle(isOn: $forceReinstall) {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text("强制重装（忽略已装版本）")
                        .font(PIFont.captionStrong)
                    Text("勾选后重新下载并激活当前发布包；版本没变但发布字节变了时必须勾选。")
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!canStart)
            .accessibilityIdentifier("installHost.forceReinstall")
            PIPrimaryButton(
                title: primaryButtonTitle,
                isEnabled: canStart && coordinator.failureCode != .unitFailed,
                identifier: "installHost.start"
            ) {
                portFocused = false
                if coordinator.phase == .directFailed, let host {
                    Task {
                        await coordinator.retryDirectOnly(
                            host: host,
                            model: model,
                            connection: connection
                        )
                    }
                } else {
                    guard let host, let port = Int(portText.piTrimmed) else { return }
                    coordinator.start(
                        host: host,
                        port: port,
                        forceReinstall: forceReinstall,
                        direct: directConfiguration,
                        directEndpoint: canonicalDirectEndpoint,
                        model: model,
                        connection: connection
                    )
                }
            }
            HStack(spacing: PISpacing.s12) {
                PISecondaryButton(
                    title: coordinator.isLoadingLog ? "正在读取日志…" : "查看安装日志",
                    isEnabled: !coordinator.isLoadingLog
                ) {
                    showingLog = true
                    Task {
                        await coordinator.loadLog(
                            model: model,
                            connection: connection,
                            hostID: hostID
                        )
                    }
                }
                .accessibilityIdentifier("installHost.log")
                PISecondaryButton(title: "刷新日志") {
                    Task {
                        await coordinator.loadLog(
                            model: model,
                            connection: connection,
                            hostID: hostID
                        )
                    }
                }
                .disabled(coordinator.isLoadingLog)
                .accessibilityIdentifier("installHost.log.refresh")
            }
            if coordinator.phase == .failed {
                PISecondaryButton(title: "返回服务器") {
                    dismiss()
                }
                .accessibilityIdentifier("installHost.back")
            }
        }
    }

    private var primaryButtonTitle: String {
        switch coordinator.phase {
        case .running, .stalled:
            return "正在安装…"
        case .directFailed:
            return "重试 Direct"
        case .failed:
            switch coordinator.failureCode {
            case .downloadFailed, .checksumMismatch:
                return "重试下载"
            case .pairFailed:
                return "重新配对"
            default:
                return "重试安装"
            }
        case .success:
            return "重新运行安装"
        case .idle:
            return "开始安装"
        }
    }

    private var missingHostCard: some View {
        PICard {
            Text("无法开始")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("服务器记录已被删除，请返回服务器页重新添加并保存 SSH 凭证。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
        }
    }

    private var privacyCard: some View {
        PICard {
            Text("安全边界")
                .font(PIFont.metaSmall)
                .tracking(1.1)
                .foregroundStyle(PIColor.text3)
            Text("配对令牌只在内存中使用，随即从服务器删除；设备令牌只写入本机 Keychain。令牌与 API Key 都不会进入日志或状态文件。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepIcon(_ state: String) -> (String, Color) {
        switch state {
        case "完成": return ("checkmark.circle", PIColor.success)
        case "进行中": return ("clock", PIColor.accent)
        case "失败": return ("xmark.circle", PIColor.danger)
        default: return ("circle", PIColor.text3)
        }
    }

    private func seedPort() {
        guard !didSeedPort else { return }
        didSeedPort = true
        if let existing = host?.hostPort, (1...65_535).contains(existing) {
            portText = String(existing)
        } else {
            portText = "44271"
        }
        directEndpoint = host?.directEndpoint ?? ""
        if let endpoint = host?.directEndpoint.flatMap(URL.init(string:)) {
            directName = endpoint.host ?? ""
            directPortText = endpoint.port.map(String.init) ?? "9443"
        }
    }
}

private struct InstallAdaptorLogSheet: View {
    @ObservedObject var coordinator: InstallAdaptorCoordinator
    let reload: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if coordinator.isLoadingLog {
                    ProgressView("正在读取 bootstrap.log…")
                        .padding(PISpacing.s24)
                } else if coordinator.logError == nil {
                    Text(coordinator.logText ?? "还没有读取日志。")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PIColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(PIMetrics.pageMargin)
                }
            }
            .background(PIColor.bg)
            .piMessageAlert(title: "日志读取失败", message: Binding(
                get: { coordinator.logError },
                set: { if $0 == nil { coordinator.dismissLogError() } }
            ))
            .navigationTitle("安装日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("刷新") { Task { await reload() } }
                        .disabled(coordinator.isLoadingLog)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            if coordinator.logText == nil {
                await reload()
            }
        }
    }
}

@MainActor
private final class InstallAdaptorCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case stalled
        case success
        case directFailed
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state: BootstrapStateFile?
    @Published private(set) var activity = "准备探测服务器平台。"
    @Published private(set) var stallMessage: String?
    @Published private(set) var failureCode: BootstrapFailureCode?
    @Published private(set) var failureDetail: String?
    @Published private(set) var failureCount = 0
    @Published private(set) var isFailureAlertDismissed = false
    @Published private(set) var transitionNotes: [String] = []
    @Published private(set) var postInstallWarning: String?
    @Published private(set) var resolvedRelease: AdaptorReleaseResolution?
    /// 仅在回退内置版本时非空，展示固定原因。
    @Published private(set) var releaseNotice: String?
    @Published private(set) var logText: String?
    @Published private(set) var logError: String?
    @Published private(set) var isLoadingLog = false
    @Published private(set) var pendingDirectTrust: BootstrapDirectTrust?
    @Published private(set) var directError: String?
    @Published private(set) var directAttemptId: String?

    private var runTask: Task<Void, Never>?
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    private var runID = UUID()

#if DEBUG
    init() {
        switch ProcessInfo.processInfo.environment["PI_IOS_INSTALL_FIXTURE_FAILURE"] {
        case "download-twice":
            phase = .failed
            failureCode = .downloadFailed
            failureCount = 2
            failureDetail = "UI fixture：下载在 42% 中断。"
        case "pair-expired":
            phase = .failed
            failureCode = .pairFailed
            failureCount = 1
            failureDetail = "UI fixture：一次性配对令牌已过期。"
        case "sudo-failure":
            phase = .failed
            failureCode = .unitFailed
            failureCount = 1
            failureDetail = "UI fixture：sudo 密码错误。"
        default:
            break
        }
        switch ProcessInfo.processInfo.environment["PI_IOS_INSTALL_FIXTURE_DIRECT"] {
        case "confirm":
            let trustJSON = "{\"schemaVersion\":1,\"attemptId\":\"fixture-direct\",\"hostId\":\"host_fixture_direct\",\"certificateSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"notBefore\":\"2026-01-01T00:00:00Z\",\"notAfter\":\"2099-01-01T00:00:00Z\"}"
            let trust = try! BootstrapDirectTrust.parse(
                data: Data(trustJSON.utf8),
                expectedAttemptId: "fixture-direct"
            )
            Task { @MainActor in self.pendingDirectTrust = trust }
        case "failed":
            phase = .directFailed
            directError = "tlsTrust：UI fixture 的 Direct 首验失败"
            directAttemptId = "fixture-direct-failed"
            activity = "配对与 hostId 已保存；Direct 首验失败，等待你明确选择。"
        default:
            break
        }
    }
#endif

    var isRunning: Bool { phase == .running || phase == .stalled }

    var failureSummary: String {
        if failureDetail == nil, let failureCode {
            return failureCode.displayMessage
        }
        return failureDetail ?? "安装器返回了未知错误。"
    }

    func dismissFailure() {
        isFailureAlertDismissed = true
    }

    func dismissLogError() {
        logError = nil
    }

    private func requestDirectAuthorization(_ trust: BootstrapDirectTrust) async -> Bool {
        pendingDirectTrust = trust
        return await withCheckedContinuation { continuation in
            trustContinuation = continuation
        }
    }

    func authorizePendingDirectTrust() {
        pendingDirectTrust = nil
        trustContinuation?.resume(returning: true)
        trustContinuation = nil
    }

    func rejectPendingDirectTrust() {
        pendingDirectTrust = nil
        trustContinuation?.resume(returning: false)
        trustContinuation = nil
    }

    func start(
        host: HostRecord,
        port: Int,
        sudoCredential: String? = nil,
        forceReinstall: Bool = false,
        direct: BootstrapDirectConfiguration? = nil,
        directEndpoint: String? = nil,
        model: AppModel,
        connection: ConnectionModel
    ) {
        guard !isRunning else { return }
        let generation = UUID()
        let previousDirectAttempt = directAttemptId
        runID = generation
        phase = .running
        state = nil
        activity = "正在连接 SSH 并探测服务器平台。"
        stallMessage = nil
        failureCode = nil
        failureDetail = nil
        isFailureAlertDismissed = false
        transitionNotes = []
        postInstallWarning = nil
        resolvedRelease = nil
        releaseNotice = nil
        directError = nil
        directAttemptId = nil
        rejectPendingDirectTrust()

        runTask = Task { [weak self] in
            guard let self else { return }
            if let previousDirectAttempt {
                await connection.completeInstallSSHOnly(
                    hostID: host.id,
                    attemptId: previousDirectAttempt
                )
            }
            do {
                if let sudoCredential {
                    guard !sudoCredential.isEmpty else {
                        throw AdaptorInstallError.emptySudoPassword
                    }
                    self.activity = "正在通过 SSH stdin 授权 loginctl enable-linger。"
                    try await connection.authorizeAdaptorInstall(
                        record: host,
                        sudoPassword: sudoCredential
                    )
                    guard self.runID == generation else { return }
                }
                let outcome = try await connection.installAdaptor(
                    record: host,
                    port: port,
                    force: forceReinstall,
                    direct: direct,
                    directEndpoint: directEndpoint,
                    directTrustAuthorizer: { [weak self] trust in
                        guard let self, direct != nil, directEndpoint != nil else { return false }
                        return await self.requestDirectAuthorization(trust)
                    },
                    onReleaseResolved: { resolution in
                        guard self.runID == generation else { return }
                        self.resolvedRelease = resolution
                        self.releaseNotice = resolution.fallbackReason
                        if let reason = resolution.fallbackReason {
                            self.activity = "未能解析最新稳定发布，已回退内置 PI-adaptor \(resolution.release.version)：\(reason)。"
                        } else {
                            self.activity = "已解析最新稳定发布 PI-adaptor \(resolution.release.version)，正在生成安装脚本。"
                        }
                    },
                    eventHandler: { event in
                        await self.receive(event)
                    }
                )
                guard self.runID == generation else { return }
                self.finish(outcome: outcome, host: host, model: model, connection: connection)
            } catch is CancellationError {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.isFailureAlertDismissed = false
                self.failureCount += 1
                self.failureDetail = "安装任务已取消；服务器上的后台任务可能仍在继续，可查看日志或重试。"
            } catch {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.isFailureAlertDismissed = false
                self.failureCount += 1
                self.failureDetail = ConnectionErrorText.describe(error)
            }
            if self.runID == generation {
                self.runTask = nil
            }
        }
    }

    private func receive(_ event: BootstrapRunnerEvent) {
        switch event {
        case .state(let next):
            if let previous = state,
               previous.step == next.step,
               (previous.artifact?.downloadedBytes ?? 0) == (next.artifact?.downloadedBytes ?? 0) {
                // Preserve the stalled presentation until there is real progress.
            } else {
                stallMessage = nil
                if phase == .stalled { phase = .running }
            }
            state = next
            activity = "当前步骤：\(stepTitle(next.step))"
        case .transitionIssues(let issues):
            transitionNotes = issues.map(\.message)
        case .stalled(let message):
            stallMessage = message
            if phase == .running { phase = .stalled }
        case .pairingStarted:
            activity = "正在用同一 SSH 连接交换一次性配对令牌。"
        case .pairingCompleted(let deviceId):
            activity = "配对成功，设备 \(deviceId) 已写入 Keychain；正在等待常驻服务启动。"
        case .verificationStarted:
            activity = "正在用新设备令牌重连 RACP 并发送 connection/ping。"
        case .verificationCompleted:
            activity = "设备令牌验证通过，正在等待 install 的最终回执。"
        }
    }

    private func finish(
        outcome: AdaptorInstallRunOutcome,
        host: HostRecord,
        model: AppModel,
        connection: ConnectionModel
    ) {
        switch outcome.result {
        case .succeeded(let success):
            state = success.state
            let persisted = model.completeAdaptorInstallation(
                id: host.id,
                expectedHost: host.host,
                expectedPort: host.port,
                expectedUsername: host.username,
                port: success.port,
                version: outcome.releaseVersion,
                attemptId: outcome.attemptId,
                releaseSource: outcome.releaseSource.map { $0.isFallback ? .fallback : .latest }
            )
            switch BootstrapInstallCompletionPolicy.disposition(
                persisted: persisted,
                saveError: model.saveError
            ) {
            case .succeeded:
                if outcome.requiresSSHOnlyConfirmation {
                    phase = .directFailed
                    directError = outcome.directError ?? "Direct 首验失败"
                    directAttemptId = outcome.attemptId
                    postInstallWarning = outcome.directError
                    activity = "配对与 hostId 已保存；Direct 首验失败，等待你明确选择。"
                    failureCode = nil
                    failureDetail = nil
                    return
                }
                if let directError = outcome.directError {
                    phase = .failed
                    isFailureAlertDismissed = false
                    failureDetail = directError
                    failureCount += 1
                    return
                }
                let info = success.serverInfo
                phase = .success
                let sourceName = outcome.releaseSource?.displayName ?? "版本来源未知"
                activity = "\(info.serverName) \(info.serverVersion) 正在运行（\(sourceName)）；pi-adaptor.service active、设备令牌重连与 ping 均成功。"
                if let source = outcome.releaseSource, source.isFallback {
                    releaseNotice = source.fallbackReason
                }
                postInstallWarning = nil
                failureCode = nil
                failureDetail = nil
                failureCount = 0
                connectAfterInstall(host: host, model: model, connection: connection)
            case .failed(let reason):
                phase = .failed
                isFailureAlertDismissed = false
                failureCode = .receiptFailed
                failureDetail = "远端安装与运行验证已通过，但无法提交本机服务器记录：\(reason)"
                postInstallWarning = reason
                failureCount += 1
            }
        case .failed(let failure):
            state = failure.state
            phase = .failed
            isFailureAlertDismissed = false
            failureCode = failure.code
            let meta = failureMeta(failure)
            if let source = outcome.releaseSource,
               source.isFallback,
               let reason = source.fallbackReason {
                let suffix = "本次已回退内置版本 \(outcome.releaseVersion)：\(reason)。"
                failureDetail = [meta, suffix].compactMap { $0 }.joined(separator: "\n")
                releaseNotice = reason
            } else {
                failureDetail = meta
            }
            failureCount += 1
        case .unsupported(let reason):
            phase = .failed
            isFailureAlertDismissed = false
            failureCode = reason.code
            failureDetail = reason.message
            failureCount += 1
        }
    }

    func completeDirectWithSSHOnly(
        host: HostRecord,
        model: AppModel,
        connection: ConnectionModel
    ) async {
        guard let directAttemptId else { return }
        await connection.completeInstallSSHOnly(hostID: host.id, attemptId: directAttemptId)
        phase = .success
        activity = "已明确选择仅使用 SSH；配对与 hostId 保持有效，Direct 错误仍保留供诊断。"
        postInstallWarning = directError
        self.directAttemptId = nil
        connectAfterInstall(host: host, model: model, connection: connection)
    }

    func retryDirectOnly(
        host: HostRecord,
        model: AppModel,
        connection: ConnectionModel
    ) async {
        guard let directAttemptId else { return }
        phase = .running
        activity = "仅重试 Direct 首验，不重新安装或配对；SSH 保持到结果明确。"
        guard let outcome = await connection.retryBootstrapDirect(
            record: host,
            attemptId: directAttemptId
        ) else {
            phase = .directFailed
            directError = "当前没有可重试的 Direct 首验上下文"
            activity = "仅重试 Direct 首验，不重新配对。"
            return
        }
        directError = outcome.directError
        if outcome.directVerified {
            phase = .success
            postInstallWarning = nil
            activity = "Direct 首验成功，未重新执行安装或配对。"
            self.directAttemptId = nil
            connectAfterInstall(host: host, model: model, connection: connection)
        } else {
            phase = .directFailed
            self.directAttemptId = outcome.attemptId
            postInstallWarning = outcome.directError
            activity = "Direct 首验仍失败；可仅使用 SSH，或仅重试 Direct，不会重新配对。"
        }
    }

    /// 安装流程的收尾验证用的是临时连接，验证通过后会关掉；不在这里补一次
    /// 连接，App 会停在「已配对 · 未连接」，用户还得手动去设置页点「连接」。
    ///
    /// 只对「本来就是当前服务器」或「还没有当前服务器」的情况自动连：给另一台
    /// 服务器装 PI-adaptor 时不能悄悄切走用户正在用的连接。
    private func connectAfterInstall(
        host: HostRecord,
        model: AppModel,
        connection: ConnectionModel
    ) {
        let isCurrent = model.currentHost?.id == host.id
        guard isCurrent || model.currentHost == nil else { return }
        guard !(isCurrent && connection.state.isOnline) else { return }
        Task { await model.setCurrentHost(id: host.id) }
    }

    private func failureMeta(_ failure: BootstrapRunFailure) -> String? {
        var details: [String] = []
        if failure.callbackFailure == .pairing {
            details.append("客户端配对回调失败；令牌已失效时请重试以重新启动 --pair。")
        } else if failure.callbackFailure == .verification {
            details.append("运行身份或版本验证失败；安装器不会把旧 PI-adaptor 或错误版本当作成功。")
        }
        if let detail = failure.detail, !detail.isEmpty {
            details.append(detail)
        }
        if let raw = failure.state.failureCodeRaw, raw != failure.code.rawValue {
            details.append("服务器原始失败码：\(raw)")
        }
        if let structured = failure.state.failureDetails?.displayText, !structured.isEmpty {
            details.append(structured)
        }
        if let artifact = failure.state.artifact?.name {
            details.append("产物：\(artifact)")
        }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    func loadLog(
        model: AppModel,
        connection: ConnectionModel,
        hostID: UUID
    ) async {
        guard !isLoadingLog else { return }
        guard let host = model.hosts.first(where: { $0.id == hostID }) else {
            logError = "服务器记录已不存在。"
            return
        }
        isLoadingLog = true
        logError = nil
        defer { isLoadingLog = false }
        do {
            logText = try await connection.hostInstallLog(record: host)
        } catch {
            logError = ConnectionErrorText.describe(error)
        }
    }

    func value(for step: BootstrapStep) -> String {
        guard let current = state else { return "等待" }
        if current.status == .failed, current.step == step { return "失败" }
        if current.status == .ok, step == .done { return "完成" }
        guard let currentOrder = current.step.order, let order = step.order else {
            return current.step == step ? "进行中" : "等待"
        }
        if order < currentOrder { return "完成" }
        if order == currentOrder { return phase == .success ? "完成" : "进行中" }
        return "等待"
    }

    func byteSummary(state: BootstrapStateFile) -> String {
        let downloaded = state.artifact?.downloadedBytes ?? 0
        let total = state.artifact?.bytes ?? 0
        if total > 0 {
            return "\(Self.bytes(downloaded)) / \(Self.bytes(total))"
        }
        if downloaded > 0 {
            return "已下载 \(Self.bytes(downloaded))"
        }
        return state.step == .download ? "正在建立下载" : "尚无下载数据"
    }

    private func stepTitle(_ step: BootstrapStep) -> String {
        InstallStepDescriptor.all.first(where: { $0.step == step })?.title ?? step.rawValue
    }

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }
}

private struct InstallStepDescriptor: Identifiable {
    let step: BootstrapStep
    let title: String
    let detail: String

    var id: String { step.rawValue }

    static let all: [InstallStepDescriptor] = [
        .init(step: .probe, title: "探测", detail: "读取 uname -s / uname -m 并选择架构"),
        .init(step: .resolve, title: "解析 Release", detail: "下载并核对冻结 manifest 的完整 sha256"),
        .init(step: .download, title: "下载", detail: "断点续传到 owner-only .part 文件"),
        .init(step: .verify, title: "校验", detail: "sha256 不匹配则不切换 current"),
        .init(step: .extract, title: "解包", detail: "解包到隔离暂存目录并检查结构"),
        .init(step: .activate, title: "激活版本", detail: "校验 package 版本与 SHA256SUMS 后原子切换 current"),
        .init(step: .writeUnit, title: "写入 unit", detail: "写入 pi-adaptor.service 并 enable-linger"),
        .init(step: .startPair, title: "启动配对进程", detail: "停止 unit，单独启动一次 --pair"),
        .init(step: .pair, title: "交换设备令牌", detail: "同一 SSH 连接完成 connection/pair"),
        .init(step: .stopManual, title: "停止手动进程", detail: "确认 --pair 进程已退出"),
        .init(step: .startUnit, title: "启动常驻服务", detail: "启动 pi-adaptor.service"),
        .init(step: .verifyDevice, title: "验证运行版本", detail: "检查 server.name、server.version 并重新 ping"),
        .init(step: .done, title: "完成", detail: "PI-adaptor 身份、版本与服务状态均匹配"),
    ]
}
