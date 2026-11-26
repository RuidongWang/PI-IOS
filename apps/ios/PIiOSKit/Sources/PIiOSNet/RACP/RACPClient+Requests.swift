import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

extension RACPClient {
    // MARK: 会话

    /// `session/attach` + （可选）`events/subscribe`：申请快照并整体替换本地视图。
    @discardableResult
    public func attach(sessionId: String, subscribe: Bool = true) async throws -> Bool? {
        sessionAttachGeneration &+= 1
        let attachGeneration = sessionAttachGeneration
        let previousSessionId = self.sessionId
        let switchesSession = previousSessionId != nil && previousSessionId != sessionId
        // 从发起到快照落地的窗口内冻结会话事件；旧订阅的迟到事件不能污染新会话。
        sessionEventsSuspended = true
        let params = RACPSessionAttachParams(sessionId: sessionId)
        let result: RACPSessionAttachResult
        do {
            result = try await request(.sessionAttach, params: params)
        } catch {
            guard attachGeneration == sessionAttachGeneration else { throw error }
            sessionEventsSuspended = false
            subscribedSessionId = previousSessionId
            if let previousSessionId {
                // The old subscription may have lost events while suspended; replay from its cursor.
                try? await subscribeSession(sessionId: previousSessionId, after: viewModel.cursor)
            }
            throw error
        }
        guard attachGeneration == sessionAttachGeneration else { return nil }

        // Candidate snapshots may reduce replay/live events before their earliest turn
        // is complete, but none of them may become visibly published in that state.
        let publicationID = UUID()
        initialHistoryPublicationSuspension = (publicationID, attachGeneration)
        // Revoke even a same-generation receipt queued before this token. Otherwise
        // begin/finish could consume it against the candidate's incomplete reducer.
        sessionChangeDelivery.revoke()
        // A replay rebuild belongs to its attachment. The new candidate starts with
        // its own clean rebuild state; the old defer is ownership-guarded below.
        isRebuildingSnapshot = false
        bufferedSessionEventsDuringAttach.removeAll()
        defer {
            // A newer attach installs a different token. Never clear that newer token.
            if initialHistoryPublicationSuspension?.id == publicationID {
                initialHistoryPublicationSuspension = nil
            }
        }

        do {
            if switchesSession {
                viewModel.resetForSession()
            }
            // 契约 §3.2 规则 1：`replayComplete=false` 也必须整体替换，并丢弃未完成草稿。
            if let snapshot = result.snapshot {
                if switchesSession || snapshot.revision >= viewModel.revision {
                    _ = viewModel.applySnapshot(snapshot, replayComplete: result.replayComplete ?? false)
                }
            }
            self.attachedSession = result.session
            self.sessionId = sessionId
            self.subscribedSessionId = sessionId
            if result.snapshot == nil, let activeTurnId = result.session.activeTurnId {
                viewModel.recordActiveTurn(id: activeTurnId)
            }

            if subscribe {
                try await subscribeSession(sessionId: sessionId, after: viewModel.cursor)
            } else {
                sessionEventsSuspended = false
            }
            guard attachGeneration == sessionAttachGeneration,
                  initialHistoryPublicationSuspension?.id == publicationID
            else { return nil }

            // Subscribe may have replaced the initial response with a newer replay
            // snapshot. Decide from that final reducer, not the first response.
            if viewModel.hasMoreHistory,
               !ConversationTurnPolicy.hasTaskBoundary(viewModel.items) {
                // The recent window usually starts in the middle of an older turn.
                // Hiding that incomplete prefix keeps the first visible row at a
                // real user task without walking the entire session backwards on
                // every attach (the old behavior made long sessions take 10–30s).
                // Omitted rows remain reachable through `loadEarlierHistory`.
                let hidden = viewModel.trimIncompleteLeadingTurn()
                if hidden == 0 {
                    _ = try await assembleEarlierHistory(
                        limit: RACPSessionHistoryParams.defaultLimit,
                        emitUpdate: false
                    )
                } else {
                    PILog.debug(
                        "History",
                        "attach trimmed incomplete leading turn items=\(hidden) hasMore=true"
                    )
                }
            } else if !viewModel.hasMoreHistory,
                      !ConversationTurnPolicy.hasTaskBoundary(viewModel.items) {
                PILog.warn("History", "history exhausted without task boundary stagedItems=0")
            }
            guard attachGeneration == sessionAttachGeneration,
                  initialHistoryPublicationSuspension?.id == publicationID
            else { return nil }

            initialHistoryPublicationSuspension = nil
            await emit(.sessionChanged)
            return result.snapshot != nil
        } catch {
            // Only the still-current candidate may invalidate itself. An old failure
            // must never clear a newer attachment, reducer, or publication token.
            guard attachGeneration == sessionAttachGeneration,
                  initialHistoryPublicationSuspension?.id == publicationID
            else { throw error }
            invalidateCandidateAttachment(attachGeneration: attachGeneration)
            throw error
        }
    }

