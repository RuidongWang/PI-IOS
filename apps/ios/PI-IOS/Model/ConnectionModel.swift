import Foundation
import UIKit
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
            return "配对令牌格式不正确：应以 ppt1. 或 ppt2. 开头，且不能包含空白字符"
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
    case probeFailed(String)
    case malformedProbe
    case emptySudoPassword
    case sudoFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseVersion:
            return "内置的 PI-adaptor Release 版本、资产或仓库配置不合法"
        case .probeFailed(let detail):
            return detail.isEmpty ? "无法探测服务器平台" : detail
        case .malformedProbe:
            return "服务器平台探测输出不完整"
        case .emptySudoPassword:
            return "请输入 sudo 密码；空密码不会发送到服务器"
        case .sudoFailed(let detail):
            return detail.isEmpty ? "sudo 授权失败，pi-adaptor unit 未启动" : detail
        }
    }
}

struct BootstrapPairingCommit: Sendable {
    let hostID: UUID
    let adaptorHostId: String
    let port: Int
    let version: String
    let attemptId: String
    let releaseSource: AdaptorReleaseResolutionSource?
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

/// 测试夹具里不访问网络：直接回退内置版本，并给出可展示的原因。
private struct FixtureAdaptorReleaseCatalog: AdaptorReleaseResolving {
    func resolve(
        target: BootstrapArtifactTarget,
        fallbackBaseURL: String
    ) async -> AdaptorReleaseResolution? {
        guard let release = PIAdaptorRelease.patched(target: target, baseURL: fallbackBaseURL) else {
            return nil
        }
        return AdaptorReleaseResolution(release: release, source: .fallback(reason: "测试环境不访问网络"))
    }
}

/// 指纹核对页的数据（S-04「核对指纹」状态）。
struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    var operationID: UUID
    var account: String
    var address: String
    var key: SSHHostKey
    var status: HostKeyTrustStatus
}

/// 隧道 + RACP 的连接状态容器。界面只读这里的状态，不自行推断「在线」。
@MainActor
final class ConnectionModel: ObservableObject {
    static let deviceRevokedMessage = "服务器已撤销该设备的访问权限"
    /// 请求已发出但连接在回执前中断：服务器可能已经撤销，不能当成「未撤销」或「离线」。
    static let deviceRevokeUnconfirmedMessage =
        "撤销结果未确认：连接在服务器确认前中断，本机凭证尚未改动。请重新连接后确认设备状态，再决定是否重试。"

    nonisolated static let defaultAdaptorInstallReleaseVersion = PIAdaptorRelease.patchedReleaseVersion
    nonisolated static let defaultAdaptorInstallReleaseBaseURL = PIAdaptorRelease.defaultPatchedBaseURL

    @Published private(set) var state: RACPTunnelState = .offline(reason: nil)
    @Published private(set) var connectionStatus = ConnectionStatus()
    @Published private(set) var projects: [RACPProjectSummary] = []
    @Published private(set) var sessions: [RACPSessionSummary] = []
    @Published private(set) var info: RACPServerInfo?
    @Published private(set) var lastError: String?
    /// Invoked when the loopback PI-adaptor port is discovered over SSH so the owner
    /// (AppModel) can persist it onto the host record.
    var onResolvedHostPort: ((UUID, Int) -> Void)?
    var onDirectVerified: ((UUID, String, String) -> Void)?
    var onBootstrapPairingCommit: ((BootstrapPairingCommit) async -> Bool)?
    @Published private(set) var hasLoadedCatalog = false
    @Published private(set) var isRefreshingCatalog = false
    @Published private(set) var catalogError: String?
    /// 「保存并测试连接」的结果文案；nil 表示没有测过。
    @Published private(set) var testResult: String?
    @Published private(set) var isTesting = false
    @Published var hostKeyPrompt: HostKeyPrompt?

    private var client: RACPClient?
    var activeClient: RACPClient? { client }
    private var updateTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var candidateClient: RACPClient?
    private var candidateTask: Task<Void, Never>?
    private var hostCatalogRefreshTask: Task<Void, Never>?
    private var hostCatalogRefreshToken: UUID?
    private var hostCatalogRefreshPending = false
    private var brokers: [UUID: HostKeyPromptBroker] = [:]
    private var connectionBrokerID: UUID?
    private var connectedAccount: String?
    private var connectionGeneration = 0
    private var connectionIntentGeneration = 0
    private var catalogGeneration = 0
    private(set) var cacheHostID: UUID?
    private var offlineCacheLimit = PersistedState.defaultOfflineCacheLimit
    private var cacheStore: SessionCacheStore
    /// 每次真实 RACP client 建立时更新；缓存迟到写入据此拒绝旧连接结果。
    private var cacheClientID = UUID()
    private struct PendingDraftWrite {
        let lease: OfflineSessionCacheWriteLease
        let sessionID: String
        let text: String
        let idempotencyKey: String?
    }
    private var pendingDraftWrite: PendingDraftWrite?
    private var draftWriteTask: Task<Void, Never>?
    private var sessionCacheWriteTask: Task<Void, Never>?
    private var sessionCacheWritePending = false
    private var cacheFlushTask: Task<Void, Never>?
    private var cacheFlushGeneration = 0
    var currentCatalogHostID: UUID? { cacheHostID }
    /// 会话内的读写（发送、审批、排队、配置）全部走它。
    let session: SessionController
    private let usesUITestFixture: Bool
    private var fixtureProviderBindingStatuses: [String: ProviderBindingStatus] = [:]
    private var fixtureAdaptorUnitSnapshot: AdaptorUnitSnapshot?
    private var fixtureUpdatableProviders: [RACPV2Provider] = []
    private var fixtureCatalogs: [UUID: UITestFixture.Catalog] = [:]
    private var fixtureConnectionState: RACPTunnelState?
    private var fixtureSupportsRevoke = false
    /// 安装时解析最新稳定版；UI 测试夹具不访问网络。
    private let releaseCatalog: any AdaptorReleaseResolving
    private var installOutcomes: [UUID: AdaptorInstallRunOutcome] = [:]
    private var pendingBootstrapTransports: [UUID: (
        attemptId: String,
        transport: SSHTransport?,
        trust: BootstrapDirectTrust?
    )] = [:]

