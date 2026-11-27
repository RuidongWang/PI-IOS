import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

extension RACPClient {
    // MARK: 入站帧

    func receive(_ data: Data, from socket: any RACPSocket) async {
        // 旧 socket 的尾部帧不能在新连接上触发订阅、ack 或会话归约。
        guard self.socket === socket else { return }
        guard let envelope = try? JSONDecoder().decode(RACPInboundEnvelope.self, from: data) else {
            return
        }
        if let id = envelope.id, envelope.method == nil {
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                let code = error.normalizedCode
                if waiter.method == RACPMethod.providerDiscover.rawValue {
                    waiter.resolve(.failure(RACPProviderDiscoveryError(
                        code: code.rawValue,
                        upstreamStatus: error.data?.value(at: ["upstreamStatus"])?.intValue,
                        reason: error.data?.value(at: ["reason"])?.stringValue
                    )))
                } else {
                    waiter.resolve(.failure(RACPClientError.server(code: code, message: error.message)))
                }
                // 历史读取的 NOT_FOUND/页预算错误由分页入口展示，不能冒充隧道故障。
                if waiter.method != RACPMethod.sessionHistory.rawValue {
                    await emit(.error(code: code, message: error.message))
                }
            } else {
                waiter.resolve(.success(envelope.result ?? .null))
            }
            return
        }
        // 通知帧：契约没有冻结事件通知的方法名，因此不按前缀判定；
        // 只要求「无 id + 载荷能解出整数 sequence」——这是契约 §3.2 归约的必需字段。
        guard envelope.id == nil, let method = envelope.method else {
            // 通知类请求（如 `notifications/initialized`）失败时，adaptor 回的是
            // `{id:null, error:{...}}`：既无 id 也无 method，以前被静默丢弃，
            // 用户只能在下一请求上看到 UNAUTHORIZED。这里补一条非秘密诊断，不改协议行为。
            if envelope.id == nil, envelope.method == nil, let error = envelope.error {
                Self.recordUndeliverableNotificationError(
                    error,
                    phase: status.phase,
                    intent: attemptIntent
                )
            }
            return
        }
        if let error = envelope.error {
            await emit(.error(code: error.normalizedCode, message: error.message))
            return
        }
        let payload = envelope.params ?? envelope.result
        if method == "events/closed",
           let payload,
           let notice = try? RACPSubscriptionClosedNotice.decoded(from: payload) {
            Task { [weak self] in
                await self?.handleSubscriptionClosed(notice, from: socket)
            }
            return
        }
        // v2 PI-adaptor 把事件包成 `params.event`（见 golden 的 `events/event`）；旧 v1 PI-adaptor
        // 直接把事件放在 `params`。两种都接受，避免实时事件被静默丢弃。
        let eventPayload = payload?.value(at: ["event"]) ?? payload
        guard let eventPayload, let event = try? RACPEvent.decoded(from: eventPayload) else {
            return
        }
        // Capture the subscription lease before any await. A delayed frame from
        // the previous subscription must never be acknowledged against a newer one.
        let sessionLease = subscriptionId
        let hostLease = hostSubscription.subscriptionID
        if sessionEventsSuspended,
           event.scope?.rawValue != RACPSubscriptionScope.host.rawValue {
            return
        }
        switch RACPEventRouter.route(
            event,
            currentSessionID: sessionEventsSuspended ? nil : subscribedSessionId
        ) {
        case .host:
            guard hostLease != nil || isHostSubscriptionPending else { return }
            if let observation = hostSubscription.observe(event),
               observation.requiresCatalogRefresh {
                if event.kind == "session.changed",
                   let attachedSession,
                   let changed = event.payload.value(at: ["payload", "session"]),
                   changed.value(at: ["id"])?.stringValue == attachedSession.id,
                   let revision = changed.value(at: ["revision"])?.intValue,
                   revision >= (attachedSession.revision ?? 0),
                   let reason = changed.value(at: ["readOnlyReason"]) {
                    self.attachedSession?.readOnlyReason = reason.stringValue
                    self.attachedSession?.revision = revision
                    await emit(.sessionChanged)
                }
                await emit(.hostChanged(observation.change))
            }
            if let hostLease, let durableSequence = event.durableSequence {
                let ack = PendingEventAck(
                    subscriptionId: hostLease,
                    sequence: durableSequence
                )
                Task { [weak self] in
                    await self?.queueHostAck(ack, from: socket)
                }
            } else if isHostSubscriptionPending, let durableSequence = event.durableSequence {
                pendingHostAckDuringSubscribe = max(
                    pendingHostAckDuringSubscribe ?? 0,
                    durableSequence
                )
            }
        case .session:
            if isRebuildingSnapshot {
                bufferedSessionEventsDuringAttach.append(event)
                if bufferedSessionEventsDuringAttach.count > Self.maxBufferedSessionEventsDuringAttach {
                    // Bound the attach replay buffer. If a slow consumer lets it
                    // grow this far, drop the socket so the reconnect path takes a
                    // fresh authoritative snapshot instead of exhausting memory.
                    bufferedSessionEventsDuringAttach.removeAll()
                    await socket.close()
                    return
                }
                if let sessionLease, let durableSequence = event.durableSequence {
                    let ack = PendingEventAck(
                        subscriptionId: sessionLease,
                        sequence: durableSequence
                    )
                    Task { [weak self] in
                        await self?.queueSessionAck(ack, from: socket)
                    }
                }
                return
            }
            switch viewModel.applyEvents([event]) {
            case .applied:
                if !sessionChangeCoalescingEnabled || (event.kind != "item.delta" && event.kind != "tool.updated") {
                    await emit(.event(event))
                }
                await emit(.sessionChanged)
                if let sessionLease, let durableSequence = event.durableSequence {
                    let ack = PendingEventAck(
                        subscriptionId: sessionLease,
                        sequence: durableSequence
                    )
                    Task { [weak self] in
                        await self?.queueSessionAck(ack, from: socket)
                    }
                } else if let durableSequence = event.durableSequence,
                          pendingSessionSubscriptionAttempt != nil,
                          pendingSessionSubscriptionSessionId == subscribedSessionId,
                          pendingSessionSubscriptionGeneration == sessionAttachGeneration {
                    pendingSessionAckDuringSubscribe = max(
                        pendingSessionAckDuringSubscribe ?? 0,
                        durableSequence
                    )
                }
            case .requiresSnapshotRebuild:
                // Freeze further session frames before yielding to the rebuild
                // task; otherwise a stale event could be applied between the
                // reducer decision and `session/attach`.
                sessionEventsSuspended = true
                Task { [weak self] in
                    guard let self else { return }
                    if await self.rebuildFromSnapshot(from: socket) == .failed {
                        await socket.abort(.transportAborted)
                    }
                }
            }
        case .ignored:
            return
        }
    }

    /// 通知帧失败没有可投递的等待者：只记录稳定分类与错误码，不记录 message/正文。
    static func recordUndeliverableNotificationError(
        _ error: RACPErrorBody,
        phase: ConnectionPhase,
        intent: String?
    ) {
        let category = connectionCategory(
            RACPClientError.server(code: error.normalizedCode, message: error.message),
            route: .ssh
        )
        ConnectionDiagnostics.shared.record(
            kind: .droppedFrame,
            intent: intent,
            phase: phase.diagnosticName,
            category: category,
            detail: error.normalizedCode.rawValue
        )
    }

    func queueSessionAck(_ ack: PendingEventAck, from socket: any RACPSocket) async {
        guard self.socket === socket, subscriptionId == ack.subscriptionId else { return }
        if let pending = pendingSessionAck,
           pending.subscriptionId == ack.subscriptionId {
            pendingSessionAck = PendingEventAck(
                subscriptionId: ack.subscriptionId,
                sequence: max(pending.sequence, ack.sequence)
            )
        } else {
            pendingSessionAck = ack
        }
        await drainSessionAcks(from: socket)
    }

    /// Serialize ACKs so a later event cannot overtake an earlier durable
    /// sequence. While an ACK is in flight the receive loop can still consume
    /// its response; later events simply raise the pending watermark.
    func drainSessionAcks(from socket: any RACPSocket) async {
        guard !isDrainingSessionAcks else { return }
        isDrainingSessionAcks = true
        defer { isDrainingSessionAcks = false }

        while let ack = pendingSessionAck, self.socket === socket {
            pendingSessionAck = nil
            // A delayed task for an old subscription must never acknowledge
            // events from the replacement subscription.
            guard subscriptionId == ack.subscriptionId else { continue }
            let params = RACPEventsAckParams(
                subscriptionId: ack.subscriptionId,
                sequence: ack.sequence
            )
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsAck,
                    params: params,
                    timeout: 10,
                    recoveryScope: .session
                )
            } catch {
                guard self.socket === socket else { break }
                // The subscription changed while the request was in flight;
                // this result cannot poison the replacement subscription.
                guard subscriptionId == ack.subscriptionId else { continue }
                guard Self.requiresCursorReset(error) else {
                    if case let RACPClientError.server(code, message) = error,
                       !code.isRetryable {
                        let reason = RACPClientError.server(code: code, message: message).description
                        subscriptionTerminalReason = reason
                        await emit(.error(code: code, message: message))
                    }
                    await socket.abort(.transportAborted)
                    break
                }
                if await rebuildFromSnapshot(from: socket) == .failed {
                    await socket.abort(.transportAborted)
                }
                break
            }
        }
    }

    /// `events/closed` 是订阅级的终态通知；必须只作用于原 socket，并按 lastSafeCursor 恢复，
    /// 不能把旧连接关闭时收到的通知拿来操作新连接。
    func handleSubscriptionClosed(
        _ notice: RACPSubscriptionClosedNotice,
        from socket: any RACPSocket
    ) async {
        guard self.socket === socket else { return }
        let closesHost = notice.subscriptionId == hostSubscription.subscriptionID
        let closesSession = notice.subscriptionId == subscriptionId
        guard closesHost || closesSession else { return }
        if let subscriptionError = notice.error {
            let code = subscriptionError.normalizedCode
            if code == .clientTooSlow, closesSession {
                subscriptionId = nil
                pendingSessionAck = nil
                if await rebuildFromSnapshot(from: socket) == .failed { await socket.abort(.transportAborted) }
                return
            }
            if code.isRetryable && code != .clientTooSlow {
                await emit(.error(code: code, message: subscriptionError.message))
                await socket.abort(.transportAborted)
                return
            }
            guard Self.canRecoverClosedSubscription(code) else {
                await terminateForClosedSubscription(subscriptionError, from: socket)
                return
            }
        }

        if closesHost {
            hostSubscription.prepareForReconnect()
            if let cursor = notice.lastSafeCursor {
                hostSubscription.restoreCursor(cursor)
            }
            pendingHostAck = nil
            await emit(.hostChanged(
                RACPHostChange(
                    reason: .resyncRequired,
                    kind: nil,
                    sessionId: nil,
                    revision: nil,
                    cursor: hostSubscription.cursor,
                    payload: .null
                )
            ))
            guard self.socket === socket else { return }
            do {
                try await subscribeHost()
            } catch {
                await socket.abort(.transportAborted)
            }
            return
        }

        subscriptionId = nil
        pendingSessionAck = nil
        guard let sessionId = subscribedSessionId else { return }
        let after = notice.lastSafeCursor ?? viewModel.cursor
        do {
            try await subscribeSession(sessionId: sessionId, after: after)
        } catch {
            await socket.abort(.transportAborted)
        }
    }

    static func canRecoverClosedSubscription(_ code: RACPErrorCode) -> Bool {
        code == .cursorExpired || code == .clientTooSlow
    }

    func terminateForClosedSubscription(
        _ error: RACPErrorBody,
        from socket: any RACPSocket
    ) async {
        let code = error.normalizedCode
        let reason = RACPClientError.server(code: code, message: error.message).description
        subscriptionTerminalReason = reason
        await emit(.error(code: code, message: error.message))
        runTask?.cancel()
        await socket.abort(.transportAborted)
    }

    func queueHostAck(_ ack: PendingEventAck, from socket: any RACPSocket) async {
        guard self.socket === socket,
              hostSubscription.subscriptionID == ack.subscriptionId
        else { return }
        if let pending = pendingHostAck,
           pending.subscriptionId == ack.subscriptionId {
            pendingHostAck = PendingEventAck(
                subscriptionId: ack.subscriptionId,
                sequence: max(pending.sequence, ack.sequence)
            )
        } else {
            pendingHostAck = ack
        }
        await drainHostAcks(from: socket)
    }

    /// 一批重放事件只发一次 `events/ack`，避免每条事件都制造一次请求风暴。
    func drainHostAcks(from socket: any RACPSocket) async {
        guard !isDrainingHostAcks else { return }
        isDrainingHostAcks = true
        defer { isDrainingHostAcks = false }

        while let ack = pendingHostAck, self.socket === socket {
            pendingHostAck = nil
            guard hostSubscription.subscriptionID == ack.subscriptionId else { continue }
            let params = RACPEventsAckParams(
                subscriptionId: ack.subscriptionId,
                sequence: ack.sequence
            )
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsAck,
                    params: params,
                    timeout: 10,
                    recoveryScope: .host
                )
            } catch {
                guard self.socket === socket else { break }
                guard hostSubscription.subscriptionID == ack.subscriptionId else { continue }
                guard Self.requiresCursorReset(error) else {
                    if case let RACPClientError.server(code, message) = error,
                       !code.isRetryable {
                        let reason = RACPClientError.server(code: code, message: message).description
                        subscriptionTerminalReason = reason
                        await emit(.error(code: code, message: message))
                    }
                    await socket.abort(.transportAborted)
                    break
                }
                hostSubscription.resetAfterCursorExpired()
                pendingHostAck = nil
                await emit(.hostChanged(
                    RACPHostChange(
                        reason: .replayIncomplete,
                        kind: nil,
                        sessionId: nil,
                        revision: nil,
                        cursor: nil,
                        payload: .null
                    )
                ))
                do {
                    try await subscribeHost()
                } catch {
                    await socket.abort(.transportAborted)
                }
                break
            }
        }
    }

    /// `CURSOR_EXPIRED` / `CLIENT_TOO_SLOW` / epoch 变化 → 重新 attach 拿快照整体替换。
    ///
    /// 注意不要在此处捕获 `sessionAttachGeneration` 再与返回值比较：`attach`
    /// 自身会先递增该值，比较必然失败，导致正常的重建与失败都被误判为
    /// `.superseded`。`attach` 已经内建了 generation 校验（被取代时返回
    /// `nil`），这里改用 socket/会话身份与返回值判断。
    func rebuildFromSnapshot(from socket: any RACPSocket) async -> SnapshotRebuildOutcome {
        guard self.socket === socket, let sessionId else { return .failed }
        // Keyed by session so concurrent rebuilds for the same session collapse,
        // while a switch to another session does not block its own rebuild.
        guard rebuildingSnapshots.insert(sessionId).inserted else { return .inProgress }
        defer { rebuildingSnapshots.remove(sessionId) }
        viewModel.discardCursorForSnapshotRebuild()
        let generationBeforeAttach = viewModel.historySnapshotGeneration
        do {
            let includedSnapshot = try await attach(sessionId: sessionId, subscribe: true)
            guard self.socket === socket, self.sessionId == sessionId else { return .superseded }
            guard let includedSnapshot else { return .superseded }
            // attach's public Bool describes only its first response. A replay may
            // apply the authoritative snapshot later; prepend/live events never
            // advance this generation, so its change proves an actual replacement.
            let appliedSnapshot = viewModel.historySnapshotGeneration != generationBeforeAttach
            return (includedSnapshot || appliedSnapshot) ? .rebuilt : .failed
        } catch {
            guard self.socket === socket, self.sessionId == sessionId else { return .superseded }
            return .failed
        }
    }

    nonisolated static func requiresCursorReset(_ error: Error) -> Bool {
        guard case let RACPClientError.server(code, _) = error else { return false }
        return code == .cursorExpired || code == .clientTooSlow
    }

}
