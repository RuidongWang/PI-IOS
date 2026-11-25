import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import CoreTransferable
import ImageIO
import PIiOSCore
import PIiOSNet

extension ConversationScreen {
    // MARK: - 线程

    func threadSection(proxy: ScrollViewProxy) -> some View {
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
    func rowSpacing(at index: Int, rows: [ConversationRow]) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = rows[index - 1]
        let current = rows[index]
        if previous.isToolLike, current.isToolLike { return PISpacing.s8 }
        if previous.isToolLike || current.isToolLike { return PISpacing.s12 }
        return PISpacing.s16
    }

    @ViewBuilder
    func conversationRowView(_ row: ConversationRow) -> some View {
        switch row {
        case let .item(item):
            itemRow(item)
        case let .toolGroup(group):
            ToolRunCard(group: group)
        }
    }

    @ViewBuilder
    func itemRow(_ item: RACPItem) -> some View {
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
    func scheduleAutomaticFollow(proxy: ScrollViewProxy) {
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

    var readingContextKey: String? {
        guard let hostID = model.currentHost?.id,
              session.openingSessionID == nil, let sessionID = session.attachedSessionId
        else { return nil }
        return "\(hostID.uuidString):\(sessionID)"
    }

    /// 附加会话 ID 会先到，`session/view` 可能晚到；视图真的换成目标会话后要再触发一次恢复。
    var readingRestoreTaskKey: String? {
        guard let context = readingContextKey else { return nil }
        return "\(context):\(session.view.sessionId ?? "pending")"
    }

    /// `scrollPosition` also writes the row that happens to be on top while the
    /// user scrolls. Feeding that back would fight the restore/paging offset, so
    /// only the screen writes this state; layout feedback is ignored.
    var trackedScrollPosition: Binding<String?> {
        Binding(get: { scrollPositionID }, set: { _ in })
    }

    func cancelReadingPositionRestore() {
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

    func cancelHistoryPositionRestore() {
        historyPositionRestoreID = nil
        historyReadingAnchorID = nil
        viewportMeasurement.cancel()
        scrollPositionID = nil
    }

    func cancelHistoryPaging() {
        historyPagingCancelled = true
        readingPositionHoldAnchorID = nil
        cancelHistoryPositionRestore()
    }

    /// 只在用户点按钮后读取一页。UIKit 锚点保留原可见条目的像素位置，
    /// 不借用回到最新的 scrollTo，也不在历史页到达时触发消息追随。
    @MainActor
    func loadEarlierHistoryPreservingPosition(proxy: ScrollViewProxy) async {
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
    func restoreReadingPosition(proxy: ScrollViewProxy) async {
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

    func recordReadingPosition() {
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
    func confirmReadingRestoreIfAligned(in frames: [String: CGRect]) -> Bool {
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

    func recordVisibleMessageCount() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        model.updateSessionActivity(
            hostID: hostID,
            sessionID: sessionID,
            messageCount: session.view.items.count
        )
    }

    func renameCurrentSession() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        if model.renameSession(hostID: hostID, sessionID: sessionID, title: renameDraft) {
            session.clearError()
        } else {
            model.showToast("会话标题不能为空")
        }
    }

    func archiveCurrentSession() {
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
    var cachedSessionId: String? {
        guard let hostID = model.currentHost?.id else { return nil }
        return model.cachedSessionSelectionID(for: hostID)
    }

    var extensionSessionId: String? {
        connection.state.isOnline ? session.attachedSessionId : (cachedSessionId ?? session.attachedSessionId)
    }

    func openingThread(sessionID: String, proxy: ScrollViewProxy) -> some View {
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
    func offlineThread(sessionId: String) -> some View {
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
    func cachedConversationRow(_ row: ConversationRow, namespace: String) -> some View {
        if row.isToolLike {
            conversationRowView(row)
        } else {
            conversationRowView(row)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.\(namespace).\(row.anchorItemID)")
        }
    }

    func offlineApprovalCard(_ approval: OfflineSessionApproval) -> some View {
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

    func cachedApprovalIsContract(_ approval: OfflineSessionApproval) -> Bool {
        let kind = approval.payload.value(at: ["kind"])?.stringValue?.lowercased() ?? ""
        return kind.contains("plan") || kind.contains("goal") || kind.contains("contract")
    }

    func cachedApprovalSummary(_ approval: OfflineSessionApproval) -> String {
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

}

struct ConversationContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ConversationItemFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ConversationHistoryTextLoaderKey: EnvironmentKey {
    static let defaultValue: (@MainActor (RACPItem) async -> String?)? = nil
}

extension EnvironmentValues {
    var conversationHistoryTextLoader: (@MainActor (RACPItem) async -> String?)? {
        get { self[ConversationHistoryTextLoaderKey.self] }
        set { self[ConversationHistoryTextLoaderKey.self] = newValue }
    }
}

/// A separate action leaves the system text-selection gesture available.
private func copyMessageButton(_ item: RACPItem) -> some View {
    ConversationItemCopyButton(item: item)
}

private struct ConversationItemCopyButton: View {
    let item: RACPItem
    @Environment(\.conversationHistoryTextLoader) private var loadHistoryText
    @State private var isLoading = false

    var body: some View {
        copyMessageButton(identifier: "conversation.copyMessage.\(item.id)") {
            guard item.historyTextByteLength != nil, let loadHistoryText else {
                UIPasteboard.general.string = item.text ?? ""
                return
            }
            isLoading = true
            Task { @MainActor in
                defer { isLoading = false }
                if let text = await loadHistoryText(item) {
                    UIPasteboard.general.string = text
                }
            }
        }
        .disabled(isLoading)
    }
}

private func copyMessageButton(_ entry: OfflineSessionCacheEntry) -> some View {
    copyMessageButton(
        identifier: "conversation.offlineCopyMessage.\(entry.id)"
    ) {
        UIPasteboard.general.string = entry.text
    }
}

private func copyMessageButton(identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
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
