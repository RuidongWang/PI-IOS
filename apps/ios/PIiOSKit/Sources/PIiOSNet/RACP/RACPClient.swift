import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

public actor RACPClient {
    /// Upper bound for events buffered while an attach snapshot is rebuilt.
    static let maxBufferedSessionEventsDuringAttach = 10_000

    let configuration: RACPConfiguration
    let confirmer: any HostKeyConfirming
    let backoff: ReconnectBackoff
    let budgets: RACPConnectionBudgets
    let connectionFactory: any RACPConnectionFactory
    /// Bootstrap 已经建立并持有 SSH 连接时必须复用它，不能为配对/校验再开第二条连接。
    let suppliedTransport: SSHTransport?
    let updates: AsyncStream<RACPClientUpdate>
    let continuation: AsyncStream<RACPClientUpdate>.Continuation
    static let updateCapacity = 512
    var updateStreamOverloaded = false
    let statusUpdates: AsyncStream<ConnectionStatus>
    let statusContinuation: AsyncStream<ConnectionStatus>.Continuation
    let sessionChangeClientID = UUID()
    var sessionChangeCoalescingEnabled = false
    var sessionChangeDelivery = SessionChangeDelivery()
    var runTask: Task<Void, Never>?
    var subscriptionTerminalReason: String?

    var connection: RACPConnection?
    var transport: SSHTransport?
    var socket: (any RACPSocket)?
    var serverInfo: RACPServerInfo?
    var state: RACPTunnelState = .offline(reason: nil)
    var status = ConnectionStatus()
    var heartbeatFailureGeneration: UUID?
    var promotionFenced = false
    /// 当前连接意图的非秘密诊断标识与起点（用于阶段耗时）。
    var attemptIntent: String?
    var attemptStartedAt: ContinuousClock.Instant?

    var nextRequestId = 1
    var pending: [RACPIdentifier: PendingRequest] = [:]

    let viewModel = SessionViewModel()
    var attachedSession: RACPSessionSummary?
    var sessionId: String?
    var subscriptionId: String?
    var subscribedSessionId: String?
    var sessionAttachGeneration = 0
    var historyRequest: (id: UUID, attach: Int, snapshot: UInt64, socket: ObjectIdentifier)?
    var sessionEventsSuspended = false
    /// Visible publication is independent from transport-event suspension. The token
    /// lets an old attach clear only its own suspension after a newer attach starts.
    var initialHistoryPublicationSuspension: (id: UUID, attach: Int)?
    var pendingSessionSubscriptionAttempt: UUID?
    var pendingSessionSubscriptionSessionId: String?
    var pendingSessionSubscriptionGeneration: Int?
    var pendingSessionAckDuringSubscribe: Int?
    var isHostSubscriptionPending = false
    var pendingHostAckDuringSubscribe: Int?
    var isRebuildingSnapshot = false
    var bufferedSessionEventsDuringAttach: [RACPEvent] = []
    var rebuildingSnapshots: Set<String> = []
    var hostSubscription = RACPHostSubscriptionTracker()
    var pendingHostAck: PendingEventAck?
    var isDrainingHostAcks = false
    var pendingSessionAck: PendingEventAck?
    var isDrainingSessionAcks = false
    public init(
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        backoff: ReconnectBackoff = ReconnectBackoff(),
        budgets: RACPConnectionBudgets = .default
    ) {
        self.configuration = configuration
        self.confirmer = confirmer
        self.backoff = backoff
        self.budgets = budgets
        self.connectionFactory = LiveRACPConnectionFactory()
        self.suppliedTransport = nil
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate>(bufferingPolicy: .bufferingOldest(Self.updateCapacity)) { sink = $0 }
        self.continuation = sink
        var statusSink: AsyncStream<ConnectionStatus>.Continuation!
        self.statusUpdates = AsyncStream<ConnectionStatus>(bufferingPolicy: .bufferingOldest(64)) { statusSink = $0 }
        self.statusContinuation = statusSink
    }

    /// 可注入连接器属于传输测试/后续 candidate 协调边界；生产仍使用 Live factory。
    init(
        configuration: RACPConfiguration,
        connectionFactory: any RACPConnectionFactory,
        budgets: RACPConnectionBudgets = .default,
        backoff: ReconnectBackoff = ReconnectBackoff()
    ) {
        self.configuration = configuration
        self.confirmer = SuppliedTransportHostKeyConfirmer()
        self.backoff = backoff
        self.budgets = budgets
        self.connectionFactory = connectionFactory
        self.suppliedTransport = nil
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate>(bufferingPolicy: .bufferingOldest(Self.updateCapacity)) { sink = $0 }
        self.continuation = sink
        var statusSink: AsyncStream<ConnectionStatus>.Continuation!
        self.statusUpdates = AsyncStream<ConnectionStatus>(bufferingPolicy: .bufferingOldest(64)) { statusSink = $0 }
        self.statusContinuation = statusSink
    }

    init(
        suppliedTransport: SSHTransport,
        hostPort: Int,
        deviceToken: String,
        clientVersion: String
    ) {
        // The SSH request is never used for this instance. Keeping it structurally
        // valid lets the one-shot path share the normal request/handshake machinery.
        self.configuration = RACPConfiguration(
            ssh: SSHConnectionRequest(
                host: "127.0.0.1",
                port: 22,
                username: "",
                credential: .password(""),
                pinnedHostKey: nil
            ),
            hostPort: hostPort,
            deviceToken: deviceToken,
            clientVersion: clientVersion
        )
        self.confirmer = SuppliedTransportHostKeyConfirmer()
        self.backoff = ReconnectBackoff()
        self.budgets = .default
        self.connectionFactory = LiveRACPConnectionFactory()
        self.suppliedTransport = suppliedTransport
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate>(bufferingPolicy: .bufferingOldest(Self.updateCapacity)) { sink = $0 }
        self.continuation = sink
        var statusSink: AsyncStream<ConnectionStatus>.Continuation!
        self.statusUpdates = AsyncStream<ConnectionStatus>(bufferingPolicy: .bufferingOldest(64)) { statusSink = $0 }
        self.statusContinuation = statusSink
    }

#if DEBUG
    init(
        testingSocket: any RACPSocket,
        subscriptionId: String?,
        subscribedSessionId: String?
    ) {
        self.configuration = RACPConfiguration(
            ssh: SSHConnectionRequest(
                host: "127.0.0.1",
                port: 22,
                username: "",
                credential: .password(""),
                pinnedHostKey: nil
            ),
            hostPort: 1,
            deviceToken: nil
        )
        self.confirmer = SuppliedTransportHostKeyConfirmer()
        self.backoff = ReconnectBackoff()
        self.budgets = .default
        self.connectionFactory = LiveRACPConnectionFactory()
        self.suppliedTransport = nil
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate>(bufferingPolicy: .bufferingOldest(Self.updateCapacity)) { sink = $0 }
        self.continuation = sink
        var statusSink: AsyncStream<ConnectionStatus>.Continuation!
        self.statusUpdates = AsyncStream<ConnectionStatus>(bufferingPolicy: .bufferingOldest(64)) { statusSink = $0 }
        self.statusContinuation = statusSink
        self.socket = testingSocket
        self.state = .online
        self.status.phase = .online(.ssh)
        self.status.activeRoute = .ssh
        self.status.activeGeneration = UUID()
        self.subscriptionId = subscriptionId
        self.subscribedSessionId = subscribedSessionId
        self.sessionId = subscribedSessionId
    }

    func receiveForTesting(_ data: Data) async {
        guard let socket else { return }
        await receive(data, from: socket)
    }

    func pendingRequestCountForTesting() -> Int {
        pending.count
    }

    func emitUpdateForTesting(_ update: RACPClientUpdate) async {
        await emit(update)
    }

    func sessionChangeDeliveryStatisticsForTesting() -> SessionChangeDelivery.Statistics {
        sessionChangeDelivery.statistics
    }

    func verifyDeviceIdentityForTesting() async throws -> RACPDeviceIdentity {
        serverInfo = RACPServerInfo(
            protocolVersion: RACPInitializeParams.protocolVersion,
            serverName: "test",
            serverVersion: "1",
            hostId: "initialize-untrusted",
            connectionId: "test",
            roles: ["owner"]
        )
        await emitPhase(.verifyingIdentity(.ssh))
        return try await authenticatedDeviceIdentity()
    }

    public func setOnlineForTesting() {
        state = .online
        status.phase = .online(.ssh)
        status.activeRoute = .ssh
        status.activeGeneration = UUID()
        statusContinuation.yield(status)
    }

    public func setOfflineForTesting() {
        state = .offline(reason: nil)
        status.phase = .offline
        status.activeRoute = nil
        status.activeGeneration = nil
        statusContinuation.yield(status)
    }

    func setSessionSubscriptionForTesting(_ id: String?) {
        subscriptionId = id
    }

    func enqueueSessionAckForTesting(subscriptionId: String, sequence: Int) async {
        guard let socket else { return }
        await queueSessionAck(
            PendingEventAck(subscriptionId: subscriptionId, sequence: sequence),
            from: socket
        )
    }
#endif

    // MARK: 生命周期

    /// 启动连接循环，返回状态/事件流。重复调用返回同一个流。
    @discardableResult
    public func start() -> AsyncStream<RACPClientUpdate> {
        if runTask == nil {
            runTask = Task { [weak self] in
                await self?.runLoop()
            }
        }
        return updates
    }

    /// 只取状态/事件流，不启动连接（用于界面先订阅再决定何时连）。
    public func stream() -> AsyncStream<RACPClientUpdate> { updates }

    /// Opt in only when the single stream consumer uses begin/finish below.
    /// Legacy consumers keep lossless direct delivery by default. The catch-up
    /// signal also covers changes queued before the consumer enabled coalescing.
    func yieldSessionChangeSignal() {
        if yieldUpdate(.sessionChanged) { return }
        sessionChangeDelivery.rollbackPending(sessionChangeKey)
    }

    @discardableResult
    func yieldUpdate(_ update: RACPClientUpdate) -> Bool {
        guard !updateStreamOverloaded else { return false }
        guard case .enqueued(let remaining) = continuation.yield(update) else { return false }
        if remaining == 1 {
            updateStreamOverloaded = true
            state = .updateBacklog
            continuation.yield(.state(state))
            continuation.finish()
            runTask?.cancel()
            Task { await stopBestEffort() }
        }
        return true
    }

    public func enableSessionChangeCoalescing() {
        guard !sessionChangeCoalescingEnabled else { return }
        sessionChangeCoalescingEnabled = true
        guard initialHistoryPublicationSuspension == nil else { return }
        if sessionChangeDelivery.invalidate(sessionChangeKey) {
            yieldSessionChangeSignal()
        }
    }

    /// Called when a payload-free sessionChanged signal is taken from the stream.
    /// A nil receipt is a revoked/redundant queued signal and can be skipped.
    public func beginSessionChangeConsumption() -> UUID? {
        if initialHistoryPublicationSuspension != nil {
            if sessionChangeCoalescingEnabled {
                // The stream signal has already been consumed by the caller. Drop
                // exactly its revoked receipt placeholder, but never expose a receipt
                // or allow it to suppress the final post-backfill publication.
                _ = sessionChangeDelivery.begin(sessionChangeKey)
                sessionChangeDelivery.revoke()
            }
            return nil
        }
        guard sessionChangeCoalescingEnabled else { return UUID() }
        return sessionChangeDelivery.begin(sessionChangeKey)
    }

    /// Must run after refreshing the view/cache. Changes arriving during that
    /// work cause another delivery; an obsolete generation/session receipt is inert.
    public func finishSessionChangeConsumption(_ receipt: UUID) {
        guard sessionChangeCoalescingEnabled,
              initialHistoryPublicationSuspension == nil else { return }
        if sessionChangeDelivery.finish(receipt, key: sessionChangeKey) {
            yieldSessionChangeSignal()
        }
    }

    var sessionChangeKey: SessionChangeDelivery.Key {
        SessionChangeDelivery.Key(
            client: sessionChangeClientID,
            generation: status.activeGeneration ?? status.candidateGeneration,
            session: sessionId ?? subscribedSessionId,
            attachmentGeneration: sessionAttachGeneration
        )
    }

}
