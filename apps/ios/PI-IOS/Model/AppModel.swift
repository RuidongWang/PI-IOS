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

    @Published private(set) var hosts: [HostRecord] = []
    @Published private(set) var offlineCacheLimit: Int = PersistedState.defaultOfflineCacheLimit
    /// 运行日志配置（设置 → 日志）。读取自本机状态文件，改动立即生效并持久化。
    @Published private(set) var logConfiguration: PILogConfiguration = .default
    /// 运行日志内核。默认即全局单例；测试可注入临时目录，避免污染真实 App 容器。
    let logStore: PILogger
    @Published private(set) var modelProviders: [StoredModelProvider] = []
    @Published private(set) var projectBindings: [StoredProjectBinding] = []
    @Published private(set) var sessionBindings: [StoredSessionBinding] = []
    @Published private(set) var lastSessionByHost: [String: String] = [:]
    @Published private(set) var lastProjectByHost: [String: String] = [:]
    @Published private(set) var collapsedProjectGroups: [String] = []
    @Published private(set) var projectBrowserPaths: [String: String] = [:]
    private var readingPositionsByHost: [String: [String: ConversationReadingPosition]] = [:]
    /// 本机状态文件读取异常时的说明；nil 表示正常。
    @Published private(set) var loadWarning: String?
    /// 最近一次写入本机文件失败的原因；nil 表示正常。
    @Published private(set) var saveError: String?

    /// 隧道与 RACP 的实时状态（服务器页测试连接、设置页状态、项目页列表都读它）。
    let connection: ConnectionModel
    let usesUITestFixture: Bool
    private var tunnelObservation: AnyCancellable?
    private var remoteObservation: AnyCancellable?
    private var connectionErrorObservation: AnyCancellable?
    private var hostSwitchGeneration = 0
    private var foregroundNotificationTransitionID: UUID?
    private var deferredStatePersistenceTask: Task<Void, Never>?
    private var automaticStatePersistenceTask: Task<Void, Never>?
    private var automaticStatePersistencePending = false
    private var canPersistLoadedState = true
    private let stateFileURL: URL?
    private var persistenceGeneration: UInt64 = 0
    private var pendingHostID: UUID?
    private var providerConnectionGeneration = 0
    private var providerIdentityGeneration = 0
    /// U15: monotonic per-host-record identity generation. Bumped whenever an
    /// install target's SSH identity or endpoint-port fields change, so an install
    /// that started before the edit can never commit its token to the new record.
    private var installIdentityGenerations: [UUID: Int] = [:]
#if DEBUG
    /// Test-only persistence override; never set outside PI-IOSTests.
    var persistenceOverrideForTesting: (() -> Bool)?
    /// Test-only interleave point after the state-file barrier produced a result
    /// but before the flush applies it. Lets tests make a newer accepted write
    /// fail in that gap.
    var afterPersistBarrierHookForTesting: (() -> Void)?
