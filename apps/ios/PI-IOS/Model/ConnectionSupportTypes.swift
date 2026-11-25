import Foundation
import UIKit
import Combine
import PIiOSCore
import PIiOSNet

typealias AdaptorUnitSnapshot = PIiOSCore.AdaptorUnitSnapshot

enum ConnectionPairingError: LocalizedError {
    case missingCredential
    case missingHostPort
    case invalidToken
    case keychainWriteFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "本机没有这台服务器的凭证：请先在服务器页保存并测试连接"
        case .missingHostPort:
            return "未填写 PI-adaptor 端口，无法建立配对隧道"
        case .invalidToken:
            return "配对令牌格式不正确：应以 ppt2. 开头，且不能包含空白字符"
        case .keychainWriteFailed:
            return "配对成功，但设备令牌未能写入 Keychain；请检查应用签名后重试"
        }
    }
}

enum ConnectionLifecycleError: LocalizedError {
    case connectionChanged

    var errorDescription: String? {
        "连接已切换或断开，请在新连接上重试"
    }
}

enum AdaptorUnitProbeError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "无法读取 PI-adaptor systemd 状态" : detail
        }
    }
}

enum AdaptorInstallError: LocalizedError {
    case invalidReleaseVersion
    case noCompatibleRelease
    case probeFailed(String)
    case malformedProbe
    case emptySudoPassword
    case sudoFailed(String)
    /// U15: the current local record no longer matches the frozen install target.
    case installationSuperseded
    /// The pending receipt is kept with the promoted credential for recovery.
    case receiptPersistenceFailed(String)
    /// Runtime verification completed without an adaptor hostId; nothing was promoted.
    case adaptorIdentityMissing

    var errorDescription: String? {
        switch self {
        case .invalidReleaseVersion:
            return "内置的 PI-adaptor Release 版本、资产或仓库配置不合法"
        case .noCompatibleRelease:
            return "找不到与当前 PI-IOS 兼容的 PI-adaptor 安装包。更新 App 后重试。"
        case .probeFailed(let detail):
            return detail.isEmpty ? "无法探测服务器平台" : detail
        case .malformedProbe:
            return "服务器平台探测输出不完整"
        case .emptySudoPassword:
            return "请输入 sudo 密码；空密码不会发送到服务器"
        case .sudoFailed(let detail):
            return detail.isEmpty ? "sudo 授权失败，pi-adaptor unit 未启动" : detail
        case .installationSuperseded:
            return "旧安装结果已过期，请到原服务器核对。"
                + "这台服务器在本机记录中的身份已变化，本次安装回执未写入，暂存的设备令牌也未提升为活跃令牌。"
        case .receiptPersistenceFailed(let detail):
            return "远端安装与运行验证已通过。本机安装回执将在下次启动时补写。\(detail)"
        case .adaptorIdentityMissing:
            return "运行验证未取得 PI-adaptor 身份（hostId），已丢弃本次安装结果，未提升设备令牌。"
        }
    }
}

struct BootstrapPairingCommit: Codable {
    let target: InstallTargetSnapshot
    let adaptorHostId: String
    let port: Int
    let version: String
    let attemptId: String
    let releaseSource: AdaptorInstallReleaseSource?
    let directEndpoint: String?

    var hostID: UUID { target.hostID }
}

/// Immutable description of one install attempt, frozen when the user presses
/// start. `target` is the HostRecord identity that was on screen; `record` is a
/// value copy of the same record, so SSH credentials and the commit check can
/// never observe a form edited after the click (U09/U15).
struct InstallRequest {
    let target: InstallTargetSnapshot
    let record: HostRecord
    let adaptorPort: Int
    /// Test-only override for the bundled release version.
    let releaseVersion: String?
    let force: Bool
    let direct: BootstrapDirectConfiguration?
    let directEndpoint: String?
    let authorizeDirectPin: Bool
}

