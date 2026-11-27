import Foundation
import Combine
import SwiftUI
import UIKit
import PIiOSCore
import PIiOSNet


extension AppModel {
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
        for sessionID in removedSessionIDs {
            readingPositionsByHost[hostKey]?.removeValue(forKey: sessionID)
        }
        if readingPositionsByHost[hostKey]?.isEmpty == true { readingPositionsByHost[hostKey] = nil }
        persistReadingPositionsIfNeeded()
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

    var readingPositionsFileURL: URL? {
        if let stateFileURL {
            return stateFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("reading-positions-v1.json", isDirectory: false)
        }
        return ReadingPositionStore.defaultFileURL
    }

    func persistReadingPositionsIfNeeded() {
        deferredReadingPositionTask?.cancel()
        deferredReadingPositionTask = nil
        readingPositionWriteGeneration &+= 1
        guard !usesUITestFixture, seedOnlyPositionsCheck else { return }
        readingPositionsDirty = !ReadingPositionStore.save(readingPositionsByHost, to: readingPositionsFileURL)
    }

    var seedOnlyPositionsCheck: Bool { canPersistLoadedState }

    private func savePendingReadingPositions() async -> Bool {
        guard readingPositionsDirty, !usesUITestFixture else { return true }
        guard canPersistLoadedState else { return false }
        readingPositionWriteGeneration &+= 1
        let generation = readingPositionWriteGeneration
        let saved = await ReadingPositionStore.saveAsync(readingPositionsByHost, to: readingPositionsFileURL)
        if generation == readingPositionWriteGeneration { readingPositionsDirty = !saved }
        return saved
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
        readingPositionWriteGeneration &+= 1
        readingPositionsDirty = true
        guard !usesUITestFixture else { return }
        deferredReadingPositionTask?.cancel()
        deferredReadingPositionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.deferredReadingPositionTask = nil
            _ = await self.savePendingReadingPositions()
        }
    }

    @discardableResult
    func flushPersistentState() async -> Bool {
        deferredReadingPositionTask?.cancel()
        deferredReadingPositionTask = nil
        automaticStatePersistenceTask?.cancel()
        automaticStatePersistenceTask = nil
        automaticStatePersistencePending = false

#if DEBUG
        if let persistenceOverrideForTesting {
            let positionsSaved = await savePendingReadingPositions()
            return persistenceOverrideForTesting() && positionsSaved
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
        let positionsSaved = await savePendingReadingPositions()
#if DEBUG
        afterPersistBarrierHookForTesting?()
#endif
        // A newer accepted write (or the cancelled background lease that owns
        // this flush) may have changed saveError after our barrier. Only the
        // generation that this flush enqueued may publish its result.
        let mayPublish = !Task.isCancelled && attempt.generation == persistenceGeneration
        switch result {
        case .committed:
            if mayPublish { saveError = positionsSaved ? nil : "阅读位置保存失败，将在下次保存时重试。" }
            return positionsSaved
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
    func scheduleAutomaticPersist() {
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
        deferredReadingPositionTask?.cancel()
        deferredReadingPositionTask = nil
        readingPositionsDirty = true
        resumedSessionUpdates.open(hostID: hostID, sessionID: sessionID)
        foregroundResumeTracker.open(hostID: hostID, sessionID: sessionID)
        if lastSessionByHost[hostKey] == sessionID {
            lastSessionByHost.removeValue(forKey: hostKey)
        }
        if currentHost?.id == hostID, lastSessionId == sessionID {
            lastSessionId = nil
        }
        persist()
        persistReadingPositionsIfNeeded()
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

    func normalizePinOrders(hostID: UUID, projectID: String?) {
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
        for provider in currentModelProviders where provider.hostID == hostID {
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

}
