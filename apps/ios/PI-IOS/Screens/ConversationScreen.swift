import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import PIiOSCore
import PIiOSNet

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
    @State private var hasNewBelow = false
    @State private var scrollToBottomRequest = 0
    @State private var isCheckingModelAvailability = false
    @State private var modelAvailabilityGeneration = 0
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
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionID = UUID()
    /// U16：最近一次选图的读取失败数 / 成功读取数 / 部分失败是否已确认发送子集。
    @State private var photoReadFailureCount = 0
    @State private var photoReadSucceededCount = 0
    @State private var photoReadAcknowledged = false

    init(session: SessionController) {
        self.session = session
    }

    private var currentHost: HostRecord? { model.currentHost }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                // 待审批卡片固定在滚动区之上，不随会话滚动：它是「工具正在等你的决定」的
                // 唯一入口，放进滚动内容时会被自动滚到底部的逻辑顶出视口（长历史下差上千点），
                // 用户看不到卡片就只能中止，表现为「工具一直在执行中」。
                if connection.state.isOnline,
                   session.attachedSessionId != nil,
                   !session.pendingApprovals.isEmpty {
                    ScrollView {
                        approvalSection
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s8)
                    }
                    .frame(maxHeight: 260)
                    .scrollBounceBehavior(.basedOnSize)
                    Divider()
                }
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: PISpacing.s16) {
                                statusArea
                                if connection.state.isOnline, session.attachedSessionId != nil {
                                    inputSection
                                    queueSection
                                    threadSection
                                } else if !connection.state.isOnline, let sessionId = cachedSessionId {
                                    offlineThread(sessionId: sessionId)
                                }
                            }
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s16)
                            .id("thread-bottom")
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
                        .scrollDismissesKeyboard(.immediately)
                        // 点消息区任意空白处收起键盘；输入框在滚动区之外，不受影响。
                        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                        .id(readingContextKey ?? "unbound-reading-context")
                        .transaction { transaction in
                            if isRestoringReadingPosition {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 2).onChanged { _ in
                                guard isRestoringReadingPosition else { return }
                                readingRestoreTargetItemID = nil
                                isRestoringReadingPosition = false
                                hasNewBelow = newMessagesDuringRestore
                            }
                        )
                        .onPreferenceChange(ConversationContentBottomKey.self) { contentBottom in
                            let distance = contentBottom - viewport.size.height
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
                            let viewportBottom = viewport.size.height
                            let visibleItemID = frames
                                .filter { frame in
                                    frame.value.maxY > 0 && frame.value.minY < viewportBottom
                                }
                                .min { lhs, rhs in
                                    lhs.value.minY < rhs.value.minY
                                }?
                                .key
                            lastMeasuredTopItemID = visibleItemID

                            if isRestoringReadingPosition {
                                let rows = threadRows
                                guard let target = readingRestoreTargetItemID,
                                      let frame = frames[ToolCallGroupingPolicy.anchorItemID(for: target, in: rows)],
                                      abs(frame.minY) <= 2
                                else { return }
                                readingRestoreTargetItemID = nil
                                topVisibleItemID = target
                                isNearBottom = false
                                hasNewBelow = newMessagesDuringRestore
                                isRestoringReadingPosition = false
                                recordReadingPosition()
                                return
                            }

                            if let lastItemID = session.view.items.last?.id {
                                let lastAnchor = ToolCallGroupingPolicy.anchorItemID(for: lastItemID, in: threadRows)
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
                        .onChange(of: session.view.items) { _, _ in
                            recordVisibleMessageCount()
                            guard !isRestoringReadingPosition else {
                                if restoreBaselineReady,
                                   session.view.items.count > restoreBaselineCount,
                                   session.view.items.last?.id != restoreBaselineLastItemID {
                                    newMessagesDuringRestore = true
                                }
                                return
                            }
                            if isNearBottom {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                    proxy.scrollTo("thread-bottom", anchor: .bottom)
                                }
                            } else {
                                hasNewBelow = true
                            }
                        }
                        .onChange(of: session.view.runningTurnId) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.view.activeItems) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.view.queuedTurns) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: scrollToBottomRequest) { _, _ in
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
                        .overlay(alignment: .bottomTrailing) {
                            if !isNearBottom {
                                Button {
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
                                .accessibilityLabel(hasNewBelow ? "有新消息，回到最新" : "回到最新")
                            }
                        }
                    }
                }
                composer
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
                Text("target=\(readingRestoreTargetItemID ?? "none"),measured=\(lastMeasuredTopItemID ?? "none")")
                    .font(.system(size: 1))
                    .foregroundStyle(PIColor.text)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityIdentifier("conversation.debugRestorationState")
                    .allowsHitTesting(false)
