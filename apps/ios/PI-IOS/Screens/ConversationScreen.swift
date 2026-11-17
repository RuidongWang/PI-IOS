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
private final class ConversationFrameSnapshot {
    var contextKey: String?
    var frames: [String: CGRect] = [:]
}

/// S-02 会话（根）。
///
/// 线程、审批、提问、排队与中止都走真实的 RACP 调用；离线时只显示本机缓存并标注可能不是最新。
/// 没有向量（vector）能力：不渲染示例对话，也不在缺数据时假装有内容。
struct ConversationScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @ObservedObject private var session: SessionController

    @State private var showingConfig = false
    @State private var selections: [String: [Int: Set<String>]] = [:]
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var isNearBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasNewBelow = false
    @State private var scrollToBottomRequest = 0
    @State private var modelAvailabilityGeneration = 0
    @State private var submissionID: UUID?
    private var isSubmitting: Bool { submissionID != nil }
    @State private var automaticFollowTask: Task<Void, Never>?
    @State private var automaticFollowID: UUID?
    @State private var isDraggingThread = false
    @State private var previewWindowLimit = 80
    /// Provider ids that exist only in the legacy store (never mirrored into the
    /// v2 PI-adaptor store). Empty until a successful v2 probe confirms we are talking
    /// to a v2 PI-adaptor, so a v1 PI-adaptor never gets its models wrongly marked.
    @State private var legacyOnlyProviderIDs: Set<String> = []
    @State private var topVisibleItemID: String?
    @State private var lastMeasuredTopItemID: String?
    @State private var readingRestoreTargetItemID: String?
    @State private var readingRestoreRequestID = 0
    @State private var activeReadingHostID: UUID?
    @State private var activeReadingSessionID: String?
    @State private var isRestoringReadingPosition = false
    @State private var newMessagesDuringRestore = false
    @State private var restoreBaselineReady = false
    @State private var restoreBaselineCount = 0
    @State private var restoreBaselineLastItemID: String?
    @State private var readingRestoreGeneration = 0
    @State private var historyPagingID: UUID?
    @State private var historyPagingCancelled = false
    @State private var historyPositionRestoreID: UUID?
    @State private var historyReadingAnchorID: String?
    @State private var viewportMeasurement = ConversationViewportMeasurement()
    @State private var frameSnapshot = ConversationFrameSnapshot()
    @State private var rowIndex: ConversationRowIndex
    /// Programmatic scroll target. `ScrollViewReader.scrollTo` cannot reach a
    /// `LazyVStack` row that has never been laid out, so restore/paging pin the
    /// anchor through `scrollPosition` first; the UIKit anchor then corrects the
    /// exact pixel offset once that row exists.
    @State private var scrollPositionID: String?
#if DEBUG
    @State private var activeAnchorCount = 0
    @State private var measuredTopY: CGFloat = 0
    @State private var debugItemIdentity = ""
    @State private var debugLastRowFrame = "unmeasured"
    @State private var debugBottomDistance: CGFloat = 0
