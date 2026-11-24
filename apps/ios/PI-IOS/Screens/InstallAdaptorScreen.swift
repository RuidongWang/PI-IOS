import SwiftUI
import PIiOSCore
import PIiOSNet

/// S-06 安装 PI-adaptor。
///
/// 一个主任务：装好。页面只展示真实步骤与下载进度，不伪造进度。
/// 文案口径见 `apps/ios/design/quiet-v2.md`：不要 footer、不要解释实现。
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

    /// 本机 App 版本（发布门禁要求它等于内置 PI-adaptor 版本）。
    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 构建版本与内置回退发布漂移时的提示（DEF：手机端不能静默装回旧版本）。
    private var bundleVersionWarning: String? {
        BootstrapBundleVersionPolicy.fallbackWarning(
            appVersion: appVersion,
            bundledReleaseVersion: PIAdaptorRelease.patchedReleaseVersion
        )
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
            return "直连地址需是完整的 wss URL（路径 /v1/racp/ws）。"
        }
        if directConfiguration == nil {
            return "直连主机填 DNS 或 IP；直连端口需与本地端口不同。"
        }
        return nil
    }

    /// U09/U15: freeze the whole install request at click time. Every retry —
    /// including the sudo re-authorization entry — reuses exactly these values;
    /// authorization inputs (sudo password, direct trust callback) stay separate.
    private func installRequest(host: HostRecord, force: Bool) -> InstallRequest? {
        guard let port = Int(portText.piTrimmed) else { return nil }
        return InstallRequest(
            target: model.installTargetSnapshot(for: host),
            record: host,
            adaptorPort: port,
            releaseVersion: nil,
            force: force,
            direct: directConfiguration,
            directEndpoint: canonicalDirectEndpoint,
            authorizeDirectPin: false
        )
    }

    private var canStart: Bool {
        host != nil && portError == nil && directConfigurationError == nil && !coordinator.isRunning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                if let host {
                    targetSection(host)
                    bundleVersionWarningCard
                    receiptSection(host)
                    configurationSection
                    statusBanners
                    if coordinator.state != nil {
                        progressSection
                    }
                    failureSection
                    actions
                } else {
                    missingHostSection
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("安装 PI-adaptor")
        .onAppear(perform: seedPort)
        .onDisappear { coordinator.leavePage(hostID: hostID, connection: connection) }
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
                            Text("SHA-256")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                            Text(wrappedFingerprint(trust.certificateSHA256))
                                .font(PIFont.codeMono)
                                .textSelection(.enabled)
                                .accessibilityLabel(trust.certificateSHA256)
                                .accessibilityIdentifier("installHost.directTrustPin")
                            Text("hostId")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
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
                    .navigationTitle("确认直连证书")
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
                text: "正在安装",
                detail: coordinator.activity
            )
            if let notice = coordinator.releaseNotice {
                PIStatusBanner(
                    kind: .warning,
                    text: "已使用内置版本",
                    detail: notice
                )
                .accessibilityIdentifier("installHost.fallbackNotice")
            }
        case .stalled:
            PIStatusBanner(
                kind: .warning,
                text: "安装暂时没有进展",
                detail: coordinator.stallMessage ?? "可以重试。"
            )
        case .success:
            PIStatusBanner(
                kind: coordinator.postInstallWarning == nil ? .success : .warning,
                text: coordinator.postInstallWarning == nil ? "安装完成" : "安装完成，有提示",
                detail: coordinator.activity
            )
            if let directError = coordinator.directError {
                PIInlineMessage(kind: .warning, text: directError)
                    .accessibilityIdentifier("installHost.directError")
            }
            if let notice = coordinator.releaseNotice {
                PIStatusBanner(
                    kind: .warning,
                    text: "本次使用内置版本",
                    detail: notice
                )
                .accessibilityIdentifier("installHost.fallbackNotice")
            }
        case .directFailed:
            PIStatusBanner(
                kind: .warning,
                text: "已配对，直连未通过",
                detail: coordinator.directError
            )
            .accessibilityIdentifier("installHost.directError")
            if !coordinator.activity.isEmpty {
                Text(coordinator.activity)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("installHost.directRetryActivity")
            }
        case .failed:
            PIInlineMessage(kind: .danger, text: "安装未完成，原因见下方。")
        case .idle:
            EmptyView()
        }
    }

    /// 目标服务器：名字 + 地址/状态，副标题只放状态数据。
    private func targetSection(_ host: HostRecord) -> some View {
        PIGroup("目标服务器") {
            PIListRow(
                title: host.name,
                subtitle: "\(host.address) · \(host.statusText)",
                showsDivider: false
            )
            .accessibilityIdentifier("installHost.target")
        }
    }

    /// App 版本与内置 PI-adaptor 回退版本不一致：必须显式提示，避免静默装旧版本。
    @ViewBuilder
    private var bundleVersionWarningCard: some View {
        if let warning = bundleVersionWarning {
            PIStatusBanner(kind: .warning, text: "App 与内置版本不一致", detail: warning)
                .accessibilityIdentifier("installHost.bundleVersionWarning")
        }
    }

    /// 上次安装：版本、端口、来源与时间都是状态数据，一行说清。
    @ViewBuilder
    private func receiptSection(_ host: HostRecord) -> some View {
        if let receipt = host.installReceipt {
            let meta = [
                receiptSourceName(receipt),
                "端口 \(receipt.hostPort)",
                receipt.completedAt.formatted(date: .abbreviated, time: .shortened),
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            PIGroup("上次安装") {
                PIListRow(title: "v\(receipt.version)", subtitle: meta, showsDivider: false)
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

    private func receiptSourceName(_ receipt: AdaptorInstallReceipt) -> String {
        switch receipt.releaseSource {
        case .latest:
            return "GitHub 最新兼容发布"
        case .fallback:
            return "内置版本"
        case nil:
            return ""
        }
    }

    private var configurationSection: some View {
        PIGroup("安装参数") {
            PIFormRow {
                PIFormField(
                    label: "端口",
                    error: portError
                ) {
                    TextField("44271", text: $portText)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($portFocused)
                        .accessibilityIdentifier("installHost.port")
                }
            }
            PIFormRow {
                PIFormField(
                    label: "直连地址",
                    error: directConfigurationError
                ) {
                    TextField("wss://host:9443/v1/racp/ws", text: $directEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("installHost.directEndpoint")
                }
            }
            PIFormRow {
                PIFormField(label: "直连主机") {
                    TextField("host.example 或 100.64.0.10", text: $directName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("installHost.directName")
                }
            }
            PIFormRow(showsDivider: coordinator.resolvedRelease != nil) {
                PIFormField(label: "直连端口") {
                    TextField("9443", text: $directPortText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("installHost.directPort")
                }
            }
            if let resolution = coordinator.resolvedRelease {
                PIFormRow(showsDivider: false) {
                    Text("PI-adaptor \(resolution.release.version) · \(resolution.source.displayName)")
                        .font(PIFont.metaMono)
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("installHost.resolvedRelease")
                }
            }
        }
    }

    /// 进度：下载数据 + 步骤状态。步骤是真状态，只留名字与状态，不再解释实现。
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            PISectionHeader(text: "进度")
            if let state = coordinator.state {
                downloadCard(state)
                PIGroup {
                    ForEach(Array(InstallStepDescriptor.all.enumerated()), id: \.element.id) { index, step in
                        let state = coordinator.value(for: step.step)
                        PIListRow(
                            title: step.title,
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
                        text: "安装状态异常",
                        detail: coordinator.transitionNotes.joined(separator: "\n")
                    )
                }
            }
        }
    }

    private func downloadCard(_ state: BootstrapStateFile) -> some View {
        PICard {
            PICardLabel(text: "下载")
            let downloaded = state.artifact?.downloadedBytes ?? 0
            let total = state.artifact?.bytes ?? 0
            Text(coordinator.byteSummary(state: state))
                .font(PIFont.listTitle)
                .monospacedDigit()
                .foregroundStyle(PIColor.text)
            if total > 0 {
                ProgressView(value: Double(min(downloaded, total)), total: Double(total))
                    .tint(PIColor.text2)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(Int(Double(min(downloaded, total)) / Double(total) * 100))%")
            } else if coordinator.isRunning && state.step == .download {
                ProgressView()
                    .tint(PIColor.text2)
                    .accessibilityLabel("正在下载")
            }
        }
    }

    /// 失败：先说发生了什么，再说下一步；机器码退到等宽小字，供核对或报障。
    @ViewBuilder
    private var failureSection: some View {
        if coordinator.phase == .failed {
            PICard {
                PICardLabel(text: "失败")
                if let code = coordinator.failureCode {
                    Text(code.displayMessage)
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(code.rawValue)
                        .font(PIFont.metaMono)
                        .foregroundStyle(PIColor.text3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("installHost.failureCode")
                }
                if [.downloadFailed, .checksumMismatch].contains(coordinator.failureCode),
                   coordinator.failureCount >= 2 {
                    Text("连续失败 \(coordinator.failureCount) 次：检查服务器能否访问 GitHub。")
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
                        .piFieldChrome()
                        .textContentType(.password)
                        .disabled(coordinator.isRunning)
                        .accessibilityIdentifier("installHost.sudoCredential")
                    PISecondaryButton(
                        title: "重新授权并继续",
                        isEnabled: !sudoCredential.isEmpty && !coordinator.isRunning
                    ) {
                        coordinator.retrySudo(
                            sudoCredential: sudoCredential,
                            model: model,
                            connection: connection
                        )
                    }
                    .accessibilityIdentifier("installHost.retrySudo")
                }
            }
        }
    }

    /// 一个主操作：主按钮永远是「继续安装 / 重试」；其余都是次要按钮。
    private var actions: some View {
        VStack(spacing: PISpacing.s12) {
            Toggle("强制重装", isOn: $forceReinstall)
                .font(PIFont.body)
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
                    guard let host, let request = installRequest(
                        host: host,
                        force: forceReinstall
                    ) else { return }
                    coordinator.start(
                        request: request,
                        model: model,
                        connection: connection
                    )
                }
            }
            if coordinator.phase == .directFailed, let host {
                PISecondaryButton(title: "仅用 SSH 完成") {
                    Task {
                        await coordinator.completeDirectWithSSHOnly(
                            host: host,
                            model: model,
                            connection: connection
                        )
                    }
                }
                .accessibilityIdentifier("installHost.completeSSHOnly")
            }
            PISecondaryButton(
                title: coordinator.isLoadingLog ? "正在读取日志…" : "安装日志",
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

    private var missingHostSection: some View {
        PICard {
            PICardLabel(text: "服务器已删除")
            Text("返回服务器列表重新添加。")
                .font(PIFont.body)
                .foregroundStyle(PIColor.text2)
        }
    }

    private func stepIcon(_ state: String) -> (String, Color) {
        switch state {
        case "完成": return ("checkmark.circle", PIColor.success)
        case "进行中": return ("clock", PIColor.text2)
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
                    ProgressView("正在读取日志…")
                        .padding(PISpacing.s24)
                } else if coordinator.logError == nil {
                    Text(coordinator.logText ?? "暂无日志")
                        .font(PIFont.metaMono)
                        .foregroundStyle(PIColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(PIMetrics.pageMargin)
                }
            }
            .background(PIColor.page)
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
                        .accessibilityIdentifier("installHost.logSheet.refresh")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("installHost.logSheet.close")
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
final class InstallAdaptorCoordinator: ObservableObject {
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
    @Published private(set) var activity = ""
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
    /// U09: the immutable request the last attempt started with. The sudo
    /// re-authorization entry replays exactly this request instead of rebuilding it
    /// from a possibly edited form.
    private var lastRequest: InstallRequest?

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
            directError = "UI fixture 的直连首验失败"
            directAttemptId = "fixture-direct-failed"
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

    func requestDirectAuthorization(_ trust: BootstrapDirectTrust) async -> Bool {
        guard !Task.isCancelled else { return false }
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

    func cancel() {
        if let runTask {
            runID = UUID()
            self.runTask = nil
            phase = .idle
            runTask.cancel()
        }
        rejectPendingDirectTrust()
    }

    func leavePage(hostID: UUID, connection: ConnectionModel) {
        cancel()
        guard let directAttemptId else { return }
        self.directAttemptId = nil
        phase = .idle
        Task { await connection.discardBootstrapDirect(hostID: hostID, attemptId: directAttemptId) }
    }

    func start(
        request: InstallRequest,
        sudoCredential: String? = nil,
        model: AppModel,
        connection: ConnectionModel
    ) {
        guard !isRunning else { return }
        let host = request.record
        lastRequest = request
        let generation = UUID()
        let previousDirectAttempt = directAttemptId
        runID = generation
        phase = .running
        state = nil
        activity = "正在连接服务器。"
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
            defer {
                if self.runID == generation { self.runTask = nil }
            }
            if let previousDirectAttempt {
                await connection.completeInstallSSHOnly(
                    hostID: host.id,
                    attemptId: previousDirectAttempt
                )
            }
            do {
                try Task.checkCancellation()
                if let sudoCredential {
                    guard !sudoCredential.isEmpty else {
                        throw AdaptorInstallError.emptySudoPassword
                    }
                    self.activity = "正在获取 sudo 权限。"
                    try await connection.authorizeAdaptorInstall(
                        record: host,
                        sudoPassword: sudoCredential
                    )
                    guard self.runID == generation else { return }
                    try Task.checkCancellation()
                }
                let outcome = try await connection.installAdaptor(
                    request: request,
                    directTrustAuthorizer: { [weak self] trust in
                        guard let self,
                              request.direct != nil,
                              request.directEndpoint != nil
                        else { return false }
                        return await self.requestDirectAuthorization(trust)
                    },
                    onReleaseResolved: { resolution in
                        guard self.runID == generation else { return }
                        self.resolvedRelease = resolution
                        self.releaseNotice = resolution.fallbackReason
                        if let reason = resolution.fallbackReason {
                            self.activity = "已使用内置版本 PI-adaptor \(resolution.release.version)。"
                        } else {
                            self.activity = "正在安装 PI-adaptor \(resolution.release.version)。"
                        }
                    },
                    eventHandler: { event in
                        guard !Task.isCancelled else { return }
                        await self.receive(event)
                    }
                )
                guard self.runID == generation else { return }
                self.finish(outcome: outcome, host: host, model: model)
            } catch is CancellationError {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.isFailureAlertDismissed = false
                self.failureCount += 1
                self.failureDetail = "安装已取消。服务器上的任务可能仍在继续。"
            } catch {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.isFailureAlertDismissed = false
                self.failureCount += 1
                if let installError = error as? AdaptorInstallError {
                    switch installError {
                    case .installationSuperseded:
                        // U15 stale branch: point the user back to the original server,
                        // never invite them to retry A's install against the new record.
                        self.failureCode = nil
                        self.failureDetail = error.localizedDescription
                    case .receiptPersistenceFailed:
                        self.failureCode = .receiptFailed
                        self.failureDetail = error.localizedDescription
                    default:
                        self.failureDetail = ConnectionErrorText.describe(error)
                    }
                } else {
                    self.failureDetail = ConnectionErrorText.describe(error)
                }
            }
        }
    }

    /// U09 sudo recovery entry: the original immutable request is replayed, and a
    /// changed target identity stops the retry explicitly instead of running A's
    /// parameters against B.
    func retrySudo(
        sudoCredential: String,
        model: AppModel,
        connection: ConnectionModel
    ) {
        guard let request = lastRequest else { return }
        guard let current = model.hosts.first(where: { $0.id == request.record.id }),
              model.installTargetSnapshot(for: current).matches(request.target)
        else {
            phase = .failed
            isFailureAlertDismissed = false
            failureCode = nil
            failureDetail = "服务器信息已变化，请重新开始安装。"
            failureCount += 1
            return
        }
        start(request: request, sudoCredential: sudoCredential, model: model, connection: connection)
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
        case .transitionIssues(let issues):
            transitionNotes = issues.map(\.message)
        case .stalled(let message):
            stallMessage = message
            if phase == .running { phase = .stalled }
        case .pairingStarted:
            activity = "正在配对。"
        case .pairingCompleted:
            activity = "配对完成。"
        case .verificationStarted:
            activity = "正在验证设备。"
        case .verificationCompleted:
            activity = "设备验证通过。"
        }
    }

    private func finish(
        outcome: AdaptorInstallRunOutcome,
        host: HostRecord,
        model: AppModel
    ) {
        switch outcome.result {
        case .succeeded(let success):
            state = success.state
            // U15: the install receipt and the staged-token promotion already happened
            // in ConnectionModel's single controlled commit section. This view only
            // consumes the result — it must never write a second receipt from an old
            // snapshot.
            if outcome.requiresSSHOnlyConfirmation {
                phase = .directFailed
                directError = outcome.directError ?? "直连首验失败"
                directAttemptId = outcome.attemptId
                postInstallWarning = outcome.directError
                activity = ""
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
            activity = "\(info.serverName) \(info.serverVersion) 正在运行。"
            if let source = outcome.releaseSource, source.isFallback {
                releaseNotice = source.fallbackReason
            }
            postInstallWarning = nil
            failureCode = nil
            failureDetail = nil
            failureCount = 0
            connectAfterInstall(host: host, model: model)
        case .failed(let failure):
            state = failure.state
            phase = .failed
            isFailureAlertDismissed = false
            failureCode = failure.code
            let meta = failureMeta(failure)
            if let source = outcome.releaseSource,
               source.isFallback,
               let reason = source.fallbackReason {
                let suffix = "本次选择的内置版本为 \(outcome.releaseVersion)。"
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
        guard self.directAttemptId == directAttemptId else { return }
        phase = .success
        activity = "已明确选择仅使用 SSH。"
        postInstallWarning = directError
        self.directAttemptId = nil
        connectAfterInstall(host: host, model: model)
    }

    func retryDirectOnly(
        host: HostRecord,
        model: AppModel,
        connection: ConnectionModel
    ) async {
        guard let directAttemptId else { return }
        phase = .running
        activity = "仅重试 Direct 首验，不重新配对。"
        let result = await connection.retryBootstrapDirect(
            record: host,
            attemptId: directAttemptId
        )
        guard self.directAttemptId == directAttemptId else { return }
        guard let outcome = result else {
            phase = .directFailed
            directError = "没有可重试的直连首验，重新开始安装。"
            activity = "仅重试 Direct 首验，不重新配对。"
            return
        }
        directError = outcome.directError
        if outcome.directVerified {
            phase = .success
            postInstallWarning = nil
            activity = "直连首验通过。"
            self.directAttemptId = nil
            connectAfterInstall(host: host, model: model)
        } else {
            phase = .directFailed
            self.directAttemptId = outcome.attemptId
            postInstallWarning = outcome.directError
            activity = ""
        }
    }

    /// 安装流程的收尾验证用的是临时连接，验证通过后会关掉；不在这里补一次
    /// 连接，App 会停在「已配对 · 未连接」，用户还得手动去设置页点「连接」。
    ///
    /// 只对「本来就是当前服务器」或「还没有当前服务器」的情况自动连：给另一台
    /// 服务器装 PI-adaptor 时不能悄悄切走用户正在用的连接。
    private func connectAfterInstall(host: HostRecord, model: AppModel) {
        guard model.currentHost?.id == host.id || model.currentHost == nil else { return }
        Task { await model.setCurrentHost(id: host.id) }
    }

    private func failureMeta(_ failure: BootstrapRunFailure) -> String? {
        if failure.code == .downgradeBlocked,
           let details = failure.state.failureDetails,
           let current = details.actualVersion, let target = details.expectedVersion {
            return "服务器当前为 PI-adaptor \(current)，本次目标为 \(target)。为避免降级，已停止安装。"
        }
        var details: [String] = []
        if failure.callbackFailure == .pairing {
            details.append("配对失败。重试即可。")
        } else if failure.callbackFailure == .verification {
            details.append("运行版本验证失败，重试安装。")
        }
        if let detail = failure.detail, !detail.isEmpty {
            details.append(detail)
        }
        if let raw = failure.state.failureCodeRaw, raw != failure.code.rawValue {
            details.append("失败码：\(raw)")
        }
        if let structured = failure.state.failureDetails?.displayText, !structured.isEmpty {
            details.append(structured)
        }
        if let artifact = failure.state.artifact?.name {
            details.append("安装包：\(artifact)")
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

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }
}

private struct InstallStepDescriptor: Identifiable {
    let step: BootstrapStep
    let title: String

    var id: String { step.rawValue }

    /// 步骤是真正的状态：只留名词标题，实现细节（路径、参数、协议）不进界面。
    static let all: [InstallStepDescriptor] = [
        .init(step: .probe, title: "探测"),
        .init(step: .resolve, title: "解析发布"),
        .init(step: .download, title: "下载"),
        .init(step: .verify, title: "校验"),
        .init(step: .extract, title: "解包"),
        .init(step: .activate, title: "激活版本"),
        .init(step: .writeUnit, title: "写入服务"),
        .init(step: .startPair, title: "启动配对"),
        .init(step: .pair, title: "交换令牌"),
        .init(step: .stopManual, title: "停止配对"),
        .init(step: .startUnit, title: "启动服务"),
        .init(step: .verifyDevice, title: "验证版本"),
        .init(step: .done, title: "完成"),
    ]
}
