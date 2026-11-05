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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                PIGroup("已安装", footer: "Skill 复制到 PI-adaptor 全局目录；运行中的 turn 固定使用启动时版本。") {
                    if isLoading {
                        PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                    } else if skills.isEmpty {
                        PIListRow(title: "还没有全局 Skill", subtitle: "在下方「安装来源」填写后安装", isEnabled: false, showsDivider: false)
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
                }
                PIGroup("安装来源") {
                    PIFormRow {
                        Picker("来源类型", selection: $sourceType) {
                            Text("公开 Git").tag("git")
                            Text("服务器目录").tag("directory")
                        }
                        .pickerStyle(.segmented)
                    }
                    PIFormRow {
                        PIFormField(label: sourceType == "git" ? "Git URL" : "服务器目录") {
                            TextField(
                                sourceType == "git" ? "https://github.com/…" : "/home/user/skills/demo",
                                text: $sourceValue
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "子目录（可选）") {
                            TextField("skills/demo", text: $subdir)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    if sourceType == "git" {
                        PIFormRow {
                            PIFormField(label: "branch / tag / commit（可选）") {
                                TextField("main", text: $ref)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                    }
                    PIFormRow {
                        Toggle("同名覆盖", isOn: $replace)
                            .font(PIFont.body)
                            .tint(PIColor.accent)
                    }
                    PIFormRow(showsDivider: false) {
                        PIPrimaryButton(
                            title: "安装 Skill",
                            isEnabled: connection.state.isOnline
                                && !sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            Task { await install() }
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
                return
            }
            await reload()
        }
        .refreshable { await reload() }
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

    private func reload() async {
        guard connection.state.isOnline else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await connection.listAdaptorSkills()
            error = nil
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }

    private func install() async {
        let value = sourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: [String: JSONValue] = ["type": .string(sourceType)]
        if sourceType == "git" {
            source["url"] = .string(value)
            if !subdir.isEmpty { source["subdir"] = .string(subdir) }
            if !ref.isEmpty { source["ref"] = .string(ref) }
        } else {
            source["path"] = .string(value)
            if !subdir.isEmpty { source["subdir"] = .string(subdir) }
        }
        do {
            _ = try await connection.installAdaptorSkill(source: .object(source), replace: replace)
            sourceValue = ""
            subdir = ""
            ref = ""
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }

    private func delete(_ skill: RACPV2Skill) async {
        do {
            try await connection.deleteAdaptorSkill(id: skill.id)
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }
}