#endif
    @State private var readingRestoreFailed = false
    @State private var readingRestoreRetryAvailable = false
    @State private var readingRestoreRetryNonce = 0
    /// A prepend that could not be pixel-compensated keeps this logical anchor
    /// authoritative until the user scrolls or a later correction applies.
    @State private var readingPositionHoldAnchorID: String?
    @State private var approvalFullInput: ApprovalFullInput?
    /// 选图批次的读取/上传仍在进行时禁止发送，避免用户看不到尚未完成的图片。
    @State private var isReadingPhotos = false
    @State private var photoReadCompletedCount = 0
    @State private var photoReadTotalCount = 0
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionID = UUID()
    /// U16：最近一次选图的读取失败数 / 成功读取数 / 部分失败是否已确认发送子集。
    @State private var photoReadFailureCount = 0
    @State private var photoReadSucceededCount = 0
    @State private var photoReadAcknowledged = false

    init(session: SessionController) {
        self.session = session
        _rowIndex = State(initialValue: ConversationRowIndex(items: session.view.items))
#if DEBUG
        _debugItemIdentity = State(initialValue: ConversationStabilityIdentity.digest(orderedItemIDs: session.view.items.map(\.id)))
#endif
    }

    private var currentHost: HostRecord? { model.currentHost }

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
                                        inputSection
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
                    }
                }
                if session.openingSessionID == nil { composer }
            }
            .piPageBackground()
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
                    unavailableProviderIDs: legacyOnlyProviderIDs,
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

    private var sessionTitle: String {
        guard let sessionID = session.openingSessionID ?? session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return "会话" }
        let fallback = connection.sessions.first(where: { $0.id == sessionID })?.title
            ?? (session.attachedSummary?.id == sessionID ? session.attachedSummary?.title : nil)
            ?? "会话 \(sessionID)"
        return model.sessionDisplayTitle(hostID: hostID, sessionID: sessionID, fallback: fallback)
    }

    // MARK: - 头部（常驻，AC-08.12）

    /// 一行说清「连的是谁、现在什么状态」。
    ///
    /// quiet-v2：原来这里是「服务器名 · 地址 · 模型」三段挤一行，12pt 下必然中间截断，
    /// 而且「模型」和输入栏上方的模型 chip 是同一事实的两次展示（R9）。
    /// 现在只留状态 + 服务器名；地址在服务器页，模型状态在它自己的 chip 上。
    private var statusLine: String {
        guard let host = currentHost else { return connection.state.displayText }
        // 离线详情由下方唯一状态行表达，页头这里只保留 Host 身份，避免同义复述。
        return connection.state.isOnline ? "\(connection.state.displayText) · \(host.name)" : host.name
    }

    private var header: some View {
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
    private struct StatusLine: Identifiable {
        let id: String
        let text: String
        let tint: Color
        var dismiss: (() -> Void)?
    }

    /// 只放「现在什么状态」。日常可用时整条不出现，不占一行空白。
    private var statusLines: [StatusLine] {
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
        if let error = session.lastError, !duplicatesModelAvailabilityWarning(error) {
            lines.append(StatusLine(
                id: "conversation.errorNotice",
                text: error,
                tint: PIColor.danger,
                dismiss: { session.clearError() }
            ))
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
    private func duplicatesModelAvailabilityWarning(_ error: String) -> Bool {
        switch session.modelAvailability {
        case .unavailable, .unknown:
            return error == session.modelAvailability.displayText
                || error == "当前模型不可用，请重新选择模型"
        case .available, .checking:
            return false
        }
    }

    private var offlineStatusText: String {
        if let detail = connection.state.detail, !detail.isEmpty {
            return "离线 · \(detail)"
        }
        // 缓存只读与可能过期由离线线程说明；顶部只保留连接事实，避免同义复述。
        return "离线"
    }

    /// 与旧线程内的「正在生成…」同义：纯工具长任务期间 activeItems 为空，
    /// 只看 activeItems 会缺这段时间的状态。
    private var streamingStatusText: String {
        session.activeItems.isEmpty ? "运行中" : "运行中 · \(session.activeItems.count) 条"
    }

    @ViewBuilder
    private var sessionStatusStrip: some View {
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
    private var readingRestoreRetryStrip: some View {
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
    private var statusArea: some View {
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

    // MARK: - 线程

    private func threadSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            if session.view.hasMoreHistory || session.historyError != nil {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    Button {
                        Task { await loadEarlierHistoryPreservingPosition(proxy: proxy) }
                    } label: {
                        HStack(spacing: PISpacing.s8) {
                            if session.isLoadingEarlierHistory { ProgressView().controlSize(.small) }
                            Label(
                                session.isLoadingEarlierHistory ? "正在加载更早消息…" : "加载更早消息",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                        .font(PIFont.captionStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PISpacing.s8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!session.isOnline || session.isBusy || session.isLoadingEarlierHistory || historyPagingID != nil || isRestoringReadingPosition)
                    .accessibilityIdentifier("conversation.loadEarlierHistory")
                    if let error = session.historyError {
                        Text("更早消息加载失败：\(error)")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.danger)
                            .accessibilityIdentifier("conversation.historyError")
                    }
                }
            }
            if session.view.items.isEmpty {
                PIEmptyState(
                    title: "这个会话还没有消息",
                    icon: "bubble.left.and.text.bubble.right"
                )
            } else {
                let rows = rowIndex.rows
                let restoreAnchor = readingRestoreTargetItemID.map { rowIndex.anchorItemID(for: $0) }
                let pagingAnchor = historyReadingAnchorID.map { rowIndex.anchorItemID(for: $0) }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.anchorItemID) { index, row in
                        conversationRowView(row)
                            .padding(.top, rowSpacing(at: index, rows: rows))
                            .background {
                                ReadingRestoreAnchor(
                                    itemID: row.anchorItemID,
                                    targetID: restoreAnchor,
                                    requestID: readingRestoreRequestID,
                                    historyAnchorID: pagingAnchor,
                                    historyTopSpacing: rowSpacing(at: index, rows: rows),
                                    historyRequestID: historyPositionRestoreID,
                                    viewportMeasurement: viewportMeasurement,
                                    onUserInteraction: {
                                        cancelHistoryPaging()
                                        cancelReadingPositionRestore()
                                    }
                                )
                            }
                            .background {
                                GeometryReader { frame in
                                    Color.clear.preference(
                                        key: ConversationItemFrameKey.self,
                                        value: [
                                            row.anchorItemID: frame.frame(in: .named("conversation-scroll"))
                                        ]
                                    )
                                }
                            }
                    }
                }
                .scrollTargetLayout()
            }
            // 运行状态已经常驻在 `sessionStatusStrip`，线程末尾不再重复一条同样的文案。
        }
    }

    /// 工具类行之间更紧凑；工具行与正文之间留出正常段落间距。
    private func rowSpacing(at index: Int, rows: [ConversationRow]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = rows[index - 1]
        let current = rows[index]
        if previous.isToolLike, current.isToolLike { return PISpacing.s8 }
        if previous.isToolLike || current.isToolLike { return PISpacing.s12 }
        return PISpacing.s16
    }

    @ViewBuilder
    private func conversationRowView(_ row: ConversationRow) -> some View {
        switch row {
        case let .item(item):
            itemRow(item)
        case let .toolGroup(group):
            ToolRunCard(group: group)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RACPItem) -> some View {
        if item.isToolItem {
            ToolItemCard(item: item)
        } else if item.role == "user" {
            // 用户消息：右对齐、accentSoft 底、无头像无角色标签；不画描边、不画阴影。
            // quiet-v2 §2：accent 只表达「可交互」，所以气泡只用选中底，不用 accent 描边。
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if !item.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            ForEach(item.attachments, id: \.id) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    Text(item.text ?? item.kind ?? "条目")
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("conversation.userMessage.\(item.id)")
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(maxWidth: 320, alignment: .leading)
                .background(
                    PIColor.accentSoft,
                    in: RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous)
                )
                copyMessageButton(item)
            }
        } else {
            // Agent / 系统消息：直接排在页面上，无气泡、无头像、无角色标签。
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if !item.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            ForEach(item.attachments, id: \.id) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    // Agent 输出几乎都是 Markdown（表格、围栏代码块、粗体、列表），
                    // 纯 Text 会把标记原样画出来；用户气泡保持纯文本，避免把用户输入的
                    // `*`、`_` 当成语法解释。
                    PIMarkdownView(
                        text: item.text ?? item.kind ?? "条目",
                        identifier: "conversation.agentMessage.\(item.id)"
                    )
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                Spacer(minLength: 0)
                copyMessageButton(item)
            }
        }
    }

    /// Coalesce message, status and queue updates without restarting animations.
    private func scheduleAutomaticFollow(proxy: ScrollViewProxy) {
        guard automaticFollowTask == nil, !isDraggingThread, isNearBottom,
              !isRestoringReadingPosition, historyPagingID == nil,
              session.openingSessionID == nil else { return }
        let context = readingContextKey
        let requestID = UUID()
        automaticFollowID = requestID
        automaticFollowTask = Task { @MainActor in
            defer {
                if automaticFollowID == requestID { automaticFollowTask = nil }
            }
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            guard !Task.isCancelled, context == readingContextKey,
                  !isDraggingThread, isNearBottom, !isRestoringReadingPosition,
                  historyPagingID == nil, session.openingSessionID == nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("thread-bottom", anchor: .bottom) }
        }
    }

    private var readingContextKey: String? {
        guard let hostID = model.currentHost?.id,
              session.openingSessionID == nil, let sessionID = session.attachedSessionId
        else { return nil }
        return "\(hostID.uuidString):\(sessionID)"
    }

    /// 附加会话 ID 会先到，`session/view` 可能晚到；视图真的换成目标会话后要再触发一次恢复。
    private var readingRestoreTaskKey: String? {
        guard let context = readingContextKey else { return nil }
        return "\(context):\(session.view.sessionId ?? "pending")"
    }

    /// `scrollPosition` also writes the row that happens to be on top while the
    /// user scrolls. Feeding that back would fight the restore/paging offset, so
    /// only the screen writes this state; layout feedback is ignored.
    private var trackedScrollPosition: Binding<String?> {
        Binding(get: { scrollPositionID }, set: { _ in })
    }

    private func cancelReadingPositionRestore() {
        readingRestoreGeneration &+= 1
        readingRestoreRequestID &+= 1
        readingRestoreTargetItemID = nil
        scrollPositionID = nil
        readingRestoreFailed = false
        readingRestoreRetryAvailable = false
        readingPositionHoldAnchorID = nil
        if isRestoringReadingPosition { hasNewBelow = newMessagesDuringRestore }
        isRestoringReadingPosition = false
    }

    private func cancelHistoryPositionRestore() {
        historyPositionRestoreID = nil
        historyReadingAnchorID = nil
        viewportMeasurement.cancel()
        scrollPositionID = nil
    }

    private func cancelHistoryPaging() {
        historyPagingCancelled = true
        readingPositionHoldAnchorID = nil
        cancelHistoryPositionRestore()
    }

    /// 只在用户点按钮后读取一页。UIKit 锚点保留原可见条目的像素位置，
    /// 不借用回到最新的 scrollTo，也不在历史页到达时触发消息追随。
    @MainActor
    private func loadEarlierHistoryPreservingPosition(proxy: ScrollViewProxy) async {
        guard historyPagingID == nil, !session.isLoadingEarlierHistory,
              !isRestoringReadingPosition, let contextKey = readingContextKey else { return }
        let requestID = UUID()
        historyPagingID = requestID
        historyPagingCancelled = false
        readingPositionHoldAnchorID = nil
        readingRestoreFailed = false
        readingRestoreRetryAvailable = false
        let anchorID = lastMeasuredTopItemID ?? topVisibleItemID ?? session.view.items.first?.id
        historyReadingAnchorID = anchorID
        let rowAnchorID = anchorID.map { rowIndex.anchorItemID(for: $0) }
        let rowTopSpacing = rowAnchorID.flatMap { anchorID in
            rowIndex.rows.firstIndex(where: { $0.anchorItemID == anchorID }).map {
                rowSpacing(at: $0, rows: rowIndex.rows)
            }
        } ?? 0
        viewportMeasurement.begin(
            requestID: requestID,
            itemID: rowAnchorID,
            topSpacing: rowTopSpacing
        )
        let previousNearBottom = isNearBottom
        isNearBottom = false
        var outcome: ConversationPagingPositionOutcome = .unapplied
        defer {
            if historyPagingID == requestID {
                if !historyPagingCancelled,
                   !outcome.recordsVisiblePosition,
                   let anchorID {
                    readingPositionHoldAnchorID = anchorID
                }
                historyPagingID = nil
                historyPagingCancelled = false
                cancelHistoryPositionRestore()
            }
        }
        // 日志：分页请求/历史加载的开始（耗时基准与条数），只记 debug，不记录消息内容。
        let logStartedAt = Date()
        let logItemsBefore = session.view.items.count
        PILog.debug(
            "UI",
            "history page start items=\(logItemsBefore) anchor=\(anchorID.map { String($0.prefix(8)) } ?? "-")"
        )
        let inserted = await session.loadEarlierHistory()
        // 日志：分页请求/历史加载的耗时与条数，只记 debug，不记录消息内容。
        defer {
            PILog.debug(
                "UI",
                "history page end inserted=\(inserted) items=\(session.view.items.count) before=\(logItemsBefore) applied=\(outcome == .applied) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
            )
        }
        outcome = inserted ? .unapplied : .notInserted
        guard !Task.isCancelled, readingContextKey == contextKey,
              historyPagingID == requestID,
              !historyPagingCancelled else { return }
        // 分页跨过工具分组边界时行身份可能变化，像素基准存放在共享测量器中。
        // 只在响应归约后启动补偿；等待期间用户拖动/点回到最新会取消它。
        if inserted, viewportMeasurement.requestID == requestID, let anchorID {
            rowIndex = ConversationRowIndex(items: session.view.items)
            // A prepend may merge the old row into a new tool group outside the
            // lazy window. Materialize that new row before applying its old Y.
            let target = rowIndex.anchorItemID(for: anchorID)
            if viewportMeasurement.itemID != target {
                scrollPositionID = target
            }
            proxy.scrollTo(target, anchor: .top)
            await Task.yield()
            guard viewportMeasurement.requestID == requestID,
                  !historyPagingCancelled else { return }
            historyPositionRestoreID = requestID
            for _ in 0..<30 {
                guard !Task.isCancelled, readingContextKey == contextKey,
                      viewportMeasurement.requestID == requestID,
                      !historyPagingCancelled else { return }
                if viewportMeasurement.appliedRequestID == requestID {
                    // The pixel baseline is back; stop pinning the row to the top.
                    outcome = .applied
                    scrollPositionID = nil
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard outcome == .applied else {
                // The old reading position is still the only verified one. Keep
                // its logical anchor instead of recording the transient pre-page
                // viewport; a later restore/paging action may retry.
                topVisibleItemID = anchorID
                lastMeasuredTopItemID = anchorID
                isNearBottom = previousNearBottom
                return
            }
            topVisibleItemID = anchorID
        }
        guard !Task.isCancelled, readingContextKey == contextKey,
              historyPagingID == requestID,
              !historyPagingCancelled else { return }
        if !inserted, viewportMeasurement.requestID == requestID {
            isNearBottom = previousNearBottom
        }
        guard outcome.recordsVisiblePosition, anchorID != nil else { return }
        readingPositionHoldAnchorID = nil
        historyPagingID = nil
        cancelHistoryPositionRestore()
        recordReadingPosition()
    }

    @MainActor
    private func restoreReadingPosition(proxy: ScrollViewProxy) async {
        historyPagingID = nil
        historyPagingCancelled = false
        readingPositionHoldAnchorID = nil
        cancelHistoryPositionRestore()
        readingRestoreFailed = false
        readingRestoreRetryAvailable = false
        readingRestoreGeneration &+= 1
        let generation = readingRestoreGeneration
        defer {
            if readingRestoreGeneration == generation {
                isRestoringReadingPosition = false
                scrollPositionID = nil
            }
        }
        // 日志：阅读位置恢复的开始/结束（耗时、条数），只记 debug，不记录消息内容。
        let logStartedAt = Date()
        let logItemsAtStart = session.view.items.count
        PILog.debug("UI", "reading restore start items=\(logItemsAtStart)")
        defer {
            PILog.debug(
                "UI",
                "reading restore end items=\(session.view.items.count) startItems=\(logItemsAtStart) restoring=\(isRestoringReadingPosition) failed=\(readingRestoreFailed) elapsedMs=\(Int(Date().timeIntervalSince(logStartedAt) * 1000))"
            )
        }
        if !connection.state.isOnline {
            await connection.waitForOfflineCacheReady()
            guard !Task.isCancelled, readingRestoreGeneration == generation else { return }
        }
        guard let hostID = model.currentHost?.id,
              let sessionID = session.attachedSessionId,
              let contextKey = readingContextKey
        else {
            activeReadingHostID = nil
            activeReadingSessionID = nil
            topVisibleItemID = nil
            return
        }

        activeReadingHostID = hostID
        activeReadingSessionID = sessionID
        topVisibleItemID = nil
        lastMeasuredTopItemID = nil
        readingRestoreTargetItemID = nil
        newMessagesDuringRestore = false
        restoreBaselineReady = false
        restoreBaselineCount = 0
        restoreBaselineLastItemID = nil
        hasNewBelow = false
        isRestoringReadingPosition = true

        // `attachedSessionId` 会早于 sessionView 完成更新；等这一代会话的视图落位后再恢复。
        for _ in 0..<60 {
            guard !Task.isCancelled, readingContextKey == contextKey,
                  readingRestoreGeneration == generation else { return }
            if session.view.sessionId == sessionID { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, readingRestoreGeneration == generation,
              readingContextKey == contextKey,
              session.view.sessionId == sessionID
        else { return }
        restoreBaselineCount = session.view.items.count
        restoreBaselineLastItemID = session.view.items.last?.id
        restoreBaselineReady = true

        // Large restored snapshots need multiple layout passes before the target's
        // UIKit anchor can drive the scroll view and its frame can be confirmed.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, readingContextKey == contextKey,
              readingRestoreGeneration == generation else { return }
        rowIndex = ConversationRowIndex(items: session.view.items)

        let saved = model.readingPosition(hostID: hostID, sessionID: sessionID)
        if let saved,
           !saved.isNearBottom,
           let itemID = saved.lastVisibleItemID,
           session.view.items.contains(where: { $0.id == itemID }) {
            isNearBottom = false
            hasNewBelow = newMessagesDuringRestore
            let anchorID = rowIndex.anchorItemID(for: itemID)
            // LazyVStack does not register off-screen rows with ScrollViewReader,
            // so scrollTo alone can silently do nothing and leave the restored
            // view at the content top. Pinning the anchor through scrollPosition
            // makes SwiftUI instantiate that row before the pixel correction.
            //
            // Arm the target before the scroll. If the scroll settles in the
            // same run loop, assigning the target afterwards produces no new
            // frame preference and the restore times out even though the row is
            // already at the viewport top.
            readingRestoreTargetItemID = itemID
            readingRestoreRequestID &+= 1
            // A restarted restore can start with the view already at the saved
            // row. Arming the target then produces no new frame preference, so
            // confirm against the last geometry before waiting for one.
            let confirmed = frameSnapshot.contextKey == contextKey
                && confirmReadingRestoreIfAligned(in: frameSnapshot.frames)
            if !confirmed {
                scrollPositionID = anchorID
                proxy.scrollTo(anchorID, anchor: .top)
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, readingRestoreGeneration == generation,
                      readingContextKey == contextKey else { return }
                for _ in 0..<30 where isRestoringReadingPosition {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, readingRestoreGeneration == generation,
                          readingContextKey == contextKey else { return }
                    if !isRestoringReadingPosition { break }
                    guard readingRestoreTargetItemID == itemID else { return }
                    // The lazy stack's content height grows as rows realize. Re-arm
                    // the pinned target so scrollPosition resolves it again against
                    // the new layout instead of keeping the first clamped offset.
                    scrollPositionID = nil
                    await Task.yield()
                    guard !Task.isCancelled, readingRestoreGeneration == generation,
                          readingContextKey == contextKey,
                          isRestoringReadingPosition else { return }
                    scrollPositionID = anchorID
                    // The row may only have become real after the first scroll
                    // request; retry now that scrollTo can resolve it.
                    proxy.scrollTo(anchorID, anchor: .top)
                    readingRestoreRequestID &+= 1
                }
                guard readingRestoreTargetItemID == nil else {
                    // The bounded wait elapsed without a confirmed frame. Keep the
                    // saved reading position and expose one explicit local retry;
                    // never fake success from the requested item id or loop forever.
                    let restoreOutcome = ConversationRestoreOutcome.timedOut
                    readingRestoreTargetItemID = nil
                    isRestoringReadingPosition = false
                    readingRestoreFailed = restoreOutcome.preservesSavedPosition
                    readingRestoreRetryAvailable = restoreOutcome.offersLocalRetry
                    hasNewBelow = newMessagesDuringRestore
                    topVisibleItemID = lastMeasuredTopItemID
                    return
                }
            }
            isNearBottom = false
            hasNewBelow = newMessagesDuringRestore
        } else {
            readingRestoreTargetItemID = nil
            proxy.scrollTo("thread-bottom", anchor: .bottom)
            topVisibleItemID = session.view.items.last?.id
            isNearBottom = true
            hasNewBelow = false
        }

        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, readingContextKey == contextKey,
              readingRestoreGeneration == generation else { return }
        isRestoringReadingPosition = false
        recordReadingPosition()
    }

    private func recordReadingPosition() {
        guard !isRestoringReadingPosition,
              session.openingSessionID == nil,
              !readingRestoreFailed,
              readingPositionHoldAnchorID == nil,
              historyPagingID == nil,
              let hostID = activeReadingHostID,
              let sessionID = activeReadingSessionID,
              model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID
        else { return }
        model.rememberReadingPosition(
            hostID: hostID,
            sessionID: sessionID,
            lastVisibleItemID: topVisibleItemID ?? session.view.items.last?.id,
            isNearBottom: isNearBottom
        )
    }

    /// Confirms the saved row only from measured geometry. The same predicate is
    /// used by the live probe, so a successful restore cannot report the row above
    /// the saved item as the first visible one.
    @discardableResult
    private func confirmReadingRestoreIfAligned(in frames: [String: CGRect]) -> Bool {
        guard isRestoringReadingPosition,
              let target = readingRestoreTargetItemID,
              let frame = frames[rowIndex.anchorItemID(for: target)],
              ConversationViewportGeometry.isAnchorAlignedAtViewportTop(
                  measuredMinY: frame.minY
              )
        else { return false }
        readingRestoreTargetItemID = nil
        readingRestoreFailed = false
        readingRestoreRetryAvailable = false
        topVisibleItemID = target
        isNearBottom = false
        hasNewBelow = newMessagesDuringRestore
        isRestoringReadingPosition = false
        recordReadingPosition()
        return true
    }

    private func recordVisibleMessageCount() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        model.updateSessionActivity(
            hostID: hostID,
            sessionID: sessionID,
            messageCount: session.view.items.count
        )
    }

    private func renameCurrentSession() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        if model.renameSession(hostID: hostID, sessionID: sessionID, title: renameDraft) {
            session.clearError()
        } else {
            model.showToast("会话标题不能为空")
        }
    }

    private func archiveCurrentSession() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        let projectID = session.attachedSummary?.projectId
            ?? model.sessionBinding(hostID: hostID, sessionID: sessionID)?.projectID
        let next = connection.sessions
            .filter {
                $0.id != sessionID
                    && $0.projectId == projectID
                    && model.sessionBinding(hostID: hostID, sessionID: $0.id).map {
                        !$0.isArchived && !$0.isDeleted
                    } == true
            }
            .sorted {
                (model.sessionBinding(hostID: hostID, sessionID: $0.id)?.lastActivityAt ?? .distantPast)
                    > (model.sessionBinding(hostID: hostID, sessionID: $1.id)?.lastActivityAt ?? .distantPast)
            }
            .first
        model.setSessionArchived(hostID: hostID, sessionID: sessionID, archived: true)
        model.rememberSession(nil)
        if let next {
            Task {
                await connection.session.attach(sessionId: next.id, source: "nextSession")
                model.rememberSession(next.id)
            }
        } else {
            session.detach()
            model.switchRoot(.projects)
        }
    }

    /// 离线时只显示用户在侧边栏显式点过、且按当前 PI-adaptor 保存的会话。
    private var cachedSessionId: String? {
        guard let hostID = model.currentHost?.id else { return nil }
        return model.cachedSessionSelectionID(for: hostID)
    }

    private var extensionSessionId: String? {
        connection.state.isOnline ? session.attachedSessionId : (cachedSessionId ?? session.attachedSessionId)
    }

    private func openingThread(sessionID: String, proxy: ScrollViewProxy) -> some View {
        let entries = connection.cachedSession(sessionId: sessionID)?.entries ?? []
        let anchorID = model.currentHost.flatMap {
            model.readingPosition(hostID: $0.id, sessionID: sessionID)?.lastVisibleItemID
        }
        let anchorIndex = anchorID.flatMap { id in entries.firstIndex { $0.id == id } }
        let range = ConversationPreviewWindow.range(count: entries.count, anchorIndex: anchorIndex, limit: previewWindowLimit)
        let rows = Array(entries[range].reversed())
        let previewRows = ToolCallGroupingPolicy.rows(for: rows.map(\.conversationItem))
        return LazyVStack(alignment: .leading, spacing: PISpacing.s12) {
            if session.isAttaching {
                ProgressView("正在同步会话…")
                    .font(PIFont.meta)
                    .accessibilityIdentifier("conversation.sessionOpening")
            } else {
                PIInlineMessage(kind: .danger, text: session.lastError ?? "会话尚未同步")
                    .accessibilityIdentifier("conversation.sessionOpenError")
                Button("重试同步") {
                    Task { await session.attach(sessionId: sessionID, source: "previewRetry") }
                }
                .accessibilityIdentifier("conversation.retrySessionOpen")
            }
            if !rows.isEmpty {
                Text("本机历史 · 同步完成后更新")
                    .font(PIFont.meta).foregroundStyle(PIColor.text2)
                if rows.count < entries.count {
                    Button("加载更多本机历史") {
                        let anchor = previewRows.first?.anchorItemID
                        previewWindowLimit = min(entries.count, previewWindowLimit + 80)
                        Task { @MainActor in
                            await Task.yield()
                            guard session.openingSessionID == sessionID, let anchor else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { proxy.scrollTo("preview-\(anchor)", anchor: .top) }
                        }
                    }
                    .font(PIFont.meta)
                    .accessibilityIdentifier("conversation.loadMoreCachedPreview")
                    .accessibilityValue("已显示 \(rows.count) 条，共 \(entries.count) 条")
                }
                ForEach(previewRows, id: \.id) { row in
                    cachedConversationRow(row, namespace: "previewMessage")
                        .id("preview-\(row.anchorItemID)")
                }
            } else if session.isAttaching {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: PIRadius.control)
                        .fill(PIColor.surface2)
                        .frame(maxWidth: index == 1 ? 220 : .infinity)
                        .frame(height: 52)
                        .accessibilityHidden(true)
                }
            }
        }
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            PILog.debug("UI", "cached preview mounted session=\(sessionID.prefix(8)) rows=\(rows.count) cached=\(entries.count)")
        }
    }

    @ViewBuilder
    private func offlineThread(sessionId: String) -> some View {
        let cached = connection.cachedSession(sessionId: sessionId)
        // 缓存按新→旧读取；会话阅读与在线线程一致，按旧→新展示。
        let entries = (cached?.entries ?? []).reversed().filter { !$0.conversationItem.isBlankNonToolItem }
        LazyVStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "缓存的历史（只读）")
            PIInlineMessage(
                kind: .warning,
                text: "离线只读 · 缓存可能已过期"
            )
            if let approvals = cached?.approvals, !approvals.isEmpty {
                PISectionHeader(text: "缓存的待审批（\(approvals.count)）")
                ForEach(approvals, id: \.id) { approval in
                    offlineApprovalCard(approval)
                }
            }
            if let draft = cached?.draft,
               !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PICard {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text("未发送草稿（离线只读）")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                        Text(draft.text)
                            .font(PIFont.body)
                            .foregroundStyle(PIColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !connection.offlineCacheReady {
                ProgressView("正在读取本机历史…")
                    .accessibilityIdentifier("conversation.offlineCacheLoading")
            } else if let error = connection.offlineCacheLoadError {
                PIInlineMessage(kind: .danger, text: "本机历史读取失败：\(error)")
                    .accessibilityIdentifier("conversation.offlineCacheError")
            } else if cached == nil {
                PIListRow(
                    title: "本机没有这个会话的缓存",
                    subtitle: "最多 \(PersistedState.maxCachedConversations) 个会话",
                    isEnabled: false,
                    showsDivider: false
                )
            } else if entries.isEmpty {
                PIListRow(
                    title: "缓存里没有文本消息",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(entries, id: \.id) { entry in
                    let presentation = ToolResultPresentation(text: entry.displayText)
                    PICard {
                        HStack(alignment: .top, spacing: PISpacing.s8) {
                            VStack(alignment: .leading, spacing: PISpacing.s4) {
                                Text(presentation.preview)
                                    .font(PIFont.body)
                                    .foregroundStyle(PIColor.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("conversation.offlineMessage.\(entry.id)")
                                if let notice = presentation.truncationNotice {
                                    Text(notice)
                                        .font(PIFont.meta)
                                        .foregroundStyle(PIColor.text2)
                                }
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text2)
                            }
                            Spacer(minLength: 0)
                            copyMessageButton(entry)
                        }
                    }
                }
            }
        }
    }

    /// Tool cards own their button identifiers; an outer identifier would replace
    /// the collapsed header's toggle identity in SwiftUI's accessibility tree.
    @ViewBuilder
    private func cachedConversationRow(_ row: ConversationRow, namespace: String) -> some View {
        if row.isToolLike {
            conversationRowView(row)
        } else {
            conversationRowView(row)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.\(namespace).\(row.anchorItemID)")
        }
    }

    private func offlineApprovalCard(_ approval: OfflineSessionApproval) -> some View {
        let contract = cachedApprovalIsContract(approval)
        return PICard {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                HStack {
                    Text(contract ? "计划契约" : "权限请求")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                    Spacer()
                    Text(approval.offlineStatusText)
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.warning)
                }
                Text(cachedApprovalSummary(approval))
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if contract {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: PISpacing.s8) {
                            PIApprovalPrimaryButton(title: "批准", isEnabled: false) {}
                            PIDangerOutlineButton(title: "驳回", isEnabled: false) {}
                        }
                    } else {
                        HStack(spacing: PISpacing.s8) {
                            PIApprovalPrimaryButton(title: "批准", isEnabled: false) {}
                            PIDangerOutlineButton(title: "驳回", isEnabled: false) {}
                        }
                    }
                } else {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: PISpacing.s8) {
                            PIApprovalSecondaryButton(title: "允许一次", isEnabled: false) {}
                            PIApprovalSecondaryButton(title: "本会话允许", isEnabled: false) {}
                            PIDangerOutlineButton(title: "拒绝", isEnabled: false) {}
                        }
                    } else {
                        HStack(spacing: PISpacing.s8) {
                            PIApprovalSecondaryButton(title: "允许一次", isEnabled: false) {}
                            PIApprovalSecondaryButton(title: "本会话允许", isEnabled: false) {}
                            PIDangerOutlineButton(title: "拒绝", isEnabled: false) {}
                        }
                    }
                }
            }
        }
    }

    private func cachedApprovalIsContract(_ approval: OfflineSessionApproval) -> Bool {
        let kind = approval.payload.value(at: ["kind"])?.stringValue?.lowercased() ?? ""
        return kind.contains("plan") || kind.contains("goal") || kind.contains("contract")
    }

    private func cachedApprovalSummary(_ approval: OfflineSessionApproval) -> String {
        var lines: [String] = []
        if let tool = approval.payload.value(at: ["toolName"])?.stringValue {
            lines.append("工具：\(tool)")
        }
        if let preview = ApprovalInputPreview.text(from: approval.payload) {
            lines.append(preview)
        }
        if !lines.isEmpty { return lines.joined(separator: "\n\n") }
        if let text = approval.payload.value(at: ["summary"])?.stringValue {
            return text
        }
        if let text = approval.payload.value(at: ["detail"])?.stringValue {
            return text
        }
        return "服务器没有给出摘要"
    }

    // MARK: - 审批（AC-10 / AC-12）

    @ViewBuilder
    private var approvalSection: some View {
        ForEach(orderedApprovals, id: \.id) { card in
            let availability = session.availability(for: card.id)
            let isContract = SessionController.isContract(card)
            let canDecide = !(session.isBusy || !connection.state.isOnline)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s12) {
                    HStack(spacing: PISpacing.s8) {
                        // 类型是名词标签，状态用语义色；装饰点删除（quiet-v2 §2）。
                        Text(isContract ? "计划契约" : "权限请求")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                            .accessibilityIdentifier("conversation.approval.\(card.id).kind")
                        Spacer(minLength: PISpacing.s4)
                        if let status = availability.statusText {
                            Text(status)
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.warning)
                        }
                    }
                    Text(summary(of: card))
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let full = ApprovalInputPreview.fullText(from: card.payload) {
                        Button("查看完整参数") {
                            approvalFullInput = ApprovalFullInput(
                                id: card.id,
                                title: card.toolName ?? "审批参数",
                                text: full
                            )
                        }
                        .font(PIFont.captionStrong)
                        .accessibilityIdentifier("conversation.approval.\(card.id).showFullInput")
                    }
                    if availability.isActionable {
                        if isContract {
                            HStack(spacing: PISpacing.s8) {
                                PIApprovalPrimaryButton(title: "批准", isEnabled: canDecide) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .approve) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).approve")
                                PIDangerOutlineButton(title: "驳回", isEnabled: canDecide) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .reject) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).reject")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: PISpacing.s8) {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(spacing: PISpacing.s8) {
                                        PIApprovalPrimaryButton(title: "允许一次", isEnabled: canDecide) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowOnce) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowOnce")
                                        PIApprovalSecondaryButton(title: "本会话允许", isEnabled: canDecide) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowSession) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowSession")
                                    }
                                } else {
                                    HStack(spacing: PISpacing.s8) {
                                        PIApprovalPrimaryButton(title: "允许一次", isEnabled: canDecide) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowOnce) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowOnce")
                                        PIApprovalSecondaryButton(title: "本会话允许", isEnabled: canDecide) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowSession) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowSession")
                                    }
                                }
                                Divider().padding(.top, PISpacing.s4)
                                PIDangerOutlineButton(title: "拒绝", isEnabled: canDecide) {
                                    Task { await session.decide(approvalId: card.id, decision: .deny) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).deny")
                            }
                        }
                    } else {
                        Text("已失效，同步后重试")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.approval.\(card.id)")
            .sheet(item: $approvalFullInput) { item in
                NavigationStack {
                    ScrollView {
                        Text(item.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(PISpacing.s16)
                            .accessibilityIdentifier("conversation.approval.fullInput")
                    }
                    .navigationTitle(item.title)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { approvalFullInput = nil }
                        }
                    }
                }
            }
        }
        ForEach(Array(session.view.expiredApprovalIds).sorted(), id: \.self) { expiredId in
            if session.availability(for: expiredId) == .expired {
                PICard {
                    HStack {
                        Text("审批已失效")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                        Spacer()
                    }
                    .accessibilityIdentifier("conversation.approval.\(expiredId).expired")
                }
            }
        }
    }

    /// 可提交的卡片排在最前：审批卡片区在滚动内容最前面，用户被带过去时第一眼就该能处理它；
    /// 已失效（不在快照里）的卡片沉到后面——AC-14.5 只要求标失效，没有要求保留到达顺序。
    private var orderedApprovals: [RACPApprovalRequest] {
        session.pendingApprovals.enumerated()
            .sorted { lhs, rhs in
                let left = session.availability(for: lhs.element.id).isActionable
                let right = session.availability(for: rhs.element.id).isActionable
                if left != right { return left }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func summary(of card: RACPApprovalRequest) -> String {
        // 工具审批必须先让用户看到要执行的命令/参数，再决定是否放行；
        // 只显示工具名会让审批门禁形同虚设。
        var lines: [String] = []
        if let tool = card.toolName { lines.append("工具：\(tool)") }
        if let preview = ApprovalInputPreview.text(from: card.payload) {
            lines.append(preview)
        }
        if !lines.isEmpty { return lines.joined(separator: "\n\n") }
        if let text = card.payload.value(at: ["summary"])?.stringValue { return text }
        if let text = card.payload.value(at: ["detail"])?.stringValue { return text }
        return "服务器没有给出摘要"
    }

    // MARK: - 提问（AC-11）

    @ViewBuilder
    private var inputSection: some View {
        ForEach(session.pendingInputs, id: \.id) { card in
            let questions = InputQuestionParser.questions(from: card)
            let draftKey = answerDraftKey(card.id)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s12) {
                    Text("需要你回答")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("conversation.input.\(card.id).title")
                    if questions.isEmpty {
                        Text("没有选项，提交会跳过")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                    }
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            Text(question.prompt)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !question.options.isEmpty {
                                VStack(alignment: .leading, spacing: PISpacing.s8) {
                                    ForEach(question.options, id: \.self) { option in
                                        PISelectableChip(
                                            title: option,
                                            isSelected: isSelected(
                                                draftKey: draftKey,
                                                question: question.id,
                                                option: option
                                            )
                                        ) {
                                            setSelected(
                                                draftKey: draftKey,
                                                question: question.id,
                                                option: option,
                                                isOn: !isSelected(
                                                    draftKey: draftKey,
                                                    question: question.id,
                                                    option: option
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: PISpacing.s8) {
                        PIApprovalPrimaryButton(
                            title: "提交回答",
                            isEnabled: !session.isBusy && connection.state.isOnline
                        ) {
                            let answers = InputQuestionParser.answers(
                                selections: selections[draftKey] ?? [:],
                                questionCount: questions.count
                            )
                            Task {
                                // U06：只有成功或明确失效才清空已选答案；普通失败保留，
                                // 重试复用 SessionRequestKeyStore 里已持久化的幂等键。
                                let outcome = await session.answer(inputId: card.id, answers: answers)
                                if outcome.clearsDraft { selections[draftKey] = nil }
                            }
                        }
                        .accessibilityIdentifier("conversation.input.\(card.id).submit")
                        PIApprovalSecondaryButton(
                            title: "全部跳过",
                            isEnabled: !session.isBusy && connection.state.isOnline
                        ) {
                            let answers = InputQuestionParser.answers(
                                selections: [:],
                                questionCount: questions.count
                            )
                            Task {
                                let outcome = await session.answer(inputId: card.id, answers: answers)
                                if outcome.clearsDraft { selections[draftKey] = nil }
                            }
                        }
                        .accessibilityIdentifier("conversation.input.\(card.id).skip")
                    }
                }
            }
        }
    }

    /// 回答草稿的作用域键：服务器 + 会话 + 提问卡（U06）。
    /// 切换服务器或会话后不会把 A 会话选中的答案带到 B 会话。
    private func answerDraftKey(_ inputID: String) -> String {
        AnswerDraftScope(
            hostID: model.currentHost?.id.uuidString ?? "",
            sessionID: session.attachedSessionId ?? "",
            inputID: inputID
        ).storageKey
    }

    private func isSelected(draftKey: String, question: Int, option: String) -> Bool {
        selections[draftKey]?[question]?.contains(option) ?? false
    }

    private func setSelected(draftKey: String, question: Int, option: String, isOn: Bool) {
        var card = selections[draftKey] ?? [:]
        var set = card[question] ?? []
        if isOn {
            set.insert(option)
        } else {
            set.remove(option)
        }
        card[question] = set
        selections[draftKey] = card
    }

    // MARK: - 排队（AC-13）

    @ViewBuilder
    private var queueSection: some View {
        if !session.queuedTurns.isEmpty {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                // 总数由常驻状态条表达，这里只标识待发送内容，不重复计数。
                PISectionHeader(text: "待发送")
                    .accessibilityIdentifier("conversation.queueHeader")
                ForEach(session.queuedTurns) { turn in
                    PICard {
                        HStack(spacing: PISpacing.s8) {
                            // 优先显示正文；服务端快照缺正文时显示附件数/排队提示，不显示裸 id。
                            Text(turn.displayText)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .lineLimit(2)
                                .accessibilityIdentifier("conversation.queuedTurnText.\(turn.id)")
                            Spacer(minLength: PISpacing.s8)
                            // 取消是危险动作：danger 文字，不加装饰底色；热区补足 44pt。
                            Button(role: .destructive) {
                                Task { await session.cancelQueued(turnId: turn.id) }
                            } label: {
                                Text("取消")
                                    .font(PIFont.captionStrong)
                                    .foregroundStyle(PIColor.danger)
                                    .frame(minWidth: PIMetrics.minHitTarget, minHeight: PIMetrics.minHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PIPressableButtonStyle())
                            .disabled(session.isBusy || !connection.state.isOnline)
                            .accessibilityIdentifier("conversation.cancelQueued.\(turn.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conversation.queuedTurn.\(turn.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.queueSection")
        }
    }

    // MARK: - 输入栏

    private var composer: some View {
        // Read the main-actor-isolated admission into a plain value once: the
        // PhotosPicker label runs in a Sendable closure and must not touch
        // `session` directly (Swift 6).
        let allowsAttachments = session.sendAdmission.isAllowed
        return VStack(alignment: .leading, spacing: PISpacing.s8) {
            composerConfigurationChips
            if isReadingPhotos {
                ProgressView("正在处理图片 \(photoReadCompletedCount)/\(photoReadTotalCount)",
                             value: Double(photoReadCompletedCount), total: Double(max(1, photoReadTotalCount)))
                    .font(PIFont.meta)
                    .accessibilityIdentifier("composer.photoReadProgress")
            }
            if let notice = photoReadFailureNotice {
                HStack(alignment: .top, spacing: PISpacing.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.warning)
                        .accessibilityHidden(true)
                    Text(notice)
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("composer.photoReadFailure")
                    Spacer(minLength: PISpacing.s4)
                    if photoReadNeedsConfirmation {
                        // U16：部分失败时不允许无提示发送子集，必须显式确认。
                        Button("仍要发送已读取的图片") {
                            photoReadAcknowledged = true
                        }
                        .font(PIFont.metaSmall.weight(.semibold))
                        .foregroundStyle(PIColor.accent)
                        .accessibilityIdentifier("composer.confirmPartialPhotos")
                    } else if photoReadSucceededCount == 0 {
                        // 全部失败：给出明确的关闭入口，保留“失败可见”而不是静默跳过。
                        Button("知道了") {
                            photoReadFailureCount = 0
                        }
                        .font(PIFont.metaSmall.weight(.semibold))
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("composer.dismissPhotoReadFailure")
                    }
                }
            }
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PISpacing.s8) {
                        ForEach(session.pendingAttachments, id: \.id) { attachment in
                            HStack(spacing: PISpacing.s4) {
                                Image(systemName: "photo")
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Button {
                                    session.removeAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除附件")
                                .accessibilityIdentifier("composer.removeAttachment.\(attachment.id)")
                            }
                            .font(PIFont.meta)
                            .padding(.horizontal, PISpacing.s8)
                            .padding(.vertical, PISpacing.s4)
                            .background(PIColor.surface2, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: PISpacing.s8) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(allowsAttachments ? PIColor.text : PIColor.text3)
                        .frame(width: 36, height: 36)
                        .background(PIColor.surface3, in: Circle())
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Circle())
                }
                .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                .accessibilityLabel("添加图片附件")
                .accessibilityHint("最多选择 10 张 JPEG、PNG 或 WebP 图片")
                .onChange(of: selectedPhotos) { items in
                    guard !items.isEmpty else { return }
                    let selection = session.attachmentSelectionGeneration
                    let photoSelection = UUID()
                    photoSelectionID = photoSelection
                    photoReadFailureCount = 0
                    photoReadSucceededCount = 0
                    photoReadAcknowledged = false
                    isReadingPhotos = true
                    photoReadCompletedCount = 0
                    photoReadTotalCount = items.count
                    Task {
                        var failed = 0
                        var succeeded = 0
                        for item in items {
                            guard session.attachmentSelectionGeneration == selection,
                                  photoSelectionID == photoSelection else { break }
                            // U16：读取失败不再静默跳过；计数后在输入栏上方明确呈现，
                            defer {
                                if photoSelectionID == photoSelection { photoReadCompletedCount += 1 }
                            }
                            // 部分失败必须确认后才能发送已读取的子集。
                            let data: Data
                            do {
                                guard let loaded = try await item.loadTransferable(type: Data.self) else {
                                    failed += 1
                                    continue
                                }
                                data = loaded
                            } catch {
                                failed += 1
                                continue
                            }
                            guard let mime = imageMimeType(data) else {
                                // 不支持解码的格式（例如 HEIC）不能直接标成 JPEG。
                                failed += 1
                                continue
                            }
                            let ext = mime == "image/png" ? "png" : (mime == "image/webp" ? "webp" : "jpg")
                            let added = await session.addImage(
                                data: data,
                                mimeType: mime,
                                fileName: "photo-\(UUID().uuidString).\(ext)"
                            )
                            if added { succeeded += 1 } else { failed += 1 }
                        }
                        guard session.attachmentSelectionGeneration == selection,
                              photoSelectionID == photoSelection else {
                            if photoSelectionID == photoSelection { isReadingPhotos = false }
                            return
                        }
                        isReadingPhotos = false
                        photoReadFailureCount = failed
                        photoReadSucceededCount = succeeded
                        photoReadAcknowledged = false
                        selectedPhotos = []
                    }
                }
                // 占位文字自己画、自己对齐：原生 placeholder 跟着输入框内部基线走，
                // 单行时看起来比左右按钮低一点。输入框固定 44pt 高后，占位和实际
                // 文字都在这条中线上，空态、输入态、换行态不会各偏各的。
                TextField("", text: $session.draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .frame(minHeight: PIMetrics.minHitTarget)
                    .overlay(alignment: .leading) {
                        if session.draftText.isEmpty {
                            Text("给 Agent 的指令")
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text3)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                    .accessibilityLabel("给 Agent 的指令")
                    .accessibilityIdentifier("conversation.composer")
                Button {
                    if showsAbortButton {
                        Task { await session.interrupt() }
                    } else {
                        guard !isSubmitting, let intent = session.makeSendIntent() else { return }
                        let submission = UUID()
                        submissionID = submission
                        scrollToBottomRequest &+= 1
                        // U11：点击瞬间冻结发送意图；模型可用性检查可能等待网络，
                        // 期间切换会话/模型或继续编辑都由 send(expected:) 拒绝，不会误发。
                        let instruction = session.trimmedDraft
                        let isFirstInstruction = session.view.items.isEmpty
                        // Freeze the title target at click time. Reading it after the
                        // send await could generate a title for a newly switched session.
                        let titleSessionID = session.attachedSessionId
                        let titleHostID = model.currentHost?.id
                        let titleGeneration = connection.currentConnectionGeneration
                        Task {
                            defer {
                                if submissionID == submission { submissionID = nil }
                            }
                            let check = await refreshModelAvailability(reuseRecent: true)
                            guard check != .superseded else { return }
                            await session.send(expected: intent)
                            if submissionID == submission { submissionID = nil }
                            // 新建会话不再预填标题：首条指令成功发出后由 AI 生成。
                            if isFirstInstruction, session.trimmedDraft.isEmpty,
                               let titleSessionID, let titleHostID {
                                await generateTitleIfNeeded(
                                    instruction: instruction,
                                    hostID: titleHostID,
                                    sessionID: titleSessionID,
                                    connectionGeneration: titleGeneration
                                )
                            }
                        }
                    }
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(PIColor.onAccent)
                        } else {
                            Image(systemName: showsAbortButton ? "stop.fill" : "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                        .foregroundStyle(sendButtonEnabled ? PIColor.onAccent : PIColor.text3)
                        .frame(width: 36, height: 36)
                        .background(
                            (sendButtonEnabled || isSubmitting)
                                ? (showsAbortButton ? PIColor.danger : PIColor.accent)
                                : PIColor.surface3,
                            in: Circle()
                        )
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Circle())
                }
                .disabled(!sendButtonEnabled)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier(showsAbortButton ? "conversation.interrupt" : "conversation.send")
                .accessibilityLabel(isSubmitting ? "正在提交" : (showsAbortButton ? "中止" : "发送"))
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(
                PIColor.surface2,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PIColor.separatorStrong, lineWidth: PIMetrics.hairline)
            )
            .shadow(color: PIColor.floatingShadow, radius: 14, y: 5)
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, PISpacing.s8)
        .background(PIColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(height: PIMetrics.hairline)
        }
    }

    /// 用 ImageIO 判定真实格式，不能按扩展名或「非 PNG 即 JPEG」猜测。
    /// 只接受上传协议支持的 JPEG/PNG/WebP；HEIC 等返回 nil 由调用方明确拒绝。
    private func imageMimeType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.jpeg", "public.jpeg-2000": return "image/jpeg"
        case "public.png": return "image/png"
        case "org.webmproject.webp": return "image/webp"
        default: return nil
        }
    }

    /// 发送按钮可用性：附件部分读取失败且未确认时禁止发送（U16）。
    private var canTapSend: Bool {
        session.canSend && !session.isBusy && !isSubmitting && !isReadingPhotos && !photoReadNeedsConfirmation
    }

    /// 输入框为空且会话有任务正在执行时，发送按钮切换成中止按钮；
    /// 一旦输入了内容（文字或附件），仍然保留发送按钮，点击即排队。
    private var showsAbortButton: Bool {
        session.isTurnRunning
            && session.trimmedDraft.isEmpty
            && session.pendingAttachments.isEmpty
    }

    private var sendButtonEnabled: Bool {
        !isSubmitting && (showsAbortButton
            ? session.canInterrupt && !session.isBusy
            : canTapSend)
    }

    /// 最近一次选图的读取失败提示；`nil` 表示没有失败。
    private var photoReadFailureNotice: String? {
        guard photoReadFailureCount > 0 else { return nil }
        if photoReadSucceededCount > 0 {
            return "\(photoReadFailureCount) 张图片读取失败，已读取 \(photoReadSucceededCount) 张"
        }
        return "全部图片读取失败（\(photoReadFailureCount) 张），请重新选择图片。"
    }

    /// 部分失败且未确认：必须显式确认才能发送已读取的子集。
    private var photoReadNeedsConfirmation: Bool {
        photoReadFailureCount > 0 && photoReadSucceededCount > 0 && !photoReadAcknowledged
    }

    /// 保留异常时直接打开会话模型配置的入口；无绑定文案只改成中性名称，不复述错误。
    private var composerModelLabel: String {
        if selectedModelLabel == "模型未绑定" {
            switch session.modelAvailability {
            case .unavailable, .unknown:
                return "会话模型"
            default:
                break
            }
        }
        return selectedModelLabel
    }

    private var composerConfigurationChips: some View {
        HStack(spacing: PISpacing.s8) {
            // 会话模式 / 权限模式不再压在输入框上方：它们仍可在「会话操作 →
            // 会话配置」里查看与切换，输入区只保留与本次发送直接相关的模型信息。
            Spacer(minLength: PISpacing.s4)
            configurationChip(
                title: composerModelLabel,
                tint: PIColor.text2,
                identifier: "composer.modelChip",
                systemImage: "cpu",
                maxWidth: 190,
                alignment: .trailing
            )
            if session.thinkingLevel != nil, selectedModelDeclaresThinking {
                configurationChip(
                    title: session.thinkingLevel?.rawValue ?? "",
                    tint: PIColor.text2,
                    identifier: "composer.thinkingChip",
                    systemImage: "brain.head.profile"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configurationChip(
        title: String,
        tint: Color,
        identifier: String,
        systemImage: String? = nil,
        maxWidth: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Button {
            showingConfig = true
        } label: {
            HStack(spacing: PISpacing.s4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .font(PIFont.metaSmall.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, PISpacing.s8)
            .frame(minHeight: 30)
            .frame(maxWidth: maxWidth, alignment: alignment)
            // 输入区已有唯一外框，模型入口作为轻量文本控件，不再叠第二层胶囊描边。
            // 视觉 30pt 高，热区补足到 44pt（spec AC-7）。
            .padding(.vertical, (PIMetrics.minHitTarget - 30) / 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            session.isTurnRunning
                || session.isBusy
                || !connection.state.isOnline
                || session.attachedSessionId == nil
        )
        .accessibilityIdentifier(identifier)
        .accessibilityHint(
            session.isTurnRunning
                ? "等待当前轮次结束后才能切换"
                : (session.isBusy ? "等待当前操作完成" : "打开会话配置")
        )
    }

    /// 收起键盘：输入框没有 `@FocusState`，直接让当前第一响应者 resign。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var selectedModelDeclaresThinking: Bool {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return false }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return !record.thinkingLevels.isEmpty
            }
        }
        return false
    }

    /// 新建会话的首条指令发出后，让服务器用当前模型生成一个短标题。
    ///
    /// 已经是用户命名 / 已生成过标题的会话不会再调用；旧版 PI-adaptor 没有
    /// `session/suggest-title` 时会退回指令首行，避免会话一直叫「New session」。
    private func generateTitleIfNeeded(
        instruction: String,
        hostID: UUID,
        sessionID: String,
        connectionGeneration: Int
    ) async {
        guard model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID,
              connection.currentConnectionGeneration == connectionGeneration
        else { return }
        let current = model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: sessionID,
            fallback: session.attachedSummary?.title ?? ""
        )
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCurrent.isEmpty
            || normalizedCurrent == "New session"
            || normalizedCurrent == "新会话"
        else { return }

        // 没有绑定的 provider/model 时不调用服务器：直接用指令首行兜底，
        // 不让新会话一直停留在「新会话」。
        var title: String?
        if let providerID = session.selectedProviderId,
           let modelID = session.selectedModelId {
            do {
                title = try await connection.suggestSessionTitle(
                    sessionId: sessionID,
                    instruction: instruction,
                    providerId: providerID,
                    modelId: modelID,
                    apiKey: session.providerAPIKey?(providerID),
                    thinkingLevel: session.thinkingLevel?.rawValue
                )
            } catch {
                title = nil
            }
        }
        let cleaned = sanitizedTitle(title) ?? localFallbackTitle(instruction)
        guard !cleaned.isEmpty else { return }
        // The user may have renamed the session or switched away while the
        // suggestion was in flight; never overwrite a manual title.
        guard model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID,
              connection.currentConnectionGeneration == connectionGeneration
        else { return }
        let latest = model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: sessionID,
            fallback: session.attachedSummary?.title ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard latest.isEmpty || latest == "New session" || latest == "新会话" else { return }
        guard model.renameSession(hostID: hostID, sessionID: sessionID, title: cleaned) else { return }
        // 本机标题先生效；服务器写入失败不回滚本机名称，下次打开仍能看到。
        try? await connection.renameSession(sessionId: sessionID, title: cleaned)
    }

    private func sanitizedTitle(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’。.，,：:；;"))
        value = value.replacingOccurrences(of: "\n", with: " ")
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= 30 ? collapsed : String(collapsed.prefix(30)) + "…"
    }

    private func localFallbackTitle(_ instruction: String) -> String {
        let firstLine = instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? instruction
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        return collapsed.count <= 24 ? collapsed : String(collapsed.prefix(24)) + "…"
    }

    // MARK: - 恢复路径（模型不可用）

    /// 模型不可用的唯一恢复出口：直达「模型服务」子页（不是设置根页）。
    ///
    /// 上一轮删掉「重新检查」时的理由是「打开模型配置就会重新检查」——那是错的：
    /// 检查只在会话 ID / 模型绑定变化时触发，于是模型服务恢复后横幅会一直挂着，
    /// 而唯一的动作只是把用户丢到设置根页，让他自己再找一次。
    /// 现在点一下就落到 `SettingsRoute.models`，修完回到会话页会自动重查。
    ///
    /// 横幅挂在会话页本身、不在浮层里，所以这里**不**调用 `dismiss()`——那会把会话页
    /// 自己关掉。浮层里的同一入口（会话配置的「模型服务」行）由浮层自己先 `dismiss()`。
    /// 兜底：若配置浮层正开着，先关掉再切根，避免设置页被压在半屏浮层底下。
    private func openModelServices() {
        if showingConfig { showingConfig = false }
        model.showSettings(.models)
    }

    /// 恢复路径的有界重查：只在「明确不可用 / 状态未知」时补一次。
    ///
    /// 排除两种状态，避免把一次廉价检查变成服务器压力：
    /// - `.available`：已有可信结论。否则每次开关配置浮层、每次回到会话页都会打一次服务器，
    ///   还会闪一次「正在检查模型可用性」。
    /// - `.checking`：上一次检查还没回来。叠第二次会 `modelAvailabilityGeneration` 自增，
    ///   让先发起的那次返回 `superseded`——并发两次互相覆盖，结论反而更不可信。
    ///
    /// 触发点只有两个：配置浮层关闭、会话页重新出现。没有定时器，也不挂在其它 UI 事件上。
    private func recheckModelAvailabilityIfNeeded() {
        switch session.modelAvailability {
        case .unavailable, .unknown:
            Task { await refreshModelAvailability() }
        case .available, .checking:
            return
        }
    }

    private var modelAvailabilityContextKey: String {
        "\(connection.currentConnectionGeneration):\(session.attachedSessionId ?? ""):\(session.selectedBindingKey):\(session.openingSessionID ?? "")"
    }

    /// 检查当前会话模型的可用性，并返回显式结果（U11）：`superseded` 表示检查期间
    /// 会话/服务器/模型绑定已经被更新的检查取代，发送方必须放弃这次点击而不是继续发送。
    @discardableResult
    private func refreshModelAvailability(reuseRecent: Bool = false) async -> ModelAvailabilityCheckResult {
        guard !Task.isCancelled, session.openingSessionID == nil else { return .superseded }
        if reuseRecent, session.hasRecentModelAvailability() { return .available }
        guard connection.state.isOnline,
              let sessionID = session.attachedSessionId,
              let host = model.currentHost
        else {
            legacyOnlyProviderIDs = []
            session.markModelAvailabilityUnknown("服务器离线或尚未打开会话")
            return .skipped(reason: "服务器离线或尚未打开会话")
        }
        modelAvailabilityGeneration &+= 1
        let generation = modelAvailabilityGeneration
        let bindingKey = session.selectedBindingKey
        let connectionGeneration = connection.currentConnectionGeneration
        session.markModelAvailabilityChecking()
        do {
            // Prefer the v2 PI-adaptor's own provider store; fall back to the legacy
            // SSH-based binding probe for old v1 Hosts.
            let status = try await connection.adaptorV2BindingStatus(sessionId: sessionID)
            guard generation == modelAvailabilityGeneration,
                  !Task.isCancelled, session.openingSessionID == nil,
                  connection.currentConnectionGeneration == connectionGeneration,
                  model.currentHost?.id == host.id,
                  session.attachedSessionId == sessionID,
                  session.selectedBindingKey == bindingKey
            else { return .superseded }
            // A successful v2 probe means the PI-adaptor keeps providers in the v2
            // store; anything our local catalog knows only from the legacy store
            // cannot drive a turn on it.
            let legacyOnly = Set(
                model.currentModelProviders
                    .filter { $0.hostV2Mirror != true }
                    .map(\.providerId)
            )
            legacyOnlyProviderIDs = legacyOnly
            if let reason = Self.legacyOnlyReason(status: status, legacyOnly: legacyOnly) {
                // Self-heal when possible: mirror the legacy-only provider into
                // the v2 store and rebind, if we still hold its key locally.
                let healed = await mirrorLegacyOnlyProvider(
                    pinnedProviderId: status.pinnedProviderId,
                    pinnedModelId: status.pinnedModelId,
                    host: host
                )
                guard !Task.isCancelled, generation == modelAvailabilityGeneration,
                      connection.currentConnectionGeneration == connectionGeneration,
                      model.currentHost?.id == host.id, session.attachedSessionId == sessionID,
                      session.openingSessionID == nil else { return .superseded }
                if healed {
                    session.markModelAvailabilityChecking()
                    return .skipped(reason: "已触发模型重新绑定，正在重新检查可用性")
                } else {
                    session.markModelUnavailable(reason)
                    return .unavailable(reason: reason)
                }
            } else {
                session.applyModelAvailability(status)
                return Self.availabilityCheckResult(session.modelAvailability)
            }
        } catch {
            guard !Task.isCancelled, generation == modelAvailabilityGeneration,
                  connection.currentConnectionGeneration == connectionGeneration,
                  session.openingSessionID == nil else { return .superseded }
            legacyOnlyProviderIDs = []
            do {
                let receipt = try await connection.providerBindingStatus(
                    record: host,
                    sessionId: sessionID
                )
                guard generation == modelAvailabilityGeneration,
                      !Task.isCancelled, session.openingSessionID == nil,
                      connection.currentConnectionGeneration == connectionGeneration,
                      model.currentHost?.id == host.id,
                      session.attachedSessionId == sessionID,
                      session.selectedBindingKey == bindingKey
                else { return .superseded }
                switch receipt {
                case .success(let status):
                    session.applyModelAvailability(status)
                    return Self.availabilityCheckResult(session.modelAvailability)
                case .failure(let failure):
                    session.markModelAvailabilityUnknown(failure.displayMessage)
                    return .failed(reason: failure.displayMessage)
                case .unparseable(let reason):
                    let message = "服务器返回的绑定状态无法解析：\(reason)"
                    session.markModelAvailabilityUnknown(message)
                    return .failed(reason: message)
                }
            } catch {
                guard generation == modelAvailabilityGeneration,
                      !Task.isCancelled, session.openingSessionID == nil,
                      connection.currentConnectionGeneration == connectionGeneration,
                      model.currentHost?.id == host.id,
                      session.attachedSessionId == sessionID,
                      session.selectedBindingKey == bindingKey
                else { return .superseded }
                let message = ConnectionErrorText.describe(error)
                session.markModelAvailabilityUnknown(message)
                return .failed(reason: message)
            }
        }
    }

    private static func availabilityCheckResult(
        _ availability: SessionModelAvailability
    ) -> ModelAvailabilityCheckResult {
        switch availability {
        case .available:
            return .available
        case .checking:
            return .skipped(reason: "正在检查模型可用性")
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .unknown(let reason):
            return .failed(reason: reason)
        }
    }

    /// When the v2 PI-adaptor reports the pinned provider as missing but our local
    /// catalog knows it only from the legacy store, the real cause is the
    /// two-store split — name it and point at the fix (re-import writes the
    /// provider and its key into PI-adaptor) instead of a generic message.
    private static func legacyOnlyReason(
        status: ProviderBindingStatus,
        legacyOnly: Set<String>
    ) -> String? {
        guard status.available != true,
              status.unavailableReason == "provider_missing",
              let providerId = status.pinnedProviderId,
              legacyOnly.contains(providerId)
        else { return nil }
        return "这个模型服务只在服务器的旧存储里，未同步到 PI-adaptor。"
            + "到 设置 → 模型服务 重新导入即可。"
    }

    /// Best-effort self-heal for the two-store split (§7): when a session is
    /// bound to a provider that exists only in the legacy store, and we still
    /// hold its API key in the Keychain, mirror it into the v2 PI-adaptor store and
    /// rebind the session to the mirrored provider id. Returns true when a
    /// rebind was issued (a fresh availability check follows).
    private func mirrorLegacyOnlyProvider(
        pinnedProviderId: String?,
        pinnedModelId: String?,
        host: HostRecord
    ) async -> Bool {
        guard let pinnedProviderId, let pinnedModelId else { return false }
        guard let local = model.currentModelProviders.first(where: {
            $0.providerId == pinnedProviderId && $0.hostV2Mirror != true
        }) else { return false }
        guard let key = KeychainStore.loadProviderKey(hostID: host.id, providerId: pinnedProviderId),
              let operation = model.providerOperationContext(for: host)
        else { return false }
        let specs = local.models.map(\.providerSpec)
        guard let mirrored = try? await connection.registerAdaptorProvider(
            name: local.name,
            vendorKey: "mirror-\(UUID().uuidString)",
            baseURL: local.baseURL,
            apiKey: key,
            models: specs
        ), model.canApplyProviderOperation(operation) else { return false }
        let input = ProviderCreateInput(
            name: local.name,
            vendorKey: mirrored.vendorKey,
            type: mirrored.type,
            protocol: mirrored.protocolName,
            authKind: mirrored.authKind,
            baseUrl: local.baseURL,
            models: specs,
            defaultModelId: local.defaultModelId
        )
        guard model.recordImportedProvider(
            context: operation,
            input: input,
            providerId: mirrored.id,
            serverDefaultSet: false,
            legacyProviderId: pinnedProviderId,
            hostV2Mirror: true
        ) else { return false }
        // 镜像后会话绑定的是新的 v2 provider id；Keychain 里的明文仍挂在 legacy id
        // 下。发送路径按会话里的 provider id 取 key，这里不同步写一份就会得到
        // PROVIDER_SECRET_MISSING——provider 已上传服务器、key 却没有同步。
        if !KeychainStore.saveProviderKey(key, hostID: host.id, providerId: mirrored.id) {
            PILog.warn(
                "Model",
                "provider 镜像后本机密钥写入失败 provider=\(String(mirrored.id.prefix(8)))"
            )
        } else {
            PILog.info(
                "Model",
                "provider 镜像完成 provider=\(String(mirrored.id.prefix(8))) legacy=\(String(pinnedProviderId.prefix(8))) key=synced"
            )
        }
        await session.configure(providerId: mirrored.id, modelId: pinnedModelId)
        return true
    }

    private var selectedModelLabel: String {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return "模型未绑定" }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return "\(group.name) · \(record.displayName)"
            }
        }
        return "\(providerID) · \(modelID)"
    }
}

/// 模型可用性检查的显式结果（U11）。发送按钮在等待检查后必须能区分
/// 「仍可用」「不可用/失败」与「检查结果已被更新的会话/绑定取代」。
private enum ModelAvailabilityCheckResult: Equatable {
    case available
    case unavailable(reason: String)
    case failed(reason: String)
    case skipped(reason: String)
    /// 检查期间会话/服务器/模型绑定已变化，本次结果不再适用于点击时的意图。
    case superseded
}

private struct ConversationContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationItemFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Explicit copy action kept separate from selectable text so long press always
/// belongs to the system selection gesture. Empty bodies intentionally copy "".
private func copyMessageButton(_ item: RACPItem) -> some View {
    copyMessageButton(
        text: item.text ?? "",
        identifier: "conversation.copyMessage.\(item.id)"
    )
}

private func copyMessageButton(_ entry: OfflineSessionCacheEntry) -> some View {
    copyMessageButton(
        text: entry.text,
        identifier: "conversation.offlineCopyMessage.\(entry.id)"
    )
}

private func copyMessageButton(text: String, identifier: String) -> some View {
    Button {
        UIPasteboard.general.string = text
    } label: {
        Label("复制消息", systemImage: "doc.on.doc")
            .labelStyle(.iconOnly)
    }
    .buttonStyle(.borderless)
    .font(PIFont.caption)
    .foregroundStyle(PIColor.text2)
    .frame(width: 32, height: 32)
    .contentShape(Rectangle())
    .accessibilityLabel("复制消息")
    .accessibilityIdentifier(identifier)
}

private struct ToolItemCard: View {
    enum Style {
        /// 线程里单独出现的一条工具调用。
        case standalone
        /// 分组展开后的子条目：底色更浅、层级更紧凑。
        case nested
    }

    let item: RACPItem
    var style: Style = .standalone
    var showsStatus: Bool = true
    private let presentation: ToolResultPresentation
    @State private var expanded = false
    @State private var renderStartedAt: TimeInterval?
    @State private var renderMilliseconds: Double?
    @State private var firstFrameMilliseconds: Double?
    private let measuresRender: Bool

    /// 超过这个体积才把正文放进定高滚动区，短结果仍然随卡片自然增高。
    private static let inlineBodyByteLimit = 1_200
    private static let maxBodyHeight: CGFloat = 280

    init(item: RACPItem, style: Style = .standalone, showsStatus: Bool = true) {
        self.item = item
        self.style = style
        self.showsStatus = showsStatus
        presentation = ToolResultPresentation(text: item.text ?? "")
#if DEBUG
        measuresRender = ProcessInfo.processInfo.environment["PI_IOS_MEASURE_TOOL_RENDER"] == "1"
#else
        measuresRender = false
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolRowHeader(
                icon: ToolVisuals.icon(for: item.status),
                iconTint: ToolVisuals.iconTint(for: item.status),
                title: toolTitle,
                statusText: showsStatus
                    ? (ToolStatusPresentation.label(for: item.status) ?? "状态未知")
                    : nil,
                statusTint: ToolVisuals.statusTint(for: item.status),
                summary: collapsedSummary,
                isExpanded: expanded,
                titleIdentifier: "toolCard.\(item.id).title",
                statusIdentifier: showsStatus ? "toolCard.\(item.id).status" : nil
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleExpansion() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolCard.\(item.id).toggle")
            .accessibilityValue(renderMeasurementValue)
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if let text = item.text, !text.isEmpty {
                        if presentation.preview.utf8.count > Self.inlineBodyByteLimit {
                            ScrollView(.vertical) {
                                resultText
                            }
                            .frame(height: Self.maxBodyHeight)
                            .scrollIndicators(.visible)
                            .clipShape(RoundedRectangle(cornerRadius: PISpacing.s8, style: .continuous))
                        } else {
                            resultText
                        }
                        if let notice = presentation.truncationNotice {
                            Text(notice)
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text2)
                                .accessibilityIdentifier("toolCard.\(item.id).truncation")
                        }
                    }
                    // 结束但没有正文：折叠行已经写了「无输出」，展开区不再复述（R9）。
                    if let emptyBodyNotice {
                        Text(emptyBodyNotice)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .accessibilityIdentifier("toolCard.\(item.id).emptyBody")
                    }
                    HStack {
                        Spacer()
                        copyMessageButton(item)
                    }
                }
                .padding(.top, PISpacing.s4)
                .padding(.bottom, PISpacing.s8)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toolCard.\(item.id).body")
            }
        }
        .padding(.horizontal, style == .nested ? 0 : PISpacing.s12)
        .background(cardBackground)
        .overlay(cardBorder)
        .animation(.easeInOut(duration: 0.22), value: expanded)
    }

    private var resultText: some View {
        Text(presentation.preview)
            .font(PIFont.caption)
            .foregroundStyle(PIColor.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("toolCard.\(item.id).preview")
            .onAppear { finishRenderMeasurement() }
            .background {
#if DEBUG
                if measuresRender, let renderStartedAt {
                    ToolFirstFrameProbe(startedAt: renderStartedAt) { milliseconds in
                        guard firstFrameMilliseconds == nil else { return }
                        firstFrameMilliseconds = milliseconds
                    }
                }
#endif
            }
    }

    /// 折叠态一行摘要：有正文取正文首行，没正文时只在结束时说明「无输出」，
    /// 运行中的状态已经由标题旁的状态文案表达，不再重复。
    private var collapsedSummary: String? {
        if let summary = presentation.summary() { return summary }
        if ToolStatusPresentation.isRunning(item.status) { return nil }
        return "无输出"
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch style {
        case .standalone:
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .fill(PIColor.surface)
        case .nested:
            // 外层 ToolRunCard 已提供唯一表面与边界，内部行只保留内容。
            Color.clear
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        switch style {
        case .standalone:
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        case .nested:
            EmptyView()
        }
    }

    private func toggleExpansion() {
        if !expanded {
            renderStartedAt = CACurrentMediaTime()
            renderMilliseconds = nil
            firstFrameMilliseconds = nil
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            expanded.toggle()
        }
    }

    private func finishRenderMeasurement() {
        guard measuresRender,
              renderMilliseconds == nil,
              let started = renderStartedAt
        else { return }
        renderMilliseconds = (CACurrentMediaTime() - started) * 1_000
    }

    private var renderMeasurementValue: String {
        guard let renderMilliseconds, let firstFrameMilliseconds else { return "" }
        return String(
            format: "renderMs=%.3f;firstFrameMs=%.3f",
            renderMilliseconds,
            firstFrameMilliseconds
        )
    }

    /// 工具名就是标题：图标已经说明这是工具调用，不再加「工具 · 」前缀。
    private var toolTitle: String {
        let name = item.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "工具调用" : name
    }

    /// 运行中的工具只是还没有正文；把「还没输出」说成「没有返回正文」会让用户
    /// 以为工具已经结束、结果丢了。结束且真的没有正文时，折叠行已经说了「无输出」，
    /// 这里不再复述。
    private var emptyBodyNotice: String? {
        if item.status == nil || ToolStatusPresentation.isRunning(item.status) {
            return "执行中"
        }
        return nil
    }
}

/// 一轮对话的中间过程分组：默认折叠成一行「N 次工具调用 + 工具名汇总 + 状态」，
/// 展开后逐条显示紧凑的工具行与工具之间的过渡消息；工具行仍可再展开查看完整结果。
private struct ToolRunCard: View {
    let group: ToolCallGroup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolRowHeader(
                icon: "wrench.and.screwdriver",
                iconTint: group.hasFailure ? PIColor.danger : PIColor.text2,
                title: group.title,
                statusText: group.statusSummary,
                // 运行中不是强调色场景：accent 只用于可交互（quiet-v2 §2）。
                statusTint: group.hasFailure
                    ? PIColor.danger
                    : (group.isRunning ? PIColor.text2 : PIColor.success),
                summary: group.toolSummary,
                isExpanded: expanded,
                titleIdentifier: "toolGroup.\(group.items.first?.id ?? group.id).title",
                statusIdentifier: "toolGroup.\(group.items.first?.id ?? group.id).status"
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.22)) {
                    expanded.toggle()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolGroup.\(group.items.first?.id ?? group.id).toggle")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    PIRowDivider(leadingInset: 0)
                        .padding(.top, PISpacing.s4)
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { PIRowDivider(leadingInset: 0) }
                        if item.isToolItem {
                            ToolItemCard(
                                item: item,
                                style: .nested,
                                showsStatus: !allItemsCompleted
                            )
                        } else {
                            ToolRunMessage(item: item)
                        }
                    }
                }
                .padding(.bottom, PISpacing.s8)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PISpacing.s12)
        .background(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .fill(PIColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .animation(.easeInOut(duration: 0.22), value: expanded)
    }

    /// 只有整组完成时才省略子行重复状态；混合组继续显示每一项的真实状态。
    private var allItemsCompleted: Bool {
        !group.toolItems.isEmpty
            && group.toolItems.allSatisfy { ToolStatusPresentation.isCompleted($0.status) }
    }
}

/// 分组内的中间过程消息：工具调用之间的过渡说明，展开分组后按正文样式展示。
private struct ToolRunMessage: View {
    let item: RACPItem

    var body: some View {
        HStack(alignment: .top, spacing: PISpacing.s8) {
            PIMarkdownView(text: item.text ?? item.kind ?? "条目")
                .padding(.horizontal, PISpacing.s8)
                .padding(.vertical, PISpacing.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("toolGroup.message.\(item.id)")
            copyMessageButton(item)
        }
    }
}

/// 工具行标题：工具名/数量、状态、结果摘要各占清晰层级，整体保持两行以内的紧凑高度。
private struct ToolRowHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let icon: String
    let iconTint: Color
    let title: String
    let statusText: String?
    let statusTint: Color
    let summary: String?
    let isExpanded: Bool
    var titleIdentifier: String? = nil
    var statusIdentifier: String? = nil

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                HStack(spacing: PISpacing.s8) {
                    leadingContent
                    Spacer(minLength: PISpacing.s4)
                    chevron
                }
                summaryContent
                    .padding(.leading, 28)
            }
            .frame(minHeight: PIMetrics.minHitTarget, alignment: .leading)
        } else {
            HStack(spacing: PISpacing.s8) {
                leadingContent
                summaryContent
                chevron
            }
            .frame(minHeight: PIMetrics.minHitTarget)
        }
    }

    private var leadingContent: some View {
        HStack(spacing: PISpacing.s8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .layoutPriority(2)
                .piOptionalIdentifier(titleIdentifier)
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(PIFont.metaSmall.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .piOptionalIdentifier(statusIdentifier)
            }
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary, !summary.isEmpty {
            Text(summary)
                .font(PIFont.metaSmall)
                .foregroundStyle(PIColor.text2)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 0)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PIColor.text3)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

private enum ToolVisuals {
    static func icon(for status: String?) -> String {
        if ToolStatusPresentation.isFailure(status) { return "exclamationmark.triangle" }
        if ToolStatusPresentation.isRunning(status) { return "clock" }
        if ToolStatusPresentation.isCancelled(status) { return "xmark.circle" }
        return "wrench.and.screwdriver"
    }

    static func iconTint(for status: String?) -> Color {
        if ToolStatusPresentation.isFailure(status) { return PIColor.danger }
        if ToolStatusPresentation.isRunning(status) { return PIColor.text2 }
        return PIColor.text2
    }

    static func statusTint(for status: String?) -> Color {
        if ToolStatusPresentation.isFailure(status) { return PIColor.danger }
        if ToolStatusPresentation.isRunning(status) { return PIColor.text2 }
        if ToolStatusPresentation.isCompleted(status) { return PIColor.success }
        return PIColor.text3
    }
}

#if DEBUG
private struct ToolFirstFrameProbe: UIViewRepresentable {
    let startedAt: TimeInterval
    let onFirstFrame: (Double) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.startedAt = startedAt
        view.onFirstFrame = onFirstFrame
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.startedAt = startedAt
        uiView.onFirstFrame = onFirstFrame
    }

    final class ProbeView: UIView {
        var startedAt: TimeInterval = 0
        var onFirstFrame: ((Double) -> Void)?
        private var displayLink: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frameCommitted(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func frameCommitted(_ link: CADisplayLink) {
            let milliseconds = (link.timestamp - startedAt) * 1_000
            link.invalidate()
            displayLink = nil
            onFirstFrame?(milliseconds)
        }
    }
}
#endif

/// 只在有值时套 identifier：避免空字符串标识混进无障碍树。
private struct PIOptionalIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier, !identifier.isEmpty {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

extension View {
    func piOptionalIdentifier(_ identifier: String?) -> some View {
        modifier(PIOptionalIdentifier(identifier: identifier))
    }
}

// MARK: - 会话配置（AC-07）

private struct SessionConfigSheet: View {
    @ObservedObject var session: SessionController
    let groups: [ProviderModelGroup]
    let diagnostics: [ModelGroupingDiagnostic]
    /// Providers our local catalog knows but the connected v2 PI-adaptor's own store
    /// does not (legacy-only imports); their models cannot drive a turn.
    let unavailableProviderIDs: Set<String>
    let extensionSessionID: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    private var selectedBinding: ModelRecord? {
        flatten(groups).first {
            $0.providerId == session.selectedProviderId && $0.modelId == session.selectedModelId
        }
    }

    private var configLocked: Bool { session.isTurnRunning || session.isBusy }
    private var configEnabled: Bool { !configLocked && session.isOnline && session.attachedSessionId != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    if !diagnostics.isEmpty {
                        PIInlineMessage(
                            kind: .warning,
                            text: "模型清单有重复记录：\(diagnostics.map(\.message).joined(separator: "\n"))"
                        )
                    }
                    if !unavailableProviderIDs.isEmpty {
                        PIInlineMessage(
                            kind: .warning,
                            text: "有模型只存在于服务器的旧存储，未同步到 PI-adaptor。"
                                + "到 设置 → 模型服务 重新导入即可。"
                        )
                    }
                    if configLocked {
                        PIInlineMessage(kind: .warning, text: "当前轮次仍在运行：本轮结束后可切换。")
                    } else if !session.isOnline {
                        PIInlineMessage(kind: .warning, text: "服务器离线，恢复连接后才能提交。")
                    }
                    if let sessionID = extensionSessionID {
                        SessionExtensionsLink(catalog: model.connection.extensions, sessionID: sessionID)
                    }
                    // quiet-v2 §6.3：配置组不再用 footer 解释协议名。单选控件用勾选表达状态，
                    // 选择即提交，用户从行本身就能读懂。
                    PIGroup("权限模式") {
                        let modes = RACPPermissionMode.allCases
                        ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                            configOptionRow(
                                title: mode.title,
                                isSelected: session.permissionMode == mode,
                                showsDivider: index != modes.count - 1,
                                identifier: "conversation.config.permission.\(mode.rawValue)"
                            ) {
                                Task { await session.configure(permissionMode: mode) }
                            }
                        }
                    }
                    PIGroup("会话模式") {
                        let modes = RACPSessionMode.allCases
                        ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                            configOptionRow(
                                title: mode.title,
                                isSelected: session.sessionMode == mode,
                                showsDivider: index != modes.count - 1,
                                identifier: "conversation.config.mode.\(mode.rawValue)"
                            ) {
                                Task { await session.configure(mode: mode) }
                            }
                        }
                    }
                    PIGroup("模型") {
                        if groups.isEmpty {
                            // quiet-v2：原来是一行禁用说明（"先到 设置 → 模型服务 导入模型"），
                            // 属于用文案补布局。改成可点的出口：状态写在副标题，动作在行本身。
                            PIListRow(
                                title: "模型服务",
                                subtitle: "没有可用模型",
                                showsChevron: true,
                                showsDivider: false,
                                action: {
                                    // 浮层自己先关，再走同一条深链：落到「模型服务」子页，
                                    // 不是设置根页——用户已经选了「模型服务」，不该再找一次。
                                    dismiss()
                                    model.showSettings(.models)
                                }
                            )
                            .accessibilityIdentifier("conversation.openModelServices")
                        } else {
                            ForEach(groups.indices, id: \.self) { groupIndex in
                                let group = groups[groupIndex]
                                Text(group.name)
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                                    .padding(.horizontal, PISpacing.s16)
                                    .padding(.top, groupIndex == 0 ? 0 : PISpacing.s8)
                                ForEach(group.models.indices, id: \.self) { modelIndex in
                                    let record = group.models[modelIndex]
                                    let unavailable = isUnavailable(record)
                                    PIListRow(
                                        title: record.displayName,
                                        subtitle: unavailable
                                            ? "\(modelSubtitle(record)) · 未同步"
                                            : modelSubtitle(record),
                                        value: isSelected(record) ? "当前" : nil,
                                        isEnabled: configEnabled && !unavailable,
                                        showsDivider: !(groupIndex == groups.count - 1 && modelIndex == group.models.count - 1),
                                        action: { select(record) }
                                    )
                                    .accessibilityIdentifier("conversation.config.model.\(record.modelId)")
                                }
                            }
                        }
                    }
                    if let selectedBinding, !selectedBinding.thinkingLevels.isEmpty {
                        PIGroup("思考档位") {
                            let levels = selectedBinding.thinkingLevels
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, raw in
                                configOptionRow(
                                    title: raw,
                                    isSelected: session.thinkingLevel?.rawValue == raw,
                                    showsDivider: index != levels.count - 1,
                                    identifier: "conversation.config.thinking.\(raw)"
                                ) {
                                    Task { await select(selectedBinding, thinking: RACPThinkingLevel(rawValue: raw)) }
                                }
                            }
                        }
                    }
                    if let notice = session.thinkingFallbackNotice {
                        PIInlineMessage(kind: .info, text: "档位已调整：\(notice)")
                    }
                    if let error = session.lastError {
                        PIInlineMessage(kind: .danger, text: "配置未生效：\(error)")
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("会话配置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 单选行：勾选即状态。footer 删掉后，选中态就是唯一的约束表达。
    @ViewBuilder
    private func configOptionRow(
        title: String,
        isSelected: Bool,
        showsDivider: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        PIOptionRow(
            title: title,
            isSelected: isSelected,
            showsDivider: showsDivider,
            action: action
        )
        .disabled(!configEnabled)
        .accessibilityIdentifier(identifier)
    }

    private func isSelected(_ record: ModelRecord) -> Bool {
        record.providerId == session.selectedProviderId && record.modelId == session.selectedModelId
    }

    private func isUnavailable(_ record: ModelRecord) -> Bool {
        guard let providerId = record.providerId else { return false }
        return unavailableProviderIDs.contains(providerId)
    }

    private func modelSubtitle(_ record: ModelRecord) -> String {
        var parts = [record.modelId]
        if let context = record.contextWindow {
            parts.append("\(compactModelTokens(context)) ctx")
        }
        if let output = record.maxTokens {
            parts.append("\(compactModelTokens(output)) output")
        }
        if !record.thinkingLevels.isEmpty {
            parts.append("思考 \(record.thinkingLevels.joined(separator: "/"))")
        }
        return parts.joined(separator: " · ")
    }

    private func compactModelTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }

    private func select(_ record: ModelRecord, thinking: RACPThinkingLevel? = nil) {
        guard let providerId = record.providerId else { return }
        let levels = record.thinkingLevels.compactMap(RACPThinkingLevel.init(rawValue:))
        let support = ThinkingLevelSupport(
            declared: levels,
            defaultLevel: record.defaultThinkingLevel.flatMap(RACPThinkingLevel.init(rawValue:))
        )
        Task {
            await session.configure(
                providerId: providerId,
                modelId: record.modelId,
                thinkingLevel: thinking,
                thinkingSupport: support
            )
        }
    }
}

/// 在发出历史请求前同步记录旧行位置；工具分组跨页重组时，新行也能沿用同一像素基准。
@MainActor
final class ConversationViewportMeasurement {
    private final class WeakAnchor {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var anchors: [String: WeakAnchor] = [:]
    private(set) var requestID: UUID?
    private(set) var itemID: String?
    private(set) var viewportY: CGFloat?
    private(set) var appliedRequestID: UUID?

#if DEBUG
    var activeAnchorCount: Int { anchors.values.filter { $0.view?.window != nil }.count }
    var registeredAnchorCount: Int { anchors.count }
#endif

    func register(_ view: UIView, itemID: String) {
        anchors[itemID] = WeakAnchor(view)
    }

    func unregister(_ view: UIView, itemID: String) {
        if anchors[itemID]?.view === view { anchors.removeValue(forKey: itemID) }
    }

    func begin(requestID: UUID, itemID: String?, topSpacing: CGFloat) {
        anchors = anchors.filter { $0.value.view != nil }
        self.requestID = requestID
        self.itemID = itemID
        viewportY = nil
        appliedRequestID = nil
        guard let itemID, let view = anchors[itemID]?.view,
              view.window != nil, let scrollView = view.enclosingScrollView else { return }
        let contentMinY = ConversationViewportGeometry.pagingContentMinY(
            anchorMinY: view.convert(view.bounds, to: scrollView).minY,
            topSpacing: topSpacing
        )
        viewportY = ConversationViewportGeometry.viewportMinY(
            contentMinY: contentMinY,
            contentOffsetY: scrollView.contentOffset.y
        )
    }

    func markApplied(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        appliedRequestID = requestID
    }

    func cancel() {
        requestID = nil
        itemID = nil
        viewportY = nil
        appliedRequestID = nil
    }
}

/// SwiftUI's item-level `ScrollViewReader.scrollTo`/`scrollPosition` can keep the
/// previous offset when session content is swapped in place. This anchor applies
/// the restore directly to the enclosing UIScrollView, then the measured frame is
/// used by `ConversationScreen` to confirm success.
private struct ReadingRestoreAnchor: UIViewRepresentable {
    private static let historySettlePasses = 8

    let itemID: String
    let targetID: String?
    let requestID: Int
    let historyAnchorID: String?
    let historyTopSpacing: CGFloat
    let historyRequestID: UUID?
    let viewportMeasurement: ConversationViewportMeasurement
    let onUserInteraction: () -> Void

    final class Coordinator {
        var itemID: String?
        var viewportMeasurement: ConversationViewportMeasurement?
        var appliedRequestID = 0
        var historyRequestID: UUID?
        var historyTopSpacing: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.itemID != itemID,
           let oldItemID = context.coordinator.itemID {
            viewportMeasurement.unregister(uiView, itemID: oldItemID)
        }
        context.coordinator.itemID = itemID
        context.coordinator.viewportMeasurement = viewportMeasurement
        viewportMeasurement.register(uiView, itemID: itemID)
        if targetID != itemID { context.coordinator.appliedRequestID = 0 }
        if historyAnchorID != itemID { context.coordinator.historyRequestID = nil }
        context.coordinator.historyTopSpacing = historyTopSpacing
        updateHistoryPosition(uiView, coordinator: context.coordinator)
        guard targetID == itemID,
              requestID > 0,
              context.coordinator.appliedRequestID != requestID
        else { return }
        context.coordinator.appliedRequestID = requestID
        let expectedRequestID = requestID

        DispatchQueue.main.async {
            guard context.coordinator.appliedRequestID == expectedRequestID else { return }
            guard uiView.window != nil,
                  let scrollView = uiView.enclosingScrollView
            else {
                context.coordinator.appliedRequestID = 0
                return
            }
            guard !scrollView.isDragging,
                  !scrollView.isTracking,
                  !scrollView.isDecelerating
            else {
                onUserInteraction()
                return
            }
            scrollView.layoutIfNeeded()
            let current = uiView.convert(uiView.bounds, to: scrollView)
            let inset = scrollView.adjustedContentInset
            // Both restore confirmation and this correction use the same
            // canonical viewport top: visual top minus the adjusted top inset.
            let desiredY = ConversationViewportGeometry.restoreContentOffsetY(
                anchorContentMinY: current.minY,
                adjustedTopInset: inset.top
            )
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
            )
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: min(max(desiredY, minimumY), maximumY)
                ),
                animated: false
            )
        }
    }

    private func updateHistoryPosition(_ uiView: UIView, coordinator: Coordinator) {
        guard let historyRequestID, historyAnchorID == itemID,
              viewportMeasurement.requestID == historyRequestID,
              viewportMeasurement.appliedRequestID != historyRequestID,
              let viewportY = viewportMeasurement.viewportY else {
            coordinator.historyRequestID = nil
            return
        }
        guard coordinator.historyRequestID != historyRequestID else { return }
        coordinator.historyRequestID = historyRequestID
        settleHistoryPosition(
            uiView,
            coordinator: coordinator,
            requestID: historyRequestID,
            viewportY: viewportY,
            pass: 0
        )
    }

    /// Hold the pre-page viewport origin across a few layout passes. A single
    /// correction can run before the load control / merged row finishes laying
    /// out, which leaves the original item a few points off even though the
    /// first offset was correct. Any user drag aborts this immediately.
    private func settleHistoryPosition(
        _ uiView: UIView,
        coordinator: Coordinator,
        requestID: UUID,
        viewportY: CGFloat,
        pass: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard coordinator.historyRequestID == requestID,
                  viewportMeasurement.requestID == requestID,
                  viewportMeasurement.appliedRequestID != requestID else { return }
            guard uiView.window != nil,
                  let scrollView = uiView.enclosingScrollView else {
                coordinator.historyRequestID = nil
                return
            }
            guard !scrollView.isDragging, !scrollView.isTracking, !scrollView.isDecelerating else {
                onUserInteraction()
                return
            }
            scrollView.layoutIfNeeded()
            let inset = scrollView.adjustedContentInset
            let minimumY = -inset.top
            let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
            let anchorMinY = uiView.convert(uiView.bounds, to: scrollView).minY
            let contentMinY = ConversationViewportGeometry.pagingContentMinY(
                anchorMinY: anchorMinY,
                topSpacing: coordinator.historyTopSpacing
            )
            let targetY = min(max(contentMinY - viewportY, minimumY), maximumY)
            if abs(scrollView.contentOffset.y - targetY) > 0.5 {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: targetY),
                    animated: false
                )
            }
            if pass + 1 >= ReadingRestoreAnchor.historySettlePasses {
                viewportMeasurement.markApplied(requestID)
            } else {
                settleHistoryPosition(
                    uiView,
                    coordinator: coordinator,
                    requestID: requestID,
                    viewportY: viewportY,
                    pass: pass + 1
                )
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let itemID = coordinator.itemID,
              let viewportMeasurement = coordinator.viewportMeasurement else { return }
        viewportMeasurement.unregister(uiView, itemID: itemID)
    }

}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}
private struct AttachmentReadSource {
    let key: AttachmentImageKey
    let read: AttachmentImageLoader.Read

