import SwiftUI
import PIiOSNet

/// Direct RACP 的纯展示与输入区域。
///
/// 视图不读取 Keychain、不创建连接，也不把 preference 或 pin 解释成在线。
/// `ConnectionStatus` 是 route/phase 的唯一事实来源；授权、模式切换与重试均由
/// 调用方通过回调执行。endpoint 使用 Binding，便于父表单保留自己的校验与保存节奏。
struct DirectConnectionSection: View {
    @Binding private var endpoint: String

    private let preference: ConnectionPreference
    private let status: ConnectionStatus
    private let adaptorHostId: String?
    private let trustPin: DirectTLSTrustPin?
    private let isTrustAuthorized: Bool
    private let endpointError: String?
    private let isBusy: Bool
    private let canAuthorize: Bool
    private let authorizationDisabledReason: String?
    private let canRetryDirect: Bool
    private let retryDisabledReason: String?
    private let onPreferenceChange: (ConnectionPreference) -> Void
    private let onAuthorize: () -> Void
    private let onRetryDirect: () -> Void

    init(
        endpoint: Binding<String>,
        preference: ConnectionPreference,
        status: ConnectionStatus,
        adaptorHostId: String? = nil,
        trustPin: DirectTLSTrustPin? = nil,
        isTrustAuthorized: Bool = false,
        endpointError: String? = nil,
        isBusy: Bool = false,
        canAuthorize: Bool = true,
        authorizationDisabledReason: String? = nil,
        canRetryDirect: Bool = false,
        retryDisabledReason: String? = nil,
        onPreferenceChange: @escaping (ConnectionPreference) -> Void,
        onAuthorize: @escaping () -> Void,
        onRetryDirect: @escaping () -> Void
    ) {
        _endpoint = endpoint
        self.preference = preference
        self.status = status
        self.adaptorHostId = adaptorHostId
        self.trustPin = trustPin
        self.isTrustAuthorized = isTrustAuthorized
        self.endpointError = endpointError
        self.isBusy = isBusy
        self.canAuthorize = canAuthorize
        self.authorizationDisabledReason = authorizationDisabledReason
        self.canRetryDirect = canRetryDirect
        self.retryDisabledReason = retryDisabledReason
        self.onPreferenceChange = onPreferenceChange
        self.onAuthorize = onAuthorize
        self.onRetryDirect = onRetryDirect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s24) {
            statusBanner
            configurationGroup
            routeGroup
            trustGroup
            if preference == .directPreferred {
                retryGroup
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 配置

    private var configurationGroup: some View {
        PIGroup("直连") {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                PIFormField(
                    label: "直连地址",
                    error: endpointError
                ) {
                    TextField("wss://host:9443/v1/racp/ws", text: $endpoint)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("directConnection.endpoint")
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
            .disabled(isBusy)

            PIRowDivider()

            VStack(alignment: .leading, spacing: PISpacing.s8) {
                Text("连接模式")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                Picker(
                    "连接模式",
                    selection: Binding(
                        get: { preference },
                        set: onPreferenceChange
                    )
                ) {
                    Text("仅 SSH").tag(ConnectionPreference.sshOnly)
                    Text("直连优先").tag(ConnectionPreference.directPreferred)
                }
                .pickerStyle(.segmented)
                .disabled(isBusy)
                .accessibilityIdentifier("directConnection.preference")
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    // MARK: - 通路与阶段

    @ViewBuilder
    private var statusBanner: some View {
        switch status.phase {
        case .online(let route):
            PIStatusBanner(kind: .success, text: "在线 · \(routeTitle(route))")
        case .failed:
            PIStatusBanner(kind: .danger, text: "连接失败")
        case .fallingBack:
            PIStatusBanner(kind: .warning, text: "正在回退到 SSH")
        case .offline:
            PIStatusBanner(
                kind: hasRouteFailures ? .warning : .info,
                text: hasRouteFailures ? "当前离线" : "尚未连接"
            )
        default:
            PIStatusBanner(
                kind: .info,
                text: isBusy ? "正在处理连接操作" : "连接正在推进",
                detail: phaseTitle(status.phase)
            )
        }
    }

    private var routeGroup: some View {
        PIGroup("通路") {
            PIListRow(
                title: "当前通路",
                value: status.activeRoute.map(routeTitle) ?? "无",
                icon: "point.3.connected.trianglepath.dotted",
                iconTint: status.activeRoute == nil ? PIColor.text3 : PIColor.text2,
                isEnabled: false,
                showsDivider: true
            )
            .accessibilityIdentifier("directConnection.activeRoute")

            PIListRow(
                title: "阶段",
                subtitle: phaseTitle(status.phase),
                icon: "dot.radiowaves.left.and.right",
                iconTint: phaseTint,
                isEnabled: false,
                showsDivider: status.promotionFenced || hasRouteFailures
            )
            .accessibilityIdentifier("directConnection.phase")

            if status.promotionFenced {
                PIListRow(
                    title: "切换保护",
                    value: "进行中",
                    icon: "lock.shield",
                    iconTint: PIColor.warning,
                    isEnabled: false,
                    showsDivider: hasRouteFailures
                )
                .accessibilityIdentifier("directConnection.promotionFence")
            }

            if let failure = status.directFailure {
                PIListRow(
                    title: "Direct 失败",
                    subtitle: failureText(failure),
                    icon: "bolt",
                    iconTint: PIColor.danger,
                    isEnabled: false,
                    showsDivider: status.sshFailure != nil
                )
                .accessibilityIdentifier("directConnection.directFailure")
            }

            if let failure = status.sshFailure {
                PIListRow(
                    title: "SSH 失败",
                    subtitle: failureText(failure),
                    icon: "lock.shield",
                    iconTint: PIColor.danger,
                    isEnabled: false,
                    showsDivider: false
                )
                .accessibilityIdentifier("directConnection.sshFailure")
            }
        }
    }

    private var phaseTint: Color {
        switch status.phase {
        case .online:
            return PIColor.success
        case .failed:
            return PIColor.danger
        case .offline:
            return hasRouteFailures ? PIColor.warning : PIColor.text3
        default:
            return PIColor.text2
        }
    }

    private var hasRouteFailures: Bool {
        status.directFailure != nil || status.sshFailure != nil
    }

    /// R6：失败只写「发生了什么 + 下一步」，不写阶段枚举与稳定错误码。
    private func failureText(_ failure: RouteFailure) -> String {
        var text = failureCategoryTitle(failure.category)
        if let retryAfterMs = failure.retryAfterMs {
            let seconds = Double(retryAfterMs) / 1000
            text += " · \(seconds.formatted(.number.precision(.fractionLength(0...1)))) 秒后重试"
        }
        return text
    }

    private func routeTitle(_ route: ConnectionRoute) -> String {
        switch route {
        case .direct: return "Direct"
        case .ssh: return "SSH"
        }
    }

    private func phaseTitle(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .offline:
            return "离线"
        case .connecting(let route):
            return "正在建立 \(routeTitle(route)) 连接"
        case .handshaking(let route):
            return "\(routeTitle(route)) 握手"
        case .authenticating(let route):
            return "\(routeTitle(route)) 认证"
        case .verifyingIdentity(let route):
            return "\(routeTitle(route)) 核对身份"
        case .restoring(let route):
            return "\(routeTitle(route)) 恢复会话"
        case .fallingBack:
            return "Direct 失败，回退到 SSH"
        case .online(let route):
            return "在线 · \(routeTitle(route))"
        case .reconnecting(let route, let attempt, let delay):
            let delayText = delay.formatted(.number.precision(.fractionLength(0...1)))
            return "\(routeTitle(route)) 第 \(attempt) 次重连 · 等待 \(delayText) 秒"
        case .failed:
            return "连接失败"
        }
    }

    private func failureCategoryTitle(_ category: ConnectionFailureCategory) -> String {
        switch category {
        case .configuration: return "本机配置不完整"
        case .offline: return "本机无网络"
        case .dns: return "服务器地址解析失败"
        case .tcp: return "TCP 连接失败"
        case .connectTimeout: return "连接超时"
        case .socketInterrupted: return "连接被中断"
        case .heartbeatFailed: return "心跳连续失败"
        case .tlsTrust: return "证书校验失败"
        case .authentication: return "设备认证失败"
        case .deviceRevoked: return "设备已撤销"
        case .hostKey: return "SSH 主机密钥校验失败"
        case .hostIdentity: return "服务器身份不一致"
        case .protocol: return "版本不匹配"
        case .endpoint: return "地址格式不对"
        case .permission: return "权限不足"
        case .validation: return "请求被拒绝"
        case .notFound: return "资源不存在"
        case .conflict: return "请求冲突"
        case .rateLimited: return "请求太频繁"
        case .providerUpstream: return "Provider 上游失败"
        case .business: return "业务请求失败"
        case .internal: return "服务器内部错误"
        case .canceled: return "操作已取消"
        }
    }

    // MARK: - 证书与身份

    private var trustGroup: some View {
        PIGroup("证书") {
            PIListRow(
                title: trustState.title,
                icon: trustState.icon,
                iconTint: trustState.tint,
                isEnabled: false,
                showsDivider: true
            )
            .accessibilityIdentifier("directConnection.trustState")

            VStack(alignment: .leading, spacing: PISpacing.s16) {
                trustValue(
                    title: "证书 SHA-256",
                    value: trustPin?.certificateSHA256,
                    emptyText: "尚未取得证书 pin",
                    identifier: "directConnection.certificateSHA256"
                )
                trustValue(
                    title: hasHostIdentityMismatch ? "候选 hostId" : "adaptor hostId",
                    value: trustPin?.hostId ?? adaptorHostId,
                    emptyText: "尚未取得 hostId",
                    identifier: "directConnection.hostId"
                )
                if hasHostIdentityMismatch, let adaptorHostId {
                    trustValue(
                        title: "已记录的 hostId",
                        value: adaptorHostId,
                        emptyText: "无",
                        identifier: "directConnection.recordedHostId"
                    )
                }
                if isTrustAuthorized, !hasHostIdentityMismatch, let authorizedAt = trustPin?.authorizedAt {
                    Text("授权时间 \(authorizedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)

            PIRowDivider()

            VStack(alignment: .leading, spacing: PISpacing.s8) {
                PISecondaryButton(
                    title: authorizationButtonTitle,
                    isEnabled: canPerformAuthorization
                ) {
                    onAuthorize()
                }
                .accessibilityIdentifier("directConnection.authorize")
                if !canPerformAuthorization {
                    Text(authorizationBlockedReason)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isBusy {
                    HStack(spacing: PISpacing.s8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PIColor.text2)
                        Text("正在等待调用方完成操作…")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var hasHostIdentityMismatch: Bool {
        guard let candidate = trustPin?.hostId, let recorded = adaptorHostId else { return false }
        return candidate != recorded
    }

    private var canPerformAuthorization: Bool {
        // Identity mismatch blocks direct retry, not the trusted-SSH repair path.
        canAuthorize && !isBusy
    }

    private var authorizationButtonTitle: String {
        if hasHostIdentityMismatch {
            return "重新核对并授权"
        }
        return isTrustAuthorized && trustPin != nil ? "重新授权" : "经 SSH 授权"
    }

    /// 不能授权时只给下一步，不解释实现（R6）。
    private var authorizationBlockedReason: String {
        if hasHostIdentityMismatch {
            return "先经可信 SSH 重新核对身份"
        }
        if isBusy {
            return "另一项操作进行中"
        }
        return authorizationDisabledReason ?? "先完成 SSH 配对"
    }

    private var trustState: (title: String, icon: String, tint: Color) {
        if hasHostIdentityMismatch {
            return ("hostId 不一致", "exclamationmark.octagon", PIColor.danger)
        }
        if isTrustAuthorized, trustPin != nil {
            return ("已授权", "checkmark.shield", PIColor.success)
        }
        if trustPin != nil {
            return ("待你授权", "person.badge.key", PIColor.warning)
        }
        if isTrustAuthorized {
            return ("缺少证书 pin", "exclamationmark.triangle", PIColor.danger)
        }
        return ("未取得证书", "shield", PIColor.text3)
    }

    private func trustValue(
        title: String,
        value: String?,
        emptyText: String,
        identifier: String
    ) -> some View {
        let visibleValue = value.flatMap { $0.isEmpty ? nil : $0 }
        return VStack(alignment: .leading, spacing: PISpacing.s4) {
            Text(title)
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text2)
            Text(visibleValue ?? emptyText)
                .font(PIFont.codeMono)
                .foregroundStyle(visibleValue == nil ? PIColor.text3 : PIColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 手动重试

    private var retryGroup: some View {
        PIGroup("重试") {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                PIPrimaryButton(
                    title: "重试直连",
                    isEnabled: canPerformDirectRetry,
                    identifier: "directConnection.retry"
                ) {
                    onRetryDirect()
                }
                if !canPerformDirectRetry {
                    Text(retryBlockedReason)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var canPerformDirectRetry: Bool {
        canRetryDirect && !isBusy && !hasHostIdentityMismatch
    }

    private var retryBlockedReason: String {
        if hasHostIdentityMismatch {
            return "先重新核对身份再重试"
        }
        if isBusy {
            return "另一项操作进行中"
        }
        return retryDisabledReason ?? "SSH 在线且证书已验证时可重试"
    }
}

#if DEBUG
// MARK: - Demo data and previews

/// Preview-only interaction recorder. It never performs I/O and never advances
/// route/phase, so tapping a preview action cannot manufacture an online state.
private struct DirectConnectionSectionDemo: View {
    let status: ConnectionStatus
    let trustPin: DirectTLSTrustPin?
    let adaptorHostId: String?
    let isTrustAuthorized: Bool
    let canRetryDirect: Bool
    let endpointError: String?

    @State private var endpoint: String
    @State private var preference: ConnectionPreference
    @State private var lastAction = "尚未触发回调"

    init(
        endpoint: String,
        preference: ConnectionPreference,
        status: ConnectionStatus,
        trustPin: DirectTLSTrustPin?,
        adaptorHostId: String? = nil,
        isTrustAuthorized: Bool,
        canRetryDirect: Bool = false,
        endpointError: String? = nil
    ) {
        _endpoint = State(initialValue: endpoint)
        _preference = State(initialValue: preference)
        self.status = status
        self.trustPin = trustPin
        self.adaptorHostId = adaptorHostId
        self.isTrustAuthorized = isTrustAuthorized
        self.canRetryDirect = canRetryDirect
        self.endpointError = endpointError
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                PIStatusBanner(
                    kind: .info,
                    text: "Demo data · 非实时状态",
                    detail: "预览未发起网络连接；按钮只记录回调，不修改 ConnectionStatus。"
                )
                DirectConnectionSection(
                    endpoint: $endpoint,
                    preference: preference,
                    status: status,
                    adaptorHostId: adaptorHostId ?? trustPin?.hostId,
                    trustPin: trustPin,
                    isTrustAuthorized: isTrustAuthorized,
                    endpointError: endpointError,
                    canRetryDirect: canRetryDirect,
                    onPreferenceChange: { next in
                        preference = next
                        lastAction = "模式回调：\(next.rawValue)（仅 demo UI state）"
                    },
                    onAuthorize: {
                        lastAction = "授权回调已记录；未修改 pin、hostId 或在线状态"
                    },
                    onRetryDirect: {
                        lastAction = "重试回调已记录；未修改 route、phase 或在线状态"
                    }
                )
                Text("最近动作：\(lastAction)")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("directConnection.demo.lastAction")
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .scrollDismissesKeyboard(.immediately)
        .piPageBackground()
    }
}

private enum DirectConnectionDemoData {
    static let endpoint = "wss://100.64.0.10:9443/v1/racp/ws"
    static let hostId = "7F2D87F8-0F78-4E6C-A06F-60A2C529C8B4"
    static let pin = DirectTLSTrustPin(
        hostId: hostId,
        certificateSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        authorizedAt: Date(timeIntervalSince1970: 1_762_300_000)
    )
}

#Preview("待授权 · Light") {
    DirectConnectionSectionDemo(
        endpoint: DirectConnectionDemoData.endpoint,
        preference: .sshOnly,
        status: ConnectionStatus(),
        trustPin: DirectConnectionDemoData.pin,
        isTrustAuthorized: false
    )
    .preferredColorScheme(.light)
}

#Preview("SSH 回退 · Dark") {
    DirectConnectionSectionDemo(
        endpoint: DirectConnectionDemoData.endpoint,
        preference: .directPreferred,
        status: ConnectionStatus(
            phase: .online(.ssh),
            activeRoute: .ssh,
            activeGeneration: UUID(),
            directFailure: RouteFailure(
                route: .direct,
                phase: .connecting(.direct),
                category: .connectTimeout
            )
        ),
        trustPin: DirectConnectionDemoData.pin,
        isTrustAuthorized: true,
        canRetryDirect: true
    )
    .preferredColorScheme(.dark)
}

#Preview("双通路失败") {
    DirectConnectionSectionDemo(
        endpoint: "https://wrong.example/v1/racp/ws",
        preference: .directPreferred,
        status: ConnectionStatus(
            phase: .failed,
            directFailure: RouteFailure(
                route: .direct,
                phase: .connecting(.direct),
                category: .connectTimeout
            ),
            sshFailure: RouteFailure(
                route: .ssh,
                phase: .authenticating(.ssh),
                category: .authentication
            )
        ),
        trustPin: DirectConnectionDemoData.pin,
        isTrustAuthorized: true,
        canRetryDirect: false,
        endpointError: "直连地址必须使用 wss，且路径固定为 /v1/racp/ws"
    )
    .preferredColorScheme(.light)
}
#endif
