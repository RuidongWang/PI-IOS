import Foundation
import UIKit
import Combine
import PIiOSCore
import PIiOSNet


private final class BootstrapDirectAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var hostId: String?
    private var trust: BootstrapDirectTrust?
    private var trustError: String?

    func setHostId(_ value: String) { lock.withLock { hostId = value } }
    func setTrust(_ value: BootstrapDirectTrust?) { lock.withLock { trust = value } }
    func setTrustError(_ value: String) { lock.withLock { trustError = value } }
    var current: (hostId: String?, trust: BootstrapDirectTrust?, error: String?) {
        lock.withLock { (hostId, trust, trustError) }
    }
}


private struct RecoveryHostKeyConfirmer: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        status == .matches ? .trust : .reject
    }
}

/// 把手握期间的主机指纹判定转成「等界面回答」的 async 调用（AC-02.1）。
///
/// `matches` 不打扰用户；`firstUse` / `changed` 都要界面参与，`changed` 只允许拒绝（AC-02.2）。

extension ConnectionModel {
    func completeInstallSSHOnly(hostID: UUID, attemptId: String) async {
        guard await discardBootstrapDirect(hostID: hostID, attemptId: attemptId) else { return }
        if let old = installOutcomes[hostID], old.attemptId == attemptId {
            installOutcomes[hostID] = AdaptorInstallRunOutcome(
                result: old.result,
                releaseVersion: old.releaseVersion,
                attemptId: old.attemptId,
                releaseSource: old.releaseSource,
                adaptorHostId: old.adaptorHostId,
                directEndpoint: old.directEndpoint,
                directVerified: false,
                directError: old.directError,
                requiresSSHOnlyConfirmation: false
            )
        }
    }

    @discardableResult
    func discardBootstrapDirect(hostID: UUID, attemptId: String) async -> Bool {
        guard let pending = pendingBootstrapTransports[hostID], pending.attemptId == attemptId else { return false }
        pendingBootstrapTransports.removeValue(forKey: hostID)
#if DEBUG
        if let clearDirectTrustExecutorForTesting {
            await clearDirectTrustExecutorForTesting(attemptId)
        }
        if pending.transport == nil {
            await transportCloseExecutorForTesting?()
        }
#endif
        if let transport = pending.transport {
            _ = try? await transport.exec(
                BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                stdin: nil,
                timeout: 15
            )
            await transport.close()
        }
        return true
    }

    /// Retries only the direct socket validation, never install/pair/revoke/staging.
    func retryBootstrapDirect(
        record: HostRecord,
        attemptId: String
    ) async -> AdaptorInstallRunOutcome? {
        guard let pending = pendingBootstrapTransports[record.id], pending.attemptId == attemptId,
              let old = installOutcomes[record.id], old.attemptId == attemptId,
              let endpoint = old.directEndpoint,
              let adaptorHostId = old.adaptorHostId
        else { return nil }
        let verification: (verified: Bool, error: String?)
#if DEBUG
        if let retryBootstrapDirectHandlerForTesting {
            verification = await retryBootstrapDirectHandlerForTesting(record, pending.trust, adaptorHostId)
        } else {
            verification = await attemptBootstrapDirect(
                record: record,
                endpoint: endpoint,
                trust: pending.trust,
                expectedHostId: adaptorHostId,
                retryAttemptId: attemptId
            )
        }
#else
        verification = await attemptBootstrapDirect(
            record: record,
            endpoint: endpoint,
            trust: pending.trust,
            expectedHostId: adaptorHostId,
            retryAttemptId: attemptId
        )
#endif
        guard pendingBootstrapTransports[record.id]?.attemptId == attemptId else { return nil }
        let requiresConfirmation = !verification.verified && verification.error != nil
        let outcome = AdaptorInstallRunOutcome(
            result: old.result,
            releaseVersion: old.releaseVersion,
            attemptId: old.attemptId,
            releaseSource: old.releaseSource,
            adaptorHostId: old.adaptorHostId,
            directEndpoint: old.directEndpoint,
            directVerified: verification.verified,
            directError: verification.error,
            requiresSSHOnlyConfirmation: requiresConfirmation
        )
        installOutcomes[record.id] = outcome
        if verification.verified {
            onDirectVerified?(record.id, endpoint, adaptorHostId)
            await discardBootstrapDirect(hostID: record.id, attemptId: attemptId)
        }
        return outcome
    }


#if DEBUG
    func attemptBootstrapDirectForTesting(
        record: HostRecord,
        endpoint: String,
        trust: BootstrapDirectTrust?,
        expectedHostId: String?
    ) async -> (verified: Bool, error: String?) {
        await attemptBootstrapDirect(
            record: record,
            endpoint: endpoint,
            trust: trust,
            expectedHostId: expectedHostId
        )
    }