extension InstallTargetSnapshot {
    init(record: HostRecord, identityGeneration: Int) {
        self.init(
            hostID: record.id,
            host: record.host,
            sshPort: record.port,
            username: record.username,
            hostPort: record.hostPort,
            directEndpoint: record.directEndpoint,
            identityGeneration: identityGeneration
        )
    }

    func matches(record: HostRecord, identityGeneration: Int) -> Bool {
        matches(InstallTargetSnapshot(record: record, identityGeneration: identityGeneration))
    }
}

struct AdaptorInstallRunOutcome: Sendable {
    let result: BootstrapRunResult
    let releaseVersion: String
    let attemptId: String
    let releaseSource: AdaptorReleaseResolutionSource?
    let adaptorHostId: String?
    let directEndpoint: String?
    let directVerified: Bool
    let directError: String?
    let requiresSSHOnlyConfirmation: Bool

    init(
        result: BootstrapRunResult,
        releaseVersion: String,
        attemptId: String,
        releaseSource: AdaptorReleaseResolutionSource?,
        adaptorHostId: String? = nil,
        directEndpoint: String? = nil,
        directVerified: Bool = false,
        directError: String? = nil,
        requiresSSHOnlyConfirmation: Bool = false
    ) {
        self.result = result
        self.releaseVersion = releaseVersion
        self.attemptId = attemptId
        self.releaseSource = releaseSource
        self.adaptorHostId = adaptorHostId
        self.directEndpoint = directEndpoint
        self.directVerified = directVerified
        self.directError = directError
        self.requiresSSHOnlyConfirmation = requiresSSHOnlyConfirmation
    }
}


struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    var operationID: UUID
    var account: String
    var address: String
    var key: SSHHostKey
    var status: HostKeyTrustStatus
}

/// 隧道 + RACP 的连接状态容器。界面只读这里的状态，不自行推断「在线」。

final class HostKeyPromptBroker: HostKeyConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private let operationID: UUID
    private let account: String
    private let address: String
    private let onPrompt: @Sendable (HostKeyPrompt) -> Void
    private var pending: CheckedContinuation<HostKeyConfirmation, Never>?
    private var cancelled = false

    init(
        operationID: UUID,
        account: String,
        address: String,
        onPrompt: @escaping @Sendable (HostKeyPrompt) -> Void
    ) {
        self.operationID = operationID
        self.account = account
        self.address = address
        self.onPrompt = onPrompt
    }

    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        let isCancelled = lock.withLock { cancelled }
        if isCancelled { return .reject }
        if status == .matches {
            return .trust
        }
        // DEF-R4-004：`.changed` 也必须挂起并弹出「主机指纹已变化」浮层（AC-02.2），
        // 此前直接拒绝导致 UI 只能看到握手失败被归类为超时。
        // UI 在 `.changed` 态只提供「取消（不建立连接）」，因此这条路径的结果
        // 仍是拒绝——但通过用户显式确认，且错误分类保留为指纹不一致。
        return await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: .reject)
                return
            }
            pending = continuation
            lock.unlock()
            onPrompt(
                HostKeyPrompt(
                    operationID: operationID,
                    account: account,
                    address: address,
                    key: key,
                    status: status
                )
            )
        }
    }

    func respond(_ confirmation: HostKeyConfirmation) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(returning: confirmation)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(returning: .reject)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 错误 → 用户可读文案（不含任何凭证内容，AC-G2）。
