import SwiftUI
import PIiOSCore

struct SkillsScreen: View {
    @EnvironmentObject private var connection: ConnectionModel

    @State private var skills: [RACPV2Skill] = []
    @State private var isLoading = false
    @State private var error: String?
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
                // 安装已经成功、只有列表没刷新：这是部分成功，必须就地说明，
                // 不能让用户以为要再装一次。
                if case let .installedListStale(message) = install.phase {
                    staleListNotice(message)
                }
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
                skills = []
                error = nil
                isLoading = false
                // 离线不打断在途安装：让它自己收尾，避免把「正在安装」清成「没装过」。
                if !install.phase.isSubmitting { install = SkillInstallMachine() }
                return
            }
            await reloadReportingFailure()
        }
        .refreshable { await reloadReportingFailure() }
        .confirmationDialog(
            "删除 Skill？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除安装副本", role: .destructive) {
                if let skill = pendingDelete { Task { await delete(skill) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 PI-adaptor 的安装副本，不修改来源仓库或来源目录。")
        }
        .piMessageAlert(title: "Skill 操作失败", message: $error)
    }

    // MARK: - 已安装

    private var installedSection: some View {
        PIGroup("已安装", footer: "Skill 复制到 PI-adaptor 全局目录；运行中的 turn 固定使用启动时版本。") {
            if isLoading {
                PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
            } else if skills.isEmpty {
                PIListRow(
                    title: "还没有全局 Skill",
                    subtitle: "在下方「安装来源」填写后安装",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                    PIListRow(
                        title: skill.name,
                        subtitle: "\(skill.description) · \(skill.status)",
                        icon: "puzzlepiece.extension",
                        iconTint: PIColor.accent,
                        showsChevron: false,
                        showsDivider: index < skills.count - 1
                    ) {
                        Button(role: .destructive) {
                            pendingDelete = skill
                        } label: {
                            Text("删除")
                                .font(PIFont.captionStrong)
                                .foregroundStyle(PIColor.danger)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(PIColor.dangerSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // 离线时列表内容是「未知」而不是「空的」：与真正的空态分开说，
            // 避免把没读到写成没有。（离线禁用安装的文案由下方安装区承担。）
            if !connection.state.isOnline, !isLoading {
                PIInlineMessage(
                    kind: .warning,
                    text: "连接后才能读取已安装列表：现在显示的「还没有」不代表本机或服务器上确实没有。"
                )
                .padding(.horizontal, PISpacing.s16)
                .padding(.bottom, PISpacing.s12)
                .accessibilityIdentifier("skills.listUnknownOffline")
            }
        }
    }

    /// 安装成功、列表刷新失败时的就地提示（部分成功）。
    private func staleListNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIInlineMessage(
                kind: .warning,
                text: "已安装，但列表更新失败：\(message)。安装本身已成功，请不要重复安装。"
            )
            Button(isLoading ? "正在刷新…" : "重新读取列表") {
                Task { await retryListRefresh() }
            }
            .font(PIFont.captionStrong)
            .disabled(isLoading || !connection.state.isOnline)
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
                }
            }
            PIFormRow {
                PIFormField(label: "子目录（可选）") {
                    TextField("skills/demo", text: $subdir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(locked)
                }
            }
            if sourceType == "git" {
                PIFormRow {
                    PIFormField(label: "branch / tag / commit（可选）") {
                        TextField("main", text: $ref)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(locked)
                    }
                }
            }
            PIFormRow {
                Toggle("同名覆盖", isOn: $replace)
                    .font(PIFont.body)
                    .tint(PIColor.accent)
                    .disabled(locked)
            }
            PIFormRow(showsDivider: false) {
                // 注意：不要给这个按钮设 accessibilityIdentifier。既有 L3 用例 SKL-01
                // 用 `app.buttons["安装 Skill"]` 按**标签**定位，显式 identifier 会改变
                // 元素的可访问性标识，有把该用例打红的风险。
                PIPrimaryButton(
                    title: install.phase.buttonTitle,
                    isEnabled: canInstall
                ) {
                    Task { await startInstall() }
                }
            }
            if !connection.state.isOnline {
                PIInlineMessage(
                    kind: .warning,
                    text: "PI-adaptor 未连接，连接后可读取和管理全局 Skill。"
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
    /// 是否把它弹成「操作失败」由调用方决定：安装成功后的刷新失败必须说成
    /// 「已安装，列表更新失败」，不能被误报成安装失败。
    private func reload() async -> String? {
        guard connection.state.isOnline else {
            isLoading = false
            return nil
        }
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await connection.listAdaptorSkills()
            error = nil
            return nil
        } catch {
            return ConnectionErrorText.describe(error)
        }
    }

    /// 与安装无关的列表刷新（首次进入、下拉、删除后）：失败直接就近报错。
    private func reloadReportingFailure() async {
        if let failure = await reload() {
            error = failure
        }
    }

    private func startInstall() async {
        // 冻结提交值：await 之后只用这份快照，表单此刻再怎么改都不影响本次安装。
        let request = installRequest
        guard connection.state.isOnline, install.begin(request) else { return }
        error = nil
        do {
            _ = try await connection.installAdaptorSkill(
                source: request.sourcePayload(),
                replace: request.replace
            )
            install.installSucceeded()
            if let failure = await reload() {
                // 安装已成功，只有列表过期：保留来源，给出「重新读取列表」而不是再装一次。
                install.listRefreshFailed(failure)
            } else if install.listRefreshSucceeded() {
                // 安装成功且列表刷新成功，才清空输入。
                clearSourceFields()
            }
        } catch {
            let message = ConnectionErrorText.describe(error)
            install.installFailed(message)
            self.error = message
        }
    }

    /// 「已安装但列表没刷新」后的手动重试；成功后同样清空来源。
    private func retryListRefresh() async {
        if let failure = await reload() {
            error = failure
            return
        }
        if install.listRefreshSucceeded() {
            clearSourceFields()
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
            await reloadReportingFailure()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }
}