    func installBootstrapRetryOutcomeForTesting(
        hostID: UUID,
        outcome: AdaptorInstallRunOutcome,
        trust: BootstrapDirectTrust?
    ) {
        installOutcomes[hostID] = outcome
        pendingBootstrapTransports[hostID] = (outcome.attemptId, nil, trust)
    }
#endif

    // MARK: - 测试连接（SSH）

    /// 「保存并测试连接」：走真实的 SSH 握手 + 认证 + 一次 `exec`，返回可展示的结果。
    ///
    /// 不做假成功：任何一步失败都返回错误原文；指纹首次出现时会挂起等用户核对（AC-02.1）。
    func testConnection(record: HostRecord, credential: SSHCredential) async -> String {
        isTesting = true
        defer { isTesting = false }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        let pinned = KeychainStore.loadHostKey(account: account)
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        defer { releaseHostKeyBroker(operationID) }

        let request = SSHConnectionRequest(
            host: record.host,
            port: record.port,
            username: record.username,
            credential: credential,
            pinnedHostKey: pinned
        )
        do {
            let transport = try await SSHTransport.connect(request, confirmer: promptBroker)
            let result = try await transport.exec("true", timeout: 15)
            await transport.close()
            let fingerprint = transport.presentedHostKey?.fingerprint ?? pinned?.fingerprint ?? "未知"
            let message: String
            if result.exitStatus == 0 {
                message = "SSH 连接成功，主机指纹 \(fingerprint)"
            } else {
                message = "SSH 已连接，但远端命令返回退出码 \(result.exitStatus)："
                    + ConnectionDiagnosticRedactor.redact(result.stderrText)
            }
            testResult = message
            return message
        } catch {
            let message = ConnectionErrorText.describe(error)
            testResult = message
            return message
        }
    }

    // MARK: - PI-adaptor 配对

