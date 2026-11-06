import SwiftUI
import PIiOSCore

struct AdaptorProvidersScreen: View {
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel

    @State private var providers: [RACPV2Provider] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var warning: String?
    /// 本机 Keychain 里确实存有密钥的 provider id。
    @State private var localKeyProviderIDs: Set<String> = []
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var pendingDelete: RACPV2Provider?
    @State private var editingProvider: RACPV2Provider?
    @State private var editName = ""
    @State private var editBaseURL = ""
    @State private var editApiKey = ""
    @State private var editModelID = ""
    @State private var editError: String?
    @State private var editKeyWarning: String?
    @State private var isCreating = false
    @State private var isSavingEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                if let warning {
                    PIInlineMessage(kind: .warning, text: warning)
                        .accessibilityIdentifier("providers.warning")
                }
                PIGroup(
                    "服务器 provider",
                    footer: "API Key 只保存在本机 Keychain，不写入 PI-adaptor 服务器；换机或重装后需要重新填写。"
                ) {
                    if isLoading {
                        PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                    } else if providers.isEmpty {
                        PIListRow(title: "还没有 provider", isEnabled: false, showsDivider: false)
                    } else {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            PIListRow(
                                title: provider.name,
                                subtitle: "\(provider.baseUrl) · \(provider.models.count) 个模型 · \(secretText(for: provider))",
                                showsDivider: index < providers.count - 1
                            ) {
                                HStack(spacing: PISpacing.s8) {
                                    Button {
                                        startEditing(provider)
                                    } label: {
                                        Text("编辑")
                                            .font(PIFont.captionStrong)
                                            .foregroundStyle(PIColor.accent)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(PIColor.accentSoft, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    Button(role: .destructive) {
                                        pendingDelete = provider
                                    } label: {
                                        Text("删除")
                                            .font(PIFont.captionStrong)
                                            .foregroundStyle(PIColor.danger)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(PIColor.dangerSoft, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("providers.delete.\(provider.name)")
                                }
                            }
                        }
                    }
                }
                PIGroup("新增 provider") {
                    PIFormRow {
                        PIFormField(label: "名称") {
                            TextField("localhost", text: $name)
                                .disabled(isCreating)
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "Base URL") {
                            TextField("https://api.example.com/v1", text: $baseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isCreating)
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "API Key", hint: "只保存在本机 Keychain") {
                            SecureField("sk-…", text: $apiKey)
                                .disabled(isCreating)
                                .accessibilityIdentifier("providers.createAPIKey")
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "模型 ID") {
                            TextField("model-id", text: $modelID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isCreating)
                        }
                    }
                    PIFormRow(showsDivider: false) {
                        PIPrimaryButton(
                            title: isCreating ? "正在保存…" : "保存到 PI-adaptor",
                            isEnabled: !isCreating
                                && connection.state.isOnline
                                && !name.isEmpty
                                && !baseURL.isEmpty
                                && !apiKey.isEmpty
                                && !modelID.isEmpty
                        ) {
                            Task { await create() }
                        }
                    }
                    if !connection.state.isOnline {
                        PIInlineMessage(
                            kind: .warning,
                            text: "PI-adaptor 未连接，连接后可管理 Provider。"
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
        .navigationTitle("PI-adaptor Provider")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.state.isOnline) {
            guard connection.state.isOnline else {
                providers = []
                localKeyProviderIDs = []
                error = nil
                warning = nil
                isLoading = false
                return
            }
            await reload()
        }
        .refreshable { await reload() }
        .onChange(of: model.currentHost?.id) { _ in
            Task { await reload() }
        }
        .confirmationDialog(
            "删除 provider？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let provider = pendingDelete { Task { await delete(provider) } }
            }
            .accessibilityIdentifier("providers.delete.confirm")
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("providers.delete.cancel")
        } message: {
            Text("将从服务器删除该 provider 记录，并清除本机保存的密钥；不会自动把默认项切到其他 provider。")
        }
        .piMessageAlert(title: "Provider 操作失败", message: $error)
        .sheet(item: $editingProvider) { provider in
            NavigationStack {
                Form {
                    Section("Provider 配置") {
                        TextField("名称", text: $editName)
                        TextField("Base URL", text: $editBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("新 API Key（留空保持不变）", text: $editApiKey)
                            .accessibilityIdentifier("providers.editAPIKey")
                        TextField("模型 ID", text: $editModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    // U14：保存期间禁止继续编辑，避免请求值与本机 Keychain 写入分叉。
                    .disabled(isSavingEdit)
                    if let editKeyWarning {
                        Section {
                            PIInlineMessage(kind: .warning, text: editKeyWarning)
                                .accessibilityIdentifier("providers.editKeyWarning")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .piPageBackground()
                .navigationTitle("编辑 Provider")
                .navigationBarTitleDisplayMode(.inline)
                // 保存失败时父页面已被 sheet 覆盖；错误由当前 sheet 独立持有，
                // 关闭提示后再退出编辑不会在父页面重复弹出旧错误。
                .piMessageAlert(title: "Provider 操作失败", message: $editError)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editingProvider = nil }
                            .disabled(isSavingEdit)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSavingEdit ? "保存中…" : "保存") { Task { await saveEdit(id: provider.id) } }
                            .disabled(
                                isSavingEdit
                                    || editName.isEmpty
                                    || editBaseURL.isEmpty
                                    || editModelID.isEmpty
                            )
                    }
                }
            }
        }
    }

    /// v0.0.3 起 `apiKeyMask` 为 null 不再等于「无密钥」；
    /// 由本机 Keychain 决定显示「密钥仅存本机」还是「本机缺少密钥」。
    private func secretText(for provider: RACPV2Provider) -> String {
        ProviderSecretDisplay.text(
            authKind: provider.authKind,
            hasApiKey: provider.hasApiKey,
            apiKeyMask: provider.apiKeyMask,
            keyStorage: provider.keyStorage,
            hasLocalKey: localKeyProviderIDs.contains(provider.id)
        )
    }

    private func startEditing(_ provider: RACPV2Provider) {
        editError = nil
        editKeyWarning = nil
        editName = provider.name
        editBaseURL = provider.baseUrl
        editApiKey = ""
        editModelID = provider.models.first?.id ?? ""
        editingProvider = provider
    }

    private func saveEdit(id: String) async {
        // Bind the request to the PI-adaptor it was started on: the network call goes
        // through the live tunnel, so a switch mid-flight must not be recorded as
        // if it happened on the new PI-adaptor.
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.editError = "当前 PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试。"
            return
        }
        guard !isSavingEdit else { return }
        // U14：冻结提交值；请求与 Keychain 写入都只读这份快照。
        let intent = ProviderSaveIntent(
            kind: .update(providerId: id),
            hostID: host.id,
            name: editName,
            baseURL: editBaseURL,
            models: [ProviderModelSpec(
                id: editModelID,
                contextWindow: 128_000,
                maxTokens: 16_384,
                thinkingLevels: []
            )],
            apiKey: editApiKey,
            apiKeyDraft: editApiKey
        )
        isSavingEdit = true
        editError = nil
        editKeyWarning = nil
        defer { isSavingEdit = false }
        do {
            let provider = try await connection.updateAdaptorProvider(
                id: id,
                name: intent.name,
                baseURL: intent.baseURL,
                apiKey: intent.requestAPIKey,
                modelID: intent.models.first?.id ?? ""
            )
            guard model.canApplyProviderOperation(context) else {
                self.editError = "PI-adaptor 在保存过程中已切换：本次修改可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
                return
            }
            recordLocalBinding(provider)
            if let key = intent.keychainAPIKey,
               !KeychainStore.saveProviderKey(key, hostID: intent.hostID, providerId: id) {
                editKeyWarning = "服务器已更新，但本机密钥保存失败：发送时服务器会拒绝，请重新填写 API Key 后再保存。"
            }
            if intent.apiKeyDraftIsUnchanged(editApiKey) {
                editApiKey = ""
                // 有持久警告时留在编辑页，避免「密钥没存上」只闪一下就被关闭。
                if editKeyWarning == nil {
                    editingProvider = nil
                }
            } else {
                editKeyWarning = "保存期间输入有变化：本次未提交后输入的内容，请核对后再保存一次。"
            }
            await reload()
        } catch {
            self.editError = ConnectionErrorText.describe(error)
        }
    }

    private func reload() async {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            providers = []
            localKeyProviderIDs = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await connection.listAdaptorProviders()
            guard model.canApplyProviderOperation(context) else { return }
            providers = fetched
            localKeyProviderIDs = Set(
                fetched.filter { provider in
                    KeychainStore.loadProviderKey(hostID: host.id, providerId: provider.id) != nil
                }.map(\.id)
            )
            error = nil
        } catch {
            guard model.canApplyProviderOperation(context) else { return }
            self.error = ConnectionErrorText.describe(error)
        }
    }

    private func create() async {
        guard !isCreating else { return }
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.error = "当前 PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试。"
            return
        }
        // U14：创建同样冻结提交值（new provider 的密钥必须来自本次提交时刻的输入）。
        let intent = ProviderSaveIntent(
            kind: .create,
            hostID: host.id,
            name: name,
            baseURL: baseURL,
            models: [ProviderModelSpec(
                id: modelID,
                contextWindow: 128_000,
                maxTokens: 16_384,
                thinkingLevels: []
            )],
            apiKey: apiKey,
            apiKeyDraft: apiKey
        )
        if let rejection = intent.createRejection {
            self.error = rejection
            return
        }
        let frozenModelID = intent.models.first?.id ?? ""
        guard !frozenModelID.isEmpty else {
            self.error = "请填写模型 ID"
            return
        }
        isCreating = true
        warning = nil
        defer { isCreating = false }
        do {
            let provider = try await connection.createAdaptorProvider(
                name: intent.name,
                baseURL: intent.baseURL,
                apiKey: intent.requestAPIKey ?? "",
                modelID: frozenModelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.error = "PI-adaptor 在创建过程中已切换：该 provider 可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
                return
            }
            recordLocalBinding(provider)
            // Keychain 写入只用冻结值，并按提交时的 Host 记录；失败必须可见。
            if let key = intent.keychainAPIKey,
               !KeychainStore.saveProviderKey(key, hostID: intent.hostID, providerId: provider.id) {
                warning = "模型服务已创建，但本机密钥保存失败：发送时服务器会拒绝，请重新打开该服务填写 API Key。"
            }
            // 保存期间被改动的内容不清空（字段已禁用，这里只做防御）。
            if intent.apiKeyDraftIsUnchanged(apiKey) { apiKey = "" }
            if intent.name == name { name = "" }
            if intent.baseURL == baseURL { baseURL = "" }
            if frozenModelID == self.modelID { self.modelID = "" }
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }

    /// PI-adaptor v2 stores the provider server-side; sessions still bind through the
    /// local model catalog, so mirror the created/updated provider into it.
    private func recordLocalBinding(_ provider: RACPV2Provider) {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else { return }
        let input = ProviderCreateInput(
            name: provider.name,
            vendorKey: provider.vendorKey,
            type: provider.type,
            protocol: provider.protocolName,
            authKind: provider.authKind,
            baseUrl: provider.baseUrl,
            models: provider.models.map { spec in
                ProviderModelSpec(
                    id: spec.id,
                    contextWindow: spec.contextWindow,
                    maxTokens: spec.maxTokens,
                    thinkingLevels: spec.thinkingLevels,
                    defaultThinkingLevel: spec.defaultThinkingLevel,
                    alias: spec.displayName == spec.id ? nil : spec.displayName,
                    supportsImages: spec.supportsImages
                )
            },
            defaultModelId: provider.models.first?.id
        )
        // Carry forward the legacy mapping: editing a mirror imported over SSH must
        // not orphan the legacy provider (and its key) on the server.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
        model.recordImportedProvider(
            context: context,
            input: input,
            providerId: provider.id,
            serverDefaultSet: true,
            legacyProviderId: existing?.legacyProviderId,
            hostV2Mirror: true
        )
    }

    private func delete(_ provider: RACPV2Provider) async {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.error = "当前 PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试删除。"
            return
        }
        warning = nil
        // Capture the local mapping (legacy id + local record id) before deleting.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
        // U07：与模型服务详情页共用同一套删除分支与文案；不再丢弃 legacy 回执。
        let target = ProviderDeletionTarget(
            host: host,
            providerId: provider.id,
            legacyProviderId: existing?.legacyProviderId,
            hostV2Mirror: existing?.hostV2Mirror ?? true,
            localRecordId: existing?.id,
            displayName: provider.name,
            keychainProviderIds: [provider.id, existing?.legacyProviderId].compactMap { $0 }
        )
        let report = await ProviderDeletionUseCase(model: model, connection: connection)
            .delete(target)
        guard model.canApplyProviderOperation(context) else { return }
        if let failure = report.failureMessage {
            // 业务失败/回执不可解析：本机映射与 Keychain 线索已由用例保留。
            self.error = failure
            await reload()
            return
        }
        if report.tone == .needsAttention {
            // 已删除但默认模型未转移等需要跟进的结果，必须继续可见。
            warning = report.message
        }
        await reload()
    }
}
