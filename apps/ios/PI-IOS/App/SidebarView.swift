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
    @State private var searchText = ""
    @State private var dragSessionID: String?
    @State private var dropResolution: SessionDropResolution?
    @State private var sessionRowFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hostSelector
            divider
            conversationArea
            divider
            bottomBar
        }
        .frame(width: PIMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // 侧边栏顶部不留一条死白：用一层由浅到无的顶光渐变把状态栏区域接进来，
            // 与页面背景的「顶部微光」保持同一语言。
            ZStack(alignment: .top) {
                PIColor.surface
                LinearGradient(
                    colors: [PIColor.surface2.opacity(0.85), PIColor.surface.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 210)
                RadialGradient(
                    colors: [PIColor.accent.opacity(0.10), .clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 260
                )
                .frame(height: 260)
            }
            .ignoresSafeArea()
        }
        .onDisappear(perform: resetSessionDrag)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(width: PIMetrics.hairline)
                .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
    }

    private var divider: some View {
        Rectangle()
            .fill(PIColor.separator)
            .frame(height: PIMetrics.hairline)
    }

    // MARK: - PI-adaptor 选择器

    @ViewBuilder
    private var hostSelector: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            HStack {
                Text("服务器")
                    .font(PIFont.metaSmall)
                    .tracking(1.2)
                    .foregroundStyle(PIColor.text3)
                Spacer()
                Button {
                    model.closeSidebar()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(PIColor.text2)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .background(PIColor.surface2, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("关闭侧边栏")
                .accessibilityIdentifier("sidebar.close")
            }

            if model.hosts.isEmpty {
                Button {
                    model.showSettings()
                } label: {
                    HStack(spacing: PISpacing.s12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PIColor.accent)
                            .frame(width: 34, height: 34)
                            .background(PIColor.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text("未配置服务器")
                                .font(PIFont.listTitle)
                                .foregroundStyle(PIColor.text)
                            Text("去设置添加服务器")
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.accent)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.vertical, PISpacing.s8)
                    .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: PIMetrics.minHitTarget)
            } else {
                Menu {
                    ForEach(model.hosts) { host in
                        Button {
                            Task { await model.setCurrentHost(id: host.id) }
                        } label: {
                            Text(host.isCurrent ? "✓ \(host.name)" : host.name)
                        }
                    }
                    Divider()
                    Button("管理服务器…") { model.showSettings() }
                } label: {
                    HStack(spacing: PISpacing.s12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PIColor.accent)
                            .frame(width: 34, height: 34)
                            .background(PIColor.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(model.currentHost?.name ?? "选择服务器")
                                .font(PIFont.listTitle)
                                .foregroundStyle(PIColor.text)
                                .lineLimit(1)
                            HStack(spacing: PISpacing.s4) {
                                Circle()
                                    .fill(connection.state.isOnline ? PIColor.success : PIColor.warning)
                                    .frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                                Text(model.currentHost?.statusText ?? "")
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text2)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: PISpacing.s4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PIColor.text3)
                    }
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.vertical, PISpacing.s8)
                    .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
                    .contentShape(Rectangle())
                }
                .frame(minHeight: PIMetrics.minHitTarget)
                .accessibilityLabel("切换服务器")
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s12)
        .padding(.bottom, PISpacing.s12)
    }

    private var conversationArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                        .accessibilityHidden(true)
                    TextField("搜索会话或项目", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .font(PIFont.body)
                        .onSubmit {}
                }
                .padding(.horizontal, PISpacing.s12)
                .frame(minHeight: 40)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
                )
                .padding(.bottom, PISpacing.s8)
                if connection.state.isOnline {
                    if sidebarGroups.isEmpty {
                        Text(
                            searchQuery.isEmpty
                                ? "没有活跃会话；上游同步的会话会先进入已归档，可在项目详情恢复。"
                                : "没有匹配的会话或项目。"
                        )
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(sidebarGroups) { group in
                            projectGroup(group)
                        }
                    }
                } else {
                    // 一次读出缓存 id 列表：离线分组的过滤与空态都基于同一份输入，
                    // 避免每渲染一次就多读几次缓存快照。
                    let cachedSessionIDs = connection.cachedSessionIds()
                    let groups = offlineSidebarGroups(cachedSessionIDs: cachedSessionIDs)
                    if groups.isEmpty {
                        Text(
                            SidebarFilterPolicy.offlineEmptyMessage(
                                hasCachedSessions: !cachedSessionIDs.isEmpty,
                                query: searchQuery
                            )
                        )
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("离线：下面是可以只读查看的缓存会话。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
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
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PIColor.text3)
                        .frame(width: 12)
                    Text(group.name)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text)
                        .lineLimit(1)
                    Text("\(group.sessionIDs.count)")
                        .font(PIFont.metaSmall)
                        .monospacedDigit()
                        .foregroundStyle(PIColor.text3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(PIColor.surface2, in: Capsule())
                    if current {
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
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PIColor.text3)
                        .frame(width: 12)
                    Text(group.name)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text)
                        .lineLimit(1)
                    Text("\(group.sessions.count)")
                        .font(PIFont.metaSmall)
                        .monospacedDigit()
                        .foregroundStyle(PIColor.text3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(PIColor.surface2, in: Capsule())
                    if current {
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
        return HStack(spacing: PISpacing.s8) {
            if isPinned {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
            Button {
                openSession(session)
            } label: {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    HStack(spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                            .lineLimit(1)
                        if hostID.map({ model.hasSessionUpdate(hostID: $0, sessionID: session.id) }) == true {
                            Text("新")
                                .font(PIFont.metaSmall.weight(.semibold))
                                .foregroundStyle(PIColor.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(PIColor.accentSoft, in: Capsule())
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
                            .foregroundStyle(sessionStatusTint(session) ?? PIColor.text3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            (dropResolution?.targetID == session.id || isCurrent ? PIColor.accentSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(PIColor.accent)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
        }
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
        .gesture(
            reorderGesture(
                sessionID: session.id,
                projectID: projectID,
                isPinned: isPinned,
                reorderableIDs: reorderableIDs
            )
        )
        .accessibilityHint(
            isPinned ? "长按 0.5 秒后拖动，可在本项目内调整置顶顺序" : ""
        )
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
        if let projectID = session.projectId {
            model.rememberProject(projectID)
        }
        model.rememberSession(session.id)
        Task {
            await connection.session.attach(sessionId: session.id)
            model.switchRoot(.conversation)
            model.closeSidebar()
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            if connection.state.isOnline {
                PIListRow(
                    title: "新建会话",
                    subtitle: "先选择项目（作为工作区）",
                    icon: "plus.circle",
                    iconTint: PIColor.accent,
                    showsChevron: true,
                    showsDivider: false,
                    action: {
                        model.switchRoot(.projects)
                        model.closeSidebar()
                    }
                )
            } else {
                disabledAction(title: "新建会话", reason: "未连接服务器，无法新建会话")
            }
            HStack(spacing: PISpacing.s8) {
                // IA §1 的三个根都要有入口：会话 / 项目 / 设置（会话页仍是既有空态，不造假数据）。
                rootButton(.conversation)
                rootButton(.projects)
                rootButton(.settings)
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s12)
        .padding(.bottom, PISpacing.s16)
    }

    private func rootButton(_ root: AppModel.Root) -> some View {
        Button {
            model.switchRoot(root)
        } label: {
            VStack(spacing: PISpacing.s4) {
                Image(systemName: rootIcon(root))
                    .font(.system(size: 15, weight: .semibold))
                Text(root.title)
                    .font(PIFont.metaSmall.weight(.semibold))
            }
            .foregroundStyle(model.root == root ? PIColor.accent : PIColor.text2)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                model.root == root ? PIColor.accentSoft : PIColor.surface2,
                in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(
                        model.root == root ? PIColor.accentBorder : PIColor.separator,
                        lineWidth: PIMetrics.hairline
                    )
            )
        }
        .buttonStyle(PIPressableButtonStyle())
        .accessibilityLabel(root.title)
        .accessibilityAddTraits(model.root == root ? .isSelected : [])
    }

    private func rootIcon(_ root: AppModel.Root) -> String {
        switch root {
        case .conversation: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .settings: return "gearshape"
        }
    }

    /// 禁用态操作：明确写清原因，不做「点了没反应」的按钮。
    private func disabledAction(title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack(spacing: PISpacing.s8) {
                Image(systemName: "lock")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(PIFont.button)
                Spacer(minLength: 0)
            }
            .foregroundStyle(PIColor.text3)
            .padding(.horizontal, PISpacing.s12)
            .frame(maxWidth: .infinity, minHeight: PIMetrics.minHitTarget)
            .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
            Text(reason)
                .font(PIFont.metaSmall)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，不可用：\(reason)")
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