#endif
            }
            // 会话页内容自带常驻状态区，用 inline 标题：大标题会跟着内嵌滚动视图
            // 下拉进出，压在状态区上（标题被同步下拉）。
            .piRootNavBar(sessionTitle, displayMode: .inline, onMenu: model.openSidebar) {
                Menu {
                    Button("会话配置") { showingConfig = true }
                        .disabled(!connection.state.isOnline || session.attachedSessionId == nil)
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
                .accessibilityLabel("会话操作")
            }
            .sheet(isPresented: $showingConfig) {
                SessionConfigSheet(
                    session: session,
                    groups: model.currentModelGroups,
                    diagnostics: model.currentModelDiagnostics,
                    unavailableProviderIDs: legacyOnlyProviderIDs
                )
            }
            .alert("重命名会话", isPresented: $showingRename) {
                TextField("会话标题", text: $renameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { renameCurrentSession() }
            } message: {
                Text("标题只保存在本机，不会改写服务器上的会话内容。")
            }
            .piMessageAlert(title: "操作未完成", message: Binding(
                get: { showingConfig ? nil : session.lastError },
                set: { if $0 == nil { session.clearError() } }
            ))
            .piMessageAlert(title: "会话更新", message: Binding(
                get: { session.notice },
                set: { if $0 == nil { session.clearNotice() } }
            ))
            .task(id: session.attachedSessionId) {
                await refreshModelAvailability()
            }
            .onDisappear {
                recordReadingPosition()
            }
            .onChange(of: session.selectedBindingKey) { _, _ in
                Task { await refreshModelAvailability() }
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
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return "会话" }
        let fallback = session.attachedSummary?.title ?? "会话 \(sessionID)"
        return model.sessionDisplayTitle(hostID: hostID, sessionID: sessionID, fallback: fallback)
    }

    // MARK: - 头部（常驻，AC-08.12）

    /// 服务器与模型独占第二行，避免连接状态和运行操作把模型名称挤出视口。
    private var secondaryLine: String {
        let hostPart = currentHost.map { "\($0.name) · \($0.address)" }
        let modelPart = selectedModelLabel
        switch (hostPart, modelPart.isEmpty) {
        case let (host?, false): return "\(host) · \(modelPart)"
        case let (host?, true): return host
        case (nil, false): return modelPart
        case (nil, true): return ""
        }
    }

    /// 运行中的 turn id 只留前 8 位：完整 UUID 会换行占两行，把真正的状态信息挤下去。
    /// UI 测试用的 fixture id（如 `turn-s2`）短于 8 位，保持原样。
    private var runningTurnLabel: String {
        guard let id = session.runningTurnId else { return "正在运行" }
        let short = id.count > 8 ? String(id.prefix(8)) + "…" : id
        return "正在运行 \(short)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack(spacing: PISpacing.s8) {
                PIPermissionBadge(mode: session.permissionMode)
                Text(session.sessionMode.title)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: PISpacing.s4)
                if session.isTurnRunning {
                    Text(runningTurnLabel)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .accessibilityIdentifier("conversation.runningTurn")
                    Button(role: .destructive) {
                        Task { await session.interrupt() }
                    } label: {
                        Label("中止", systemImage: "stop.circle.fill")
                            .font(PIFont.captionStrong)
                            .lineLimit(1)
                            .padding(.horizontal, PISpacing.s8)
                            .padding(.vertical, 5)
                            .background(PIColor.dangerSoft, in: Capsule())
                    }
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("conversation.interrupt")
                    .disabled(!session.canInterrupt || session.isBusy)
                } else {
                    Circle()
                        .fill(connection.state.isOnline ? PIColor.success : PIColor.warning)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(connection.state.displayText)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(connection.state.isOnline ? PIColor.success : PIColor.warning)
                        .lineLimit(1)
                }
            }
            if !secondaryLine.isEmpty {
                Text(secondaryLine)
                    .font(PIFont.metaSmall)
                    .foregroundStyle(PIColor.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, 8)
        .background(PIColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(height: PIMetrics.hairline)
        }
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    // MARK: - 状态区

    @ViewBuilder
    private var statusArea: some View {
        if !connection.state.isOnline {
            PIInlineMessage(
                kind: .warning,
                text: connection.state.detail.map {
                    "离线，内容可能不是最新：\(connection.state.displayText)：\($0)"
                } ?? "隧道未建立时只能读到本机缓存；发送与审批已禁用。"
            )
        } else if session.attachedSessionId == nil {
            PIEmptyState(
                title: "还没有打开会话",
                message: "到项目页选择或新建一个会话。",
                actionTitle: "去项目页",
                action: { model.switchRoot(.projects) },
                icon: "bubble.left.and.text.bubble.right"
            )
        } else {
            switch session.modelAvailability {
            case .available:
                EmptyView()
            case .checking:
                PIStatusBanner(
                    kind: .info,
                    text: "正在检查模型可用性",
                    detail: "发送会在服务器确认 provider、模型与密钥都可用后放行。"
                )
            case .unavailable(let reason), .unknown(let reason):
                PIStatusBanner(
                    kind: .warning,
                    text: "模型暂不可用",
                    detail: reason,
                    actionTitle: isCheckingModelAvailability ? "正在检查…" : "重新检查",
                    action: {
                        Task { await refreshModelAvailability() }
                    }
                )
                PIGhostChipButton(title: "选择其他模型", systemImage: "slider.horizontal.3") {
                    showingConfig = true
                }
                .padding(.horizontal, PISpacing.s4)
            }
        }
    }

    // MARK: - 线程

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            if session.view.items.isEmpty {
                PIEmptyState(
                    title: "这个会话还没有消息",
                    message: "在下方输入框发出第一条指令",
                    icon: "bubble.left.and.text.bubble.right"
                )
            } else {
                let rows = threadRows
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        conversationRowView(row)
                            .padding(.top, rowSpacing(at: index, rows: rows))
                            .id(scrollID(for: row.anchorItemID))
                            .background {
                                ReadingRestoreAnchor(
                                    itemID: row.anchorItemID,
                                    targetID: readingRestoreTargetItemID.map {
                                        ToolCallGroupingPolicy.anchorItemID(for: $0, in: rows)
                                    },
                                    requestID: readingRestoreRequestID,
                                    onUserInteraction: {
                                        guard isRestoringReadingPosition else { return }
                                        readingRestoreTargetItemID = nil
                                        isRestoringReadingPosition = false
                                        hasNewBelow = newMessagesDuringRestore
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
            }
            // DEF-R4-005：纯工具长任务（如 sleep）运行期间 activeItems 为空，
            // 只按 activeItems 判断会缺「正在生成…」状态条；改与头部同一判据 isTurnRunning。
            if session.isTurnRunning {
                Text(session.activeItems.isEmpty
                     ? "正在生成内容…"
                     : "正在生成 \(session.activeItems.count) 条内容…")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .accessibilityIdentifier("conversation.streamingCount")
            }
        }
    }

    /// 线程行：连续工具调用按策略合并为可折叠分组，其余条目保持原样。
    private var threadRows: [ConversationRow] {
        ToolCallGroupingPolicy.rows(for: session.view.items)
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
            // 用户消息：右侧淡蓝气泡、无角色标签（design-system.md §7 / spec AC-1）。
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
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 320, alignment: .leading)
                .background(
                    PIColor.accentSoft,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: PIRadius.card,
                        bottomLeadingRadius: PIRadius.card,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: PIRadius.card,
                        style: .continuous
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: PIRadius.card,
                        bottomLeadingRadius: PIRadius.card,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: PIRadius.card,
                        style: .continuous
                    )
                    .strokeBorder(PIColor.accentBorder, lineWidth: PIMetrics.hairline)
                )
            }
        } else {
            // Agent / 系统消息：左对齐、无气泡、无头像、无角色标签（design-system.md §7 / spec AC-2）。
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
                    PIMarkdownView(text: item.text ?? item.kind ?? "条目")
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var readingContextKey: String? {
        guard let hostID = model.currentHost?.id,
              let sessionID = session.attachedSessionId
        else { return nil }
        return "\(hostID.uuidString):\(sessionID)"
    }

    /// 附加会话 ID 会先到，`session/view` 可能晚到；视图真的换成目标会话后要再触发一次恢复。
    private var readingRestoreTaskKey: String? {
        guard let context = readingContextKey else { return nil }
        return "\(context):\(session.view.sessionId ?? "pending")"
    }

    private func scrollID(for itemID: String) -> String {
        "conversation-item:\(itemID)"
    }

    @MainActor
    private func restoreReadingPosition(proxy: ScrollViewProxy) async {
        readingRestoreGeneration &+= 1
        let generation = readingRestoreGeneration
        defer {
            if readingRestoreGeneration == generation {
                isRestoringReadingPosition = false
            }
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
            guard !Task.isCancelled, readingContextKey == contextKey else { return }
            if session.view.sessionId == sessionID { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled,
              readingContextKey == contextKey,
              session.view.sessionId == sessionID
        else { return }
        restoreBaselineCount = session.view.items.count
        restoreBaselineLastItemID = session.view.items.last?.id
        restoreBaselineReady = true

        // Large restored snapshots need multiple layout passes before the target's
        // UIKit anchor can drive the scroll view and its frame can be confirmed.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, readingContextKey == contextKey else { return }

        let saved = model.readingPosition(hostID: hostID, sessionID: sessionID)
        if let saved,
           !saved.isNearBottom,
           let itemID = saved.lastVisibleItemID,
           session.view.items.contains(where: { $0.id == itemID }) {
            readingRestoreTargetItemID = itemID
            isNearBottom = false
            hasNewBelow = newMessagesDuringRestore
            readingRestoreRequestID &+= 1
            for _ in 0..<10 where isRestoringReadingPosition {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      readingContextKey == contextKey,
                      readingRestoreTargetItemID == itemID
                else { return }
                readingRestoreRequestID &+= 1
            }
            if isRestoringReadingPosition,
               readingRestoreTargetItemID == itemID {
                readingRestoreTargetItemID = nil
                topVisibleItemID = itemID
                isRestoringReadingPosition = false
                isNearBottom = false
                hasNewBelow = newMessagesDuringRestore
                return
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
        guard !Task.isCancelled, readingContextKey == contextKey else { return }
        isRestoringReadingPosition = false
        recordReadingPosition()
    }

    private func recordReadingPosition() {
        guard !isRestoringReadingPosition,
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
                await connection.session.attach(sessionId: next.id)
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

    @ViewBuilder
    private func offlineThread(sessionId: String) -> some View {
        let cached = connection.cachedSession(sessionId: sessionId)
        let entries = cached?.entries ?? []
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "缓存的历史（只读）")
            PIInlineMessage(
                kind: .warning,
                text: "离线只读 · 缓存可能已过期；审批卡只用于展示，恢复在线后会按服务器快照重建。"
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
                        Text("恢复在线后可继续编辑或发送。")
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
            }
            if cached == nil {
                PIListRow(
                    title: "本机没有这个会话的缓存",
                    subtitle: "只包含联网时缓存的内容（最多 \(PersistedState.maxCachedConversations) 个会话）",
                    isEnabled: false,
                    showsDivider: false
                )
            } else if entries.isEmpty {
                PIListRow(
                    title: "缓存里没有文本消息",
                    subtitle: "审批卡与草稿仍可在上方查看。",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(entries, id: \.id) { entry in
                    PICard {
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(entry.displayText)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text3)
                        }
                    }
                }
            }
        }
    }

    private func offlineApprovalCard(_ approval: OfflineSessionApproval) -> some View {
        let contract = cachedApprovalIsContract(approval)
        return PICard {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                HStack {
                    Text(contract ? "计划 / 目标契约" : "权限请求")
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
                    HStack(spacing: PISpacing.s8) {
                        PIApprovalPrimaryButton(title: "批准", isEnabled: false) {}
                        PIDangerOutlineButton(title: "驳回", isEnabled: false) {}
                    }
                } else {
                    HStack(spacing: PISpacing.s8) {
                        PIApprovalSecondaryButton(title: "允许一次", isEnabled: false) {}
                        PIApprovalSecondaryButton(title: "本会话允许", isEnabled: false) {}
                        PIDangerOutlineButton(title: "拒绝", isEnabled: false) {}
                    }
                }
                Text("离线时不可提交，恢复在线后再操作。")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text3)
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
        return "服务器当时没有给出可显示的摘要（id \(approval.id)）"
    }

    // MARK: - 审批（AC-10 / AC-12）

    @ViewBuilder
    private var approvalSection: some View {
        ForEach(orderedApprovals, id: \.id) { card in
            let availability = session.availability(for: card.id)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    HStack(spacing: PISpacing.s4) {
                        Circle()
                            .fill(SessionController.isContract(card) ? PIColor.warning : PIColor.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(SessionController.isContract(card) ? "计划 / 目标契约" : "权限请求")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                        Spacer()
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
                    if availability.isActionable {
                        if SessionController.isContract(card) {
                            HStack(spacing: PISpacing.s8) {
                                PIApprovalPrimaryButton(title: "批准", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .approve) }
                                }
                                PIDangerOutlineButton(title: "驳回", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .reject) }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: PISpacing.s8) {
                                HStack(spacing: PISpacing.s8) {
                                    PIApprovalPrimaryButton(title: "允许一次", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .allowOnce) }
                                    }
                                    PIApprovalSecondaryButton(title: "本会话允许", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .allowSession) }
                                    }
                                }
                                // 危险决策与安全决策视觉不共位：独立一行 + 上方留白（design-system.md 原则 2）。
                                HStack(spacing: PISpacing.s8) {
                                    PIDangerOutlineButton(title: "拒绝", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .deny) }
                                    }
                                }
                                .padding(.top, PISpacing.s4)
                            }
                        }
                    } else {
                        Text("卡片已失效，等待同步后重试。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                }
            }
        }
        ForEach(Array(session.view.expiredApprovalIds).sorted(), id: \.self) { expiredId in
            if session.availability(for: expiredId) == .expired {
                PICard {
                    HStack {
                        Text("审批 \(expiredId) 已失效")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                        Spacer()
                    }
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
        return "服务器没有给出可显示的摘要（id \(card.id)）"
    }

    // MARK: - 提问（AC-11）

    @ViewBuilder
    private var inputSection: some View {
        ForEach(session.pendingInputs, id: \.id) { card in
            let questions = InputQuestionParser.questions(from: card)
            let draftKey = answerDraftKey(card.id)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    Text("需要你回答")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                    if questions.isEmpty {
                        Text("无法解析该提问，只能跳过。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(question.prompt)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if question.options.isEmpty {
                                Text("没有选项，提交将跳过。")
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                            } else {
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
                PISectionHeader(text: "排队中（\(session.queuedTurns.count)）")
                    .accessibilityIdentifier("conversation.queueHeader")
                ForEach(session.queuedTurns) { turn in
                    PICard {
                        HStack(spacing: PISpacing.s8) {
                            VStack(alignment: .leading, spacing: PISpacing.s4) {
                                // 优先显示正文；服务端快照缺正文时显示附件数/排队提示，不显示裸 id。
                                Text(turn.displayText)
                                    .font(PIFont.body)
                                    .foregroundStyle(PIColor.text)
                                    .lineLimit(2)
                                    .accessibilityIdentifier("conversation.queuedTurnText.\(turn.id)")
                                Text("当前 turn 结束后自动开始")
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await session.cancelQueued(turnId: turn.id) }
                            } label: {
                                Text("取消")
                                    .font(PIFont.captionStrong)
                                    .padding(.horizontal, PISpacing.s12)
                                    .padding(.vertical, 6)
                                    .background(PIColor.dangerSoft, in: Capsule())
                            }
                            .buttonStyle(PIPressableButtonStyle())
                            .disabled(session.isBusy || !connection.state.isOnline)
                            .accessibilityIdentifier("conversation.cancelQueued.\(turn.id)")
                        }
                    }
                    .accessibilityIdentifier("conversation.queuedTurn.\(turn.id)")
                }
            }
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
            if !session.isOnline {
                Text("离线：发送已禁用")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.warning)
            }
            if session.sendAdmission.isQueueing {
                // 只保留一行短提示；运行状态仍由页面顶部状态行表达，不恢复旧的长提示。
                Text("当前 turn 运行中，发送将排队")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text2)
                    .accessibilityIdentifier("conversation.queueHint")
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
                    Task {
                        var failed = 0
                        var succeeded = 0
                        for item in items {
                            guard session.attachmentSelectionGeneration == selection,
                                  photoSelectionID == photoSelection else { break }
                            // U16：读取失败不再静默跳过；计数后在输入栏上方明确呈现，
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
                            succeeded += 1
                            let mime = imageMimeType(data)
                            let ext = mime == "image/png" ? "png" : (mime == "image/webp" ? "webp" : "jpg")
                            await session.addImage(
                                data: data,
                                mimeType: mime,
                                fileName: "photo-\(UUID().uuidString).\(ext)"
                            )
                        }
                        guard session.attachmentSelectionGeneration == selection,
                              photoSelectionID == photoSelection else { return }
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
                    scrollToBottomRequest &+= 1
                    // U11：点击瞬间冻结发送意图；模型可用性检查可能等待网络，
                    // 期间切换会话/模型或继续编辑都由 send(expected:) 拒绝，不会误发。
                    let intent = session.makeSendIntent()
                    Task {
                        let check = await refreshModelAvailability()
                        guard check != .superseded else { return }
                        await session.send(expected: intent)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canTapSend ? PIColor.onAccent : PIColor.text3)
                        .frame(width: 36, height: 36)
                        .background(
                            canTapSend ? PIColor.accent : PIColor.surface3,
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .disabled(!canTapSend)
                .accessibilityLabel("发送")
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
            .shadow(color: PIColor.floatingShadow.opacity(0.5), radius: 14, y: 5)
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

    private func imageMimeType(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }

    /// 发送按钮可用性：附件部分读取失败且未确认时禁止发送（U16）。
    private var canTapSend: Bool {
        session.canSend && !session.isBusy && !photoReadNeedsConfirmation
    }

    /// 最近一次选图的读取失败提示；`nil` 表示没有失败。
    private var photoReadFailureNotice: String? {
        guard photoReadFailureCount > 0 else { return nil }
        if photoReadSucceededCount > 0 {
            return "部分图片读取失败（\(photoReadFailureCount) 张），当前只包含已读取的 \(photoReadSucceededCount) 张。确认后才能发送。"
        }
        return "全部图片读取失败（\(photoReadFailureCount) 张），请重新选择图片。"
    }

    /// 部分失败且未确认：必须显式确认才能发送已读取的子集。
    private var photoReadNeedsConfirmation: Bool {
        photoReadFailureCount > 0 && photoReadSucceededCount > 0 && !photoReadAcknowledged
    }

    private var composerConfigurationChips: some View {
        HStack(spacing: PISpacing.s8) {
            configurationChip(
                title: session.sessionMode.title,
                tint: PIColor.text2,
                identifier: "composer.modeChip",
                systemImage: "slider.horizontal.3"
            )
            configurationChip(
                title: session.permissionMode.title,
                tint: session.permissionMode.tint,
                identifier: "composer.permissionChip",
                systemImage: "lock.shield"
            )
            Spacer(minLength: PISpacing.s4)
            configurationChip(
                title: selectedModelLabel,
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .font(PIFont.metaSmall.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, PISpacing.s8)
            .frame(minHeight: 30)
            .frame(maxWidth: maxWidth, alignment: alignment)
            .background(PIColor.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline))
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

    /// 检查当前会话模型的可用性，并返回显式结果（U11）：`superseded` 表示检查期间
    /// 会话/服务器/模型绑定已经被更新的检查取代，发送方必须放弃这次点击而不是继续发送。
    @discardableResult
    private func refreshModelAvailability() async -> ModelAvailabilityCheckResult {
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
        isCheckingModelAvailability = true
        session.markModelAvailabilityChecking()
        defer {
            if generation == modelAvailabilityGeneration {
                isCheckingModelAvailability = false
            }
        }
        do {
            // Prefer the v2 PI-adaptor's own provider store; fall back to the legacy
            // SSH-based binding probe for old v1 Hosts.
            let status = try await connection.adaptorV2BindingStatus(sessionId: sessionID)
            guard generation == modelAvailabilityGeneration,
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
            legacyOnlyProviderIDs = []
            do {
                let receipt = try await connection.providerBindingStatus(
                    record: host,
                    sessionId: sessionID
                )
                guard generation == modelAvailabilityGeneration,
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
        return "该模型服务只导入到了服务器的旧存储，尚未同步到 PI-adaptor，因此无法驱动会话。"
            + "请到 设置 → 模型服务 重新导入这个服务（导入会一并写入 PI-adaptor 并保存密钥）。"
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

private struct ToolItemCard: View {
    enum Style {
        /// 线程里单独出现的一条工具调用。
        case standalone
        /// 分组展开后的子条目：底色更浅、层级更紧凑。
        case nested
    }

    let item: RACPItem
    var style: Style = .standalone
    private let presentation: ToolResultPresentation
    @State private var expanded = false
    @State private var renderStartedAt: TimeInterval?
    @State private var renderMilliseconds: Double?
    @State private var firstFrameMilliseconds: Double?
    private let measuresRender: Bool

    /// 超过这个体积才把正文放进定高滚动区，短结果仍然随卡片自然增高。
    private static let inlineBodyByteLimit = 1_200
    private static let maxBodyHeight: CGFloat = 280

    init(item: RACPItem, style: Style = .standalone) {
        self.item = item
        self.style = style
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
                title: item.toolName.map { "工具 · \($0)" } ?? "工具调用",
                statusText: ToolStatusPresentation.label(for: item.status),
                statusTint: ToolVisuals.statusTint(for: item.status),
                summary: collapsedSummary,
                isExpanded: expanded
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
                                .foregroundStyle(PIColor.text3)
                                .accessibilityIdentifier("toolCard.\(item.id).truncation")
                        }
                    } else {
                        Text(emptyBodyNotice)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                .padding(.top, PISpacing.s4)
                .padding(.bottom, PISpacing.s8)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PISpacing.s12)
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
            RoundedRectangle(cornerRadius: PISpacing.s8, style: .continuous)
                .fill(PIColor.surface2)
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

    /// 运行中的工具只是还没有正文。把「还没输出」说成「服务器没有返回工具输出正文」
    /// 会让用户以为工具已经结束、结果丢了。
    private var emptyBodyNotice: String {
        if item.status == nil || ToolStatusPresentation.isRunning(item.status) {
            return "工具执行中…"
        }
        return "服务器没有返回工具输出正文。"
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
                statusTint: group.hasFailure
                    ? PIColor.danger
                    : (group.isRunning ? PIColor.accent : PIColor.success),
                summary: group.toolSummary,
                isExpanded: expanded
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.items, id: \.id) { item in
                        if item.isToolItem {
                            ToolItemCard(item: item, style: .nested)
                        } else {
                            ToolRunMessage(item: item)
                        }
                    }
                }
                .padding(.top, PISpacing.s4)
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
}

/// 分组内的中间过程消息：工具调用之间的过渡说明，展开分组后按正文样式展示。
private struct ToolRunMessage: View {
    let item: RACPItem

    var body: some View {
        PIMarkdownView(text: item.text ?? item.kind ?? "条目")
            .padding(.horizontal, PISpacing.s8)
            .padding(.vertical, PISpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("toolGroup.message.\(item.id)")
    }
}

/// 工具行标题：工具名/数量、状态、结果摘要各占清晰层级，整体保持两行以内的紧凑高度。
private struct ToolRowHeader: View {
    let icon: String
    let iconTint: Color
    let title: String
    let statusText: String?
    let statusTint: Color
    let summary: String?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: PISpacing.s8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 24, height: 24)
                .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text)
                .lineLimit(1)
                .layoutPriority(2)
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(PIFont.metaSmall.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(statusTint.opacity(0.12), in: Capsule())
                    .layoutPriority(1)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(PIFont.metaSmall)
                    .foregroundStyle(PIColor.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PIColor.text3)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .frame(minHeight: PIMetrics.minHitTarget)
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
        if ToolStatusPresentation.isRunning(status) { return PIColor.accent }
        return PIColor.text2
    }

    static func statusTint(for status: String?) -> Color {
        if ToolStatusPresentation.isFailure(status) { return PIColor.danger }
        if ToolStatusPresentation.isRunning(status) { return PIColor.accent }
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

// MARK: - 会话配置（AC-07）

private struct SessionConfigSheet: View {
    @ObservedObject var session: SessionController
    let groups: [ProviderModelGroup]
    let diagnostics: [ModelGroupingDiagnostic]
    /// Providers our local catalog knows but the connected v2 PI-adaptor's own store
    /// does not (legacy-only imports); their models cannot drive a turn.
    let unavailableProviderIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    private var selectedBinding: ModelRecord? {
        flatten(groups).first {
            $0.providerId == session.selectedProviderId && $0.modelId == session.selectedModelId
        }
    }

    private var configLocked: Bool { session.isTurnRunning || session.isBusy }
    private var configEnabled: Bool { !configLocked && session.isOnline }

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
                            text: "部分模型未同步到 PI-adaptor：标记为「未同步」的模型只存在于服务器的旧存储，无法在该服务器上运行。"
                                + "请到 设置 → 模型服务 重新导入对应服务（会写入 PI-adaptor）。"
                        )
                    }
                    if configLocked {
                        PIInlineMessage(
                            kind: .warning,
                            text: "当前轮次仍在运行：模型、会话模式和思考档位会在本轮结束后恢复可切换。"
                        )
                    } else if !session.isOnline {
                        PIInlineMessage(kind: .warning, text: "服务器离线，恢复连接后才能提交会话配置。")
                    }
                    PIGroup("权限模式", footer: "改动通过 `session/configure` 下发，运行中的轮次不允许切换。") {
                        ForEach(RACPPermissionMode.allCases, id: \.self) { mode in
                            PIListRow(
                                title: mode.title,
                                value: session.permissionMode == mode ? "当前" : nil,
                                isEnabled: configEnabled,
                                showsDivider: mode != .auto,
                                action: { Task { await session.configure(permissionMode: mode) } }
                            )
                        }
                    }
                    PIGroup("会话模式", footer: "Plan 模式提交计划后需要你在这里或用审批卡批准。") {
                        ForEach(RACPSessionMode.allCases, id: \.self) { mode in
                            PIListRow(
                                title: mode.title,
                                value: session.sessionMode == mode ? "当前" : nil,
                                isEnabled: configEnabled,
                                showsDivider: mode != .goal,
                                action: { Task { await session.configure(mode: mode) } }
                            )
                        }
                    }
                    PIGroup("模型", footer: "来自本机模型清单；选择后通过 `session/configure` 下发 providerId、modelId 与该模型的默认思考档位。") {
                        if groups.isEmpty {
                            PIListRow(
                                title: "没有可用模型",
                                subtitle: "先到 设置 → 模型服务 导入模型",
                                isEnabled: false,
                                showsDivider: false
                            )
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
                                            ? "\(modelSubtitle(record)) · 未同步到 PI-adaptor"
                                            : modelSubtitle(record),
                                        value: isSelected(record) ? "当前" : nil,
                                        isEnabled: configEnabled && !unavailable,
                                        showsDivider: !(groupIndex == groups.count - 1 && modelIndex == group.models.count - 1),
                                        action: { select(record) }
                                    )
                                }
                            }
                        }
                    }
                    if let selectedBinding, !selectedBinding.thinkingLevels.isEmpty {
                        PIGroup("思考档位", footer: "档位只来自当前模型；未声明档位的模型不显示本组。") {
                            let levels = selectedBinding.thinkingLevels
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, raw in
                                let level = RACPThinkingLevel(rawValue: raw)
                                PIListRow(
                                    title: raw,
                                    value: session.thinkingLevel?.rawValue == raw ? "当前" : nil,
                                    isEnabled: configEnabled,
                                    showsDivider: index != levels.count - 1,
                                    action: {
                                        Task { await select(selectedBinding, thinking: level) }
                                    }
                                )
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

/// SwiftUI's item-level `ScrollViewReader.scrollTo`/`scrollPosition` can keep the
/// previous offset when session content is swapped in place. This anchor applies
/// the restore directly to the enclosing UIScrollView, then the measured frame is
/// used by `ConversationScreen` to confirm success.
private struct ReadingRestoreAnchor: UIViewRepresentable {
    let itemID: String
    let targetID: String?
    let requestID: Int
    let onUserInteraction: () -> Void

    final class Coordinator {
        var appliedRequestID = 0
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
            let current = uiView.convert(uiView.bounds, to: scrollView)
            let inset = scrollView.adjustedContentInset
            let desiredY = scrollView.contentOffset.y + current.minY
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
struct AttachmentThumbnailView: View {
    let attachment: RACPV2Attachment
    @EnvironmentObject private var connection: ConnectionModel
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(PIRadius.control)
                    .onTapGesture { showingDetail = true }
            } else if isLoading {
                ProgressView()
                    .frame(height: 100)
            } else if loadFailed {
                Label("图片加载失败", systemImage: "exclamationmark.triangle")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.danger)
            } else {
                HStack(spacing: PISpacing.s4) {
                    Image(systemName: "photo")
                    Text(attachment.fileName)
                        .font(PIFont.meta)
                }
                .padding(PISpacing.s8)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            }
        }
        .task {
            await loadImage()
        }
        .sheet(isPresented: $showingDetail) {
            if let uiImage {
                NavigationStack {
                    VStack {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                        ShareLink(
                            item: Image(uiImage: uiImage),
                            preview: SharePreview(attachment.fileName, image: Image(uiImage: uiImage))
                        ) {
                            Label("保存或分享图片", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                    .navigationTitle(attachment.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("关闭") { showingDetail = false }
                    }
                }
            }
        }
    }

    private func loadImage() async {
        guard uiImage == nil, !isLoading else { return }
        guard let client = connection.activeClient else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let read = try await client.readImageAttachment(attachmentId: attachment.id, offset: 0, length: 20 * 1024 * 1024)
            if let data = Data(base64Encoded: read.dataBase64), let image = UIImage(data: data) {
                uiImage = image
                loadFailed = false
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

