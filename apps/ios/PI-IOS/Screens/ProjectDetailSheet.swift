import SwiftUI
import PIiOSCore

/// 项目行：名称 + 计数/状态数据。
///
/// quiet-v2 §10「用布局替代解释」：一行只有一个点击目标——整行进项目详情浮层，
/// chevron 是唯一的可点提示。详情浮层里再开会话、改名、归档、删除。
/// 图标单色，不带色块 chip（§2）。
struct ProjectSummaryRow: View {
    let projectID: String
    let name: String
    let sessionCount: Int
    let runningCount: Int
    let pendingCount: Int
    let isCurrent: Bool
    let showsDivider: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(alignment: .center, spacing: PISpacing.s12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(isCurrent ? PIColor.accent : PIColor.text2)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(name)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: PISpacing.s8) {
                            if isCurrent {
                                Text("当前")
                                    .font(PIFont.metaSmall.weight(.semibold))
                                    .foregroundStyle(PIColor.accent)
                            }
                            Text("\(sessionCount) 个会话")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                            if runningCount > 0 {
                                statusChip("运行 \(runningCount)", tint: PIColor.success)
                            }
                            if pendingCount > 0 {
                                statusChip("待处理 \(pendingCount)", tint: PIColor.warning)
                            }
                        }
                    }
                    Spacer(minLength: PISpacing.s8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(maxWidth: .infinity, minHeight: PIMetrics.listRowMinHeight)
                .background(
                    isCurrent ? PIColor.accentSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name)，\(isCurrent ? "当前项目，" : "")\(summary)")
            .accessibilityIdentifier("projects.row.\(projectID)")
            if showsDivider { PIRowDivider() }
        }
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        HStack(spacing: PISpacing.s4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(text)
                .font(PIFont.metaSmall)
                .foregroundStyle(PIColor.text2)
        }
    }

    private var summary: String {
        var parts: [String] = ["\(sessionCount) 个会话"]
        if runningCount > 0 { parts.append("运行 \(runningCount)") }
        if pendingCount > 0 { parts.append("待处理 \(pendingCount)") }
        return parts.joined(separator: " · ")
    }
}