    /// Invalidate every visible and replay-owned piece of a failed candidate without
    /// closing a socket that a newer attachment may already be using.
    func invalidateCandidateAttachment(attachGeneration: Int) {
        guard sessionAttachGeneration == attachGeneration else { return }
        sessionAttachGeneration &+= 1
        sessionId = nil
        subscribedSessionId = nil
        attachedSession = nil
        subscriptionId = nil
        viewModel.resetForSession()
        sessionEventsSuspended = true
        if historyRequest?.attach == attachGeneration { historyRequest = nil }
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        pendingSessionAck = nil
        isRebuildingSnapshot = false
        bufferedSessionEventsDuringAttach.removeAll()
        rebuildingSnapshots.removeAll()
        sessionChangeDelivery.revoke()
    }

    /// 手动补取更早历史；返回实际前置的条数。历史页不参与实时游标/快照恢复。
    /// 被会话切换、快照替换或换 socket 取代时丢弃响应，绝不关闭活动连接。
    @discardableResult
    public func loadEarlierHistory(limit: Int = RACPSessionHistoryParams.defaultLimit) async throws -> Int {
        try await assembleEarlierHistory(limit: limit, emitUpdate: true)
    }

    /// Stage all pages needed to complete the earliest turn, then prepend and publish once.
    func assembleEarlierHistory(limit: Int, emitUpdate: Bool) async throws -> Int {
        guard state.isOnline, !promotionFenced, let socket, let sessionId,
              !sessionEventsSuspended, !isRebuildingSnapshot else {
            throw RACPClientError.notConnected
        }
        guard viewModel.hasMoreHistory else { return 0 }
        let attach = sessionAttachGeneration
        let snapshot = viewModel.historySnapshotGeneration
        let socketID = ObjectIdentifier(socket)
        if let current = historyRequest,
           current.attach == attach, current.snapshot == snapshot, current.socket == socketID {
            return 0
        }
        let requestID = UUID()
        historyRequest = (requestID, attach, snapshot, socketID)
        defer {
            if historyRequest?.id == requestID { historyRequest = nil }
        }
        let originalFirstItemID = viewModel.items.first?.id
        var staged: [RACPItem] = []
        var hasMore = true

        while true {
            let beforeItemID = staged.first?.id ?? originalFirstItemID
            // 先保留成功/失败结果，统一检查代次；旧快照的错误也不能污染新视图。
            let response: Result<RACPSessionHistoryResult, Error>
            do {
                response = .success(try await request(
                    .sessionHistory,
                    params: RACPSessionHistoryParams(
                        sessionId: sessionId,
                        beforeItemId: beforeItemID,
                        limit: max(1, min(limit, RACPSessionHistoryParams.maxLimit))
                    )
                ))
            } catch {
                response = .failure(error)
            }
            try Task.checkCancellation()
            guard self.socket === socket, self.sessionId == sessionId,
                  state.isOnline, !promotionFenced, !sessionEventsSuspended, !isRebuildingSnapshot,
                  sessionAttachGeneration == attach,
                  viewModel.historySnapshotGeneration == snapshot,
                  viewModel.items.first?.id == originalFirstItemID,
                  historyRequest?.id == requestID else { throw CancellationError() }

            let result = try response.get()
            hasMore = result.hasMore ?? false
            var seen = Set((viewModel.items + staged).map(\.id))
            let newItems = result.items.filter { seen.insert($0.id).inserted }
            if hasMore, newItems.isEmpty {
                throw RACPClientError.malformedFrame("历史分页没有向前推进，请重试打开会话")
            }
            staged.insert(contentsOf: newItems, at: 0)

            if !hasMore || ConversationTurnPolicy.hasUsableTaskBoundary(staged) {
                break
            }
        }

        if !hasMore, !ConversationTurnPolicy.hasUsableTaskBoundary(staged + viewModel.items) {
            PILog.warn("History", "history exhausted without task boundary stagedItems=\(staged.count)")
        }
        // No await occurs between the final ownership check and this single commit.
        let beforeCount = viewModel.items.count
        _ = viewModel.prependHistory(staged, hasMore: hasMore)
        if hasMore {
            let hidden = viewModel.trimIncompleteLeadingTurn()
            if hidden > 0 {
                PILog.debug("History", "trimmed incomplete leading turn items=\(hidden) hasMore=\(hasMore)")
            }
        }
        let inserted = max(0, viewModel.items.count - beforeCount)
        if emitUpdate { await emit(.sessionChanged) }
        return inserted
    }

