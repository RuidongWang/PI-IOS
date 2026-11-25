import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

extension RACPClient {
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        heartbeatFailureGeneration = nil
        await teardown(reason: nil)
        status.phase = .offline
        status.activeRoute = nil
        status.activeGeneration = nil
        status.candidateGeneration = nil
        statusContinuation.yield(status)
        continuation.finish()
        statusContinuation.finish()
    }

    /// Bounded cleanup for recovery paths. `teardown` ultimately closes SSH/NIO
    /// resources whose close futures may not cooperate with task cancellation.
    @discardableResult
    public func stopBestEffort(timeout: TimeInterval = 1) async -> Bool {
        runTask?.cancel()
        runTask = nil
        let completed = await boundedAsyncValue(seconds: timeout) { [self] in
            await self.finishStopBestEffort()
            return true
        }
        if completed != true {
            // Make the update stream terminal even if an underlying close future
            // continues in the background. No caller waits for that orphaned close.
            continuation.finish()
            statusContinuation.finish()
        }
        return completed == true
    }

    func finishStopBestEffort() async {
        await teardown(reason: nil)
        status.phase = .offline
        status.activeRoute = nil
        status.activeGeneration = nil
        status.candidateGeneration = nil
        statusContinuation.yield(status)
        continuation.finish()
        statusContinuation.finish()
    }

    public func currentState() -> RACPTunnelState { state }
    public func connectionStatus() -> ConnectionStatus { status }
    public func statusStream() -> AsyncStream<ConnectionStatus> { statusUpdates }
    public func info() -> RACPServerInfo? { serverInfo }

    /// Pauses only new business writes and heartbeat on the old active route.
    /// Socket reads, events, ACKs and read-only catalog requests remain live.
    public func setPromotionFenced(_ fenced: Bool) {
        promotionFenced = fenced
        status.promotionFenced = fenced
        statusContinuation.yield(status)
    }

    /// 使用一次性配对令牌完成单次交换。调用者必须持久化结果，随后用设备令牌重建连接。
    /// 此方法不会重试：超时可能意味着令牌已被消费，不能盲目再次交换。
    public func pairOnce(deviceLabel: String? = nil) async throws -> RACPPairResult {
        guard runTask == nil, transport == nil, let token = configuration.deviceToken,
              token.hasPrefix("ppt2."),
              !token.contains(where: { $0.isWhitespace }) else {
            throw RACPClientError.protocolMismatch("需要有效的一次性配对令牌且连接必须处于空闲状态")
        }
        do {
            try await establish()
            let result: RACPPairResult = try await request(.pair, params: RACPPairParams(deviceLabel: deviceLabel))
            guard !result.deviceId.isEmpty,
                  result.deviceToken.hasPrefix("pdt2.") else {
                throw RACPClientError.malformedFrame("配对响应缺少有效设备凭证")
            }
            await teardown(reason: nil)
            state = .offline(reason: nil)
            return result
        } catch {
            await teardown(reason: nil)
            state = .offline(reason: nil)
            throw error
        }
    }

    /// Runs `connection/initialize` + `connection/pair` on the caller-owned SSH
    /// transport used by bootstrap. The transport remains open for the next
    /// polling step; only the RACP WebSocket child channel is closed.
    public static func pairOnce(
        using transport: SSHTransport,
        hostPort: Int,
        pairingToken: String,
        clientVersion: String = "0.0.1",
        deviceLabel: String? = nil
    ) async throws -> RACPPairResult {
        guard (1...65_535).contains(hostPort),
              let token = RACPPairingToken.normalize(pairingToken) else {
            throw RACPClientError.protocolMismatch("需要有效的 PI-adaptor 端口与一次性配对令牌")
        }
        let client = RACPClient(
            suppliedTransport: transport,
            hostPort: hostPort,
            deviceToken: token,
            clientVersion: clientVersion
        )
        return try await client.pairOnceOnSuppliedTransport(deviceLabel: deviceLabel)
    }

    /// Reconnects RACP with the newly issued device token on the same bootstrap
    /// SSH transport, then verifies the round trip with `connection/ping`.
    public static func verifyDevice(
        using transport: SSHTransport,
        hostPort: Int,
        deviceToken: String,
        clientVersion: String = "0.0.1"
    ) async throws -> RACPServerInfo {
        guard (1...65_535).contains(hostPort),
              !deviceToken.isEmpty,
              !deviceToken.contains(where: \.isWhitespace) else {
            throw RACPClientError.protocolMismatch("需要有效的 PI-adaptor 端口与设备令牌")
        }
        let client = RACPClient(
            suppliedTransport: transport,
            hostPort: hostPort,
            deviceToken: deviceToken,
            clientVersion: clientVersion
        )
        return try await client.verifyDeviceOnSuppliedTransport()
    }

    /// Bootstrap-only trusted identity proof. Unlike legacy verifyDevice, this
    /// requires the authenticated ping's pong + hostId; initialize.hostId is only diagnostic.
    public static func verifyDeviceIdentity(
        using transport: SSHTransport,
        hostPort: Int,
        deviceToken: String,
        clientVersion: String = "0.0.1"
    ) async throws -> RACPDeviceIdentity {
        guard (1...65_535).contains(hostPort),
              !deviceToken.isEmpty,
              !deviceToken.contains(where: \.isWhitespace) else {
            throw RACPClientError.protocolMismatch("需要有效的 PI-adaptor 端口与设备令牌")
        }
        let client = RACPClient(
            suppliedTransport: transport,
            hostPort: hostPort,
            deviceToken: deviceToken,
            clientVersion: clientVersion
        )
        return try await client.verifyDeviceIdentityOnSuppliedTransport()
    }

    func pairOnceOnSuppliedTransport(
        deviceLabel: String?
    ) async throws -> RACPPairResult {
        guard suppliedTransport != nil,
              configuration.deviceToken?.hasPrefix("ppt2.") == true else {
            throw RACPClientError.protocolMismatch("一次性配对需要 bootstrap 提供的 SSH 连接")
        }
        do {
            try await establish()
            let result: RACPPairResult = try await request(
                .pair,
                params: RACPPairParams(deviceLabel: deviceLabel)
            )
            guard !result.deviceId.isEmpty,
                  result.deviceToken.hasPrefix("pdt2.") else {
                throw RACPClientError.malformedFrame("配对响应缺少有效设备凭证")
            }
            await closeWebSocketPreservingTransport()
            return result
        } catch {
            await closeWebSocketPreservingTransport()
            throw error
        }
    }

    func verifyDeviceOnSuppliedTransport() async throws -> RACPServerInfo {
        guard suppliedTransport != nil else {
            throw RACPClientError.protocolMismatch("设备校验需要 bootstrap 提供的 SSH 连接")
        }
        do {
            try await establish()
            await emitPhase(.authenticating(.ssh))
            await emitPhase(.verifyingIdentity(.ssh))
            try await ping()
            guard let serverInfo else {
                throw RACPClientError.malformedFrame("设备校验未取得 PI-adaptor 信息")
            }
            await closeWebSocketPreservingTransport()
            return serverInfo
        } catch {
            await closeWebSocketPreservingTransport()
            throw error
        }
    }

    func verifyDeviceIdentityOnSuppliedTransport() async throws -> RACPDeviceIdentity {
        guard suppliedTransport != nil else {
            throw RACPClientError.protocolMismatch("设备身份校验需要 bootstrap 提供的 SSH 连接")
        }
        do {
            try await establish()
            await emitPhase(.authenticating(.ssh))
            await emitPhase(.verifyingIdentity(.ssh))
            let identity = try await authenticatedDeviceIdentity()
            await closeWebSocketPreservingTransport()
            return identity
        } catch {
            await closeWebSocketPreservingTransport()
            throw error
        }
    }

    func authenticatedDeviceIdentity() async throws -> RACPDeviceIdentity {
        let hostId = try await authenticatedHostId()
        guard let serverInfo else { throw RACPConnectionError(category: .hostIdentity) }
        return RACPDeviceIdentity(serverInfo: serverInfo, adaptorHostId: hostId)
    }

    /// Returns the Host identity proven by the authenticated Ping response.
    public func authenticatedHostId(timeout: TimeInterval = 20) async throws -> String {
        let result: RACPAuthenticatedPingResult = try await request(
            .ping,
            params: RACPEmptyParams(),
            timeout: timeout
        )
        guard result.ok == true,
              result.pong == true,
              let hostId = result.hostId,
              !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RACPConnectionError(category: .hostIdentity) }
        return hostId
    }


    // MARK: 连接循环

    func runLoop() async {
        var sshAttempt = 0
        var connectionStageFailures = 0
        var route: ConnectionRoute = configuration.connectionPreference == .directPreferred
            && suppliedTransport == nil ? .direct : .ssh
        var didStartSSHFallback = false

        while !Task.isCancelled {
            let generation = UUID()
            let attemptRoute = route
            attemptIntent = ConnectionDiagnostics.shortID(generation)
            attemptStartedAt = ContinuousClock.now
            do {
                let connectBudget = attemptRoute == .direct ? budgets.directConnect : budgets.sshConnect
                ConnectionDiagnostics.shared.record(
                    kind: .phase,
                    intent: attemptIntent,
                    route: attemptRoute,
                    phase: "attempt.start",
                    budgetSeconds: connectBudget
                )
                try await withTimeoutValue(seconds: connectBudget, phase: "RACP 建连与身份验证") {
                    try await self.establish(route: attemptRoute, generation: generation)
                    try await self.verifyIdentity(route: attemptRoute, generation: generation)
                }
                try await withTimeoutValue(seconds: budgets.restore, phase: "RACP 恢复") {
                    try await self.restore(route: attemptRoute, generation: generation)
                }
                guard let socket, status.candidateGeneration == generation else {
                    throw RACPConnectionError(category: .canceled)
                }
                sshAttempt = 0
                connectionStageFailures = 0
                status.activeGeneration = generation
                status.candidateGeneration = nil
                heartbeatFailureGeneration = nil
                await emitPhase(.online(route))
                let heartbeat = Task { [weak self] in
                    await self?.heartbeatLoop(expectedSocket: socket, generation: generation)
                }
                let termination = await socket.terminationError
                heartbeat.cancel()
                if heartbeatFailureGeneration == generation {
                    throw RACPConnectionError(category: .heartbeatFailed)
                }
                throw termination
            } catch is CancellationError {
                await teardown(reason: nil)
                return
            } catch {
                if Task.isCancelled {
                    await teardown(reason: nil)
                    return
                }
                let failedPhase = status.phase
                let category = Self.connectionCategory(error, route: route)
                recordFailure(route: route, phase: failedPhase, category: category, error: error)
                let reason = Self.describe(error)
                await teardown(reason: reason, failing: error)
                if let terminalReason = subscriptionTerminalReason {
                    await emitPhase(.failed)
                    await emit(.state(.offline(reason: terminalReason)))
                    continuation.finish()
                    statusContinuation.finish()
                    return
                }

                if route == .direct,
                   !didStartSSHFallback,
                   Self.isTransportFailure(category, error: error) {
                    // 每 intent 仅进入一次；此后 SSH backoff 永远不再重评 direct。
                    didStartSSHFallback = true
                    route = .ssh
                    await emitPhase(.fallingBack)
                    continue
                }

                let terminalCategory = Self.isTerminalConnectionCategory(category)
                if route == .direct || terminalCategory || isFatal(error) {
                    await emitPhase(.failed)
                    continuation.finish()
                    statusContinuation.finish()
                    return
                }

                if Self.isConnectionStageFailure(error) {
                    connectionStageFailures += 1
                    if connectionStageFailures >= Self.maxConnectionStageFailures {
                        await emitPhase(.failed)
                        await emit(.state(.offline(
                            reason: reason
                                + "\n连续 \(connectionStageFailures) 次在建立 SSH 通道阶段失败，已停止自动重连。"
                                + "先修服务器（端口/sshd/限流）再点「连接」。"
                        )))
                        continuation.finish()
                        statusContinuation.finish()
                        return
                    }
                } else {
                    connectionStageFailures = 0
                }
                sshAttempt += 1
                let delay = backoff.delay(forAttempt: sshAttempt)
                await emitPhase(.reconnecting(.ssh, attempt: sshAttempt, delay: delay))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func heartbeatLoop(expectedSocket: any RACPSocket, generation: UUID) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard self.socket === expectedSocket,
                  status.activeGeneration == generation,
                  state.isOnline
            else { return }
            if promotionFenced { continue }
            do {
                _ = try await requestJSON(
                    .ping,
                    params: RACPEmptyParams(),
                    timeout: 5,
                    allowReceiveProgress: true
                )
                consecutiveFailures = 0
            } catch {
                guard !Task.isCancelled, self.socket === expectedSocket else { return }
                consecutiveFailures += 1
                if consecutiveFailures >= 2 {
                    heartbeatFailureGeneration = generation
                    await expectedSocket.abort(.transportAborted)
                    return
                }
            }
        }
    }

    /// 连续多少次「建立通道阶段」失败后停止自动重连。
    static let maxConnectionStageFailures = 3

    /// 是不是“再怎么重试也一样”的失败：认证失败、端口无人监听、主机密钥不被接受。
    ///
    /// `.closedByPeer` **不在此列**：移动网络切换、NAT 超时与 sshd `MaxStartups` 造成的
    /// 握手期 EOF 都是瞬时的，把它算成确定性失败会让一次网络抖动在三次之后永久停连，
    /// 只能靠用户手点「连接」恢复。上限仍然是 `maxConnectionStageFailures = 3`。
    static func isConnectionStageFailure(_ error: Error) -> Bool {
        guard let error = error as? SSHTransportError else { return false }
        switch error {
        case .authenticationFailed, .tunnelRefused, .hostKeyAlgorithmUnsupported, .hostKeyUnreadable:
            return true
        case .closedByPeer, .invalidPrivateKey, .hostKeyRejected, .timedOut, .channelClosed, .networkFailure,
             .outputLimitExceeded:
            return false
        }
    }

    func establish(
        route: ConnectionRoute = .ssh,
        generation requestedGeneration: UUID? = nil
    ) async throws {
        let generation = requestedGeneration ?? UUID()
        status.candidateGeneration = generation
        await emitPhase(.connecting(route))
        let newConnection = try await connectionFactory.makeConnection(
            route: route,
            configuration: configuration,
            confirmer: confirmer,
            suppliedTransport: suppliedTransport
        )
        guard status.candidateGeneration == generation else {
            await newConnection.close()
            throw RACPConnectionError(category: .canceled)
        }
        connection = newConnection
        transport = newConnection.transport
        let socket = newConnection.socket
        self.socket = socket
        let reader = Task { [weak self] in
            await RACPInboundContext.$socketID.withValue(ObjectIdentifier(socket)) {
                for await message in socket.inbound {
                    await self?.receive(message, from: socket)
                }
            }
        }
        socket.registerInboundReader(reader)
        await emitPhase(.handshaking(route))
        try await handshake()
    }

    func verifyIdentity(route: ConnectionRoute, generation: UUID) async throws {
        guard status.candidateGeneration == generation else {
            throw RACPConnectionError(category: .canceled)
        }
        if route == .direct,
           serverInfo?.capabilities?.value(at: ["directTransport"])?.boolValue != true {
            throw RACPConnectionError(category: .protocol)
        }
        await emitPhase(.authenticating(route))
        await emitPhase(.verifyingIdentity(route))
        let result: RACPAuthenticatedPingResult = try await request(
            .ping,
            params: RACPEmptyParams(),
            timeout: 20
        )
        // 旧 sshOnly adaptor 允许只有 ok/serverTime；direct 与 directPreferred 的 SSH
        // 回退必须严格检查 pong + 认证 ping.hostId，initialize.hostId 不作信任依据。
        guard route == .direct || configuration.connectionPreference == .directPreferred else {
            return
        }
        guard let expected = configuration.direct?.adaptorHostId,
              !expected.isEmpty
        else { throw RACPConnectionError(category: .configuration) }
        guard result.ok == true,
              result.pong == true,
              let hostId = result.hostId,
              !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hostId == expected
        else { throw RACPConnectionError(category: .hostIdentity) }
    }

    func restore(route: ConnectionRoute, generation: UUID) async throws {
        guard status.candidateGeneration == generation else {
            throw RACPConnectionError(category: .canceled)
        }
        await emitPhase(.restoring(route))
        // 订阅恢复仍使用原有 cursor、ACK 与快照逻辑，不能另建业务状态。
        try await subscribeHost()
        if let sessionId = subscribedSessionId {
            try await subscribeSession(sessionId: sessionId, after: viewModel.cursor)
        }
    }

    /// 契约 §2.2：10 秒内完成 `connection/initialize` + `notifications/initialized`。
    func handshake() async throws {
        let params = RACPInitializeParams(
            client: RACPClientInfo(version: configuration.clientVersion)
        )
        let result: JSONValue = try await withTimeoutValue(seconds: 10, phase: "RACP 握手") {
            try await self.requestJSON(.initialize, params: params, timeout: 10)
        }
        let info = try RACPInitializeResult.decoded(from: result).serverInfo()
        guard info.protocolVersion == RACPInitializeParams.protocolVersion else {
            throw RACPClientError.protocolMismatch("协议版本 \(info.protocolVersion)")
        }
        serverInfo = info
        let notification = RACPNotification(method: .initializedNotification, params: RACPEmptyParams())
        let data = try JSONEncoder().encode(notification)
        guard let text = String(data: data, encoding: .utf8), let socket else {
            throw RACPClientError.malformedFrame("初始化通知编码失败")
        }
        try await sendRACPMessageWithDeadline(
            text,
            to: socket,
            timeout: 10,
            phase: "RACP 初始化通知"
        )
        // ready 只表示 initialize 完成；online 必须由认证 ping + host/session 恢复后发布。
        await emit(.ready(info))
    }

    func teardown(reason: String?, failing error: Error? = nil) async {
        // Phase 1：先同步失效所有指针与 generation（不 await）。
        // 失败路径不能被 EventLoopFuture.get() 这类不响应取消的关闭操作卡住，
        // 旧 generation 必须在进入 Phase 2 之前就不可用（契约 §7.2 资源关闭 best-effort）。
        let oldConnection = connection
        connection = nil
        let oldSocket = socket
        socket = nil
        let oldTransport = transport
        transport = nil
        subscriptionId = nil
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        isHostSubscriptionPending = false
        pendingHostAckDuringSubscribe = nil
        hostSubscription.prepareForReconnect()
        pendingHostAck = nil
        isDrainingHostAcks = false
        pendingSessionAck = nil
        isDrainingSessionAcks = false
        serverInfo = nil
        status.activeRoute = nil
        status.activeGeneration = nil
        status.candidateGeneration = nil
        sessionChangeDelivery.revoke()
        failAllPending(with: error ?? RACPClientError.notConnected)
        if !state.isOnline || reason != nil {
            await emit(.state(.offline(reason: reason)))
        }

        // Phase 2：有界关闭，最多等 1s。超时只是放弃等待，资源由底层自行收尾。
        let started = ContinuousClock.now
        await Self.closeBounded(
            connection: oldConnection,
            socket: oldSocket,
            transport: oldTransport
        )
        ConnectionDiagnostics.shared.record(
            kind: .teardown,
            intent: attemptIntent,
            elapsedMs: ConnectionDiagnostics.milliseconds(since: started),
            detail: "teardown"
        )
    }

    /// 旧连接关闭最多等 1s；调用点必须已经同步失效 generation。
    static func closeBounded(
        connection: RACPConnection?,
        socket: (any RACPSocket)?,
        transport: SSHTransport?
    ) async {
        let closer = OldConnectionCloser(
            connection: connection,
            socket: socket,
            transport: transport
        )
        _ = await boundedAsyncValue(seconds: 1) {
            await closer.close()
            return true
        }
    }

    /// One-shot bootstrap calls must leave the SSH connection open so the
    /// runner can continue polling and then use the same transport to verify
    /// the device token.
    func closeWebSocketPreservingTransport() async {
        let oldConnection = connection
        connection = nil
        let socket = self.socket
        self.socket = nil
        subscriptionId = nil
        subscribedSessionId = nil
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        isHostSubscriptionPending = false
        pendingHostAckDuringSubscribe = nil
        hostSubscription.prepareForReconnect()
        pendingHostAck = nil
        isDrainingHostAcks = false
        pendingSessionAck = nil
        isDrainingSessionAcks = false
        serverInfo = nil
        state = .offline(reason: nil)
        status.phase = .offline
        status.activeRoute = nil
        status.activeGeneration = nil
        status.candidateGeneration = nil
        if let oldConnection {
            await oldConnection.closeSocket()
        } else {
            await socket?.close()
        }
        failAllPending(with: RACPClientError.notConnected)
    }

    func failAllPending(with error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters {
            waiter.resolve(.failure(error))
        }
    }


    func emit(_ update: RACPClientUpdate) async {
        if case let .state(newState) = update {
            state = newState
        }
        // Suppress before both coalescer invalidation and continuation.yield: no
        // queued signal may expose an incomplete initial candidate snapshot.
        if case .sessionChanged = update, initialHistoryPublicationSuspension != nil {
            return
        }
        if case .sessionChanged = update, sessionChangeCoalescingEnabled {
            guard sessionChangeDelivery.invalidate(sessionChangeKey) else { return }
        }
        // Reliable updates are always yielded directly, in their original order.
        continuation.yield(update)
    }

    func emitPhase(_ phase: ConnectionPhase) async {
        status.phase = phase
        ConnectionDiagnostics.shared.record(
            kind: .phase,
            intent: attemptIntent,
            route: phase.diagnosticRoute,
            phase: phase.diagnosticName,
            elapsedMs: attemptStartedAt.map { ConnectionDiagnostics.milliseconds(since: $0) }
        )
        switch phase {
        case .offline:
            await emit(.state(.offline(reason: nil)))
        case .connecting, .fallingBack:
            await emit(.state(.connecting))
        case .handshaking, .restoring:
            await emit(.state(.handshaking))
        case .authenticating, .verifyingIdentity:
            await emit(.state(.authenticating))
        case .online(let route):
            status.activeRoute = route
            await emit(.state(.online))
        case .reconnecting(_, let attempt, let delay):
            let reason = status.sshFailure.map { "SSH: \($0.category.rawValue)" }
            await emit(.state(.reconnecting(attempt: attempt, delay: delay, reason: reason ?? "SSH reconnect")))
        case .failed:
            var reasons: [String] = []
            if let direct = status.directFailure { reasons.append("direct: \(direct.category.rawValue)") }
            if let ssh = status.sshFailure { reasons.append("SSH: \(ssh.category.rawValue)") }
            await emit(.state(.offline(reason: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))))
        }
        statusContinuation.yield(status)
    }

    func recordFailure(
        route: ConnectionRoute,
        phase: ConnectionPhase,
        category: ConnectionFailureCategory,
        error: Error
    ) {
        let failure = RouteFailure(
            route: route,
            phase: phase,
            category: category,
            retryAfterMs: (error as? RACPConnectionError)?.retryAfterMs
        )
        switch route {
        case .direct: status.directFailure = failure
        case .ssh: status.sshFailure = failure
        }
        var isBudgetExpiry = false
        if case RACPClientError.timedOut = error { isBudgetExpiry = true }
        ConnectionDiagnostics.shared.record(
            kind: .failure,
            intent: attemptIntent,
            route: route,
            phase: phase.diagnosticName,
            elapsedMs: attemptStartedAt.map { ConnectionDiagnostics.milliseconds(since: $0) },
            category: category,
            httpStatus: (error as? RACPConnectionError)?.httpStatus,
            closeCode: (error as? RACPSocketTermination)?.closeCode,
            detail: isBudgetExpiry ? "budget-expired" : nil
        )
    }

    static func isTransportFailure(_ category: ConnectionFailureCategory, error: Error) -> Bool {
        switch category {
        case .dns, .tcp, .connectTimeout, .socketInterrupted, .heartbeatFailed:
            return true
        case .internal:
            // 仅 Upgrade 阶段明确 503 属于通路故障；Live direct 将 502/503/504 映射 tcp。
            return (error as? RACPConnectionError)?.httpStatus == 503
        default:
            return false
        }
    }

    static func isTerminalConnectionCategory(_ category: ConnectionFailureCategory) -> Bool {
        switch category {
        case .configuration, .offline, .tlsTrust, .authentication, .deviceRevoked,
             .hostKey, .hostIdentity, .protocol, .endpoint, .permission, .validation,
             .notFound, .conflict, .canceled:
            return true
        default:
            return false
        }
    }

    static func connectionCategory(_ error: Error, route: ConnectionRoute) -> ConnectionFailureCategory {
        if let error = error as? RACPConnectionError { return error.category }
        if let error = error as? RACPSocketTermination { return error.category }
        if error is CancellationError { return .canceled }
        if let error = error as? RACPClientError {
            switch error {
            case .notConnected: return .socketInterrupted
            case .protocolMismatch, .malformedFrame: return .protocol
            case .timedOut: return .connectTimeout
            case .server(let code, _):
                switch code {
                case .unauthorized: return .authentication
                case .forbidden: return .permission
                case .protocolMismatch: return .protocol
                case .invalidArgument, .payloadTooLarge: return .validation
                case .notFound, .methodNotFound: return .notFound
                case .conflict, .idempotencyConflict: return .conflict
                case .rateLimited: return .rateLimited
                case .serverInternal: return .internal
                default: return .business
                }
            }
        }
        if let error = error as? SSHTransportError {
            switch error {
            case .invalidPrivateKey, .authenticationFailed: return .authentication
            case .hostKeyRejected, .hostKeyAlgorithmUnsupported, .hostKeyUnreadable: return .hostKey
            case .timedOut: return .connectTimeout
            case .channelClosed, .closedByPeer: return .socketInterrupted
            case .tunnelRefused, .networkFailure: return .tcp
            case .outputLimitExceeded: return .protocol
            }
        }
        if let error = error as? RACPWebSocketError {
            switch error {
            case .upgradeRejected(let status):
                switch status {
                case 401, 403: return .authentication
                case 404, 426: return .endpoint
                case 400: return .protocol
                case 429: return .rateLimited
                case 502, 503, 504: return .tcp
                default: return .protocol
                }
            case .protocolViolation: return .protocol
            case .closed: return .socketInterrupted
            }
        }
        return .internal
    }

    func isFatal(_ error: Error) -> Bool {
        switch error {
        case RACPClientError.protocolMismatch:
            return true
        case RACPClientError.server(let code, _):
            return !code.isRetryable
        case SSHTransportError.hostKeyRejected, SSHTransportError.invalidPrivateKey:
            return true
        default:
            return false
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? RACPClientError { return error.description }
        if let error = error as? RACPConnectionError { return error.description }
        if let error = error as? RACPSocketTermination { return error.description }
        if let error = error as? SSHTransportError { return error.description }
        if let error = error as? SSHPrivateKeyError { return error.description }
        if let error = error as? RACPWebSocketError { return error.description }
        return error.localizedDescription
    }
}