struct ProjectDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let project: RACPProjectSummary
    let initialName: String
    let onOpenSession: (RACPSessionSummary) -> Void
    let onNewSession: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    @State private var projectName: String
    @State private var nameError: String?
    @State private var showingDeleteConfirm = false
    @State private var sessionActionError: String?
    @State private var isRestoringSession = false

    init(
        project: RACPProjectSummary,
        initialName: String,
        onOpenSession: @escaping (RACPSessionSummary) -> Void,
        onNewSession: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.project = project
        self.initialName = initialName
        self.onOpenSession = onOpenSession
        self.onNewSession = onNewSession
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.onRestore = onRestore
        _projectName = State(initialValue: initialName)
    }

    private var hostID: UUID? { model.currentHost?.id }

    private var binding: StoredProjectBinding? {
        guard let hostID else { return nil }
        return model.projectBinding(hostID: hostID, projectID: project.id)
    }

    private var sessions: [RACPSessionSummary] {
        connection.sessions.filter { session in
            guard session.projectId == project.id else { return false }
            guard let hostID else { return true }
            return !(model.sessionBinding(hostID: hostID, sessionID: session.id)?.isDeleted ?? false)
        }
    }

    private var runningCount: Int {
        sessions.filter { ($0.status?.lowercased() ?? "").contains("running") }.count
    }

    private var activeSessionCount: Int {
        guard let hostID else { return 0 }
        return sessions.filter { session in
            guard let binding = model.sessionBinding(hostID: hostID, sessionID: session.id) else {
                return false
            }
            return !binding.isArchived && !binding.isDeleted
        }.count
    }

    private var isArchived: Bool {
        binding?.isArchived ?? false
    }

    private var sessionStatisticsText: String {
        guard connection.hasLoadedCatalog else {
            return "正在读取会话"
        }
        let suffix = isCatalogStale ? " · 上次同步" : ""
        return "\(sessions.count) 个会话 · \(activeSessionCount) 个活跃 · 运行中 \(runningCount)\(suffix)"
    }

    private var isCatalogStale: Bool {
        !connection.state.isOnline || connection.catalogError != nil
    }

    private var canCreateSession: Bool {
        connection.state.isOnline
            && !isArchived
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    PICard {
                        Text(binding?.name ?? initialName)
                            .font(PIFont.display)
                            .foregroundStyle(PIColor.text)
                        Text(binding?.path ?? "路径未记录")
                            .font(PIFont.metaMono)
                            .foregroundStyle(PIColor.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(sessionStatisticsText)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }


                    if !connection.hasLoadedCatalog {
                        PIInlineMessage(kind: .info, text: "正在读取")
                    } else if let catalogError = connection.catalogError {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            PIInlineMessage(
                                kind: .warning,
                                text: "数据可能不是最新：\(catalogError)"
                            )
                            Button(connection.isRefreshingCatalog ? "正在重试…" : "重试") {
                                Task { await connection.refreshRemote() }
                            }
                            .font(PIFont.captionStrong)
                            .disabled(connection.isRefreshingCatalog)
                            .accessibilityIdentifier("projectDetail.retry")
                        }
                    } else if !connection.state.isOnline {
                        PIInlineMessage(kind: .warning, text: "服务器离线 · 上次同步数据")
                    }

                    PIGroup("项目名称") {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            TextField("项目名称", text: $projectName)
                                .piFieldChrome()
                                .accessibilityIdentifier("projectDetail.name")
                            if let nameError {
                                Text(nameError)
                                    .font(PIFont.caption)
                                    .foregroundStyle(PIColor.danger)
                            }
                            // quiet-v2：整宽实心只留给「一页一个主操作」。
                            // 改名是次要提交，降为次级按钮。
                            PISecondaryButton(
                                title: "保存名称",
                                isEnabled: canSaveName
                            ) {
                                saveName()
                            }
                            .accessibilityIdentifier("projectDetail.saveName")
                        }
                        .padding(PISpacing.s16)
                    }

                    PIGroup("会话") {
                        if !connection.hasLoadedCatalog {
                            PIListRow(
                                title: "正在读取会话",
                                isEnabled: false,
                                showsDivider: true
                            )
                        } else if sessions.isEmpty {
                            PIListRow(
                                title: "没有会话",
                                isEnabled: false,
                                showsDivider: true
                            )
                        } else {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { _, session in
                                sessionRow(session, showsDivider: true)
                            }
                        }
                        PIListRow(
                            title: "新建会话",
                            icon: "plus.circle",
                            iconTint: PIColor.accent,
                            isEnabled: canCreateSession,
                            showsChevron: true,
                            showsDivider: false,
                            action: onNewSession
                        )
                        .accessibilityIdentifier("projectDetail.newSession")
                    }

                    PIGroup("项目状态") {
                        PIListRow(
                            title: isArchived ? "恢复项目" : "归档项目",
                            showsDivider: true,
                            action: {
                                if isArchived {
                                    onRestore()
                                } else {
                                    onArchive()
                                }
                            }
                        )
                        .accessibilityIdentifier("projectDetail.archive")
                        PIDangerRow(
                            title: "从本机删除项目",
                            action: { showingDeleteConfirm = true }
                        )
                        .accessibilityIdentifier("projectDetail.delete")
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("项目详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(isRestoringSession)
                }
            }
            // R7：确认框只说后果。标题写动作，一行 message 写会失去什么；不写安抚性保证。
            .alert("删除「\(displayName)」？", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("本机的项目记录、会话记录与缓存都会清除。")
            }
            .piMessageAlert(title: "操作未完成", message: $sessionActionError)
            .interactiveDismissDisabled(isRestoringSession)
            .onChange(of: model.projectBindings) { _, _ in
                if let current = binding?.name, projectName != current {
                    projectName = current
                }
            }
        }
    }

    /// 确认框与卡片使用同一份「本机显示名」。
    private var displayName: String {
        binding?.name ?? initialName
    }

    private var canSaveName: Bool {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (binding?.name ?? initialName)
    }

    private func saveName() {
        guard let hostID else { return }
        if model.renameProject(hostID: hostID, projectID: project.id, name: projectName) {
            nameError = nil
            model.showToast("项目名称已更新")
        } else {
            nameError = "项目名称不能为空，且同一 PI-adaptor 内不能重名"
        }
    }

    private func sessionRow(_ session: RACPSessionSummary, showsDivider: Bool) -> some View {
        let hostID = self.hostID
        let binding = hostID.flatMap { model.sessionBinding(hostID: $0, sessionID: session.id) }
        let archived = binding?.isArchived ?? false
        let title = hostID.map {
            model.sessionDisplayTitle(hostID: $0, sessionID: session.id, fallback: session.title ?? session.id)
        } ?? (session.title ?? session.id)
        return VStack(spacing: 0) {
            HStack(spacing: PISpacing.s8) {
                Button {
                    if archived { restoreSession(session) } else { onOpenSession(session) }
                } label: {
                    HStack(spacing: PISpacing.s12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(PIColor.text2)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(title)
                                .font(PIFont.listTitle)
                                .foregroundStyle(PIColor.text)
                            Text(archived ? "已归档" : Self.statusText(session.status))
                                .font(PIFont.caption)
                                .foregroundStyle(archived ? PIColor.text3 : PIColor.text2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: PIMetrics.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(archived && isRestoringSession)
                .accessibilityIdentifier("projectDetail.session.\(session.id)")
                if archived {
                    Button("恢复") { restoreSession(session) }
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.accent)
                        .frame(minWidth: PIMetrics.minHitTarget, minHeight: PIMetrics.minHitTarget)
                        .contentShape(Rectangle())
                        .disabled(isRestoringSession)
                        .accessibilityIdentifier("projectDetail.restoreSession.\(session.id)")
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
            if showsDivider { PIRowDivider() }
        }
    }

    /// 服务器下发的是英文状态码，只在展示层翻译一次。
    private static func statusText(_ status: String?) -> String {
        guard let status else { return "空闲" }
        let value = status.lowercased()
        if value.contains("running") || value.contains("working") { return "运行中" }
        if value.contains("waiting") || value.contains("approval")
            || value.contains("input") || value.contains("pending") { return "待处理" }
        if value == "idle" { return "空闲" }
        return status
    }

    private func restoreSession(_ session: RACPSessionSummary) {
        guard let hostID, connection.beginSessionAction() else { return }
        isRestoringSession = true
        Task {
            defer {
                isRestoringSession = false
                connection.endSessionAction()
            }
            do {
                let restored = try await connection.archiveSession(
                    sessionId: session.id,
                    archived: false
                )
                model.setSessionArchived(hostID: hostID, sessionID: session.id, archived: false)
                onOpenSession(restored)
            } catch {
                sessionActionError = ConnectionErrorText.describeSessionAction(error)
            }
        }
    }
}
