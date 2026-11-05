import SwiftUI
import PIiOSCore

/// Result of a provider deletion, forwarded to the presenting screen so a
/// partial outcome (secret kept, default model not moved) is shown after the
/// sheet closes instead of being replaced by a generic "已删除" banner.
enum ProviderDeletionNotice: Equatable {
    case success(String)
    case needsAttention(String)
}

struct ModelProviderDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let provider: StoredModelProvider
    let host: HostRecord
    let onDeleted: (ProviderDeletionNotice) -> Void

    @State private var isDeleting = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var editName = ""
    @State private var editBaseURL = ""
    @State private var editAPIKey = ""
    @State private var editModels: [ProviderModelEditDraft] = []
    @State private var editError: String?

    private var canUpdate: Bool {
        provider.hostV2Mirror != false && connection.state.isOnline
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    if isEditing {
                        editingForm
                    } else {
                        PICard {
                            Text(provider.name)
                                .font(PIFont.display)
                                .foregroundStyle(PIColor.text)
                            Text(provider.baseURL)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(provider.models.count) 个模型 · 本机记录")
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text3)
                        }

                        PIGroup("模型") {
                            ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, item in
                                VStack(alignment: .leading, spacing: PISpacing.s4) {
                                    HStack {
                                        Text(item.displayName)
                                            .font(PIFont.listTitle)
                                            .foregroundStyle(PIColor.text)
                                        Spacer()
                                        if provider.defaultModelId == item.id {
                                            Text("默认")
                                                .font(PIFont.metaSmall)
                                                .foregroundStyle(PIColor.accent)
                                        }
                                    }
                                    Text(item.id)
                                        .font(PIFont.codeMono)
                                        .foregroundStyle(PIColor.text2)
                                    Text(
                                        "\(compact(item.contextWindow)) ctx"
                                            + " · \(compact(item.maxTokens)) output"
                                            + (item.thinkingLevels.isEmpty
                                                ? " · 无思考档位"
                                                : " · \(item.thinkingLevels.joined(separator: "/"))")
                                    )
                                    .font(PIFont.metaSmall)
                                    .foregroundStyle(PIColor.text3)
                                }
                                .padding(.horizontal, PISpacing.s16)
                                .padding(.vertical, PISpacing.s12)
                                if index < provider.models.count - 1 { PIRowDivider() }
                            }
                        }

                        PIGroup("更新模型", footer: "编辑服务信息与完整模型列表，密钥留空保持不变。") {
                            PISecondaryButton(
                                title: "编辑模型",
                                isEnabled: canUpdate && !isDeleting
                            ) { startEditing() }
                            .accessibilityIdentifier("models.provider.edit")
                            .padding(.horizontal, PISpacing.s16)
                            .padding(.vertical, PISpacing.s12)
                        }
                        if provider.hostV2Mirror == false {
                            Text("这条旧版服务没有可原位更新的 PI-adaptor v2 镜像；不会用删除重建替代更新。")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !connection.state.isOnline {
                            Text("连接服务器后可更新模型。")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text3)
                        }

                        PIGroup(
                            "删除模型服务",
                            footer: "删除会移除服务器上的 provider 记录与密钥。正在运行的 turn 可能失败且不会被自动迁移；建议先中止运行中的轮次。"
                        ) {
                            PIDangerRow(
                                title: isDeleting ? "正在删除…" : "删除这条服务",
                                isEnabled: connection.state.isOnline && !isDeleting,
                                disabledReason: connection.state.isOnline ? nil : "服务器离线，无法确认删除结果",
                                action: { showingDeleteConfirm = true }
                            )
                        }
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar(isEditing ? "编辑模型服务" : "模型服务详情")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("取消") { isEditing = false }
                            .disabled(isSaving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button(isSaving ? "保存中…" : "保存") { saveEdit() }
                            .disabled(isSaving || editModels.isEmpty)
                            .accessibilityIdentifier("models.provider.save")
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .alert("删除「\(provider.name)」？", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    Task { await deleteProvider() }
                }
            } message: {
                Text("将从服务器删除该 provider 及其密钥，并清理本机记录。项目、文件和设备配对不受影响。")
            }
            .piMessageAlert(title: "删除未完成", message: $errorMessage)
            .piMessageAlert(title: "模型服务未更新", message: $editError)
            .piMessageAlert(title: "模型服务已更新", message: $resultMessage)
        }
    }

    private var editingForm: some View {
        Group {
            PIGroup("服务信息", footer: "API Key 留空保留服务器上的原密钥，不会写入本机记录。") {
                VStack(alignment: .leading, spacing: PISpacing.s16) {
                    PIFormField(label: "服务名称") {
                        TextField("服务名称", text: $editName)
                            .accessibilityIdentifier("models.provider.editName")
                    }
                    PIFormField(label: "Base URL") {
                        TextField("https://models.example/v1", text: $editBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("models.provider.editBaseURL")
                    }
                    PIFormField(label: "新 API Key", hint: "可选；留空保持不变") {
                        SecureField("新 API Key", text: $editAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("models.provider.editAPIKey")
                    }
                }
                .padding(PISpacing.s16)
            }

            PIGroup(
                "模型列表",
                footer: "思考档位用逗号分隔；默认思考档位必须包含在档位中。删除默认模型后将选择剩余第一项。"
            ) {
                ForEach(editModels) { draft in
                    ProviderModelEditRow(
                        draft: editDraftBinding(for: draft),
                        canRemove: editModels.count > 1
                    ) {
                        editModels.removeAll { $0.id == draft.id }
                    }
                    PIRowDivider()
                }
                PISecondaryButton(title: "添加模型") {
                    editModels.append(ProviderModelEditDraft(spec: ProviderModelSpec(
                        id: "", contextWindow: 128_000, maxTokens: 16_384,
                        thinkingLevels: []
                    )))
                }
                .accessibilityIdentifier("models.provider.addModel")
                .padding(PISpacing.s16)
            }

            PIPrimaryButton(title: isSaving ? "正在保存…" : "保存模型更新") {
                saveEdit()
            }
            .disabled(isSaving || editModels.isEmpty)
        }
    }

    private func startEditing() {
        editName = provider.name
        editBaseURL = provider.baseURL
        editAPIKey = ""
        editModels = provider.models.map { item in
            var draft = ProviderModelEditDraft(spec: item.providerSpec)
            draft.compose()
            return draft
        }
        editError = nil
        isEditing = true
    }

    private func editDraftBinding(for draft: ProviderModelEditDraft) -> Binding<ProviderModelEditDraft> {
        Binding(
            get: {
                // `ForEach($editModels)` captures an array index in its binding.
                // Removing a row while a Toggle/TextField is still rendering can then
                // read the old index and trap inside Array.subscript. Resolve the
                // stable row ID instead, so a delayed UIKit read cannot go out of bounds.
                editModels.first { $0.id == draft.id } ?? draft
            },
            set: { updated in
                guard let index = editModels.firstIndex(where: { $0.id == draft.id }) else { return }
                editModels[index] = updated
            }
        )
    }

    private func saveEdit() {
        guard provider.hostID == host.id, provider.hostV2Mirror != false,
              let operation = model.providerOperationContext(for: host) else {
            editError = "当前 PI-adaptor 不支持更新或已切换，请在原 PI-adaptor 上重试。"
            return
        }
        // 兼容尚未写入镜像标记的旧 v2 记录：只有 PI-adaptor 确认其存在时才允许更新。
        let requiresV2Confirmation = provider.hostV2Mirror != true
        let input = ProviderUpdateInput(
            name: editName,
            baseURL: editBaseURL,
            apiKey: editAPIKey.isEmpty ? nil : editAPIKey,
            models: editModels.map(\.spec),
            defaultModelID: provider.defaultModelId
        )
        isSaving = true
        editError = nil
        Task {
            defer { isSaving = false }
            do {
                if requiresV2Confirmation {
                    let providers = try await connection.listAdaptorProviders()
                    guard providers.contains(where: { $0.id == provider.providerId }) else {
                        editError = "服务器未确认这条旧记录的 v2 镜像；为避免误更新，本机记录未改动。"
                        return
                    }
                    guard model.canApplyProviderOperation(operation) else {
                        editError = "PI-adaptor 在保存过程中已切换：本次修改未提交，请到原 PI-adaptor 上重试。"
                        return
                    }
                }
                let updated = try await connection.updateAdaptorProvider(id: provider.providerId, input: input)
                guard model.canApplyProviderOperation(operation) else {
                    editError = "PI-adaptor 在保存过程中已切换：本次修改可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
                    return
                }
                let createInput = ProviderCreateInput(
                    name: updated.name,
                    vendorKey: updated.vendorKey,
                    type: updated.type,
                    protocol: updated.protocolName,
                    authKind: updated.authKind,
                    baseUrl: updated.baseUrl,
                    models: updated.models.map { wire in
                        var spec = ProviderUpdateComposer.modelSpec(wire)
                        let previous = provider.models.first { $0.id == wire.id }?.providerSpec
                        spec.contextWindowSource = previous?.contextWindowSource
                        spec.maxTokensSource = previous?.maxTokensSource
                        spec.thinkingProtocol = previous?.thinkingProtocol
                        spec.supportsReasoningEffort = previous?.supportsReasoningEffort
                        spec.supportsDocuments = previous?.supportsDocuments
                        spec.availableForSubagents = previous?.availableForSubagents
                        spec.nativeWebSearch = previous?.nativeWebSearch
                        return spec
                    },
                    defaultModelId: ProviderUpdateComposer.resolvedDefaultModelID(
                        previous: provider.defaultModelId, models: updated.models.map { ProviderUpdateComposer.modelSpec($0) }
                    )
                )
                guard model.recordImportedProvider(
                    context: operation,
                    input: createInput,
                    providerId: updated.id,
                    serverDefaultSet: false,
                    legacyProviderId: provider.legacyProviderId,
                    hostV2Mirror: true
                ) else {
                    editError = "服务器已更新，但本机记录保存失败。请保留此页提示并稍后重新打开详情核对。"
                    return
                }
                if !editAPIKey.isEmpty {
                    _ = KeychainStore.saveProviderKey(
                        editAPIKey, hostID: host.id, providerId: provider.providerId
                    )
                }
                editAPIKey = ""
                isEditing = false
                resultMessage = provider.legacyProviderId == nil
                    ? "已更新 \(updated.models.count) 个模型。"
                    : "PI-adaptor v2 镜像已更新；关联的旧版服务未改动。"
            } catch {
                editError = ConnectionErrorText.describe(error)
            }
        }
    }
    private func deleteProvider() async {
        guard provider.hostID == host.id,
              let operation = model.providerOperationContext(for: host) else { return }
        isDeleting = true
        errorMessage = nil
        resultMessage = nil
        defer { isDeleting = false }
        do {
            guard model.canApplyProviderOperation(operation) else { return }
            var summaryText: String?
            // Set when the server reported an outcome the user must act on, so the
            // parent screen can surface it as a warning rather than a plain success.
            var needsAttention = false
            // 服务端已经查不到这条 provider：删除是幂等的，继续清本机记录并关掉详情页，
            // 不能停在这里报「删除未完成」（NOT_FOUND 不是失败）。
            var serverAlreadyAbsent = false
            // 1) Drop the v2 PI-adaptor mirror, if this record has one. Records written
            //    before `hostV2Mirror` existed have `nil`; probe the PI-adaptor in that
            //    case so an old legacy record (whose id the PI-adaptor does not know) is
            //    not misread as a mirror and its real legacy entry is still cleaned.
            var v2Removed = false
            if provider.hostV2Mirror ?? true {
                guard connection.state.isOnline else {
                    errorMessage = "服务器离线：无法确认删除 v2 PI-adaptor 上的 provider 镜像，本机记录已保留。请连接后重试。"
                    return
                }
                do {
                    try await connection.deleteAdaptorProvider(id: provider.providerId)
                    v2Removed = true
                } catch let error as RACPV2Error {
                    if case .server(let code, _) = error, code == "NOT_FOUND" {
                        // The record may be legacy-only, or already removed elsewhere.
                        serverAlreadyAbsent = true
                    } else {
                        errorMessage = ConnectionErrorText.describe(error)
                        return
                    }
                } catch {
                    errorMessage = ConnectionErrorText.describe(error)
                    return
                }
                guard model.canApplyProviderOperation(operation) else { return }
            }
            // 2) Drop the legacy SSH store entry when one exists (or is implied).
            var legacyId: String? = provider.legacyProviderId
            if legacyId == nil, provider.hostV2Mirror != true, !v2Removed {
                legacyId = provider.providerId
            }
            if let legacyProviderId = legacyId {
                let receipt = try await connection.removeProvider(
                    record: host,
                    providerId: legacyProviderId
                )
                guard model.canApplyProviderOperation(operation) else { return }
                switch receipt {
                case .success(let summary):
                    summaryText = deleteSummaryText(summary)
                case .defaultTransferOrderUnknown(_, let secretCleared):
                    // 契约 §4.2/§8 的四键例外：已删记录，但默认项因 createdAt 不可比未转移。
                    // 需要人工跟进，必须作为警告展示而不是通用「已删除」。
                    needsAttention = true
                    summaryText = secretCleared
                        ? "服务器已删除记录与密钥，但默认模型因创建时间不可比未转移，请重新选择默认模型。"
                        : "服务器已删除记录，但密钥未清除且默认模型未转移，请人工在服务器上处理。"
                case .failure(.notFound):
                    // 服务端已无此记录：等同 `.absent`，继续清本机记录。
                    serverAlreadyAbsent = true
                case .failure(let failure):
                    errorMessage = failure.displayMessage
                    return
                case .unparseable(let reason):
                    errorMessage = "服务器回执无法解析：\(reason)。本机记录已保留。"
                    return
                }
            }
            guard model.removeLocalProvider(id: provider.id, context: operation) else { return }
            // Drop any locally stored key(s) for this provider — both the v2 id
            // and, when the record was mirrored from a legacy import, the legacy id.
            _ = KeychainStore.deleteProviderKey(hostID: provider.hostID, providerId: provider.providerId)
            if let legacyProviderId = provider.legacyProviderId, legacyProviderId != provider.providerId {
                _ = KeychainStore.deleteProviderKey(hostID: provider.hostID, providerId: legacyProviderId)
            }
            let detail = summaryText
                ?? (v2Removed
                    ? "已从 v2 PI-adaptor 删除该 provider 及其密钥。"
                    : (serverAlreadyAbsent
                        ? "服务器上已不存在该记录；本机残留记录已清理。"
                        : "已清理本机记录。"))
            resultMessage = detail
            // Hand the outcome to the parent: it owns the post-dismiss alert, so a
            // partial result cannot be hidden behind a generic success message.
            onDeleted(
                needsAttention
                    ? .needsAttention("已删除模型服务「\(provider.name)」：\(detail)")
                    : .success("已删除模型服务「\(provider.name)」")
            )
        } catch {
            guard model.canApplyProviderOperation(operation) else { return }
            errorMessage = ConnectionErrorText.describe(error)
        }
    }
private struct ProviderModelEditDraft: Identifiable, Equatable {
    let id = UUID()
    var spec: ProviderModelSpec
    var modelID: String
    var displayName: String
    var contextWindow: String
    var maxTokens: String
    var thinkingLevels: String
    var defaultThinkingLevel: String
    var supportsImages: Bool

    init(spec: ProviderModelSpec) {
        self.spec = spec
        modelID = spec.id
        displayName = spec.alias ?? spec.id
        contextWindow = String(spec.contextWindow)
        maxTokens = String(spec.maxTokens)
        thinkingLevels = spec.thinkingLevels.joined(separator: ", ")
        defaultThinkingLevel = spec.defaultThinkingLevel ?? ""
        supportsImages = spec.supportsImages ?? false
    }

    mutating func compose() {
        spec = ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
            base: spec,
            modelId: modelID,
            displayName: displayName,
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            thinkingLevels: thinkingLevels,
            defaultThinkingLevel: defaultThinkingLevel
        ))
        spec.supportsImages = supportsImages
    }
}