    /// 使用服务器 `pi-adaptor --pair` 输出的一次性令牌完成 RACP 配对。
    ///
    /// `pairOnce` 只交换设备凭证并立即断开；调用方随后必须用已保存的设备令牌重新建连。
    func pair(record: HostRecord, credential: SSHCredential, pairingToken: String) async throws {
        guard let token = RACPPairingToken.normalize(pairingToken) else {
            throw ConnectionPairingError.invalidToken
        }
        await disconnect()

        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        let pinned = KeychainStore.loadHostKey(account: account)
        guard let hostPort = await resolveHostPort(
            record: record,
            credential: credential,
            account: account,
            pinned: pinned
        ) else {
            throw ConnectionPairingError.missingHostPort
        }
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        defer { releaseHostKeyBroker(operationID) }

        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                hostPort: hostPort,
                deviceToken: token
            ),
            confirmer: promptBroker
        )
        let result = try await client.pairOnce(deviceLabel: UIDevice.current.name)
        guard KeychainStore.savePairing(
            deviceId: result.deviceId,
            deviceToken: result.deviceToken,
            hostID: record.id
        ) else {
            throw ConnectionPairingError.keychainWriteFailed
        }
    }

    // MARK: - PI-adaptor 安装

    /// Runs the real remote bootstrap state machine over one SSH transport.
    ///
    /// The same transport is passed to the pairing and device-verification
    /// adapters. This is an isolated/test-injected operation; callers must not
    /// invoke it against a production PI-adaptor without explicit user action.
    func installAdaptor(
        request: InstallRequest,
        directTrustAuthorizer: (@Sendable (BootstrapDirectTrust) async -> Bool)? = nil,
        /// 版本解析完成时回调，用于在安装页显示本次目标版本与回退原因。
        onReleaseResolved: ((AdaptorReleaseResolution) -> Void)? = nil,
        eventHandler: BootstrapRunner.EventHandler? = nil
    ) async throws -> AdaptorInstallRunOutcome {
#if DEBUG
        installAdaptorCallCountForTesting += 1
#endif
        let record = request.record
        guard activeAdaptorInstalls.insert(record.id).inserted else {
            throw BootstrapRunnerError.installationBusy
        }
        defer { activeAdaptorInstalls.remove(record.id) }
        let port = request.adaptorPort
        let releaseVersion = request.releaseVersion
        let force = request.force
        let direct = request.direct
        let directEndpoint = request.directEndpoint
        let authorizeDirectPin = request.authorizeDirectPin
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        // The request is built from the record at click time; a mismatch here means
        // the caller assembled it from a different record and must be rejected.
        guard request.target.matches(
            record: record,
            identityGeneration: request.target.identityGeneration
        ) else {
            throw AdaptorInstallError.installationSuperseded
        }
        if let previous = pendingBootstrapTransports[record.id] {
            await discardBootstrapDirect(hostID: record.id, attemptId: previous.attemptId)
        }
        await recoverStagedPairings(record: record, attemptId: nil)
        try Task.checkCancellation()
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }

        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        let transport = connection.transport
        var preserveBootstrapTransport = false
        defer {
            releaseHostKeyBroker(connection.operationID)
            if !preserveBootstrapTransport {
                Task { await transport.close() }
            }
        }

        let probe: SSHExecResult
        do {
            probe = try await transport.exec(
                BootstrapRemoteCommand.probe,
                timeout: 15
            )
        } catch {
            await transport.close()
            throw error
        }
        guard probe.exitStatus == 0 else {
            await transport.close()
            throw AdaptorInstallError.probeFailed(probe.stderrText)
        }
        let identity = try parseBootstrapProbe(probe.stdoutText)
        let decision = BootstrapPlatformProbe.decide(
            unameSystem: identity.platform,
            unameMachine: identity.architecture
        )
        guard case let .supported(target) = decision else {
            await transport.close()
            if case let .unsupported(reason) = decision {
                return AdaptorInstallRunOutcome(
                    result: .unsupported(reason),
                    releaseVersion: releaseVersion ?? PIAdaptorRelease.releaseVersion,
                    attemptId: "",
                    releaseSource: nil
                )
            }
            throw AdaptorInstallError.malformedProbe
        }

        // 架构确定后才能解析对应产物。显式版本只用于测试，仍走内置固定摘要。
        let resolution: AdaptorReleaseResolution
        if let releaseVersion {
            guard releaseVersion == PIAdaptorRelease.patchedReleaseVersion,
                  let release = PIAdaptorRelease.patched(
                    target: target,
                    baseURL: ConnectionModel.defaultAdaptorInstallReleaseBaseURL
                  )
            else {
                await transport.close()
                throw AdaptorInstallError.invalidReleaseVersion
            }
            resolution = AdaptorReleaseResolution(release: release, source: .fallback(reason: "已手动指定内置版本"))
        } else {
            guard let resolved = await releaseCatalog.resolve(
                target: target,
                fallbackBaseURL: ConnectionModel.defaultAdaptorInstallReleaseBaseURL
            ) else {
                await transport.close()
                throw AdaptorInstallError.noCompatibleRelease
            }
            resolution = resolved
        }
        // 用户取消时不能继续安装（尤其不能因为取消就静默装内置回退版）。
        if Task.isCancelled {
            await transport.close()
            throw CancellationError()
        }
        onReleaseResolved?(resolution)
        let release = resolution.release

        let attemptId = "ios-\(UUID().uuidString.lowercased())"
        let scriptConfiguration = try BootstrapScriptConfiguration(
            release: release,
            attemptId: attemptId,
            hostArchitecture: identity.architecture,
            port: port,
            force: force,
            direct: direct
        )
        // Keep the newly issued token in memory until runtime identity and
        // version have been proven. A failed reinstall therefore cannot
        // overwrite the previous PI-adaptor's working token.
        let sshFingerprint = KeychainStore.loadHostKey(account: account)?.fingerprint
        let pairingAdapter = BootstrapInstallPairingAdapter(
            persist: { device in
                guard KeychainStore.saveStagedPairing(
                    deviceId: device.deviceId,
                    deviceToken: device.deviceToken,
                    hostID: record.id,
                    attemptId: attemptId,
                    targetPort: port,
                    sshAccount: account,
                    sshFingerprint: sshFingerprint
                ) else {
                    throw BootstrapInstallAdapterError.persistenceFailed
                }
            }
        )
        let attemptState = BootstrapDirectAttemptState()
        let verificationAdapter = BootstrapInstallVerificationAdapter(
            verify: { commandTransport, hostPort, device in
                guard let ssh = commandTransport as? SSHTransport else {
                    throw BootstrapInstallAdapterError.requiresSSHTransport
                }
                let identity = try await RACPClient.verifyDeviceIdentity(
                    using: ssh,
                    hostPort: hostPort,
                    deviceToken: device.deviceToken
                )
                attemptState.setHostId(identity.adaptorHostId)
                return identity.serverInfo
            }
        )
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairingAdapter,
            verifier: verificationAdapter,
            eventHandler: { event in
                await eventHandler?(event)
                if case .verificationCompleted = event {
                    do {
                        let response = try await transport.exec(
                            BootstrapRemoteCommand.readDirectTrust(attemptId: attemptId),
                            stdin: nil,
                            timeout: 20
                        )
                        guard response.exitStatus == 0 else {
                            attemptState.setTrustError("DIRECT_TRUST_INVALID")
                            return
                        }
                        let text = response.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.isEmpty {
                            attemptState.setTrust(nil)
                        } else {
                            let trust = try BootstrapDirectTrust.parse(
                                data: Data(text.utf8),
                                expectedAttemptId: attemptId
                            )
                            attemptState.setTrust(trust)
                        }
                    } catch {
                        attemptState.setTrustError("DIRECT_TRUST_INVALID")
                    }
                }
            }
        )
        let result: BootstrapRunResult
        do {
            result = try await runner.run(
                configuration: scriptConfiguration,
                deviceLabel: UIDevice.current.name,
                keepTransportOpen: true
            )
        } catch {
            await recoverStagedPairings(record: record, attemptId: attemptId)
            throw error
        }
        let identityState = attemptState.current
        if case .succeeded = result {
            guard let adaptorHostId = identityState.hostId, !adaptorHostId.isEmpty else {
                await recoverStagedPairings(record: record, attemptId: attemptId)
                throw AdaptorInstallError.adaptorIdentityMissing
            }
            let canonicalEndpoint = directEndpoint.flatMap {
                HostValidator.canonicalDirectEndpoint($0)
            }
            let commit = BootstrapPairingCommit(
                target: request.target,
                adaptorHostId: adaptorHostId,
                port: port,
                version: release.version,
                attemptId: attemptId,
                releaseSource: resolution.usedFallback ? .fallback : .latest,
                directEndpoint: canonicalEndpoint
            )
            let commitResult: BootstrapPairingCommitResult
            if let onBootstrapPairingCommit {
                commitResult = onBootstrapPairingCommit(commit)
            } else {
                // No app-level owner (tests/previews): still promote only after the
                // remote verification succeeded, and clean up this attempt on failure.
                if KeychainStore.promoteStagedPairing(
                    hostID: record.id,
                    attemptId: attemptId,
                    verifiedAdaptorHostId: adaptorHostId,
                    previousAdaptorHostId: record.adaptorHostId
                ) {
                    commitResult = .committed
                } else {
                    commitResult = .tokenPromotionFailed
                }
            }
            if commitResult == .staleTarget || commitResult == .tokenPromotionFailed {
                await recoverStagedPairings(record: record, attemptId: attemptId)
            }
            switch commitResult {
            case .committed:
                await recoverReplacedPairings(record: record, port: port, adaptorHostId: adaptorHostId)
            case .staleTarget:
                throw AdaptorInstallError.installationSuperseded
            case .receiptPersistenceFailed(let reason):
                throw AdaptorInstallError.receiptPersistenceFailed(reason)
            case .tokenPromotionFailed:
                throw ConnectionPairingError.keychainWriteFailed
            }
        } else {
            await recoverStagedPairings(record: record, attemptId: attemptId)
        }
        var directVerified = false
        var directError = identityState.error
        let canonicalEndpoint = directEndpoint.flatMap { HostValidator.canonicalDirectEndpoint($0) }
        if directEndpoint != nil && canonicalEndpoint == nil {
            directError = "direct endpoint 不合法"
        }
        var didRejectDirect = false
        let installSucceeded: Bool
        if case .succeeded = result { installSucceeded = true } else { installSucceeded = false }
        let wantsDirect = installSucceeded && !Task.isCancelled && canonicalEndpoint != nil
            && (authorizeDirectPin || directTrustAuthorizer != nil)
        var directAuthorized = authorizeDirectPin
        if wantsDirect, let trust = identityState.trust, let directTrustAuthorizer {
            directAuthorized = await directTrustAuthorizer(trust)
            didRejectDirect = !directAuthorized
            if didRejectDirect { directError = nil }
        }
        if wantsDirect, identityState.trust == nil, !didRejectDirect {
            directError = "DIRECT_TRUST_INVALID"
        }
        let shouldAttemptDirect = wantsDirect && !Task.isCancelled && directAuthorized && identityState.trust != nil
        if shouldAttemptDirect, let canonicalEndpoint {
            let verification = await attemptBootstrapDirect(
                record: record,
                endpoint: canonicalEndpoint,
                trust: identityState.trust,
                expectedHostId: identityState.hostId
            )
            directVerified = verification.verified
            directError = verification.error
            if verification.verified, let adaptorHostId = identityState.hostId, !adaptorHostId.isEmpty {
                // v0.0.2 parity: a successful first direct verification promotes the
                // record to directPreferred. The staged token was promoted above, and
                // `attemptBootstrapDirect` already saved the matching pin.
                onDirectVerified?(record.id, canonicalEndpoint, adaptorHostId)
            }
        }
        let requiresConfirmation = wantsDirect && !Task.isCancelled && !didRejectDirect && directError != nil
        if requiresConfirmation {
            pendingBootstrapTransports[record.id] = (attemptId, transport, identityState.trust)
            preserveBootstrapTransport = true
        } else {
            _ = try? await transport.exec(
                BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                stdin: nil,
                timeout: 15
            )
        }
        let outcome = AdaptorInstallRunOutcome(
            result: result,
            releaseVersion: release.version,
            attemptId: attemptId,
            releaseSource: resolution.source,
            adaptorHostId: identityState.hostId,
            directEndpoint: canonicalEndpoint,
            directVerified: directVerified,
            directError: directError,
            requiresSSHOnlyConfirmation: requiresConfirmation
        )
        installOutcomes[record.id] = outcome
        return outcome
    }

    func attemptBootstrapDirect(
        record: HostRecord,
        endpoint: String,
        trust: BootstrapDirectTrust?,
        expectedHostId: String?,
        retryAttemptId: String? = nil
    ) async -> (verified: Bool, error: String?) {
        guard let trust else { return (false, "DIRECT_TRUST_INVALID") }
        guard let expectedHostId, trust.hostId == expectedHostId else {
            return (false, "direct trust hostId 与认证 ping 不一致")
        }
        let now = Date()
        guard trust.notBefore <= now, trust.notAfter >= now else {
            return (false, "direct 证书不在有效期内")
        }
        guard let token = KeychainStore.loadDeviceToken(hostID: record.id),
              token.hasPrefix("pdt2.") else {
            return (false, "缺少已提升的 pdt2")
        }
        let pin = DirectTLSTrustPin(
            hostId: expectedHostId,
            certificateSHA256: trust.certificateSHA256,
            authorizedAt: now
        )
        func savePin() -> String? {
            guard !Task.isCancelled, KeychainStore.loadDeviceToken(hostID: record.id) == token,
                  retryAttemptId == nil || pendingBootstrapTransports[record.id]?.attemptId == retryAttemptId else {
                return "直连验证已结束或服务器配对已变化"
            }
            if let onPrepareHostConnection {
                guard let current = onPrepareHostConnection(record.id),
                      current.adaptorHostId == expectedHostId,
                      current.directEndpoint == endpoint,
                      current.installReceipt?.attemptId == trust.attemptId else {
                    return "直连配置已变化，请重新验证"
                }
            }
            return KeychainStore.saveDirectTLSTrustPin(pin, hostID: record.id) ? nil : "direct pin 未能写入 Keychain"
        }
#if DEBUG
        if let bootstrapDirectValidationHandlerForTesting {
            let result = await bootstrapDirectValidationHandlerForTesting()
            if result.verified, let error = savePin() {
                return (false, error)
            }
            return result
        }
#endif
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        let (operationID, promptBroker) = makeHostKeyBroker(account: account, address: record.address)
        defer { releaseHostKeyBroker(operationID) }
        guard let url = URL(string: endpoint) else { return (false, "direct endpoint 不合法") }
        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: nil,
                hostPort: nil,
                deviceToken: token,
                connectionPreference: .directPreferred,
                direct: DirectRACPConfiguration(
                    endpoint: url,
                    certificateSHA256: trust.certificateSHA256,
                    adaptorHostId: expectedHostId
                )
            ),
            confirmer: promptBroker
        )
        do {
            let updates = await client.start()
            for await update in updates {
                if case .state(.online) = update {
                    _ = await client.stopBestEffort(timeout: 1)
                    if let error = savePin() { return (false, error) }
                    return (true, nil)
                }
                if case .state(.offline(let reason)) = update {
                    throw RACPClientError.protocolMismatch(reason ?? "direct 首验失败")
                }
            }
            throw RACPClientError.notConnected
        } catch {
            _ = await client.stopBestEffort(timeout: 1)
            return (false, error.localizedDescription)
        }
    }

    /// Recover abandoned pairing attempts at launch. Installation holds the same
    /// gate so recovery cannot revoke an in-progress attempt.
    func recoverStagedPairings(record: HostRecord) async {
        guard activeAdaptorInstalls.insert(record.id).inserted else { return }
        defer { activeAdaptorInstalls.remove(record.id) }
        await recoverStagedPairings(record: record, attemptId: nil)
    }

    func recoverStagedPairings(record: HostRecord, attemptId: String?) async {
        let active = KeychainStore.loadActivePairing(hostID: record.id)
        let staging = KeychainStore.loadAllStagedPairings(hostID: record.id).filter {
            attemptId == nil || $0.attemptId == attemptId
        }
        _ = await BootstrapStagingRecoveryCoordinator.recover(
            staging: staging,
            activeDeviceId: active?.deviceId,
            activeDeviceToken: active?.deviceToken,
            revoke: { [self] attempt in
                guard KeychainStore.loadDeviceId(hostID: record.id) != attempt.deviceId else { return .failed }
                return await revokePairingBestEffort(
                    record: record,
                    port: attempt.targetPort,
                    deviceId: attempt.deviceId,
                    deviceToken: attempt.deviceToken,
                    expectedSSHAccount: attempt.sshAccount,
                    expectedSSHFingerprint: attempt.sshFingerprint
                )
            },
            clear: { attempt in
                KeychainStore.clearStagedPairing(attempt)
            }
        )
    }

    func recoverReplacedPairings(record: HostRecord, port: Int, adaptorHostId: String) async {
        guard let activeToken = KeychainStore.loadDeviceToken(hostID: record.id) else { return }
        let pending = KeychainStore.pendingPairingRevocations(hostID: record.id, activeToken: activeToken)
        for retired in pending where retired.adaptorHostId == adaptorHostId {
            guard KeychainStore.loadDeviceToken(hostID: record.id) == activeToken else { return }
            let result = await revokePairingBestEffort(
                record: record, port: port, deviceId: retired.deviceId, deviceToken: activeToken,
                expectedAdaptorHostId: adaptorHostId
            )
            guard result == .revoked || result == .notFound else { return }
            KeychainStore.confirmPairingRevocation(retired, hostID: record.id, activeToken: activeToken)
        }
    }

    func revokePairingBestEffort(
        record: HostRecord,
        port: Int,
        deviceId: String,
        deviceToken: String,
        expectedSSHAccount: String? = nil,
        expectedSSHFingerprint: String? = nil,
        expectedAdaptorHostId: String? = nil
    ) async -> BootstrapStagingRevokeResult {
#if DEBUG
        if let bootstrapRevocationHandlerForTesting {
            return await bootstrapRevocationHandlerForTesting(port, deviceId, deviceToken, expectedAdaptorHostId)
        }
#endif
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard expectedSSHAccount == nil || expectedSSHAccount == account,
              let credential = KeychainStore.loadCredential(account: account),
              let pinned = KeychainStore.loadHostKey(account: account),
              expectedSSHFingerprint == nil || expectedSSHFingerprint == pinned.fingerprint else { return .failed }

        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                hostPort: port,
                deviceToken: deviceToken
            ),
            confirmer: RecoveryHostKeyConfirmer()
        )
        // The operation may not cooperate with cancellation. The deadline wins
        // independently, then stopBestEffort separately bounds client shutdown.
        let result = await boundedAsyncValue(seconds: 8) { () -> BootstrapStagingRevokeResult in
            let stream = await client.start()
            for await update in stream {
                switch update {
                case .state(.online):
                    do {
                        if let expectedAdaptorHostId,
                           try await client.authenticatedHostId(timeout: 4) != expectedAdaptorHostId {
                            return .failed
                        }
                        // PI-adaptor returns false only when this device is already revoked.
                        return try await client.revokeDevice(deviceId: deviceId) ? .revoked : .notFound
                    } catch RACPClientError.server(.unknown("DEVICE_NOT_FOUND"), _) {
                        return .notFound
                    } catch {
                        return .failed
                    }
                case .error, .state(.offline):
                    return .failed
                default:
                    continue
                }
            }
            return .failed
        }
        _ = await client.stopBestEffort(timeout: 1)
        return result ?? .unknown
    }

    /// Reads the owner-only bootstrap log through a fresh SSH `exec`. The
    /// remote launcher never writes the pairing FIFO/token to this file.
    func hostInstallLog(record: HostRecord) async throws -> String {
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let result = try await connection.transport.exec(
                BootstrapInstallDiagnostics.logCommand,
                timeout: 20
            )
            await connection.transport.close()
            guard result.exitStatus == 0 else {
                throw AdaptorUnitProbeError.commandFailed(result.stderrText)
            }
            let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "服务器上还没有 bootstrap 日志。" : text
        } catch {
            await connection.transport.close()
            throw error
        }
    }

    /// Grants the one privilege required by the user-unit installation path:
    /// `loginctl enable-linger`. The password goes over SSH stdin only.
    func authorizeAdaptorInstall(record: HostRecord, sudoPassword: String) async throws {
        guard !sudoPassword.isEmpty else { throw AdaptorInstallError.emptySudoPassword }
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let result = try await connection.transport.exec(
                BootstrapInstallDiagnostics.enableLingerCommand,
                stdin: Data((sudoPassword + "\n").utf8),
                timeout: 20
            )
            await connection.transport.close()
            guard result.exitStatus == 0 else {
                throw AdaptorInstallError.sudoFailed(result.stderrText)
            }
        } catch {
            await connection.transport.close()
            throw error
        }
    }

    func parseBootstrapProbe(
        _ output: String
    ) throws -> (platform: String, architecture: String) {
        var platform: String?
        var architecture: String?
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0] == "platform" { platform = fields[1] }
            if fields[0] == "arch" { architecture = fields[1] }
        }
        guard let platform, let architecture,
              !platform.isEmpty, !architecture.isEmpty else {
            throw AdaptorInstallError.malformedProbe
        }
        return (platform, architecture)
    }

}
