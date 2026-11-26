import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

// MARK: - 隧道状态

/// 隧道 + 会话层状态（设置页与项目页都直接展示这里的状态，绝不伪造在线）。
public enum RACPTunnelState: Equatable, Sendable {
    /// 未连接；`reason` 为上次失败原因。
    case offline(reason: String?)
    case connecting
    /// 正在等用户核对主机指纹（S-04「核对指纹」）。
    case verifyingHostKey(fingerprint: String, status: HostKeyTrustStatus)
    case authenticating
    case handshaking
    case online
    /// 退避重连中（契约 §7 `AGENT_UNAVAILABLE`）。
    case reconnecting(attempt: Int, delay: TimeInterval, reason: String)

    public var displayText: String {
        switch self {
        case .offline: return "未连接"
        case .connecting: return "连接中"
        case .verifyingHostKey: return "等待核对指纹"
        case .authenticating: return "认证中"
        case .handshaking: return "握手中"
        case .online: return "在线"
        case .reconnecting: return "重连中"
        }
    }

    public var isOnline: Bool { self == .online }
}

public struct RACPServerInfo: Equatable, Sendable {
    public var protocolVersion: String
    public var serverName: String
    public var serverVersion: String
    public var hostId: String?
    public var connectionId: String
    public var roles: [String]
    /// `policy.remoteMaxPermissionMode`：权限展示的唯一依据（契约 §2.2）。
    public var remoteMaxPermissionMode: String?
    /// `policy.applyCeilingToPairedDevices`
    public var applyCeilingToPairedDevices: Bool?
    /// `capabilities` 原始值：入口可用性按它裁剪（契约 §2.2 / §8）。
    public var capabilities: JSONValue?
    /// `server.piVersion`：PI-adaptor 自带并返回的 Pi 版本。
    public var piVersion: String?

    public init(
        protocolVersion: String,
        serverName: String,
        serverVersion: String,
        hostId: String?,
        connectionId: String,
        roles: [String],
        remoteMaxPermissionMode: String? = nil,
        applyCeilingToPairedDevices: Bool? = nil,
        capabilities: JSONValue? = nil,
        piVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.hostId = hostId
        self.connectionId = connectionId
        self.roles = roles
        self.remoteMaxPermissionMode = remoteMaxPermissionMode
        self.applyCeilingToPairedDevices = applyCeilingToPairedDevices
        self.capabilities = capabilities
        self.piVersion = piVersion
    }
}

public struct RACPDeviceIdentity: Equatable, Sendable {
    public var serverInfo: RACPServerInfo
    public var adaptorHostId: String

    public init(serverInfo: RACPServerInfo, adaptorHostId: String) {
        self.serverInfo = serverInfo
        self.adaptorHostId = adaptorHostId
    }
}

public struct RACPRecoveryContext: Equatable, Sendable {
    public var hostCursor: RACPCursor?
    public var sessionId: String?
    public var sessionSummary: RACPSessionSummary?
    public var snapshot: RACPSnapshot?
    public var replayComplete: Bool

    public init(
        hostCursor: RACPCursor?,
        sessionId: String?,
        sessionSummary: RACPSessionSummary?,
        snapshot: RACPSnapshot?,
        replayComplete: Bool
    ) {
        self.hostCursor = hostCursor
        self.sessionId = sessionId
        self.sessionSummary = sessionSummary
        self.snapshot = snapshot
        self.replayComplete = replayComplete
    }
}

public enum RACPClientUpdate: Sendable {
    case state(RACPTunnelState)
    case ready(RACPServerInfo)
    /// 会话视图（items / 快照）已变化。
    case sessionChanged
    /// PI-adaptor 级事件表明会话目录或某个会话的 revision 已变化，需要刷新列表。
    case hostChanged(RACPHostChange)
    /// replayComplete=false 后取得的完整目录；必须先于 online 应用。
    case hostSnapshot(projects: [RACPProjectSummary], sessions: [RACPSessionSummary])
    /// 收到一条事件（已按契约 §3.2 归约）。
    case event(RACPEvent)
    case error(code: RACPErrorCode, message: String?)
}

