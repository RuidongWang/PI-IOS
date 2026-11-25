import Foundation
import UIKit
import Combine
import PIiOSCore
import PIiOSNet


@MainActor
final class ConnectionModel: ObservableObject {
    static let deviceRevokedMessage = "服务器已撤销该设备的访问权限"
    /// 请求已发出但连接在回执前中断：服务器可能已经撤销，不能当成「未撤销」或「离线」。
    static let deviceRevokeUnconfirmedMessage =
        "撤销结果未确认：连接在服务器确认前中断，本机凭证尚未改动。请重新连接后确认设备状态，再决定是否重试。"

    nonisolated static let defaultAdaptorInstallReleaseVersion = PIAdaptorRelease.patchedReleaseVersion
    nonisolated static let defaultAdaptorInstallReleaseBaseURL = PIAdaptorRelease.defaultPatchedBaseURL

    @Published var state: RACPTunnelState = .offline(reason: nil) {
        didSet {
            syncExtensionContext()
            notifyOnlineWaitersIfNeeded()
        }
    }
    var onlineWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @Published var connectionStatus = ConnectionStatus()
    @Published var projects: [RACPProjectSummary] = []
    @Published var sessions: [RACPSessionSummary] = []
    @Published var info: RACPServerInfo? {
        didSet {
            extensionInfoHostID = cacheHostID
            syncExtensionContext()
        }
    }
    var extensionInfoHostID: UUID?
    @Published var lastError: String?
    /// Invoked when the loopback PI-adaptor port is discovered over SSH so the owner
    /// (AppModel) can persist it onto the host record.
    var onResolvedHostPort: ((UUID, Int) -> Void)?
    var onDirectVerified: ((UUID, String, String) -> Void)?
    var onBootstrapPairingCommit: ((BootstrapPairingCommit) -> BootstrapPairingCommitResult)?
    var onPrepareHostConnection: ((UUID) -> HostRecord?)?
    var activeAdaptorInstalls: Set<UUID> = []
    var activePiCLIAccounts: Set<String> = []
    @Published var hasLoadedCatalog = false
    @Published var isRefreshingCatalog = false
    @Published var catalogError: String?
    /// 「保存并测试连接」的结果文案；nil 表示没有测过。
    @Published var testResult: String?
    @Published var isTesting = false
    @Published var hostKeyPrompt: HostKeyPrompt?

    var client: RACPClient? { didSet { updateCacheContext() } }
    @Published var offlineCacheReady = false
    @Published var offlineCacheLoadError: String?
    var cacheSessionObservation: AnyCancellable?
    var cacheStatusRevision: UInt64 = 0
    var activeClient: RACPClient? { client }
    /// 会话归档/恢复/删除的全局互斥：视图关闭不会重置或允许重复提交。
    @Published var sessionActionInFlight = false

    func beginSessionAction() -> Bool {
        guard !sessionActionInFlight else { return false }
        sessionActionInFlight = true
        return true
    }

    func endSessionAction() {
        sessionActionInFlight = false
    }
    var updateTask: Task<Void, Never>?
    var statusTask: Task<Void, Never>?
    var candidateClient: RACPClient?
    var candidateTask: Task<Void, Never>?
    var hostCatalogRefreshTask: Task<Void, Never>?
    var hostCatalogRefreshToken: UUID?
    var hostCatalogRefreshPending = false
    var brokers: [UUID: HostKeyPromptBroker] = [:]
    var connectionBrokerID: UUID?
    var connectedAccount: String?
    var connectionGeneration = 0 { didSet { updateCacheContext() } }
    /// 连接代次只读快照。异步回调用它在完成时确认「发起时的连接仍是当前连接」，
    /// 生产代码不得修改代次；测试用访问器见 `#if DEBUG` 的 `connectionGenerationForTesting`。
    var currentConnectionGeneration: Int { connectionGeneration }
    var connectionIntentGeneration = 0
    var catalogGeneration = 0
    /// 仅用于日志连接耗时的起点：connect 开始计时、online/offline 或断开时清空。不参与业务分支。
    var connectLogStartedAt: Date?
    var cacheHostID: UUID? { didSet { updateCacheContext() } }
    var offlineCacheLimit = PersistedState.defaultOfflineCacheLimit
    var cacheStore: SessionCacheStore
    /// 每次真实 RACP client 建立时更新；缓存迟到写入据此拒绝旧连接结果。
    var cacheClientID = UUID() { didSet { updateCacheContext() } }
    struct PendingDraftWrite {
        let lease: OfflineSessionCacheWriteLease
        let sessionID: String
        let text: String
        let idempotencyKey: String?
    }
    var pendingDraftWrite: PendingDraftWrite?
    var draftWriteDebounce = CacheWriteDebounce()
    var draftWriteTask: Task<Void, Never>?
    var sessionCacheWriteTask: Task<Void, Never>?
    var sessionCacheWritePending = false
    var cacheFlushTask: Task<CacheFlushReport?, Never>?
    var cacheFlushGeneration = 0
#if DEBUG
    /// Test-only interleave point between the flush barrier and applying its
    /// result, used to publish a real newer revision from the real save path.
    var afterCacheFlushBarrierHookForTesting: (() async -> Void)?
    var beforeCacheFlushHookForTesting: (() -> Void)?
    var bootstrapRevocationHandlerForTesting: ((Int, String, String, String?) async -> BootstrapStagingRevokeResult)?
#endif
    var currentCatalogHostID: UUID? { cacheHostID }
    /// 当前选中的 HostRecord id（由 AppModel 的 setCacheHostID 保持同步）。
    /// Provider key lookup 用它定位本机 Keychain 中的 (host, provider) 密钥。
    var currentHostID: UUID? { cacheHostID }
    /// 会话内的读写（发送、审批、排队、配置）全部走它。
    let session: SessionController
#if DEBUG
    @Published var uiTestTerminalTurn: RACPTurnRef?
#endif
    let requestKeys: SessionRequestKeyStore
    let extensions = ExtensionCatalogModel()
    var extensionSnapshotGeneration: UInt64?
    var fixtureState = ConnectionFixtureState()
    /// 安装时解析最新稳定版；UI 测试夹具不访问网络。
    let releaseCatalog: any AdaptorReleaseResolving
    var installOutcomes: [UUID: AdaptorInstallRunOutcome] = [:]
    var pendingBootstrapTransports: [UUID: (
        attemptId: String,
        transport: SSHTransport?,
        trust: BootstrapDirectTrust?
    )] = [:]