private struct ProviderModelEditRow: View {
    @Binding var draft: ProviderModelEditDraft
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            HStack {
                Text("模型参数")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                Spacer()
                if canRemove {
                    Button("移除模型", role: .destructive, action: remove)
                        .font(PIFont.caption)
                }
            }
            PIFormField(label: "模型 ID") {
                TextField("model/example", text: $draft.modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("models.provider.modelID")
            }
            PIFormField(label: "显示名") {
                TextField("模型显示名", text: $draft.displayName)
            }
            HStack(spacing: PISpacing.s12) {
                PIFormField(label: "上下文") {
                    TextField("128000", text: $draft.contextWindow)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("models.provider.contextWindow")
                }
                PIFormField(label: "输出上限") {
                    TextField("16384", text: $draft.maxTokens)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("models.provider.maxTokens")
                }
            }
            PIFormField(label: "思考档位", hint: "例如 off, low, high") {
                TextField("off, low, high", text: $draft.thinkingLevels)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("models.provider.thinkingLevels")
            }
            PIFormField(label: "默认思考档位", hint: "留空表示不指定") {
                TextField("low", text: $draft.defaultThinkingLevel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("支持图片输入", isOn: $draft.supportsImages)
                .font(PIFont.body)
                .tint(PIColor.accent)
        }
        .padding(PISpacing.s16)
        .onChange(of: draft.modelID) { _, _ in draft.compose() }
        .onChange(of: draft.displayName) { _, _ in draft.compose() }
        .onChange(of: draft.contextWindow) { _, _ in draft.compose() }
        .onChange(of: draft.maxTokens) { _, _ in draft.compose() }
        .onChange(of: draft.thinkingLevels) { _, _ in draft.compose() }
        .onChange(of: draft.defaultThinkingLevel) { _, _ in draft.compose() }
        .onChange(of: draft.supportsImages) { _, _ in draft.compose() }
    }
}

    private func deleteSummaryText(_ summary: ProviderRemoveSummary) -> String {
        guard summary.effect == .deleted else {
            return "服务器上已不存在该记录；本机残留记录已清理，本次没有再次执行删除。"
        }
        var parts = ["服务器已删除记录与密钥。"]
        switch summary.defaultMoved {
        case .moved(let providerId, let modelId):
            parts.append("默认模型已转给 \(providerId.prefix(8))… / \(modelId)。")
        case .notMoved(let reason):
            parts.append(reason == "no_remaining"
                ? "已无剩余模型服务，请重新添加。"
                : "没有合格的候选模型，默认模型未转移，请重新选择。")
        case nil:
            break
        }
        if summary.remainingEligible == 0 {
            parts.append("当前已无可用模型服务。")
        }
        return parts.joined(separator: " ")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }
}