public enum RACPHostChangeReason: String, Equatable, Sendable {
    /// `session.created` / `session.changed` / `session.archived` / `host.changed`。
    case catalogChanged
    /// PI-adaptor 无可重放事件；客户端必须拉取完整目录。
    case replayIncomplete
    /// PI-adaptor 明确要求重新同步。
    case resyncRequired
    /// PI-adaptor 事件流的 epoch 已变化。
    case epochChanged
    /// durable sequence 不连续，说明中间有事件丢失。
    case eventGap
}

/// PI-adaptor 级变更的最小投影。原始载荷仍保留在事件的 `payload` 中。
public struct RACPHostChange: Equatable, Sendable {
    public var reason: RACPHostChangeReason
    public var kind: String?
    public var sessionId: String?
    public var revision: Int?
    public var cursor: RACPCursor?
    public var payload: JSONValue

    public init(
        reason: RACPHostChangeReason,
        kind: String?,
        sessionId: String?,
        revision: Int?,
        cursor: RACPCursor?,
        payload: JSONValue
    ) {
        self.reason = reason
        self.kind = kind
        self.sessionId = sessionId
        self.revision = revision
        self.cursor = cursor
        self.payload = payload
    }
}

/// 事件帧只冻结了 `{epoch, sequence}` 与 `payload`；PI-adaptor 订阅需要的分类字段从原始载荷读取。
extension RACPEvent {
    public var scope: RACPSubscriptionScope? {
        guard let raw = payload.value(at: ["scope"])?.stringValue else { return nil }
        return RACPSubscriptionScope(rawValue: raw)
    }

    public var kind: String? {
        payload.value(at: ["kind"])?.stringValue
    }

    public var sessionId: String? {
        payload.value(at: ["sessionId"])?.stringValue
    }

    public var revision: Int? {
        payload.value(at: ["revision"])?.intValue
    }
}

enum RACPEventRoute: Equatable {
    case session(RACPEvent)
    case host(RACPEvent)
    case ignored
}

/// 会话事件只能归约到当前 attach 的会话；PI-adaptor 事件走独立通道。
enum RACPEventRouter {
    static func route(_ event: RACPEvent, currentSessionID: String?) -> RACPEventRoute {
        switch event.scope {
        case .host:
            return .host(event)
        case .session:
            guard let currentSessionID else { return .ignored }
            if let eventSessionID = event.sessionId, eventSessionID != currentSessionID {
                return .ignored
            }
            return .session(event)
        case nil:
            // 兼容未携带 scope 的旧会话帧；无 item 的未知帧不能污染会话归约器。
            guard let currentSessionID else { return .ignored }
            if let eventSessionID = event.sessionId, eventSessionID != currentSessionID {
                return .ignored
            }
            return event.item == nil ? .ignored : .session(event)
        }
    }
}

struct RACPHostEventObservation: Equatable {
    var change: RACPHostChange
    var requiresCatalogRefresh: Bool
}

/// PI-adaptor 订阅跨重连保留“最后已处理游标”，但每次连接都重建 subscription id。
struct RACPHostSubscriptionTracker: Equatable, Sendable {
    static let catalogKinds: Set<String> = [
        "session.created",
        "session.changed",
        "session.archived",
        "session.deleted",
        "host.changed",
    ]

    private(set) var subscriptionID: String?
    private(set) var cursor: RACPCursor?

    mutating func prepareForReconnect() {
        subscriptionID = nil
    }

    mutating func resetAfterCursorExpired() {
        subscriptionID = nil
        cursor = nil
    }

    mutating func restoreCursor(_ cursor: RACPCursor) {
        self.cursor = cursor
    }

