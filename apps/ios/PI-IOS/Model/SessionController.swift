import Foundation
import PIiOSCore
import PIiOSNet

enum SessionModelAvailability: Equatable {
    case checking
    case available
    case unavailable(reason: String)
    case unknown(reason: String)

    var allowsSending: Bool { self == .available }

    var displayText: String? {
        switch self {
        case .checking:
            return "正在确认当前模型是否可用"
        case .available:
            return nil
        case .unavailable(let reason):
            return "当前模型不可用：\(reason)"
        case .unknown(let reason):
            return "无法确认当前模型是否可用：\(reason)"
        }
    }
}

/// 会话内的全部写操作（发送 / 中止 / 排队 / 审批 / 提问 / 配置）都经过这里。
///
/// 规则（与契约一致，不做例外处理）：
/// - 写操作一律要求隧道在线；离线时按钮禁用并给出原因，不产生静默失败（AC-15.2 / AC-G1）。
/// - 一次性动作（审批、提问、发送）都会带幂等键：发送的键**持久化**并在重试时复用（AC-14.4）。
/// - 提交审批用快照里该卡自己的 `revision`；卡片已不在快照里就不可提交（AC-14.5 / AC-14.6）。
@MainActor
final class SessionController: ObservableObject {
    /// A message accepted by `turn/start` may be absent from the server
    /// snapshot until the reply arrives. Keep a local bubble and replace it
    /// once the authoritative user item appears.
    struct PendingUserEcho: Equatable, Sendable {
        let id: String
        let sessionID: String
        let turnID: String
        let text: String
        let baselineItemIDs: Set<String>
        /// Last item before this send; keeps the local bubble before any
        /// assistant item that streams into the snapshot later.
        let anchorItemID: String?

        var item: RACPItem {
            RACPItem(id: id, payload: .object([
                "id": .string(id),
                "itemType": .string("message"),
                "role": .string("user"),
                "text": .string(text),
                "turnId": .string(turnID),
                "localEcho": .bool(true),
            ]))
        }

