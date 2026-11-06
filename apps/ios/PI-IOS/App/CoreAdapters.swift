import SwiftUI
import PIiOSCore
import PIiOSNet

// MARK: - App ↔ PIiOSCore / PIiOSNet 的适配层

/// 权限徽标需要的展示信息。枚举本身来自 `PIiOSCore.RACPPermissionMode`，
/// App 里不再保留第二份 `PIPermissionMode`（避免两处枚举漂移）。
extension RACPPermissionMode {
    var title: String {
        switch self {
        case .ask: return "每次询问"
        case .acceptEdits: return "允许编辑"
        case .auto: return "全自动"
        }
    }

    /// 语义色：ask 灰、accept-edits 蓝、auto 橙（design-system.md §3）。
    var tint: Color {
        switch self {
        case .ask: return PIColor.text2
        case .acceptEdits: return PIColor.accent
        case .auto: return PIColor.warning
        }
    }
}

extension RACPSessionMode {
    var title: String {
        switch self {
        case .agent: return "Agent"
        case .plan: return "Plan"
        case .goal: return "Goal"
        }
    }
}

/// 契约 §7「客户端行为」对用户显示的文案。行为本身在 `RACPErrorCode.action` 里，
/// 这里只负责把它说成人话；未知码原样展示，不静默归为成功。
extension RACPErrorCode {
    var userMessage: String {
        switch self {
        case .unauthorized: return "设备令牌已失效：需要重新配对后再连"
        case .forbidden: return "当前设备没有这个操作的权限"
        case .protocolMismatch: return "服务器版本不兼容，已停止连接"
        case .invalidArgument: return "参数不合法"
        case .notFound: return "对象不存在，列表已刷新"
        case .methodNotFound: return "这台服务器不支持该操作"
        case .agentUnavailable: return "PI-adaptor 暂不可用，正在退避重连"
        case .agentBusy: return "PI-adaptor 正忙"
        case .conflict: return "状态已变化，重新拉取后再试"
        case .idempotencyConflict: return "同一幂等键对应了不同内容，需要人工确认"
        case .cursorExpired: return "事件游标已过期，已按快照重建"
        case .clientTooSlow: return "客户端处理过慢，已丢弃订阅并按快照重建"
        case .approvalExpired: return "审批已过期"
        case .approvalStale: return "审批已失效"
        case .payloadTooLarge: return "内容超过上限，请压缩后重试"
        case .rateLimited: return "请求过于频繁，稍后重试"
        case .pairingFailed: return "配对失败"
        case .pairingTokenExpired: return "配对令牌已过期，需要重启 PI-adaptor 取新令牌"
        case .capabilityUnavailable: return "服务器未提供该能力"
        case .serverInternal: return "服务器内部错误"
        case .unknown(let raw): return raw
        }
    }
}

/// 隧道状态的展示信息（设置页与项目页共用，保证两处口径一致）。
extension RACPTunnelState {
    var bannerKind: PIStatusKind {
        switch self {
        case .online: return .success
        case .offline: return .info
        case .reconnecting, .verifyingHostKey: return .warning
        case .connecting, .authenticating, .handshaking: return .info
        }
    }

    /// 供列表行使用的详细说明；`nil` 表示无需额外解释。
    var detail: String? {
        switch self {
        case .offline(let reason): return reason
        case .reconnecting(let attempt, let delay, let reason):
            return "第 \(attempt) 次重连，\(Int(delay)) 秒后重试。上次原因：\(reason)"
        case .verifyingHostKey(_, let status):
            switch status {
            case .firstUse: return "首次连接：确认指纹后才会建立连接"
            case .changed(let pinned): return "指纹与固定记录不一致（原 \(pinned.fingerprint)），已拒绝连接"
            case .matches: return "与固定记录一致"
            }
        default:
            return nil
        }
    }
}

// MARK: - 服务器页提交快照（U13）