    mutating func install(subscriptionID: String, starting: RACPCursor?) {
        self.subscriptionID = subscriptionID
        guard let starting else { return }
        let baseline = RACPCursor(
            epoch: starting.epoch,
            sequence: max(0, starting.sequence - 1)
        )
        guard let cursor else {
            self.cursor = baseline
            return
        }
        // 重放事件可能先于 subscribe 响应到达；不要把已经推进的游标回拨。
        if cursor.epoch != baseline.epoch || cursor.sequence < baseline.sequence {
            self.cursor = baseline
        }
    }

    mutating func observe(_ event: RACPEvent) -> RACPHostEventObservation? {
        guard event.scope?.rawValue == RACPSubscriptionScope.host.rawValue else { return nil }
        let kind = event.kind

        if kind == "resync.required" {
            let epoch = event.epoch ?? cursor?.epoch ?? "unknown"
            let sequence = event.durableSequence ?? event.afterSequence ?? cursor?.sequence ?? 0
            let next = RACPCursor(epoch: epoch, sequence: sequence)
            if event.isDurable {
                self.cursor = next
            }
            return observation(
                for: event,
                cursor: next,
                reason: .resyncRequired,
                requiresRefresh: true
            )
        }

        guard let sequence = event.durableSequence else { return nil }

        if let epoch = event.epoch,
           let cursor,
           cursor.epoch != epoch {
            let next = RACPCursor(epoch: epoch, sequence: sequence)
            self.cursor = next
            return observation(
                for: event,
                cursor: next,
                reason: .epochChanged,
                requiresRefresh: true
            )
        }

        if let cursor,
           (event.epoch == nil || event.epoch == cursor.epoch),
           sequence <= cursor.sequence {
            return nil
        }

        let epoch = event.epoch ?? cursor?.epoch ?? "unknown"
        let next = RACPCursor(epoch: epoch, sequence: sequence)
        cursor = next
        // 不要用序号连续性判定缺口：`sequence` 是 PI-adaptor 的**全局**序号（契约 §3.2），
        // host 订阅只收到 host 事件，会话事件会穿插占用序号，因此「相邻 host 事件
        // 序号不连续」是常态。真正的重同步信号是 epoch 变化、`resync.required`
        // 以及服务端 `CURSOR_EXPIRED`。
        if let kind, Self.catalogKinds.contains(kind) {
            return observation(
                for: event,
                cursor: next,
                reason: .catalogChanged,
                requiresRefresh: true
            )
        }
        return observation(
            for: event,
            cursor: next,
            reason: .catalogChanged,
            requiresRefresh: false
        )
    }

    private func observation(
        for event: RACPEvent,
        cursor: RACPCursor,
        reason: RACPHostChangeReason,
        requiresRefresh: Bool
    ) -> RACPHostEventObservation {
        RACPHostEventObservation(
            change: RACPHostChange(
                reason: reason,
                kind: event.kind,
                sessionId: event.sessionId,
                revision: event.revision,
                cursor: cursor,
                payload: event.payload
            ),
            requiresCatalogRefresh: requiresRefresh
        )
    }
}

// MARK: - 配置

public struct RACPConfiguration: Sendable {
    public var ssh: SSHConnectionRequest?
    /// PI-adaptor 在服务器回环上的端口（`direct-tcpip` 目标端口）。direct 不读取它。
    public var hostPort: Int?
    /// 设备令牌（契约 §2.3，走 `Authorization: Bearer`）。
    public var deviceToken: String?
    public var clientVersion: String
    public var connectionPreference: ConnectionPreference
    public var direct: DirectRACPConfiguration?

    public init(
        ssh: SSHConnectionRequest?,
        hostPort: Int?,
        deviceToken: String?,
        clientVersion: String = "0.0.1",
        connectionPreference: ConnectionPreference = .sshOnly,
        direct: DirectRACPConfiguration? = nil
    ) {
        self.ssh = ssh
        self.hostPort = hostPort
        self.deviceToken = deviceToken
        self.clientVersion = clientVersion
        self.connectionPreference = connectionPreference
        self.direct = direct
    }
}

