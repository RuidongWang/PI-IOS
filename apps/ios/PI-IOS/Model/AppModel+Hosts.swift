import Foundation
import Combine
import SwiftUI
import UIKit
import PIiOSCore
import PIiOSNet


extension AppModel {
    // MARK: - 导航

    func openSidebar() { isSidebarOpen = true }

    func closeSidebar() { isSidebarOpen = false }

    func switchRoot(_ target: Root) {
        root = target
        isSidebarOpen = false
    }

    /// 抽屉里点「设置」并希望落在服务器列表时使用：切根并保持抽屉关闭。
    func showSettings() { switchRoot(.settings) }

    /// 跨页面深链：切到设置根，并请求设置页把自己压栈到指定子页。
    ///
    /// 为什么放在这里：恢复路径（比如「模型不可用 → 去模型服务」）不该让每个页面
    /// 自己拼路由，也不该只把用户丢到设置根页再让他找一次。
    /// `SettingsScreen` 消费后立即清空，保持「一次性意图」的语义。
    func showSettings(_ route: SettingsRoute) {
        pendingSettingsRoute = route
        switchRoot(.settings)
    }

    func consumePendingSettingsRoute() -> SettingsRoute? {
        defer { pendingSettingsRoute = nil }
        return pendingSettingsRoute
    }

    // MARK: - 主机记录

    @discardableResult
    func addHost(_ draft: HostDraft) -> HostRecord? {
        let errors = HostValidator.validate(draft)
        guard errors.isValid else { return nil }
        let host = draft.host.piTrimmed
        let record = HostRecord(
            id: UUID(),
            name: draft.name.piTrimmed.isEmpty ? host : draft.name.piTrimmed,
            host: host,
            port: Int(draft.port.piTrimmed) ?? 22,
            username: draft.username.piTrimmed,
            authKind: draft.authKind,
            createdAt: Date(),
            isCurrent: hosts.isEmpty,
            pairedAt: nil,
            tunnelUpAt: nil,
            hostPort: Int(draft.hostPort.piTrimmed),
            keyFileName: draft.keyFileName,
            connectionPreference: .sshOnly,
            directEndpoint: HostValidator.canonicalDirectEndpoint(draft.directEndpoint),
            adaptorHostId: nil
        )
        var next = snapshot
        next.hosts.append(record)
        guard persist(next) else { return nil }
        hosts = next.hosts
        return record
    }

    @discardableResult
    func updateHost(id: UUID, with draft: HostDraft) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
        let errors = HostValidator.validate(draft, requiresSecret: false)
        guard errors.isValid else { return false }
        let previous = hosts[index]
        let wasCurrent = currentHost?.id == id
        var edited = previous
        edited.host = draft.host.piTrimmed
        edited.name = draft.name.piTrimmed.isEmpty ? edited.host : draft.name.piTrimmed
        edited.port = Int(draft.port.piTrimmed) ?? previous.port
        edited.username = draft.username.piTrimmed
        edited.authKind = draft.authKind
        edited.hostPort = Int(draft.hostPort.piTrimmed)
        edited.keyFileName = draft.keyFileName
        edited.directEndpoint = HostValidator.canonicalDirectEndpoint(draft.directEndpoint)
        let sshAddressChanged = previous.host != edited.host || previous.port != edited.port
            || previous.username != edited.username
        let pairingChanged = sshAddressChanged || previous.hostPort != edited.hostPort
        let authChanged = previous.authKind != edited.authKind
        let endpointChanged = previous.directEndpoint != edited.directEndpoint
        if pairingChanged || endpointChanged || draft.connectionPreference != .directPreferred
            || edited.adaptorHostId == nil
            || KeychainStore.loadDirectTLSTrustPin(hostID: id)?.hostId != edited.adaptorHostId {
            edited.connectionPreference = .sshOnly
        }
        if pairingChanged {
            edited.pairedAt = nil
            edited.tunnelUpAt = nil
            edited.installReceipt = nil
            edited.adaptorHostId = nil
        }

