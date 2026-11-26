import Foundation
import UIKit
import Combine
import PIiOSCore
import PIiOSNet


extension ConnectionModel {
#if DEBUG
    func installConnectionPiecesForTesting(
        oldClient: RACPClient,
        candidate: RACPClient? = nil,
        hostID: UUID
    ) {
        client = oldClient
        candidateClient = candidate
        cacheHostID = hostID
        state = .online
        connectionStatus = ConnectionStatus(phase: .online(.ssh), activeRoute: .ssh)
    }

    func runDirectCandidateForTesting(
        candidate: RACPClient,
        stream: AsyncStream<RACPClientUpdate>,
        record: HostRecord
    ) async {
        await runDirectCandidate(
            candidate,
            stream: stream,
            record: record,
            endpoint: record.directEndpoint ?? "",
            adaptorHostId: record.adaptorHostId ?? "",
            brokerID: UUID(),
            intent: connectionIntentGeneration,
            expectedGeneration: connectionGeneration
        )
    }
#endif

    // MARK: - RACP 隧道

    /// 建立隧道并拉取 `project/list` / `session/list`。
    ///
    /// 前提是 Keychain 里已有凭证与设备令牌；缺任何一项都直接给出原因，不假装在线。
    func connect(record requested: HostRecord, preserveSessionView: Bool = false) async {
        // 日志：连接开始只落 host UUID 前 8 位与 hostPort，不落用户名/密码/私钥/令牌。
        let hostLabel = requested.id.uuidString.prefix(8)
        let logStartedAt = Date()
        PILog.info(
            "Connection",
            "connect start host=\(hostLabel) hostPort=\(requested.hostPort.map { String($0) } ?? "-")"
        )
        connectionIntentGeneration &+= 1
        let intent = connectionIntentGeneration
        await disconnectCurrent(expectedIntent: intent, preserveSessionView: preserveSessionView)
        guard intent == connectionIntentGeneration,
              cacheHostID == requested.id
        else {
            PILog.debug(
                "Connection",
                "connect cancelled host=\(hostLabel) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
            )
            return
        }
        if fixtureConnectIfApplicable(hostID: requested.id, hostLabel: hostLabel) {
            return
        }
        guard let record = prepareHostConnection(requested) else {
            state = .offline(reason: "配对记录待恢复：请重新连接以重试保存。")
            return
        }
        guard record.pairedAt != nil else {
            PILog.warn("Connection", "connect failed host=\(hostLabel) category=notPaired")
            state = .offline(reason: "本机记录尚未配对：请先完成 PI-adaptor 配对")
            return
        }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let token = KeychainStore.loadDeviceToken(hostID: record.id) else {
            PILog.warn("Connection", "connect failed host=\(hostLabel) category=missingDeviceToken")
            state = .offline(reason: "本机没有设备令牌：请到服务器页用一次性令牌完成配对")
            return
        }
        let preference = record.connectionPreference
        var directConfiguration: DirectRACPConfiguration?
        if preference == .directPreferred {
            guard let endpointText = record.directEndpoint,
                  let endpoint = URL(string: endpointText),
                  let adaptorHostId = record.adaptorHostId,
                  let pin = KeychainStore.loadDirectTLSTrustPin(hostID: record.id),
                  pin.hostId == adaptorHostId,
                  token.hasPrefix("pdt2.")
            else {
                PILog.warn("Connection", "connect failed host=\(hostLabel) category=missingDirectConfig")
                state = .offline(reason: "direct 配置缺少已授权 pin、endpoint、hostId 或 pdt2，不能直连")
                return
            }
            directConfiguration = DirectRACPConfiguration(
                endpoint: endpoint,
                certificateSHA256: pin.certificateSHA256,
                adaptorHostId: adaptorHostId
            )
        }

        let credential = KeychainStore.loadCredential(account: account)
        if preference == .sshOnly, credential == nil {
            PILog.warn("Connection", "connect failed host=\(hostLabel) category=missingCredential")
            state = .offline(reason: "本机没有保存这台服务器的凭证：请先在服务器页「保存并测试连接」")
            return
        }
        let pinned = KeychainStore.loadHostKey(account: account)
        var hostPort = record.hostPort
        if preference == .sshOnly {
            guard let credential else {
                PILog.warn("Connection", "connect failed host=\(hostLabel) category=missingCredential")
                state = .offline(reason: "本机没有保存这台服务器的凭证")
                return
            }
            hostPort = await resolveHostPort(
                record: record,
                credential: credential,
                account: account,
                pinned: pinned
            )
            guard hostPort != nil else {
                PILog.warn("Connection", "connect failed host=\(hostLabel) category=hostPortUnresolved")
                state = .offline(reason: "无法确定 PI-adaptor 端口：SSH 探测失败且未记录端口")
                return
            }
        }
        if intent == connectionIntentGeneration, cacheHostID == record.id,
           !activeAdaptorInstalls.contains(record.id),
           let hostPort, let adaptorHostId = record.adaptorHostId {
            await recoverReplacedPairings(record: record, port: hostPort, adaptorHostId: adaptorHostId)
        }
        guard intent == connectionIntentGeneration, cacheHostID == record.id,
              KeychainStore.loadDeviceToken(hostID: record.id) == token else {
            PILog.debug(
                "Connection",
                "connect cancelled host=\(hostLabel) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
            )
            return
        }
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        connectionBrokerID = operationID
        connectedAccount = account
        let sshRequest = credential.map {
            SSHConnectionRequest(
                host: record.host,
                port: record.port,
                username: record.username,
                credential: $0,
                pinnedHostKey: pinned
            )
        }
        let configuration = RACPConfiguration(
            ssh: sshRequest,
            hostPort: hostPort,
            deviceToken: token,
            connectionPreference: preference,
            direct: directConfiguration
        )
        // 日志计时在真正创建客户端前开始，供 apply 里首次 online/offline 计算耗时。
        connectLogStartedAt = logStartedAt
        let newClient = RACPClient(configuration: configuration, confirmer: promptBroker)
        client = newClient
        connectionGeneration &+= 1
        cacheClientID = UUID()
        let generation = connectionGeneration
        invalidateCatalogLoads()
        session.bind(client: newClient, online: false, preserveView: preserveSessionView)
        let stream = await newClient.start()
        guard self.client === newClient, connectionGeneration == generation else {
            connectLogStartedAt = nil
            PILog.debug(
                "Connection",
                "connect cancelled host=\(hostLabel) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
            )
            releaseHostKeyBroker(operationID)
            _ = await newClient.stopBestEffort(timeout: 1)
            return
        }
        updateTask = Task { [weak self] in
            await newClient.enableSessionChangeCoalescing()
            guard !Task.isCancelled else { return }
            for await update in stream {
                await self?.apply(update, client: newClient, generation: generation)
            }
        }
        let statusStream = await newClient.statusStream()
        statusTask = Task { [weak self] in
            for await next in statusStream {
                guard let self, self.client === newClient, self.connectionGeneration == generation else {
                    return
                }
                self.connectionStatus = next
            }
        }
        PILog.debug(
            "Connection",
            "connect setup done host=\(hostLabel) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
        )
    }