/// 「保存并测试连接」点击瞬间冻结的提交快照。
///
/// 点击之后，校验、Keychain 账号、身份变化判断、记录更新与连接测试都只读这一份值：
/// 既不读页面上的实时 `draft`（保存期间相关字段被禁用），也不读实时的 `HostRecord`。
/// 因此一次提交只属于同一时刻的目标与凭证；保存完成后再产生的编辑是下一次提交。
struct HostSaveIntent: Equatable {
    /// 点击时既有记录的身份快照；新增记录为 `nil`。
    struct Identity: Equatable {
        let host: String
        let port: Int
        let username: String
        let authKind: AuthKind
        let hostPort: Int?
        let directEndpoint: String?
        let connectionPreference: ConnectionPreference
        let isCurrent: Bool

        init(record: HostRecord) {
            host = record.host
            port = record.port
            username = record.username
            authKind = record.authKind
            hostPort = record.hostPort
            directEndpoint = record.directEndpoint
            connectionPreference = record.connectionPreference
            isCurrent = record.isCurrent
        }

        /// 与冻结的提交草稿比较：连接身份是否变化（口径与 `HostValidator` 一致）。
        func connectionIdentityChanged(by draft: HostDraft) -> Bool {
            host != draft.host.piTrimmed
                || port != (Int(draft.port.piTrimmed) ?? port)
                || username != draft.username.piTrimmed
                || authKind != draft.authKind
                || hostPort != Int(draft.hostPort.piTrimmed)
                || directEndpoint != HostValidator.canonicalDirectEndpoint(draft.directEndpoint)
                || connectionPreference != draft.connectionPreference
        }
    }

    let hostID: UUID?
    let draft: HostDraft
    /// 点击时算出的 Keychain 账号：测试连接与凭证写入都用它，不随之后的表单变化。
    let account: String
    /// 点击时冻结的凭证（新输入的、或从冻结账号读出的旧凭证）。
    let credential: SSHCredential
    /// 本次提交是否需要断开旧连接并按新身份重连（仅当前服务器且身份/凭证变化时）。
    let requiresReconnect: Bool
    /// 本次提交的凭证校验口径：新增记录或切换认证方式时必须重新填写。
    let requiresSecret: Bool
    let identity: Identity?

    /// 冻结草稿的校验结果：保存过程中现场再改表单也不会改变这次提交的校验口径。
    var validationErrors: HostDraftErrors {
        HostValidator.validate(draft, requiresSecret: requiresSecret)
    }

    /// 本次提交的显示名（名称留空时用地址）。
    var displayName: String {
        let trimmed = draft.name.piTrimmed
        return trimmed.isEmpty ? draft.host.piTrimmed : trimmed
    }

    /// 在点击瞬间从实时表单与当前记录冻结出提交快照。
    static func freeze(
        hostID: UUID?,
        draft: HostDraft,
        existing: HostRecord?,
        account: String,
        credential: SSHCredential
    ) -> HostSaveIntent {
        let identity = existing.map(Identity.init(record:))
        let requiresSecret = !(existing != nil && existing?.authKind == draft.authKind)
        let identityChanged = identity?.connectionIdentityChanged(by: draft) ?? false
        let requiresReconnect = identity?.isCurrent == true
            && (identityChanged || !draft.secret.piTrimmed.isEmpty)
        return HostSaveIntent(
            hostID: hostID,
            draft: draft,
            account: account,
            credential: credential,
            requiresReconnect: requiresReconnect,
            requiresSecret: requiresSecret,
            identity: identity
        )
    }

    /// 记录更新前与连接测试前的身份代次核验（U13）。
    ///
    /// - 不需要重连（新增记录或连接身份没变）：没有代次要求。
    /// - 需要重连却没拿到代次（准备阶段发现服务器已被切走）：不得继续提交。
    /// - 拿到代次后交给调用方核验：`model.canApplyHostIdentityChange(id:generation:)`。
    func canApplyIdentityChange(identityGeneration: Int?, isValid: (Int) -> Bool) -> Bool {
        guard requiresReconnect else { return true }
        guard let identityGeneration else { return false }
        return isValid(identityGeneration)
    }
}

// MARK: - 设备令牌失效的就地重新配对入口（U17）

