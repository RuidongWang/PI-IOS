import Foundation
import UIKit
import Combine
import PIiOSCore
import PIiOSNet


extension ConnectionModel {
    // MARK: - 模型服务

    /// Ad-hoc discovery uses only the active host-bound RACP client. The temporary
    /// API key is confined to that request payload and never enters SSH argv/logs.
    func discoverModels(
        record: HostRecord,
        baseURL: String,
        apiKey: String,
        protocol wireProtocol: String? = nil
    ) async throws -> [DiscoveredModel] {
        guard cacheHostID == record.id, state.isOnline, let client else {
            throw RACPV2Error.notConnected
        }
        guard info?.capabilities?.value(at: ["providerDiscovery"])?.boolValue == true else {
            throw RACPV2Error.server(
                code: RACPErrorCode.capabilityUnavailable.rawValue,
                message: "PI-adaptor 未声明 providerDiscovery 能力"
            )
        }
        PILog.debug(
            "Model",
            "provider/discover protocol=\(wireProtocol ?? "-") apiKey=present"
        )
        return try await RemoteProviderOperations.discoverModels(
            client: client,
            requestURL: baseURL,
            apiKey: apiKey,
            protocol: wireProtocol,
            timeout: RemoteProviderOperations.userVisibleTimeout
        )
    }

    func importProvider(
        record: HostRecord,
        payload: Data
    ) async throws -> ProviderImportReceipt {
        guard cacheHostID == record.id,
              state.isOnline,
              let client
        else { throw RACPV2Error.notConnected }
        let payload = try ProviderImportEncoder.decode(payload)
        // 排查「配置的 provider 传给服务器了，key 有没有一起上传」：只记有无，
        // 不记明文、不记完整载荷。api_key 服务缺 key 时服务器会拒绝，这里先留痕。
        let requiresKeyCount = payload.providers.filter { $0.input.authKind != "none" }.count
        let keyedCount = payload.providers.filter {
            $0.input.authKind != "none" && !(($0.input.secretValue ?? "").isEmpty)
        }.count
        let keyState: String
        if requiresKeyCount == 0 {
            keyState = "not-required"
        } else {
            keyState = keyedCount == requiresKeyCount ? "present" : "missing/partial"
        }
        PILog.info(
            "Model",
            "provider/create providers=\(payload.providers.count) key=\(keyState)"
                + " default=\(payload.defaultModel?.modelId ?? "-")"
        )
        return try await RemoteProviderOperations.importProviders(
            client: client,
            payload: payload,
            timeout: RemoteProviderOperations.userVisibleTimeout
        )
    }

    func removeProvider(
        record: HostRecord,
        providerId: String
    ) async throws -> ProviderRemoveReceipt {
        guard cacheHostID == record.id,
              state.isOnline,
              let client
        else { throw RACPV2Error.notConnected }
        return try await RemoteProviderOperations.removeProvider(
            client: client,
            providerId: providerId,
            timeout: RemoteProviderOperations.userVisibleTimeout
        )
    }

    func providerBindingStatus(
        record: HostRecord,
        sessionId: String
    ) async throws -> ProviderBindingReceipt {
        if let fixtureReceipt = fixtureProviderBindingStatusResult(sessionId: sessionId) {
            return fixtureReceipt
        }
        guard cacheHostID == record.id,
              state.isOnline,
              let client
        else { throw RACPV2Error.notConnected }
        return try await RemoteProviderOperations.bindingStatus(
            client: client,
            sessionId: sessionId,
            timeout: RemoteProviderOperations.userVisibleTimeout
        )
    }

    // MARK: - PI-adaptor v2 additive features

    func syncExtensionContext() {
        let identityMatches = cacheHostID != nil && extensionInfoHostID == cacheHostID
        extensions.setContext(.init(
            hostID: cacheHostID, generation: connectionGeneration,
            remoteHostID: identityMatches ? info?.hostId : nil,
            online: state.isOnline && identityMatches,
            inventorySupported: identityMatches && info?.capabilities?.value(at: ["extensionInventory"])?.boolValue == true,
            sessionSupported: identityMatches && info?.capabilities?.value(at: ["sessionExtensions"])?.boolValue == true
        ))
    }

