import SwiftUI
import PIiOSCore

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
    @State private var keyWarning: String?

    private var canUpdate: Bool {
        provider.hostV2Mirror != false && connection.state.isOnline
    }

    /// 本机 Keychain 是否还留有这条服务（或它的 legacy 映射）的密钥。
    private var hasLocalProviderKey: Bool {
        if KeychainStore.loadProviderKey(hostID: provider.hostID, providerId: provider.providerId) != nil {
            return true
        }
        guard let legacyProviderId = provider.legacyProviderId,
              legacyProviderId != provider.providerId
        else { return false }
        return KeychainStore.loadProviderKey(hostID: provider.hostID, providerId: legacyProviderId) != nil
    }

    /// v0.0.3 起服务器不保存 api_key 类服务的密钥；这里只反映本机 Keychain。
    private var keyStatusText: String {
        ProviderSecretDisplay.localText(hasLocalKey: hasLocalProviderKey)
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
                            Text(keyStatusText)
                                .font(PIFont.meta)
                                .foregroundStyle(hasLocalProviderKey ? PIColor.text3 : PIColor.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("models.provider.keyStatus")
                        }
                        if let guidance = ProviderSecretDisplay.missingKeyGuidance(
                            .localOnly(hasLocalKey: hasLocalProviderKey)
                        ) {
                            PIInlineMessage(kind: .warning, text: guidance)
                        }
                        if let keyWarning {
                            PIInlineMessage(kind: .warning, text: keyWarning)
                                .accessibilityIdentifier("models.provider.keyWarning")
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

                        PIGroup("更新模型", footer: "编辑服务信息与完整模型列表。API Key 只保存在本机 Keychain，留空保持不变。") {
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
                            footer: "删除会移除服务器上的 provider 记录，并清除本机保存的密钥。正在运行的 turn 可能失败且不会被自动迁移；建议先中止运行中的轮次。"
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
                Text("将从服务器删除该 provider 记录，并清除本机 Keychain 中的密钥。项目、文件和设备配对不受影响。")
            }
            .piMessageAlert(title: "删除未完成", message: $errorMessage)
            .piMessageAlert(title: "模型服务未更新", message: $editError)
            .piMessageAlert(title: "模型服务已更新", message: $resultMessage)
        }
    }

    private var editingForm: some View {
        Group {
            PIGroup("服务信息", footer: "新 API Key 只写入本机 Keychain；留空保持不变。") {
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
        // U14：保存期间禁止继续编辑密钥与相关字段，避免请求值与本机写入分叉，
        // 也避免保存完成后把「还未提交的修改」无声丢弃。
        .disabled(isSaving)
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
        guard !isSaving else { return }
        // 兼容尚未写入镜像标记的旧 v2 记录：只有 PI-adaptor 确认其存在时才允许更新。
        let requiresV2Confirmation = provider.hostV2Mirror != true
        // U14：请求前冻结提交值。请求与本机 Keychain 写入都只读这份快照，
        // 不再在回执后回读界面上的实时输入。
        let intent = ProviderSaveIntent(
            kind: .update(providerId: provider.providerId),
            hostID: host.id,
            name: editName,
            baseURL: editBaseURL,
            models: editModels.map(\.spec),
            apiKey: editAPIKey,
            apiKeyDraft: editAPIKey,
            legacyProviderId: provider.legacyProviderId,
            hostV2Mirror: provider.hostV2Mirror,
            defaultModelID: provider.defaultModelId
        )
        isSaving = true
        editError = nil
        keyWarning = nil
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
                let updated = try await connection.updateAdaptorProvider(
                    id: provider.providerId,
                    input: intent.updateInput()
                )
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
                // Keychain 写入同样只用冻结值（服务器实际收到的那份密钥），
                // 并按提交时的 Host 记录；写入失败必须可见，不能静默丢弃。
                if let key = intent.keychainAPIKey {
                    if !KeychainStore.saveProviderKey(
                        key,
                        hostID: intent.hostID,
                        providerId: provider.providerId
                    ) {
                        keyWarning = "服务器已更新，但本机密钥保存失败：发送时服务器会拒绝，请在“模型服务”里重新填写 API Key。"
                    }
                }
                // 只有输入框仍是本次提交的值时才清空；否则保留用户后输入的内容。
                if intent.apiKeyDraftIsUnchanged(editAPIKey) {
                    editAPIKey = ""
                } else {
                    keyWarning = "保存期间 API Key 输入有变化：本次未提交后输入的内容，请核对后再保存一次。"
                }
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
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        resultMessage = nil
        defer { isDeleting = false }
        // U07：与 PI-adaptor Provider 页共用同一套删除分支与文案。
        let target = ProviderDeletionTarget(
            host: host,
            providerId: provider.providerId,
            legacyProviderId: provider.legacyProviderId,
            hostV2Mirror: provider.hostV2Mirror,
            localRecordId: provider.id,
            displayName: provider.name,
            keychainProviderIds: [provider.providerId, provider.legacyProviderId].compactMap { $0 }
        )
        let report = await ProviderDeletionUseCase(model: model, connection: connection)
            .delete(target)
        guard model.canApplyProviderOperation(operation) else { return }
        if let failure = report.failureMessage {
            // 失败/结果不确定：本机映射与 Keychain 线索已由用例保留，详情页留在原地。
            errorMessage = failure
            return
        }
        resultMessage = report.message
        // Hand the outcome to the parent: it owns the post-dismiss alert, so a
        // partial result cannot be hidden behind a generic success message.
        onDeleted(report.notice ?? .success(report.message))
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

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }
}
