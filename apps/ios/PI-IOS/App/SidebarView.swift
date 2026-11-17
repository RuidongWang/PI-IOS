import SwiftUI
import Foundation
import PIiOSCore

/// 会话侧边栏（screens.md S-07 / information-architecture.md §2 抽屉浮层）。
///
/// 构成：顶部 PI-adaptor 选择器（名称、连接状态、▾）+ 右侧 ×；会话区；底部新建会话与 项目 / 设置。
/// 会话区读真实数据：在线时列服务器上的会话（可点开），离线时列本机缓存的会话（只读）。
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var dragSessionID: String?
    @State private var dropResolution: SessionDropResolution?
    @State private var sessionRowFrames: [String: CGRect] = [:]
    @State private var revealedSessionID: String?
    @State private var sessionPendingDelete: SessionDeletionTarget?
    @State private var sessionActionSheet: SessionDeletionTarget?
    /// 操作 sheet 必须先完全关闭，再弹出删除确认 alert；直接在 sheet 内切换会丢失 alert。
    @State private var pendingDeleteAfterSheet: SessionDeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hostSelector
            divider
            conversationArea
            divider
            bottomBar
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        // quiet-v2 §2：抽屉是「页面之上的一层表面」，纯 surface，不画顶光、不画渐变。
        .background {
            PIColor.surface.ignoresSafeArea()
        }
        .onDisappear(perform: resetSessionDrag)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(width: PIMetrics.hairline)
                .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        .alert(item: $sessionPendingDelete) { target in
            let session = target.session
            return Alert(
                title: Text("删除「\(sessionDisplayTitle(session))」？"),
                message: Text("服务器会话记录与媒体将永久删除，本机缓存也会清除。此操作不可恢复。"),
                primaryButton: .destructive(Text("删除")) {
                    sessionPendingDelete = nil
                    deleteSession(session)
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $sessionActionSheet, onDismiss: {
            guard let target = pendingDeleteAfterSheet else { return }
            pendingDeleteAfterSheet = nil
            sessionPendingDelete = target
        }) { target in
            NavigationStack {
                VStack(alignment: .leading, spacing: PISpacing.s16) {
                    Text(sessionDisplayTitle(target.session))
                        .font(PIFont.display)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PIApprovalSecondaryButton(title: "归档") {
                        sessionActionSheet = nil
                        archiveSession(target.session)
                    }
                    .accessibilityIdentifier("sidebar.archive.\(target.session.id)")
                    PIDangerOutlineButton(title: "删除") {
                        // 只记录待确认目标并关闭 sheet；alert 在 onDismiss 后弹出，
                        // 避免 sheet 未完成关闭时弹 alert 被系统丢弃。
                        pendingDeleteAfterSheet = SessionDeletionTarget(session: target.session)
                        sessionActionSheet = nil
                    }
                    .accessibilityIdentifier("sidebar.delete.\(target.session.id)")
                    Spacer()
                }
                .padding(PISpacing.s16)
                .navigationTitle("会话操作")
                .navigationBarTitleDisplayMode(.inline)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: searchText) { _, _ in
            withAnimation(PIMotion.quick) { revealedSessionID = nil }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(PIColor.separator)
            .frame(height: PIMetrics.hairline)
    }

    // MARK: - PI-adaptor 选择器

    @ViewBuilder
    private var hostSelector: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack {
                Text("服务器")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                Spacer()
                Button {
                    model.closeSidebar()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PIColor.text2)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭侧边栏")
                .accessibilityIdentifier("sidebar.close")
                .padding(.trailing, -PISpacing.s12)
            }

            if model.hosts.isEmpty {
                settingsLinkRow
            } else {
                hostMenu
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s8)
        .padding(.bottom, PISpacing.s12)
    }

    /// 没有服务器时，这一行就是「去设置」的入口：一行文字 + chevron，没有第二个动作。
    private var settingsLinkRow: some View {
        Button {
            model.showSettings()
        } label: {
            HStack(spacing: PISpacing.s12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(PIColor.text2)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("未配置服务器")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Spacer(minLength: PISpacing.s8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: PIMetrics.listRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("未配置服务器，打开设置")
        .accessibilityIdentifier("sidebar.addHost")
    }

    /// 当前服务器：名称 + 实时连接状态 + ▾。图标单色，不做色块 chip。
    private var hostMenu: some View {
        Menu {
            ForEach(model.hosts) { host in
                Button {
                    Task { await model.setCurrentHost(id: host.id) }
                } label: {
                    Text(host.isCurrent ? "✓ \(host.name)" : host.name)
                }
            }
            Divider()
            Button("服务器管理") { model.showSettings() }
        } label: {
            HStack(spacing: PISpacing.s12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(PIColor.text2)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentHost?.name ?? "选择服务器")
                        .font(PIFont.listTitle)
                        .foregroundStyle(PIColor.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(connection.state.isOnline ? PIColor.success : PIColor.warning)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(connection.state.displayText)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: PISpacing.s8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: PIMetrics.listRowMinHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("切换服务器")
        // 当前服务器与连接状态读在 value 上：Menu 只有一个无障碍元素，子文本不进元素树。
        .accessibilityValue("\(model.currentHost?.name ?? "")，\(connection.state.displayText)")
        .accessibilityIdentifier("sidebar.host")
    }

    private var conversationArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PIColor.text2)
                        .accessibilityHidden(true)
                    TextField("搜索", text: $searchText)
                        .accessibilityIdentifier("sidebar.search")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .font(PIFont.body)
                        .accessibilityIdentifier("sidebar.search")
                        .onSubmit {}
                }
                .padding(.horizontal, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
                )
                .padding(.bottom, PISpacing.s8)
                if connection.state.isOnline {
                    if sidebarGroups.isEmpty {
                        emptyLine(searchQuery.isEmpty ? "没有会话" : "没有匹配")
                    } else {
                        ForEach(sidebarGroups) { group in
                            projectGroup(group)
                        }
                    }
                } else if !connection.offlineCacheReady {
                    ProgressView("正在读取本机会话…")
                        .font(PIFont.body)
                        .accessibilityIdentifier("sidebar.cache.loading")
                } else if let error = connection.offlineCacheLoadError {
                    emptyLine(error)
                        .accessibilityIdentifier("sidebar.cache.error")
                } else {
                    // 一次读出缓存 id 列表：离线分组的过滤与空态都基于同一份输入，
                    // 避免每渲染一次就多读几次缓存快照。
                    let cachedSessionIDs = connection.cachedSessionIds()
                    let groups = offlineSidebarGroups(cachedSessionIDs: cachedSessionIDs)
                    if groups.isEmpty {
                        emptyLine(
                            SidebarFilterPolicy.offlineEmptyMessage(
                                hasCachedSessions: !cachedSessionIDs.isEmpty,
                                query: searchQuery
                            )
                        )
                    } else {
                        ForEach(groups) { group in
                            offlineProjectGroup(group)
                        }
                    }
                }
            }
            .onPreferenceChange(SidebarSessionFramePreferenceKey.self) { frames in
                sessionRowFrames = frames
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s16)
        }
        .coordinateSpace(name: SidebarSessionCoordinates.list)
    }

    /// 空态：一句话。动作由底部「新建会话」与项目页承担，这里不再写第二句解释。
    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(PIFont.body)
            .foregroundStyle(PIColor.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private struct SessionDeletionTarget: Identifiable {
        let session: RACPSessionSummary
        var id: String { session.id }
    }

    private struct SidebarGroup: Identifiable {
        let project: RACPProjectSummary
        let name: String
        let sessions: [RACPSessionSummary]

        var id: String { project.id }
    }

    private struct OfflineSidebarGroup: Identifiable {
        let projectID: String
        let name: String
        let sessionIDs: [String]

        var id: String { projectID }
    }

    /// 归一化后的搜索查询：在线与离线分组共用同一份（见 `SidebarFilterPolicy`）。
    private var searchQuery: String {
        SidebarFilterPolicy.normalizedQuery(searchText)
    }

    private var sidebarGroups: [SidebarGroup] {
        guard let hostID = model.currentHost?.id else { return [] }
        let projects = connection.projects.filter {
            !model.isProjectDeleted(hostID: hostID, projectID: $0.id)
                && !model.isProjectArchived(hostID: hostID, projectID: $0.id)
        }
        let query = searchQuery
        let groups = projects.compactMap { project -> SidebarGroup? in
            let name = model.projectDisplayName(
                hostID: hostID,
                projectID: project.id,
                fallback: project.label ?? project.id
            )
            let sessions = connection.sessions
                .filter { $0.projectId == project.id }
                .filter { session in
                    guard let binding = model.sessionBinding(hostID: hostID, sessionID: session.id) else {
                        return false
                    }
                    return !binding.isArchived && !binding.isDeleted
                }
                .filter { session in
                    let title = model.sessionDisplayTitle(
                        hostID: hostID,
                        sessionID: session.id,
                        fallback: session.title ?? session.id
                    )
                    return SidebarFilterPolicy.matches(
                        title: title,
                        projectName: name,
                        query: query
                    )
                }
            let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let pinnedOrders = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                model.sessionBinding(hostID: hostID, sessionID: session.id)?
                    .pinOrder
                    .map { (session.id, $0) }
            })
            let activity = Dictionary(uniqueKeysWithValues: sessions.map { session in
                (session.id, model.sessionBinding(hostID: hostID, sessionID: session.id)?.lastActivityAt ?? .distantPast)
            })
            let ordered = SessionOrderingPolicy.orderedIDs(
                sessions.map(\.id),
                pinnedOrders: pinnedOrders,
                lastActivity: activity
            ).compactMap { byID[$0] }
            guard !ordered.isEmpty || query.isEmpty else { return nil }
            return SidebarGroup(project: project, name: name, sessions: ordered)
        }
        let activeProject = model.lastProjectID(for: hostID)
        return groups.sorted { left, right in
            if left.project.id == activeProject, right.project.id != activeProject { return true }
            if right.project.id == activeProject, left.project.id != activeProject { return false }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
    }

    /// 离线分组：与在线分组共用同一套查询匹配（`SidebarFilterPolicy`）。
    ///
    /// `cachedSessionIDs` 由调用方一次读出后传入，避免过滤/空态各读一次缓存快照。
    private func offlineSidebarGroups(cachedSessionIDs: [String]) -> [OfflineSidebarGroup] {
        guard let hostID = model.currentHost?.id else { return [] }
        var byProject: [String: [String]] = [:]

        for sessionID in cachedSessionIDs {
            let binding = model.sessionBinding(hostID: hostID, sessionID: sessionID)
            guard binding?.isArchived != true, binding?.isDeleted != true else { continue }
            let projectID = binding?.projectID ?? "offline-unassigned"
            if let project = model.projectBinding(hostID: hostID, projectID: projectID),
               project.isArchived || project.isDeleted {
                continue
            }
            let projectName = offlineProjectName(hostID: hostID, projectID: projectID)
            let title = offlineSessionTitle(hostID: hostID, sessionID: sessionID)
            guard SidebarFilterPolicy.matches(
                title: title,
                projectName: projectName,
                query: searchQuery
            ) else { continue }
            byProject[projectID, default: []].append(sessionID)
        }

        let groups = byProject.map { projectID, sessionIDs in
            let name = offlineProjectName(hostID: hostID, projectID: projectID)
            let pinnedOrders = Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { sessionID in
                model.sessionBinding(hostID: hostID, sessionID: sessionID)?
                    .pinOrder
                    .map { (sessionID, $0) }
            })
            let activity = Dictionary(uniqueKeysWithValues: sessionIDs.map { sessionID in
                (sessionID, model.sessionBinding(hostID: hostID, sessionID: sessionID)?.lastActivityAt ?? .distantPast)
            })
            return OfflineSidebarGroup(
                projectID: projectID,
                name: name,
                sessionIDs: SessionOrderingPolicy.orderedIDs(
                    sessionIDs,
                    pinnedOrders: pinnedOrders,
                    lastActivity: activity
                )
            )
        }
        let activeProject = model.lastProjectID(for: hostID)
        return groups.sorted { left, right in
            if left.projectID == activeProject, right.projectID != activeProject { return true }
            if right.projectID == activeProject, left.projectID != activeProject { return false }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
    }

    private func offlineProjectName(hostID: UUID, projectID: String) -> String {
        projectID == "offline-unassigned"
            ? "未归属项目"
            : model.projectDisplayName(
                hostID: hostID,
                projectID: projectID,
                fallback: projectID
            )
    }

    /// 离线会话的显示标题：优先本机保存的标题，缺失才退回会话 ID。
    ///
    /// 说明：缓存快照里还有服务器下发的 `title`，但当前 `ConnectionModel` 没有
    /// 公开的快照读取入口（本轮该文件被其它车道锁定），所以这里先用手上有的
    /// `titleOverride`（本机保存的显示标题），没有才用 ID。
    private func offlineSessionTitle(hostID: UUID, sessionID: String) -> String {
        model.sessionDisplayTitle(hostID: hostID, sessionID: sessionID, fallback: sessionID)
    }

    @ViewBuilder
    private func projectGroupHeader(
        name: String,
        count: Int,
        isCurrent: Bool,
        isCollapsed: Bool
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PIColor.text2)
                        .frame(width: 12)
                    Text(name)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: PISpacing.s8) {
                    Text("\(count) 个会话")
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text2)
                    if isCurrent {
                        Label("当前", systemImage: "checkmark")
                            .font(PIFont.metaSmall)
                            .foregroundStyle(PIColor.accent)
                            .labelStyle(.titleOnly)
                    }
                    Spacer()
                }
            }
        } else {
            HStack(spacing: PISpacing.s8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(PIColor.text2)
                    .frame(width: 12)
                Text(name)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                    .lineLimit(1)
                Text("\(count)")
                    .font(PIFont.metaSmall)
                    .monospacedDigit()
                    .foregroundStyle(PIColor.text2)
                if isCurrent {
                    HStack(spacing: PISpacing.s4) {
                        Circle()
                            .fill(PIColor.accent)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text("当前")
                            .font(PIFont.metaSmall)
                            .foregroundStyle(PIColor.accent)
                    }
                }
                Spacer()
            }
        }
    }

    private func offlineProjectGroup(_ group: OfflineSidebarGroup) -> some View {
        let hostID = model.currentHost?.id
        let collapsed = SidebarFilterPolicy.isCollapsed(
            storedCollapsed: hostID.map {
                model.isProjectGroupCollapsed(hostID: $0, projectID: group.projectID)
            } == true,
            query: searchQuery
        )
        let current = hostID.map { model.lastProjectID(for: $0) == group.projectID } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard SidebarFilterPolicy.canToggleGroup(query: searchQuery), let hostID else { return }
                model.toggleProjectGroup(hostID: hostID, projectID: group.projectID)
            } label: {
                projectGroupHeader(
                    name: group.name,
                    count: group.sessionIDs.count,
                    isCurrent: current,
                    isCollapsed: collapsed
                )
                .padding(.horizontal, PISpacing.s8)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(group.name)，\(group.sessionIDs.count) 个会话"
                    + (current ? "，当前项目" : "")
                    + (collapsed ? "，已折叠" : "")
            )
            .accessibilityHint(collapsed ? "展开会话列表" : "折叠会话列表")
            .accessibilityIdentifier("sidebar.project.\(group.projectID)")

            if !collapsed {
                ForEach(group.sessionIDs, id: \.self) { sessionID in
                    PIListRow(
                        // 离线行标题优先本机保存的标题，缺失才退回会话 ID（旧实现只显示 ID）。
                        title: hostID.map {
                            offlineSessionTitle(hostID: $0, sessionID: sessionID)
                        } ?? sessionID,
                        subtitle: hostID.map {
                            model.hasSessionUpdate(hostID: $0, sessionID: sessionID)
                                ? "本机缓存（只读） · 新" : "本机缓存（只读）"
                        } ?? "本机缓存（只读）",
                        showsChevron: true,
                        showsDivider: true,
                        action: {
                            guard let hostID else { return }
                            model.selectCachedSession(hostID: hostID, sessionID: sessionID)
                            model.switchRoot(.conversation)
                            model.closeSidebar()
                        }
                    )
                    // 稳定标识：离线行标题现在是「本机保存的标题」，不再以会话 ID 开头，
                    // 按标题找不到行；用例应改用这个 identifier 定位。
                    .accessibilityIdentifier("sidebar.cachedSession.\(sessionID)")
                }
            }
        }
        .padding(.bottom, PISpacing.s4)
    }

    private func projectGroup(_ group: SidebarGroup) -> some View {
        let hostID = model.currentHost?.id
        let collapsed = SidebarFilterPolicy.isCollapsed(
            storedCollapsed: hostID.map {
                model.isProjectGroupCollapsed(hostID: $0, projectID: group.project.id)
            } == true,
            query: searchQuery
        )
        let current = hostID.map { model.lastProjectID(for: $0) == group.project.id } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard SidebarFilterPolicy.canToggleGroup(query: searchQuery), let hostID else { return }
                model.toggleProjectGroup(hostID: hostID, projectID: group.project.id)
            } label: {
                projectGroupHeader(
                    name: group.name,
                    count: group.sessions.count,
                    isCurrent: current,
                    isCollapsed: collapsed
                )
                .padding(.horizontal, PISpacing.s8)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(group.name)，\(group.sessions.count) 个会话"
                    + (current ? "，当前项目" : "")
                    + (collapsed ? "，已折叠" : "")
            )
            .accessibilityHint(collapsed ? "展开会话列表" : "折叠会话列表")
            .accessibilityIdentifier("sidebar.project.\(group.project.id)")

            if !collapsed {
                let reorderableIDs = projectReorderableSessionIDs(for: group)
                ForEach(group.sessions, id: \.id) { session in
                    sessionRow(
                        session,
                        projectID: group.project.id,
                        reorderableIDs: reorderableIDs
                    )
                }
            }
        }
        .padding(.bottom, PISpacing.s4)
    }

    private func projectReorderableSessionIDs(for group: SidebarGroup) -> [String] {
        guard let hostID = model.currentHost?.id else { return [] }
        let candidates = group.sessions.compactMap { session -> SessionDragCandidate? in
            guard let binding = model.sessionBinding(
                hostID: hostID,
                sessionID: session.id
            ) else { return nil }
            return SessionDragCandidate(
                sessionID: session.id,
                projectID: binding.projectID ?? group.project.id,
                isPinned: binding.isPinned
            )
        }
        return SessionDragPolicy.reorderableSessionIDs(
            from: candidates,
            projectID: group.project.id
        )
    }

    private func sessionRow(
        _ session: RACPSessionSummary,
        projectID: String,
        reorderableIDs: [String]
    ) -> some View {
        let hostID = model.currentHost?.id
        let binding = hostID.flatMap { model.sessionBinding(hostID: $0, sessionID: session.id) }
        let title = hostID.map {
            model.sessionDisplayTitle(hostID: $0, sessionID: session.id, fallback: session.title ?? session.id)
        } ?? (session.title ?? session.id)
        let isCurrent = connection.session.attachedSessionId == session.id
        let isPinned = binding?.isPinned == true
        let content = HStack(spacing: PISpacing.s8) {
            if isPinned {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                    HStack(spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if hostID.map({ model.hasSessionUpdate(hostID: $0, sessionID: session.id) }) == true {
                            Text("新")
                                .font(PIFont.metaSmall.weight(.semibold))
                                .foregroundStyle(PIColor.text2)
                                .accessibilityLabel("离开期间有更新")
                        }
                    }
                    HStack(spacing: 5) {
                        if let tint = sessionStatusTint(session) {
                            Circle()
                                .fill(tint)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        Text(sessionStatus(session, binding: binding))
                            .font(PIFont.metaSmall)
                            .foregroundStyle(PIColor.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            .onTapGesture { openSession(session) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sidebar.session.\(session.id)")
            if isCurrent {
                HStack(spacing: PISpacing.s4) {
                    Circle()
                        .fill(PIColor.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("当前")
                        .font(PIFont.metaSmall.weight(.semibold))
                        .foregroundStyle(PIColor.accent)
                }
            }
            if let hostID {
                Button {
                    if isPinned {
                        model.unpinSession(hostID: hostID, sessionID: session.id)
                    } else {
                        model.pinSession(hostID: hostID, sessionID: session.id)
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isPinned ? PIColor.accent : PIColor.text3)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPinned ? "取消置顶" : "置顶会话")
                .accessibilityIdentifier("sidebar.pin.\(session.id)")
            }
        }
        .padding(.horizontal, PISpacing.s8)
        .padding(.vertical, 6)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarSessionFramePreferenceKey.self,
                    value: [
                        session.id: proxy.frame(
                            in: .named(SidebarSessionCoordinates.list)
                        ),
                    ]
                )
            }
        }
        .background(
            // 拖拽位置只由上下指示线表达；柔底专属于当前会话，避免两种状态叠成同一语义。
            (isCurrent ? PIColor.accentSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
        )
        .overlay(alignment: .top) {
            if dropResolution?.targetID == session.id, dropResolution?.edge == .before {
                dropIndicator
            }
        }
        .overlay(alignment: .bottom) {
            if dropResolution?.targetID == session.id, dropResolution?.edge == .after {
                dropIndicator
            }
        }
        .opacity(dragSessionID == session.id ? 0.72 : 1)
        .contentShape(Rectangle())
        .simultaneousGesture(
            reorderGesture(
                sessionID: session.id,
                projectID: projectID,
                isPinned: isPinned,
                reorderableIDs: reorderableIDs
            )
        )
        .accessibilityHint(isPinned ? "长按拖动可调整置顶顺序" : "")

        return HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if revealedSessionID == session.id, !dynamicTypeSize.isAccessibilitySize {
                sessionActionButtons(for: session)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : PIMotion.standard, value: revealedSessionID)
        .simultaneousGesture(sessionSwipeGesture(for: session))
        .accessibilityAction(named: "归档") { archiveSession(session) }
        .accessibilityAction(named: "删除") {
            revealedSessionID = nil
            sessionPendingDelete = SessionDeletionTarget(session: session)
        }
    }

    private func sessionActionButtons(for session: RACPSessionSummary) -> some View {
        HStack(spacing: 0) {
            sessionActionButton(
                title: "归档",
                icon: "archivebox",
                tint: PIColor.text,
                background: PIColor.warningSoft,
                identifier: "sidebar.archive.\(session.id)"
            ) { archiveSession(session) }
            sessionActionButton(
                title: "删除",
                icon: "trash",
                tint: PIColor.danger,
                background: PIColor.dangerSoft,
                identifier: "sidebar.delete.\(session.id)"
            ) {
                revealedSessionID = nil
                sessionPendingDelete = SessionDeletionTarget(session: session)
            }
        }
        .disabled(connection.sessionActionInFlight)
        .accessibilityElement(children: .contain)
    }

    private func sessionActionButton(
        title: String,
        icon: String,
        tint: Color,
        background: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PIFont.captionStrong)
                .lineLimit(1)
                .foregroundStyle(tint)
                .frame(width: 76)
                .frame(maxHeight: .infinity)
                .background(background)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// 快速横滑只展开操作；置顶会话的长按拖动仍走原 reorderGesture。
    private func sessionSwipeGesture(for session: RACPSessionSummary) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                guard !connection.sessionActionInFlight else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) else { return }
                if horizontal < -32 {
                    if dynamicTypeSize.isAccessibilitySize {
                        sessionActionSheet = SessionDeletionTarget(session: session)
                    } else {
                        withAnimation(reduceMotion ? nil : PIMotion.standard) {
                            revealedSessionID = session.id
                        }
                    }
                } else if horizontal > 32 {
                    withAnimation(reduceMotion ? nil : PIMotion.standard) {
                        revealedSessionID = nil
                    }
                }
            }
    }

    private var dropIndicator: some View {
        Rectangle()
            .fill(PIColor.accent)
            .frame(height: 2)
            .padding(.horizontal, PISpacing.s4)
            .accessibilityHidden(true)
    }

    private func reorderGesture(
        sessionID: String,
        projectID: String,
        isPinned: Bool,
        reorderableIDs: [String]
    ) -> some Gesture {
        LongPressGesture(
            minimumDuration: SessionDragPolicy.longPressDuration,
            maximumDistance: SessionDragPolicy.scrollCancellationDistance
        )
        .sequenced(
            before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(SidebarSessionCoordinates.list)
            )
        )
        .onChanged { value in
            guard isPinned else { return }
            switch value {
            case .first(true):
                dragSessionID = sessionID
                dropResolution = nil
            case .second(true, let drag):
                guard dragSessionID == sessionID, let drag else { return }
                dropResolution = SessionDragPolicy.resolveDrop(
                    at: drag.location,
                    sourceID: sessionID,
                    projectID: projectID,
                    candidates: dragCandidates(
                        reorderableIDs,
                        projectID: projectID
                    ),
                    frames: sessionRowFrames
                )
            default:
                break
            }
        }
        .onEnded { value in
            let sourceID = dragSessionID
            let resolution: SessionDropResolution?
            if case .second(true, let drag) = value, let drag {
                resolution = SessionDragPolicy.resolveDrop(
                    at: drag.location,
                    sourceID: sessionID,
                    projectID: projectID,
                    candidates: dragCandidates(
                        reorderableIDs,
                        projectID: projectID
                    ),
                    frames: sessionRowFrames
                )
            } else {
                resolution = dropResolution
            }
            defer { resetSessionDrag() }
            guard isPinned,
                  sourceID == sessionID,
                  let resolution,
                  let hostID = model.currentHost?.id
            else { return }
            applyDrop(
                hostID: hostID,
                projectID: projectID,
                sourceID: sessionID,
                resolution: resolution,
                orderedIDs: reorderableIDs
            )
        }
    }

    private func dragCandidates(
        _ reorderableIDs: [String],
        projectID: String
    ) -> [SessionDragCandidate] {
        reorderableIDs.map {
            SessionDragCandidate(
                sessionID: $0,
                projectID: projectID,
                isPinned: true
            )
        }
    }

    private func applyDrop(
        hostID: UUID,
        projectID: String,
        sourceID: String,
        resolution: SessionDropResolution,
        orderedIDs: [String]
    ) {
        switch resolution.edge {
        case .before:
            model.movePinnedSession(
                hostID: hostID,
                projectID: projectID,
                sessionID: sourceID,
                before: resolution.targetID
            )
        case .after:
            guard let targetIndex = orderedIDs.firstIndex(of: resolution.targetID) else {
                return
            }
            if let nextID = orderedIDs
                .dropFirst(targetIndex + 1)
                .first(where: { $0 != sourceID }) {
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: sourceID,
                    before: nextID
                )
            } else {
                // The PI-adaptor-facing model exposes "move before" only. These two
                // scoped moves append the source after the final pinned row.
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: sourceID,
                    before: resolution.targetID
                )
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: resolution.targetID,
                    before: sourceID
                )
            }
        }
    }

    private func resetSessionDrag() {
        dragSessionID = nil
        dropResolution = nil
        // 侧栏关闭/切换分组后不应把上一次展开的归档/删除按钮留给下一次进入的界面。
        revealedSessionID = nil
    }

    private func sessionStatus(
        _ session: RACPSessionSummary,
        binding: StoredSessionBinding?
    ) -> String {
        let status = session.status?.lowercased() ?? ""
        var parts: [String] = []
        if status.contains("running") || status.contains("working") {
            parts.append("运行中")
        } else if status.contains("waiting")
                    || status.contains("approval")
                    || status.contains("input")
                    || status.contains("pending") {
            parts.append("待处理")
        } else if status == "idle" {
            parts.append("空闲")
        } else {
            parts.append(session.status ?? "空闲")
        }
        if let messageCount = binding?.messageCount {
            parts.append("\(messageCount) 条")
        }
        return parts.joined(separator: " · ")
    }

    /// 运行中 / 待处理的会话在侧边栏给一个状态色；其余保持元信息灰。
    private func sessionStatusTint(_ session: RACPSessionSummary) -> Color? {
        let status = session.status?.lowercased() ?? ""
        if status.contains("running") || status.contains("working") {
            return PIColor.success
        }
        if status.contains("waiting")
            || status.contains("approval")
            || status.contains("input")
            || status.contains("pending") {
            return PIColor.warning
        }
        return nil
    }

    private func openSession(_ session: RACPSessionSummary) {
        guard !connection.sessionActionInFlight else { return }
        if revealedSessionID != nil {
            withAnimation(reduceMotion ? nil : PIMotion.quick) { revealedSessionID = nil }
            return
        }
        if let projectID = session.projectId {
            model.rememberProject(projectID)
        }
        model.rememberSession(session.id)
        // 已在当前会话时直接进入会话页：重复 attach 会无谓地重放历史，
        // 长会话下表现为点了没反应。
        if connection.session.openingSessionID == nil,
           connection.session.attachedSessionId == session.id,
           connection.session.view.sessionId == session.id {
            model.switchRoot(.conversation)
            model.closeSidebar()
            return
        }
        connection.session.prepareToOpen(sessionId: session.id)
        model.switchRoot(.conversation)
        model.closeSidebar()
        Task {
            guard !connection.sessionActionInFlight,
                  model.lastSessionId == session.id,
                  connection.session.openingSessionID == session.id else { return }
            await connection.session.attach(sessionId: session.id, source: "sidebar")
        }
    }

    private func sessionDisplayTitle(_ session: RACPSessionSummary) -> String {
        guard let hostID = model.currentHost?.id else { return session.title ?? session.id }
        return model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: session.id,
            fallback: session.title ?? session.id
        )
    }

    private func archiveSession(_ session: RACPSessionSummary) {
        guard let hostID = model.currentHost?.id else {
            PILog.warn("Session", "archive rejected session=\(session.id.prefix(8)) reason=noCurrentHost")
            return
        }
        guard connection.beginSessionAction() else {
            PILog.warn("Session", "archive rejected session=\(session.id.prefix(8)) reason=sessionActionInFlight")
            model.showToast("正在处理上一个会话操作，请稍候")
            return
        }
        PILog.info("Session", "archive start session=\(session.id.prefix(8)) host=\(hostID.uuidString.prefix(8))")
        revealedSessionID = nil
        Task {
            defer { connection.endSessionAction() }
            do {
                try await connection.archiveSession(sessionId: session.id, archived: true)
                model.setSessionArchived(hostID: hostID, sessionID: session.id, archived: true)
                finishSessionActionIfCurrent(session.id)
                PILog.info("Session", "archive end session=\(session.id.prefix(8)) result=ok")
                model.showToast("会话已归档")
            } catch {
                let message = ConnectionErrorText.describeSessionAction(error)
                PILog.warn("Session", "archive failed session=\(session.id.prefix(8)) error=\(message)")
                // Toast 位于根视图，抽屉关闭后 Host 原始错误仍可见。
                model.showToast(message)
            }
        }
    }

    private func deleteSession(_ session: RACPSessionSummary) {
        guard let hostID = model.currentHost?.id else {
            PILog.warn("Session", "delete rejected session=\(session.id.prefix(8)) reason=noCurrentHost")
            return
        }
        guard connection.beginSessionAction() else {
            PILog.warn("Session", "delete rejected session=\(session.id.prefix(8)) reason=sessionActionInFlight")
            model.showToast("正在处理上一个会话操作，请稍候")
            return
        }
        PILog.info("Session", "delete start session=\(session.id.prefix(8)) host=\(hostID.uuidString.prefix(8))")
        Task {
            defer { connection.endSessionAction() }
            do {
                try await connection.deleteSession(
                    sessionId: session.id,
                    confirmSessionId: session.id
                )
                model.deleteSessionLocally(hostID: hostID, sessionID: session.id)
                revealedSessionID = nil
                finishSessionActionIfCurrent(session.id)
                PILog.info("Session", "delete end session=\(session.id.prefix(8)) result=ok")
                model.showToast("会话已删除")
            } catch {
                let message = ConnectionErrorText.describeSessionAction(error)
                PILog.warn("Session", "delete failed session=\(session.id.prefix(8)) error=\(message)")
                model.showToast(message)
            }
        }
    }

    /// 先使任何仍在进行的打开请求失效，再按完成时的 attached ID 决定是否退出。
    private func finishSessionActionIfCurrent(_ sessionID: String) {
        connection.session.cancelPendingAttach(for: sessionID)
        guard connection.session.attachedSessionId == sessionID else { return }
        connection.session.detach()
        model.rememberSession(nil)
        model.switchRoot(.projects)
        model.closeSidebar()
    }

    // MARK: - 底部

    /// 抽屉底部只有两件事：**一个动作**（新建会话）与**一处目的地列表**（三个根）。
    ///
    /// quiet-v2 §6：旧的三个等宽描边方块既像分段控件又像按钮，只能靠图标+文字才读懂。
    /// 现在分成两种一眼可辨的形态：
    /// - 动作 = 实心强调色按钮（唯一的实心块，不可误读成「当前选中」）；
    /// - 根 = 单选目的地列表（一行一个根，当前项用强调色 + 勾选表达）。
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            PIPrimaryButton(
                title: "新建会话",
                isEnabled: connection.state.isOnline,
                identifier: "sidebar.newSession"
            ) {
                model.switchRoot(.projects)
            }
            HStack(spacing: PISpacing.s4) {
                ForEach(Self.rootOrder, id: \.self) { root in
                    rootRow(root)
                }
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s16)
        .padding(.bottom, PISpacing.s16)
    }

    private static let rootOrder: [AppModel.Root] = [.conversation, .projects, .settings]

    /// 一级导航：三个纯图标横向并列；文字仅保留给辅助技术。
    private func rootRow(_ root: AppModel.Root) -> some View {
        let isCurrent = model.root == root
        return Button {
            model.switchRoot(root)
        } label: {
            Image(systemName: rootIcon(root))
                .font(.system(size: 18, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? PIColor.accent : PIColor.text2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    isCurrent ? PIColor.accentSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PIPressableButtonStyle())
        .accessibilityLabel(root.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("sidebar.root.\(root.rawValue)")
    }

    private func rootIcon(_ root: AppModel.Root) -> String {
        switch root {
        case .conversation: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .settings: return "gearshape"
        }
    }

}

private enum SidebarSessionCoordinates {
    static let list = "sidebar-session-list"
}

private struct SidebarSessionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