/// 会话视图的对外快照（`SessionViewModel` 只在客户端内部持有）。
/// 会话视图的对外快照（`SessionViewModel` 只在客户端内部持有）。
public struct RACPSessionView: Equatable, Sendable {
    public var sessionId: String?
    public var summary: RACPSessionSummary?
    public var items: [RACPItem]
    /// 正在运行中的条目（快照 `activeItems`）；非空即视为有 turn 在跑。
    public var activeItems: [RACPItem]
    /// 排队中的补充指令（AC-13.1）；元素形状未冻结，只解析出可用于取消的 id。
    public var queuedTurns: [QueuedTurn]
    public var failedQueueStartID: String?
    public var pendingApprovals: [RACPApprovalRequest]
    /// 曾出现、但已不在快照里的审批卡（AC-14.5：显示为失效且不可点击）。
    public var expiredApprovalIds: Set<String>
    public var cursor: RACPCursor?
    public var revision: Int
    public var replayComplete: Bool
    public var hasMoreHistory: Bool
    /// 正在运行的 turn id；`nil` 表示没有可中止的 turn。
    public var runningTurnId: String?

    public init(
        sessionId: String?,
        summary: RACPSessionSummary?,
        items: [RACPItem],
        activeItems: [RACPItem],
        queuedTurns: [QueuedTurn],
        pendingApprovals: [RACPApprovalRequest],
        expiredApprovalIds: Set<String>,
        cursor: RACPCursor?,
        revision: Int,
        replayComplete: Bool,
        hasMoreHistory: Bool,
        runningTurnId: String?,
        failedQueueStartID: String? = nil
    ) {
        self.sessionId = sessionId
        self.summary = summary
        self.items = items
        self.activeItems = activeItems
        self.queuedTurns = queuedTurns
        self.failedQueueStartID = failedQueueStartID
        self.pendingApprovals = pendingApprovals
        self.expiredApprovalIds = expiredApprovalIds
        self.cursor = cursor
        self.revision = revision
        self.replayComplete = replayComplete
        self.hasMoreHistory = hasMoreHistory
        self.runningTurnId = runningTurnId
    }

    public static let empty = RACPSessionView(
        sessionId: nil, summary: nil, items: [], activeItems: [], queuedTurns: [],
        pendingApprovals: [], expiredApprovalIds: [],
        cursor: nil, revision: 0, replayComplete: false, hasMoreHistory: false, runningTurnId: nil
    )
}

public enum RACPClientError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case protocolMismatch(String)
    case server(code: RACPErrorCode, message: String?)
    case timedOut(String)
    case malformedFrame(String)

    public var description: String {
        switch self {
        case .notConnected:
            return "隧道未连接"
        case .protocolMismatch(let detail):
            return "PI-adaptor 版本不兼容：\(detail)"
        case .server(let code, let message):
            return message ?? "服务器返回错误：\(code)"
        case .timedOut(let phase):
            return "超时：\(phase)"
        case .malformedFrame(let detail):
            return "收到无法解析的帧：\(detail)"
        }
    }
}

/// The host key was already checked when the bootstrap SSH transport was
/// opened. This confirmer is never consulted on the supplied-transport path;
/// rejecting is the safe fallback if that invariant is ever broken.
struct SuppliedTransportHostKeyConfirmer: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .reject
    }
}

// MARK: - 客户端

/// RACP 客户端最小闭环（契约 §2.2 / §2.3 / §3）：
/// SSH 隧道 → `direct-tcpip` → WebSocket（子协议 `pi-racp.v2.jsonrpc`）→ 握手 → 请求/事件。
enum RequestRecoveryScope: Sendable {
    case session
    case host
}

struct PendingEventAck: Equatable, Sendable {
    let subscriptionId: String
    let sequence: Int
}

