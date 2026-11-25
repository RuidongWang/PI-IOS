import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import CoreTransferable
import ImageIO
import PIiOSCore
import PIiOSNet
#if DEBUG
import CryptoKit

/// Only IDs enter this probe: no message text, tool output or image bytes.
enum ConversationStabilityIdentity {
    static func digest(orderedItemIDs: [String]) -> String {
        SHA256.hash(data: Data(orderedItemIDs.joined(separator: "\n").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

/// Latest frame geometry for synchronous restore confirmation. Kept as an
/// unobserved reference so scrolling does not schedule another SwiftUI render.
final class ConversationFrameSnapshot {
    var contextKey: String?
    var frames: [String: CGRect] = [:]
}

/// S-02 会话（根）。
///
/// 线程、审批、提问、排队与中止都走真实的 RACP 调用；离线时只显示本机缓存并标注可能不是最新。
/// 没有向量（vector）能力：不渲染示例对话，也不在缺数据时假装有内容。
struct ConversationScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connection: ConnectionModel
    @ObservedObject var session: SessionController

    @State var showingConfig = false
    @State var showingRename = false
    @State var renameDraft = ""
    @State var isNearBottom = true
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var hasNewBelow = false
    @State var scrollToBottomRequest = 0
    @State var modelAvailabilityGeneration = 0
    @State var submissionID: UUID?
    var isSubmitting: Bool { submissionID != nil }
    @State var automaticFollowTask: Task<Void, Never>?
    @State var automaticFollowID: UUID?
    @State var isDraggingThread = false
    @State var previewWindowLimit = 80
    @State var topVisibleItemID: String?
    @State var lastMeasuredTopItemID: String?
    @State var readingRestoreTargetItemID: String?
    @State var readingRestoreRequestID = 0
    @State var activeReadingHostID: UUID?
    @State var activeReadingSessionID: String?
    @State var isRestoringReadingPosition = false
    @State var newMessagesDuringRestore = false
    @State var restoreBaselineReady = false
    @State var restoreBaselineCount = 0
    @State var restoreBaselineLastItemID: String?
    @State var readingRestoreGeneration = 0
    @State var historyPagingID: UUID?
    @State var historyPagingCancelled = false
    @State var historyPositionRestoreID: UUID?
    @State var historyReadingAnchorID: String?
    @State var viewportMeasurement = ConversationViewportMeasurement()
    @State var frameSnapshot = ConversationFrameSnapshot()
    @State var rowIndex: ConversationRowIndex
    /// Programmatic scroll target. `ScrollViewReader.scrollTo` cannot reach a
    /// `LazyVStack` row that has never been laid out, so restore/paging pin the
    /// anchor through `scrollPosition` first; the UIKit anchor then corrects the
    /// exact pixel offset once that row exists.
    @State var scrollPositionID: String?
#if DEBUG
    @State var activeAnchorCount = 0
    @State var measuredTopY: CGFloat = 0
    @State var debugItemIdentity = ""
    @State var debugLastRowFrame = "unmeasured"
    @State var debugBottomDistance: CGFloat = 0
#endif
    @State var readingRestoreFailed = false
    @State var readingRestoreRetryAvailable = false
    @State var readingRestoreRetryNonce = 0
    /// A prepend that could not be pixel-compensated keeps this logical anchor
    /// authoritative until the user scrolls or a later correction applies.
    @State var readingPositionHoldAnchorID: String?
    @State var approvalFullInput: ApprovalFullInput?
    @State var reviewedApprovalDigests: [String: (revision: Int?, digest: String)] = [:]
    /// 选图批次的读取/上传仍在进行时禁止发送，避免用户看不到尚未完成的图片。
    @State var isReadingPhotos = false
    @State var photoReadCompletedCount = 0
    @State var photoReadTotalCount = 0
    @State var selectedPhotos: [PhotosPickerItem] = []
    @State var photoSelectionID = UUID()
    /// U16：最近一次选图的读取失败数 / 成功读取数 / 部分失败是否已确认发送子集。
    @State var photoReadFailureCount = 0
    @State var photoReadSucceededCount = 0
    @State var photoReadAcknowledged = false

    init(session: SessionController) {
        self.session = session
        _rowIndex = State(initialValue: ConversationRowIndex(items: session.view.items))
#if DEBUG
        _debugItemIdentity = State(initialValue: ConversationStabilityIdentity.digest(orderedItemIDs: session.view.items.map(\.id)))
#endif
    }

    var currentHost: HostRecord? { model.currentHost }

    var historyTextLoader: @MainActor (RACPItem) async -> String? {
        let selection = session.attachmentSelectionGeneration
        return { item in
            guard session.attachmentSelectionGeneration == selection else { return nil }
            return await session.copyableHistoryText(for: item)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                // 页头或状态条只保留一条底部分隔，避免相邻 Divider 与自定义描边叠成双线。
                if statusLines.isEmpty { Divider() }
                // 常驻状态条：运行中 / 排队 / 最近一次操作结果。
                // 这些状态不能只活在被自动滚动带走的线程里——用户从别处回来，
                // 第一眼要看到「现在什么状态、要不要我动手」。
                sessionStatusStrip
                readingRestoreRetryStrip
                // 待审批卡片固定在滚动区之上，不随会话滚动：它是「工具正在等你的决定」的
                // 唯一入口，放进滚动内容时会被自动滚到底部的逻辑顶出视口（长历史下差上千点），
                // 用户看不到卡片就只能中止，表现为「工具一直在执行中」。
                if connection.state.isOnline,
                   session.attachedSessionId != nil,
                   session.openingSessionID == nil,
                   !session.pendingApprovals.isEmpty {
                    ScrollView {
                        approvalSection
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s8)
                    }
                    .frame(maxHeight: 260)
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityElement(children: .contain)
                    .piOptionalIdentifier(
                        session.pendingApprovals.count > 1 ? "conversation.pendingApprovalsNotice" : nil
                    )
                    Divider()
                }
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: PISpacing.s16) {
                                if let target = session.openingSessionID {
                                    openingThread(sessionID: target, proxy: proxy)
                                } else {
                                    statusArea
                                    if connection.state.isOnline, session.attachedSessionId != nil {
                                        queueSection
                                        threadSection(proxy: proxy)
                                    } else if !connection.state.isOnline, let sessionId = cachedSessionId {
                                        offlineThread(sessionId: sessionId)
                                    }
                                }
                                Color.clear.frame(height: 1).id("thread-bottom")
                            }
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s16)
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: ConversationContentBottomKey.self,
                                        value: content.frame(in: .named("conversation-scroll")).maxY
                                    )
                                }
                            }
                        }
                        .coordinateSpace(name: "conversation-scroll")
                        .accessibilityIdentifier("conversation.timeline")
                        .scrollPosition(id: trackedScrollPosition, anchor: .top)
                        .scrollDismissesKeyboard(.immediately)
                        // 点消息区任意空白处收起键盘；输入框在滚动区之外，不受影响。
                        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                        .id(readingContextKey ?? "unbound-reading-context")
                        .transaction { transaction in
                            if isRestoringReadingPosition || historyPagingID != nil {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 2).onChanged { _ in
                                isDraggingThread = true
                                automaticFollowTask?.cancel()
                                automaticFollowTask = nil
                                cancelHistoryPaging()
                                cancelReadingPositionRestore()
                            }.onEnded { _ in isDraggingThread = false }
                        )
                        .onPreferenceChange(ConversationContentBottomKey.self) { contentBottom in
                            let distance = contentBottom - viewport.size.height
#if DEBUG
                            debugBottomDistance = distance
#endif
                            let near = distance <= 96
                            let changed = isNearBottom != near
                            if near {
                                hasNewBelow = false
                            }
                            isNearBottom = near
                            if changed {
                                recordReadingPosition()
                            }
                        }
                        .onPreferenceChange(ConversationItemFrameKey.self) { frames in
                            frameSnapshot.contextKey = readingContextKey
                            frameSnapshot.frames = frames
                            let viewportBottom = viewport.size.height
                            let visibleItemID = ConversationViewportGeometry.firstVisibleItemID(
                                frames: frames, viewportBottom: viewportBottom
                            )
                            lastMeasuredTopItemID = visibleItemID
#if DEBUG
                            measuredTopY = visibleItemID.flatMap { frames[$0]?.minY } ?? 0
                            activeAnchorCount = viewportMeasurement.activeAnchorCount
                            if let lastID = session.view.items.last?.id {
                                let anchor = rowIndex.anchorItemID(for: lastID)
                                let frame = frames[anchor].map { "minY=\($0.minY),maxY=\($0.maxY)" } ?? "missing"
                                debugLastRowFrame = "last=\(lastID),anchor=\(anchor),frame=\(frame)"
                            } else {
                                debugLastRowFrame = "empty"
                            }
#endif

                            if isRestoringReadingPosition {
                                confirmReadingRestoreIfAligned(in: frames)
                                return
                            }

                            if let lastItemID = session.view.items.last?.id {
                                let lastAnchor = rowIndex.anchorItemID(for: lastItemID)
                                let lastFrame = frames[lastAnchor]
                                let near = lastFrame.map {
                                    $0.maxY > 0 && $0.minY <= viewportBottom + 96
                                } ?? false
                                if isNearBottom != near {
                                    isNearBottom = near
                                    if near { hasNewBelow = false }
                                    recordReadingPosition()
                                }
                            }
                            guard let visibleItemID,
                                  visibleItemID != topVisibleItemID
                            else { return }
                            topVisibleItemID = visibleItemID
                            recordReadingPosition()
                        }
                        .onChange(of: session.view.items) { oldItems, newItems in
                            rowIndex = ConversationRowIndex(items: newItems)
#if DEBUG
                            debugItemIdentity = ConversationStabilityIdentity.digest(orderedItemIDs: newItems.map(\.id))
#endif
                            recordVisibleMessageCount()
                            // 前置旧历史不是新消息，不应把读者拉回底部或显示“新消息”。
                            if historyPagingID != nil {
                                if oldItems.last?.id != newItems.last?.id { hasNewBelow = true }
                                return
                            }
                            guard !isRestoringReadingPosition else {
                                if restoreBaselineReady,
                                   session.view.items.count > restoreBaselineCount,
                                   session.view.items.last?.id != restoreBaselineLastItemID {
                                    newMessagesDuringRestore = true
                                }
                                return
                            }
                            if isNearBottom && !isDraggingThread {
                                scheduleAutomaticFollow(proxy: proxy)
                            } else {
                                hasNewBelow = true
                            }
                        }
                        .onChange(of: session.view.runningTurnId) { _, _ in
                            scheduleAutomaticFollow(proxy: proxy)
                        }
                        .onChange(of: session.view.activeItems) { _, _ in
                            scheduleAutomaticFollow(proxy: proxy)
                        }
                        .onChange(of: session.view.queuedTurns) { _, _ in
                            scheduleAutomaticFollow(proxy: proxy)
                        }
                        .onChange(of: scrollToBottomRequest) { _, _ in
                            cancelHistoryPaging()
                            cancelReadingPositionRestore()
                            isNearBottom = true
                            hasNewBelow = false
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                            recordReadingPosition()
                        }
                        .task(id: readingRestoreTaskKey) {
                            await restoreReadingPosition(proxy: proxy)
                        }
                        .onChange(of: readingRestoreRetryNonce) { _, nonce in
                            guard nonce > 0 else { return }
                            Task { await restoreReadingPosition(proxy: proxy) }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            scrollToLatestButton(proxy: proxy)
                        }
                    }
                }
                if session.openingSessionID == nil { composer }
            }
            .environment(\.conversationHistoryTextLoader, historyTextLoader)
            .piPageBackground()
            .sheet(item: $approvalFullInput) { item in
                ApprovalInputSheet(item: item, load: session.loadApprovalInput) { digest in
                    if let digest {
                        reviewedApprovalDigests[item.id] = (item.revision, digest)
                    }
                    approvalFullInput = nil
                }
            }
            .onChange(of: session.pendingApprovals.map(\.id)) { _, ids in
                reviewedApprovalDigests = reviewedApprovalDigests.filter { ids.contains($0.key) }
            }
            .overlay(alignment: .topLeading) {
#if DEBUG
                Text(topVisibleItemID ?? "none")
                    .font(.system(size: 1))
                    .foregroundStyle(PIColor.text)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityIdentifier("conversation.debugTopVisibleItem")
                    .allowsHitTesting(false)
                Text("target=\(readingRestoreTargetItemID ?? "none"),measured=\(lastMeasuredTopItemID ?? "none"),y=\(measuredTopY),active=\(activeAnchorCount),items=\(rowIndex.indexedItemCount)")
                    .font(.system(size: 1))
                    .foregroundStyle(PIColor.text)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityIdentifier("conversation.debugRestorationState")
                    .allowsHitTesting(false)
                Text(debugItemIdentity)
                    .font(.system(size: 1))
                    .frame(width: 1, height: 1).clipped()
                    .accessibilityIdentifier("conversation.debugItemIdentity")
                    .allowsHitTesting(false)
                Text(verbatim: "near=\(isNearBottom),items=\(session.view.items.count),indexed=\(rowIndex.indexedItemCount),distance=\(debugBottomDistance),restoring=\(isRestoringReadingPosition),\(debugLastRowFrame)")
                    .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                    .accessibilityIdentifier("conversation.debugBottomFollowState")
                    .allowsHitTesting(false)
                if SessionController.observesUITestTurnOutcome {
                    if let turnID = session.uiTestSubmittedTurnID {
                        Text(verbatim: turnID)
                            .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                            .accessibilityIdentifier("conversation.debugSubmittedTurn")
                            .allowsHitTesting(false)
                    }
                    if let turn = connection.uiTestTerminalTurn, turn.sessionId == session.attachedSessionId,
                       let status = turn.status {
                        Text(verbatim: "\(turn.id):\(status)")
                            .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                            .accessibilityIdentifier("conversation.debugTerminalTurn")
                            .allowsHitTesting(false)
                    }
                }
#endif
            }
            // 会话页内容自带常驻状态区，用 inline 标题：大标题会跟着内嵌滚动视图
            // 下拉进出，压在状态区上（标题被同步下拉）。
            .piRootNavBar(sessionTitle, displayMode: .inline, onMenu: model.openSidebar) {
                Menu {
#if DEBUG
                    if UITestFixture.stabilityControlsEnabled {
                        Button("追加测试消息") { session.appendStabilityFixtureMessage() }
                            .accessibilityIdentifier("conversation.fixture.appendMessage")
                    }
#endif
                    Button("会话配置") { showingConfig = true }
                        .disabled(extensionSessionId == nil)
                    Button("重命名会话") {
                        renameDraft = sessionTitle
                        showingRename = true
                    }
                    .disabled(session.attachedSessionId == nil)
                    Button("归档会话", role: .destructive) {
                        archiveCurrentSession()
                    }
                    .disabled(session.attachedSessionId == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                }
                .disabled(session.openingSessionID != nil)
                .accessibilityLabel("会话操作")
            }
            .sheet(isPresented: $showingConfig) {
                SessionConfigSheet(
                    session: session,
                    groups: model.currentModelGroups,
                    diagnostics: model.currentModelDiagnostics,
                    extensionSessionID: extensionSessionId
                )
            }
            .alert("重命名会话", isPresented: $showingRename) {
                TextField("会话标题", text: $renameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { renameCurrentSession() }
            }
            // 操作失败与完成都不再弹窗：结论放在常驻状态条里（见 `sessionStatusStrip`），
            // 用户在处理审批 / 工具卡时不会因为一个模态框丢掉当前上下文。
            // 换会话 / 首次挂上会话：attach 刚把状态置为 `.checking`，这一条必须无条件查。
            .task(id: modelAvailabilityContextKey) {
                guard session.openingSessionID == nil, !session.hasRecentModelAvailability() else { return }
                await refreshModelAvailability()
            }
            // A frame snapshot only describes the session that produced it. Do
            // not let a previous visit's geometry confirm a restore in a newly
            // attached session.
            .onChange(of: readingContextKey) { _, _ in
                submissionID = nil
                automaticFollowTask?.cancel()
                automaticFollowTask = nil
                frameSnapshot.contextKey = nil
                frameSnapshot.frames = [:]
            }
            // 回到会话页（首次出现也算）：只在「没有可信结论」时补查一次，不轮询。
            .task {
                recheckModelAvailabilityIfNeeded()
            }
            .onDisappear {
                submissionID = nil
                recordReadingPosition()
                automaticFollowTask?.cancel()
                automaticFollowTask = nil
            }
            .onChange(of: session.openingSessionID) { _, _ in
                previewWindowLimit = 80
                submissionID = nil
                automaticFollowTask?.cancel()
                automaticFollowTask = nil
            }
            // 会话配置浮层关闭：用户可能去改了模型，也可能什么都没改就退出。
            // 只在明确不可用 / 未知时补一次，其余交给绑定变化与页面出现。
            .onChange(of: showingConfig) { _, isPresented in
                guard !isPresented else { return }
                recheckModelAvailabilityIfNeeded()
            }
            .onChange(of: session.pendingAttachments.count) { _, count in
                // 附件清空（发送成功或手动移除）后，上次部分读取失败的提示不再适用。
                guard count == 0, photoReadAcknowledged else { return }
                photoReadFailureCount = 0
                photoReadSucceededCount = 0
                photoReadAcknowledged = false
            }
        }
    }

    var sessionTitle: String {
        guard let sessionID = session.openingSessionID ?? session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return "会话" }
        let fallback = connection.sessions.first(where: { $0.id == sessionID })?.title
            ?? (session.attachedSummary?.id == sessionID ? session.attachedSummary?.title : nil)
            ?? "会话 \(sessionID)"
        return model.sessionDisplayTitle(hostID: hostID, sessionID: sessionID, fallback: fallback)
    }

    @ViewBuilder
    private func scrollToLatestButton(proxy: ScrollViewProxy) -> some View {
        if !isNearBottom, session.openingSessionID == nil {
            Button {
                automaticFollowTask?.cancel()
                automaticFollowTask = nil
                cancelHistoryPaging()
                cancelReadingPositionRestore()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo("thread-bottom", anchor: .bottom)
                }
                isNearBottom = true
                hasNewBelow = false
                recordReadingPosition()
            } label: {
                Text(hasNewBelow ? "新消息 · 回到最新" : "回到最新")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.onAccent)
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.vertical, PISpacing.s8)
                    .background(PIColor.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(PISpacing.s12)
            .accessibilityIdentifier("conversation.scrollToLatest")
            .accessibilityLabel(hasNewBelow ? "有新消息，回到最新" : "回到最新")
        }
    }

    // MARK: - 头部（常驻，AC-08.12）

    /// 一行说清「连的是谁、现在什么状态」。
    ///
    /// quiet-v2：原来这里是「服务器名 · 地址 · 模型」三段挤一行，12pt 下必然中间截断，
    /// 而且「模型」和输入栏上方的模型 chip 是同一事实的两次展示（R9）。
    /// 现在只留状态 + 服务器名；地址在服务器页，模型状态在它自己的 chip 上。
    var statusLine: String {
        guard let host = currentHost else { return connection.state.displayText }
        // 离线详情由下方唯一状态行表达，页头这里只保留 Host 身份，避免同义复述。
        return connection.state.isOnline ? "\(connection.state.displayText) · \(host.name)" : host.name
    }

    var header: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack(spacing: PISpacing.s8) {
                if connection.state.isOnline {
                    Circle()
                        .fill(PIColor.success)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(statusLine)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !connection.state.isOnline {
                HStack(alignment: .firstTextBaseline, spacing: PISpacing.s8) {
                    Circle()
                        .fill(PIColor.warning)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(offlineStatusText)
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, PISpacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface)
        .accessibilityElement(children: .combine)
        .piOptionalIdentifier(connection.state.isOnline ? nil : "conversation.offlineNotice")
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    // MARK: - 常驻状态

    /// 状态条的一行：一条事实 + 可选关闭动作。id 同时用作 accessibilityIdentifier。
    struct StatusLine: Identifiable {
        let id: String
        let text: String
        let tint: Color
        var dismiss: (() -> Void)?
    }

    /// 只放「现在什么状态」。日常可用时整条不出现，不占一行空白。
    var statusLines: [StatusLine] {
        var lines: [StatusLine] = []
        guard session.openingSessionID == nil else { return lines }
        if isSubmitting {
            lines.append(StatusLine(id: "conversation.submitting", text: "正在提交…", tint: PIColor.text2))
        }
        if session.isTurnRunning {
            lines.append(StatusLine(
                id: "conversation.streamingCount",
                text: streamingStatusText,
                tint: PIColor.text2
            ))
        }
        if !session.queuedTurns.isEmpty {
            lines.append(StatusLine(
                id: "conversation.queuedNotice",
                text: "排队 \(session.queuedTurns.count)",
                tint: PIColor.text2
            ))
        }
        if let error = connection.offlineCacheLoadError,
           error == OfflineCacheEncryptionError.unavailable.localizedDescription {
            lines.append(StatusLine(id: "conversation.cacheEncryptionError", text: error, tint: PIColor.danger))
        }
        if let error = session.lastError, !duplicatesModelAvailabilityWarning(error) {
            lines.append(StatusLine(
                id: "conversation.errorNotice",
                text: error,
                tint: PIColor.danger,
                dismiss: { session.clearError() }
            ))
        } else if session.sendAdmission == .blockedReadOnly {
            lines.append(StatusLine(id: "conversation.readOnly", text: RACPErrorCode.sessionReadOnly.userMessage, tint: PIColor.text2))
        } else if let notice = session.notice {
            // 完成提示是中性事实（「已中止」不是成功），用状态色只在失败时出现。
            lines.append(StatusLine(
                id: "conversation.notice",
                text: notice,
                tint: PIColor.text2,
                dismiss: { session.clearNotice() }
            ))
        }
        return lines
    }

    /// 发送前的模型准入失败会同时写入 lastError；同一原因已由模型警告表达时不再画第二条。
    /// 其他独立的连接、审批或工具错误仍原样保留。
    func duplicatesModelAvailabilityWarning(_ error: String) -> Bool {
        switch session.modelAvailability {
        case .unavailable, .unknown:
            return error == session.modelAvailability.displayText
                || error == "当前模型不可用，请重新选择模型"
        case .available, .checking:
            return false
        }
    }

    var offlineStatusText: String {
        if let detail = connection.state.detail, !detail.isEmpty {
            return "离线 · \(detail)"
        }
        // 缓存只读与可能过期由离线线程说明；顶部只保留连接事实，避免同义复述。
        return "离线"
    }

    /// 与旧线程内的「正在生成…」同义：纯工具长任务期间 activeItems 为空，
    /// 只看 activeItems 会缺这段时间的状态。
    var streamingStatusText: String {
        session.activeItems.isEmpty ? "运行中" : "运行中 · \(session.activeItems.count) 条"
    }

    @ViewBuilder
    var sessionStatusStrip: some View {
        let lines = statusLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: PISpacing.s8) {
                        Circle()
                            .fill(line.tint)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(line.text)
                            .font(PIFont.meta.weight(.semibold))
                            .foregroundStyle(PIColor.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(line.id)
                        Spacer(minLength: PISpacing.s4)
                        if let dismiss = line.dismiss {
                            Button(action: dismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(PIColor.text3)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭提示")
                            .accessibilityIdentifier("\(line.id).dismiss")
                        }
                    }
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PIColor.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PIColor.separator)
                    .frame(height: PIMetrics.hairline)
            }
            // `.contain`：容器有 identifier 时不能合并子元素，否则每条状态自己的
            // identifier（离线 / 运行中 / 排队）会被吞掉。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.statusStrip")
        }
    }

    @ViewBuilder
    var readingRestoreRetryStrip: some View {
        if readingRestoreRetryAvailable {
            HStack(spacing: PISpacing.s8) {
                Text("阅读位置尚未恢复")
                    .font(PIFont.meta.weight(.semibold))
                    .foregroundStyle(PIColor.text)
                Spacer(minLength: PISpacing.s4)
                Button("重试定位") {
                    readingRestoreRetryAvailable = false
                    readingRestoreRetryNonce &+= 1
                }
                .font(PIFont.meta.weight(.semibold))
                .accessibilityIdentifier("conversation.retryReadingPosition")
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s8)
            .background(PIColor.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PIColor.separator)
                    .frame(height: PIMetrics.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.readingRestoreNotice")
        }
    }

    // MARK: - 状态区

    @ViewBuilder
    var statusArea: some View {
        if connection.state.isOnline, session.attachedSessionId == nil {
            PIEmptyState(
                title: "还没有打开会话",
                actionTitle: "去项目页",
                action: { model.switchRoot(.projects) },
                actionIdentifier: "conversation.openProjects",
                icon: "bubble.left.and.text.bubble.right"
            )
        } else if connection.state.isOnline {
            switch session.modelAvailability {
            case .available:
                EmptyView()
            case .checking:
                PIStatusBanner(
                    kind: .info,
                    text: "正在检查模型可用性"
                )
            case .unavailable(let reason), .unknown(let reason):
                // 一条横幅只承担一件事：告诉你不可用，并给唯一出口。
                // 这个出口是闭环：直达「模型服务」子页去修模型，回到会话页时按当前状态
                // 自动重查一次（见 `recheckModelAfterReappearing`）。
                PIStatusBanner(
                    kind: .warning,
                    text: "模型暂不可用",
                    detail: reason,
                    actionTitle: "选择其他模型",
                    action: { openModelServices() }
                )
            }
        }
    }

}