    func installOutcome(hostID: UUID, attemptId: String) -> AdaptorInstallRunOutcome? {
        guard let outcome = installOutcomes[hostID], outcome.attemptId == attemptId else { return nil }
        return outcome
    }

    /// Explicit user choice after a direct failure. Only now may bootstrap SSH close.
    func completeInstallSSHOnly(hostID: UUID, attemptId: String) async {
        guard let pending = pendingBootstrapTransports[hostID], pending.attemptId == attemptId else { return }
        pendingBootstrapTransports.removeValue(forKey: hostID)
#if DEBUG
        if let clearDirectTrustExecutorForTesting {
            await clearDirectTrustExecutorForTesting(attemptId)
        } else if let transport = pending.transport {
            _ = try? await transport.exec(
                BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                stdin: nil,
                timeout: 15
            )
            await transport.close()
        }
        if pending.transport == nil {
            await transportCloseExecutorForTesting?()
        }
#else
        if let transport = pending.transport {
            _ = try? await transport.exec(
                BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                stdin: nil,
                timeout: 15
            )
            await transport.close()
        }
#endif
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
                expectedHostId: adaptorHostId
            )
        }
#else
        verification = await attemptBootstrapDirect(
            record: record,
            endpoint: endpoint,
            trust: pending.trust,
            expectedHostId: adaptorHostId
        )
#endif
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
            pendingBootstrapTransports.removeValue(forKey: record.id)
#if DEBUG
            if let clearDirectTrustExecutorForTesting {
                await clearDirectTrustExecutorForTesting(attemptId)
            } else if let transport = pending.transport {
                _ = try? await transport.exec(
                    BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                    stdin: nil,
                    timeout: 15
                )
                await transport.close()
            }
            if pending.transport == nil {
                await transportCloseExecutorForTesting?()
            }
#else
            if let transport = pending.transport {
                _ = try? await transport.exec(
                    BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                    stdin: nil,
                    timeout: 15
                )
                await transport.close()
            }
#endif
            onDirectVerified?(record.id, endpoint, adaptorHostId)
        } else {
            pendingBootstrapTransports[record.id] = (attemptId, pending.transport, pending.trust)
        }
        return outcome
    }

#if DEBUG
    var retryBootstrapDirectHandlerForTesting: (
        (HostRecord, BootstrapDirectTrust?, String) async -> (verified: Bool, error: String?)
    )?
    var installAdaptorCallCountForTesting = 0
    var clearDirectTrustExecutorForTesting: ((String) async -> Void)?
    var transportCloseExecutorForTesting: (() async -> Void)?
    var bootstrapDirectValidationHandlerForTesting: (() async -> (verified: Bool, error: String?))?

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

