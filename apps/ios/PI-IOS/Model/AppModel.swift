import Foundation
import Combine
import SwiftUI
import UIKit
import PIiOSCore
import PIiOSNet

/// 本机「默认模型」：哪条服务的哪个模型，以及它声明的默认思考档位。
///
/// host 级单选，来源是本机 provider 记录（见 `ProviderDefaultModelRecorder`）。
struct DefaultModelSelection: Equatable {
    let providerId: String
    let modelId: String
    let displayName: String
    let thinkingLevel: String?

    var label: String { displayName }
}

/// 应用状态：三个根页的导航状态、本机服务器记录、本机偏好、提示。
///
/// 本机记录 + 偏好 + 提示；隧道/RACP 的实时状态在 `connection`（`ConnectionModel`）里，
/// 界面只读它的真实值，不自行推断在线。
@MainActor
final class AppModel: ObservableObject {
    /// 三个一级入口（information-architecture.md §1「根」）。
    enum Root: String, CaseIterable, Identifiable {
        case projects
        case conversation
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: return "项目"
            case .conversation: return "会话"
            case .settings: return "设置"
            }
        }
    }

    @Published var hosts: [HostRecord] = []
    @Published var offlineCacheLimit: Int = PersistedState.defaultOfflineCacheLimit
    /// 运行日志配置（设置 → 日志）。读取自本机状态文件，改动立即生效并持久化。
    @Published var logConfiguration: PILogConfiguration = .default
    /// 运行日志内核。默认即全局单例；测试可注入临时目录，避免污染真实 App 容器。
    let logStore: PILogger
    @Published var modelProviders: [StoredModelProvider] = []
    @Published var projectBindings: [StoredProjectBinding] = []
    @Published var sessionBindings: [StoredSessionBinding] = []
    @Published var lastSessionByHost: [String: String] = [:]
    @Published var lastProjectByHost: [String: String] = [:]
    @Published var collapsedProjectGroups: [String] = []
    @Published var projectBrowserPaths: [String: String] = [:]
    var readingPositionsByHost: [String: [String: ConversationReadingPosition]] = [:]
    /// 本机状态文件读取异常时的说明；nil 表示正常。
    @Published var loadWarning: String?
    /// 最近一次写入本机文件失败的原因；nil 表示正常。
    @Published var saveError: String?
    @Published var pendingSettingsRoute: SettingsRoute?

    /// 隧道与 RACP 的实时状态（服务器页测试连接、设置页状态、项目页列表都读它）。
    let connection: ConnectionModel
    let usesUITestFixture: Bool
    var tunnelObservation: AnyCancellable?
    var remoteObservation: AnyCancellable?
    var connectionErrorObservation: AnyCancellable?
    var hostSwitchGeneration = 0
    var foregroundNotificationTransitionID: UUID?
    var deferredReadingPositionTask: Task<Void, Never>?
    var readingPositionsDirty = false
    var automaticStatePersistenceTask: Task<Void, Never>?
    var automaticStatePersistencePending = false
    var canPersistLoadedState = true
    let stateFileURL: URL?
    var persistenceGeneration: UInt64 = 0
    var pendingHostID: UUID?
    var providerConnectionGeneration = 0
    var providerIdentityGeneration = 0
    /// U15: monotonic per-host-record identity generation. Bumped whenever an
    /// install target's SSH identity or endpoint-port fields change, so an install
    /// that started before the edit can never commit its token to the new record.
    var installIdentityGenerations: [UUID: Int] = [:]
#if DEBUG
    /// Test-only persistence override; never set outside PI-IOSTests.
    var persistenceOverrideForTesting: (() -> Bool)?
    /// Test-only interleave point after the state-file barrier produced a result
    /// but before the flush applies it. Lets tests make a newer accepted write
    /// fail in that gap.
    var afterPersistBarrierHookForTesting: (() -> Void)?