enum SnapshotRebuildOutcome: Equatable {
    case rebuilt
    case inProgress
    case superseded
    case failed
}


// MARK: - 帧与结果形状

/// 入站帧：在 `RACPIncomingFrame` 之外还需 `params`（事件帧的有效载荷），
/// 因此这里单独解一层；响应部分与 `RACPIncomingFrame` 的语义一致。
struct RACPInboundEnvelope: Decodable {
    var id: RACPIdentifier?
    var method: String?
    var result: JSONValue?
    var error: RACPErrorBody?
    var params: JSONValue?
}

/// `events/closed` 通知体。
///
/// v2 契约（`docs/api/pi-adaptor.md`）冻结为扁平 `{ "subscriptionId": …, "code": "UNAUTHORIZED" }`；
/// 早期 v1 形状把错误包在 `error` 对象里。两种都接受，否则严格按 v2 发来的终态码
/// （如设备被撤销的 `UNAUTHORIZED`）会被当成 `error == nil` 的可恢复关闭，导致无限重订阅而非进入终态。
struct RACPSubscriptionClosedNotice: Decodable, Equatable {
    var subscriptionId: String
    var error: RACPErrorBody?
    var lastSafeCursor: RACPCursor?

    private enum CodingKeys: String, CodingKey {
        case subscriptionId, error, lastSafeCursor, code, message
    }

    init(subscriptionId: String, error: RACPErrorBody?, lastSafeCursor: RACPCursor?) {
        self.subscriptionId = subscriptionId
        self.error = error
        self.lastSafeCursor = lastSafeCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.lastSafeCursor = try container.decodeIfPresent(RACPCursor.self, forKey: .lastSafeCursor)
        if let nested = try container.decodeIfPresent(RACPErrorBody.self, forKey: .error) {
            self.error = nested
        } else if let code = try container.decodeIfPresent(String.self, forKey: .code) {
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self.error = RACPErrorBody(code: code, message: message)
        } else {
            self.error = nil
        }
    }
}

/// `session/attach` 的参数与返回（契约 §3.1 / §3.2）。
struct RACPSessionAttachParams: Encodable, Sendable {
    var sessionId: String
    var includeSnapshot = true
    var role: String?
    var after: RACPCursor?

    enum CodingKeys: String, CodingKey {
        case sessionId, includeSnapshot, role, after
    }
}

struct RACPSessionAttachResult: Decodable {
    var session: RACPSessionSummary
    var role: String?
    var replayComplete: Bool?
    var snapshot: RACPSnapshot?
}

struct RACPInitializeResult: Decodable {
    struct Server: Decodable {
        var name: String?
        var version: String?
        var hostId: String?
        var piVersion: String?
    }

    struct Principal: Decodable {
        var subject: String?
        var roles: [String]?
    }

    struct Policy: Decodable {
        var remoteMaxPermissionMode: String?
        var applyCeilingToPairedDevices: Bool?
    }

    var protocolVersion: String
    var server: Server?
    var connectionId: String?
    var roles: [String]?
    var principal: Principal?
    var policy: Policy?
    var capabilities: JSONValue?

    func serverInfo() -> RACPServerInfo {
        let trimmedPiVersion = server?.piVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RACPServerInfo(
            protocolVersion: protocolVersion,
            serverName: server?.name ?? "",
            serverVersion: server?.version ?? "",
            hostId: server?.hostId,
            connectionId: connectionId ?? "",
            roles: roles ?? principal?.roles ?? [],
            remoteMaxPermissionMode: policy?.remoteMaxPermissionMode,
            applyCeilingToPairedDevices: policy?.applyCeilingToPairedDevices,
            capabilities: capabilities,
            piVersion: trimmedPiVersion?.isEmpty == false ? trimmedPiVersion : nil
        )
    }
}

struct RACPV2AttachmentCreateResult: Decodable {
    var attachmentId: String
    var chunkSize: Int
    var expiresAt: String
}