    func refreshExtensionInventory() async {
        syncExtensionContext()
        if await fixtureRefreshExtensionInventoryIfApplicable() { return }
        guard let client else { return }
        await extensions.refreshInventory {
            try await client.request(.extensionList, params: .object([:]))
        }
    }

    func refreshSessionExtensions(_ sessionID: String) async {
        syncExtensionContext()
        if await fixtureRefreshSessionExtensionsIfApplicable(sessionID) { return }
        guard let client else { return }
        await extensions.refreshSession(sessionID) {
            try await client.request(
                .sessionExtensions,
                params: .object(["sessionId": .string(sessionID)])
            )
        }
    }

    struct AdaptorV2SkillList: Decodable {
        var skills: [RACPV2Skill]
    }

    struct AdaptorV2SkillEnvelope: Decodable {
        var skill: RACPV2Skill
    }

    struct AdaptorV2DeleteEnvelope: Decodable {
        var deleted: Bool
    }

    struct AdaptorV2ProviderList: Decodable {
        var providers: [RACPV2Provider]
    }

    struct AdaptorV2ProviderEnvelope: Decodable {
        var provider: RACPV2Provider
    }

    /// v2 equivalent of the legacy SSL `provider-binding-status` probe: read the
    /// session's pinned provider/model, then verify it against the PI-adaptor store.
    func adaptorV2BindingStatus(sessionId: String) async throws -> ProviderBindingStatus {
        if let fixtureStatus = fixtureAdaptorV2BindingStatusResult(sessionId: sessionId) {
            return fixtureStatus
        }
        guard let client, state.isOnline else { throw RACPV2Error.notConnected }
        let receipt = try await RemoteProviderOperations.bindingStatus(
            client: client,
            sessionId: sessionId
        )
        switch receipt {
        case .success(let status):
            return status
        case .failure(let failure):
            throw RACPV2Error.server(
                code: failure.rawValue,
                message: failure.displayMessage
            )
        case .unparseable(let reason):
            throw RACPV2Error.protocolViolation(reason)
        }
    }

    func listAdaptorSkills() async throws -> [RACPV2Skill] {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: AdaptorV2SkillList = try await client.request(
            .skillList,
            params: .object([:])
        )
        return result.skills
    }

