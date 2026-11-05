import SwiftUI
import PIiOSCore

struct AdaptorProvidersScreen: View {
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel

    @State private var providers: [RACPV2Provider] = []
    @State private var isLoading = false
    @State private var error: String?
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
    @State private var isCreating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                PIGroup("服务器 provider", footer: "API Key 只写入 PI-adaptor；本机不保存明文。") {
                    if isLoading {
                        PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                    } else if providers.isEmpty {
                        PIListRow(title: "还没有 provider", isEnabled: false, showsDivider: false)
                    } else {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            PIListRow(
                                title: provider.name,
                                subtitle: "\(provider.baseUrl) · \(provider.models.count) 个模型 · \(provider.apiKeyMask ?? "无密钥")",
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
                                }
                            }
                        }
                    }
                }
                PIGroup("新增 provider") {
                    PIFormRow {
                        PIFormField(label: "名称") {
                            TextField("DeepSeek", text: $name)
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "Base URL") {
                            TextField("https://api.example.com/v1", text: $baseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "API Key") {
                            SecureField("sk-…", text: $apiKey)
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "模型 ID") {
                            TextField("deepseek-chat", text: $modelID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
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
                error = nil
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
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 PI-adaptor 清除该 provider 与密钥；不会自动把默认项切到其他 provider。")
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
                        TextField("模型 ID", text: $editModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await saveEdit(id: provider.id) } }
                            .disabled(editName.isEmpty || editBaseURL.isEmpty || editModelID.isEmpty)
                    }
                }
            }
        }
    }

    private func startEditing(_ provider: RACPV2Provider) {
        editError = nil
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
        do {
            let provider = try await connection.updateAdaptorProvider(
                id: id,
                name: editName,
                baseURL: editBaseURL,
                apiKey: editApiKey.isEmpty ? nil : editApiKey,
                modelID: editModelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.editError = "PI-adaptor 在保存过程中已切换：本次修改可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
                return
            }
            recordLocalBinding(provider)
            if !editApiKey.isEmpty {
                _ = KeychainStore.saveProviderKey(editApiKey, hostID: host.id, providerId: id)
            }
            editingProvider = nil
            editError = nil
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
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await connection.listAdaptorProviders()
            guard model.canApplyProviderOperation(context) else { return }
            providers = fetched
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
        isCreating = true
        defer { isCreating = false }
        do {
            let provider = try await connection.createAdaptorProvider(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                modelID: modelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.error = "PI-adaptor 在创建过程中已切换：该 provider 可能已写入原 PI-adaptor，请到该 PI-adaptor 上核对。"
                return
            }
            recordLocalBinding(provider)
            _ = KeychainStore.saveProviderKey(apiKey, hostID: host.id, providerId: provider.id)
            name = ""
            baseURL = ""
            apiKey = ""
            modelID = ""
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
        // Capture the legacy mapping before removing the local record.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
        do {
            do {
                try await connection.deleteAdaptorProvider(id: provider.id)
            } catch let error as RACPV2Error {
                // 幂等删除：PI-adaptor 上已经查不到这条记录时继续清理本机镜像。
                guard case .server(let code, _) = error, code == "NOT_FOUND" else { throw error }
            }
            guard model.canApplyProviderOperation(context) else { return }
            // A provider mirrored from a legacy SSH import also lives in the legacy
            // store; deleting only the v2 record would leave the legacy service and
            // its secret on the server.
            var legacyError: Error?
            if let legacyProviderId = existing?.legacyProviderId {
                do {
                    _ = try await connection.removeProvider(record: host, providerId: legacyProviderId)
                } catch {
                    legacyError = error
                }
                guard model.canApplyProviderOperation(context) else { return }
            }
            if let legacyError {
                self.error = "v2 Provider 已删除，但 legacy 服务清理失败：\(ConnectionErrorText.describe(legacyError))。本地映射已保留以便重试。"
                await reload()
                return
            }
            _ = model.removeLocalProvider(
                id: "\(host.id.uuidString):\(provider.id)",
                context: context
            )
            _ = KeychainStore.deleteProviderKey(hostID: host.id, providerId: provider.id)
            await reload()
        } catch {
            self.error = ConnectionErrorText.describe(error)
        }
    }
}