    /// 用会话**当前游标**重新订阅（重连后补齐缺失事件，AC-14.1）。
    public func subscribeSession(sessionId: String, after: RACPCursor?) async throws {
        let attachGeneration = sessionAttachGeneration
        guard let socket else { throw RACPClientError.notConnected }
        let subscribeAttempt = UUID()
        pendingSessionSubscriptionAttempt = subscribeAttempt
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        if let previousSubscriptionId = subscriptionId {
            subscriptionId = nil
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsUnsubscribe,
                    params: RACPEventsUnsubscribeParams(subscriptionId: previousSubscriptionId),
                    timeout: 10
                )
            } catch {
                let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                    && attachGeneration == sessionAttachGeneration
                    && self.sessionId == sessionId
                if ownsAttempt {
                    // A live old subscription could keep delivering unscoped
                    // frames. Drop the whole socket rather than risk applying
                    // them to a replacement subscription on the same socket.
                    await socket.abort(.transportAborted)
                    throw RACPClientError.notConnected
                }
                return
            }
        }
        guard attachGeneration == sessionAttachGeneration, self.sessionId == sessionId else { return }
        // Replay frames may arrive before `events/subscribe` returns its new
        // subscription id. Apply them from the durable cursor and remember the
        // highest watermark so it can be ACKed once the id is installed.
        sessionEventsSuspended = false
        pendingSessionSubscriptionSessionId = sessionId
        pendingSessionSubscriptionGeneration = attachGeneration
        pendingSessionAckDuringSubscribe = nil
        let params = RACPEventsSubscribeParams(scope: .session, sessionId: sessionId, after: after)
        let value: JSONValue
        do {
            value = try await requestJSON(
                .eventsSubscribe,
                params: params,
                timeout: 20,
                recoveryScope: .session
            )
        } catch {
            let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                && pendingSessionSubscriptionGeneration == attachGeneration
                && pendingSessionSubscriptionSessionId == sessionId
                && attachGeneration == sessionAttachGeneration
                && self.sessionId == sessionId
            if ownsAttempt {
                pendingSessionSubscriptionAttempt = nil
                pendingSessionSubscriptionSessionId = nil
                pendingSessionSubscriptionGeneration = nil
                pendingSessionAckDuringSubscribe = nil
            }
            guard ownsAttempt else { return }
            guard Self.requiresCursorReset(error) else {
                // The server may have installed the subscription even though
                // the response timed out. Drop the uncertain socket so a new
                // subscription replays from the durable cursor.
                await socket.abort(.transportAborted)
                throw RACPClientError.notConnected
            }
            let outcome = await rebuildFromSnapshot(from: socket)
            if outcome == .failed,
               attachGeneration == sessionAttachGeneration,
               self.sessionId == sessionId,
               self.socket === socket {
                await socket.abort(.transportAborted)
            }
            return
        }
        let result: RACPEventsSubscribeResult
        do {
            result = try RACPEventsSubscribeResult.decoded(from: value)
        } catch {
            let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                && pendingSessionSubscriptionGeneration == attachGeneration
                && pendingSessionSubscriptionSessionId == sessionId
                && attachGeneration == sessionAttachGeneration
                && self.sessionId == sessionId
            if ownsAttempt {
                pendingSessionSubscriptionAttempt = nil
                pendingSessionSubscriptionSessionId = nil
                pendingSessionSubscriptionGeneration = nil
                pendingSessionAckDuringSubscribe = nil
                await socket.abort(.transportAborted)
                throw error
            }
            return
        }
        let ownsPendingAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
            && pendingSessionSubscriptionGeneration == attachGeneration
            && pendingSessionSubscriptionSessionId == sessionId
            && attachGeneration == sessionAttachGeneration
            && self.sessionId == sessionId
        let replayAck = ownsPendingAttempt
            ? pendingSessionAckDuringSubscribe
            : nil
        if ownsPendingAttempt {
            pendingSessionSubscriptionAttempt = nil
            pendingSessionSubscriptionSessionId = nil
            pendingSessionSubscriptionGeneration = nil
            pendingSessionAckDuringSubscribe = nil
        }
        guard !result.subscriptionId.isEmpty else {
            if ownsPendingAttempt {
                await socket.abort(.transportAborted)
                throw RACPClientError.malformedFrame("events/subscribe 未返回 subscriptionId")
            }
            return
        }
        guard ownsPendingAttempt,
              attachGeneration == sessionAttachGeneration,
              self.sessionId == sessionId
        else {
            _ = try? await requestJSON(
                .eventsUnsubscribe,
                params: RACPEventsUnsubscribeParams(subscriptionId: result.subscriptionId),
                timeout: 10
            )
            return
        }
        subscriptionId = result.subscriptionId
        subscribedSessionId = sessionId
        if let replayAck {
            await queueSessionAck(
                PendingEventAck(subscriptionId: result.subscriptionId, sequence: replayAck),
                from: socket
            )
        }
        if result.replayComplete != true {
            isRebuildingSnapshot = true
            bufferedSessionEventsDuringAttach.removeAll()
            defer {
                // An old replay must never clear a replacement attachment's flag or
                // buffer, including when both attachments use the same session id.
                if attachGeneration == sessionAttachGeneration,
                   self.sessionId == sessionId,
                   self.socket === socket {
                    isRebuildingSnapshot = false
                    bufferedSessionEventsDuringAttach.removeAll()
                }
            }
            let attachResult: RACPSessionAttachResult = try await request(
                .sessionAttach,
                params: RACPSessionAttachParams(sessionId: sessionId)
            )
            guard attachGeneration == sessionAttachGeneration, self.sessionId == sessionId else {
                return
            }
            if let snapshot = attachResult.snapshot,
               snapshot.revision >= viewModel.revision {
                _ = viewModel.applySnapshot(snapshot, replayComplete: true)
                let snapshotSeq = snapshot.cursor.sequence
                let newerBuffered = bufferedSessionEventsDuringAttach.filter {
                    ($0.durableSequence ?? 0) > snapshotSeq
                }
                if !newerBuffered.isEmpty {
                    _ = viewModel.applyEvents(newerBuffered)
                }
            }
            attachedSession = attachResult.session
            self.sessionId = sessionId
            if attachResult.snapshot == nil, let activeTurnId = attachResult.session.activeTurnId {
                viewModel.recordActiveTurn(id: activeTurnId)
            }
            await emit(.sessionChanged)
        }
    }

    /// PI-adaptor 级订阅：感知其他客户端创建会话、归档会话与 revision 变化。
    ///
    /// 游标跨重连保留；subscriber id 每次连接重建。`replayComplete=false` 时
    /// 不尝试逐条补齐，而是要求上层重新拉取完整项目/会话目录。
    func subscribeHost() async throws {
        if let previousSubscriptionID = hostSubscription.subscriptionID {
            _ = try? await requestJSON(
                .eventsUnsubscribe,
                params: RACPEventsUnsubscribeParams(subscriptionId: previousSubscriptionID),
                timeout: 10
            )
        }
        hostSubscription.prepareForReconnect()

        var didResetExpiredCursor = false
        while true {
            isHostSubscriptionPending = true
            pendingHostAckDuringSubscribe = nil
            do {
                let value = try await requestJSON(
                    .eventsSubscribe,
                    params: RACPEventsSubscribeParams(scope: .host, after: hostSubscription.cursor),
                    timeout: 20,
                    recoveryScope: .host
                )
                let result = try RACPEventsSubscribeResult.decoded(from: value)
                guard !result.subscriptionId.isEmpty else {
                    throw RACPClientError.malformedFrame("host events/subscribe 未返回 subscriptionId")
                }
                guard let socket else { throw RACPClientError.notConnected }
                let replayAck = pendingHostAckDuringSubscribe
                isHostSubscriptionPending = false
                pendingHostAckDuringSubscribe = nil
                hostSubscription.install(
                    subscriptionID: result.subscriptionId,
                    starting: result.starting
                )
                if let replayAck {
                    await queueHostAck(
                        PendingEventAck(
                            subscriptionId: result.subscriptionId,
                            sequence: replayAck
                        ),
                        from: socket
                    )
                }
                await drainHostAcks(from: socket)

                if result.replayComplete != true {
                    await emit(.hostChanged(
                        RACPHostChange(
                            reason: .replayIncomplete,
                            kind: nil,
                            sessionId: nil,
                            revision: nil,
                            cursor: hostSubscription.cursor,
                            payload: .null
                        )
                    ))
                    // initialize/订阅建立不等于可用：目录快照必须先成功取得并交付，
                    // runLoop 才能在下一步发布 online；读取失败会留在 restoring/failed。
                    let projects = try await listProjects()
                    let sessions = try await listSessions()
                    await emit(.hostSnapshot(projects: projects, sessions: sessions))
                }
                return
            } catch {
                isHostSubscriptionPending = false
                pendingHostAckDuringSubscribe = nil
                guard !didResetExpiredCursor, Self.requiresCursorReset(error) else { throw error }
                didResetExpiredCursor = true
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
            }
        }
    }

    public func listSessions(timeout: TimeInterval = 20) async throws -> [RACPSessionSummary] {
        let result: RACPSessionListResult = try await request(
            .sessionList,
            params: RACPEmptyParams(),
            timeout: timeout
        )
        return result.sessions
    }

    public func getSession(id: String) async throws -> RACPSessionSummary {
        let generation = sessionAttachGeneration
        let result: RACPSessionGetResult = try await request(.sessionGet, params: RACPSessionGetParams(sessionId: id))
        if self.sessionId == id, generation == sessionAttachGeneration,
           result.session.revision.map({ $0 >= (attachedSession?.revision ?? 0) }) ?? true {
            attachedSession = result.session
            if result.session.revision.map({ $0 >= viewModel.revision }) ?? true {
                viewModel.recordActiveTurn(id: result.session.activeTurnId)
            }
            await emit(.sessionChanged)
        }
        return result.session
    }

    public func listProjects(timeout: TimeInterval = 20) async throws -> [RACPProjectSummary] {
        let result: RACPProjectListResult = try await request(
            .projectList,
            params: RACPEmptyParams(),
            timeout: timeout
        )
        return result.projects
    }

    /// 认证往返探测。默认沿用普通请求预算；前台恢复的存活检查会传更短的预算。
    public func ping(timeout: TimeInterval = 20) async throws {
        let _: RACPJSONObject = try await request(.ping, params: RACPEmptyParams(), timeout: timeout)
    }

    // MARK: - 发送 / 中止 / 排队（AC-08 / AC-09 / AC-13）

    public func uploadImage(
        sessionId: String,
        data: Data,
        mimeType: String,
        fileName: String
    ) async throws -> RACPV2Attachment {
        guard data.count > 0, data.count <= 20 * 1024 * 1024 else {
            throw RACPClientError.protocolMismatch("图片必须为 1 字节至 20 MiB")
        }
        guard ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else {
            throw RACPClientError.protocolMismatch("仅支持 JPEG、PNG、WebP")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let created: RACPV2AttachmentCreateResult = try await request(
            .attachmentCreate,
            params: .object([
                "sessionId": .string(sessionId),
                "fileName": .string(fileName),
                "mimeType": .string(mimeType),
                "byteLength": .number(Double(data.count)),
                "sha256": .string(digest),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("attach_\(UUID().uuidString)")
                ])
            ])
        )
        let chunkSize = max(1, created.chunkSize)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            let chunk = data.subdata(in: offset..<end)
            let _: RACPV2AttachmentChunkResult = try await request(
                .attachmentChunk,
                params: .object([
                    "attachmentId": .string(created.attachmentId),
                    "offset": .number(Double(offset)),
                    "dataBase64": .string(chunk.base64EncodedString()),
                    "context": .object([
                        "requestId": .string("req_\(UUID().uuidString)"),
                        "idempotencyKey": .string("attach_chunk_\(UUID().uuidString)")
                    ])
                ])
            )
            offset = end
        }
        let completed: RACPV2AttachmentEnvelope = try await request(
            .attachmentComplete,
            params: .object([
                "attachmentId": .string(created.attachmentId),
                "sha256": .string(digest),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("attach_complete_\(UUID().uuidString)")
                ])
            ])
        )
        return completed.attachment
    }

    public func readImageAttachment(
        attachmentId: String,
        offset: Int = 0,
        length: Int = 262_144
    ) async throws -> RACPV2AttachmentReadResult {
        try await request(
            .attachmentRead,
            params: .object([
                "attachmentId": .string(attachmentId),
                "offset": .number(Double(offset)),
                "length": .number(Double(length)),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)")
                ])
            ])
        )
    }

    /// 发送一条消息。`idempotencyKey` 必须由调用方持久化并在重试时复用（AC-14.4）。
    ///
    /// `admission` 为 `.queue` 时表示当前有 turn 在跑，这条指令排队（AC-13.1）。
    /// `apiKey` 只随本次请求发送（服务端不落盘）；不得写入日志、诊断或错误文本。
    public func startTurn(
        sessionId: String,
        text: String,
        attachments: [String] = [],
        admission: RACPTurnAdmission?,
        idempotencyKey: String,
        apiKey: String? = nil,
        providerBinding: RACPProviderKeyBinding? = nil,
        isRetry: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> RACPTurnStartResult {
        let attachGeneration = sessionAttachGeneration
        if self.sessionId == sessionId, let reason = attachedSession?.readOnlyReason {
            throw RACPClientError.server(code: .sessionReadOnly, message: reason)
        }
        let params = RACPTurnStartParams(
            sessionId: sessionId,
            admission: admission,
            input: RACPTurnInput(text: text, attachments: attachments.map(JSONValue.string)),
            context: makeContext(idempotencyKey: idempotencyKey),
            apiKey: apiKey,
            providerBinding: providerBinding
        )
        var result: RACPTurnStartResult
        do {
            result = try await request(.turnStart, params: params, timeout: timeout)
        } catch let error as RACPClientError {
            if case .server(.sessionReadOnly, let reason) = error,
               self.sessionId == sessionId, sessionAttachGeneration == attachGeneration {
                attachedSession?.readOnlyReason = reason ?? RACPErrorCode.sessionReadOnly.rawValue
                await emit(.sessionChanged)
            }
            throw error
        }
        if isRetry, result.accepted, serverInfo?.serverName != "pi-host" {
            // A replayed admission receipt can predate a restart or a terminal event.
            do {
                let current: RACPTurnResult = try await request(
                    .turnGet, params: RACPTurnByIDParams(turnId: result.turn.id), timeout: timeout
                )
                guard current.turn.id == result.turn.id,
                      current.turn.sessionId == nil || current.turn.sessionId == sessionId,
                      current.turn.status != nil else {
                    throw RACPClientError.malformedFrame("轮次状态与发送回执不一致")
                }
                result.turn = current.turn
            } catch let error as RACPClientError {
                switch error {
                case .server(.methodNotFound, _), .server(.unknown("-32601"), _):
                    break // Legacy servers may implement turn/start without turn/get.
                default:
                    throw error
                }
            }
        }
        guard self.sessionId == sessionId, sessionAttachGeneration == attachGeneration else { return result }
        let status = result.turn.status?.lowercased()
        switch status {
        case "queued":
            viewModel.recordQueuedTurn(id: result.turn.id, text: text)
        case "running", "waiting_approval", "waiting_input", "in_progress":
            viewModel.removeQueuedTurn(id: result.turn.id)
            viewModel.recordActiveTurn(id: result.turn.id)
        case "completed", "interrupted", "failed", "canceled", "cancelled", "uncertain":
            viewModel.removeQueuedTurn(id: result.turn.id)
            if viewModel.activeTurnId == result.turn.id {
                viewModel.recordActiveTurn(id: nil)
            }
        case nil:
            if admission == .queue {
                viewModel.recordQueuedTurn(id: result.turn.id, text: text)
            } else {
                viewModel.recordActiveTurn(id: result.turn.id)
            }
        default:
            if admission == .queue {
                viewModel.recordQueuedTurn(id: result.turn.id, text: text)
            } else {
                viewModel.recordActiveTurn(id: result.turn.id)
            }
        }
        return result
    }

    /// Fetch an oversized history item's original text without changing the current view.
    public func readHistoryText(sessionId: String, itemId: String, byteLength: Int) async throws -> String {
        var body = Data()
        while body.count < byteLength {
            try Task.checkCancellation()
            let params = RACPSessionHistoryParams(
                sessionId: sessionId,
                textRange: .init(itemId: itemId, offset: body.count)
            )
            let result: RACPSessionHistoryResult = try await request(.sessionHistory, params: params)
            guard let chunk = result.textChunk,
                  chunk.totalBytes == byteLength,
                  let bytes = Data(base64Encoded: chunk.dataBase64),
                  !bytes.isEmpty,
                  bytes.count <= min(64 * 1024, byteLength - body.count)
            else { throw RACPClientError.protocolMismatch("历史原文分段与预览不一致") }
            body.append(bytes)
        }
        guard let text = String(data: body, encoding: .utf8) else {
            throw RACPClientError.protocolMismatch("历史原文不是有效的 UTF-8")
        }
        return text
    }

    /// 让 AI 根据首条指令生成会话标题（0.0.4 起支持）。
    ///
    /// 旧版 PI-adaptor 没有这个方法，调用方应把 `METHOD_NOT_FOUND` 当成
    /// 「不支持」并退回本地标题，而不是把它当成会话失败。
    public func suggestSessionTitle(
        sessionId: String,
        instruction: String,
        providerId: String,
        modelId: String,
        apiKey: String?,
        providerBinding: RACPProviderKeyBinding? = nil,
        thinkingLevel: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        var fields: [String: JSONValue] = [
            "context": .object([
                "requestId": .string(UUID().uuidString),
            ]),
            "sessionId": .string(sessionId),
            "instruction": .string(instruction),
            "providerId": .string(providerId),
            "modelId": .string(modelId),
        ]
        if let apiKey, !apiKey.isEmpty { fields["apiKey"] = .string(apiKey) }
        if let providerBinding {
            fields["providerBinding"] = .object([
                "providerId": .string(providerBinding.providerId),
                "baseUrl": .string(providerBinding.baseUrl),
            ])
        }
        if let thinkingLevel, !thinkingLevel.isEmpty { fields["thinkingLevel"] = .string(thinkingLevel) }
        let params: JSONValue = .object(fields)
        let result: RACPV2SuggestTitleResult = try await request(
            .sessionSuggestTitle,
            params: params,
            timeout: timeout
        )
        return result.title
    }

    /// 把服务器上的会话改名（AI 标题确认后写入）。
    public func renameSession(sessionId: String, title: String) async throws {
        let params: JSONValue = .object([
            "context": .object(["requestId": .string(UUID().uuidString)]),
            "sessionId": .string(sessionId),
            "title": .string(title),
        ])
        let _: RACPV2SessionResult = try await request(
            .sessionRename,
            params: params
        )
    }

    /// 归档或恢复会话。这里只发送 Host 请求，不提前修改本地目录或缓存。
    public func archiveSession(
        sessionId: String,
        archived: Bool
    ) async throws -> RACPV2SessionResult {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "archived": .bool(archived),
            "context": .object([
                "requestId": .string("req_\(UUID().uuidString)"),
                "idempotencyKey": .string("session_archive_\(UUID().uuidString)"),
            ]),
        ])
        return try await request(.sessionArchive, params: params)
    }

    /// 删除会话。双 ID 必须在发送前一致，Host 明确成功后才由上层清理本机状态。
    public func deleteSession(
        sessionId: String,
        confirmSessionId: String
    ) async throws -> RACPV2SessionDeleteResult {
        guard !sessionId.isEmpty, sessionId == confirmSessionId else {
            throw RACPClientError.protocolMismatch("删除确认目标不一致")
        }
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "confirmSessionId": .string(confirmSessionId),
            "context": .object([
                "requestId": .string("req_\(UUID().uuidString)"),
                "idempotencyKey": .string("session_delete_\(UUID().uuidString)"),
            ]),
        ])
        return try await request(.sessionDelete, params: params)
    }

    /// 中止正在运行的 turn（AC-09.1）。
    public func interruptTurn(turnId: String) async throws {
        let _: RACPTurnResult = try await request(
            .turnInterrupt,
            params: RACPTurnIDParams(turnId: turnId, context: makeContext())
        )
        if viewModel.activeTurnId == turnId { viewModel.recordActiveTurn(id: nil) }
    }

    /// 取消一条排队中的 turn（AC-13.2）。
    public func cancelTurn(turnId: String) async throws {
        let _: RACPTurnResult = try await request(
            .turnCancel,
            params: RACPTurnIDParams(turnId: turnId, context: makeContext())
        )
        viewModel.removeQueuedTurn(id: turnId)
        if viewModel.activeTurnId == turnId { viewModel.recordActiveTurn(id: nil) }
    }

    // MARK: - 审批与提问（AC-10 / AC-11 / AC-12）

    /// 工具类审批。返回体形状未冻结，按原始 JSON 返回，由界面只读可能的 `alreadyResolved`。
    public func respondApproval(
        approvalId: String,
        decision: RACPApprovalDecision,
        permissionMode: RACPPermissionMode? = nil,
        expectedRevision: Int?,
        idempotencyKey: String
    ) async throws -> JSONValue {
        let params = RACPApprovalRespondParams(
            approvalId: approvalId,
            decision: decision,
            permissionMode: permissionMode,
            context: makeContext(idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
        )
        return try await request(.approvalRespond, params: params)
    }

    /// Plan / Goal 契约审批（AC-12.1）。
    public func respondContract(
        approvalId: String,
        decision: RACPContractDecision,
        expectedRevision: Int?,
        idempotencyKey: String
    ) async throws -> JSONValue {
        let params = RACPApprovalRespondParams(
            approvalId: approvalId,
            contractDecision: decision,
            context: makeContext(idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
        )
        return try await request(.approvalRespond, params: params)
    }

    public func markApprovalExpired(id: String) async {
        viewModel.markApprovalExpired(id: id)
        await emit(.sessionChanged)
    }

    // MARK: - 配置 / 项目 / 设备

    /// 切换模型、档位、会话模式与权限模式（AC-07.1）。只下发调用方明确给出的字段。
    public func configureSession(
        sessionId: String,
        mode: RACPSessionMode? = nil,
        permissionMode: RACPPermissionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil
    ) async throws -> RACPSessionSummary {
        let params = RACPSessionConfigureParams(
            sessionId: sessionId,
            mode: mode,
            providerId: providerId,
            modelId: modelId,
            thinkingLevel: thinkingLevel,
            permissionMode: permissionMode
        )
        let result: RACPSessionConfigureResult = try await request(.sessionConfigure, params: params)
        if attachedSession?.id == result.session.id { attachedSession = result.session }
        return result.session
    }

    /// 新建会话（AC-08.1 / AC-08.2）。
    public func createSession(
        title: String? = nil,
        projectId: String? = nil,
        mode: RACPSessionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil,
        permissionMode: RACPPermissionMode? = nil
    ) async throws -> RACPSessionSummary {
        let params = RACPSessionCreateParams(
            title: title,
            projectId: projectId,
            mode: mode,
            providerId: providerId,
            modelId: modelId,
            thinkingLevel: thinkingLevel,
            permissionMode: permissionMode
        )
        return try await createSession(params, idempotencyKey: "session_create_\(UUID().uuidString)")
    }

    public func createSession(_ draft: RACPSessionCreateParams, idempotencyKey: String) async throws -> RACPSessionSummary {
        var params = draft
        params.context = makeContext(idempotencyKey: idempotencyKey)
        let result: RACPSessionCreateResult = try await request(.sessionCreate, params: params)
        return result.session
    }

    /// 浏览服务器目录（AC-08.4）。
    public func browseProject(path: String? = nil) async throws -> RACPProjectBrowseResult {
        try await request(.projectBrowse, params: RACPProjectBrowseParams(path: path))
    }

    /// 注册服务器目录为项目（AC-08.4）。
    public func registerProject(path: String) async throws -> RACPProjectSummary {
        let result: RACPProjectRegisterResult = try await request(
            .projectRegister,
            params: RACPProjectRegisterParams(path: path)
        )
        return result.project
    }

    /// 撤销某台设备的配对（AC-03.1）。
    public func revokeDevice(deviceId: String) async throws -> Bool {
        guard !deviceId.isEmpty, !deviceId.contains(where: \.isWhitespace) else {
            throw RACPClientError.protocolMismatch("需要有效的 deviceId")
        }
        let context = RACPV2Context(
            requestId: "req_\(UUID().uuidString)",
            idempotencyKey: "revoke_\(UUID().uuidString)"
        )
        let params = RACPV2RevokeParams(deviceId: deviceId, context: context)
        let value: JSONValue = try await request(
            .revoke,
            params: .object([
                "deviceId": .string(params.deviceId),
                "context": .object([
                    "requestId": .string(params.context.requestId),
                    "idempotencyKey": .string(
                        params.context.idempotencyKey ?? "revoke_\(UUID().uuidString)"
                    ),
                ]),
            ])
        )
        let result = try RACPSessionRevokeResult.decoded(from: value)
        return result.revoked
    }

    /// Lets additive projections re-query after attach/rebuild without polling on every delta.
    public func sessionSnapshotGeneration() -> UInt64 { viewModel.historySnapshotGeneration }

    public func sessionView() -> RACPSessionView {
        RACPSessionView(
            sessionId: sessionId,
            summary: attachedSession,
            items: viewModel.items,
            activeItems: viewModel.activeItems,
            queuedTurns: QueuedTurn.parse(viewModel.queuedTurns),
            pendingApprovals: viewModel.pendingApprovals,
            expiredApprovalIds: viewModel.expiredApprovalIds,
            cursor: viewModel.cursor,
            revision: viewModel.revision,
            replayComplete: viewModel.lastReplayComplete,
            hasMoreHistory: viewModel.hasMoreHistory,
            runningTurnId: viewModel.activeTurnId,
            failedQueueStartID: viewModel.failedQueueStartID
        )
    }

    /// C1 is a value snapshot, never a shared mutable reducer or ACK lease.
    public func recoveryContext() -> RACPRecoveryContext {
        RACPRecoveryContext(
            hostCursor: hostSubscription.cursor,
            sessionId: subscribedSessionId ?? sessionId,
            sessionSummary: attachedSession,
            snapshot: viewModel.recoverySnapshot,
            replayComplete: viewModel.lastReplayComplete
        )
    }

    /// Applies C1 to this candidate only, then performs final host/session replay.
    /// The old active client is untouched and can keep reading and serving its UI.
    public func restoreRecoveryContext(_ context: RACPRecoveryContext) async throws -> RACPSessionView {
        guard state.isOnline else { throw RACPClientError.notConnected }
        if let hostCursor = context.hostCursor {
            hostSubscription.restoreCursor(hostCursor)
        } else {
            hostSubscription.resetAfterCursorExpired()
        }
        pendingHostAck = nil
        pendingHostAckDuringSubscribe = nil

        sessionAttachGeneration &+= 1
        subscriptionId = nil
        subscribedSessionId = nil
        pendingSessionAck = nil
        pendingSessionAckDuringSubscribe = nil
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        viewModel.resetForSession()
        attachedSession = nil
        sessionId = nil

        if let sessionId = context.sessionId {
            if let snapshot = context.snapshot {
                _ = viewModel.applySnapshot(snapshot, replayComplete: context.replayComplete)
                attachedSession = context.sessionSummary
                self.sessionId = sessionId
                subscribedSessionId = sessionId
                sessionEventsSuspended = false
            } else {
                _ = try await attach(sessionId: sessionId, subscribe: false)
            }
        }

        try await subscribeHost()
        if let sessionId = context.sessionId {
            try await subscribeSession(sessionId: sessionId, after: viewModel.cursor)
        }
        return sessionView()
    }

    /// 请求上下文：`requestId` 每次唯一；幂等键与期望 revision 由调用方给出。
    func makeContext(idempotencyKey: String? = nil, expectedRevision: Int? = nil) -> RACPContext {
        RACPContext(
            requestId: "req_\(UUID().uuidString)",
            idempotencyKey: idempotencyKey,
            expectedRevision: expectedRevision
        )
    }

    // MARK: 请求

    public func request<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: RACPMethod,
        params: P,
        timeout: TimeInterval = 20
    ) async throws -> R {
        let value = try await requestJSON(method, params: params, timeout: timeout)
        return try R.decoded(from: value)
    }

    public func request<R: Decodable & Sendable>(
        _ method: RACPMethod,
        params: JSONValue,
        timeout: TimeInterval = 20
    ) async throws -> R {
        let value = try await requestJSON(method, params: params, timeout: timeout)
        return try R.decoded(from: value)
    }

    func requestJSON<P: Encodable & Sendable>(
        _ method: RACPMethod,
        params: P,
        timeout: TimeInterval,
        recoveryScope: RequestRecoveryScope? = nil,
        allowReceiveProgress: Bool = false
    ) async throws -> JSONValue {
        if configuration.deviceToken?.hasPrefix("ppt2.") == true,
           method != .pair && method != .initialize {
            throw RACPClientError.protocolMismatch("配对连接只允许交换设备令牌")
        }
        guard let socket, canSendDuringCurrentPhase(method) else { throw RACPClientError.notConnected }
        let id = RACPIdentifier.number(nextRequestId)
        nextRequestId += 1
        let request = RACPRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RACPClientError.malformedFrame("请求编码失败")
        }
        // 先登记再发送：响应可能比登记更快到达，反序会丢响应并等到超时。
        let box = PendingRequest(recoveryScope: recoveryScope, method: method.rawValue)
        pending[id] = box
        do {
            // SSH 的同一字节流中，大响应会把后面的 pong 一起挡住。仅历史读取与
            // 内部心跳按真实入站进度延续空闲预算，写操作/握手期限保持不变。
            let progress = (allowReceiveProgress || method == .sessionAttach || method == .sessionHistory)
                ? socket.receiveProgress : nil
            let value = try await box.wait(
                timeout: timeout,
                method: method.rawValue,
                receiveProgress: progress,
                maximumDuration: allowReceiveProgress
                    ? racpHeartbeatProgressCeiling
                    : racpResponseProgressCeiling,
                send: { try await socket.send(text: text) },
                abandonSend: { Task { await socket.abort(.transportAborted) } }
            )
            pending.removeValue(forKey: id)
            return value
        } catch {
            pending.removeValue(forKey: id)
            let mappedError: Error = error is CancellationError || error is RACPClientError || error is RACPProviderDiscoveryError
                ? error
                : RACPClientError.notConnected
            box.resolve(.failure(mappedError))
            throw mappedError
        }
    }

    func canSendDuringCurrentPhase(_ method: RACPMethod) -> Bool {
        if promotionFenced {
            return state.isOnline && Self.fenceReadOnlyMethods.contains(method)
        }
        if state.isOnline { return true }
        let isPairingToken = configuration.deviceToken?.hasPrefix("ppt2.") == true
        if isPairingToken, method == .pair || method == .initialize {
            return socket != nil
        }
        switch status.phase {
        case .handshaking:
            return method == .initialize
        case .authenticating:
            return method == .initializedNotification
        case .verifyingIdentity:
            return method == .ping
        case .restoring:
            return Self.restoringMethods.contains(method)
        default:
            return false
        }
    }

    static let restoringMethods: Set<RACPMethod> = [
        .ping, .eventsSubscribe, .eventsUnsubscribe, .eventsAck,
        .sessionAttach, .sessionGet, .sessionList, .sessionHistory,
        .projectList, .projectBrowse, .turnGet,
    ]

    static let fenceReadOnlyMethods: Set<RACPMethod> = {
        var methods = restoringMethods
        methods.formUnion([
            .providerList, .providerDiscover, .skillList, .skillGet,
            .attachmentRead, .extensionList, .sessionExtensions,
        ])
        return methods
    }()

}