    static func current(attachment: RACPV2Attachment, hostID: UUID?, client: RACPClient?) -> Self? {
        guard let hostID else { return nil }
        if let client {
            return Self(
                key: AttachmentImageKey(hostID: hostID, connectionID: ObjectIdentifier(client), attachment: attachment),
                read: { offset, length in
                    try await client.readImageAttachment(attachmentId: attachment.id, offset: offset, length: length)
                }
            )
        }
#if DEBUG
        if let fixture = UITestFixture.stabilityImageSource(attachment: attachment, hostID: hostID) {
            return Self(key: fixture.key, read: fixture.read)
        }
#endif
        return nil
    }
}

struct AttachmentThumbnailView: View {
    let attachment: RACPV2Attachment
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDetail = false
    @State private var loadID = UUID()

    private var source: AttachmentReadSource? {
        AttachmentReadSource.current(attachment: attachment, hostID: model.currentHost?.id, client: connection.activeClient)
    }

    private var key: AttachmentImageKey? { source?.key }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(PIRadius.control)
                    .onTapGesture { showingDetail = true }
                    .accessibilityLabel("查看图片")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("conversation.attachment.\(attachment.id)")
            } else if isLoading {
                ProgressView().frame(height: 100)
            } else if loadFailed {
                Label("图片加载失败", systemImage: "exclamationmark.triangle")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.danger)
                    .accessibilityIdentifier("conversation.attachment.\(attachment.id).error")
            } else {
                Label(attachment.fileName, systemImage: "photo")
                    .font(PIFont.meta)
                    .padding(PISpacing.s8)
                    .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control))
            }
        }
        .task(id: key) { await loadImage() }
        .onChange(of: key) { _, newKey in
            if newKey == nil {
                showingDetail = false
            }
        }
        .onDisappear {
            loadID = UUID()
            uiImage = nil
            isLoading = false
            showingDetail = false
        }
        .sheet(isPresented: $showingDetail) {
            if let source {
                AttachmentImageDetail(attachment: attachment, key: source.key, read: source.read, session: connection.session)
            } else {
                Color.clear
                    .onAppear { showingDetail = false }
            }
        }
    }

    private func loadImage() async {
        let requestID = UUID()
        loadID = requestID
        uiImage = nil
        loadFailed = false
        isLoading = false
        guard let source else { return }
        let key = source.key
        isLoading = true
        defer { if loadID == requestID { isLoading = false } }
        do {
            let bitmap = try await AttachmentImageLoader.shared.thumbnail(key: key, attachment: attachment, read: source.read)
            guard !Task.isCancelled, loadID == requestID, self.key == key else { return }
            uiImage = UIImage(cgImage: bitmap.image)
        } catch is CancellationError {
            // A disappearing row has no failure to present.
        } catch {
            guard !Task.isCancelled, loadID == requestID, self.key == key else { return }
            loadFailed = true
        }
    }
}