#endif
    var foregroundResumeTracker = ForegroundResumeTracker()
    @Published var resumedSessionUpdates = ForegroundSessionUpdateMarkers()

    @Published var root: Root = .settings
    @Published var isSidebarOpen = false
    @Published var toast: PIToast?
    /// 上次打开的会话与项目（AC-18.6：切回 host / 重启后恢复上下文）。
    @Published var lastSessionId: String?
    @Published var lastProjectId: String?

    /// `seed` is a test-only injection of persisted state; the app always uses the
    /// default (load from the state file).
    init(
        seed: PersistedState? = nil,
        stateFileURL: URL? = nil,
        connectionOverride: ConnectionModel? = nil,
        logStore: PILogger = PILog.shared
    ) {
        self.stateFileURL = stateFileURL
        self.logStore = logStore
        let loadStartedAt = Date()
        let fixture = seed == nil ? UITestFixture.current : nil
        usesUITestFixture = fixture != nil
        connection = connectionOverride ?? ConnectionModel(fixture: fixture)
        let outcome: StateFile.LoadOutcome
        if let seed {
            outcome = StateFile.LoadOutcome(state: seed, warning: nil)
        } else if let fixture {
            outcome = StateFile.LoadOutcome(state: fixture.state, warning: nil)
        } else if let stateFileURL {
            outcome = StateFile.load(from: stateFileURL)
        } else {
            outcome = StateFile.load()
        }
        hosts = outcome.state.hosts
        offlineCacheLimit = outcome.state.offlineCacheLimit
        modelProviders = outcome.state.modelProviders
        lastSessionId = outcome.state.lastSessionId
        lastProjectId = outcome.state.lastProjectId
        projectBindings = outcome.state.projectBindings
        sessionBindings = outcome.state.sessionBindings
        lastSessionByHost = outcome.state.lastSessionByHost
        lastProjectByHost = outcome.state.lastProjectByHost
        collapsedProjectGroups = outcome.state.collapsedProjectGroups
        projectBrowserPaths = outcome.state.projectBrowserPaths
        if usesUITestFixture {
            readingPositionsByHost = outcome.state.readingPositionsByHost
        } else if let storedPositions = ReadingPositionStore.load(from: readingPositionsFileURL) {
            readingPositionsByHost = storedPositions
        } else {
            readingPositionsByHost = outcome.state.readingPositionsByHost
            if !readingPositionsByHost.isEmpty {
                ReadingPositionStore.save(readingPositionsByHost, to: readingPositionsFileURL)
            }
        }
        if let host = hosts.first(where: { $0.isCurrent }) ?? hosts.first {
            if lastProjectByHost[host.id.uuidString] == nil {
                lastProjectByHost[host.id.uuidString] = outcome.state.lastProjectId
            }
            if lastSessionByHost[host.id.uuidString] == nil {
                lastSessionByHost[host.id.uuidString] = outcome.state.lastSessionId
            }
        }
        loadWarning = outcome.warning
        canPersistLoadedState = outcome.canSave
        logConfiguration = outcome.state.logConfiguration
        applyLogConfiguration()
        installProviderAPIKeyResolver()
        if let warning = outcome.warning {
            logStore.log(level: .warn, category: "StateFile", message: warning)
        }
        if seed == nil, !usesUITestFixture {
            migrateLegacyDeviceTokens()
            recoverPromotedInstallReceipts()
        }
        root = LandingRule.initialRoot(hosts: hosts)
        connection.updateOfflineCacheLimit(offlineCacheLimit)
        connection.setCacheHostID(hosts.first(where: { $0.isCurrent })?.id ?? hosts.first?.id)
        connection.onResolvedHostPort = { [weak self] hostID, port in
            self?.applyDiscoveredHostPort(hostID: hostID, port: port)
        }
        connection.onDirectVerified = { [weak self] hostID, endpoint, adaptorHostId in
            _ = self?.markDirectVerified(
                id: hostID,
                endpoint: endpoint,
                adaptorHostId: adaptorHostId
            )
        }
        connection.onBootstrapPairingCommit = { [weak self] commit in
            guard let self else { return .staleTarget }
            return self.completeAdaptorInstallation(commit)
        }
        connection.onPrepareHostConnection = { [weak self] hostID in
            self?.prepareHostConnection(id: hostID)
        }
        observeTunnelState()
        observeRemoteMetadata()
        observeConnectionErrors()
        if !usesUITestFixture {
            let loadMilliseconds = Int((Date().timeIntervalSince(loadStartedAt) * 1000).rounded())
            logStore.log(
                level: .info,
                category: "App",
                message: "启动 \(Self.appVersionText) system=\(UIDevice.current.systemVersion) "
                    + "device=\(UIDevice.current.model) 状态读取 \(loadMilliseconds)ms hosts=\(hosts.count) "
                    + "日志=\(logConfiguration.isEnabled ? "on" : "off")/\(logConfiguration.level.label) binary=\(PIBuildIdentity.current)"
            )
        }
        if usesUITestFixture {
            // 夹具默认从会话页开始，便于会话类用例直接进入内容；
            // 空夹具（G-01）没有主机，仍按 LandingRule 落在设置页空态。
            if !hosts.isEmpty {
                root = .conversation
                isSidebarOpen = true
            }
            return
        }
        Task { [weak self] in
            await self?.connectCurrentHostIfPaired()
        }
    }

    /// Migrate endpoint-scoped device tokens from pre-UUID builds without ever
    /// letting a second PI-adaptor inherit the first PI-adaptor's token.
    func migrateLegacyDeviceTokens() {
        var changed = false
        let groups = Dictionary(grouping: hosts) { host in
            KeychainStore.account(username: host.username, host: host.host, port: host.port)
        }
        for (legacyAccount, group) in groups {
            let unscoped = group.filter { !KeychainStore.hasScopedDeviceToken(hostID: $0.id) }
            if group.count == 1,
               let host = group.first,
               host.pairedAt != nil,
               host.hostPort != nil {
                if KeychainStore.migrateLegacyDeviceToken(
                    hostID: host.id,
                    legacyAccount: legacyAccount
                ) {
                    KeychainStore.deleteLegacyDeviceToken(account: legacyAccount)
                    continue
                }
            }

            // A legacy token cannot prove which pi-host port issued it. Fail
            // closed and require each ambiguous PI-adaptor to pair again.
            for host in unscoped {
                guard let index = hosts.firstIndex(where: { $0.id == host.id }),
                      hosts[index].pairedAt != nil
                else { continue }
                hosts[index].pairedAt = nil
                hosts[index].tunnelUpAt = nil
                changed = true
            }
            // The ambiguous legacy value must not survive until deleting a PI-adaptor
            // later makes the group look attributable again.
            KeychainStore.deleteLegacyDeviceToken(account: legacyAccount)
        }
        if changed {
            persist()
            if loadWarning == nil {
                loadWarning = "旧版本的部分设备令牌无法唯一归属到 PI-adaptor，已要求重新配对。"
            }
        }
    }

    /// 记住当前项目（切换 host 后用于恢复）。
    func rememberProject(_ projectId: String?) {
        lastProjectId = projectId
        guard let hostID = currentHost?.id else {
            persist()
            return
        }
        if let projectId {
            lastProjectByHost[hostID.uuidString] = projectId
        } else {
            lastProjectByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    /// 记住当前会话（切换 host 后用于恢复）。
    func rememberSession(_ sessionId: String?) {
        lastSessionId = sessionId
        guard let hostID = currentHost?.id else {
            persist()
            return
        }
        if let sessionId {
            foregroundResumeTracker.open(hostID: hostID, sessionID: sessionId)
            resumedSessionUpdates.open(hostID: hostID, sessionID: sessionId)
            lastSessionByHost[hostID.uuidString] = sessionId
            if let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == sessionId
            }) {
                sessionBindings[index].lastOpenedAt = Date()
                sessionBindings[index].isUnread = false
                sessionBindings[index].updatedAt = Date()
            }
        } else {
            lastSessionByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    /// 离线缓存行被显式点选时，把它记在该 PI-adaptor 名下。
    ///
    /// 不能靠“缓存列表第一条”猜会话；同一进程切换 PI-adaptor 或重启后都要按 PI-adaptor 恢复用户的选择。
    func selectCachedSession(hostID: UUID, sessionID: String) {
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        foregroundResumeTracker.open(hostID: hostID, sessionID: sessionID)
        resumedSessionUpdates.open(hostID: hostID, sessionID: sessionID)
        if let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) {
            sessionBindings[index].isUnread = false
        }
        lastSessionId = sessionID
        lastSessionByHost[hostID.uuidString] = sessionID
        persist()
    }

    func cachedSessionSelectionID(for hostID: UUID) -> String? {
        lastSessionByHost[hostID.uuidString]
    }

    func captureBackgroundBaseline() {
        let snapshot = foregroundSnapshot()
        foregroundResumeTracker.capture(snapshot)
        guard let snapshot else {
            foregroundNotificationTransitionID = nil
            return
        }
        let transitionID = UUID()
        foregroundNotificationTransitionID = transitionID
        LocalNotificationCoordinator.shared.beginForegroundTransition(
            id: transitionID,
            baseline: notificationBaseline(from: snapshot)
        )
    }

    var hasPendingForegroundResume: Bool { foregroundResumeTracker.hasPendingResume }

    func resumeFromBackground() async {
        guard !Task.isCancelled, let ticket = foregroundResumeTracker.beginResume() else { return }
        defer { foregroundResumeTracker.retry(ticket) }
        let deadline = Date().addingTimeInterval(30)
        let hostID = ticket.baseline.hostID
        guard let host = currentHost, host.id == hostID else {
            foregroundResumeTracker.capture(nil)
            return
        }
        guard host.pairedAt != nil else {
            foregroundResumeTracker.capture(nil)
            foregroundNotificationTransitionID = nil
            return
        }
        let onlineAndAlive: Bool
        if connection.state.isOnline {
            onlineAndAlive = await connection.verifyConnectionLiveness()
        } else {
            onlineAndAlive = false
        }
        if !onlineAndAlive {
            // 离线，或界面仍显示在线但挂起期间 socket 已被回收/网络已切换：
            // 主动重建连接，不能继续等 10s 心跳 + 5s 超时 ×2 才暴露断开。
            let generation = hostSwitchGeneration &+ 1
            await setCurrentHost(id: hostID, waitForOnline: false)
            guard hostSwitchGeneration == generation else { return }
        }
        let generation = hostSwitchGeneration
        let onlineBudget = max(0.1, deadline.timeIntervalSinceNow)
        guard !Task.isCancelled,
              await connection.waitUntilOnline(timeout: onlineBudget),
              hostSwitchGeneration == generation, currentHost?.id == hostID,
              await connection.refreshRemote(
                  timeout: max(0.1, deadline.timeIntervalSinceNow)
              ),
              !Task.isCancelled, hostSwitchGeneration == generation, currentHost?.id == hostID
        else { return }
        // Merge synchronously: the Combine observer schedules its merge on a later turn.
        mergeRemoteMetadata(
            hostID: hostID,
            projects: connection.projects,
            sessions: connection.sessions
        )
        if let sessionID = connection.session.attachedSessionId ?? lastSessionByHost[hostID.uuidString] {
            if connection.session.isAttachedCurrent(to: sessionID) {
                await connection.session.refreshView(source: "foreground")
            } else {
                await connection.session.attach(sessionId: sessionID, source: "foreground")
            }
        }

        guard !Task.isCancelled,
              hostSwitchGeneration == generation, currentHost?.id == hostID,
              let snapshot = foregroundSnapshot()
        else { return }
        let updates = foregroundResumeTracker.complete(ticket, current: snapshot)
        resumedSessionUpdates.record(updates)
        if let transitionID = foregroundNotificationTransitionID {
            foregroundNotificationTransitionID = nil
            await LocalNotificationCoordinator.shared.completeForegroundTransition(
                id: transitionID,
                current: notificationSnapshot(from: snapshot)
            )
        } else if !updates.isEmpty {
            await LocalNotificationCoordinator.shared.notifyUpdates(count: updates.count)
        }
    }

    func notificationBaseline(
        from snapshot: ForegroundResumeSnapshot
    ) -> BackgroundNotificationBaseline {
        BackgroundNotificationBaseline(
            hostID: snapshot.hostID,
            sessionRevisions: snapshot.sessions.compactMapValues(\.revision),
            pendingApprovalIDs: Set(
                snapshot.sessions.values.compactMap(\.pendingApprovalIDs).flatMap { $0 }
            )
        )
    }

    func notificationSnapshot(
        from snapshot: ForegroundResumeSnapshot
    ) -> BackgroundNotificationSnapshot {
        BackgroundNotificationSnapshot(
            hostID: snapshot.hostID,
            sessionRevisions: snapshot.sessions.compactMapValues(\.revision),
            pendingApprovalIDs: Set(
                snapshot.sessions.values.compactMap(\.pendingApprovalIDs).flatMap { $0 }
            )
        )
    }

    func foregroundSnapshot() -> ForegroundResumeSnapshot? {
        guard let hostID = currentHost?.id else { return nil }
        var sessions: [String: ForegroundSessionState] = [:]
        if !connection.hasLoadedCatalog {
            for binding in sessionBindings where binding.hostID == hostID && !binding.isDeleted {
                sessions[binding.sessionID] = ForegroundSessionState(revision: binding.lastKnownRevision)
            }
        }
        for session in connection.sessions where sessionBinding(hostID: hostID, sessionID: session.id)?.isDeleted != true {
            sessions[session.id] = ForegroundSessionState(revision: session.revision, status: session.status)
        }
        let view = connection.session.view
        if let sessionID = connection.session.attachedSessionId, view.sessionId == sessionID,
           sessionBinding(hostID: hostID, sessionID: sessionID)?.isDeleted != true {
            var state = sessions[sessionID] ?? ForegroundSessionState(revision: view.revision)
            state.revision = max(state.revision ?? view.revision, view.revision)
            state.pendingApprovalIDs = Set(view.pendingApprovals.map(\.id))
            sessions[sessionID] = state
        }
        return ForegroundResumeSnapshot(hostID: hostID, sessions: sessions)
    }

    func hasSessionUpdate(hostID: UUID, sessionID: String) -> Bool {
        resumedSessionUpdates.contains(HostSessionReference(hostID: hostID, sessionID: sessionID))
            || sessionBinding(hostID: hostID, sessionID: sessionID)?.isUnread == true
    }

    func lastProjectID(for hostID: UUID) -> String? {
        lastProjectByHost[hostID.uuidString]
    }

    func lastSessionID(for hostID: UUID) -> String? {
        lastSessionByHost[hostID.uuidString]
    }

}
