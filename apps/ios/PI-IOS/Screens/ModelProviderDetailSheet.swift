import SwiftUI
import PIiOSCore

/// 已配置模型服务的详情页。
///
/// 更新以「单个模型」为粒度：每个模型可以单独编辑，也可以设为当前模型；
/// 服务信息（名称 / Base URL / API Key）单独编辑；模型清单可以随时从
/// 服务端 `/models` 重新获取并合并。
struct ModelProviderDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let provider: StoredModelProvider
    let host: HostRecord
    let onDeleted: (ProviderDeletionNotice) -> Void

    @State private var snapshot: StoredModelProvider
    @State private var isDeleting = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isSaving = false
    @State private var keyWarning: String?
    @State private var showingServiceEditor = false
    @State private var editingModel: ModelEditTarget?
    @State private var refetchPresentation: RefetchPresentation?
    @State private var statusMessage: String?

    init(
        provider: StoredModelProvider,
        host: HostRecord,
        onDeleted: @escaping (ProviderDeletionNotice) -> Void
    ) {
        self.provider = provider
        self.host = host
        self.onDeleted = onDeleted
        _snapshot = State(initialValue: provider)
    }

    private var canUpdate: Bool {
        snapshot.hostV2Mirror != false && connection.state.isOnline
    }

    /// 本机 Keychain 是否还留有这条服务（或它的 legacy 映射）的密钥。
    private var hasLocalProviderKey: Bool {
        if KeychainStore.loadProviderKey(hostID: snapshot.hostID, providerId: snapshot.providerId) != nil {
            return true
        }
        guard let legacyProviderId = snapshot.legacyProviderId,
              legacyProviderId != snapshot.providerId
        else { return false }
        return KeychainStore.loadProviderKey(hostID: snapshot.hostID, providerId: legacyProviderId) != nil
    }

    /// v0.0.3 起服务器不保存 api_key 类服务的密钥；这里只反映本机 Keychain。
    private var keyStatusText: String {
        ProviderSecretDisplay.localText(hasLocalKey: hasLocalProviderKey)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    PICard {
                        Text(snapshot.name)
                            .font(PIFont.display)
                            .foregroundStyle(PIColor.text)
                        Text(snapshot.baseURL)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(snapshot.models.count) 个模型 · 本机记录")
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
                    if isSaving {
                        PIStatusBanner(kind: .info, text: "正在保存模型更新")
                    }
                    if let statusMessage {
                        PIInlineMessage(kind: .success, text: statusMessage)
                            .accessibilityIdentifier("models.provider.status")
                    }

                    PIGroup(
                        "模型",
                        footer: "点「编辑」只改这一个模型；点「设为模型」把它设为该服务的默认模型。"
                    ) {
                        ForEach(Array(snapshot.models.enumerated()), id: \.element.id) { index, item in
                            modelRow(item, isDefault: snapshot.defaultModelId == item.id)
                            if index < snapshot.models.count - 1 { PIRowDivider() }
                        }
                    }

                    PIGroup(
                        "更新模型",
                        footer: "重新获取会调用服务端 `/models`，把新模型合并进清单；已有模型的参数保持不变。"
                    ) {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            PISecondaryButton(
                                title: isSaving ? "正在更新…" : "重新获取模型",
                                isEnabled: canUpdate && !isDeleting && !isSaving
                            ) {
                                Task { await refetchModels() }
                            }
                            .accessibilityIdentifier("models.provider.refetch")
                            PISecondaryButton(
                                title: "编辑服务信息",
                                isEnabled: canUpdate && !isDeleting && !isSaving
                            ) {
                                showingServiceEditor = true
                            }
                            .accessibilityIdentifier("models.provider.editService")
                        }
                        .padding(.horizontal, PISpacing.s16)
                        .padding(.vertical, PISpacing.s12)
                    }
                    if snapshot.hostV2Mirror == false {
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
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("模型服务详情")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingServiceEditor) {
                ProviderServiceEditSheet(
                    name: snapshot.name,
                    baseURL: snapshot.baseURL,
                    hasStoredKey: hasLocalProviderKey
                ) { name, baseURL, apiKey in
                    await persist(
                        models: snapshot.models.map(\.providerSpec),
                        defaultModelID: snapshot.defaultModelId,
                        name: name,
                        baseURL: baseURL,
                        apiKey: apiKey
                    )
                }
            }
            .sheet(item: $editingModel) { target in
                ProviderModelEditSheet(
                    spec: target.binding.providerSpec,
                    isDefault: snapshot.defaultModelId == target.binding.id
                ) { spec, makeDefault in
                    await saveSingleModel(spec, replacing: target.binding.id, makeDefault: makeDefault)
                }
            }
            .sheet(item: $refetchPresentation) { presentation in
                RefetchModelsSheet(
                    providerName: snapshot.name,
                    candidates: presentation.candidates
                ) { selected in
                    await persist(
                        models: selected,
                        defaultModelID: snapshot.defaultModelId,
                        name: snapshot.name,
                        baseURL: snapshot.baseURL,
                        apiKey: nil
                    )
                }
            }
            .alert("删除「\(snapshot.name)」？", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    Task { await deleteProvider() }
                }
            } message: {
                Text("将从服务器删除该 provider 记录，并清除本机 Keychain 中的密钥。项目、文件和设备配对不受影响。")
            }
            .piMessageAlert(title: "删除未完成", message: $errorMessage)
            .piMessageAlert(title: "模型服务已更新", message: $resultMessage)
        }
    }

    private func modelRow(_ item: StoredModelBinding, isDefault: Bool) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayName)
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Spacer()
                if isDefault {
                    Text("当前")
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
                        : " · 思考 \(item.thinkingLevels.joined(separator: "/"))")
                    + (item.defaultThinkingLevel.map { " · 默认 \($0)" } ?? "")
            )
            .font(PIFont.metaSmall)
            .foregroundStyle(PIColor.text3)
            HStack(spacing: PISpacing.s8) {
                if !isDefault {
                    Button("设为模型") {
                        Task { await setDefaultModel(item.id) }
                    }
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.accent)
                    .accessibilityIdentifier("models.provider.setDefault.\(item.id)")
                    .disabled(!canUpdate || isSaving)
                }
                Button("编辑") {
                    editingModel = ModelEditTarget(binding: item)
                }
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
                .accessibilityIdentifier("models.provider.editModel.\(item.id)")
                .disabled(!canUpdate || isSaving)
                Spacer()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
    }

    // MARK: - 更新

    private func saveSingleModel(
        _ spec: ProviderModelSpec,
        replacing originalID: String,
        makeDefault: Bool
    ) async -> String? {
        var models = snapshot.models.map(\.providerSpec)
        guard let index = models.firstIndex(where: { $0.id == originalID }) else {
            return "要编辑的模型已不在清单中，请重新打开详情页。"
        }
        // 保留本机记录里的扩展能力，只覆盖可编辑字段。
        var merged = models[index]
        merged.contextWindow = spec.contextWindow
        merged.maxTokens = spec.maxTokens
        merged.thinkingLevels = spec.thinkingLevels
        merged.defaultThinkingLevel = mergesDefaultLevel(spec, levels: spec.thinkingLevels)
        merged.alias = spec.alias
        merged.supportsImages = spec.supportsImages
        models[index] = merged
        let defaultID = (makeDefault ? merged.id : snapshot.defaultModelId) ?? merged.id
        return await persist(
            models: models,
            defaultModelID: defaultID,
            name: snapshot.name,
            baseURL: snapshot.baseURL,
            apiKey: nil
        )
    }

    private func mergesDefaultLevel(
        _ spec: ProviderModelSpec,
        levels: [String]
    ) -> String? {
        guard let level = spec.defaultThinkingLevel, levels.contains(level) else { return nil }
        return level
    }

    private func setDefaultModel(_ modelID: String) async {
        guard !isSaving else { return }
        _ = await persist(
            models: snapshot.models.map(\.providerSpec),
            defaultModelID: modelID,
            name: snapshot.name,
            baseURL: snapshot.baseURL,
            apiKey: nil
        )
    }

    /// 本机记录里两种写法并存：导入时写入的是 legacy `apiStyle`
    /// （`chat_completions` 等），详情页保存后写入的是线路协议 id。
    /// 重新获取模型需要后者，统一在这里折算。
    private var wireProtocol: String {
        switch snapshot.apiStyle {
        case "openai-responses", "responses": return "openai-responses"
        case "anthropic-messages", "anthropic_messages": return "anthropic-messages"
        case "google-generative-ai", "google_generative_ai": return "google-generative-ai"
        default: return "openai-completions"
        }
    }

    private func refetchModels() async {
        guard canUpdate, !isSaving else { return }
        guard let operation = model.providerOperationContext(for: host) else {
            errorMessage = "当前 PI-adaptor 不支持更新或已切换，请在原 PI-adaptor 上重试。"
            return
        }
        let apiKey: String
        if snapshot.hostV2Mirror == false {
            errorMessage = "这条旧版服务没有 PI-adaptor v2 镜像，无法重新获取模型。"
            return
        }
        if hasLocalProviderKey {
            guard let key = KeychainStore.loadProviderKey(
                hostID: snapshot.hostID,
                providerId: snapshot.providerId
            ) ?? snapshot.legacyProviderId.flatMap({ legacyID in
                KeychainStore.loadProviderKey(hostID: snapshot.hostID, providerId: legacyID)
            }) else {
                errorMessage = "本机密钥读取失败，请先编辑服务信息重新填写 API Key。"
                return
            }
            apiKey = key
        } else {
            errorMessage = "本机没有保存这条服务的 API Key，请先「编辑服务信息」填写后再重新获取。"
            return
        }
        isSaving = true
        statusMessage = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            let discovered = try await connection.discoverModels(
                record: host,
                baseURL: snapshot.baseURL,
                apiKey: apiKey,
                protocol: wireProtocol
            )
            let normalized = discovered.map { item -> DiscoveredModel in
                var copy = item
                copy.modelId = ECMAScriptString.trim(copy.modelId)
                return copy
            }
            let resolved = ModelConfigurationResolver.resolve(normalized)
            guard model.canApplyProviderOperation(operation) else {
                errorMessage = "PI-adaptor 在获取过程中已切换，请重试。"
                return
            }
            let existing = Dictionary(uniqueKeysWithValues: snapshot.models.map { ($0.id, $0) })
            var seen = Set<String>()
            var candidates: [RefetchCandidate] = snapshot.models.map { item in
                RefetchCandidate(spec: item.providerSpec, isNew: false, isSelected: true)
            }
            for candidate in resolved {
                let id = candidate.spec.id
                guard !id.isEmpty, !seen.contains(id), existing[id] == nil else { continue }
                seen.insert(id)
                candidates.append(
                    RefetchCandidate(spec: candidate.spec, isNew: true, isSelected: true)
                )
            }
            refetchPresentation = RefetchPresentation(candidates: candidates)
            statusMessage = "已获取 \(resolved.count) 个模型"
        } catch {
            errorMessage = ConnectionErrorText.describe(error)
        }
    }

    /// 统一的更新路径：冻结提交值，更新服务器后再写本机记录与 Keychain。
    private func persist(
        models: [ProviderModelSpec],
        defaultModelID: String?,
        name: String,
        baseURL: String,
        apiKey: String?
    ) async -> String? {
        guard snapshot.hostID == host.id,
              snapshot.hostV2Mirror != false,
              let operation = model.providerOperationContext(for: host) else {
            return "当前 PI-adaptor 不支持更新或已切换，请在原 PI-adaptor 上重试。"
        }
        guard !isSaving else { return "正在保存，请稍候。" }
        let requiresV2Confirmation = snapshot.hostV2Mirror != true
        let intent = ProviderSaveIntent(
            kind: .update(providerId: snapshot.providerId),
            hostID: host.id,
            name: name,
            baseURL: baseURL,
            models: models,
            apiKey: apiKey ?? "",
            apiKeyDraft: apiKey ?? "",
            legacyProviderId: snapshot.legacyProviderId,
            hostV2Mirror: snapshot.hostV2Mirror,
            defaultModelID: defaultModelID
        )
        isSaving = true
        errorMessage = nil
        keyWarning = nil
        defer { isSaving = false }
        do {
            if requiresV2Confirmation {
                let providers = try await connection.listAdaptorProviders()
                guard providers.contains(where: { $0.id == snapshot.providerId }) else {
                    return "服务器未确认这条旧记录的 v2 镜像；为避免误更新，本机记录未改动。"
                }
                guard model.canApplyProviderOperation(operation) else {
                    return "PI-adaptor 在保存过程中已切换：本次修改未提交，请到原 PI-adaptor 上重试。"
                }
            }
            let updated = try await connection.updateAdaptorProvider(
                id: snapshot.providerId,
                input: intent.updateInput()
            )
            guard model.canApplyProviderOperation(operation) else {
                return "PI-adaptor 在保存过程中已切换：本次修改可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
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
                    let previous = snapshot.models.first { $0.id == wire.id }?.providerSpec
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
                    previous: defaultModelID,
                    models: updated.models.map { ProviderUpdateComposer.modelSpec($0) }
                )
            )
            guard model.recordImportedProvider(
                context: operation,
                input: createInput,
                providerId: updated.id,
                serverDefaultSet: false,
                legacyProviderId: snapshot.legacyProviderId,
                hostV2Mirror: true
            ) else {
                return "服务器已更新，但本机记录保存失败。请稍后重新打开详情页核对。"
            }
            if let key = intent.keychainAPIKey {
                if !KeychainStore.saveProviderKey(
                    key,
                    hostID: intent.hostID,
                    providerId: snapshot.providerId
                ) {
                    keyWarning = "服务器已更新，但本机密钥保存失败：发送时服务器会拒绝，请重新填写 API Key。"
                }
            }
            snapshot = StoredModelProvider(
                providerId: updated.id,
                legacyProviderId: snapshot.legacyProviderId,
                hostV2Mirror: true,
                hostID: snapshot.hostID,
                name: updated.name,
                baseURL: updated.baseUrl,
                apiStyle: updated.protocolName,
                models: updated.models.map { wire in
                    StoredModelBinding(spec: ProviderUpdateComposer.modelSpec(wire))
                },
                defaultModelId: createInput.defaultModelId,
                importedAt: snapshot.importedAt
            )
            resultMessage = "已更新 \(updated.models.count) 个模型。"
            return nil
        } catch {
            let message = ConnectionErrorText.describe(error)
            errorMessage = message
            return message
        }
    }

    private func deleteProvider() async {
        guard snapshot.hostID == host.id,
              let operation = model.providerOperationContext(for: host) else { return }
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        resultMessage = nil
        defer { isDeleting = false }
        // U07：与 PI-adaptor Provider 页共用同一套删除分支与文案。
        let target = ProviderDeletionTarget(
            host: host,
            providerId: snapshot.providerId,
            legacyProviderId: snapshot.legacyProviderId,
            hostV2Mirror: snapshot.hostV2Mirror,
            localRecordId: snapshot.id,
            displayName: snapshot.name,
            keychainProviderIds: [snapshot.providerId, snapshot.legacyProviderId].compactMap { $0 }
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

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }
}