    /// Starts a direct candidate while the old SSH client remains active and readable.
    /// Only a successful final C1 replay can atomically replace the active generation.
    func retryDirect(record requested: HostRecord) async {
        guard let record = prepareHostConnection(requested) else {
            lastError = "配对记录待恢复：请重新连接以重试保存。"
            return
        }
        // 日志：直连候选属于重连尝试，只记 debug。
        PILog.debug("Connection", "direct retry start host=\(record.id.uuidString.prefix(8))")
        guard client != nil, state.isOnline, connectionStatus.activeRoute == .ssh,
              candidateClient == nil, cacheHostID == record.id,
              let token = KeychainStore.loadDeviceToken(hostID: record.id), token.hasPrefix("pdt2."),
              let endpointText = record.directEndpoint,
              let endpoint = URL(string: endpointText),
              let adaptorHostId = record.adaptorHostId,
              let pin = KeychainStore.loadDirectTLSTrustPin(hostID: record.id),
              pin.hostId == adaptorHostId
        else {
            PILog.debug("Connection", "direct retry skipped host=\(record.id.uuidString.prefix(8)) reason=precondition")
            lastError = "direct candidate 缺少已验证 endpoint、pin、hostId 或活动 SSH 连接"
            return
        }
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: KeychainStore.account(username: record.username, host: record.host, port: record.port),
            address: record.address
        )
        let candidate = RACPClient(
            configuration: RACPConfiguration(
                ssh: nil,
                hostPort: nil,
                deviceToken: token,
                connectionPreference: .directPreferred,
                direct: DirectRACPConfiguration(
                    endpoint: endpoint,
                    certificateSHA256: pin.certificateSHA256,
                    adaptorHostId: adaptorHostId
                )
            ),
            confirmer: promptBroker
        )
        let candidateIntent = connectionIntentGeneration
        let expectedGeneration = connectionGeneration
        candidateClient = candidate
        let stream = await candidate.start()
        guard connectionIntentGeneration == candidateIntent,
              connectionGeneration == expectedGeneration,
              candidateClient === candidate
        else {
            _ = await candidate.stopBestEffort(timeout: 1)
            releaseHostKeyBroker(operationID)
            return
        }
        candidateTask = Task { [weak self] in
            await self?.runDirectCandidate(
                candidate,
                stream: stream,
                record: record,
                endpoint: endpointText,
                adaptorHostId: adaptorHostId,
                brokerID: operationID,
                intent: candidateIntent,
                expectedGeneration: expectedGeneration
            )
        }
    }

    func prepareHostConnection(_ requested: HostRecord) -> HostRecord? {
        if let onPrepareHostConnection { return onPrepareHostConnection(requested.id) }
        return requested
    }

    func runDirectCandidate(
        _ candidate: RACPClient,
        stream: AsyncStream<RACPClientUpdate>,
        record: HostRecord,
        endpoint: String,
        adaptorHostId: String,
        brokerID: UUID,
        intent: Int,
        expectedGeneration: Int
    ) async {
        guard let oldClient = client else {
            _ = await candidate.stopBestEffort(timeout: 1)
            releaseHostKeyBroker(brokerID)
            return
        }
        let oldGeneration = expectedGeneration
        let oldActiveGeneration = await oldClient.connectionStatus().activeGeneration
        var didInstallCandidate = false
        do {
            var reachedInitialOnline = false
            for await update in stream {
                if case .state(.online) = update {
                    reachedInitialOnline = true
                    break
                }
                if case .state(.offline(let reason)) = update {
                    throw RACPClientError.protocolMismatch(reason ?? "direct candidate 未能上线")
                }
            }
            guard reachedInitialOnline,
                  !Task.isCancelled,
                  client === oldClient,
                  candidateClient === candidate,
                  connectionGeneration == oldGeneration,
                  connectionIntentGeneration == intent,
                  cacheHostID == record.id
            else { throw ConnectionLifecycleError.connectionChanged }

            await oldClient.setPromotionFenced(true)
            let context = await oldClient.recoveryContext()
#if DEBUG
            if !skipCandidateRestoreForTesting {
                _ = try await candidate.restoreRecoveryContext(context)
            }
#else
            _ = try await candidate.restoreRecoveryContext(context)
#endif
            guard !Task.isCancelled,
                  client === oldClient,
                  candidateClient === candidate,
                  connectionGeneration == oldGeneration,
                  connectionIntentGeneration == intent,
                  cacheHostID == record.id
            else { throw ConnectionLifecycleError.connectionChanged }

            func assertCandidateContext() throws {
                guard !Task.isCancelled,
                      client === oldClient,
                      candidateClient === candidate,
                      connectionGeneration == oldGeneration,
                      connectionIntentGeneration == intent,
                      cacheHostID == record.id
                else { throw ConnectionLifecycleError.connectionChanged }
            }
            let candidateStatus = await candidate.connectionStatus()
            try assertCandidateContext()
            let candidateInfo = await candidate.info()
            try assertCandidateContext()
            let candidateStatusStream = await candidate.statusStream()
            try assertCandidateContext()
#if DEBUG
            await beforeOldStatusCheckForTesting?()
#endif
            let oldStatus = await oldClient.connectionStatus()
            try assertCandidateContext()
            guard oldStatus.activeGeneration == oldActiveGeneration,
                  oldStatus.activeRoute == .ssh,
                  oldStatus.phase == .online(.ssh)
            else { throw ConnectionLifecycleError.connectionChanged }

            // Atomic pointer exchange: no old-view mutation happened above.
            connectionGeneration &+= 1
            let generation = connectionGeneration
            updateTask?.cancel()
            statusTask?.cancel()
            cacheClientID = UUID()
            client = candidate
            candidateClient = nil
            didInstallCandidate = true
            session.bind(client: candidate, online: true)
            connectionStatus = candidateStatus
            info = candidateInfo
            state = .online
            // 日志：直连候选切换成功，属于重连尝试结果，只记 debug。
            PILog.debug("Connection", "direct retry promoted host=\(record.id.uuidString.prefix(8))")
            connectionBrokerID = brokerID
#if DEBUG
            if candidatePostPromotionDelayForTesting > 0 {
                try? await Task.sleep(for: .milliseconds(Int(candidatePostPromotionDelayForTesting * 1000)))
            }
#endif
            guard !Task.isCancelled,
                  client === candidate,
                  connectionGeneration == generation,
                  connectionIntentGeneration == intent
            else { throw ConnectionLifecycleError.connectionChanged }
            _ = await oldClient.stopBestEffort(timeout: 1)
            guard !Task.isCancelled,
                  client === candidate,
                  connectionGeneration == generation,
                  connectionIntentGeneration == intent
            else { throw ConnectionLifecycleError.connectionChanged }
            onDirectVerified?(record.id, endpoint, adaptorHostId)
            updateTask = Task { [weak self] in
                await candidate.enableSessionChangeCoalescing()
                guard !Task.isCancelled else { return }
                for await update in stream {
                    await self?.apply(update, client: candidate, generation: generation)
                }
            }
            statusTask = Task { [weak self] in
                for await next in candidateStatusStream {
                    guard let self, self.client === candidate, self.connectionGeneration == generation else {
                        return
                    }
                    self.connectionStatus = next
                }
            }
            candidateTask = nil
        } catch {
            await oldClient.setPromotionFenced(false)
            if !didInstallCandidate {
                let previousStatus = await oldClient.connectionStatus()
                if client === oldClient,
                   connectionGeneration == oldGeneration,
                   connectionIntentGeneration == intent {
                    connectionStatus = previousStatus
                    switch previousStatus.phase {
                    case .online:
                        state = .online
                        session.bind(client: oldClient, online: true)
                    case .reconnecting(_, let attempt, let delay):
                        state = .reconnecting(
                            attempt: attempt,
                            delay: delay,
                            reason: error.localizedDescription
                        )
                        session.bind(client: oldClient, online: false)
                    default:
                        state = .offline(reason: error.localizedDescription)
                        session.bind(client: oldClient, online: false)
                    }
                    lastError = error.localizedDescription
                }
            } else {
                _ = await oldClient.stopBestEffort(timeout: 1)
            }
            _ = await candidate.stopBestEffort(timeout: 1)
            if candidateClient === candidate {
                candidateClient = nil
                candidateTask = nil
            }
            releaseHostKeyBroker(brokerID)
        }
    }

    func disconnect() async {
        // 日志：主动断开的时间轴；只落 host UUID 前 8 位，不落凭证。
        let startedAt = Date()
        PILog.info("Connection", "disconnect start host=\(cacheHostID.map { String($0.uuidString.prefix(8)) } ?? "-")")
        connectionIntentGeneration &+= 1
        await disconnectCurrent(expectedIntent: connectionIntentGeneration)
        PILog.info(
            "Connection",
            "disconnect end host=\(cacheHostID.map { String($0.uuidString.prefix(8)) } ?? "-") elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
    }

    /// Only close the connection if the PI-adaptor that requested teardown is still active.
    /// A stale PI-adaptor action must never disconnect the connection installed by a newer switch.
    func disconnect(ifHostID expectedHostID: UUID, preserveSessionView: Bool = false) async {
        guard cacheHostID == expectedHostID else {
            PILog.debug(
                "Connection",
                "disconnect skipped host=\(expectedHostID.uuidString.prefix(8)) reason=hostChanged"
            )
            return
        }
        let startedAt = Date()
        PILog.info("Connection", "disconnect start host=\(expectedHostID.uuidString.prefix(8)) reason=adaptorRequest")
        connectionIntentGeneration &+= 1
        await disconnectCurrent(
            expectedIntent: connectionIntentGeneration,
            expectedHostID: expectedHostID,
            preserveSessionView: preserveSessionView
        )
        PILog.info(
            "Connection",
            "disconnect end host=\(expectedHostID.uuidString.prefix(8)) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
    }

    func disconnectCurrent(
        expectedIntent: Int,
        expectedHostID: UUID? = nil,
        preserveSessionView: Bool = false
    ) async {
        let generation = connectionGeneration
        guard expectedIntent == connectionIntentGeneration,
              connectionGeneration == generation,
              expectedHostID == nil || cacheHostID == expectedHostID
        else { return }

        // 日志：断开后没有待完成的 connect 计时。
        connectLogStartedAt = nil

        // The caller already fenced connection intent, so candidates cannot promote
        // while the last valid draft/session writes drain under the outgoing lease.
        let needsOutgoingFlush = client != nil || candidateClient != nil || hasPendingCacheMutations
        if needsOutgoingFlush {
            await flushPendingCacheWrites()
        } else {
            PILog.debug("Cache", "disconnect flush skipped reason=cleanStart")
        }
        guard expectedIntent == connectionIntentGeneration,
              connectionGeneration == generation,
              expectedHostID == nil || cacheHostID == expectedHostID else { return }
        connectionGeneration &+= 1
        let invalidatedGeneration = connectionGeneration
        cacheClientID = UUID()
        invalidateCatalogLoads()
        cancelHostCatalogRefresh()
        updateTask?.cancel()
        updateTask = nil
        statusTask?.cancel()
        statusTask = nil
        candidateTask?.cancel()
        candidateTask = nil
        let oldCandidate = candidateClient
        candidateClient = nil
        let oldClient = client
        client = nil
        for broker in brokers.values { broker.cancel() }
        hostKeyPrompt = nil
        if let connectionBrokerID {
            brokers.removeValue(forKey: connectionBrokerID)
        }
        connectionBrokerID = nil
        session.bind(client: nil, online: false, preserveView: preserveSessionView)
        connectedAccount = nil
        connectionStatus = ConnectionStatus()
        state = .offline(reason: nil)
        let candidateStop = Task {
            if let oldCandidate { _ = await oldCandidate.stopBestEffort(timeout: 1) }
        }
        let activeStop = Task {
            if let oldClient { _ = await oldClient.stopBestEffort(timeout: 1) }
        }

#if DEBUG
        if disconnectFlushDelayForTesting > 0 {
            try? await Task.sleep(for: .milliseconds(Int(disconnectFlushDelayForTesting * 1000)))
        }
#endif
        if needsOutgoingFlush || hasPendingCacheMutations { await flushPendingCacheWrites() }
        if expectedIntent == connectionIntentGeneration,
           connectionGeneration == invalidatedGeneration {
            projects = []
            sessions = []
            info = nil
            hasLoadedCatalog = false
            catalogError = nil
        }
        _ = await candidateStop.value
        _ = await activeStop.value
    }

    func notifyOnlineWaitersIfNeeded() {
        guard state.isOnline, !onlineWaiters.isEmpty else { return }
        let waiters = onlineWaiters
        onlineWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: true)
        }
    }

    func waitUntilOnline(timeout: TimeInterval = 30) async -> Bool {
        if let fixtureResult = fixtureWaitUntilOnlineResult() { return fixtureResult }
        if state.isOnline { return true }
        guard !Task.isCancelled, timeout > 0 else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.state.isOnline || Task.isCancelled {
                    continuation.resume(returning: self.state.isOnline)
                    return
                }
                self.onlineWaiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, let waiter = self.onlineWaiters.removeValue(forKey: waiterID) else { return }
                    waiter.resume(returning: self.state.isOnline)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let waiter = self.onlineWaiters.removeValue(forKey: waiterID) else { return }
                waiter.resume(returning: false)
            }
        }
    }

    /// 回到前台时先做一次短预算的认证往返，确认「看起来在线」的隧道真的还能收发。
    ///
    /// iOS 挂起进程不会主动改写 `state`，但 socket 可能已被系统回收或网络切换打断。
    /// 只等 10s 心跳 + 5s 超时 ×2，用户会在「在线」界面下卡住半分钟才看到断开重连；
    /// 探测失败时调用方应立即重建连接。
    func verifyConnectionLiveness(timeout: TimeInterval = 4) async -> Bool {
        if let liveness = fixtureVerifyConnectionLivenessResult() { return liveness }
        guard state.isOnline, let client else { return false }
        do {
            try await client.ping(timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// 重新拉取项目与会话列表（只在在线时可用）。
    @discardableResult
    func refreshRemote(timeout: TimeInterval = 30) async -> Bool {
        guard let client else { return false }
        let connection = connectionGeneration
        catalogGeneration &+= 1
        let generation = catalogGeneration
        isRefreshingCatalog = true
        defer {
            if catalogGeneration == generation {
                isRefreshingCatalog = false
            }
        }
        do {
            // Split the caller's total budget across the two sequential catalog calls.
            let perRequestTimeout = max(0.1, timeout / 2)
            let remoteProjects = try await client.listProjects(timeout: perRequestTimeout)
            let remoteSessions = try await client.listSessions(timeout: perRequestTimeout)
            guard self.client === client,
                  connectionGeneration == connection,
                  catalogGeneration == generation
            else { return false }
            projects = remoteProjects
            sessions = remoteSessions
            hasLoadedCatalog = true
            catalogError = nil
            lastError = nil
            // 权威目录已完整到达：把缓存里权威列表已不存在的会话清掉，否则另一台
            // 设备删除会话后，本机刷新时虽不再显示，随后离线又会从缓存里把它翻出来。
            reconcileOfflineCache(with: remoteSessions)
            return true
        } catch {
            guard self.client === client,
                  connectionGeneration == connection,
                  catalogGeneration == generation
            else { return false }
            let message = ConnectionErrorText.describe(error)
            catalogError = message
            // 目录刷新失败常见于「旧 socket 正被替换」的竞态（请求在 teardown 后发出，
            // 得到 notConnected/channelClosed）。此时隧道可能已经重新在线；把这种
            // 瞬时失败写进「最近一次错误」会表现为「在线 + 当前离线错误」，和真正的
            // 断线提示混在一起。只有隧道此刻确实不在线时才记录连接级错误。
            if !state.isOnline {
                lastError = message
            }
            return false
        }
    }

    /// `project/browse`：逐级浏览服务器目录（AC-08.4）。
    func browseProject(path: String?) async throws -> RACPProjectBrowseResult {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let result = try await client.browseProject(path: path)
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        return result
    }

    /// `project/register`：把服务器目录注册为项目（AC-08.4）。
    func registerProject(path: String) async throws -> RACPProjectSummary {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        invalidateCatalogLoads()
        let connection = connectionGeneration
        let project = try await client.registerProject(path: path)
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        // 注册回执本身已足以更新项目页；随后 refreshRemote 只负责补齐其他项。
        projects = ProjectCatalogRules.upsert(project, in: projects)
        return project
    }

    func invalidateCatalogLoads() {
        catalogGeneration &+= 1
        isRefreshingCatalog = false
    }

    /// `session/create`：在项目中新建会话（AC-08.2）。
    ///
    /// 带上本机默认 provider/model 后，会话创建即处于可发送的模型绑定状态；
    /// 没有默认模型时保持原行为（绑定留空，由用户在会话配置里选择）。
    func createSession(
        title: String?,
        projectId: String?,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: String? = nil
    ) async throws -> RACPSessionSummary {
        guard let client, let hostID = cacheHostID, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let params = RACPSessionCreateParams(
            title: title,
            projectId: projectId,
            providerId: providerId,
            modelId: modelId,
            thinkingLevel: thinkingLevel.flatMap(RACPThinkingLevel.init(rawValue:))
        )
        let attempt = try requestKeys.prepare(SessionRequestIdentity(
            hostID: hostID.uuidString,
            sessionID: projectId ?? "no-project",
            action: .sessionCreate(params)
        ))
        let created = try await client.createSession(params, idempotencyKey: attempt.idempotencyKey)
        guard self.client === client, connectionGeneration == connection, cacheHostID == hostID else {
            throw ConnectionLifecycleError.connectionChanged
        }
        try requestKeys.acknowledge(attempt)
        return created
    }

    /// 在线归档或恢复会话；只有 Host 回执与当前连接代际均匹配才提交目录。
    func archiveSession(
        sessionId: String,
        archived: Bool
    ) async throws -> RACPSessionSummary {
        if let updated = try fixtureArchiveSessionIfApplicable(sessionId: sessionId, archived: archived) {
            return updated
        }
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let hostID = cacheHostID
        invalidateCatalogLoads()
        let result = try await client.archiveSession(sessionId: sessionId, archived: archived)
        guard self.client === client,
              connectionGeneration == connection,
              cacheHostID == hostID,
              result.session.id == sessionId
        else {
            if result.session.id != sessionId {
                throw RACPClientError.protocolMismatch("归档回执目标不一致")
            }
            throw ConnectionLifecycleError.connectionChanged
        }
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index] = result.session
        } else {
            sessions.append(result.session)
        }
        return result.session
    }

    /// 删除会话并提交目录与缓存；本机 binding 由 AppModel 在此返回后收尾。
    func deleteSession(
        sessionId: String,
        confirmSessionId: String
    ) async throws -> RACPV2SessionDeleteResult {
        if let result = try fixtureDeleteSessionIfApplicable(sessionId: sessionId, confirmSessionId: confirmSessionId) {
            return result
        }
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let hostID = cacheHostID
        PILog.debug(
            "Session",
            "delete request session=\(sessionId.prefix(8)) host=\(hostID.map { String($0.uuidString.prefix(8)) } ?? "-")"
        )
        invalidateCatalogLoads()
        let result = try await client.deleteSession(
            sessionId: sessionId,
            confirmSessionId: confirmSessionId
        )
        guard self.client === client,
              connectionGeneration == connection,
              cacheHostID == hostID
        else { throw ConnectionLifecycleError.connectionChanged }
        guard result.deleted,
              result.sessionId == sessionId,
              result.sessionId == confirmSessionId
        else { throw RACPClientError.protocolMismatch("删除回执未确认目标") }
        PILog.debug("Session", "delete receipt ok session=\(sessionId.prefix(8))")
        // Host 明确成功是唯一成功前提。缓存清理只是本机收尾：即使 flush 失败，
        // 也不能把已经成功的服务器删除改报为失败，否则会话会留在界面且重试只会得到 NOT_FOUND。
        // 使用请求开始时捕获的 hostID，避免等待期间切换 Host 后按新 cacheHostID
        // 误清另一台 Host 的同 ID 会话缓存。
        removeCachedSessions([sessionId], hostID: hostID)
        let flushed = await cacheStore.flushResult()
        if case .failed(let error) = flushed.outcome {
            PILog.warn(
                "Session",
                "delete cache cleanup failed session=\(sessionId.prefix(8)) error=\(error.localizedDescription); host delete already succeeded"
            )
        }
        // Host 已明确成功。连接在这之后变化时，不再把已验证的服务器删除改报为失败；
        // 只跳过当前目录清理（避免误删切换后 Host 的同 ID 会话），本机 binding 收尾
        // 仍由 SidebarView 用捕获的旧 hostID 完成。
        if self.client === client,
           connectionGeneration == connection,
           cacheHostID == hostID {
            sessions.removeAll { $0.id == sessionId }
        } else {
            PILog.warn(
                "Session",
                "delete local catalog commit skipped session=\(sessionId.prefix(8)) reason=connectionChanged"
            )
        }
        return result
    }

    func respondHostKey(_ confirmation: HostKeyConfirmation, operationID: UUID) {
        guard let prompt = hostKeyPrompt,
              prompt.operationID == operationID,
              let broker = brokers[prompt.operationID]
        else { return }
        if confirmation == .trust, prompt.status == .firstUse {
            // 首次固定：必须先成功写入 Keychain，才能记录 pinned 审计并放行本次
            // 握手。写入失败却继续 trust 会让用户误以为指纹已固定，下次仍按首次
            // 连接处理，也失去 TOFU 的实际保护。
            guard KeychainStore.saveHostKey(prompt.key, account: prompt.account) else {
                hostKeyPrompt = nil
                lastError = "无法保存主机指纹，已拒绝本次连接；请检查设备锁与签名后重试"
                broker.respond(.reject)
                return
            }
            HostKeyAuditLog.append(
                HostKeyAuditEvent(
                    kind: .pinned,
                    hostAddress: prompt.address,
                    fingerprint: prompt.key.fingerprint
                )
            )
        }
        // DEF-R4-004：`.changed` 态 UI 不提供「信任」入口；即便收到 trust 也强制拒绝（AC-02.2），
        // 并补记 mismatchRejected 审计事件（AC-02.3）。
        if case .changed(let pinned) = prompt.status {
            HostKeyAuditLog.append(
                HostKeyAuditEvent(
                    kind: .mismatchRejected,
                    hostAddress: prompt.address,
                    fingerprint: prompt.key.fingerprint,
                    previousFingerprint: pinned.fingerprint
                )
            )
            hostKeyPrompt = nil
            broker.respond(.reject)
            return
        }
        hostKeyPrompt = nil
        broker.respond(confirmation)
    }

    /// AC-02.3 的两步操作第一步：显式移除旧指纹（第二步是重新连接并确认新指纹）。
    func removeHostKeyPin(account: String, address: String, previousFingerprint: String?) {
        KeychainStore.deleteHostKey(account: account)
        HostKeyAuditLog.append(
            HostKeyAuditEvent(
                kind: .pinRemoved,
                hostAddress: address,
                fingerprint: previousFingerprint ?? "",
                previousFingerprint: previousFingerprint
            )
        )
    }

    // MARK: - 更新流

    func apply(
        _ update: RACPClientUpdate,
        client: RACPClient,
        generation: Int
    ) async {
        guard self.client === client, connectionGeneration == generation else { return }
        switch update {
        case .state(let newState):
            let sanitizedState = Self.sanitizedForDisplay(newState)
            state = sanitizedState
            session.setOnline(sanitizedState.isOnline)
            // 日志：连接时间轴。成功/失败带耗时与稳定分类；重连尝试只记 debug，避免刷屏。
            switch sanitizedState {
            case .online:
                if let startedAt = connectLogStartedAt {
                    connectLogStartedAt = nil
                    PILog.info(
                        "Connection",
                        "connect ok host=\(cacheHostID.map { String($0.uuidString.prefix(8)) } ?? "-") route=\(connectionStatus.activeRoute?.rawValue ?? "-") elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    )
                }
            case .offline(let reason):
                let hostLabel = cacheHostID.map { String($0.uuidString.prefix(8)) } ?? "-"
                if let startedAt = connectLogStartedAt {
                    connectLogStartedAt = nil
                    PILog.warn(
                        "Connection",
                        "connect failed host=\(hostLabel) category=\(ConnectionFailureClassifier.classify(message: reason).rawValue) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    )
                } else {
                    PILog.warn(
                        "Connection",
                        "tunnel offline host=\(hostLabel) category=\(ConnectionFailureClassifier.classify(message: reason).rawValue)"
                    )
                }
            case .reconnecting(let attempt, let delay, let reason):
                PILog.debug(
                    "Connection",
                    "reconnect attempt=\(attempt) delayMs=\(Int(delay * 1000)) host=\(cacheHostID.map { String($0.uuidString.prefix(8)) } ?? "-") category=\(ConnectionFailureClassifier.classify(message: reason).rawValue)"
                )
            default:
                break
            }
            if sanitizedState.isOnline {
                // 新连接已经完成握手 + 身份验证：上一轮退避期间留下的「离线/通道已关闭」
                // 不能再挂在「最近一次错误」里，否则界面显示在线却同时报离线，用户会以为
                // 连接建立后立刻断开。真正的失败会在后续 refresh 或下一次状态变化时重新写入。
                lastError = nil
                await refreshRemote()
                await session.refreshView(source: "connectionOnline")
                await refreshExtensionInventory()
                if let id = session.attachedSessionId { await refreshSessionExtensions(id) }
                scheduleCacheSessionState()
            } else {
                cancelHostCatalogRefresh()
            }
        case .ready(let serverInfo):
            info = serverInfo
        case .hostSnapshot(let remoteProjects, let remoteSessions):
            projects = remoteProjects
            sessions = remoteSessions
            hasLoadedCatalog = true
            catalogError = nil
            reconcileOfflineCache(with: remoteSessions)
        case .hostChanged:
            scheduleHostCatalogRefresh(client: client, generation: generation)
        case .sessionChanged:
            guard let receipt = await client.beginSessionChangeConsumption() else { return }
            await session.refreshView(source: "sessionEvent")
            scheduleCacheSessionState()
            let snapshotGeneration = await client.sessionSnapshotGeneration()
            if extensionSnapshotGeneration != snapshotGeneration {
                extensionSnapshotGeneration = snapshotGeneration
                if let id = session.attachedSessionId { await refreshSessionExtensions(id) }
            }
            await client.finishSessionChangeConsumption(receipt)
        case .event(let event):
            if event.kind == "session.extensions.updated" {
                let snapshot = await Task.detached { event.extensionSnapshot }.value
                guard self.client === client, connectionGeneration == generation else { return }
                if let snapshot, snapshot.sessionId == session.attachedSessionId,
                   extensions.observe(snapshot, epoch: event.epoch, sequence: event.durableSequence) {
                    await refreshSessionExtensions(snapshot.sessionId)
                }
            } else if event.kind == "turn.completed" || event.kind == "turn.failed"
                        || event.kind == "turn.interrupted" || event.kind == "turn.canceled" {
#if DEBUG
                if SessionController.observesUITestTurnOutcome,
                   let turn = event.payload.value(at: ["payload", "turn"]),
                   let outcome = try? RACPTurnRef.decoded(from: turn),
                   outcome.sessionId == session.attachedSessionId {
                    uiTestTerminalTurn = outcome
                }
#endif
                if let id = session.attachedSessionId { await refreshSessionExtensions(id) }
            }
        case .error(let code, _):
            lastError = ConnectionFailureClassifier.userMessage(forRACPCode: code)
        }
    }

    static func sanitizedForDisplay(_ state: RACPTunnelState) -> RACPTunnelState {
        switch state {
        case .offline(let reason):
            return .offline(reason: reason.map {
                ConnectionFailureClassifier.classify(message: $0).userMessage
            })
        case .reconnecting(let attempt, let delay, let reason):
            return .reconnecting(
                attempt: attempt,
                delay: delay,
                reason: ConnectionFailureClassifier.classify(message: reason).userMessage
            )
        default:
            return state
        }
    }

    /// PI-adaptor 事件可能一帧一个，但目录只需要每个短窗口刷新一次；刷新期间继续到达的
    /// 变更会合并成下一批，避免 N 个会话 revision 触发 N 次 `project/list` + `session/list`。
    func scheduleHostCatalogRefresh(client: RACPClient, generation: Int) {
        guard self.client === client, connectionGeneration == generation else { return }
        hostCatalogRefreshPending = true
        guard hostCatalogRefreshTask == nil else { return }

        let token = UUID()
        hostCatalogRefreshToken = token
        hostCatalogRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.hostCatalogRefreshToken == token,
                  self.client === client,
                  self.connectionGeneration == generation
            else { return }

            while self.hostCatalogRefreshPending {
                self.hostCatalogRefreshPending = false
                await self.refreshRemote()

                guard self.hostCatalogRefreshToken == token,
                      self.client === client,
                      self.connectionGeneration == generation,
                      self.hostCatalogRefreshPending
                else { break }
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    break
                }
            }

            guard self.hostCatalogRefreshToken == token else { return }
            self.hostCatalogRefreshTask = nil
            self.hostCatalogRefreshToken = nil
            self.hostCatalogRefreshPending = false
        }
    }

    func cancelHostCatalogRefresh() {
        hostCatalogRefreshTask?.cancel()
        hostCatalogRefreshTask = nil
        hostCatalogRefreshToken = nil
        hostCatalogRefreshPending = false
    }

    // MARK: - 撤销本机配对（AC-03.1）

    /// 用 `connection/pair` 保存下来的 `deviceId` 调 v2 `connection/revoke`。
    ///
    /// 只有服务器确认 `revoked == true` 才算撤销成功；离线、缺设备 ID、服务器拒绝都要如实报告，
    /// 不能因为「本机已删掉凭证」就当成服务器侧已撤销。
    ///
    /// DEF-R4-003：撤销动作与隧道状态更新存在竞态——界面显示在线时，`state`/`client`
    /// 可能正处于断开重建的中间快照。这里先等待一次稳定在线再重判，
    /// 并把「正在重连的竞态」与「真离线」两种文案区分开。
    func revokeThisDevice(host: HostRecord) async -> String {
        guard cacheHostID == host.id else {
            return "目标服务器不是当前连接：未发送撤销请求"
        }
        if let message = fixtureRevokeDeviceMessageIfApplicable() {
            return message
        }
        guard let deviceId = KeychainStore.loadDeviceId(hostID: host.id) else {
            return "本机没有保存的 deviceId：无法向服务器撤销，只清除了本地凭证"
        }
        var activeClient = client
        if activeClient == nil || !state.isOnline {
            // 可能是断开重建的窗口期：给一次短暂等待，避免把竞态误报成离线。
            _ = await waitUntilOnline(timeout: 3)
            activeClient = client
        }
        guard let activeClient, state.isOnline else {
            if isTransientDisconnect {
                return "正在重新连接服务器：请稍后重试撤销，本机凭证尚未改动"
            }
            return "当前处于离线状态：恢复手机网络或 VPN 后再试。"
        }
        do {
            let revoked = try await activeClient.revokeDevice(deviceId: deviceId)
            return revoked
                ? Self.deviceRevokedMessage
                : "服务器返回未撤销（设备可能早已被撤销）"
        } catch {
            // 连接在响应到达前断开时，离线文案会误导用户：请求可能已经生效
            // （host 撤销成功会主动关闭设备连接），此时再「恢复网络后重试」只会
            // 得到 revoked=false。如实报告「未确认」，保留本机凭证。
            if Self.isUnconfirmedRevokeError(error) {
                return Self.deviceRevokeUnconfirmedMessage
            }
            return "撤销失败：\(ConnectionErrorText.describe(error))"
        }
    }

    /// 请求已发出、但连接在服务器回执前中断；这类失败无法从本机判断撤销结果。
    static func isUnconfirmedRevokeError(_ error: Error) -> Bool {
        if let error = error as? RACPClientError {
            switch error {
            case .notConnected, .timedOut:
                return true
            case .protocolMismatch, .server, .malformedFrame:
                return false
            }
        }
        if let error = error as? RACPWebSocketError {
            return error == .closed
        }
        if let error = error as? SSHTransportError {
            switch error {
            case .channelClosed, .closedByPeer:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// 无本地原因的离线 = 链路抖动/重连窗口，而不是「未配对/缺凭证」这类稳定离线。
    /// 连接中（connecting/authenticating/handshaking）同样属于链路侧状态。
    var isTransientDisconnect: Bool {
        switch state {
        case .offline(let reason):
            return reason == nil
        default:
            return true
        }
    }

    // MARK: - 离线缓存读取（AC-15.1）

    /// 该会话在缓存里的条目（新→旧）。离线时用它显示历史，并标注「可能不是最新」。
    func cachedEntries(sessionId: String) -> [SessionCacheStore.Entry] {
        cachedSession(sessionId: sessionId)?.entries ?? []
    }

    /// 会话的完整只读缓存：items、cursor、审批卡与草稿。
    func cachedSession(sessionId: String) -> OfflineCachedSession? {
        cacheStore.cachedSession(hostID: cacheHostID, sessionID: sessionId)
    }

    /// 缓存里出现过的会话 id（新→旧），离线时可以据此进入只读历史。
    func cachedSessionIds() -> [String] {
        cacheStore.sessionIDs(hostID: cacheHostID)
    }

    /// Drop cached sessions the authoritative catalog no longer lists for the
    /// active host. Only call with a freshly fetched, complete list — a partial
    /// or filtered list would purge sessions that still exist.
    func reconcileOfflineCache(with remoteSessions: [RACPSessionSummary]) {
        guard let hostID = cacheHostID else { return }
        cacheStore.reconcile(hostID: hostID, authoritative: Set(remoteSessions.map(\.id)))
    }

    func removeCachedSessions(_ sessionIDs: [String], hostID explicitHostID: UUID? = nil) {
        guard !sessionIDs.isEmpty else { return }
        guard let hostID = explicitHostID ?? cacheHostID else {
            PILog.warn(
                "Session",
                "cache removal skipped sessionIDs=\(sessionIDs.map { String($0.prefix(8)) }.joined(separator: ",")) reason=noCacheHost"
            )
            return
        }
        cacheStore.removeSessions(hostID: hostID, sessionIDs: Set(sessionIDs))
        extensions.removeSessions(Set(sessionIDs), hostID: hostID)
    }

    func removeCachedHost(_ hostID: UUID) {
        cacheStore.removeHost(hostID)
        extensions.removeHost(hostID)
    }

    /// 把权威会话快照写进离线缓存：items、cursor、pending approvals 一起替换；
    /// 草稿由输入框的 change sink 独立维护。异步读取前后都校验租约，旧连接结果不能落盘。
    func cacheSessionState() async {
        guard let client,
              let hostID = cacheHostID,
              let sessionID = session.attachedSessionId
        else { return }
        let generation = connectionGeneration
        let clientID = cacheClientID
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: generation,
            hostID: hostID,
            sessionID: sessionID
        )
        guard let permit = cacheStore.permit(for: lease, draft: false) else { return }
        let view = await client.sessionView()
        guard !Task.isCancelled,
              self.client === client,
              connectionGeneration == generation,
              cacheClientID == clientID,
              isCurrentCacheWrite(lease),
              view.sessionId == sessionID
        else {
            cacheStore.abandon(permit)
            return
        }

        let input = SessionCacheStore.SessionInput(
            view: view, summary: session.attachedSummary,
            mode: session.sessionMode.rawValue, permission: session.permissionMode.rawValue,
            modelID: session.selectedModelId, providerID: session.selectedProviderId,
            hostID: hostID, sessionID: sessionID
        )
        _ = await cacheStore.saveSession(input, permit: permit)
    }

    /// Coalesce streaming/history and keystroke cache writes so disk I/O is not
    /// performed on every event or character.
    func scheduleCacheSessionState() {
        sessionCacheWritePending = true
        guard sessionCacheWriteTask == nil else { return }
        sessionCacheWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.sessionCacheWritePending = false
            await self.cacheSessionState()
            guard !Task.isCancelled else { return }
            self.sessionCacheWriteTask = nil
            if self.sessionCacheWritePending {
                self.scheduleCacheSessionState()
            }
        }
    }

    func scheduleDraftCache(
        sessionID: String,
        text: String,
        idempotencyKey: String?
    ) {
        guard let lease = currentCacheWriteLease(sessionID: sessionID),
              isCurrentDraftWrite(lease)
        else { return }
        if let previous = pendingDraftWrite, previous.lease != lease {
            draftWriteTask?.cancel()
            draftWriteTask = nil
            flushPendingDraftWrite()
        }
        pendingDraftWrite = PendingDraftWrite(
            lease: lease,
            sessionID: sessionID,
            text: text,
            idempotencyKey: idempotencyKey
        )
        draftWriteTask?.cancel()
        let delay = draftWriteDebounce.delay()
        draftWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.flushPendingDraftWrite()
            self.draftWriteTask = nil
        }
    }

    func flushPendingDraftWrite() {
        draftWriteDebounce.reset()
        guard let pending = pendingDraftWrite else { return }
        pendingDraftWrite = nil
        guard isCurrentDraftWrite(pending.lease) else { return }
        guard let permit = cacheStore.permit(for: pending.lease, draft: true) else { return }
        cacheStore.saveDraft(sessionID: pending.sessionID, hostID: pending.lease.hostID,
                             text: pending.text, idempotencyKey: pending.idempotencyKey, permit: permit)
    }

    /// Result of one cache flush barrier, kept together with the revision so a
    /// stale failure cannot be applied after a newer publish.
    struct CacheFlushReport: Sendable {
        let outcome: SessionCacheWorker.Outcome
        let statusRevision: UInt64
    }

    var hasPendingCacheMutations: Bool {
        pendingDraftWrite != nil || draftWriteTask != nil
            || sessionCacheWritePending || sessionCacheWriteTask != nil
            || cacheFlushTask != nil || cacheStore.hasPendingMutations
    }

    /// Flush both coalesced caches before backgrounding, disconnecting, or switching sessions.
    func flushPendingCacheWrites() async {
#if DEBUG
        beforeCacheFlushHookForTesting?()
#endif
        cacheFlushGeneration &+= 1
        let generation = cacheFlushGeneration
        let previous = cacheFlushTask
        let task: Task<CacheFlushReport?, Never> = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return nil }
            return await self.performCacheFlush()
        }
        cacheFlushTask = task
        let report = await task.value
        let isCurrent = cacheFlushGeneration == generation
        if isCurrent {
            cacheFlushTask = nil
        }
        // A cancelled/expired background lease may still finish its already
        // queued IO, but it must not publish the older result over newer state.
        guard isCurrent, !Task.isCancelled, let report else { return }