struct RACPV2AttachmentChunkResult: Decodable {
    var receivedBytes: Int
}

struct RACPV2AttachmentEnvelope: Decodable {
    var attachment: RACPV2Attachment
}

/// `connection/ping` 的返回（`{ok, serverTime}`）。
struct RACPJSONObject: Decodable, Sendable {
    var ok: Bool?
    var serverTime: String?
}

struct RACPAuthenticatedPingResult: Decodable, Sendable {
    var ok: Bool?
    var serverTime: String?
    var pong: Bool?
    var hostId: String?
}

// MARK: - 辅助

let racpResponseProgressCeiling: TimeInterval = 120
let racpHeartbeatProgressCeiling: TimeInterval = 60

private final class RACPSocketBox: @unchecked Sendable {
    let socket: any RACPSocket

    init(_ socket: any RACPSocket) {
        self.socket = socket
    }
}

/// Bounded write for messages without a JSON-RPC response (for example
/// `notifications/initialized`). A stalled NIO write must not hang the caller,
/// and abandoning it requires closing the original socket generation.
func sendRACPMessageWithDeadline(
    _ text: String,
    to socket: any RACPSocket,
    timeout: TimeInterval,
    phase: String
) async throws {
    let box = RACPSocketBox(socket)
    do {
        try await withNetworkDeadline(
            seconds: timeout,
            timeoutError: { RACPClientError.timedOut(phase) }
        ) {
            try await box.socket.send(text: text)
        }
    } catch {
        Task { await box.socket.abort(.transportAborted) }
        throw error
    }
}

func withTimeoutValue<T: Sendable>(
    seconds: TimeInterval,
    phase: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withNetworkDeadline(
        seconds: seconds,
        timeoutError: { RACPClientError.timedOut(phase) },
        operation: body
    )
}

/// 一次请求-响应的等待者：按 JSON-RPC `id` 关联，不按到达顺序（契约 §3 请求-响应关联）。
final class PendingRequest: @unchecked Sendable {
    let recoveryScope: RequestRecoveryScope?
    let method: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var settled: Result<JSONValue, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var sending = false
    private var sentAt: ContinuousClock.Instant?
    private var sentBytes: UInt64?
    private var abandonSend: (@Sendable () -> Void)?

    init(recoveryScope: RequestRecoveryScope? = nil, method: String? = nil) {
        self.recoveryScope = recoveryScope
        self.method = method
    }

#if DEBUG
    static func testing(method: String) -> PendingRequest {
        PendingRequest(recoveryScope: nil, method: method)
    }
#endif

    func resolve(_ result: Result<JSONValue, Error>) {
        finish(result, abandonIfSending: false)
    }

    private func finish(_ result: Result<JSONValue, Error>, abandonIfSending: Bool) {
        let completion = lock.withLock { () -> (CheckedContinuation<JSONValue, Error>?, [Task<Void, Never>], (@Sendable () -> Void)?)? in
            guard settled == nil else { return nil }
            settled = result
            let close = abandonIfSending && sending ? abandonSend : nil
            let completion = (continuation, tasks, close)
            continuation = nil
            tasks = []
            abandonSend = nil
            return completion
        }
        guard let (continuation, tasks, close) = completion else { return }
        tasks.forEach { $0.cancel() }
        // Start physical close before waking the caller, without joining cleanup
        // from the inbound reader that may have won the response race.
        close?()
        continuation?.resume(with: result)
    }

    private func didSend(progress: RACPReceiveProgress?) {
        lock.withLock {
            sending = false
            sentAt = .now
            sentBytes = progress?.snapshot().bytes
        }
    }

