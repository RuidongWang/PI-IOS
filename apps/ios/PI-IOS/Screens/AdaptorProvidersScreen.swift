import SwiftUI
import PIiOSCore

struct AdaptorProvidersScreen: View {
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel

    /// 列表的「五种现实」由一个状态表达：idle / loading / loaded / failed(+旧数据)。
    /// 只有 `.loaded([])` 才允许画空态；断线与失败都保留上一次成功的数据。
    @State private var providers: ContentState<[RACPV2Provider]> = .idle
    /// 新增失败：错误属于「保存到 PI-adaptor」按钮，就地显示在表单里。
    @State private var createError: String?
    /// 新增成功但本机密钥没存上：部分成功回执，跟着新增按钮。
    @State private var createWarning: String?
    /// 删除回执：动作结果需要用户确认，按 §5.1 用 alert，不跨屏乱跑。
    @State private var deleteAlert: DeleteAlert?
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
                // quiet-v2：页面顶部不再放任何错误。列表自己的状态画在列表里，
                // 表单/删除的失败画在触发它的控件旁。
                PIGroup("服务器 provider") {
                    switch providers.presentation() {
                    case let .loading(hasStale):
                        // 正在读：有旧数据就继续画旧数据，读不到不清空。
                        if hasStale, let cached = providers.value, !cached.isEmpty {
                            providerRows(cached)
                        } else {
                            PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                        }
                    case let .content(cached, _):
                        providerRows(cached)
                    case .empty:
                        // 只有「读成功且确实为空」才是空态。
                        PIListRow(title: "还没有 provider", isEnabled: false, showsDivider: false)
                    case let .failed(reason):
                        // 读失败且没有可复用的旧数据：说原因 + 给重试，不写「还没有」。
                        providerListFailure(reason)
                    }
                    if case let .content(_, isStale) = providers.presentation(), isStale {
                        providerListStale(providers.failureReason ?? "")
                    }
                }
                PIGroup("新增 provider") {
                    PIFormRow {
                        PIFormField(label: "名称") {
                            TextField("localhost", text: $name)
                                .disabled(isCreating)
                                .accessibilityIdentifier("providers.createName")
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "Base URL") {
                            TextField("https://api.example.com/v1", text: $baseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isCreating)
                                .accessibilityIdentifier("providers.createBaseURL")
                        }
                    }
                    PIFormRow {
                        PIFormField(label: "API Key") {
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
                                .accessibilityIdentifier("providers.createModelID")
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
                        .accessibilityIdentifier("providers.createSave")
                    }
                    // §5.1：表单提交失败属于「触发它的控件」——贴着保存按钮显示，
                    // 不再放到页面顶部让用户在长表单两端来回找。
                    if let createError, !createError.isEmpty {
                        PIInlineMessage(kind: .danger, text: createError)
                            .padding(.horizontal, PISpacing.s16)
                            .padding(.bottom, PISpacing.s12)
                            .accessibilityIdentifier("providers.error")
                    }
                    if let createWarning {
                        PIInlineMessage(kind: .warning, text: createWarning)
                            .padding(.horizontal, PISpacing.s16)
                            .padding(.bottom, PISpacing.s12)
                            .accessibilityIdentifier("providers.warning")
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
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .navigationTitle("PI-adaptor Provider")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.state.isOnline) {
            guard connection.state.isOnline else {
                // 断线：把已取到的数据降级为 stale，而不是清成「没有」。
                providers.markStale(reason: "未连接")
                return
            }
            await reload()
        }
        .refreshable { await reload() }
        .onChange(of: model.currentHost?.id) { _ in
            Task { await reload() }
        }
        // 删除是用户动作，结果是「需要被确认的一次回执」→ alert（§5.1）。
        .alert(
            deleteAlert?.title ?? "",
            isPresented: Binding(
                get: { deleteAlert != nil },
                set: { presented in
                    guard !presented, deleteAlert != nil else { return }
                    DispatchQueue.main.async { deleteAlert = nil }
                }
            )
        ) {
            Button("知道了") {}
        } message: {
            Text(deleteAlert?.message ?? "")
        }
        .confirmationDialog(
            // 标题点名要删的对象；message 只留后果，不写安抚/保证（R7）。
            "删除「\(pendingDelete?.name ?? "")」？",
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
            Text("服务器记录与本机密钥都会删除；默认模型不会自动转移。")
        }
        .sheet(item: $editingProvider) { provider in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: PISpacing.s16) {
                        // §5.1：弹层内的提交失败用页内 message，贴着右上角的「保存」出现；
                        // 不再用 alert 盖住表单——错误属于触发它的控件。
                        if let editError, !editError.isEmpty {
                            PIInlineMessage(kind: .danger, text: editError)
                                .accessibilityIdentifier("providers.editError")
                        }
                        PIGroup("Provider 配置") {
                            VStack(alignment: .leading, spacing: PISpacing.s16) {
                                PIFormField(label: "名称") {
                                    TextField("localhost", text: $editName)
                                        .accessibilityIdentifier("providers.editName")
                                }
                                PIFormField(label: "Base URL") {
                                    TextField("https://api.example.com/v1", text: $editBaseURL)
                                        .keyboardType(.URL)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .accessibilityIdentifier("providers.editBaseURL")
                                }
                                PIFormField(label: "新 API Key") {
                                    SecureField("留空保持不变", text: $editApiKey)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .accessibilityIdentifier("providers.editAPIKey")
                                }
                                PIFormField(label: "模型 ID") {
                                    TextField("model-id", text: $editModelID)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .accessibilityIdentifier("providers.editModelID")
                                }
                            }
                            .padding(PISpacing.s16)
                        }
                        // U14：保存期间禁止继续编辑，避免请求值与本机 Keychain 写入分叉。
                        .disabled(isSavingEdit)
                        if let editKeyWarning {
                            PIInlineMessage(kind: .warning, text: editKeyWarning)
                                .accessibilityIdentifier("providers.editKeyWarning")
                        }
                    }
                    .padding(.horizontal, PIMetrics.pageMargin)
                    .padding(.vertical, PISpacing.s16)
                }
                .piPageBackground()
                .scrollDismissesKeyboard(.immediately)
                .piDetailNavBar("编辑 Provider")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editingProvider = nil }
                            .disabled(isSavingEdit)
                            .accessibilityIdentifier("providers.editCancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSavingEdit ? "保存中…" : "保存") { Task { await saveEdit(id: provider.id) } }
                            .disabled(
                                isSavingEdit
                                    || editName.isEmpty
                                    || editBaseURL.isEmpty
                                    || editModelID.isEmpty
                            )
                            .accessibilityIdentifier("providers.editSave")
                    }
                }
            }
        }
    }

    // MARK: - 列表（内容状态）

    /// 成功读到的行。只有在这里才画真实数据。
    @ViewBuilder
    private func providerRows(_ list: [RACPV2Provider]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, provider in
            PIListRow(
                title: provider.name,
                subtitle: "\(provider.baseUrl) · \(provider.models.count) 个模型 · \(secretText(for: provider))",
                showsDivider: index < list.count - 1
            ) {
                HStack(spacing: PISpacing.s16) {
                    Button {
                        startEditing(provider)
                    } label: {
                        Text("编辑")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.accent)
                            .frame(minHeight: PIMetrics.minHitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("providers.edit.\(provider.name)")
                    Button(role: .destructive) {
                        pendingDelete = provider
                    } label: {
                        Text("删除")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.danger)
                            .frame(minHeight: PIMetrics.minHitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("providers.delete.\(provider.name)")
                }
            }
        }
    }

    /// 读到过数据、但这次没读到：画旧数据 + 一行 stale 提示。
    /// 一行说两件事：看到的是旧的、为什么没刷新。不清空列表。
    private func providerListStale(_ reason: String) -> some View {
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
        .accessibilityIdentifier("providers.listState")
    }

    /// 读失败且没有可复用的旧数据：原因 + 重试入口。绝不画成「还没有」。
    private func providerListFailure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIInlineMessage(kind: .danger, text: reason)
                .accessibilityIdentifier("providers.listState")
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
            .accessibilityIdentifier("providers.listRetry")
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
    }

    /// v0.0.3 起 `apiKeyMask` 为 null 不再等于「无密钥」；
    /// 由本机 Keychain 决定显示「本机有密钥」还是「本机缺密钥」。
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
            self.editError = "PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试。"
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
                self.editError = "PI-adaptor 已切换：修改可能已提交到原 PI-adaptor，请过去核对。"
                return
            }
            recordLocalBinding(provider)
            if let key = intent.keychainAPIKey,
               !KeychainStore.saveProviderKey(key, hostID: intent.hostID, providerId: id) {
                editKeyWarning = "已保存，但密钥未存上：请重新填写 API Key。"
            }
            if intent.apiKeyDraftIsUnchanged(editApiKey) {
                editApiKey = ""
                // 有持久警告时留在编辑页，避免「密钥没存上」只闪一下就被关闭。
                if editKeyWarning == nil {
                    editingProvider = nil
                }
            } else {
                editKeyWarning = "保存期间输入有变化：请核对后再保存一次。"
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
            // 没有可绑定的 PI-adaptor：这次没读到，但上次读到的照旧画出来。
            providers.markStale(reason: "当前 PI-adaptor 不可用。")
            return
        }
        // 正在读：保留上一次成功的数据，避免刷新瞬间闪成空列表。
        providers.beginLoading()
        do {
            let fetched = try await connection.listAdaptorProviders()
            guard model.canApplyProviderOperation(context) else { return }
            providers.succeed(fetched)
            localKeyProviderIDs = Set(
                fetched.filter { provider in
                    KeychainStore.loadProviderKey(hostID: host.id, providerId: provider.id) != nil
                }.map(\.id)
            )
        } catch {
            guard model.canApplyProviderOperation(context) else { return }
            // 失败不清空：有旧数据就降级成 stale，没有就画原因 + 重试。
            providers.markStale(reason: ConnectionErrorText.describe(error))
        }
    }

    private func create() async {
        guard !isCreating else { return }
        // 本次提交开始时先清掉上一次的回执，避免旧错误与新结果同时挂在按钮旁。
        createError = nil
        createWarning = nil
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.createError = "PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试。"
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
            self.createError = rejection
            return
        }
        let frozenModelID = intent.models.first?.id ?? ""
        guard !frozenModelID.isEmpty else {
            self.createError = "请填写模型 ID"
            return
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let provider = try await connection.createAdaptorProvider(
                name: intent.name,
                baseURL: intent.baseURL,
                apiKey: intent.requestAPIKey ?? "",
                modelID: frozenModelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.createError = "PI-adaptor 已切换：provider 可能已写入原 PI-adaptor，请过去核对。"
                return
            }
            recordLocalBinding(provider)
            // Keychain 写入只用冻结值，并按提交时的 Host 记录；失败必须可见。
            if let key = intent.keychainAPIKey,
               !KeychainStore.saveProviderKey(key, hostID: intent.hostID, providerId: provider.id) {
                createWarning = "已创建，但密钥未存上：请重新填写 API Key。"
            }
            // 保存期间被改动的内容不清空（字段已禁用，这里只做防御）。
            if intent.apiKeyDraftIsUnchanged(apiKey) { apiKey = "" }
            if intent.name == name { name = "" }
            if intent.baseURL == baseURL { baseURL = "" }
            if frozenModelID == self.modelID { self.modelID = "" }
            await reload()
        } catch {
            self.createError = ConnectionErrorText.describe(error)
        }
    }

    /// PI-adaptor v2 stores the provider server-side; sessions still bind through the
    /// local model catalog, so mirror the created/updated provider into it.
    private func recordLocalBinding(_ provider: RACPV2Provider) {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else { return }
        // Carry forward the legacy mapping: editing a mirror imported over SSH must
        // not orphan the legacy provider (and its key) on the server.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
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
            // 编辑服务信息/改模型不是「选择默认模型」：保留本机已有默认，
            // 绝不能把首项模型顺手写成默认（否则每次改名都会抢走默认模型）。
            defaultModelId: existing?.defaultModelId
        )
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
            deleteAlert = DeleteAlert(
                title: "删除未完成",
                message: "PI-adaptor 不可用或已切换：请在当前 PI-adaptor 上重试删除。"
            )
            return
        }
        deleteAlert = nil
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
            deleteAlert = DeleteAlert(title: "删除未完成", message: failure)
            await reload()
            return
        }
        if report.tone == .needsAttention {
            // 已删除但默认模型未转移等需要跟进的结果，必须继续可见。
            deleteAlert = DeleteAlert(title: "删除后需要处理", message: report.message)
        }
        await reload()
    }
}

/// 删除结果回执：失败与「需要处理」都走同一个确认框（§5.1：结果需要被确认）。
/// 标题点名结果，message 只放用例给的事实与下一步。
private struct DeleteAlert {
    let title: String
    let message: String
}
