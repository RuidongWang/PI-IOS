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

    // MARK: - Configuration

    private var configurationGroup: some View {
        PIGroup(
            "Direct / 直连",
            footer: "地址只来自手工输入；保存地址不会自动启用直连。切换仅 SSH 不删除配对或证书 pin。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                PIFormField(
                    label: "WSS ENDPOINT",
                    hint: "精确路径 /v1/racp/ws；不允许账号、query、fragment 或末尾斜杠。",
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
                    .font(PIFont.metaSmall)
                    .tracking(0.4)
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
                Text(preferenceDetail)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var preferenceDetail: String {
        switch preference {
        case .sshOnly:
            return "只使用 SSH 隧道，不尝试 Direct；既有配对与已授权 pin 保留。"
        case .directPreferred:
            return "每个新连接意图至多先尝试一次 Direct；只有完整认证、hostId 核对与恢复成功才发布在线。"
        }
    }

    // MARK: - Route and phase

    @ViewBuilder
    private var statusBanner: some View {
        switch status.phase {
        case .online(let route):
            PIStatusBanner(
                kind: .success,
                text: "连接已在线 · \(routeTitle(route))",
                detail: "该状态来自 ConnectionPhase.online；恢复未完成前不会在这里显示在线。"
            )
        case .failed:
            PIStatusBanner(
                kind: .danger,
                text: "连接未完成",
                detail: "下方分别保留 Direct 与 SSH 的阶段和稳定错误分类，不以最后一次错误覆盖前一条。"
            )
        case .fallingBack:
            PIStatusBanner(
                kind: .warning,
                text: "正在回退到 SSH",
                detail: phaseTitle(status.phase)
            )
        case .offline:
            if hasRouteFailures {
                PIStatusBanner(
                    kind: .warning,
                    text: "当前离线",
                    detail: "请查看两条通路各自的失败分类；界面不会据此自动信任新证书或身份。"
                )
            } else {
                PIStatusBanner(
                    kind: .info,
                    text: "尚未连接",
                    detail: "配置与证书授权不等于在线。发起连接后，这里才显示实际 route 与 phase。"
                )
            }
        default:
            PIStatusBanner(
                kind: .info,
                text: isBusy ? "正在处理连接操作" : "连接正在推进",
                detail: phaseTitle(status.phase)
            )
        }
    }

    private var routeGroup: some View {
        PIGroup("通路与阶段") {
            PIListRow(
                title: "当前活动通路",
                subtitle: status.activeRoute == nil ? "尚未发布活动通路" : "由 ConnectionStatus.activeRoute 提供",
                value: status.activeRoute.map(routeTitle) ?? "无",
                icon: "point.3.connected.trianglepath.dotted",
                iconTint: status.activeRoute == nil ? PIColor.text3 : PIColor.accent,
                isEnabled: false,
                showsDivider: true
            )
            .accessibilityIdentifier("directConnection.activeRoute")

            PIListRow(
                title: "当前阶段",
                subtitle: phaseTitle(status.phase),
                icon: "dot.radiowaves.left.and.right",
                iconTint: phaseTint,
                isEnabled: false,
                showsDivider: status.promotionFenced || hasRouteFailures
            )
            .accessibilityIdentifier("directConnection.phase")

            if status.promotionFenced {
                PIListRow(
                    title: "通路提升保护",
                    subtitle: "candidate 正在最终核对；旧 SSH 的新业务写与心跳暂时受围栏保护。",
                    value: "FENCED",
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
                    subtitle: failureDetail(failure),
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
                    subtitle: failureDetail(failure),
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
            return PIColor.accent
        }
    }

    private var hasRouteFailures: Bool {
        status.directFailure != nil || status.sshFailure != nil
    }

    private func failureDetail(_ failure: RouteFailure) -> String {
        var lines = [
            "阶段：\(phaseTitle(failure.phase))",
            "分类：\(failure.category.rawValue) · \(failureCategoryTitle(failure.category))"
        ]
        if let retryAfterMs = failure.retryAfterMs {
            lines.append("建议等待：\(retryAfterMs) ms（仅展示，不由此视图自动重试）")
        }
        return lines.joined(separator: "\n")
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
            return "\(routeTitle(route)) 协议握手"
        case .authenticating(let route):
            return "\(routeTitle(route)) 设备认证"
        case .verifyingIdentity(let route):
            return "\(routeTitle(route)) 已认证 ping 与 hostId 核对"
        case .restoring(let route):
            return "\(routeTitle(route)) 恢复 host 与当前会话"
        case .fallingBack:
            return "Direct 通路失败，正在启动一次 SSH 回退"
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
        case .dns: return "DNS 解析失败"
        case .tcp: return "TCP 连接失败"
        case .connectTimeout: return "连接或恢复超时"
        case .socketInterrupted: return "Socket 异常中断"
        case .heartbeatFailed: return "心跳连续失败"
        case .tlsTrust: return "叶证书 pin、有效期、SAN 或 hostname 校验失败"
        case .authentication: return "设备认证失败"
        case .deviceRevoked: return "设备已撤销"
        case .hostKey: return "SSH 主机密钥校验失败"
        case .hostIdentity: return "adaptor hostId 不一致或缺失"
        case .protocol: return "协议或子协议不匹配"
        case .endpoint: return "endpoint 配置错误"
        case .permission: return "权限不足"
        case .validation: return "请求校验失败"
        case .notFound: return "资源不存在"
        case .conflict: return "请求冲突"
        case .rateLimited: return "连接或消息频率受限"
        case .providerUpstream: return "Provider 上游失败"
        case .business: return "业务请求失败"
        case .internal: return "内部错误"
        case .canceled: return "操作已取消"
        }
    }

    // MARK: - Certificate and host identity

    private var trustGroup: some View {
        PIGroup(
            "证书与身份",
            footer: "指纹必须是实际单张叶证书完整 DER 的 SHA-256，不是 PEM、SPKI 或 SSH 主机指纹。只有可信 SSH 提供的候选元数据才可授权。"
        ) {
            PIListRow(
                title: trustState.title,
                subtitle: trustState.detail,
                icon: trustState.icon,
                iconTint: trustState.tint,
                isEnabled: false,
                showsDivider: true
            )
            .accessibilityIdentifier("directConnection.trustState")

            VStack(alignment: .leading, spacing: PISpacing.s16) {
                trustValue(
                    title: "完整证书 SHA-256",
                    value: trustPin?.certificateSHA256,
                    emptyText: "尚未取得证书 pin",
                    identifier: "directConnection.certificateSHA256"
                )
                trustValue(
                    title: hasHostIdentityMismatch ? "候选证书 hostId" : "adaptor hostId",
                    value: trustPin?.hostId ?? adaptorHostId,
                    emptyText: "尚未取得可信 adaptor hostId",
                    identifier: "directConnection.hostId"
                )
                if hasHostIdentityMismatch, let adaptorHostId {
                    trustValue(
                        title: "已记录的可信 adaptor hostId",
                        value: adaptorHostId,
                        emptyText: "无",
                        identifier: "directConnection.recordedHostId"
                    )
                }
                if isTrustAuthorized, !hasHostIdentityMismatch, let authorizedAt = trustPin?.authorizedAt {
                    Text("授权时间：\(authorizedAt.formatted(date: .abbreviated, time: .standard))")
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
                    Text(authorizationUnavailableText)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(authorizationGuidanceText)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isBusy {
                    HStack(spacing: PISpacing.s8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(PIColor.accent)
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
            return "经可信 SSH 诊断并重新授权"
        }
        return isTrustAuthorized && trustPin != nil ? "重新经可信 SSH 授权" : "经可信 SSH 获取并授权"
    }

    private var authorizationGuidanceText: String {
        if hasHostIdentityMismatch {
            return "只允许通过此回调重新取得并核对可信元数据；不会在这里覆盖旧 pin 或 hostId。"
        }
        return "回调应取得并核对候选 pin/hostId；只有用户明确授权后才可保存，不能自动接受新证书。"
    }

    private var authorizationUnavailableText: String {
        if hasHostIdentityMismatch {
            return "候选 pin 与已记录 hostId 不一致；请由调用方重新经可信 SSH 诊断，不能覆盖旧身份。"
        }
        if isBusy {
            return "另一项操作正在进行，完成后才能再次授权。"
        }
        return authorizationDisabledReason ?? "当前无法建立可信 SSH 授权，请先检查 SSH 配置与设备配对。"
    }

    private var trustState: (title: String, detail: String, icon: String, tint: Color) {
        if hasHostIdentityMismatch {
            return (
                "hostId 不一致",
                "候选证书元数据与可信记录不匹配；不会自动覆盖既有 pin 或身份。",
                "exclamationmark.octagon",
                PIColor.danger
            )
        }
        if isTrustAuthorized, trustPin != nil {
            return (
                "已授权此叶证书",
                "本机已保存完整 DER SHA-256 pin；授权本身不代表当前在线。",
                "checkmark.shield",
                PIColor.success
            )
        }
        if trustPin != nil {
            return (
                "等待你明确授权",
                "逐字核对完整 SHA-256 与 hostId；确认动作只通过下方回调发出。",
                "person.badge.key",
                PIColor.warning
            )
        }
        if isTrustAuthorized {
            return (
                "授权状态缺少证书 pin",
                "不能仅凭授权标记启用 Direct；需要重新经可信 SSH 取得完整元数据。",
                "exclamationmark.triangle",
                PIColor.danger
            )
        }
        return (
            "尚未取得 Direct 信任信息",
            "使用下方授权回调经已认证且主机密钥可信的 SSH 获取；公共 WSS 响应没有信任效力。",
            "shield",
            PIColor.text3
        )
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
                .font(PIFont.metaSmall)
                .tracking(0.4)
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

    // MARK: - Explicit direct retry

    private var retryGroup: some View {
        PIGroup(
            "手动重试",
            footer: "重试只发出新的 Direct candidate 请求；新通路完成认证与恢复前，调用方必须保持当前 SSH，不做后台自动切路。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                PIPrimaryButton(
                    title: "重试直连",
                    isEnabled: canPerformDirectRetry,
                    identifier: "directConnection.retry"
                ) {
                    onRetryDirect()
                }
                if !canPerformDirectRetry {
                    Text(retryUnavailableText)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("点击只触发 onRetryDirect 回调；此视图不会自行改 route、phase 或在线状态。")
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

    private var retryUnavailableText: String {
        if hasHostIdentityMismatch {
            return "hostId 不一致时不能重试；请先完成可信 SSH 诊断与重新授权。"
        }
        if isBusy {
            return "另一项连接操作正在进行。"
        }
        return retryDisabledReason ?? "仅当调用方确认 SSH 仍在线且 endpoint、pin、hostId 均已验证时才可重试。"
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