#if DEBUG
    var disconnectFlushDelayForTesting: TimeInterval = 0
    var candidatePostPromotionDelayForTesting: TimeInterval = 0
    var beforeOldStatusCheckForTesting: (() async -> Void)?
    var skipCandidateRestoreForTesting = false
    var connectionGenerationForTesting: Int { connectionGeneration }
    var candidateClientForTesting: RACPClient? { candidateClient }

    func installConnectionPiecesForTesting(
        oldClient: RACPClient,
        candidate: RACPClient,
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

    init(fixture: UITestFixture? = nil, releaseCatalog: (any AdaptorReleaseResolving)? = nil) {
        self.releaseCatalog = releaseCatalog
            ?? (fixture == nil ? AdaptorReleaseCatalog() : FixtureAdaptorReleaseCatalog())
        usesUITestFixture = fixture != nil
        if let fixture {
            fixtureProviderBindingStatuses = fixture.providerBindingStatuses
            fixtureAdaptorUnitSnapshot = fixture.adaptorUnitSnapshot
            fixtureCatalogs = fixture.catalogs
            fixtureConnectionState = fixture.connectionState
            fixtureSupportsRevoke = fixture.supportsFixtureRevoke
            fixtureUpdatableProviders = fixture.updatableProviders
            cacheStore = SessionCacheStore(
                offlineCacheLimit: PersistedState.defaultOfflineCacheLimit,
                inMemory: fixture.cache
            )
            session = SessionController(requestKeys: SessionRequestKeyStore(fileURL: nil))
#if DEBUG
            session.configureUITestSnapshots(fixture.sessionSnapshots)
#endif
            if let catalog = fixture.catalog {
                projects = catalog.projects
                sessions = catalog.sessions
                info = catalog.info
                hasLoadedCatalog = true
                state = .online
            }
            if let fixtureConnectionState {
                state = fixtureConnectionState
            }
            connectionStatus = fixture.connectionStatus ?? ConnectionStatus()
        } else {
            cacheStore = SessionCacheStore(offlineCacheLimit: PersistedState.defaultOfflineCacheLimit)
            session = SessionController()
        }
        session.onDraftChanged = { [weak self] sessionID, text, idempotencyKey in
            self?.scheduleDraftCache(
                sessionID: sessionID,
                text: text,
                idempotencyKey: idempotencyKey
            )
        }
        session.onSessionWillChange = { [weak self] in
            await self?.flushPendingCacheWrites()
        }
#if DEBUG
        session.configureUITestInterruption(enabled: fixture?.supportsFixtureInterrupt == true)
#endif
    }

    /// 设置里的「离线缓存上限」变化时同步给缓存层（AC-15.1）。
    func updateOfflineCacheLimit(_ limit: Int) {
        offlineCacheLimit = limit
        cacheStore = cacheStore.withOfflineCacheLimit(limit)
    }

    func setCacheHostID(_ hostID: UUID?) {
        cacheHostID = hostID
        if let hostID, let catalog = fixtureCatalogs[hostID] {
            applyFixtureCatalog(catalog)
        }
    }

    var cacheItemLimit: Int { cacheStore.itemLimit }

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
        record: HostRecord,
        port: Int,
        /// 测试专用：显式指定内置版本。正常安装传 `nil`，自动解析最新稳定发布。
        releaseVersion: String? = nil,
        /// 强制重装：忽略 PI-adaptor install receipt，重新下载、校验并激活。
        force: Bool = false,
        direct: BootstrapDirectConfiguration? = nil,
        directEndpoint: String? = nil,
        authorizeDirectPin: Bool = false,
        directTrustAuthorizer: (@Sendable (BootstrapDirectTrust) async -> Bool)? = nil,
        /// 版本解析完成时回调，用于在安装页显示本次目标版本与回退原因。
        onReleaseResolved: ((AdaptorReleaseResolution) -> Void)? = nil,
        eventHandler: BootstrapRunner.EventHandler? = nil
    ) async throws -> AdaptorInstallRunOutcome {
#if DEBUG
        installAdaptorCallCountForTesting += 1
#endif
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        if let previous = pendingBootstrapTransports.removeValue(forKey: record.id) {
            await previous.transport?.close()
        }
        await recoverStagedPairings(record: record)
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
                throw AdaptorInstallError.invalidReleaseVersion
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
        let pairingAdapter = BootstrapInstallPairingAdapter(
            persist: { device in
                guard KeychainStore.saveStagedPairing(
                    deviceId: device.deviceId,
                    deviceToken: device.deviceToken,
                    hostID: record.id,
                    attemptId: attemptId,
                    targetPort: port
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
            await revokeStagedPairingBestEffort(
                record: record,
                port: port,
                attemptId: attemptId
            )
            KeychainStore.clearStagedPairing(hostID: record.id, attemptId: attemptId)
            throw error
        }
        if case .succeeded = result {
            guard KeychainStore.promoteStagedPairing(
                hostID: record.id,
                attemptId: attemptId
            ) else {
                await revokeStagedPairingBestEffort(
                    record: record,
                    port: port,
                    attemptId: attemptId
                )
                KeychainStore.clearStagedPairing(hostID: record.id, attemptId: attemptId)
                throw ConnectionPairingError.keychainWriteFailed
            }
        } else {
            await revokeStagedPairingBestEffort(
                record: record,
                port: port,
                attemptId: attemptId
            )
            KeychainStore.clearStagedPairing(hostID: record.id, attemptId: attemptId)
        }
        let identityState = attemptState.current
        var directVerified = false
        var directError = identityState.error
        var pairingCommitFailed = false
        if case .succeeded = result,
           let adaptorHostId = identityState.hostId,
           let onBootstrapPairingCommit {
            let committed = await onBootstrapPairingCommit(
                BootstrapPairingCommit(
                    hostID: record.id,
                    adaptorHostId: adaptorHostId,
                    port: port,
                    version: release.version,
                    attemptId: attemptId,
                    releaseSource: resolution.source
                )
            )
            if !committed {
                pairingCommitFailed = true
                directError = "配对记录与 hostId 未能写入本机，已阻止 direct 首验"
            }
        }
        let canonicalEndpoint = directEndpoint.flatMap { HostValidator.canonicalDirectEndpoint($0) }
        if directEndpoint != nil && canonicalEndpoint == nil {
            directError = "direct endpoint 不合法"
        }
        var didRejectDirect = false
        let wantsDirect = !pairingCommitFailed && canonicalEndpoint != nil
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
        let shouldAttemptDirect = wantsDirect && directAuthorized && identityState.trust != nil
        if case .succeeded = result, shouldAttemptDirect, let canonicalEndpoint {
            let verification = await attemptBootstrapDirect(
                record: record,
                endpoint: canonicalEndpoint,
                trust: identityState.trust,
                expectedHostId: identityState.hostId
            )
            directVerified = verification.verified
            directError = verification.error
        }
        if !shouldAttemptDirect || directVerified {
            _ = try? await transport.exec(
                BootstrapRemoteCommand.clearDirectTrust(attemptId: attemptId),
                stdin: nil,
                timeout: 15
            )
        }
        var installSucceeded = false
        if case .succeeded = result { installSucceeded = true }
        let requiresConfirmation = wantsDirect && installSucceeded && !didRejectDirect && directError != nil
        if requiresConfirmation {
            pendingBootstrapTransports[record.id] = (attemptId, transport, identityState.trust)
            preserveBootstrapTransport = true
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

    private func attemptBootstrapDirect(
        record: HostRecord,
        endpoint: String,
        trust: BootstrapDirectTrust?,
        expectedHostId: String?
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
#if DEBUG
        if let bootstrapDirectValidationHandlerForTesting {
            let result = await bootstrapDirectValidationHandlerForTesting()
            if result.verified {
                guard KeychainStore.saveDirectTLSTrustPin(pin, hostID: record.id) else {
                    return (false, "direct pin 未能写入 Keychain")
                }
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
                    guard KeychainStore.saveDirectTLSTrustPin(pin, hostID: record.id) else {
                        await client.stop()
                        return (false, "direct pin 未能写入 Keychain")
                    }
                    await client.stop()
                    return (true, nil)
                }
                if case .state(.offline(let reason)) = update {
                    throw RACPClientError.protocolMismatch(reason ?? "direct 首验失败")
                }
            }
            throw RACPClientError.notConnected
        } catch {
            await client.stop()
            return (false, error.localizedDescription)
        }
    }

    /// Best-effort cleanup for a failed install. The active PI-adaptor token is never
    /// touched; only the attempt-scoped token is used and then deleted locally.
    private func revokeStagedPairingBestEffort(
        record: HostRecord,
        port: Int,
        attemptId: String
    ) async {
        guard let staged = KeychainStore.loadStagedPairing(
            hostID: record.id,
            attemptId: attemptId
        ) else { return }
        await revokePairingBestEffort(
            record: record,
            port: port,
            deviceId: staged.deviceId,
            deviceToken: staged.deviceToken
        )
    }

    /// Recover attempt credentials abandoned by a crash, force close, or prior
    /// app launch. Promotion may have committed the primary token while staging
    /// deletion failed, so recovery compares both exact values first. Matching
    /// records are cleared without revoking the live token; a different staged
    /// token gets bounded revocation. The primary record is never modified.
    func recoverStagedPairings(record: HostRecord) async {
        let active = KeychainStore.loadActivePairing(hostID: record.id)
        _ = await BootstrapStagingRecoveryCoordinator.recover(
            staging: KeychainStore.loadAllStagedPairings(hostID: record.id),
            activeDeviceId: active?.deviceId,
            activeDeviceToken: active?.deviceToken,
            revoke: { [self] attempt in
                await revokePairingBestEffort(
                    record: record,
                    port: attempt.targetPort,
                    deviceId: attempt.deviceId,
                    deviceToken: attempt.deviceToken
                )
            },
            clear: { attempt in
                KeychainStore.clearStagedPairing(attempt)
            }
        )
    }

    private func revokePairingBestEffort(
        record: HostRecord,
        port: Int,
        deviceId: String,
        deviceToken: String
    ) async {
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else { return }
        let pinned = KeychainStore.loadHostKey(account: account)
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
                hostPort: port,
                deviceToken: deviceToken
            ),
            confirmer: promptBroker
        )
        // The operation may not cooperate with cancellation. The deadline wins
        // independently, then stopBestEffort separately bounds client shutdown.
        _ = await boundedAsyncValue(seconds: 8) {
            let stream = await client.start()
            for await update in stream {
                switch update {
                case .ready:
                    return (try? await client.revokeDevice(deviceId: deviceId)) ?? false
                case .error:
                    return false
                default:
                    continue
                }
            }
            return false
        }
        _ = await client.stopBestEffort(timeout: 1)
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

    private func parseBootstrapProbe(
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

    // MARK: - 模型服务

    /// Ad-hoc discovery uses only the active host-bound RACP client. The temporary
    /// API key is confined to that request payload and never enters SSH argv/logs.
    func discoverModels(
        record: HostRecord,
        baseURL: String,
        apiKey: String
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
        return try await RemoteProviderOperations.discoverModels(
            client: client,
            requestURL: baseURL,
            apiKey: apiKey,
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
        if info?.serverName == PIAdaptorRelease.runtimeServerName {
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
        guard info?.serverName == "pi-host" else {
            throw RACPV2Error.notConnected
        }
        return try await legacyRemoveProvider(
            record: record,
            providerId: providerId
        )
    }

    private func legacyRemoveProvider(
        record: HostRecord,
        providerId: String
    ) async throws -> ProviderRemoveReceipt {
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(ProviderRemovePayload(providerId: providerId))
            let receipt = try await LegacyRemoteProviderOperations.removeProvider(
                transport: transport,
                payload: payload,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return receipt
        } catch {
            await transport.close()
            throw error
        }
    }

    func providerBindingStatus(
        record: HostRecord,
        sessionId: String
    ) async throws -> ProviderBindingReceipt {
        if usesUITestFixture {
            guard let status = fixtureProviderBindingStatuses[sessionId] else {
                return .unparseable(reason: "UI fixture 未提供该会话的 provider 绑定")
            }
            return .success(status)
        }
        if info?.serverName == PIAdaptorRelease.runtimeServerName {
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
        guard info?.serverName == "pi-host" else {
            throw RACPV2Error.notConnected
        }
        return try await legacyProviderBindingStatus(
            record: record,
            sessionId: sessionId
        )
    }

    private func legacyProviderBindingStatus(
        record: HostRecord,
        sessionId: String
    ) async throws -> ProviderBindingReceipt {
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let receipt = try await LegacyRemoteProviderOperations.bindingStatus(
                transport: transport,
                sessionId: sessionId,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return receipt
        } catch {
            await transport.close()
            throw error
        }
    }

    // MARK: - PI-adaptor v2 additive features

    private struct AdaptorV2SkillList: Decodable {
        var skills: [RACPV2Skill]
    }

    private struct AdaptorV2SkillEnvelope: Decodable {
        var skill: RACPV2Skill
    }

    private struct AdaptorV2DeleteEnvelope: Decodable {
        var deleted: Bool
    }

    private struct AdaptorV2ProviderList: Decodable {
        var providers: [RACPV2Provider]
    }

    private struct AdaptorV2ProviderEnvelope: Decodable {
        var provider: RACPV2Provider
    }

    /// v2 equivalent of the legacy SSL `provider-binding-status` probe: read the
    /// session's pinned provider/model, then verify it against the PI-adaptor store.
    func adaptorV2BindingStatus(sessionId: String) async throws -> ProviderBindingStatus {
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
        let result: AdaptorV2SkillList = try await client.v2Request(
            method: RACPV2Method.skillList.rawValue,
            params: .object([:])
        )
        return result.skills
    }

    func installAdaptorSkill(source: JSONValue, replace: Bool = false) async throws -> RACPV2Skill {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: AdaptorV2SkillEnvelope = try await client.v2Request(
            method: RACPV2Method.skillInstall.rawValue,
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
        let _: AdaptorV2DeleteEnvelope = try await client.v2Request(
            method: RACPV2Method.skillDelete.rawValue,
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

    func listAdaptorProviders() async throws -> [RACPV2Provider] {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: AdaptorV2ProviderList = try await client.v2Request(
            method: RACPV2Method.providerList.rawValue,
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
        let result: AdaptorV2ProviderEnvelope = try await client.v2Request(
            method: RACPV2Method.providerCreate.rawValue,
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
        let result: AdaptorV2ProviderEnvelope = try await client.v2Request(
            method: RACPV2Method.providerCreate.rawValue,
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
        return result.provider
    }

    /// 完整替换已配置 Provider 的模型列表；密钥缺省时由 PI-adaptor 保留原密钥。
    func updateAdaptorProvider(
        id: String,
        input: ProviderUpdateInput
    ) async throws -> RACPV2Provider {
        if usesUITestFixture {
            guard let existing = fixtureUpdatableProviders.first(where: { $0.id == id }) else {
                throw RACPV2Error.server(code: "NOT_FOUND", message: "模型服务不存在")
            }
            let composition = ProviderUpdateComposer.compose(existing: existing, input: input)
            guard composition.isValid else {
                throw ProviderImportValidationFailure(issues: composition.issues)
            }
            let updated = RACPV2Provider.fixtureForUpdate(
                existing: existing, input: composition.input
            )
            fixtureUpdatableProviders = fixtureUpdatableProviders.map {
                $0.id == id ? updated : $0
            }
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
        let result: AdaptorV2ProviderEnvelope
        do {
            result = try await client.v2Request(
                method: RACPV2Method.providerUpdate.rawValue,
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
            let _: AdaptorV2DeleteEnvelope = try await client.v2Request(
                method: RACPV2Method.providerDelete.rawValue,
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

    private static func v2Error(from error: RACPClientError) -> RACPV2Error {
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
        if usesUITestFixture {
            guard let fixtureAdaptorUnitSnapshot else {
                throw AdaptorUnitParseError.missingField("fixture AdaptorUnitSnapshot")
            }
            return fixtureAdaptorUnitSnapshot
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

    private func makeHostKeyBroker(
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
    private func resolveHostPort(
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
            let result = try await transport.exec(HostPortResolver.probeCommand, timeout: 15)
            await transport.close()
            if let port = HostPortResolver.resolve(stdout: result.stdoutText) {
                onResolvedHostPort?(record.id, port)
                return port
            }
        } catch {
            return nil
        }
        return nil
    }

    private func releaseHostKeyBroker(_ operationID: UUID) {
        brokers.removeValue(forKey: operationID)
        if connectionBrokerID == operationID {
            connectionBrokerID = nil
        }
        if hostKeyPrompt?.operationID == operationID {
            hostKeyPrompt = nil
        }
    }

    private func connectSSH(
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

    private func remainingProviderBudget(_ deadline: Date) -> TimeInterval {
        max(0.1, deadline.timeIntervalSinceNow)
    }

    private func applyFixtureCatalog(_ catalog: UITestFixture.Catalog?) {
        guard let catalog else { return }
        projects = catalog.projects
        sessions = catalog.sessions
        info = catalog.info
        hasLoadedCatalog = true
        catalogError = nil
        state = fixtureConnectionState ?? .online
    }

    // MARK: - RACP 隧道

    /// 建立隧道并拉取 `project/list` / `session/list`。
    ///
    /// 前提是 Keychain 里已有凭证与设备令牌；缺任何一项都直接给出原因，不假装在线。
    func connect(record: HostRecord) async {
        connectionIntentGeneration &+= 1
        let intent = connectionIntentGeneration
        await disconnectCurrent(expectedIntent: intent)
        guard intent == connectionIntentGeneration,
              cacheHostID == record.id
        else { return }
        if usesUITestFixture {
            applyFixtureCatalog(fixtureCatalogs[record.id])
            return
        }
        guard record.pairedAt != nil else {
            state = .offline(reason: "本机记录尚未配对：请先完成 PI-adaptor 配对")
            return
        }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let token = KeychainStore.loadDeviceToken(hostID: record.id) else {
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
            state = .offline(reason: "本机没有保存这台服务器的凭证：请先在服务器页「保存并测试连接」")
            return
        }
        let pinned = KeychainStore.loadHostKey(account: account)
        var hostPort = record.hostPort
        if preference == .sshOnly {
            guard let credential else {
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
                state = .offline(reason: "无法确定 PI-adaptor 端口：SSH 探测失败且未记录端口")
                return
            }
        }
        guard intent == connectionIntentGeneration, cacheHostID == record.id else { return }
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
        let newClient = RACPClient(configuration: configuration, confirmer: promptBroker)
        client = newClient
        connectionGeneration &+= 1
        cacheClientID = UUID()
        let generation = connectionGeneration
        invalidateCatalogLoads()
        session.bind(client: newClient, online: false)
        let stream = await newClient.start()
        guard self.client === newClient, connectionGeneration == generation else {
            releaseHostKeyBroker(operationID)
            await newClient.stop()
            return
        }
        updateTask = Task { [weak self] in
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
    }

    /// Starts a direct candidate while the old SSH client remains active and readable.
    /// Only a successful final C1 replay can atomically replace the active generation.
    func retryDirect(record: HostRecord) async {
        guard client != nil, state.isOnline, connectionStatus.activeRoute == .ssh,
              candidateClient == nil, cacheHostID == record.id,
              let token = KeychainStore.loadDeviceToken(hostID: record.id), token.hasPrefix("pdt2."),
              let endpointText = record.directEndpoint,
              let endpoint = URL(string: endpointText),
              let adaptorHostId = record.adaptorHostId,
              let pin = KeychainStore.loadDirectTLSTrustPin(hostID: record.id),
              pin.hostId == adaptorHostId
        else {
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
            await candidate.stop()
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

    private func runDirectCandidate(
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
            await candidate.stop()
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
            await oldClient.stop()
            guard !Task.isCancelled,
                  client === candidate,
                  connectionGeneration == generation,
                  connectionIntentGeneration == intent
            else { throw ConnectionLifecycleError.connectionChanged }
            onDirectVerified?(record.id, endpoint, adaptorHostId)
            updateTask = Task { [weak self] in
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
                await oldClient.stop()
            }
            await candidate.stop()
            if candidateClient === candidate {
                candidateClient = nil
                candidateTask = nil
            }
            releaseHostKeyBroker(brokerID)
        }
    }

    func disconnect() async {
        connectionIntentGeneration &+= 1
        await disconnectCurrent(expectedIntent: connectionIntentGeneration)
    }

    /// Only close the connection if the PI-adaptor that requested teardown is still active.
    /// A stale PI-adaptor action must never disconnect the connection installed by a newer switch.
    func disconnect(ifHostID expectedHostID: UUID) async {
        guard cacheHostID == expectedHostID else { return }
        connectionIntentGeneration &+= 1
        await disconnectCurrent(
            expectedIntent: connectionIntentGeneration,
            expectedHostID: expectedHostID
        )
    }

    private func disconnectCurrent(
        expectedIntent: Int,
        expectedHostID: UUID? = nil
    ) async {
        let generation = connectionGeneration
        guard expectedIntent == connectionIntentGeneration,
              connectionGeneration == generation,
              expectedHostID == nil || cacheHostID == expectedHostID
        else { return }

        // Invalidate synchronously before any await: a delayed cache flush can never
        // leave a candidate promoted into an already disconnected UI generation.
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
        session.bind(client: nil, online: false)
        connectedAccount = nil
        connectionStatus = ConnectionStatus()
        state = .offline(reason: nil)
        let candidateStop = Task { await oldCandidate?.stop() }
        let activeStop = Task { await oldClient?.stop() }

#if DEBUG
        if disconnectFlushDelayForTesting > 0 {
            try? await Task.sleep(for: .milliseconds(Int(disconnectFlushDelayForTesting * 1000)))
        }
#endif
        await flushPendingCacheWrites()
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

    func waitUntilOnline(timeout: TimeInterval = 30) async -> Bool {
        if usesUITestFixture { return state.isOnline }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            if state.isOnline { return true }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return state.isOnline
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
            lastError = ConnectionErrorText.describe(error)
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

    private func invalidateCatalogLoads() {
        catalogGeneration &+= 1
        isRefreshingCatalog = false
    }

    /// `session/create`：在项目中新建会话（AC-08.2）。
    func createSession(title: String?, projectId: String?) async throws -> RACPSessionSummary {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let created = try await client.createSession(
            title: title,
            projectId: projectId,
            permissionMode: nil
        )
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        return created
    }

    func respondHostKey(_ confirmation: HostKeyConfirmation, operationID: UUID) {
        guard let prompt = hostKeyPrompt,
              prompt.operationID == operationID,
              let broker = brokers[prompt.operationID]
        else { return }
        if confirmation == .trust, prompt.status == .firstUse {
            // 首次固定：写 Keychain 并记一条本地审计事件（AC-02.3 的固定动作）。
            _ = KeychainStore.saveHostKey(prompt.key, account: prompt.account)
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

    private func apply(
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
            if sanitizedState.isOnline {
                await refreshRemote()
                await session.refreshView()
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
            await session.refreshView()
            scheduleCacheSessionState()
        case .event:
            break
        case .error(let code, _):
            lastError = ConnectionFailureClassifier.userMessage(forRACPCode: code)
        }
    }

    private static func sanitizedForDisplay(_ state: RACPTunnelState) -> RACPTunnelState {
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
    private func scheduleHostCatalogRefresh(client: RACPClient, generation: Int) {
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

    private func cancelHostCatalogRefresh() {
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
        // 夹具没有真实 RACP client；SET-04 覆盖的是「服务器确认后清理本机配对」的 UI 路径，
        // 由夹具显式声明撤销成功（真实路径仍要求服务器回执 revoked == true）。
        if usesUITestFixture, fixtureSupportsRevoke {
            return Self.deviceRevokedMessage
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
            let revoked = if info?.serverName == "pi-host" {
                try await activeClient.revokeLegacyDevice(deviceId: deviceId)
            } else {
                try await activeClient.revokeDevice(deviceId: deviceId)
            }
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
    private static func isUnconfirmedRevokeError(_ error: Error) -> Bool {
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
    private var isTransientDisconnect: Bool {
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
        cacheStore.loadSnapshot().cachedSession(hostID: cacheHostID, sessionID: sessionId)
    }

    /// 缓存里出现过的会话 id（新→旧），离线时可以据此进入只读历史。
    func cachedSessionIds() -> [String] {
        cacheStore.loadSnapshot().sessionIDs(hostID: cacheHostID)
    }

    /// Drop cached sessions the authoritative catalog no longer lists for the
    /// active host. Only call with a freshly fetched, complete list — a partial
    /// or filtered list would purge sessions that still exist.
    private func reconcileOfflineCache(with remoteSessions: [RACPSessionSummary]) {
        guard let hostID = cacheHostID else { return }
        let authoritative = Set(remoteSessions.map(\.id))
        let stale = cacheStore.loadSnapshot()
            .sessionIDs(hostID: hostID)
            .filter { !authoritative.contains($0) }
        removeCachedSessions(stale)
    }

    func removeCachedSessions(_ sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        let removed = Set(sessionIDs)
        guard let hostID = cacheHostID else { return }
        var snapshot = cacheStore.loadSnapshot()
        for sessionID in removed {
            snapshot.removeSessionAndDraft(hostID: hostID, sessionID: sessionID)
        }
        cacheStore.save(snapshot)
    }

    func removeCachedHost(_ hostID: UUID) {
        cacheStore.removeHost(hostID)
    }

    /// 把权威会话快照写进离线缓存：items、cursor、pending approvals 一起替换；
    /// 草稿由输入框的 change sink 独立维护。异步读取前后都校验租约，旧连接结果不能落盘。
    private func cacheSessionState() async {
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
        let view = await client.sessionView()
        guard self.client === client,
              connectionGeneration == generation,
              cacheClientID == clientID,
              isCurrentCacheWrite(lease),
              view.sessionId == sessionID
        else { return }

        let now = Date()
        let existingSnapshot = cacheStore.loadSnapshot()
        let existingSession = existingSnapshot.cachedSession(
            hostID: hostID,
            sessionID: sessionID
        )
        // 视图是权威快照（`hasMoreHistory == false` 表示它已包含完整历史）时，
        // 不能用「缓存旧条目 ∪ 新视图」合并：快照重建后已从权威状态消失的条目
        // 会被旧缓存重新带回来。只有在分页未取完（可能还有更老的历史）时才保留
        // 合并语义。
        let existingEntries = view.hasMoreHistory ? (existingSession?.entries ?? []) : []
        let existingDates = Dictionary(
            existingEntries.map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        var entriesWithOriginalDate: [(entry: SessionCacheStore.Entry, hasOriginalDate: Bool)] = []
        for item in view.items {
            let originalDate = Self.cacheCreatedAt(from: item)
            let entry = SessionCacheStore.Entry(
                id: item.id,
                sessionId: sessionID,
                hostID: hostID,
                text: item.text ?? "",
                createdAt: originalDate ?? existingDates[item.id] ?? now,
                kind: item.kind,
                role: item.role,
                toolName: item.toolName,
                status: item.status,
                epoch: view.cursor?.epoch,
                sequence: item.payload.value(at: ["sequence"])?.intValue
                    ?? view.cursor?.sequence
            )
            entriesWithOriginalDate.append((entry, originalDate != nil))
        }
        let entries = OfflineSessionCachePolicy.merged(
            existingEntries,
            with: entriesWithOriginalDate.map(\.entry)
        )
        let keysWithOriginalDates = Set(
            entriesWithOriginalDate
                .filter { $0.hasOriginalDate }
                .map {
                    OfflineSessionCachePolicy.itemKey(
                        hostID: hostID,
                        sessionID: sessionID,
                        itemID: $0.entry.id
                    )
                }
        )
        // 旧版本曾把“缓存写入时间”当消息时间；一旦服务端给出原始时间，必须用原时间替换它，
        // 不能被 merge 的“较新时间优先”规则挡住。
        let retained = entries.filter {
            let key = OfflineSessionCachePolicy.itemKey(
                hostID: $0.hostID,
                sessionID: $0.sessionId,
                itemID: $0.id
            )
            return !keysWithOriginalDates.contains(key)
        }
        let newEntries = OfflineSessionCachePolicy.merged(
            retained,
            with: entriesWithOriginalDate.map(\.entry)
        )

        var next = existingSnapshot
        if let draft = existingSession?.draft {
            next.removeSession(hostID: hostID, sessionID: sessionID)
            next.drafts.removeAll {
                $0.hostID == hostID && $0.sessionId == sessionID
            }
            next.drafts.append(draft)
        } else {
            next.removeSession(hostID: hostID, sessionID: sessionID)
        }
        next.entries.append(contentsOf: newEntries)
        if let summary = session.attachedSummary {
            next.sessions.append(
                SessionCacheStore.Session(
                    hostID: hostID,
                    id: sessionID,
                    title: summary.title,
                    projectID: summary.projectId,
                    mode: session.sessionMode.rawValue,
                    permissionMode: session.permissionMode.rawValue,
                    modelID: session.selectedModelId,
                    providerID: session.selectedProviderId,
                    epoch: view.cursor?.epoch,
                    sequence: view.cursor?.sequence,
                    updatedAt: now
                )
            )
        }
        if let cursor = view.cursor {
            next.cursors.append(
                SessionCacheStore.Cursor(
                    hostID: hostID,
                    sessionId: sessionID,
                    epoch: cursor.epoch,
                    sequence: cursor.sequence,
                    updatedAt: now
                )
            )
        }
        next.approvals.append(contentsOf: view.pendingApprovals.map { card in
            SessionCacheStore.Approval(
                id: card.id,
                sessionId: sessionID,
                hostID: hostID,
                payload: CacheFieldPolicy.redactedForCache(card.payload),
                revision: card.revision,
                status: card.status ?? "pending",
                decision: card.payload.value(at: ["decision"])?.stringValue,
                createdAt: Self.cacheCreatedAt(from: card.payload) ?? now
            )
        })

        guard isCurrentCacheWrite(lease) else { return }
        cacheStore.save(next)
    }

    /// Coalesce streaming/history and keystroke cache writes so disk I/O is not
    /// performed on every event or character.
    private func scheduleCacheSessionState() {
        sessionCacheWritePending = true
        guard sessionCacheWriteTask == nil else { return }
        sessionCacheWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
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

    private func scheduleDraftCache(
        sessionID: String,
        text: String,
        idempotencyKey: String?
    ) {
        guard let lease = currentCacheWriteLease(sessionID: sessionID),
              isCurrentDraftWrite(lease)
        else { return }
        pendingDraftWrite = PendingDraftWrite(
            lease: lease,
            sessionID: sessionID,
            text: text,
            idempotencyKey: idempotencyKey
        )
        guard draftWriteTask == nil else { return }
        draftWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.flushPendingDraftWrite()
            self.draftWriteTask = nil
        }
    }

    private func flushPendingDraftWrite() {
        guard let pending = pendingDraftWrite else { return }
        pendingDraftWrite = nil
        guard isCurrentDraftWrite(pending.lease) else { return }
        var snapshot = cacheStore.loadSnapshot()
        snapshot.drafts.removeAll {
            $0.hostID == pending.lease.hostID && $0.sessionId == pending.sessionID
        }
        if !pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let idempotencyKey = pending.idempotencyKey else { return }
            snapshot.drafts.append(
                SessionCacheStore.Draft(
                    hostID: pending.lease.hostID,
                    sessionId: pending.sessionID,
                    text: pending.text,
                    idempotencyKey: idempotencyKey,
                    updatedAt: Date()
                )
            )
        }
        cacheStore.save(snapshot)
    }

    /// Flush both coalesced caches before backgrounding, disconnecting, or switching sessions.
    func flushPendingCacheWrites() async {
        cacheFlushGeneration &+= 1
        let generation = cacheFlushGeneration
        let previous = cacheFlushTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCacheFlush()
        }
        cacheFlushTask = task
        await task.value
        if cacheFlushGeneration == generation {
            cacheFlushTask = nil
        }
    }

    private func performCacheFlush() async {
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
    }

    private func currentCacheWriteLease(
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

    private func isCurrentCacheWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrent(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID,
                sessionID: session.attachedSessionId
            )
    }

    private func isCurrentDraftWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrentHost(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID
            )
    }

    private static func cacheCreatedAt(from item: RACPItem) -> Date? {
        cacheCreatedAt(from: item.payload)
    }

    private static func cacheCreatedAt(from payload: JSONValue) -> Date? {
        for key in ["createdAt", "created_at"] {
            guard let value = payload.value(at: [key]) else { continue }
            switch value {
            case .number(let raw):
                return dateFromEpoch(raw)
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let epoch = Double(trimmed), let date = dateFromEpoch(epoch) {
                    return date
                }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: trimmed) { return date }
                return ISO8601DateFormatter().date(from: trimmed)
            default:
                continue
            }
        }
        return nil
    }

    private static func dateFromEpoch(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        // 同时接受秒与毫秒时间戳；1e11 秒在现实中不会出现。
        let seconds = raw >= 100_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - 指纹核对的挂起点

/// 把手握期间的主机指纹判定转成「等界面回答」的 async 调用（AC-02.1）。
///
/// `matches` 不打扰用户；`firstUse` / `changed` 都要界面参与，`changed` 只允许拒绝（AC-02.2）。
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
            return "认证失败（401）："
                + ConnectionDiagnosticRedactor.redact(error.description)
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
        }
        return kind.userMessage
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
            return "服务器未连接（PI-adaptor 隧道未建立）：请到设置页恢复连接后重试。"
        case .protocolViolation(let reason):
            return "服务器协议异常：" + ConnectionDiagnosticRedactor.redact(reason)
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

private extension RACPV2Provider {
    static func fixtureForUpdate(
        existing: RACPV2Provider,
        input: ProviderUpdateInput
    ) -> RACPV2Provider {
        var provider = existing
        provider.name = input.name
        provider.baseUrl = input.baseURL
        provider.models = input.models.map { spec in
            let data = try! JSONEncoder().encode(ProviderUpdateComposer.modelJSON(spec))
            var model = try! JSONDecoder().decode(RACPV2ProviderModel.self, from: data)
            model.id = spec.id
            model.displayName = spec.alias ?? spec.id
            return model
        }
        provider.updatedAt = "fixture-updated"
        return provider
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