    func installOutcome(hostID: UUID, attemptId: String) -> AdaptorInstallRunOutcome? {
        guard let outcome = installOutcomes[hostID], outcome.attemptId == attemptId else { return nil }
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

#endif

#if DEBUG
    var disconnectFlushDelayForTesting: TimeInterval = 0
    var candidatePostPromotionDelayForTesting: TimeInterval = 0
    var beforeOldStatusCheckForTesting: (() async -> Void)?
    var skipCandidateRestoreForTesting = false
    var connectionGenerationForTesting: Int { connectionGeneration }
    var candidateClientForTesting: RACPClient? { candidateClient }

#endif

    init(fixture: UITestFixture? = nil, releaseCatalog: (any AdaptorReleaseResolving)? = nil,
         cacheStoreOverride: SessionCacheStore? = nil) {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? PIAdaptorRelease.releaseVersion
        self.releaseCatalog = releaseCatalog
            ?? Self.fixtureReleaseCatalog(for: fixture)
            ?? AdaptorReleaseCatalog(clientVersion: appVersion, compatibilityDefaults: .standard)
        requestKeys = SessionRequestKeyStore(fileURL: fixture == nil ? SessionCacheStore.defaultRequestKeyURL() : nil)
        if let fixture {
            cacheStore = cacheStoreOverride ?? Self.makeFixtureCacheStore(fixture: fixture)
            session = SessionController(requestKeys: requestKeys)
            applyInitialUITestFixture(fixture)
        } else {
            cacheStore = cacheStoreOverride ?? SessionCacheStore(offlineCacheLimit: PersistedState.defaultOfflineCacheLimit)
            session = SessionController(requestKeys: requestKeys)
        }
        offlineCacheReady = cacheStore.status.ready
        offlineCacheLoadError = cacheStore.status.error
        cacheStore.observe { [weak self] status in
            Task { @MainActor [weak self] in
                self?.applyCacheStatus(status)
            }
        }
        cacheSessionObservation = session.$attachedSessionId.sink { [weak self] sessionID in
            guard let self else { return }
            self.cacheStore.updateContext(clientID: self.cacheClientID, generation: self.connectionGeneration,
                                          hostID: self.cacheHostID, sessionID: sessionID, active: self.client != nil)
            Task { @MainActor [weak self] in
                guard let self, self.session.attachedSessionId == sessionID, let sessionID else { return }
                await self.refreshSessionExtensions(sessionID)
            }
        }
        updateCacheContext()
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
        // Key 不落服务器：send 前按当前 host 从本机 Keychain 取一次，仅随
        // turn/start 透传；闭包不缓存 key、不写日志，读取失败返回 nil，由服务端
        // 以 PROVIDER_SECRET_MISSING 明确拒绝。
        session.providerCredential = { [weak self] providerId in
            guard let hostID = self?.currentHostID else { return nil }
            return KeychainStore.loadProviderKeyRecord(hostID: hostID, providerId: providerId)
        }
        configureSessionUITestFixture(fixture)
    }

    /// 设置里的「离线缓存上限」变化时同步给缓存层（AC-15.1）。
    func updateOfflineCacheLimit(_ limit: Int) {
        offlineCacheLimit = limit
        cacheStore = cacheStore.withOfflineCacheLimit(limit)
    }

    func setCacheHostID(_ hostID: UUID?) {
        cacheHostID = hostID
        applyFixtureHostSelection(hostID)
    }

    /// Provider API keys live only in the local Keychain, scoped by (host, provider).
    /// The session send path resolves the key through here; the value must never be
    /// logged, persisted to the state file, or sent anywhere except `turn/start`.
    func providerKeyForCurrentHost(_ providerId: String) -> String? {
        guard let hostID = cacheHostID else { return nil }
        return KeychainStore.loadProviderKey(hostID: hostID, providerId: providerId)
    }

    var cacheTurnLimit: Int { cacheStore.turnLimit }
    /// Compatibility alias; the configured unit is a complete turn.
    var cacheItemLimit: Int { cacheTurnLimit }

}