#if DEBUG
        if let afterCacheFlushBarrierHookForTesting {
            await afterCacheFlushBarrierHookForTesting()
        }
#endif
        guard cacheFlushGeneration == generation, !Task.isCancelled else { return }
        applyCacheFlushReport(report)
    }

    func performCacheFlush() async -> CacheFlushReport {
        draftWriteTask?.cancel()
        draftWriteTask = nil
        flushPendingDraftWrite()

        let hadPendingSessionWrite = sessionCacheWriteTask != nil || sessionCacheWritePending
        sessionCacheWriteTask?.cancel()
        sessionCacheWriteTask = nil
        sessionCacheWritePending = false
        if hadPendingSessionWrite {
            await cacheSessionState()
        }
        let flushed = await cacheStore.flushResult()
        return CacheFlushReport(outcome: flushed.outcome, statusRevision: flushed.statusRevision)
    }

    func applyCacheFlushReport(_ report: CacheFlushReport) {
        applyCacheStatus(cacheStore.status)
        // Only fall back to the barrier failure when no newer publish (a real
        // recovery or a newer failure) has already superseded its revision.
        guard case .failed(let error) = report.outcome,
              cacheStatusRevision <= report.statusRevision,
              offlineCacheLoadError == nil
        else { return }
        offlineCacheLoadError = error.localizedDescription
    }

    func waitForOfflineCacheReady() async {
        await cacheStore.waitUntilReady()
        guard !Task.isCancelled else { return }
        applyCacheStatus(cacheStore.status)
    }

    func applyCacheStatus(_ status: SessionCacheWorker.Status) {
        guard status.revision > cacheStatusRevision else { return }
        cacheStatusRevision = max(cacheStatusRevision, status.revision)
        if offlineCacheReady != status.ready { offlineCacheReady = status.ready }
        if offlineCacheLoadError != status.error { offlineCacheLoadError = status.error }
    }

#if DEBUG
    func applyCacheStatusForTesting(_ status: SessionCacheWorker.Status) {
        applyCacheStatus(status)
    }

    func cacheLeaseForTesting(sessionID: String) -> OfflineSessionCacheWriteLease? {
        currentCacheWriteLease(sessionID: sessionID)
    }
#endif

    func updateCacheContext() {
        cacheStore.updateContext(clientID: cacheClientID, generation: connectionGeneration,
                                 hostID: cacheHostID, sessionID: session.attachedSessionId, active: client != nil)
        syncExtensionContext()
    }

    func currentCacheWriteLease(
        sessionID: String
    ) -> OfflineSessionCacheWriteLease? {
        guard client != nil, let hostID = cacheHostID else { return nil }
        return OfflineSessionCacheWriteLease(
            clientID: cacheClientID,
            connectionGeneration: connectionGeneration,
            hostID: hostID,
            sessionID: sessionID
        )
    }

    func isCurrentCacheWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrent(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID,
                sessionID: session.attachedSessionId
            )
    }

    func isCurrentDraftWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrentHost(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID
            )
    }


}