// MARK: - 单个模型编辑

private struct ModelEditTarget: Identifiable {
    let binding: StoredModelBinding
    var id: String { binding.id }
}

private struct ProviderServiceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let hasStoredKey: Bool
    let save: (String, String, String?) async -> String?

    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        name: String,
        baseURL: String,
        hasStoredKey: Bool,
        save: @escaping (String, String, String?) async -> String?
    ) {
        self.hasStoredKey = hasStoredKey
        self.save = save
        _name = State(initialValue: name)
        _baseURL = State(initialValue: baseURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s16) {
                    PIGroup("服务信息", footer: "新 API Key 只写入本机 Keychain；留空保持不变。") {
                        VStack(alignment: .leading, spacing: PISpacing.s16) {
                            PIFormField(label: "服务名称") {
                                TextField("服务名称", text: $name)
                                    .accessibilityIdentifier("models.provider.editName")
                            }
                            PIFormField(label: "Base URL") {
                                TextField("http://localhost:8080", text: $baseURL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("models.provider.editBaseURL")
                            }
                            PIFormField(
                                label: "新 API Key",
                                hint: hasStoredKey ? "可选；留空保持不变" : "本机尚未保存密钥，建议现在填写"
                            ) {
                                SecureField("新 API Key", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("models.provider.editAPIKey")
                            }
                        }
                        .padding(PISpacing.s16)
                    }
                    if let errorMessage {
                        PIInlineMessage(kind: .danger, text: errorMessage)
                    }
                    PIPrimaryButton(title: isSaving ? "正在保存…" : "保存服务信息") {
                        Task { await submit() }
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("编辑服务信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        if let error = await save(name, baseURL, apiKey.isEmpty ? nil : apiKey) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

private struct ProviderModelEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isDefault: Bool
    let save: (ProviderModelSpec, Bool) async -> String?

    @State private var modelID: String
    @State private var displayName: String
    @State private var contextWindow: String
    @State private var maxTokens: String
    @State private var thinkingLevels: [String]
    @State private var defaultThinkingLevel: String
    @State private var supportsImages: Bool
    @State private var makeDefault: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        spec: ProviderModelSpec,
        isDefault: Bool,
        save: @escaping (ProviderModelSpec, Bool) async -> String?
    ) {
        self.isDefault = isDefault
        self.save = save
        _modelID = State(initialValue: spec.id)
        _displayName = State(initialValue: spec.alias ?? spec.id)
        _contextWindow = State(initialValue: String(spec.contextWindow))
        _maxTokens = State(initialValue: String(spec.maxTokens))
        _thinkingLevels = State(initialValue: spec.thinkingLevels)
        _defaultThinkingLevel = State(initialValue: spec.defaultThinkingLevel ?? "")
        _supportsImages = State(initialValue: spec.supportsImages ?? false)
        _makeDefault = State(initialValue: isDefault)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s16) {
                    PIGroup("模型参数", footer: "模型 ID 不可修改；如需使用新 ID，请重新获取模型。") {
                        VStack(alignment: .leading, spacing: PISpacing.s16) {
                            PIFormField(label: "模型 ID") {
                                Text(modelID)
                                    .font(PIFont.codeMono)
                                    .foregroundStyle(PIColor.text2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            PIFormField(label: "显示名") {
                                TextField("模型显示名", text: $displayName)
                            }
                            HStack(spacing: PISpacing.s12) {
                                PIFormField(label: "上下文") {
                                    TextField("128000", text: $contextWindow)
                                        .keyboardType(.numberPad)
                                        .accessibilityIdentifier("models.provider.contextWindow")
                                }
                                PIFormField(label: "输出上限") {
                                    TextField("16384", text: $maxTokens)
                                        .keyboardType(.numberPad)
                                        .accessibilityIdentifier("models.provider.maxTokens")
                                }
                            }
                            PIThinkingLevelsPicker(
                                title: "思考档位",
                                selection: $thinkingLevels,
                                identifier: "models.provider.thinkingLevels"
                            )
                            PIThinkingLevelPicker(
                                title: "默认思考档位",
                                selection: $defaultThinkingLevel,
                                options: thinkingLevels,
                                identifier: "models.provider.defaultThinkingLevel"
                            )
                            Toggle("支持图片输入", isOn: $supportsImages)
                                .font(PIFont.body)
                                .tint(PIColor.accent)
                            if !isDefault {
                                Toggle("设为该服务的默认模型", isOn: $makeDefault)
                                    .font(PIFont.body)
                                    .tint(PIColor.accent)
                            }
                        }
                        .padding(PISpacing.s16)
                    }
                    if let errorMessage {
                        PIInlineMessage(kind: .danger, text: errorMessage)
                    }
                    PIPrimaryButton(title: isSaving ? "正在保存…" : "保存这个模型") {
                        Task { await submit() }
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("编辑模型")
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
            .disabled(isSaving)
            .onChange(of: thinkingLevels) { _, levels in
                if !levels.contains(defaultThinkingLevel) { defaultThinkingLevel = "" }
            }
        }
    }

    private func submit() async {
        let spec = ProviderModelSpec(
            id: modelID,
            contextWindow: Int(contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            maxTokens: Int(maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            thinkingLevels: thinkingLevels,
            defaultThinkingLevel: defaultThinkingLevel.isEmpty ? nil : defaultThinkingLevel,
            alias: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsImages: supportsImages
        )
        isSaving = true
        defer { isSaving = false }
        if let error = await save(spec, makeDefault) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

// MARK: - 重新获取模型

private struct RefetchCandidate: Identifiable {
    let spec: ProviderModelSpec
    let isNew: Bool
    var isSelected: Bool
    var id: String { spec.id }
}

private struct RefetchPresentation: Identifiable {
    let id = UUID()
    let candidates: [RefetchCandidate]
}

private struct RefetchModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let providerName: String
    @State private var candidates: [RefetchCandidate]
    let save: ([ProviderModelSpec]) async -> String?

    @State private var filter = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        providerName: String,
        candidates: [RefetchCandidate],
        save: @escaping ([ProviderModelSpec]) async -> String?
    ) {
        self.providerName = providerName
        self.save = save
        _candidates = State(initialValue: candidates)
    }

    private var visible: [RefetchCandidate] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.spec.id.lowercased().contains(query)
                || ($0.spec.alias ?? "").lowercased().contains(query)
        }
    }

    private var selectedSpecs: [ProviderModelSpec] {
        candidates.filter(\.isSelected).map(\.spec)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s16) {
                    Text("从「\(providerName)」的 /models 重新获取。已有模型保持原参数，新模型默认勾选。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("搜索模型 ID 或名称", text: $filter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .piFieldChrome()
                    PIGroup("模型清单（\(candidates.count)）") {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, candidate in
                            Toggle(isOn: binding(for: candidate.id)) {
                                VStack(alignment: .leading, spacing: PISpacing.s4) {
                                    HStack(spacing: PISpacing.s8) {
                                        Text(candidate.spec.alias ?? candidate.spec.id)
                                            .font(PIFont.listTitle)
                                        if candidate.isNew {
                                            Text("新增")
                                                .font(PIFont.metaSmall)
                                                .foregroundStyle(PIColor.accent)
                                                .padding(.horizontal, PISpacing.s8)
                                                .padding(.vertical, 2)
                                                .background(PIColor.accentSoft, in: Capsule())
                                        }
                                    }
                                    Text(candidate.spec.id)
                                        .font(PIFont.codeMono)
                                        .foregroundStyle(PIColor.text2)
                                    Text("\(candidate.spec.contextWindow) ctx · \(candidate.spec.maxTokens) output")
                                        .font(PIFont.metaSmall)
                                        .foregroundStyle(PIColor.text3)
                                }
                            }
                            .tint(PIColor.accent)
                            .padding(.horizontal, PISpacing.s16)
                            .padding(.vertical, PISpacing.s12)
                            if index < visible.count - 1 { PIRowDivider() }
                        }
                    }
                    if let errorMessage {
                        PIInlineMessage(kind: .danger, text: errorMessage)
                    }
                    PIPrimaryButton(title: isSaving ? "正在保存…" : "保存 \(selectedSpecs.count) 个模型") {
                        Task { await submit() }
                    }
                    .disabled(isSaving || selectedSpecs.isEmpty)
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("重新获取模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { candidates.first { $0.id == id }?.isSelected ?? false },
            set: { value in
                guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
                candidates[index].isSelected = value
            }
        )
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        if let error = await save(selectedSpecs) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
