import Foundation
import PIiOSCore
import PIiOSNet

#if DEBUG
struct SessionControllerFixtureState {
    var interruptionEnabled = false
    var snapshots: [String: RACPSessionView] = [:]
    var historyModel: SessionViewModel?
    var earlierHistoryPages: [UITestEarlierHistoryPage] = []
    var failedOpenSessions: Set<String> = []
}
#else
struct SessionControllerFixtureState {}
#endif

extension SessionController {
#if DEBUG
    func configureUITestSnapshots(_ snapshots: [String: RACPSessionView]) {
        guard client == nil, !snapshots.isEmpty else { return }
        fixtureState.snapshots = snapshots
    }

    func configureUITestInterruption(enabled: Bool) {
        fixtureState.interruptionEnabled = enabled
    }

    /// Explicitly invoked only by the opt-in stability UI fixture control. The
    /// normal Published items change drives the production grouping/follow path.
    func appendStabilityFixtureMessage() {
        guard client == nil, UITestFixture.stabilityControlsEnabled,
              let sessionID = attachedSessionId, sessionID == "S1",
              var snapshot = fixtureState.snapshots[sessionID], view.sessionId == sessionID else { return }
        let ordinal = view.items.filter { $0.id.hasPrefix("stability-live-") }.count + 1
        let id = "stability-live-\(ordinal)"
        let item = RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("assistant"),
            "text": .string("Stability appended \(ordinal)"),
        ]))
        view.items.append(item)
        snapshot.items = view.items
        fixtureState.snapshots[sessionID] = snapshot
    }
#endif

    func fixtureAttachOutcomeIfApplicable(
        sessionId: String,
        selection: Int,
        generation: Int
    ) async -> String? {
#if DEBUG
        guard let snapshot = fixtureState.snapshots[sessionId] else { return nil }
        if let behavior = UITestFixture.current?.sessionOpenBehavior {
            try? await Task.sleep(for: .milliseconds(behavior.delayMilliseconds))
            guard !Task.isCancelled, sessionSelectionGeneration == selection,
                  bindGeneration == generation else { return "cancelled" }
            if behavior.failingSessionID == sessionId, fixtureState.failedOpenSessions.insert(sessionId).inserted {
                lastError = "会话同步失败，请重试"
                return "failed"
            }
        }
        bind(client: nil, online: true)
        view = snapshot
        attachedSummary = snapshot.summary
        attachedSessionId = sessionId
        attachedBindGeneration = bindGeneration
        runningTurnId = snapshot.runningTurnId
        lastError = nil
        if snapshot.hasMoreHistory,
           let pages = UITestFixture.current?.earlierHistoryPages[sessionId],
           !pages.isEmpty {
            fixtureState.historyModel = Self.makeFixtureHistoryModel(from: snapshot)
            fixtureState.earlierHistoryPages = pages
        } else {
            fixtureState.historyModel = nil
            fixtureState.earlierHistoryPages = []
        }
        return "success"
#else
        nil
#endif
    }

    func fixtureLoadEarlierHistoryIfApplicable() async -> Bool? {
#if DEBUG
        guard client == nil,
              isOnline,
              !isBusy,
              !isLoadingEarlierHistory,
              view.hasMoreHistory,
              let sessionID = attachedSessionId,
              view.sessionId == sessionID
        else { return nil }
        return await loadFixtureEarlierHistory(sessionID: sessionID)
#else
        nil
#endif
    }

    func fixtureSendFailureIfApplicable(
        generation: Int,
        selection: Int
    ) async -> Bool {
#if DEBUG
        guard client == nil,
              let delay = UITestFixture.current?.submissionFailureDelayMilliseconds
        else { return false }
        let busy = beginBusy()
        defer { endBusy(busy) }
        try? await Task.sleep(for: .milliseconds(delay))
        guard !Task.isCancelled, generation == bindGeneration,
              selection == sessionSelectionGeneration else { return true }
        modelAvailabilityCheck = nil
        lastError = "测试连接发送失败，草稿已保留"
        return true
#else
        false
#endif
    }

    func fixtureInterruptIfApplicable() async -> Bool {
#if DEBUG
        guard fixtureState.interruptionEnabled, let turnId = runningTurnId else {
            return false
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return true
        }
        guard bindGeneration == generation,
              sessionSelectionGeneration == selection,
              self.runningTurnId == turnId
        else { return true }
        self.runningTurnId = nil
        self.view.activeItems = []
        notice = "已中止"
        lastError = nil
        return true
#else
        false
#endif
    }

#if DEBUG
    /// Test-only page loader. It follows the same loading/lifecycle gate as the
    /// client path, stages pages until the earliest turn has its task boundary,
    /// then performs one reducer prepend and one Published view assignment.
    private func loadFixtureEarlierHistory(sessionID: String) async -> Bool {
        guard let model = fixtureState.historyModel, !fixtureState.earlierHistoryPages.isEmpty else {
            return false
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let loadID = UUID()
        historyLoadID = loadID
        isLoadingEarlierHistory = true
        historyError = nil
        defer {
            if historyLoadID == loadID {
                historyLoadID = nil
                isLoadingEarlierHistory = false
            }
        }
        var staged: [RACPItem] = []
        var hasMore = view.hasMoreHistory
        while true {
            guard !fixtureState.earlierHistoryPages.isEmpty else {
                // A malformed fixture must not expose its staged partial turn.
                historyError = "测试历史缺少完整任务起点"
                return false
            }
            let page = fixtureState.earlierHistoryPages[0]
            if page.delayMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(page.delayMilliseconds))
                } catch {
                    return false
                }
            }
            guard bindGeneration == generation,
                  sessionSelectionGeneration == selection,
                  attachedSessionId == sessionID,
                  historyLoadID == loadID,
                  fixtureState.historyModel === model
            else { return false }
            fixtureState.earlierHistoryPages.removeFirst()
            staged = page.items + staged
            hasMore = page.hasMore
            if ConversationTurnPolicy.hasTaskBoundary(staged + model.items) || !hasMore {
                break
            }
        }
        guard bindGeneration == generation,
              sessionSelectionGeneration == selection,
              attachedSessionId == sessionID,
              historyLoadID == loadID,
              fixtureState.historyModel === model
        else { return false }
        let inserted = model.prependHistory(staged, hasMore: hasMore)
        var updatedView = view
        updatedView.items = model.items
        updatedView.hasMoreHistory = model.hasMoreHistory
        view = updatedView
        return inserted > 0
    }

    private static func makeFixtureHistoryModel(from snapshot: RACPSessionView) -> SessionViewModel {
        let model = SessionViewModel()
        guard let cursor = snapshot.cursor else { return model }
        model.applySnapshot(
            RACPSnapshot(
                cursor: cursor,
                revision: snapshot.revision,
                items: snapshot.items,
                activeItems: snapshot.activeItems,
                queuedTurns: [],
                pendingApprovals: snapshot.pendingApprovals,
                hasMoreHistory: snapshot.hasMoreHistory
            ),
            replayComplete: snapshot.replayComplete
        )
        return model
    }
#endif
}