enum ConnectionErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? SSHTransportError {
            return describeSSH(error)
        }
        if let error = error as? SSHPrivateKeyError {
            return "凭据无法使用：" + ConnectionDiagnosticRedactor.redact(error.description)
        }
        if let error = error as? RACPClientError {
            return describeRACP(error)
        }
        if let error = error as? RACPWebSocketError {
            return describeWebSocket(error)
        }
        if let error = error as? ProviderImportValidationFailure {
            return error.description
        }
        if let error = error as? RACPV2Error {
            return describeV2(error)
        }
        return ConnectionDiagnosticRedactor.redact(error.localizedDescription)
    }

    private static func describeSSH(_ error: SSHTransportError) -> String {
        let kind: ConnectionFailureKind
        switch error {
        case .invalidPrivateKey:
            // R6：错误 = 发生了什么 + 下一步；401 这类状态码对用户没有意义。
            return "认证失败：私钥无法使用，检查私钥格式与口令后重试。"
        case .hostKeyUnreadable, .hostKeyRejected, .hostKeyAlgorithmUnsupported:
            kind = .hostKey
        case .authenticationFailed:
            kind = .authentication
        case .timedOut:
            kind = .timeout
        case .channelClosed, .closedByPeer:
            kind = .offline
        case .tunnelRefused:
            kind = .remoteUnavailable
        case .networkFailure(_, let detail):
            kind = ConnectionFailureClassifier.classify(
                code: "ssh.networkFailure",
                message: detail
            )
        case .outputLimitExceeded:
            return "远端命令输出异常增大，已中止以保护设备内存。"
        }
        return kind.userMessage
    }

    /// 会话归档/删除优先展示 Host 的原始原因；本地错误仍走既有映射。
    static func describeSessionAction(_ error: Error) -> String {
        if case RACPClientError.server(_, let message) = error,
           let message, !message.isEmpty {
            return ConnectionDiagnosticRedactor.redact(message)
        }
        return describe(error)
    }

    private static func describeRACP(_ error: RACPClientError) -> String {
        switch error {
        case .notConnected:
            return ConnectionFailureKind.offline.userMessage
        case .protocolMismatch, .malformedFrame:
            return ConnectionFailureKind.protocolViolation.userMessage
        case .timedOut:
            return ConnectionFailureKind.timeout.userMessage
        case .server(let code, _):
            return ConnectionFailureClassifier.userMessage(forRACPCode: code)
        }
    }

    /// `RACPV2Error` 来自 PI-adaptor v2 直连（provider 增删、会话配置等）。桥接成 NSError
    /// 时只会显示「PIiOSCore.RACPV2Error 错误 N」，用户无法据此判断该做什么，
    /// 因此这里逐项映射为可操作文案。
    private static func describeV2(_ error: RACPV2Error) -> String {
        switch error {
        case .notConnected:
            return "服务器未连接：先到设置页恢复连接，再重试。"
        case .protocolViolation(let reason):
            return "服务器返回的内容无法解析，更新 PI-adaptor 后重试："
                + ConnectionDiagnosticRedactor.redact(reason)
        case .server(let code, let message):
            if let message, !message.isEmpty {
                return ConnectionDiagnosticRedactor.redact(message)
            }
            return ConnectionFailureClassifier.userMessage(
                forRACPCode: RACPErrorCode(raw: code)
            )
        }
    }

    private static func describeWebSocket(_ error: RACPWebSocketError) -> String {
        switch error {
        case .upgradeRejected(let status):
            return ConnectionFailureClassifier.classify(
                code: "websocket.upgradeRejected",
                httpStatus: status
            ).userMessage
        case .protocolViolation:
            return ConnectionFailureKind.protocolViolation.userMessage
        case .closed:
            return ConnectionFailureKind.offline.userMessage
        }
    }
}

/// 主机指纹审计日志（AC-02.3）：只记指纹与时间，不含任何凭证。
enum HostKeyAuditLog {
    private static let fileURL: URL? = SessionCacheStore.defaultURL()?
        .deletingLastPathComponent()
        .appendingPathComponent("hostkey-audit-v1.json")

    static func append(_ event: HostKeyAuditEvent) {
        guard let fileURL else { return }
        var events: [HostKeyAuditEvent] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HostKeyAuditEvent].self, from: data) {
            events = decoded
        }
        events.append(event)
        if let data = try? JSONEncoder().encode(events.suffix(200).map { $0 }) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}