        var next = snapshot
        next.hosts[index] = edited
        if pairingChanged { next.removeHostDerivedData(id, wasCurrent: wasCurrent) }
        guard persist(next) else { return false }
        if pairingChanged || authChanged || endpointChanged { bumpInstallIdentityGeneration(id) }
        if (pairingChanged || authChanged), wasCurrent || pendingHostID == id {
            providerIdentityGeneration &+= 1
            if wasCurrent { foregroundResumeTracker.capture(nil) }
        }
        if pairingChanged {
            let oldAccount = KeychainStore.account(username: previous.username, host: previous.host, port: previous.port)
            let clearOldAccount = sshAddressChanged && !usesSSHAccount(oldAccount, excluding: id)
            KeychainStore.deleteDeviceToken(hostID: id, legacyAccount: oldAccount, deleteLegacy: clearOldAccount)
            if clearOldAccount { KeychainStore.deleteHostKey(account: oldAccount) }
            KeychainStore.deleteDirectTLSTrustPin(hostID: id)
            applyHostDataRemoval(next, hostID: id, wasCurrent: wasCurrent)
        } else {
            hosts = next.hosts
        }
        return true
    }

    @discardableResult
    func deleteHost(id: UUID) async -> Bool {
        guard let host = hosts.first(where: { $0.id == id }) else { return false }
        let wasCurrent = currentHost?.id == id
        if wasCurrent || pendingHostID == id {
            hostSwitchGeneration &+= 1
            let generation = hostSwitchGeneration
            if wasCurrent {
                await connection.disconnect(ifHostID: id)
            }
            guard hostSwitchGeneration == generation,
                  hosts.contains(where: { $0.id == id && $0.address == host.address && $0.hostPort == host.hostPort })
            else { return false }
        }
        var next = snapshot
        next.hosts.removeAll { $0.id == id }
        if wasCurrent, !next.hosts.isEmpty { next.hosts[0].isCurrent = true }
        next.removeHostDerivedData(id, wasCurrent: wasCurrent)
        guard persist(next) else { return false }

        // 删除 host 只删本地记录与凭证（契约 §2.4），不动服务器上的任何东西。
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        let anotherHostUsesAccount = usesSSHAccount(account, excluding: id)
        if !anotherHostUsesAccount {
            KeychainStore.deleteCredential(account: account)
            KeychainStore.deleteHostKey(account: account)
        }
        KeychainStore.deleteDeviceToken(
            hostID: id,
            legacyAccount: account,
            deleteLegacy: !anotherHostUsesAccount
        )
        KeychainStore.deleteDirectTLSTrustPin(hostID: id)
        applyHostDataRemoval(next, hostID: id, wasCurrent: wasCurrent)
        if wasCurrent { connection.setCacheHostID(currentHost?.id) }
        if pendingHostID == id { pendingHostID = nil }
        await connection.flushPendingCacheWrites()
        return true
    }

    func usesSSHAccount(_ account: String, excluding id: UUID) -> Bool {
        hosts.contains { host in
            host.id != id && KeychainStore.account(username: host.username, host: host.host, port: host.port) == account
        }
    }

    func applyHostDataRemoval(_ state: PersistedState, hostID id: UUID, wasCurrent: Bool) {
        // Provider 密钥按 host UUID + providerId 存储，而 UUID 在改绑/删除后可能
        // 指向另一台服务器。这里必须按前缀清掉全部历史 provider key（含 legacy
        // 与已从本机投影移除的 ID），否则新端点复用同名 providerId 时会取到旧
        // 服务器的密钥。失败时不能静默，留给用户可操作提示。
        if !KeychainStore.deleteAllProviderKeys(hostID: id) {
            showToast("部分旧服务的 API Key 未能从 Keychain 清除，请重启应用后重试")
        }
        hosts = state.hosts
        modelProviders = state.modelProviders
        projectBindings = state.projectBindings
        sessionBindings = state.sessionBindings
        lastProjectByHost = state.lastProjectByHost
        lastSessionByHost = state.lastSessionByHost
        collapsedProjectGroups = state.collapsedProjectGroups
        projectBrowserPaths = state.projectBrowserPaths
        readingPositionsByHost = state.readingPositionsByHost
        persistReadingPositionsIfNeeded()
        lastProjectId = state.lastProjectId
        lastSessionId = state.lastSessionId
        resumedSessionUpdates.removeHost(id)
        connection.removeCachedHost(id)
        if wasCurrent {
            foregroundResumeTracker.capture(nil)
            connection.session.detach()
        }
    }

    /// 修改连接身份前先原子关闭旧 client，避免界面显示新地址但操作仍打到旧服务器。
    func prepareHostIdentityChange(id: UUID) async -> Int? {
        guard currentHost?.id == id else { return nil }
        hostSwitchGeneration &+= 1
        let generation = hostSwitchGeneration
        pendingHostID = id
        await connection.disconnect(ifHostID: id)
        guard hostSwitchGeneration == generation else { return nil }
        return generation
    }

    func finishHostIdentityChange(id: UUID, generation: Int) {
        guard hostSwitchGeneration == generation, pendingHostID == id else { return }
        pendingHostID = nil
    }

    func canApplyHostIdentityChange(id: UUID, generation: Int) -> Bool {
        hostSwitchGeneration == generation && currentHost?.id == id
    }

    func beginHostOperation(hostID: UUID) -> Int {
        hostSwitchGeneration &+= 1
        pendingHostID = hostID
        return hostSwitchGeneration
    }

    func canApplyHostOperation(_ generation: Int, hostID: UUID) -> Bool {
        hostSwitchGeneration == generation
            && hosts.contains(where: { $0.id == hostID })
    }

    /// 配对成功后更新本机记录；设备令牌本身只存 Keychain。
    func markHostPaired(id: UUID, adaptorHostId: String? = nil) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].pairedAt = Date()
        if let adaptorHostId, !adaptorHostId.isEmpty {
            hosts[index].adaptorHostId = adaptorHostId
        }
        persist()
    }

    func setConnectionPreference(id: UUID, preference: ConnectionPreference) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        // 只有 markDirectVerified 可以启用 directPreferred；切回 SSH 不删除任何信任或配对。
        if preference == .directPreferred { return }
        hosts[index].connectionPreference = .sshOnly
        persist()
    }

    func markDirectVerified(id: UUID, endpoint: String, adaptorHostId: String) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              let canonical = HostValidator.canonicalDirectEndpoint(endpoint),
              hosts[index].directEndpoint == canonical,
              hosts[index].adaptorHostId == adaptorHostId,
              KeychainStore.loadDirectTLSTrustPin(hostID: id)?.hostId == adaptorHostId,
              KeychainStore.loadDeviceToken(hostID: id)?.hasPrefix("pdt2.") == true
        else { return false }
        hosts[index].connectionPreference = .directPreferred
        return persist()
    }

    @discardableResult
    func completeAdaptorInstallation(
        _ commit: BootstrapPairingCommit,
        promoteStaged: (() -> Bool)? = nil
    ) -> BootstrapPairingCommitResult {
        guard let index = hosts.firstIndex(where: { $0.id == commit.hostID }) else {
            saveError = "安装完成时本机服务器记录已不存在，未把旧安装结果写回当前记录"
            return .staleTarget
        }
        let current = InstallTargetSnapshot(
            record: hosts[index],
            identityGeneration: installIdentityGeneration(forHostID: commit.hostID)
        )
        guard BootstrapInstallCommitPolicy.canCommit(
            expected: commit.target,
            current: current,
            existingAdaptorHostId: hosts[index].adaptorHostId,
            committedAdaptorHostId: commit.adaptorHostId
        ) else {
            saveError = "安装完成时服务器身份已变化，未把旧安装结果写回当前记录"
            return .staleTarget
        }
        let promoted = promoteStaged?() ?? KeychainStore.promoteStagedPairing(
            hostID: commit.hostID,
            attemptId: commit.attemptId,
            pendingInstall: commit,
            previousAdaptorHostId: hosts[index].adaptorHostId
        )
        guard promoted else { return .tokenPromotionFailed }
        return writeInstallReceipt(commit, at: index)
    }

    func recoverPromotedInstallReceipts() {
        for index in hosts.indices {
            _ = recoverPromotedInstallReceipt(at: index, afterReload: true)
        }
    }

    func prepareHostConnection(id: UUID) -> HostRecord? {
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              recoverPromotedInstallReceipt(at: index) else { return nil }
        return hosts[index]
    }

    func recoverPromotedInstallReceipt(at index: Int, afterReload: Bool = false) -> Bool {
        let host = hosts[index]
        guard let commit = KeychainStore.pendingInstall(hostID: host.id) else { return true }
        if host.installReceipt?.attemptId == commit.attemptId {
            KeychainStore.clearPendingInstall(hostID: host.id, attemptId: commit.attemptId)
            return true
        }
        let generation = afterReload ? commit.target.identityGeneration : installIdentityGeneration(forHostID: host.id)
        let current = InstallTargetSnapshot(record: host, identityGeneration: generation)
        guard BootstrapInstallCommitPolicy.canCommit(
            expected: commit.target,
            current: current,
            existingAdaptorHostId: host.adaptorHostId,
            committedAdaptorHostId: commit.adaptorHostId
        ), host.hostPort == commit.target.hostPort || host.hostPort == commit.port else { return false }
        if afterReload {
            installIdentityGenerations[host.id] = generation
        }
        return writeInstallReceipt(commit, at: index) == .committed
    }

    func writeInstallReceipt(
        _ commit: BootstrapPairingCommit,
        at index: Int
    ) -> BootstrapPairingCommitResult {
        let previousRecord = hosts[index]
        hosts[index].hostPort = commit.port
        hosts[index].pairedAt = Date()
        hosts[index].adaptorHostId = commit.adaptorHostId
        hosts[index].directEndpoint = commit.directEndpoint
        // Direct 首验通过后，markDirectVerified 再提升连接偏好。
        hosts[index].connectionPreference = .sshOnly
        hosts[index].installReceipt = AdaptorInstallReceipt(
            version: commit.version,
            hostPort: commit.port,
            attemptId: commit.attemptId,
            completedAt: Date(),
            releaseSource: commit.releaseSource
        )
        if persist() {
            KeychainStore.clearPendingInstall(hostID: commit.hostID, attemptId: commit.attemptId)
            return .committed
        }
        hosts[index] = previousRecord
        switch BootstrapInstallCompletionPolicy.disposition(
            persisted: false,
            saveError: saveError
        ) {
        case .succeeded:
            return .committed
        case .failed(let reason):
            return .receiptPersistenceFailed(reason)
        }
    }

    /// Read-only identity generation for a frozen install target. Kept in memory
    /// only: an app restart also terminates the in-flight install attempt.
    func installIdentityGeneration(forHostID id: UUID) -> Int {
        installIdentityGenerations[id] ?? 0
    }

    func installTargetSnapshot(for host: HostRecord) -> InstallTargetSnapshot {
        InstallTargetSnapshot(
            record: host,
            identityGeneration: installIdentityGeneration(forHostID: host.id)
        )
    }

    func bumpInstallIdentityGeneration(_ id: UUID) {
        installIdentityGenerations[id, default: 0] &+= 1
    }

    /// Write a port discovered over SSH back onto the host record (requirement:
    /// the user must not configure a host port). The device token stays valid
    /// because this is the same PI-adaptor the client just resolved.
    func applyDiscoveredHostPort(hostID: UUID, port: Int) {
        guard (1...65_535).contains(port),
              let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].hostPort != port
        else { return }
        hosts[index].hostPort = port
        scheduleAutomaticPersist()
    }

    func providerOperationContext(for host: HostRecord) -> ProviderOperationContext? {
        guard let current = currentHost, current.id == host.id,
              current.host == host.host, current.port == host.port,
              current.username == host.username, current.hostPort == host.hostPort,
              current.authKind == host.authKind,
              pendingHostID == nil
        else { return nil }
        return ProviderOperationContext(
            hostID: host.id, address: host.host, sshPort: host.port, username: host.username,
            hostPort: host.hostPort, authKind: host.authKind.rawValue,
            hostGeneration: hostSwitchGeneration, identityGeneration: providerIdentityGeneration,
            connectionGeneration: providerConnectionGeneration
        )
    }

    /// The locally stored provider for a PI-adaptor-side provider id, if any. Used to
    /// carry forward the legacy mapping when the v2 record is edited in place.
    func storedProvider(hostID: UUID, providerId: String) -> StoredModelProvider? {
        modelProviders.first { $0.hostID == hostID && $0.providerId == providerId }
    }

    func providerCredentialForTurn(providerId: String, hostID: UUID) -> KeychainStore.ProviderKeyRecord? {
        let stored = storedProvider(hostID: hostID, providerId: providerId)
        var key = KeychainStore.loadProviderKeyRecord(hostID: hostID, providerId: providerId)
        if key?.baseURL == nil, let endpoint = stored?.baseURL, !endpoint.isEmpty {
            key?.baseURL = endpoint
        }
        return key
    }

    func installProviderAPIKeyResolver() {
        connection.session.providerCredential = { [weak self] providerId in
            guard let self, let hostID = self.currentHost?.id else { return nil }
            return self.providerCredentialForTurn(providerId: providerId, hostID: hostID)
        }
    }

    func canApplyProviderOperation(_ context: ProviderOperationContext) -> Bool {
        context.canApply(to: currentHost.flatMap { providerOperationContext(for: $0) })
    }

    @discardableResult
    func recordImportedProvider(
        context: ProviderOperationContext,
        input: ProviderCreateInput,
        providerId: String,
        serverDefaultSet: Bool
    ) -> Bool {
        guard canApplyProviderOperation(context) else { return false }
        let hostID = context.hostID
        let previousRecord = modelProviders.first {
            $0.hostID == hostID && $0.providerId == providerId
        }
        let previousDefault = previousRecord?.defaultModelId
        let isOnlyProviderOnHost = !modelProviders.contains {
            $0.hostID == hostID && $0.providerId != providerId
        }
        let defaultModelId = ProviderDefaultModelRecorder.resolvedDefaultModelID(
            explicit: input.defaultModelId,
            previous: previousDefault,
            models: input.models,
            serverDefaultSet: serverDefaultSet,
            isOnlyProviderOnHost: isOnlyProviderOnHost
        )
        modelProviders.removeAll { $0.hostID == hostID && $0.providerId == providerId }
        modelProviders.append(
            StoredModelProvider(
                providerId: providerId,
                hostID: hostID,
                name: input.name,
                baseURL: input.baseUrl ?? "",
                apiStyle: input.apiStyle ?? "chat_completions",
                models: input.models.map(StoredModelBinding.init(spec:)),
                defaultModelId: defaultModelId,
                importedAt: Date()
            )
        )
        if defaultModelId != nil {
            // 只在新的默认项落到这台 Host 上时清掉其他 provider 的旧默认，
            // 让设置页与模型面板始终只有一个「默认模型」。
            for index in modelProviders.indices
            where modelProviders[index].hostID == hostID
                && modelProviders[index].providerId != providerId {
                modelProviders[index].defaultModelId = nil
            }
        }
        persist()
        return true
    }

    @discardableResult
    func removeLocalProvider(id: String, context: ProviderOperationContext) -> Bool {
        guard canApplyProviderOperation(context) else { return false }
        modelProviders.removeAll { $0.id == id && $0.hostID == context.hostID }
        persist()
        return true
    }

    func observeTunnelState() {
        tunnelObservation = connection.$state.sink { [weak self] state in
            PILog.debug("Connection", "隧道状态=\(state.displayText)")
            self?.providerConnectionGeneration &+= 1
            guard state.isOnline else { return }
            Task { @MainActor in
                guard let self, let index = self.hosts.firstIndex(where: { $0.isCurrent }) else { return }
                self.hosts[index].tunnelUpAt = Date()
                self.scheduleAutomaticPersist()
            }
        }
    }

    /// 连接错误按分类写日志：用于实机排查断线/重连失败，不记录任何凭证。
    func observeConnectionErrors() {
        connectionErrorObservation = connection.$lastError
            .removeDuplicates()
            .sink { error in
                guard let error else { return }
                PILog.warn("Connection", "最近错误：\(ConnectionDiagnosticRedactor.redact(error))")
            }
    }

    func observeRemoteMetadata() {
        remoteObservation = Publishers.CombineLatest(
            connection.$projects,
            connection.$sessions
        )
        .sink { [weak self] projects, sessions in
            guard let self else { return }
            let sourceHostID = self.connection.currentCatalogHostID
            Task { @MainActor in
                guard let sourceHostID,
                      self.currentHost?.id == sourceHostID,
                      self.connection.currentCatalogHostID == sourceHostID
                else { return }
                self.mergeRemoteMetadata(
                    hostID: sourceHostID,
                    projects: projects,
                    sessions: sessions
                )
            }
        }
    }

    func mergeRemoteMetadata(
        hostID: UUID,
        projects: [RACPProjectSummary],
        sessions: [RACPSessionSummary]
    ) {
        let now = Date()
        var changed = false

        for project in projects {
            if let index = projectBindings.firstIndex(where: {
                $0.hostID == hostID && $0.projectID == project.id
            }) {
                if projectBindings[index].isDeleted { continue }
                if projectBindings[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    projectBindings[index].name = project.label ?? project.id
                    projectBindings[index].updatedAt = now
                    changed = true
                }
            } else {
                projectBindings.append(
                    StoredProjectBinding(
                        hostID: hostID,
                        projectID: project.id,
                        path: nil,
                        name: project.label ?? project.id,
                        source: .upstream,
                        isArchived: true,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                changed = true
            }
        }

        for session in sessions {
            if let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == session.id
            }) {
                if sessionBindings[index].isDeleted { continue }
                if sessionBindings[index].projectID != session.projectId {
                    sessionBindings[index].projectID = session.projectId
                    changed = true
                }
                if sessionBindings[index].lastKnownRevision != session.revision {
                    if sessionBindings[index].lastKnownRevision != nil,
                       connection.session.attachedSessionId != session.id {
                        sessionBindings[index].isUnread = true
                    }
                    sessionBindings[index].lastKnownRevision = session.revision
                    sessionBindings[index].lastActivityAt = now
                    sessionBindings[index].updatedAt = now
                    changed = true
                }
                if connection.session.attachedSessionId == session.id,
                   sessionBindings[index].isUnread {
                    sessionBindings[index].isUnread = false
                    changed = true
                }
            } else {
                sessionBindings.append(
                    StoredSessionBinding(
                        hostID: hostID,
                        sessionID: session.id,
                        projectID: session.projectId,
                        source: .upstream,
                        isArchived: true,
                        lastActivityAt: now,
                        lastKnownRevision: session.revision,
                        updatedAt: now
                    )
                )
                changed = true
            }
        }
        if changed { scheduleAutomaticPersist() }
    }

    func connectCurrentHostIfPaired() async {
        guard let host = currentHost else { return }
        await connection.recoverStagedPairings(record: host)
        guard host.pairedAt != nil || KeychainStore.pendingInstall(hostID: host.id) != nil else { return }
        await setCurrentHost(id: host.id)
    }

    /// 切换当前服务器（AC-18.2）：关掉旧隧道、按新 host 的凭证重连，并恢复它上次的会话。
    func setCurrentHost(id: UUID, waitForOnline: Bool = true) async {
        guard hosts.contains(where: { $0.id == id }) else { return }
        let previousHostID = currentHost?.id
        hostSwitchGeneration &+= 1
        let generation = hostSwitchGeneration
        pendingHostID = id
        PILog.info("Connection", "切换服务器 host=\(id.uuidString.prefix(8))")
        // 先清空旧连接的目录与隧道，避免旧 PI-adaptor 的列表在新 PI-adaptor 标记生效后到达本机元数据合并。
        if let previousHostID {
            await connection.disconnect(ifHostID: previousHostID)
        }
        guard hostSwitchGeneration == generation,
              hosts.contains(where: { $0.id == id })
        else { return }
        for index in hosts.indices {
            hosts[index].isCurrent = (hosts[index].id == id)
        }
        connection.setCacheHostID(id)
        persist()
        guard let host = currentHost else { return }
        await connection.connect(record: host)
        if hostSwitchGeneration == generation {
            pendingHostID = nil
        }
        guard hostSwitchGeneration == generation else {
            return
        }
        if waitForOnline {
            if await connection.waitUntilOnline(),
               let lastSession = lastSessionByHost[host.id.uuidString],
               hostSwitchGeneration == generation {
                await connection.session.attach(sessionId: lastSession, source: "connectionRestore")
            }
        }
        if hostSwitchGeneration == generation {
            pendingHostID = nil
            PILog.info("Connection", "切换服务器完成 online=\(connection.state.isOnline)")
        }
    }

    /// 撤销本机配对（AC-03.1）：先要求服务器 v2 `connection/revoke` 成功，再清本机凭证。
    ///
    /// 服务器没确认时**保留**本机凭证并如实返回结果——只删本地会让用户以为设备已被切断访问。
    @discardableResult
    func revokePairing(hostID: UUID) async -> String {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            return "这台服务器的本机记录已不存在"
        }
        let host = hosts[index]
        let revokedDeviceId = KeychainStore.loadDeviceId(hostID: hostID)
        let outcome = await connection.revokeThisDevice(host: host)
        guard outcome == ConnectionModel.deviceRevokedMessage else {
            showToast(outcome)
            return outcome
        }
        guard let index = hosts.firstIndex(where: {
            $0.id == hostID
                && $0.username == host.username
                && $0.host == host.host
                && $0.port == host.port
                && $0.hostPort == host.hostPort
        }),
        KeychainStore.loadDeviceId(hostID: hostID) == revokedDeviceId
        else {
            let stale = "PI-adaptor 配置已变化：撤销回执未改动新的本机记录"
            showToast(stale)
            return stale
        }
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        let anotherHostUsesAccount = hosts.contains { other in
            other.id != hostID
                && KeychainStore.account(
                    username: other.username,
                    host: other.host,
                    port: other.port
                ) == account
        }
        // 主机指纹属于服务器身份，撤销配对不删它（否则会静默失去 TOFU 保护）。
        // SSH 凭证按服务器端点共享；撤销某台 PI-adaptor 的配对不能删除其他 hostPort
        // 的 PI-adaptor 仍在使用的私钥或密码。
        KeychainStore.deleteDeviceToken(
            hostID: hostID,
            legacyAccount: account,
            deleteLegacy: !anotherHostUsesAccount
        )
        if !anotherHostUsesAccount {
            KeychainStore.deleteCredential(account: account)
        }
        hosts[index].pairedAt = nil
        hosts[index].tunnelUpAt = nil
        persist()
        await connection.disconnect(ifHostID: hostID)
        showToast(outcome)
        return outcome
    }

    // MARK: - 本机偏好

    func setOfflineCacheLimit(_ limit: Int) {
        let clamped = PersistedState.clampOfflineCacheLimit(limit)
        guard clamped != offlineCacheLimit else { return }
        offlineCacheLimit = clamped
        connection.updateOfflineCacheLimit(clamped)
        logStore.log(level: .info, category: "Settings", message: "离线缓存上限=\(clamped)")
        persist()
    }

    // MARK: - 日志（设置 → 日志）

    /// 打开/关闭持久日志。关闭时先记录一条再落配置，保证「关闭」这件事本身可追溯。
    func setLoggingEnabled(_ enabled: Bool) {
        guard logConfiguration.isEnabled != enabled else { return }
        if enabled {
            logConfiguration.isEnabled = true
            applyLogConfiguration()
            logStore.log(level: logConfiguration.level, category: "Settings", message: "日志已开启")
        } else {
            // 用当前生效等级记录：level=warn 时 info 会被过滤，关闭动作就不可追溯了。
            logStore.log(level: logConfiguration.level, category: "Settings", message: "日志已关闭")
            logConfiguration.isEnabled = false
            applyLogConfiguration()
            logStore.flush()
        }
        persist()
    }

    func setLogLevel(_ level: PILogLevel) {
        guard logConfiguration.level != level else { return }
        logConfiguration.level = level
        applyLogConfiguration()
        logStore.log(level: level, category: "Settings", message: "日志等级=\(level.label)")
        persist()
    }

    func setLogTimeFormat(_ format: PILogTimeFormat) {
        guard logConfiguration.timeFormat != format else { return }
        logConfiguration.timeFormat = format
        applyLogConfiguration()
        logStore.log(level: .info, category: "Settings", message: "日志时间格式=\(format.rawValue)")
        persist()
    }

    /// 设置页日志记录（只读内存，不读盘）；默认全部，显式 limit 可用于局部投影。
    func currentLogRecords(limit: Int? = nil) -> [PILogRecord] {
        logStore.recentRecords(limit: limit)
    }

    /// 导出 txt 全文；读取轮转文件可能到 MB 级，固定放后台线程生成。
    func exportLogText() async -> String {
        let metadata = logExportMetadata
        let store = logStore
        return await Task.detached(priority: .utility) {
            store.exportText(metadata: metadata)
        }.value
    }

    /// 清空日志：`PILogger.clear()` 是同步磁盘 API（内部用信号量等后台队列），
    /// 按「日志 IO 不在主线程」的约定放到后台任务执行；调用方 await 后再重置页面快照。
    func clearLogs() async {
        let store = logStore
        await Task.detached(priority: .utility) {
            store.clear()
        }.value
    }

    /// 前后台切换时启停卡顿监测：后台不记录（避免误报切回时的长间隔）。
    func updateLogSceneActive(_ active: Bool) {
        MainThreadStallMonitor.shared.setSceneActive(active)
    }

    /// 退后台/退出前把待写批次落盘。由 `BackgroundFlushLease` 持有后台任务断言，
    /// 避免系统立即挂起时丢掉最后 ~0.5s 的待写日志。
    func flushLogsForBackground() async {
        let store = logStore
        await Task.detached(priority: .utility) {
            store.flushSync()
        }.value
    }

    /// 重启后日志页首屏快照：默认从磁盘读取全部记录，避免「导出有内容、页面却显示暂无日志」。
    func loadStoredLogRecords(limit: Int? = nil) async -> [PILogRecord] {
        let store = logStore
        return await Task.detached(priority: .utility) {
            store.storedRecords(limit: limit)
        }.value
    }

    func applyLogConfiguration() {
        logStore.configure(logConfiguration)
        MainThreadStallMonitor.shared.setEnabled(logConfiguration.isEnabled && !usesUITestFixture)
    }

    var logExportMetadata: PILogExportMetadata {
        PILogExportMetadata(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            configuration: logConfiguration,
            buildIdentity: PIBuildIdentity.current
        )
    }

    static var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version)(\(build))"
    }

    /// 缓存裁剪时必须传的上限（AC-15.1）：`CacheRetention.pruneItems(items, limit: cacheRetentionLimit)`。
    /// 传设置里的值而不是用无参默认值，否则设置里选 1000 也会按 200 淘汰。
    var cacheRetentionLimit: Int { PersistedState.clampOfflineCacheLimit(offlineCacheLimit) }

    // MARK: - 提示

    func showToast(_ text: String) {
        toast = PIToast(text: text)
    }

    func dismissToast() {
        toast = nil
    }

    func dismissLoadWarning() {
        loadWarning = nil
    }

    func dismissSaveError() {
        saveError = nil
    }

}
