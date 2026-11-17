import SwiftUI
import PIiOSCore

struct SkillsScreen: View {
    @EnvironmentObject private var connection: ConnectionModel

    /// 列表的「五种现实」：idle / loading / loaded / failed(+旧数据)。
    /// 只有 `.loaded([])` 才允许画空态；断线与失败保留上一次成功的数据。
    @State private var skills: ContentState<[RACPV2Skill]> = .idle
    /// 删除失败：用户动作的回执，按 §5.1 用 alert 确认。
    @State private var deleteError: String?
    @State private var sourceType = "git"
    @State private var sourceValue = ""
    @State private var subdir = ""
    @State private var ref = ""
    @State private var replace = false
    @State private var pendingDelete: RACPV2Skill?
    /// 安装阶段（U08）：区分「未受理 / 正在安装 / 已安装但列表没刷新 / 安装失败」。
    @State private var install = SkillInstallMachine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                // quiet-v2：页面顶部不再放任何错误。列表状态画在列表里，
                // 安装失败/部分成功画在「安装 Skill」按钮旁。
                installedSection
                sourceSection
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .navigationTitle("全局 Skill")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.state.isOnline) {
            guard connection.state.isOnline else {
                // 断线：把已取到的列表降级为 stale，而不是清成「没有」。
                skills.markStale(reason: "未连接")
                // 离线不打断在途安装：让它自己收尾，避免把「正在安装」清成「没装过」。
                if !install.phase.isSubmitting { install = SkillInstallMachine() }
                return
            }
            await reload()
        }
        .refreshable { await reload() }
        // 删除失败是「需要被确认的一次结果」，用 alert；列表状态不走弹窗。
        .piMessageAlert(title: "删除未完成", message: $deleteError)
        .confirmationDialog(
            // 与另外两个破坏性确认框同口径：标题点名对象，message 说后果（R7）。
            "删除「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除安装副本", role: .destructive) {
                if let skill = pendingDelete { Task { await delete(skill) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // R7：只说后果，不写「来源仓库不受影响」这类安抚/保证句。
            Text("PI-adaptor 上的安装副本会被删除。")
        }
    }

    // MARK: - 已安装

    private var installedSection: some View {
        PIGroup("已安装") {
            switch skills.presentation() {
            case let .loading(hasStale):
                // 正在读：有旧数据就继续画，读不到不清空。
                if hasStale, let cached = skills.value, !cached.isEmpty {
                    installedRows(cached)
                } else {
                    PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                }
            case let .content(cached, _):
                installedRows(cached)
            case .empty:
                // 只有「读成功且确实为空」才是空态。
                PIListRow(
                    title: "还没有全局 Skill",
                    isEnabled: false,
                    showsDivider: false
                )
            case let .failed(reason):
                // 读失败且没有旧数据：说原因 + 给重试，不写「还没有」。
                listFailureRow(reason)
            }
            if case let .content(_, isStale) = skills.presentation(), isStale {
                listStaleRow(skills.failureReason ?? "")
            }
        }
    }

    /// 成功读到的行。
    @ViewBuilder
    private func installedRows(_ list: [RACPV2Skill]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, skill in
            PIListRow(
                title: skill.name,
                subtitle: "\(skill.description) · \(skill.status)",
                icon: "puzzlepiece.extension",
                iconTint: PIColor.text2,
                showsChevron: false,
                showsDivider: index < list.count - 1
            ) {
                Button(role: .destructive) {
                    pendingDelete = skill
                } label: {
                    Text("删除")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.danger)
                        .frame(minHeight: PIMetrics.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("skills.delete.\(skill.name)")
            }
        }
    }

    /// 读到过数据、但这次没读到：画旧数据 + 一行 stale 提示，不清空。
    private func listStaleRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack(spacing: PISpacing.s8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(PIColor.warning)
                    .accessibilityHidden(true)
                Text("上次读取的数据")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
            }
            if !reason.isEmpty {
                Text(reason)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills.listState")
    }

    /// 读失败且没有旧数据：原因 + 重试入口。
    private func listFailureRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIInlineMessage(kind: .danger, text: reason)
                .accessibilityIdentifier("skills.listState")
            Button {
                Task { await reload() }
            } label: {
                Text("重新读取")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.accent)
                    .frame(minHeight: PIMetrics.minHitTarget)
            }
            .buttonStyle(.plain)
            .disabled(!connection.state.isOnline)
            .accessibilityIdentifier("skills.listRetry")
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
    }

    /// 安装成功、列表刷新失败时的就地提示（部分成功）。
    /// 归属「安装 Skill」按钮：是这次点按的回执，不是列表的加载失败。
    private func staleListNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIInlineMessage(
                kind: .warning,
                text: "已安装，但列表未刷新：\(message)。"
            )
            Button(install.phase.isSubmitting ? "正在刷新…" : "重新读取列表") {
                Task { await retryListRefresh() }
            }
            .font(PIFont.captionStrong)
            .disabled(install.phase.isSubmitting || !connection.state.isOnline)
            .accessibilityIdentifier("skills.reloadStaleList")
        }
        .accessibilityIdentifier("skills.installStale")
    }

    // MARK: - 安装来源

    private var sourceSection: some View {
        let locked = install.phase.isSubmitting
        return PIGroup("安装来源") {
            PIFormRow {
                Picker("来源类型", selection: $sourceType) {
                    Text("公开 Git").tag("git")
                    Text("服务器目录").tag("directory")
                }
                .pickerStyle(.segmented)
                .disabled(locked)
                .accessibilityIdentifier("skills.sourceType")
            }
            PIFormRow {
                PIFormField(label: sourceType == "git" ? "Git URL" : "服务器目录") {
                    TextField(
                        sourceType == "git" ? "https://github.com/…" : "/home/user/skills/demo",
                        text: $sourceValue
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(locked)
                    .accessibilityIdentifier("skills.sourceValue")
                }
            }
            PIFormRow {
                PIFormField(label: "子目录") {
                    TextField("skills/demo", text: $subdir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(locked)
                        .accessibilityIdentifier("skills.subdir")
                }
            }
            if sourceType == "git" {
                PIFormRow {
                    PIFormField(label: "分支或版本") {
                        TextField("main", text: $ref)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(locked)
                            .accessibilityIdentifier("skills.ref")
                    }
                }
            }
            PIFormRow {
                Toggle("同名覆盖", isOn: $replace)
                    .font(PIFont.body)
                    .tint(PIColor.accent)
                    .disabled(locked)
                    .accessibilityIdentifier("skills.replace")
            }
            PIFormRow(showsDivider: false) {
                // 按钮标题随安装阶段变化（安装 Skill / 正在安装… / 重试安装），
                // 所以 L3 只能按 identifier 定位，不能按标签。
                PIPrimaryButton(
                    title: install.phase.buttonTitle,
                    isEnabled: canInstall,
                    identifier: "skills.install"
                ) {
                    Task { await startInstall() }
                }
            }
            // §5.1：安装失败属于「安装 Skill」按钮，贴着按钮说原因，不放到页面顶部。
            if case let .failed(message) = install.phase {
                PIInlineMessage(kind: .danger, text: message)
                    .padding(.horizontal, PISpacing.s16)
                    .padding(.bottom, PISpacing.s12)
                    .accessibilityIdentifier("skills.error")
            }
            // 安装已成功、只有列表没刷新：部分成功，也说在同一个按钮旁。
            if case let .installedListStale(message) = install.phase {
                staleListNotice(message)
                    .padding(.horizontal, PISpacing.s16)
                    .padding(.bottom, PISpacing.s12)
            }
            if !connection.state.isOnline {
                PIInlineMessage(
                    kind: .warning,
                    text: "未连接：连接后可管理。"
                )
                .padding(.horizontal, PISpacing.s16)
                .padding(.bottom, PISpacing.s12)
            }
        }
    }

    /// 本次点击要提交的来源。安装开始前冻结一次，之后不再读实时输入。
    private var installRequest: SkillInstallRequest {
        SkillInstallRequest(
            sourceType: sourceType,
            location: sourceValue,
            subdir: subdir,
            reference: ref,
            replace: replace
        )
    }

    private var canInstall: Bool {
        connection.state.isOnline
            && install.canStartNewInstall
            && installRequest.isValid
    }

    // MARK: - 行为

    /// 读取已安装列表。返回失败文案（成功返回 `nil`）。
    ///
    /// 列表本身的失败已经写进 `skills` 状态（就地画在列表区）；
    /// 返回值只给「安装成功后的刷新失败」用——那属于安装按钮的部分成功回执，
    /// 不能被说成安装失败。
    /// 列表刷新结果必须区分「成功」「失败」「未执行（离线）」。之前离线也返回
    /// nil，调用方把 nil 当成功，安装成功后断网会误清空来源并丢失“已安装未刷新”
    /// 的部分成功提示。
    private enum ReloadOutcome {
        case success
        case failed(String)
        case notAttempted
    }

    private func reload() async -> ReloadOutcome {
        guard connection.state.isOnline else {
            // 没读到：降级为 stale，保留上次列表。
            skills.markStale(reason: "未连接")
            return .notAttempted
        }
        // 正在读：保留上一次成功的数据，刷新瞬间不闪成空列表。
        skills.beginLoading()
        do {
            skills.succeed(try await connection.listAdaptorSkills())
            return .success
        } catch {
            let message = ConnectionErrorText.describe(error)
            // 失败不清空：有旧数据就降级成 stale，没有就画原因 + 重试。
            skills.markStale(reason: message)
            return .failed(message)
        }
    }

    private func startInstall() async {
        // 冻结提交值：await 之后只用这份快照，表单此刻再怎么改都不影响本次安装。
        let request = installRequest
        guard connection.state.isOnline, install.begin(request) else { return }
        do {
            _ = try await connection.installAdaptorSkill(
                source: request.sourcePayload(),
                replace: request.replace
            )
            install.installSucceeded()
            switch await reload() {
            case .failed(let failure):
                // 安装已成功，只有列表过期：保留来源，给出「重新读取列表」而不是再装一次。
                install.listRefreshFailed(failure)
            case .notAttempted:
                install.listRefreshFailed("安装成功，但当前未连接，列表未刷新")
            case .success:
                if install.listRefreshSucceeded() {
                    // 安装成功且列表刷新成功，才清空输入。
                    clearSourceFields()
                }
            }
        } catch {
            // 失败原因随阶段一起就地显示在安装按钮旁（install.phase）。
            install.installFailed(ConnectionErrorText.describe(error))
        }
    }

    /// 「已安装但列表没刷新」后的手动重试；成功后同样清空来源。
    private func retryListRefresh() async {
        switch await reload() {
        case .failed(let failure):
            install.listRefreshFailed(failure)
        case .notAttempted:
            install.listRefreshFailed("仍未连接，列表未刷新")
        case .success:
            if install.listRefreshSucceeded() {
                clearSourceFields()
            }
        }
    }

    private func clearSourceFields() {
        sourceValue = ""
        subdir = ""
        ref = ""
    }

    private func delete(_ skill: RACPV2Skill) async {
        do {
            try await connection.deleteAdaptorSkill(id: skill.id)
            await reload()
        } catch {
            deleteError = ConnectionErrorText.describe(error)
        }
    }
}