    func installAdaptorSkill(source: JSONValue, replace: Bool = false) async throws -> RACPV2Skill {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: AdaptorV2SkillEnvelope = try await client.request(
            .skillInstall,
            params: .object([
                "source": source,
                "replace": .bool(replace),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("skill_install_\(UUID().uuidString)")
                ])
            ])
        )
        return result.skill
    }

    func deleteAdaptorSkill(id: String) async throws {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let _: AdaptorV2DeleteEnvelope = try await client.request(
            .skillDelete,
            params: .object([
                "skillId": .string(id),
                "confirmSkillId": .string(id),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("skill_delete_\(UUID().uuidString)")
                ])
            ])
        )
    }

    /// 让服务器上的 AI 根据首条指令生成会话标题。
    func suggestSessionTitle(
        sessionId: String,
        instruction: String,
        providerId: String,
        modelId: String,
        apiKey: String?,
        providerBinding: RACPProviderKeyBinding?,
        thinkingLevel: String?
    ) async throws -> String {
        guard let client, state.isOnline else { throw RACPV2Error.notConnected }
        return try await client.suggestSessionTitle(
            sessionId: sessionId,
            instruction: instruction,
            providerId: providerId,
            modelId: modelId,
            apiKey: apiKey,
            providerBinding: providerBinding,
            thinkingLevel: thinkingLevel
        )
    }

    /// 把会话标题写回服务器，保证其他客户端看到同一个名字。
    func renameSession(sessionId: String, title: String) async throws {
        guard let client, state.isOnline else { throw RACPV2Error.notConnected }
        try await client.renameSession(sessionId: sessionId, title: title)
    }

    func listAdaptorProviders() async throws -> [RACPV2Provider] {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: AdaptorV2ProviderList = try await client.request(
            .providerList,
            params: .object([:])
        )
        return result.providers
    }

    func createAdaptorProvider(
        name: String,
        baseURL: String,
        apiKey: String,
        modelID: String
    ) async throws -> RACPV2Provider {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let model: JSONValue = .object([
            "id": .string(modelID),
            "displayName": .string(modelID),
            "contextWindow": .number(128000),
            "maxTokens": .number(16384),
            "thinkingLevels": .array([]),
            "defaultThinkingLevel": .null,
            "supportsImages": .bool(false)
        ])
        let result: AdaptorV2ProviderEnvelope = try await client.request(
            .providerCreate,
            params: .object([
                "provider": .object([
                    "name": .string(name),
                    "vendorKey": .string("v2-\(UUID().uuidString)"),
                    "type": .string("openai_compatible"),
                    "protocol": .string("openai_completions"),
                    "baseUrl": .string(baseURL),
                    "authKind": .string("api_key"),
                    "apiKey": .string(apiKey),
                    "models": .array([model])
                ]),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_create_\(UUID().uuidString)")
                ])
            ])
        )
        return result.provider
    }

    /// Mirror a provider (with its full model list and API key) into the v2 PI-adaptor
    /// provider store.
    ///
    /// The v2 PI-adaptor resolves a session's provider/model only from its own store
    /// (`provider/list`). Providers imported over the legacy SSH path live in a
    /// different store, so a session bound to them can never run. Mirroring keeps
    /// both stores in sync and returns the PI-adaptor-side id to record locally.
    func registerAdaptorProvider(
        name: String,
        vendorKey: String,
        baseURL: String,
        apiKey: String,
        models: [ProviderModelSpec]
    ) async throws -> RACPV2Provider {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        guard !models.isEmpty else {
            throw RACPV2Error.protocolViolation("provider has no models")
        }
        let modelValues: [JSONValue] = models.map { spec in
            .object([
                "id": .string(spec.id),
                "displayName": .string(spec.alias ?? spec.id),
                "contextWindow": .number(Double(spec.contextWindow)),
                "maxTokens": .number(Double(spec.maxTokens)),
                "thinkingLevels": .array(spec.thinkingLevels.map { .string($0) }),
                "defaultThinkingLevel": spec.defaultThinkingLevel.map { .string($0) } ?? .null,
                "supportsImages": .bool(spec.supportsImages ?? false)
            ])
        }
        let result: AdaptorV2ProviderEnvelope = try await client.request(
            .providerCreate,
            params: .object([
                "provider": .object([
                    "name": .string(name),
                    "vendorKey": .string(vendorKey),
                    "type": .string("openai_compatible"),
                    "protocol": .string("openai_completions"),
                    "baseUrl": .string(baseURL),
                    "authKind": .string("api_key"),
                    "apiKey": .string(apiKey),
                    "models": .array(modelValues)
                ]),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_create_\(UUID().uuidString)")
                ])
            ])
        )
        PILog.info(
            "Model",
            "provider/create(mirror) provider=\(String(result.provider.id.prefix(8))) key=present"
        )
        return result.provider
    }

    /// 完整替换已配置 Provider 的模型列表。
    ///
    /// 密钥语义：缺省表示「本次不改」，请求里省略 `apiKey`；服务器不落盘任何密钥，
    /// 发送时由 `turn/start` 另带本机 Keychain 明文。客户端只在用户确实改过密钥
    /// 时把新值随本次请求上传（服务器仅校验后丢弃），不把它当作长期保存。
    func updateAdaptorProvider(
        id: String,
        input: ProviderUpdateInput
    ) async throws -> RACPV2Provider {
        if let updated = try fixtureUpdateAdaptorProviderIfApplicable(id: id, input: input) {
            return updated
        }
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        guard let existing = try await listAdaptorProviders().first(where: { $0.id == id }) else {
            throw RACPV2Error.server(code: "NOT_FOUND", message: "模型服务不存在")
        }
        let composition = ProviderUpdateComposer.compose(existing: existing, input: input)
        guard composition.isValid else {
            throw ProviderImportValidationFailure(issues: composition.issues)
        }
        logProviderUpdate(id: id, composition: composition)
        let result: AdaptorV2ProviderEnvelope
        do {
            result = try await client.request(
                .providerUpdate,
                params: .object([
                    "providerId": .string(id),
                    "provider": composition.fields,
                    "context": .object([
                        "requestId": .string("req_\(UUID().uuidString)"),
                        "idempotencyKey": .string("provider_update_\(UUID().uuidString)")
                    ])
                ])
            )
        } catch let error as RACPClientError {
            throw Self.v2Error(from: error)
        }
        return result.provider
    }

    /// 只记 `apiKey` 是「省略」还是「本次替换」，不记明文：用于回答
    /// 「provider 配置上传了，key 是否同步上传」这类排查，且满足日志不落密钥。
    func logProviderUpdate(id: String, composition: ProviderUpdateComposition) {
        PILog.info(
            "Model",
            "provider/update id=\(String(id.prefix(8)))"
                + " apiKey=\(composition.input.apiKey == nil ? "unchanged(omitted)" : "replacement(uploaded)")"
                + " models=\(composition.input.models.count)"
        )
    }

    /// 保留旧“编辑首项模型 ID”的辅助入口；主模型服务使用完整列表更新。

    func updateAdaptorProvider(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String?,
        modelID: String
    ) async throws -> RACPV2Provider {
        guard let existing = try await listAdaptorProviders().first(where: { $0.id == id }) else {
            throw RACPV2Error.server(code: "NOT_FOUND", message: "模型服务不存在")
        }
        let models = existing.models.enumerated().map { index, model in
            let editsPrimary = index == 0 && !modelID.isEmpty && model.id != modelID
            return ProviderModelSpec(
                id: editsPrimary ? modelID : model.id,
                contextWindow: model.contextWindow,
                maxTokens: model.maxTokens,
                thinkingLevels: model.thinkingLevels,
                defaultThinkingLevel: model.defaultThinkingLevel,
                alias: editsPrimary ? modelID : model.displayName,
                supportsImages: model.supportsImages
            )
        }
        return try await updateAdaptorProvider(
            id: id,
            input: ProviderUpdateInput(
                name: name, baseURL: baseURL, apiKey: apiKey, models: models,
                defaultModelID: models.first?.id
            )
        )
    }

    func deleteAdaptorProvider(id: String) async throws {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        do {
            let _: AdaptorV2DeleteEnvelope = try await client.request(
                .providerDelete,
                params: .object([
                    "providerId": .string(id),
                    "confirmProviderId": .string(id),
                    "context": .object([
                        "requestId": .string("req_\(UUID().uuidString)"),
                        "idempotencyKey": .string("provider_delete_\(UUID().uuidString)")
                    ])
                ])
            )
        } catch let error as RACPClientError {
            // `v2Request` 抛的是 `RACPClientError`；统一折成 `RACPV2Error`，
            // 调用方才能按错误码识别 NOT_FOUND 等幂等/可重试语义。
            throw Self.v2Error(from: error)
        }
    }

    static func v2Error(from error: RACPClientError) -> RACPV2Error {
        switch error {
        case .server(let code, let message):
            return .server(code: code.rawValue, message: message)
        case .notConnected:
            return .notConnected
        case .protocolMismatch(let detail), .timedOut(let detail), .malformedFrame(let detail):
            return .protocolViolation(detail)
        }
    }

    func adaptorUnitSnapshot(record: HostRecord) async throws -> AdaptorUnitSnapshot {
        if let snapshot = try fixtureAdaptorUnitSnapshotIfApplicable() {
            return snapshot
        }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        let result: SSHExecResult
        do {
            result = try await connection.transport.exec(
                "systemctl --user show pi-adaptor.service --property=LoadState,ActiveState,UnitFileState",
                timeout: 15
            )
        } catch {
            await connection.transport.close()
            throw error
        }
        await connection.transport.close()
        guard result.exitStatus == 0 else {
            throw AdaptorUnitProbeError.commandFailed(result.stderrText)
        }
        do {
            return try AdaptorUnitSnapshotParser.parse(result.stdoutText)
        } catch {
            throw RACPClientError.malformedFrame(error.localizedDescription)
        }
    }

    func installedPiVersion(record: HostRecord) async throws -> RemotePiVersion {
        try await withPiCLISSH(record: record) { transport in
            try await RemotePiMaintenance.installedVersion(using: transport)
        }
    }

    func upgradePiCLI(record: HostRecord, from installed: RemotePiVersion, toAtLeast latest: RemotePiVersion) async throws -> RemotePiVersion {
        try await withPiCLISSH(record: record) { transport in
            try await RemotePiMaintenance.upgrade(from: installed, toAtLeast: latest, using: transport)
        }
    }

    func withPiCLISSH(
        record: HostRecord,
        _ operation: (SSHTransport) async throws -> RemotePiVersion
    ) async throws -> RemotePiVersion {
        func matchesSavedAccount() -> Bool {
            guard let current = prepareHostConnection(record) else { return false }
            return current.host == record.host && current.port == record.port
                && current.username == record.username && current.authKind == record.authKind
        }
        guard matchesSavedAccount() else { throw ConnectionLifecycleError.connectionChanged }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        guard activePiCLIAccounts.insert(account).inserted else { throw RemotePiMaintenanceError.busy }
        defer { activePiCLIAccounts.remove(account) }
        let connection = try await connectSSH(record: record, credential: credential, account: account)
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            guard matchesSavedAccount() else { throw ConnectionLifecycleError.connectionChanged }
            let version = try await operation(connection.transport)
            await connection.transport.close()
            return version
        } catch {
            await connection.transport.close()
            throw error
        }
    }

    func makeHostKeyBroker(
        account: String,
        address: String
    ) -> (UUID, HostKeyPromptBroker) {
        for broker in brokers.values {
            broker.cancel()
        }
        hostKeyPrompt = nil
        let operationID = UUID()
        let broker = HostKeyPromptBroker(
            operationID: operationID,
            account: account,
            address: address,
            onPrompt: { [weak self] prompt in
                Task { @MainActor in
                    guard let self,
                          self.brokers[operationID]?.isCancelled == false
                    else { return }
                    self.hostKeyPrompt = prompt
                }
            }
        )
        brokers[operationID] = broker
        return (operationID, broker)
    }

    /// Resolve the loopback RACP port to tunnel to.
    ///
    /// Requirement: the user must not configure a host port. Prefer a recorded
    /// value, otherwise discover it over SSH (see `HostPortResolver`). Returns
    /// nil when the value cannot be determined so the caller reports an explicit
    /// offline reason rather than silently tunneling to a guessed port — a guess
    /// could reach a different PI-adaptor sharing the machine.
    func resolveHostPort(
        record: HostRecord,
        credential: SSHCredential,
        account: String,
        pinned: SSHHostKey?
    ) async -> Int? {
        if let port = record.hostPort, (1...65_535).contains(port) {
            return port
        }
        let (operationID, promptBroker) = makeHostKeyBroker(account: account, address: record.address)
        defer { releaseHostKeyBroker(operationID) }
        do {
            let transport = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                confirmer: promptBroker,
                timeout: 15
            )
            do {
                let result = try await transport.exec(HostPortResolver.probeCommand, timeout: 15)
                await transport.close()
                if let port = HostPortResolver.resolve(stdout: result.stdoutText) {
                    onResolvedHostPort?(record.id, port)
                    return port
                }
            } catch {
                // exec 失败也必须关闭已建立的 SSH 连接，否则反复探测会累积通道。
                await transport.close()
                return nil
            }
        } catch {
            return nil
        }
        return nil
    }

    func releaseHostKeyBroker(_ operationID: UUID) {
        brokers.removeValue(forKey: operationID)
        if connectionBrokerID == operationID {
            connectionBrokerID = nil
        }
        if hostKeyPrompt?.operationID == operationID {
            hostKeyPrompt = nil
        }
    }

    func connectSSH(
        record: HostRecord,
        credential: SSHCredential,
        account: String,
        timeout: TimeInterval = 20
    ) async throws -> (transport: SSHTransport, operationID: UUID) {
        let pinned = KeychainStore.loadHostKey(account: account)
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        do {
            let transport = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                confirmer: promptBroker,
                timeout: timeout
            )
            return (transport, operationID)
        } catch {
            releaseHostKeyBroker(operationID)
            throw error
        }
    }

    func remainingProviderBudget(_ deadline: Date) -> TimeInterval {
        max(0.1, deadline.timeIntervalSinceNow)
    }

}