        func isEchoed(in items: [RACPItem]) -> Bool {
            items.contains { item in
                guard item.id != id, item.role == "user" else { return false }
                if item.turnId == turnID { return true }
                // A server reply may omit turnId. Only then compare text, and
                // never match an item that existed before this send.
                guard !baselineItemIDs.contains(item.id) else { return false }
                return (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    == text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        func inserted(into items: [RACPItem]) -> [RACPItem] {
            guard let anchorItemID,
                  let index = items.firstIndex(where: { $0.id == anchorItemID })
            else { return items + [item] }
            var result = items
            result.insert(item, at: index + 1)
            return result
        }
    }
    @Published private(set) var view: RACPSessionView = .empty
    @Published private(set) var attachedSessionId: String?
    @Published private(set) var attachedSummary: RACPSessionSummary?
    /// Selected destination is separate from the transport's attached session.
    /// Retained after failure so the selected cache and retry remain visible.
    @Published private(set) var openingSessionID: String?
    @Published private(set) var isAttaching = false
    @Published private(set) var lastError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingEarlierHistory = false
    @Published private(set) var historyError: String?
    @Published private(set) var isOnline = false
    @Published private(set) var runningTurnId: String?
    @Published private(set) var permissionMode: RACPPermissionMode = .ask
    @Published private(set) var sessionMode: RACPSessionMode = .agent
    @Published private(set) var thinkingLevel: RACPThinkingLevel?
    @Published private(set) var selectedProviderId: String?
    @Published private(set) var selectedModelId: String?
    @Published private(set) var thinkingSupport = ThinkingLevelSupport(declared: [])
    /// 档位回落说明（AC-07.6）：非 nil 时界面必须展示。
    @Published private(set) var thinkingFallbackNotice: String?
    @Published private(set) var modelAvailability: SessionModelAvailability = .unknown(reason: "尚未检查")
    @Published private(set) var pendingAttachments: [RACPV2Attachment] = []
    @Published var draftText = "" {
        didSet { persistDraftIfNeeded() }
    }

    /// 由 `ConnectionModel` 注入：按 PI-adaptor/连接代次门控后写入离线缓存。
    var onDraftChanged: ((String, String, String?) -> Void)?
    /// Flush the outgoing session's coalesced cache before changing `attachedSessionId`.
    var onSessionWillChange: (() async -> Void)?

    /// 由 `ConnectionModel` 注入：按 provider id 读取本机 Keychain 里的 API key。
    ///
    /// 密钥不落服务器（keyStorage=client），发送时按当前 `selectedProviderId` 取 key
    /// 并作为 `turn/start.apiKey` 一次性透传。这里只保存取 key 的闭包，绝不缓存 key、
    /// 不写日志；读取失败返回 nil，由服务端以 `PROVIDER_SECRET_MISSING` 明确拒绝。
    var providerAPIKey: ((String) -> String?)?

    private var client: RACPClient?
    private var bindGeneration = 0
    private var attachedBindGeneration: Int?
    private var sessionSelectionGeneration = 0
    var attachmentSelectionGeneration: Int { sessionSelectionGeneration }
    private var configurationGeneration = 0
    private var attachTask: Task<Void, Never>?
    private var refreshTask: (id: UUID, bind: Int, selection: Int, task: Task<Void, Never>)?
    private var refreshRequested = false
    private var pendingUserEchoes: [PendingUserEcho] = []
    /// 最近一次仍在进行的打开请求目标；用于归档/删除时只取消自己的 pending attach。
    private var pendingAttachSessionId: String?
    private var historyLoadID: UUID?
    private var busyTokens: Set<UUID> = []
    private var attachmentUploads: Set<UUID> = []
    private var draftSessionID: String?
    private var isReplacingDraft = false
    private var modelAvailabilityCheck: (date: Date, binding: String, bind: Int, selection: Int)?
#if DEBUG
    private var fixtureInterruptionEnabled = false
    var beforeRefreshReadForTesting: (() async -> Void)?
#endif
    private let requestKeys: SessionRequestKeyStore
    private var attachedHostID: String?
    private var draftPreview: (text: String, key: String)?
#if DEBUG
    private var fixtureSnapshots: [String: RACPSessionView] = [:]
    private var fixtureHistoryModel: SessionViewModel?
    private var fixtureEarlierHistoryPages: [UITestEarlierHistoryPage] = []

    private var fixtureFailedOpenSessions: Set<String> = []
    func configureUITestSnapshots(_ snapshots: [String: RACPSessionView]) {
        guard client == nil, !snapshots.isEmpty else { return }
        fixtureSnapshots = snapshots
    }

    /// Explicitly invoked only by the opt-in stability UI fixture control. The
    /// normal Published items change drives the production grouping/follow path.
    func appendStabilityFixtureMessage() {
        guard client == nil, UITestFixture.stabilityControlsEnabled,
              let sessionID = attachedSessionId, sessionID == "S1",
              var snapshot = fixtureSnapshots[sessionID], view.sessionId == sessionID else { return }
        let ordinal = view.items.filter { $0.id.hasPrefix("stability-live-") }.count + 1
        let id = "stability-live-\(ordinal)"
        let item = RACPItem(id: id, payload: .object([
            "id": .string(id),
            "role": .string("assistant"),
            "text": .string("Stability appended \(ordinal)"),
        ]))
        view.items.append(item)
        snapshot.items = view.items
        fixtureSnapshots[sessionID] = snapshot
    }
#endif

    init(requestKeys: SessionRequestKeyStore = SessionRequestKeyStore(fileURL: SessionCacheStore.defaultRequestKeyURL())) {
        self.requestKeys = requestKeys
    }

    var queuedTurns: [QueuedTurn] { view.queuedTurns }
    var pendingApprovals: [RACPApprovalRequest] { view.pendingApprovals }
    var pendingInputs: [RACPInputRequest] { view.pendingInputs }
    var activeItems: [RACPItem] { view.activeItems }

    /// 发送准入：离线禁用；有 turn 在跑则排队（AC-13.1）。
    var sendAdmission: SendAdmission {
        TurnQueuePolicy.admission(
            online: isOnline && openingSessionID == nil,
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    var canSend: Bool {
        sendAdmission.isAllowed
            && (!trimmedDraft.isEmpty || !pendingAttachments.isEmpty)
            && modelAvailability.allowsSending
    }

    var canInterrupt: Bool {
        TurnQueuePolicy.canInterrupt(
            online: isOnline && openingSessionID == nil,
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    /// 没有模型目录时（本轮不提供模型服务管理）档位控件不出现（AC-07.7）。
    var showsThinkingControl: Bool { !thinkingSupport.declared.isEmpty }

    var isTurnRunning: Bool {
        TurnQueuePolicy.isRunning(
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    var selectedBindingKey: String {
        [
            selectedProviderId ?? "",
            selectedModelId ?? "",
            thinkingLevel?.rawValue ?? "",
        ].joined(separator: "\u{1F}")
    }

    var trimmedDraft: String { draftText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func prepareDraft(for sessionID: String) {
        guard draftSessionID != sessionID else { return }
        if let previousSessionID = draftSessionID {
            let normalized = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            onDraftChanged?(
                previousSessionID,
                normalized.isEmpty ? "" : draftText,
                normalized.isEmpty ? nil : draftPreview?.key
            )
        }
        isReplacingDraft = true
        draftText = ""
        draftPreview = nil
        draftSessionID = sessionID
        isReplacingDraft = false
    }

    private func persistDraftIfNeeded() {
        guard !isReplacingDraft,
              let sessionID = attachedSessionId,
              sessionID == draftSessionID
        else { return }
        let normalized = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            draftPreview = nil
            onDraftChanged?(sessionID, "", nil)
            return
        }
        if draftPreview?.text != normalized {
            draftPreview = (normalized, "draft_\(UUID().uuidString)")
        }
        onDraftChanged?(sessionID, draftText, draftPreview?.key)
    }

    // MARK: 生命周期

    /// 连接建立/断开时由 `ConnectionModel` 调用。
    func bind(client: RACPClient?, online: Bool) {
        bindGeneration &+= 1
        sessionSelectionGeneration &+= 1
        pendingUserEchoes.removeAll()
        cancelRefresh()
        resetHistoryLoad()
        attachTask?.cancel()
        attachTask = nil
        pendingAttachSessionId = nil
        openingSessionID = nil
        isAttaching = false
        modelAvailabilityCheck = nil
        self.client = client
        attachedHostID = nil
        draftSessionID = nil
        draftPreview = nil
        isOnline = online
        busyTokens.removeAll()
        attachmentUploads.removeAll()
        isBusy = false
        if client == nil {
            view = .empty
            attachedSessionId = nil
            attachedSummary = nil
            runningTurnId = nil
            selectedProviderId = nil
            selectedModelId = nil
            thinkingSupport = ThinkingLevelSupport(declared: [])
            thinkingLevel = nil
            modelAvailability = .unknown(reason: "尚未检查")
            pendingAttachments = []
        }
    }

    func setOnline(_ online: Bool) {
        isOnline = online
        if !online {
            resetHistoryLoad()
            modelAvailabilityCheck = nil
        }
    }

    /// Share event bursts, but drain a follow-up read requested during a read.
    /// Write-admission callers await the complete shared task, including that read.
    func refreshView(source: String = "caller") async {
        guard let client else { return }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        if let current = refreshTask, current.bind == generation, current.selection == selection {
            refreshRequested = true
            await current.task.value
            return
        }
        cancelRefresh()
        let id = UUID()
        refreshRequested = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let operation = PILogOperation("Session", "refresh", fields: "source=\(source) bind=\(generation) selection=\(selection)")
            var outcome = "superseded"
            defer {
                operation.finish(outcome: outcome, fields: "items=\(self.view.items.count)")
                if self.refreshTask?.id == id { self.refreshTask = nil; self.refreshRequested = false }
            }
            while self.refreshRequested && self.isCurrent(client, generation: generation, selection: selection) {
                self.refreshRequested = false
#if DEBUG
                await self.beforeRefreshReadForTesting?()
#endif
                guard self.isCurrent(client, generation: generation, selection: selection) else { return }
                let latest = await client.sessionView()
                let hostID = await client.info()?.hostId
                guard self.isCurrent(client, generation: generation, selection: selection) else {
                    outcome = Task.isCancelled ? "cancelled" : "superseded"
                    return
                }
                self.applyRefreshedView(latest, hostID: hostID)
                outcome = "success"
            }
        }
        refreshTask = (id, generation, selection, task)
        await task.value
    }

    private func cancelRefresh() {
        refreshTask?.task.cancel()
        refreshTask = nil
        refreshRequested = false
    }

    private func applyRefreshedView(_ latest: RACPSessionView, hostID: String?) {
        if attachedHostID != hostID {
            if attachedHostID != nil {
                sessionSelectionGeneration &+= 1
                resetHistoryLoad()
            }
            attachedHostID = hostID
            draftSessionID = nil
            if let sessionID = attachedSessionId { prepareDraft(for: sessionID) }
        }
        var next = latest
        next.items = Self.mergePendingUserEchoes(
            &pendingUserEchoes,
            into: latest.items,
            sessionID: latest.sessionId ?? attachedSessionId
        )
        if view != next { view = next }
        if runningTurnId != latest.runningTurnId { runningTurnId = latest.runningTurnId }
        if let summary = latest.summary {
            if attachedSummary != summary { attachedSummary = summary }
            if let mode = summary.mode, sessionMode != mode { sessionMode = mode }
            if let permission = summary.permissionMode, permissionMode != permission { permissionMode = permission }
        }
    }

    /// Synchronous feedback before navigation or the first cache/network await.
    func prepareToOpen(sessionId: String) {
        if isAttaching && pendingAttachSessionId == sessionId { return }
        if attachedBindGeneration == bindGeneration && openingSessionID == nil && attachedSessionId == sessionId && view.sessionId == sessionId { return }
        cancelPendingAttach()
        resetHistoryLoad()
        pendingAttachSessionId = sessionId
        openingSessionID = sessionId
        isAttaching = true
        lastError = nil
    }

    /// 打开会话：`session/attach` 拉快照并订阅。
    func attach(sessionId: String, source: String = "caller") async {
        if attachedBindGeneration == bindGeneration && openingSessionID == nil && attachedSessionId == sessionId && view.sessionId == sessionId {
            PILog.debug("Session", "attach skipped source=\(source) reason=alreadyAttached session=\(sessionId.prefix(8))")
            return
        }
        if pendingAttachSessionId == sessionId, let task = attachTask {
            PILog.debug("Session", "attach reused source=\(source) session=\(sessionId.prefix(8))")
            await task.value
            return
        }
        prepareToOpen(sessionId: sessionId)
        let selection = sessionSelectionGeneration
        let generation = bindGeneration
        // Register before the first await, including the outgoing cache barrier.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAttach(sessionId: sessionId, generation: generation, selection: selection, source: source)
        }
        attachTask = task
        await task.value
    }

    private func performAttach(sessionId: String, generation: Int, selection: Int, source: String) async {
        guard !Task.isCancelled, bindGeneration == generation, sessionSelectionGeneration == selection else { return }
        defer {
            if sessionSelectionGeneration == selection, bindGeneration == generation {
                isAttaching = false
                pendingAttachSessionId = nil
                attachTask = nil
            }
        }
        let operation = PILogOperation("Session", "attach", fields: "source=\(source) session=\(sessionId.prefix(8)) bind=\(generation) selection=\(selection)")
        PILog.info("Session", "attach start source=\(source) session=\(sessionId.prefix(8)) op=\(operation.id)")
        var outcome = "superseded"
        defer {
            operation.finish(outcome: outcome, fields: "items=\(view.items.count)")
            PILog.info("Session", "attach end source=\(source) session=\(sessionId.prefix(8)) op=\(operation.id) outcome=\(outcome) items=\(view.items.count) elapsedMs=\(operation.elapsedMilliseconds)")
        }
#if DEBUG
        if let snapshot = fixtureSnapshots[sessionId] {
            if let behavior = UITestFixture.current?.sessionOpenBehavior {
                try? await Task.sleep(for: .milliseconds(behavior.delayMilliseconds))
                guard !Task.isCancelled, sessionSelectionGeneration == selection,
                      bindGeneration == generation else { return }
                if behavior.failingSessionID == sessionId, fixtureFailedOpenSessions.insert(sessionId).inserted {
                    lastError = "会话同步失败，请重试"
                    outcome = "failed"
                    return
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
                fixtureHistoryModel = Self.makeFixtureHistoryModel(from: snapshot)
                fixtureEarlierHistoryPages = pages
            } else {
                fixtureHistoryModel = nil
                fixtureEarlierHistoryPages = []
            }
            outcome = "success"
            return
        }
#endif
        guard client != nil else {
            lastError = "隧道未连接：无法打开会话"
            outcome = "failed"
            return
        }
        // Selection was invalidated synchronously before navigation.
        // A newer tap supersedes the in-flight attach immediately. Waiting for the
        // old attach's history assembly made switching sessions look unresponsive
        // for 10–30s on long histories; `RACPClient` invalidates the stale attach
        // by generation, so its late result cannot overwrite the new candidate.
        await onSessionWillChange?()
        guard self.bindGeneration == generation,
              self.sessionSelectionGeneration == selection,
              self.client != nil
        else { return }
        guard let client else { return }
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            try await client.attach(sessionId: sessionId)
            guard isCurrent(client, generation: generation, selection: selection) else {
                outcome = Task.isCancelled ? "cancelled" : "superseded"
                return
            }
            if attachedSessionId != sessionId {
                pendingAttachments = []
                attachmentUploads.removeAll()
            }
            attachedSessionId = sessionId
            modelAvailability = .checking
            await refreshView(source: "attach")
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            prepareDraft(for: sessionId)
            lastError = nil
            openingSessionID = nil
            attachedBindGeneration = generation
            outcome = "success"
        } catch {
            let message = ConnectionErrorText.describe(error)
            outcome = Task.isCancelled ? "cancelled" : "failed"
            PILog.warn("Session", "attach failed op=\(operation.id) session=\(sessionId.prefix(8)) error=\(message)")
            guard isCurrent(client, generation: generation, selection: selection) else {
                outcome = Task.isCancelled ? "cancelled" : "superseded"
                return
            }
            lastError = message
        }
    }

    /// 只读历史加载独立于发送/配置的 busy 状态；失败不会断开隧道或覆盖连接错误。
    @discardableResult
    func loadEarlierHistory() async -> Bool {
#if DEBUG
        if client == nil,
           isOnline,
           !isBusy,
           !isLoadingEarlierHistory,
           view.hasMoreHistory,
           let sessionID = attachedSessionId,
           view.sessionId == sessionID {
            return await loadFixtureEarlierHistory(sessionID: sessionID)
        }
#endif
        guard isOnline, !isBusy, !isLoadingEarlierHistory, view.hasMoreHistory,
              let sessionID = attachedSessionId, view.sessionId == sessionID,
              let client else { return false }
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
        do {
            let inserted = try await client.loadEarlierHistory()
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionID, historyLoadID == loadID else { return false }
            await refreshView()
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionID, historyLoadID == loadID else { return false }
            return inserted > 0
        } catch is CancellationError {
            return false
        } catch {
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionID, historyLoadID == loadID else { return false }
            historyError = ConnectionErrorText.describe(error)
            return false
        }
    }

#if DEBUG
    /// Test-only page loader. It follows the same loading/lifecycle gate as the
    /// client path, stages pages until the earliest turn has its task boundary,
    /// then performs one reducer prepend and one Published view assignment.
    private func loadFixtureEarlierHistory(sessionID: String) async -> Bool {
        guard let model = fixtureHistoryModel, !fixtureEarlierHistoryPages.isEmpty else {
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
            guard !fixtureEarlierHistoryPages.isEmpty else {
                // A malformed fixture must not expose its staged partial turn.
                historyError = "测试历史缺少完整任务起点"
                return false
            }
            let page = fixtureEarlierHistoryPages[0]
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
                  fixtureHistoryModel === model
            else { return false }
            fixtureEarlierHistoryPages.removeFirst()
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
              fixtureHistoryModel === model
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
                pendingInputs: snapshot.pendingInputs,
                hasMoreHistory: snapshot.hasMoreHistory
            ),
            replayComplete: snapshot.replayComplete
        )
        return model
    }
#endif

    private func resetHistoryLoad() {
        historyLoadID = nil
        isLoadingEarlierHistory = false
        historyError = nil
    }

    /// 只取消仍在进行的打开请求，保留当前已附着会话；成功归档/删除时用于阻止迟到导航。
    /// Also matches a failed preview retained for retry.
    func cancelPendingAttach(for sessionID: String? = nil) {
        if let sessionID, pendingAttachSessionId != sessionID, openingSessionID != sessionID { return }
        sessionSelectionGeneration &+= 1
        cancelRefresh()
        attachTask?.cancel()
        attachTask = nil
        pendingAttachSessionId = nil
        openingSessionID = nil
        isAttaching = false
    }

    func detach() {
        // 日志：关闭会话（只记会话短 ID 与消息数）。
        PILog.info("Session", "detach session=\(attachedSessionId.map { String($0.prefix(8)) } ?? "-") items=\(view.items.count)")
        sessionSelectionGeneration &+= 1
        pendingUserEchoes.removeAll()
        cancelRefresh()
        resetHistoryLoad()
        attachTask?.cancel()
        attachTask = nil
        pendingAttachSessionId = nil
        openingSessionID = nil
        isAttaching = false
        modelAvailabilityCheck = nil
        busyTokens.removeAll()
        attachmentUploads.removeAll()
        isBusy = false
        attachedSessionId = nil
        attachedSummary = nil
        view = .empty
        runningTurnId = nil
        selectedProviderId = nil
        selectedModelId = nil
        thinkingSupport = ThinkingLevelSupport(declared: [])
        thinkingLevel = nil
        modelAvailability = .unknown(reason: "尚未打开会话")
        pendingAttachments = []
    }

    // MARK: 发送（AC-08 / AC-13.1）

    /// 上传一张图片。返回 false 表示没有进入待发送附件（无会话、超限或上传失败），
    /// 调用方必须把它计入失败集合，不能假定附件已就绪。
    @discardableResult
    func addImage(data: Data, mimeType: String, fileName: String) async -> Bool {
        guard let sessionId = attachedSessionId, let client else {
            lastError = "还没有打开会话"
            return false
        }
        guard pendingAttachments.count + attachmentUploads.count < 10 else {
            lastError = "每条消息最多 10 张图片"
            return false
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let uploadID = UUID()
        attachmentUploads.insert(uploadID)
        defer { attachmentUploads.remove(uploadID) }
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let attachment = try await client.uploadImage(
                sessionId: sessionId,
                data: data,
                mimeType: mimeType,
                fileName: fileName
            )
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId else { return false }
            pendingAttachments.append(attachment)
            lastError = nil
            return true
        } catch {
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId else { return false }
            lastError = ConnectionErrorText.describe(error)
            return false
        }
    }

    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// 点击发送时冻结的当前发送意图（U11）。必须在模型可用性检查之前调用，
    /// 之后把返回值原样传给 `send(expected:)`；发送任务只认这份冻结值。
    func makeSendIntent() -> SendIntent? {
        guard let state = currentSendState() else { return nil }
        return SendIntent(
            hostID: state.hostID,
            sessionID: state.sessionID,
            bindingKey: state.bindingKey,
            draftText: state.draftText,
            attachmentIDs: state.attachmentIDs,
            selectionGeneration: state.selectionGeneration
        )
    }

    /// 发送一条消息。
    ///
    /// `expected` 非空时，入口与 `refreshView()` 之后都会核对当前会话/服务器/模型绑定/
    /// 草稿/附件是否仍属于点击时冻结的意图；不匹配就取消本次发送并保留草稿，
    /// 绝不把另一会话的内容当成这次点击发出去（U11）。成功后也只有当前状态仍属于
    /// 原意图时才清草稿，提交期间的新编辑不会被旧任务清掉。
    func send(expected intent: SendIntent? = nil) async {
        guard intentIsCurrent(intent) else {
            notice = "会话、模型或草稿已变化：本次发送已取消，草稿已保留"
            return
        }
        guard let sessionId = attachedSessionId else {
            lastError = "还没有打开会话"
            return
        }
        guard !isBusy else {
            lastError = "上一条写入请求仍在处理中，请稍后重试"
            return
        }
        let text = trimmedDraft
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard sendAdmission.isAllowed else {
            lastError = "隧道未连接：现在发送会失败，已阻止"
            return
        }
        guard modelAvailability.allowsSending else {
            lastError = modelAvailability.displayText ?? "当前模型不可用，请重新选择模型"
            return
        }
#if DEBUG
        if client == nil, let delay = UITestFixture.current?.submissionFailureDelayMilliseconds {
            let generation = bindGeneration
            let selection = sessionSelectionGeneration
            let busy = beginBusy()
            defer { endBusy(busy) }
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, generation == bindGeneration,
                  selection == sessionSelectionGeneration else { return }
            modelAvailabilityCheck = nil
            lastError = "测试连接发送失败，草稿已保留"
            return
        }
#endif
        guard let client else {
            lastError = "隧道未连接"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              trimmedDraft == text,
              let hostID = currentRequestHostID()
        else { return }
        guard intentIsCurrent(intent) else {
            notice = "会话、模型或草稿已变化：本次发送已取消，草稿已保留"
            return
        }
        do {
            let attachmentIDs = pendingAttachments.map(\.id)
            let action: SessionRequestAction = attachmentIDs.isEmpty
                ? .turn(text: text)
                : .turnAttachments(text: text, attachmentIds: attachmentIDs)
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, action: action),
                admission: sendAdmission.turnAdmission
            )
            draftPreview = (text, attempt.idempotencyKey)
            onDraftChanged?(sessionId, draftText, attempt.idempotencyKey)
            // 密钥只从本机 Keychain 取一次并随这次请求透传；不缓存、不写日志。
            // 排查「key 是否同步」时只记录有无（present/absent），绝不记录明文。
            let apiKey = selectedProviderId.flatMap { providerAPIKey?($0) }
            PILog.debug(
                "Model",
                "turn/start provider=\(String((selectedProviderId ?? "-").prefix(8)))"
                    + " apiKey=\(apiKey == nil ? "absent" : "present")"
            )
            let result = try await client.startTurn(
                sessionId: sessionId,
                text: text,
                attachments: attachmentIDs,
                admission: attempt.admission,
                idempotencyKey: attempt.idempotencyKey,
                apiKey: apiKey
            )
            PILog.debug(
                "Model",
                "turn/start ok turn=\(result.turn.id.prefix(8)) status=\(result.turn.status ?? "-")"
            )
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            let echo = PendingUserEcho(
                id: "local-user-\(result.turn.id)",
                sessionID: sessionId,
                turnID: result.turn.id,
                text: text.isEmpty ? "已发送 \(attachmentIDs.count) 个附件" : text,
                baselineItemIDs: Set(view.items.map(\.id)),
                anchorItemID: view.items.last?.id
            )
            pendingUserEchoes.removeAll { $0.id == echo.id }
            pendingUserEchoes.append(echo)
            var optimistic = view
            optimistic.items = Self.mergePendingUserEchoes(
                &pendingUserEchoes,
                into: view.items,
                sessionID: sessionId
            )
            if optimistic != view { view = optimistic }
            PILog.debug("Session", "local echo added turn=\(echo.turnID.prefix(8)) items=\(view.items.count)")
            runningTurnId = await client.sessionView().runningTurnId
            if intentIsCurrent(intent),
               trimmedDraft == text,
               draftPreview?.key == attempt.idempotencyKey {
                draftText = ""
                draftPreview = nil
                pendingAttachments = []
            }
            notice = attempt.admission == nil
                ? nil
                : "已排队：当前 turn 结束后自动开始（\(result.turn.id)）"
            lastError = nil
            await refreshView()
        } catch {
            // 保留草稿与幂等键：重试必须复用同一个键，否则服务器会当成第二条指令。
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
            modelAvailabilityCheck = nil
        }
    }

    /// 当前发送状态的快照，用于冻结/核对 `SendIntent`。
    private struct SendState {
        let hostID: String
        let sessionID: String
        let bindingKey: String
        let draftText: String
        let attachmentIDs: [String]
        let selectionGeneration: Int
    }

    private func currentSendState() -> SendState? {
        guard let sessionID = attachedSessionId else { return nil }
        return SendState(
            hostID: attachedHostID ?? "",
            sessionID: sessionID,
            bindingKey: selectedBindingKey,
            draftText: trimmedDraft,
            attachmentIDs: pendingAttachments.map(\.id),
            selectionGeneration: sessionSelectionGeneration
        )
    }

    /// `intent == nil` 表示调用方不冻结意图（内部兼容路径）；否则逐项核对。
    private func intentIsCurrent(_ intent: SendIntent?) -> Bool {
        guard let intent else { return true }
        guard let state = currentSendState() else { return false }
        return intent.matches(
            hostID: state.hostID,
            sessionID: state.sessionID,
            bindingKey: state.bindingKey,
            draftText: state.draftText,
            attachmentIDs: state.attachmentIDs,
            selectionGeneration: state.selectionGeneration
        )
    }

    // MARK: 中止 / 取消排队（AC-09.1 / AC-13.2）

#if DEBUG
    func configureUITestInterruption(enabled: Bool) {
        fixtureInterruptionEnabled = enabled
    }
#endif

    func interrupt() async {
        guard isOnline else {
            lastError = "隧道未连接：无法中止当前 turn"
            return
        }
#if DEBUG
        if fixtureInterruptionEnabled, let turnId = runningTurnId {
            let generation = bindGeneration
            let selection = sessionSelectionGeneration
            let busy = beginBusy()
            defer { endBusy(busy) }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard bindGeneration == generation,
                  sessionSelectionGeneration == selection,
                  self.runningTurnId == turnId
            else { return }
            self.runningTurnId = nil
            self.view.activeItems = []
            notice = "已中止"
            lastError = nil
            return
        }
#endif
        guard let client, let sessionId = attachedSessionId else {
            lastError = "没有正在运行的 turn"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            var turnId = runningTurnId
            do {
                // A queued turn promoted by the PI-adaptor has no local start response.
                // Resolve the authoritative active id immediately before interrupting.
                _ = try await client.getSession(id: sessionId)
                guard isCurrent(client, generation: generation, selection: selection),
                      attachedSessionId == sessionId
                else { return }
                turnId = await client.sessionView().runningTurnId
                runningTurnId = turnId
            } catch {
                // Preserve the last known id only when it exists; the interrupt
                // request will still surface the underlying transport error.
                guard turnId != nil else { throw error }
            }
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId
            else { return }
            guard let turnId else {
                lastError = "没有正在运行的 turn"
                return
            }
            try await client.interruptTurn(turnId: turnId)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            if runningTurnId == turnId {
                runningTurnId = nil
                view.activeItems = []
            }
            notice = "已中止"
            lastError = nil
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    func cancelQueued(turnId: String) async {
        guard isOnline else {
            lastError = "隧道未连接：无法取消排队项"
            return
        }
        guard let client else {
            lastError = "隧道未连接"
            return
        }
        guard TurnQueuePolicy.canCancel(queued: queuedTurns, id: turnId) else {
            lastError = "该排队项已不在队列里"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            try await client.cancelTurn(turnId: turnId)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            notice = "已取消排队项"
            await refreshView()
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    // MARK: 审批 / 提问（AC-10 / AC-11 / AC-12）

    func availability(for approvalId: String) -> DecisionAvailability {
        DecisionPolicy.approvalAvailability(
            id: approvalId,
            pending: pendingApprovals,
            expiredIds: view.expiredApprovalIds
        )
    }

    /// 判断这张卡是工具审批还是 Plan/Goal 契约（按卡片 `kind` 读，读不到按工具审批处理）。
    static func isContract(_ card: RACPApprovalRequest) -> Bool {
        let kind = card.payload.value(at: ["kind"])?.stringValue?.lowercased() ?? ""
        return kind.contains("plan") || kind.contains("goal") || kind.contains("contract")
    }

    func decide(approvalId: String, decision: RACPApprovalDecision) async {
        await respondApproval(approvalId: approvalId) { _ in
            .approval(decision: decision, permissionMode: decision == .allowSession ? self.permissionMode : nil)
        }
    }

    func decideContract(approvalId: String, decision: RACPContractDecision) async {
        await respondApproval(approvalId: approvalId) { card in
            try DecisionPolicy.contractAction(for: card, decision: decision, currentMode: self.permissionMode)
        }
    }

    private func respondApproval(
        approvalId: String,
        action makeAction: (RACPApprovalRequest) throws -> SessionRequestAction
    ) async {
        guard isOnline, let client else {
            lastError = "隧道未连接：审批现在提交会失败，已阻止"
            return
        }
        guard !isBusy else { return }
        let busy = beginBusy()
        defer { endBusy(busy) }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              let sessionId = attachedSessionId,
              let hostID = currentRequestHostID()
        else { return }
        let availability = availability(for: approvalId)
        guard case let .actionable(cardRevision) = availability, let revision = cardRevision else {
            lastError = availability.statusText ?? "未取得审批版本：请刷新后重试"
            return
        }
        do {
            guard let card = pendingApprovals.first(where: { $0.id == approvalId }) else { return }
            let action = try makeAction(card)
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, itemID: approvalId, action: action)
            )
            let params = try RACPApprovalRespondParams(
                approvalId: approvalId, action: action,
                context: RACPContext(requestId: "req_\(UUID().uuidString)", idempotencyKey: attempt.idempotencyKey, expectedRevision: revision)
            )
            let result: JSONValue = try await client.request(.approvalRespond, params: params)
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            let alreadyResolved = result.value(at: ["alreadyResolved"])?.boolValue ?? false
            notice = alreadyResolved ? "该审批已被处理过，未重复执行" : "已提交审批结果"
            lastError = nil
            await refreshView()
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            if let code = Self.serverCode(from: error), DecisionPolicy.marksCardStale(after: code) {
                await client.markApprovalExpired(id: approvalId)
                await refreshView()
                lastError = "该审批已失效：\(code.userMessage)"
            } else {
                lastError = ConnectionErrorText.describe(error)
            }
            await refreshView()
        }
    }

    /// 回答 AskTool 提问；`answers` 顺序必须与该卡问题顺序对齐（AC-11.1）。
    ///
    /// 返回结构化结果供界面决定是否清空已选答案（U06）：只有成功或明确失效才清，
    /// 普通失败必须保留用户的选择。失败重试复用 `requestKeys` 里已持久化的幂等键，
    /// 不会把同一条回答当第二条提交。
    @discardableResult
    func answer(inputId: String, answers: [[String]?]) async -> InputAnswerOutcome {
        guard isOnline, let client else {
            let reason = "隧道未连接：回答现在提交会失败，已阻止"
            lastError = reason
            return .failed(reason: reason)
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              let sessionId = attachedSessionId,
              let hostID = currentRequestHostID()
        else {
            // 会话已切换或身份已变化：提交结果未知，保留草稿让用户重试。
            return .failed(reason: lastError ?? "会话已切换：请重新提交回答")
        }
        let availability = DecisionPolicy.inputAvailability(id: inputId, pending: pendingInputs)
        guard case let .actionable(cardRevision) = availability, let revision = cardRevision else {
            if case .missing = availability {
                let reason = "该提问已由其他端处理或不存在：请刷新后重试"
                lastError = reason
                await refreshView()
                return .noLongerActionable(reason: reason)
            }
            let reason = "该提问缺少版本：请刷新后重试"
            lastError = reason
            return .failed(reason: reason)
        }
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, itemID: inputId, action: .input(answers: answers))
            )
            _ = try await client.respondInput(
                inputId: inputId,
                answers: answers,
                expectedRevision: revision,
                idempotencyKey: attempt.idempotencyKey
            )
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else {
                // 服务器已受理；界面可以按作用域清掉这张卡的选择。
                return .submitted
            }
            notice = "已回答提问"
            lastError = nil
            await refreshView()
            return .submitted
        } catch {
            let described = ConnectionErrorText.describe(error)
            guard isCurrent(client, generation: generation, selection: selection) else {
                lastError = described
                return .failed(reason: described)
            }
            await refreshView()
            // 刷新后卡片消失 = 其他端已经回答/卡片失效；否则按错误码分诊。
            let stillPending = pendingInputs.contains { $0.id == inputId }
            let outcome = AnswerDraftPolicy.outcomeAfterFailure(
                serverCode: Self.serverCode(from: error),
                cardStillPending: stillPending,
                reason: described
            )
            lastError = outcome.reason ?? described
            await refreshView()
            return outcome
        }
    }

    // MARK: 配置（AC-07）

    /// 切换会话模式/权限模式/档位；运行中的 turn 不允许改模型（AC-07.2）。
    func configure(
        mode: RACPSessionMode? = nil,
        permissionMode: RACPPermissionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel requested: RACPThinkingLevel? = nil,
        thinkingSupport support: ThinkingLevelSupport? = nil
    ) async {
        guard isOnline else {
            lastError = "隧道未连接：配置未提交"
            return
        }
        guard let client, let sessionId = attachedSessionId else {
            lastError = "还没有打开会话"
            return
        }
        guard !isBusy else {
            lastError = "上一项操作仍在进行：请稍候再提交配置"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        guard !TurnQueuePolicy.isRunning(activeItemCount: view.activeItems.count, runningTurnId: runningTurnId) else {
            lastError = "当前轮次仍在运行：等它结束再切换模型或档位"
            return
        }
        let changesModel = providerId != nil || modelId != nil
        let nextSupport = support ?? thinkingSupport
        let currentThinkingLevel = thinkingLevel
        let resolution: ThinkingLevelResolution
        if changesModel || requested != nil {
            resolution = ThinkingLevelPolicy.resolve(current: requested ?? currentThinkingLevel, support: nextSupport)
        } else {
            resolution = ThinkingLevelResolution(
                level: thinkingLevel,
                didFallback: false,
                fallbackSource: nil
            )
        }
        configurationGeneration &+= 1
        let configGeneration = configurationGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let summary = try await client.configureSession(
                sessionId: sessionId,
                mode: mode,
                permissionMode: permissionMode,
                providerId: providerId,
                modelId: modelId,
                thinkingLevel: resolution.level
            )
            guard configGeneration == configurationGeneration,
                  isCurrent(client, generation: generation, selection: selection)
            else { return }
            attachedSummary = summary
            if let newMode = summary.mode { sessionMode = newMode }
            if let newPermission = summary.permissionMode { self.permissionMode = newPermission }
            thinkingLevel = resolution.level
            if let providerId { selectedProviderId = providerId }
            if let modelId { selectedModelId = modelId }
            if support != nil { thinkingSupport = nextSupport }
            if changesModel { modelAvailability = .checking }
            thinkingFallbackNotice = resolution.didFallback
                ? ThinkingLevelPolicy.fallbackExplanation(
                    from: currentThinkingLevel,
                    to: resolution.level,
                    fallbackSource: resolution.fallbackSource
                )
                : nil
            notice = "会话配置已更新"
            lastError = nil
        } catch {
            guard configGeneration == configurationGeneration,
                  isCurrent(client, generation: generation, selection: selection)
            else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    // MARK: 错误分类

    static func serverCode(from error: Error) -> RACPErrorCode? {
        if case let RACPClientError.server(code, _) = error { return code }
        return nil
    }

    private func currentRequestHostID() -> String? {
        guard isOnline, let hostID = attachedHostID, !hostID.isEmpty else {
            lastError = "未确认在线 PI-adaptor 身份：请重新连接后重试"
            return nil
        }
        return hostID
    }

    private func isCurrent(
        _ client: RACPClient,
        generation: Int,
        selection: Int
    ) -> Bool {
        self.client === client
            && bindGeneration == generation
            && sessionSelectionGeneration == selection
    }

    private func beginBusy() -> UUID {
        let token = UUID()
        busyTokens.insert(token)
        isBusy = true
        return token
    }

    private func endBusy(_ token: UUID) {
        busyTokens.remove(token)
        isBusy = !busyTokens.isEmpty
    }

    func clearError() { lastError = nil }
    func clearNotice() { notice = nil }

    func applyModelAvailability(_ status: ProviderBindingStatus) {
        if let providerId = status.pinnedProviderId {
            selectedProviderId = providerId
        }
        if let modelId = status.pinnedModelId {
            selectedModelId = modelId
        }
        if let rawLevel = status.pinnedThinkingLevel {
            thinkingLevel = RACPThinkingLevel(rawValue: rawLevel)
        }
        if status.available == true {
            modelAvailabilityCheck = (Date(), selectedBindingKey, bindGeneration, sessionSelectionGeneration)
            modelAvailability = .available
            return
        }
        let reason = Self.availabilityReason(status.unavailableReason)
        if status.available == false {
            modelAvailability = .unavailable(reason: reason)
        } else {
            modelAvailability = .unknown(reason: reason)
        }
    }

    func hasRecentModelAvailability(now: Date = Date()) -> Bool {
        guard modelAvailability == .available, openingSessionID == nil,
              let check = modelAvailabilityCheck,
              check.binding == selectedBindingKey,
              check.bind == bindGeneration,
              check.selection == sessionSelectionGeneration else { return false }
        let age = now.timeIntervalSince(check.date)
        return age >= 0 && age < 30
    }

    func markModelAvailabilityUnknown(_ reason: String) {
        modelAvailability = .unknown(reason: reason)
    }

    /// Mark the current model as known-unavailable with a reason the caller
    /// derived (e.g. the provider exists only in the legacy store), so the UI
    /// can show why sending is blocked and how to fix it.
    func markModelUnavailable(_ reason: String) {
        modelAvailability = .unavailable(reason: reason)
    }

    func markModelAvailabilityChecking() {
        modelAvailability = .checking
    }

    private static func availabilityReason(_ value: String?) -> String {
        switch value {
        case "provider_missing": return "模型服务不存在"
        case "provider_disabled": return "模型服务已禁用"
        case "models_empty": return "模型服务没有模型"
        case "model_removed": return "所选模型已被移除"
        case "secret_missing": return "模型服务缺少密钥"
        case "oauth_unsupported": return "不支持订阅账号型模型服务"
        case "no_candidate": return "没有可用的模型服务"
        default: return "请重新检查或选择其他模型"
        }
    }
    /// Merge optimistic user items into a server snapshot. The snapshot stays
    /// authoritative: once it carries the same user message, the local copy is
    /// removed rather than shown twice.
    static func mergePendingUserEchoes(
        _ pending: inout [PendingUserEcho],
        into items: [RACPItem],
        sessionID: String?
    ) -> [RACPItem] {
        guard let sessionID else { return items }
        let matched = pending.filter { $0.sessionID == sessionID && $0.isEchoed(in: items) }
        if !matched.isEmpty {
            pending.removeAll { echo in matched.contains(echo) }
            for echo in matched {
                PILog.debug("Session", "local echo matched turn=\(echo.turnID.prefix(8))")
            }
        }
        var merged = items
        var ids = Set(items.map(\.id))
        for echo in pending where echo.sessionID == sessionID && !ids.contains(echo.id) {
            merged = echo.inserted(into: merged)
            ids.insert(echo.id)
        }
        return merged
    }

}