private struct AttachmentImageDetail: View {
    let attachment: RACPV2Attachment
    let key: AttachmentImageKey
    let read: AttachmentImageLoader.Read
    @ObservedObject var session: SessionController
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: AttachmentImageContent?
    @State private var failed = false

    private var isCurrent: Bool {
        session.attachedSessionId == key.sessionID
            && AttachmentReadSource.current(attachment: attachment, hostID: model.currentHost?.id,
                                            client: connection.activeClient)?.key == key
    }

    var body: some View {
        NavigationStack {
            VStack {
                if let content {
                    let image = Image(uiImage: UIImage(cgImage: content.bitmap.image))
                    image.resizable().scaledToFit().padding()
                        .accessibilityIdentifier("conversation.attachment.detailImage")
                        .accessibilityLabel("原图")
#if DEBUG
                    Text(verbatim: "width=\(content.bitmap.image.width),height=\(content.bitmap.image.height),bytes=\(content.original.count)")
                        .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                        .accessibilityIdentifier("conversation.attachment.debugDetailContent")
#endif
                    shareLink(for: content, previewImage: image)
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .accessibilityIdentifier("conversation.attachment.shareOriginal")
                } else if failed {
                    Label("图片加载失败", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("正在读取原图…")
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }
                    .accessibilityIdentifier("conversation.attachment.closeDetail")
            }
        }
        .task(id: isCurrent) {
            guard isCurrent else { content = nil; dismiss(); return }
            do {
                let loaded = try await AttachmentImageLoader.shared.detail(attachment: attachment, read: read)
                guard !Task.isCancelled, isCurrent else { return }
                content = loaded
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, isCurrent { failed = true }
            }
        }
        .onDisappear { content = nil }
    }

    @ViewBuilder
    private func shareLink(
        for content: AttachmentImageContent,
        previewImage: Image
    ) -> some View {
        let format = AttachmentShareFormat(
            mimeType: attachment.mimeType,
            fileName: attachment.fileName
        )
        let fileName = format.normalizedFileName(attachment.fileName)
        let preview = SharePreview(fileName, image: previewImage)
        switch format {
        case .png:
            ShareLink(
                item: AttachmentOriginal<PNGOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        case .jpeg:
            ShareLink(
                item: AttachmentOriginal<JPEGOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        case .webp:
            ShareLink(
                item: AttachmentOriginal<WebPOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        }
    }

    private var shareLabel: some View {
        Label("保存或分享图片", systemImage: "square.and.arrow.up")
    }
}


/// 审批卡“查看完整参数”弹层内容。
private struct ApprovalFullInput: Identifiable {
    let id: String
    let title: String
    let text: String
}