#endif
    private var foregroundResumeTracker = ForegroundResumeTracker()
    @Published private(set) var resumedSessionUpdates = ForegroundSessionUpdateMarkers()

    @Published var root: Root = .settings
    @Published var isSidebarOpen = false
    @Published var toast: PIToast?
    /// 上次打开的会话与项目（AC-18.6：切回 host / 重启后恢复上下文）。
    @Published private(set) var lastSessionId: String?
    @Published private(set) var lastProjectId: String?

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
        readingPositionsByHost = outcome.state.readingPositionsByHost
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
    private func migrateLegacyDeviceTokens() {
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
        if connection.session.attachedSessionId == nil,
           let sessionID = lastSessionByHost[hostID.uuidString] {
            await connection.session.attach(sessionId: sessionID, source: "foreground")
        } else {
            await connection.session.refreshView(source: "foreground")
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

    private func notificationBaseline(
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

    private func notificationSnapshot(
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

    private func foregroundSnapshot() -> ForegroundResumeSnapshot? {
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

    // MARK: - 本机项目元数据

    func projectBinding(hostID: UUID, projectID: String) -> StoredProjectBinding? {
        projectBindings.first { $0.hostID == hostID && $0.projectID == projectID }
    }

    func projectBinding(hostID: UUID, path: String) -> StoredProjectBinding? {
        projectBindings.first { $0.hostID == hostID && $0.path == path }
    }

    func projectDisplayName(
        hostID: UUID,
        projectID: String,
        fallback: String
    ) -> String {
        if let local = projectBinding(hostID: hostID, projectID: projectID)?.name
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !local.isEmpty {
            return local
        }
        return fallback
    }

    func currentProjectDisplayName(projectID: String, fallback: String) -> String {
        guard let hostID = currentHost?.id else { return fallback }
        return projectDisplayName(hostID: hostID, projectID: projectID, fallback: fallback)
    }

    @discardableResult
    func recordProjectBinding(
        hostID: UUID,
        projectID: String,
        path: String?,
        name: String
    ) -> StoredProjectBinding {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = projectBindings.first { binding in
            binding.hostID == hostID
                && (binding.projectID == projectID || (path != nil && binding.path == path))
        }
        projectBindings.removeAll { binding in
            guard binding.hostID == hostID else { return false }
            if binding.projectID == projectID { return true }
            guard let path, let oldPath = binding.path else { return false }
            return oldPath == path
        }
        let binding = StoredProjectBinding(
            hostID: hostID,
            projectID: projectID,
            path: path,
            name: normalizedName,
            source: .local,
            isArchived: false,
            isDeleted: false,
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date()
        )
        projectBindings.append(binding)
        persist()
        return binding
    }

    func isProjectArchived(hostID: UUID, projectID: String) -> Bool {
        projectBinding(hostID: hostID, projectID: projectID)?.isArchived ?? false
    }

    func isProjectDeleted(hostID: UUID, projectID: String) -> Bool {
        projectBinding(hostID: hostID, projectID: projectID)?.isDeleted ?? false
    }

    func setProjectArchived(hostID: UUID, projectID: String, archived: Bool) {
        guard let index = projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) else { return }
        projectBindings[index].isArchived = archived
        projectBindings[index].updatedAt = Date()
        if archived, lastProjectByHost[hostID.uuidString] == projectID {
            lastProjectByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    func deleteProjectLocally(hostID: UUID, projectID: String, name: String) -> Bool {
        guard hosts.contains(where: { $0.id == hostID }) else { return false }
        var next = snapshot
        let boundSessionIDs = next.sessionBindings
            .filter { $0.hostID == hostID && $0.projectID == projectID }
            .map(\.sessionID)
        let catalogSessionIDs = connection.currentCatalogHostID == hostID
            ? connection.sessions.filter { $0.projectId == projectID }.map(\.id)
            : []
        let removedSessionIDs = Set(boundSessionIDs + catalogSessionIDs)
        let now = Date()
        if let index = next.projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) {
            next.projectBindings[index].isDeleted = true
            next.projectBindings[index].isArchived = true
            next.projectBindings[index].updatedAt = now
        } else {
            next.projectBindings.append(StoredProjectBinding(
                hostID: hostID, projectID: projectID, path: nil, name: name,
                isArchived: true, isDeleted: true, createdAt: now, updatedAt: now
            ))
        }
        for index in next.sessionBindings.indices where
            next.sessionBindings[index].hostID == hostID
                && removedSessionIDs.contains(next.sessionBindings[index].sessionID) {
            next.sessionBindings[index].isDeleted = true
            next.sessionBindings[index].isPinned = false
            next.sessionBindings[index].pinOrder = nil
            next.sessionBindings[index].updatedAt = now
        }
        let hostKey = hostID.uuidString
        for sessionID in removedSessionIDs {
            next.readingPositionsByHost[hostKey]?.removeValue(forKey: sessionID)
        }
        if next.readingPositionsByHost[hostKey]?.isEmpty == true {
            next.readingPositionsByHost.removeValue(forKey: hostKey)
        }
        if next.lastProjectByHost[hostKey] == projectID {
            next.lastProjectByHost.removeValue(forKey: hostKey)
        }
        if let lastSession = next.lastSessionByHost[hostKey], removedSessionIDs.contains(lastSession) {
            next.lastSessionByHost.removeValue(forKey: hostKey)
        }
        if currentHost?.id == hostID {
            if next.lastProjectId == projectID { next.lastProjectId = nil }
            if let lastSession = next.lastSessionId, removedSessionIDs.contains(lastSession) {
                next.lastSessionId = nil
            }
        }
        guard persist(next) else { return false }

        projectBindings = next.projectBindings
        sessionBindings = next.sessionBindings
        readingPositionsByHost = next.readingPositionsByHost
        lastProjectByHost = next.lastProjectByHost
        lastSessionByHost = next.lastSessionByHost
        lastProjectId = next.lastProjectId
        lastSessionId = next.lastSessionId
        connection.removeCachedSessions(Array(removedSessionIDs), hostID: hostID)
        return true
    }

    @discardableResult
    func renameProject(hostID: UUID, projectID: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let duplicate = projectBindings.contains {
            $0.hostID == hostID
                && $0.projectID != projectID
                && !$0.isDeleted
                && $0.name == trimmed
        }
        guard !duplicate else { return false }
        guard let index = projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) else { return false }
        projectBindings[index].name = trimmed
        projectBindings[index].updatedAt = Date()
        persist()
        return true
    }

    func projectBrowserPath(hostID: UUID) -> String? {
        projectBrowserPaths[hostID.uuidString]
    }

    func rememberProjectBrowserPath(hostID: UUID, path: String) {
        guard projectBrowserPaths[hostID.uuidString] != path else { return }
        projectBrowserPaths[hostID.uuidString] = path
        persist()
    }

    // MARK: - 本机会话元数据

    func sessionBinding(hostID: UUID, sessionID: String) -> StoredSessionBinding? {
        sessionBindings.first { $0.hostID == hostID && $0.sessionID == sessionID }
    }

    func readingPosition(
        hostID: UUID,
        sessionID: String
    ) -> ConversationReadingPosition? {
        readingPositionsByHost[hostID.uuidString]?[sessionID]
    }

    func rememberReadingPosition(
        hostID: UUID,
        sessionID: String,
        lastVisibleItemID: String?,
        isNearBottom: Bool
    ) {
        // 已删除 tombstone 不允许被迟到的滚动位置写入复活。
        if sessionBinding(hostID: hostID, sessionID: sessionID)?.isDeleted == true {
            return
        }
        let normalizedItemID = lastVisibleItemID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = ConversationReadingPosition(
            lastVisibleItemID: normalizedItemID?.isEmpty == false ? normalizedItemID : nil,
            isNearBottom: isNearBottom
        )
        let hostKey = hostID.uuidString
        let current = readingPositionsByHost[hostKey]?[sessionID]
        guard current != next else { return }
        readingPositionsByHost[hostKey, default: [:]][sessionID] = next
        deferredStatePersistenceTask?.cancel()
        deferredStatePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.deferredStatePersistenceTask = nil
            _ = await self.persistAsync()
        }
    }

    @discardableResult
    func flushPersistentState() async -> Bool {
        deferredStatePersistenceTask?.cancel()
        deferredStatePersistenceTask = nil
        automaticStatePersistenceTask?.cancel()
        automaticStatePersistenceTask = nil
        automaticStatePersistencePending = false

#if DEBUG
        if let persistenceOverrideForTesting {
            return persistenceOverrideForTesting()
        }
#endif
        guard !usesUITestFixture else { return true }
        guard canPersistLoadedState else {
            saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            return false
        }

        // Persist the current snapshot, then inspect a real serial-queue barrier.
        // This catches a newer accepted write that fails while the first flush is
        // suspended instead of returning the first write's stale `true`.
        let attempt = await persistAsyncTracked()
        let result = await StateFile.waitForPendingWritesResult()
#if DEBUG
        afterPersistBarrierHookForTesting?()
#endif
        // A newer accepted write (or the cancelled background lease that owns
        // this flush) may have changed saveError after our barrier. Only the
        // generation that this flush enqueued may publish its result.
        let mayPublish = !Task.isCancelled && attempt.generation == persistenceGeneration
        switch result {
        case .committed:
            if mayPublish { saveError = nil }
            return true
        case .failed(let message):
            if mayPublish { saveError = "保存本机记录失败：\(message)" }
            return false
        }
    }

    /// Shared by the scene background path and regression tests: a state failure
    /// is observable but must never short-circuit the independent cache barrier.
    func flushForBackground() async {
        _ = await flushPersistentState()
        await connection.flushPendingCacheWrites()
    }

    /// Coalesce automatic (remote/tunnel/discovery) state saves onto the same
    /// 250 ms debounce used by reading positions. Only one task is retained; new
    /// changes set a pending flag instead of growing the queue.
    private func scheduleAutomaticPersist() {
        guard !usesUITestFixture else { return }
        automaticStatePersistencePending = true
        guard automaticStatePersistenceTask == nil else { return }
        automaticStatePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                self?.automaticStatePersistenceTask = nil
                return
            }
            guard let self else { return }
            guard self.automaticStatePersistencePending else {
                self.automaticStatePersistenceTask = nil
                return
            }
            self.automaticStatePersistencePending = false
            _ = await self.persistAsync()
            self.automaticStatePersistenceTask = nil
            if self.automaticStatePersistencePending {
                self.scheduleAutomaticPersist()
            }
        }
    }

    func sessionDisplayTitle(
        hostID: UUID,
        sessionID: String,
        fallback: String
    ) -> String {
        let override = sessionBinding(hostID: hostID, sessionID: sessionID)?
            .titleOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return fallback
    }

    func recordCreatedSession(
        hostID: UUID,
        sessionID: String,
        projectID: String?,
        title: String?,
        now: Date = Date()
    ) {
        sessionBindings.removeAll { $0.hostID == hostID && $0.sessionID == sessionID }
        sessionBindings.append(
            StoredSessionBinding(
                hostID: hostID,
                sessionID: sessionID,
                projectID: projectID,
                titleOverride: title,
                source: .local,
                isArchived: false,
                lastOpenedAt: now,
                lastActivityAt: now,
                updatedAt: now
            )
        )
        persist()
    }

    func updateSessionActivity(
        hostID: UUID,
        sessionID: String,
        messageCount: Int,
        markRead: Bool = true
    ) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].messageCount = messageCount
        sessionBindings[index].lastActivityAt = Date()
        if markRead {
            sessionBindings[index].isUnread = false
        }
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    @discardableResult
    func renameSession(hostID: UUID, sessionID: String, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return false }
        sessionBindings[index].titleOverride = trimmed
        sessionBindings[index].updatedAt = Date()
        persist()
        return true
    }

    func setSessionArchived(hostID: UUID, sessionID: String, archived: Bool) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].isArchived = archived
        if archived {
            sessionBindings[index].isPinned = false
            sessionBindings[index].pinOrder = nil
        }
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    /// Host 已明确删除目标后的本机收尾；不得把本方法当成另一个删除入口。
    func deleteSessionLocally(hostID: UUID, sessionID: String) {
        let hostKey = hostID.uuidString
        if let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) {
            sessionBindings[index].isDeleted = true
            sessionBindings[index].isArchived = true
            sessionBindings[index].titleOverride = nil
            sessionBindings[index].messageCount = nil
            sessionBindings[index].lastOpenedAt = nil
            sessionBindings[index].lastKnownRevision = nil
            sessionBindings[index].lastActivityAt = .distantPast
            sessionBindings[index].isUnread = false
            sessionBindings[index].isPinned = false
            sessionBindings[index].pinOrder = nil
            sessionBindings[index].updatedAt = Date()
        }
        readingPositionsByHost[hostKey]?.removeValue(forKey: sessionID)
        if readingPositionsByHost[hostKey]?.isEmpty == true {
            readingPositionsByHost.removeValue(forKey: hostKey)
        }
        // 取消旧阅读位置的延迟持久化，并阻止后续通知继续指向已删除目标。
        deferredStatePersistenceTask?.cancel()
        deferredStatePersistenceTask = nil
        resumedSessionUpdates.open(hostID: hostID, sessionID: sessionID)
        foregroundResumeTracker.open(hostID: hostID, sessionID: sessionID)
        if lastSessionByHost[hostKey] == sessionID {
            lastSessionByHost.removeValue(forKey: hostKey)
        }
        if currentHost?.id == hostID, lastSessionId == sessionID {
            lastSessionId = nil
        }
        persist()
    }

    func pinSession(hostID: UUID, sessionID: String) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }), !sessionBindings[index].isPinned else { return }
        let projectID = sessionBindings[index].projectID
        let maxOrder = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
            }
            .compactMap(\.pinOrder)
            .max() ?? -1
        sessionBindings[index].isPinned = true
        sessionBindings[index].pinOrder = maxOrder + 1
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    func unpinSession(hostID: UUID, sessionID: String) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].isPinned = false
        sessionBindings[index].pinOrder = nil
        sessionBindings[index].updatedAt = Date()
        normalizePinOrders(hostID: hostID, projectID: sessionBindings[index].projectID)
        persist()
    }

    func movePinnedSession(
        hostID: UUID,
        projectID: String?,
        sessionID: String,
        before targetID: String
    ) {
        let group = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
                    && !$0.isArchived
            }
        let orders = Dictionary(uniqueKeysWithValues: group.compactMap { item in
            item.pinOrder.map { (item.sessionID, $0) }
        })
        let moved = SessionOrderingPolicy.movePinned(
            group.map(\.sessionID),
            pinnedOrders: orders,
            sourceID: sessionID,
            before: targetID
        )
        guard moved != orders else { return }
        for (id, order) in moved {
            guard let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == id
            }) else { continue }
            sessionBindings[index].pinOrder = order
        }
        persist()
    }

    private func normalizePinOrders(hostID: UUID, projectID: String?) {
        let pinned = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
            }
            .sorted { ($0.pinOrder ?? Int.max) < ($1.pinOrder ?? Int.max) }
        for (order, item) in pinned.enumerated() {
            guard let index = sessionBindings.firstIndex(where: { $0.id == item.id }) else { continue }
            sessionBindings[index].pinOrder = order
        }
    }

    func isProjectGroupCollapsed(hostID: UUID, projectID: String) -> Bool {
        collapsedProjectGroups.contains("\(hostID.uuidString):\(projectID)")
    }

    func toggleProjectGroup(hostID: UUID, projectID: String) {
        let key = "\(hostID.uuidString):\(projectID)"
        if let index = collapsedProjectGroups.firstIndex(of: key) {
            collapsedProjectGroups.remove(at: index)
        } else {
            collapsedProjectGroups.append(key)
        }
        persist()
    }

    /// 当前服务器：`isCurrent` 优先，其次第一条（不合成「幽灵」记录）。
    var currentHost: HostRecord? {
        hosts.first(where: { $0.isCurrent }) ?? hosts.first
    }

    var isCurrentHostPaired: Bool { currentHost?.pairedAt != nil }

    var currentModelProviders: [StoredModelProvider] {
        guard let hostID = currentHost?.id else { return [] }
        return modelProviders
            .filter { $0.hostID == hostID }
            .sorted { $0.importedAt > $1.importedAt }
    }

    var currentModelGroups: [ProviderModelGroup] {
        currentModelGrouping.groups
    }

    var currentModelGrouping: ModelGroupingResult {
        groupModelsByProviderDetailed(
            currentModelProviders.map { provider in
                ProviderRecord(
                    providerId: provider.providerId,
                    name: provider.name,
                    models: provider.records(defaultModelId: provider.defaultModelId)
                )
            }
        )
    }

    var currentModelDiagnostics: [ModelGroupingDiagnostic] {
        currentModelGrouping.diagnostics
    }

    /// 当前 Host 的默认模型（host 级单选）。新会话用它作为初始绑定，
    /// 设置页「默认模型」一行也直接读它，避免两处各自推导出不同结论。
    var defaultModelSelection: DefaultModelSelection? {
        guard let hostID = currentHost?.id else { return nil }
        // `hostV2Mirror == false` 是只存在旧 SSH 存储的记录：它不能驱动会话，
        // 不能作为默认模型显示或绑定。`nil` 是旧记录，保守放行。
        for provider in currentModelProviders
        where provider.hostID == hostID && provider.hostV2Mirror != false {
            guard let modelId = provider.defaultModelId,
                  let binding = provider.models.first(where: { $0.id == modelId })
            else { continue }
            return DefaultModelSelection(
                providerId: provider.providerId,
                modelId: binding.id,
                displayName: "\(provider.name) · \(binding.displayName)",
                thinkingLevel: binding.defaultThinkingLevel
            )
        }
        return nil
    }

    /// 新建会话用的默认绑定。`defaultModelSelection` 已经排除仅 legacy 的服务，
    /// 这里保持单一口径：新建会话与设置页看到的是同一个默认模型。
    var defaultModelSelectionForNewSession: DefaultModelSelection? {
        defaultModelSelection
    }

    var defaultModelLabel: String {
        defaultModelSelection?.label ?? "未配置"
    }

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
    @Published private(set) var pendingSettingsRoute: SettingsRoute?

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

    private func usesSSHAccount(_ account: String, excluding id: UUID) -> Bool {
        hosts.contains { host in
            host.id != id && KeychainStore.account(username: host.username, host: host.host, port: host.port) == account
        }
    }

    private func applyHostDataRemoval(_ state: PersistedState, hostID id: UUID, wasCurrent: Bool) {
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

    private func recoverPromotedInstallReceipts() {
        for index in hosts.indices {
            _ = recoverPromotedInstallReceipt(at: index, afterReload: true)
        }
    }

    private func prepareHostConnection(id: UUID) -> HostRecord? {
        guard let index = hosts.firstIndex(where: { $0.id == id }),
              recoverPromotedInstallReceipt(at: index) else { return nil }
        return hosts[index]
    }

    private func recoverPromotedInstallReceipt(at index: Int, afterReload: Bool = false) -> Bool {
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

    private func writeInstallReceipt(
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

    private func bumpInstallIdentityGeneration(_ id: UUID) {
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

    /// Resolve the key with its saved endpoint. Raw Keychain entries can use the
    /// existing local projection, including an explicitly recorded legacy mirror.
    func providerCredentialForTurn(providerId: String, hostID: UUID) -> KeychainStore.ProviderKeyRecord? {
        let stored = storedProvider(hostID: hostID, providerId: providerId)
        var key = KeychainStore.loadProviderKeyRecord(hostID: hostID, providerId: providerId)
        if key == nil, let legacyID = stored?.legacyProviderId, legacyID != providerId {
            key = KeychainStore.loadProviderKeyRecord(hostID: hostID, providerId: legacyID)
        }
        let legacyEndpoint = stored?.endpointForLegacyKey
        if key?.baseURL == nil, let legacyEndpoint, !legacyEndpoint.isEmpty {
            key?.baseURL = legacyEndpoint
        }
        return key
    }

    /// 会话发送路径的 key 解析器。ConnectionModel 在 init 里装了默认实现（只按
    /// provider id 查）；AppModel 持有本机映射，能在默认实现之上补 legacy 回退。
    private func installProviderAPIKeyResolver() {
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
        serverDefaultSet: Bool,
        legacyProviderId: String? = nil,
        hostV2Mirror: Bool? = nil
    ) -> Bool {
        guard canApplyProviderOperation(context) else { return false }
        let hostID = context.hostID
        let previousRecord = modelProviders.first {
            $0.hostID == hostID && $0.providerId == providerId
        }
        let previousDefault = previousRecord?.defaultModelId
        let legacyKeyBaseURL = previousRecord?.endpointForLegacyKey
            ?? legacyProviderId.flatMap { storedProvider(hostID: hostID, providerId: $0)?.endpointForLegacyKey }
            ?? ""
        // 默认模型是 host 级单选：`input.defaultModelId` 代表「本次用户明确选择或
        // 导入载荷声明的默认」，必须优先于本机旧值；旧实现把 previous 排在新选择
        // 前面，导致「设为默认」在刷新本机记录时被还原成旧默认。
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
                legacyProviderId: legacyProviderId,
                hostV2Mirror: hostV2Mirror,
                hostID: hostID,
                name: input.name,
                baseURL: input.baseUrl ?? "",
                apiStyle: input.apiStyle ?? "chat_completions",
                models: input.models.map(StoredModelBinding.init(spec:)),
                defaultModelId: defaultModelId,
                importedAt: Date(),
                legacyKeyBaseURL: legacyKeyBaseURL
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

    private func observeTunnelState() {
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
    private func observeConnectionErrors() {
        connectionErrorObservation = connection.$lastError
            .removeDuplicates()
            .sink { error in
                guard let error else { return }
                PILog.warn("Connection", "最近错误：\(ConnectionDiagnosticRedactor.redact(error))")
            }
    }

    private func observeRemoteMetadata() {
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

    private func mergeRemoteMetadata(
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

    private func connectCurrentHostIfPaired() async {
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

    private func applyLogConfiguration() {
        logStore.configure(logConfiguration)
        MainThreadStallMonitor.shared.setEnabled(logConfiguration.isEnabled && !usesUITestFixture)
    }

    private var logExportMetadata: PILogExportMetadata {
        PILogExportMetadata(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            configuration: logConfiguration,
            buildIdentity: PIBuildIdentity.current
        )
    }

    private static var appVersionText: String {
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

    // MARK: - 持久化

    private var snapshot: PersistedState {
        PersistedState(
            hosts: hosts,
            offlineCacheLimit: offlineCacheLimit,
            modelProviders: modelProviders,
            lastSessionId: lastSessionId,
            lastProjectId: lastProjectId,
            projectBindings: projectBindings,
            sessionBindings: sessionBindings,
            lastSessionByHost: lastSessionByHost,
            lastProjectByHost: lastProjectByHost,
            collapsedProjectGroups: collapsedProjectGroups,
            projectBrowserPaths: projectBrowserPaths,
            readingPositionsByHost: readingPositionsByHost,
            logConfiguration: logConfiguration
        )
    }

    @discardableResult
    private func persist(_ preparedState: PersistedState? = nil) -> Bool {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
#if DEBUG
        if let persistenceOverrideForTesting { return persistenceOverrideForTesting() }
#endif
        guard !usesUITestFixture else { return true }
        guard canPersistLoadedState else {
            if generation == persistenceGeneration {
                saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            }
            return false
        }
        do {
            let state = preparedState ?? snapshot
            if let stateFileURL {
                try StateFile.save(state, to: stateFileURL)
            } else {
                try StateFile.save(state)
            }
            if generation == persistenceGeneration {
                saveError = nil
            }
            return true
        } catch {
            PILog.warn("StateFile", "保存失败：\(error.localizedDescription)")
            if generation == persistenceGeneration {
                saveError = "保存本机记录失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    private struct PersistAttempt {
        let succeeded: Bool
        let generation: UInt64
    }

    @discardableResult
    private func persistAsync() async -> Bool {
        let attempt = await persistAsyncTracked()
        return attempt.succeeded
    }

    /// Async save that reports the generation it owns, so a barrier caller can
    /// tell whether a newer accepted write superseded its result.
    private func persistAsyncTracked() async -> PersistAttempt {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        func attempt(_ succeeded: Bool) -> PersistAttempt {
            PersistAttempt(succeeded: succeeded, generation: generation)
        }
#if DEBUG
        if let persistenceOverrideForTesting { return attempt(persistenceOverrideForTesting()) }
#endif
        guard !usesUITestFixture else { return attempt(true) }
        guard canPersistLoadedState else {
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            }
            return attempt(false)
        }
        let state = snapshot
        do {
            if let stateFileURL {
                try await StateFile.saveAsync(state, to: stateFileURL)
            } else {
                try await StateFile.saveAsync(state)
            }
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = nil
            }
            return attempt(true)
        } catch {
            PILog.warn("StateFile", "保存失败：\(error.localizedDescription)")
            if !Task.isCancelled, generation == persistenceGeneration {
                saveError = "保存本机记录失败：\(error.localizedDescription)"
            }
            return attempt(false)
        }
    }
}