    /// The timer is armed before the independent sender starts. The send phase
    /// has a fixed deadline, even when unrelated bytes are arriving. Only the
    /// existing read/heartbeat whitelist can extend response idle time; its
    /// absolute ceiling always starts at the original request instant.
    func wait(
        timeout: TimeInterval,
        method: String,
        receiveProgress: RACPReceiveProgress? = nil,
        maximumDuration: TimeInterval = 120,
        send: (@Sendable () async throws -> Void)? = nil,
        abandonSend: (@Sendable () -> Void)? = nil
    ) async throws -> JSONValue {
        let started = ContinuousClock.now
        let interval = max(0, timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let existing = lock.withLock { () -> Result<JSONValue, Error>? in
                    if let settled { return settled }
                    self.continuation = continuation
                    self.sending = send != nil
                    self.abandonSend = abandonSend
                    if send == nil {
                        sentAt = started
                        sentBytes = receiveProgress?.snapshot().bytes
                    }
                    return nil
                }
                if let existing {
                    continuation.resume(with: existing)
                    return
                }
                let timer = Task { [weak self] in
                    let sendDeadline = started + .seconds(interval)
                    let absoluteDeadline = started + .seconds(
                        receiveProgress == nil ? interval : max(interval, maximumDuration)
                    )
                    var lastProgressAt = started
                    var observedBytes: UInt64?
                    while !Task.isCancelled {
                        guard let self else { return }
                        let phase = self.lock.withLock { (self.sending, self.sentAt, self.sentBytes) }
                        if !phase.0, let sentAt = phase.1 {
                            // Discard all progress observed before send completed.
                            if observedBytes == nil {
                                observedBytes = phase.2
                                lastProgressAt = max(lastProgressAt, sentAt)
                            }
                            if let receiveProgress {
                                let progress = receiveProgress.snapshot()
                                if progress.bytes != observedBytes {
                                    observedBytes = progress.bytes
                                    lastProgressAt = max(sentAt, progress.lastReceivedAt ?? sentAt)
                                }
                            }
                        }
                        let deadline = phase.0 ? sendDeadline
                            : min(absoluteDeadline, lastProgressAt + .seconds(interval))
                        if ContinuousClock.now >= deadline {
                            self.finish(.failure(RACPClientError.timedOut(method)), abandonIfSending: true)
                            return
                        }
                        do { try await Task.sleep(until: deadline, clock: .continuous) }
                        catch { return }
                    }
                }
                var workers = [timer]
                if let send {
                    workers.append(Task { [self] in
                        guard !Task.isCancelled else { return }
                        do {
                            try await send()
                            didSend(progress: receiveProgress)
                        } catch {
                            finish(.failure(error), abandonIfSending: true)
                        }
                    })
                }
                let completed = lock.withLock { () -> Bool in
                    guard settled == nil else { return true }
                    tasks = workers
                    return false
                }
                if completed { workers.forEach { $0.cancel() } }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), abandonIfSending: true)
        }
    }
}

/// `turn/interrupt` / `turn/cancel` 按 `turnId` 寻址（契约 §3.1）。
/// v2 契约（`docs/api/pi-adaptor.md` §2）要求所有写操作携带 `context`，因此这里带上
/// `requestId`（每次唯一），与其它写操作一致，便于去重与链路追踪。
struct RACPTurnIDParams: Encodable, Sendable {
    var turnId: String
    var context: RACPContext
}

// MARK: - 有界关闭

/// 只持有旧连接资源，负责在 1s 预算内尽力关闭。
///
/// 单独成类型是为了让 `boundedAsyncValue` 的 `@Sendable` 闭包只捕获这个
/// `@unchecked Sendable` 盒子，而不是把 actor 状态或非 Sendable 的 socket 带出去。
final class OldConnectionCloser: @unchecked Sendable {
    private let connection: RACPConnection?
    private let socket: (any RACPSocket)?
    private let transport: SSHTransport?

    init(connection: RACPConnection?, socket: (any RACPSocket)?, transport: SSHTransport?) {
        self.connection = connection
        self.socket = socket
        self.transport = transport
    }

    func close() async {
        if let connection {
            await connection.close()
        } else {
            await socket?.close()
            await transport?.close()
        }
    }
}