/// 最近一次连接失败是否属于「设备令牌被服务器拒绝 / 设备被撤销」。
enum PairingAuthFailure: Equatable {
    case none
    /// 设备令牌失效：网关 401/403 或 RACP `UNAUTHORIZED`。
    case tokenUnauthorized
    /// 服务器明确撤销了这台设备（连接以 `device revoked` 关闭）。
    case deviceRevoked

    var isFailure: Bool { self != .none }
}

/// 服务器页 / 设置页「PI-adaptor 连接」入口的展示策略（纯函数，便于单测）。
///
/// 只读现有 `ConnectionStatus`，不新增 `ConnectionModel` 写接口，也不改变凭证语义：
/// 重新配对是独立动作，撤销仍然要服务器确认。
struct PairingEntryPolicy: Equatable {
    let hasDeviceToken: Bool
    let isPaired: Bool
    let authFailure: PairingAuthFailure

    /// 已有设备令牌时，除了「连接」还要提供「使用新的一次性令牌重新配对」。
    var showsRepairEntry: Bool { hasDeviceToken }

    /// 连接失败且分类为令牌失效/设备撤销时，把重新配对入口提到最前面并解释。
    var isRepairPromoted: Bool { hasDeviceToken && authFailure.isFailure }

    /// 设置页「服务器」分组里的重新配对入口是否出现（未配对或令牌已失效）。
    var shouldShowSettingsRepairRow: Bool { !isPaired || authFailure.isFailure }

    var repairTitle: String {
        switch authFailure {
        case .deviceRevoked: return "服务器已撤销这台设备的访问权限"
        case .tokenUnauthorized: return "设备令牌已失效，服务器拒绝了连接"
        case .none: return "使用新的一次性令牌重新配对"
        }
    }

    /// 就地恢复的说明：讲清为什么需要新令牌，以及旧令牌在新配对成功前不会被覆盖。
    var repairExplanation: String {
        switch authFailure {
        case .deviceRevoked:
            return "这台设备的访问权限已在服务器侧撤销。请用服务器上的 pi-adaptor 重新输出的一次性令牌就地重新配对；"
                + "新配对成功前，本机保存的旧设备令牌不会被覆盖。撤销访问权限是另一个动作，仍需要服务器确认。"
        case .tokenUnauthorized:
            return "服务器拒绝了本机的设备令牌（可能已失效或被重置）。请用服务器重新输出的一次性令牌就地重新配对；"
                + "新配对成功前，本机保存的旧设备令牌不会被覆盖。撤销访问权限是另一个动作，仍需要服务器确认。"
        case .none:
            return "服务器重装、令牌重置或设备被撤销后，可用新的一次性令牌重新配对。"
        }
    }

    var repairActionTitle: String { "使用新的一次性令牌重新配对" }

    var repairRowSubtitle: String {
        if authFailure.isFailure {
            return "上次连接被服务器拒绝：用新令牌恢复；新配对成功前旧令牌保留"
        }
        return "服务器撤销设备或令牌失效时使用；新配对成功前旧令牌保留"
    }

    var settingsRepairTitle: String {
        authFailure.isFailure ? "重新配对（设备令牌已失效）" : "重新配对"
    }

    var settingsRepairSubtitle: String {
        authFailure.isFailure
            ? "打开服务器页，用新的一次性令牌就地重新配对"
            : "打开服务器页完成配对"
    }

    /// 从连接状态推导失败分类（只读现有状态，不新增写接口）。
    ///
    /// - 直连 401/403（`.authentication`）视为设备令牌失效；
    /// - 直连/SSH 以 `device revoked` 关闭视为设备撤销；
    /// - SSH 路由在 SSH 认证阶段失败属于 SSH 凭证问题，重新配对同样需要可用凭证，不提示。
    static func authFailure(from status: ConnectionStatus) -> PairingAuthFailure {
        if status.directFailure?.category == .deviceRevoked
            || status.sshFailure?.category == .deviceRevoked {
            return .deviceRevoked
        }
        if status.directFailure?.category == .authentication {
            return .tokenUnauthorized
        }
        if let ssh = status.sshFailure, ssh.category == .authentication,
           case .authenticating = ssh.phase {
            return .none
        }
        if status.sshFailure?.category == .authentication {
            return .tokenUnauthorized
        }
        return .none
    }
}
