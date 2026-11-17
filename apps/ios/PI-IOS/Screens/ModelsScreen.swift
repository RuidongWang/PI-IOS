import CryptoKit
import SwiftUI
import PIiOSCore
import PIiOSNet

/// Settings → Models. Discovery and import run through the existing SSH
/// connection so the API key never leaves the encrypted SSH transport from the
/// phone's perspective.
struct ModelsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel

    @State private var serviceName = ProviderProtocolPreset.defaultServiceName
    @State private var baseURL = ProviderProtocolPreset.defaultBaseURL
    @State private var apiKey = ""
    @State private var filter = ""
    @State private var modelDrafts: [EditableModelDraft] = []
    @State private var selectedDraftIDs = Set<UUID>()
    @State private var isFetching = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var keyWarning: String?
    @State private var selectedProvider: StoredModelProvider?
    @State private var deletionNotice: ProviderDeletionNotice?
    @State private var servicePreset: ProviderProtocolPreset = .openAIChatCompletions
    @State private var discoveryFingerprint: String?
    @State private var discoveryOperation: ProviderOperationContext?
    @State private var discoveryRequestID: UUID?

    /// 创建模型服务时只选择线路协议；认证统一为 API Key + Base URL。
    enum ProviderProtocolPreset: String, CaseIterable, Identifiable {
        case openAIChatCompletions = "OpenAI Chat Completions"
        case openAIResponses = "OpenAI Responses"
        case anthropicMessages = "Anthropic Messages"
        case googleGenerativeAI = "Google Generative AI"

        var id: String { rawValue }

        static let defaultServiceName = "localhost"
        static let defaultBaseURL = "http://localhost:8080"

        var protocolName: String {
            switch self {
            case .openAIChatCompletions: return "openai-completions"
            case .openAIResponses: return "openai-responses"
            case .anthropicMessages: return "anthropic-messages"
            case .googleGenerativeAI: return "google-generative-ai"
            }
        }
    }

    private var currentHost: HostRecord? { model.currentHost }

    /// 本机模型记录没有服务端 `authKind`，只能按本机 Keychain 判断密钥是否还在。
    private func hasLocalKey(_ provider: StoredModelProvider) -> Bool {
        if KeychainStore.loadProviderKey(hostID: provider.hostID, providerId: provider.providerId) != nil {
            return true
        }
        return provider.legacyProviderId.map { legacyProviderId in
            legacyProviderId != provider.providerId
                && KeychainStore.loadProviderKey(hostID: provider.hostID, providerId: legacyProviderId) != nil
        } ?? false
    }

    private func localKeyText(_ provider: StoredModelProvider) -> String {
        ProviderSecretDisplay.localText(hasLocalKey: hasLocalKey(provider))
    }

    /// 获取模型走 SSH（只需本机保存的凭证），导入却必须经在线的 PI-adaptor
    /// 隧道调用 `provider/create`。两者前置条件不同，必须提前说清楚，否则用户
    /// 在隧道离线时填完表单、拿到模型清单，最后只看到一条协议错误。
    private var importBlocker: String? {
        if connection.state.isOnline { return nil }
        if let host = currentHost, host.pairedAt == nil {
            return "这台服务器还没有配对：先在「服务器」用一次性令牌配对。"
        }
        let reason = connection.state.detail.map { "（\($0)）" } ?? ""
        return "PI-adaptor 当前离线（\(connection.state.displayText)）\(reason)：连接后重试。"
    }

    private struct EditableModelDraft: Identifiable, Equatable {
        let id = UUID()
        var source: ResolvedModelCandidate
        var modelId: String
        var displayName: String
        var contextWindow: String
        var maxTokens: String
        var thinkingLevels: [String]
        var defaultThinkingLevel: String

        init(candidate: ResolvedModelCandidate) {
            source = candidate
            modelId = candidate.spec.id
            displayName = candidate.spec.alias ?? candidate.discovered.displayName
            contextWindow = String(candidate.spec.contextWindow)
            maxTokens = String(candidate.spec.maxTokens)
            thinkingLevels = candidate.spec.thinkingLevels
            defaultThinkingLevel = candidate.spec.defaultThinkingLevel ?? ""
        }

        var editedSpec: ProviderModelSpec {
            ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
                base: source.spec,
                modelId: modelId,
                displayName: displayName,
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                thinkingLevels: thinkingLevels.joined(separator: ", "),
                defaultThinkingLevel: defaultThinkingLevel
            ))
        }
    }

    /// 主按钮的可用性必须同时传给 `isEnabled:`：`PIPrimaryButton` 的填充色读的是
    /// 参数本身，只在外层 `.disabled()` 会让按钮看起来仍可点。
    private var canFetchModels: Bool {
        currentHost != nil && !apiKey.isEmpty && !isFetching && !isImporting
    }

    private var canImportModels: Bool {
        !isImporting && !isFetching && !selectedDraftIDs.isEmpty && !apiKey.isEmpty && importBlocker == nil
    }

    private var visibleDrafts: [EditableModelDraft] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return modelDrafts }
        return modelDrafts.filter {
            $0.modelId.lowercased().contains(query)
                || $0.displayName.lowercased().contains(query)
        }
    }

    private var selectedDrafts: [EditableModelDraft] {
        modelDrafts.filter { selectedDraftIDs.contains($0.id) }
    }

    private var configurationFingerprint: String {
        let fields = [ECMAScriptString.trim(baseURL), ECMAScriptString.trim(apiKey)]
        let data = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func invalidateDiscovery() {
        discoveryFingerprint = nil
        discoveryOperation = nil
        discoveryRequestID = nil
        modelDrafts = []
        selectedDraftIDs = []
        isFetching = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                if isFetching {
                    PIStatusBanner(kind: .info, text: "正在获取模型")
                } else if isImporting {
                    PIStatusBanner(kind: .info, text: "正在导入模型服务")
                }
                configuredProviders
                addService
                if !modelDrafts.isEmpty {
                    discoveredModels
                }
                serverRecords
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("模型服务")
        .onChange(of: configurationFingerprint) { _, _ in invalidateDiscovery() }
        .onChange(of: currentHost.flatMap { model.providerOperationContext(for: $0) }) { _, _ in
            invalidateDiscovery()
        }
        .onChange(of: servicePreset) { _, _ in invalidateDiscovery() }
        .onChange(of: model.currentModelProviders) { _, providers in
            if let selected = selectedProvider {
                guard let updated = providers.first(where: { $0.id == selected.id }) else {
                    selectedProvider = nil
                    return
                }
                selectedProvider = updated
            }
        }
        .piMessageAlert(title: "模型服务已删除", message: Binding(
            get: {
                guard selectedProvider == nil, case .success(let message)? = deletionNotice else { return nil }
                return message
            },
            set: { if $0 == nil { deletionNotice = nil } }
        ))
        .piMessageAlert(title: "删除后需要处理", message: Binding(
            get: {
                guard selectedProvider == nil, case .needsAttention(let message)? = deletionNotice else { return nil }
                return message
            },
            set: { if $0 == nil { deletionNotice = nil } }
        ))
        .sheet(isPresented: Binding(
            get: { selectedProvider != nil },
            set: { if !$0 { selectedProvider = nil } }
        )) {
            if let provider = selectedProvider, let host = currentHost, provider.hostID == host.id {
                ModelProviderDetailSheet(
                    provider: provider,
                    host: host,
                    onDeleted: { notice in
                        switch notice {
                        case .success, .needsAttention:
                            deletionNotice = notice
                        }
                        selectedProvider = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        Group {
            if let errorMessage {
                PIInlineMessage(kind: .danger, text: errorMessage)
            } else if let statusMessage {
                PIInlineMessage(kind: .success, text: statusMessage)
            }
            // Keychain 写入失败属于「服务器已完成、本机密钥不可用」的部分结果，必须单独可见。
            if let keyWarning {
                PIInlineMessage(kind: .warning, text: keyWarning)
                    .accessibilityIdentifier("models.keyWarning")
            }
        }
    }

    private var configuredProviders: some View {
        PIGroup("本机模型清单") {
            if model.currentModelProviders.isEmpty {
                PIListRow(
                    title: "还没有模型服务",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(Array(model.currentModelProviders.enumerated()), id: \.element.id) { index, provider in
                    PIListRow(
                        title: provider.name,
                        subtitle: "\(provider.models.count) 个模型 · \(provider.baseURL)",
                        icon: "cpu",
                        iconTint: PIColor.accent,
                        isEnabled: true,
                        showsChevron: true,
                        showsDivider: index != model.currentModelProviders.count - 1,
                        action: { selectedProvider = provider }
                    ) {
                        // 缺密钥需要用户处理：图标表达警告，文字保持可读的文本色。
                        if !hasLocalKey(provider) {
                            HStack(spacing: PISpacing.s4) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PIColor.warning)
                                    .accessibilityHidden(true)
                                Text(localKeyText(provider))
                                    .font(PIFont.caption)
                                    .foregroundStyle(PIColor.text2)
                            }
                        }
                    }
                    .accessibilityIdentifier("models.providerRow.\(provider.providerId)")
                }
            }
        }
    }

    private var addService: some View {
        PIGroup("添加模型服务") {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                PIFormField(label: "协议") {
                    Picker("协议", selection: $servicePreset) {
                        ForEach(ProviderProtocolPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("models.servicePreset")
                }
                PIFormField(label: "服务名称") {
                    TextField("localhost", text: $serviceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("models.serviceName")
                }
                PIFormField(label: "Base URL") {
                    TextField(ProviderProtocolPreset.defaultBaseURL, text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("models.baseURL")
                }
                PIFormField(label: "API Key", isPill: false) {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        SecureField("sk-…", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .piFieldChrome()
                            .accessibilityIdentifier("models.apiKey")
                        // 全 App 唯一一处说明密钥归属：用户第一次输入 API Key 就在这里。
                        // 上一轮只留「只存在本机」是错的：发现/导入确实会把它临时发给
                        // PI-adaptor。一句说清「存哪、会不会离开本机、服务器落不落盘」。
                        Text("只存本机；发现/导入时临时发给 PI-adaptor，不落盘")
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text2)
                            .accessibilityIdentifier("models.apiKeyNote")
                    }
                }
                PIPrimaryButton(
                    title: isFetching ? "正在获取…" : "获取模型",
                    isEnabled: canFetchModels
                ) {
                    fetchModels()
                }
                .accessibilityIdentifier("models.fetchModels")
                .disabled(!canFetchModels)
                if currentHost == nil {
                    Text("先在「服务器」添加并连接。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                } else if let importBlocker {
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        Text("无法导入模型服务")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.warning)
                        PIInlineMessage(kind: .warning, text: importBlocker)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("models.importBlocked")
                }
                status
            }
            .padding(PISpacing.s16)
        }
    }

    private var discoveredModels: some View {
        PIGroup("可用模型（\(modelDrafts.count)）") {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                TextField("搜索模型 ID 或名称", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .piFieldChrome()
                    .accessibilityIdentifier("models.modelFilter")
                HStack(spacing: PISpacing.s8) {
                    Button("全选") {
                        selectedDraftIDs.formUnion(visibleDrafts.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PIColor.accent)
                    .accessibilityIdentifier("models.selectAll")
                    Button("取消全选") {
                        selectedDraftIDs.subtract(visibleDrafts.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PIColor.text2)
                    .accessibilityIdentifier("models.selectNone")
                    Spacer()
                }
                .font(PIFont.caption)

                ForEach(visibleDrafts) { draft in
                    modelRow(draft)
                    if draft.id != visibleDrafts.last?.id {
                        Divider()
                    }
                }

                PIPrimaryButton(
                    title: isImporting ? "正在导入…" : "导入 \(selectedDraftIDs.count) 个模型",
                    isEnabled: canImportModels
                ) {
                    importModels()
                }
                .accessibilityIdentifier("models.importModels")
                .disabled(!canImportModels)
            }
            .padding(PISpacing.s16)
        }
    }

    /// quiet-v2 §0.2 第 2 条：v2 provider 记录不再是设置页的并列一级入口，
    /// 而是「模型服务」页内部的「服务器记录」。
    ///
    /// 只在**当前连接的** host 真支持 v2 provider 记录时出现。
    ///
    /// 判据按可信度从高到低：服务器声明的 `capabilities.providers` → 本机已有
    /// `hostV2Mirror` 记录（说明这个 host 以前确实给过 v2 provider）→ serverName 兜底。
    /// 第三条必须留：老版本 PI-adaptor 不返回 `capabilities`，只看第一条会把入口永久藏起来。
    /// 离线时不出现——记录存在服务器上，点开只能是失败。
    private var showsServerRecords: Bool {
        guard connection.state.isOnline, let info = connection.info else { return false }
        if let supportsProviders = info.capabilities?.value(at: ["providers"])?.boolValue {
            return supportsProviders
        }
        // 本机已经存着这个 host 的 v2 provider 镜像：入口必须可达，否则用户删不掉它们。
        if model.currentModelProviders.contains(where: { $0.hostV2Mirror == true }) {
            return true
        }
        return info.serverName == PIAdaptorRelease.runtimeServerName
    }

    /// 这一行只负责「把门放在正确的位置」，不为了副标题再多打一次 provider/list。
    @ViewBuilder
    private var serverRecords: some View {
        if showsServerRecords {
            PIGroup {
                NavigationLink(value: SettingsRoute.adaptorProviders) {
                    PIListRow(
                        title: "服务器记录",
                        icon: "server.rack",
                        showsChevron: true,
                        showsDivider: false
                    )
                }
                .buttonStyle(PIPressableButtonStyle())
                .accessibilityIdentifier("models.serverRecords")
            }
        }
    }

    private func modelRow(_ draft: EditableModelDraft) -> some View {
        let binding = draftBinding(for: draft.id)
        return VStack(alignment: .leading, spacing: PISpacing.s8) {
            Toggle(isOn: Binding(
                get: { selectedDraftIDs.contains(draft.id) },
                set: { enabled in
                    if enabled {
                        selectedDraftIDs.insert(draft.id)
                    } else {
                        selectedDraftIDs.remove(draft.id)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text(draft.displayName.isEmpty ? draft.modelId : draft.displayName)
                        .font(PIFont.listTitle)
                        .foregroundStyle(PIColor.text)
                    Text(draft.modelId)
                        .font(PIFont.metaMono)
                        .foregroundStyle(PIColor.text2)
                    Text(summary(draft))
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(PIColor.accent)
            .accessibilityIdentifier("models.draft.toggle.\(draft.modelId)")

            if selectedDraftIDs.contains(draft.id) {
                DisclosureGroup("编辑模型参数") {
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        TextField("模型 ID", text: binding.modelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .piFieldChrome()
                            .accessibilityIdentifier("models.draft.modelId.\(draft.modelId)")
                        TextField("显示名称", text: binding.displayName)
                            .piFieldChrome()
                            .accessibilityIdentifier("models.draft.displayName.\(draft.modelId)")
                        HStack(spacing: PISpacing.s8) {
                            TextField("上下文上限", text: binding.contextWindow)
                                .keyboardType(.numberPad)
                                .piFieldChrome()
                                .accessibilityIdentifier("models.draft.contextWindow.\(draft.modelId)")
                            TextField("输出上限", text: binding.maxTokens)
                                .keyboardType(.numberPad)
                                .piFieldChrome()
                                .accessibilityIdentifier("models.draft.maxTokens.\(draft.modelId)")
                        }
                        PIThinkingLevelsPicker(
                            title: "思考档位",
                            selection: binding.thinkingLevels,
                            identifier: "models.thinkingLevels"
                        )
                        PIThinkingLevelPicker(
                            title: "默认思考档位",
                            selection: binding.defaultThinkingLevel,
                            options: draft.thinkingLevels,
                            identifier: "models.defaultThinkingLevel"
                        )
                    }
                    .padding(.top, PISpacing.s8)
                }
                .font(PIFont.caption)
            }
        }
        .onChange(of: draft.thinkingLevels) { _, levels in
            // 档位被取消勾选后，默认档位不能继续指向一个不存在的值。
            if !levels.contains(binding.defaultThinkingLevel.wrappedValue) {
                binding.defaultThinkingLevel.wrappedValue = ""
            }
        }
    }

    private func draftBinding(for id: UUID) -> Binding<EditableModelDraft> {
        Binding(
            get: {
                modelDrafts.first(where: { $0.id == id })
                    ?? EditableModelDraft(candidate: placeholderCandidate)
            },
            set: { updated in
                guard let index = modelDrafts.firstIndex(where: { $0.id == id }) else { return }
                modelDrafts[index] = updated
            }
        )
    }

    private var placeholderCandidate: ResolvedModelCandidate {
        ResolvedModelCandidate(
            discovered: DiscoveredModel(modelId: "", displayName: ""),
            spec: ProviderModelSpec(
                id: "",
                contextWindow: -1,
                maxTokens: -1,
                thinkingLevels: []
            ),
            metadataSource: .generic
        )
    }

    private func summary(_ draft: EditableModelDraft) -> String {
        let spec = draft.editedSpec
        var parts = [
            "\(compactTokens(spec.contextWindow)) ctx",
            "\(compactTokens(spec.maxTokens)) output",
        ]
        if !spec.thinkingLevels.isEmpty {
            parts.append("思考 \(spec.thinkingLevels.joined(separator: "/"))")
        }
        if spec.supportsImages == true { parts.append("图片") }
        if spec.supportsDocuments == true { parts.append("PDF") }
        return parts.joined(separator: " · ")
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }

    private func fetchModels() {
        guard let host = currentHost,
              let operation = model.providerOperationContext(for: host) else { return }
        let normalizedBaseURL = ECMAScriptString.trim(baseURL)
        let validation = EndpointPolicy.validate(baseUrl: normalizedBaseURL, vendorKey: "custom")
        guard validation.isValid else {
            errorMessage = validation.displayReason
            return
        }
        let compatibilityWarning = EndpointPolicy.hostCompatibilityWarning(baseUrl: normalizedBaseURL)
        let normalizedAPIKey = ECMAScriptString.trim(apiKey)
        guard !normalizedAPIKey.isEmpty else {
            errorMessage = "请填写 API Key"
            return
        }
        if let compatibilityWarning { statusMessage = compatibilityWarning }
        invalidateDiscovery()
        let requestID = UUID()
        let fingerprint = configurationFingerprint
        discoveryRequestID = requestID
        isFetching = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let discovered = try await connection.discoverModels(
                    record: host,
                    baseURL: normalizedBaseURL,
                    apiKey: normalizedAPIKey,
                    protocol: servicePreset.protocolName
                )
                let normalizedModels = discovered.map { discovered in
                    var model = discovered
                    model.modelId = ECMAScriptString.trim(model.modelId)
                    return model
                }
                let resolved = ModelConfigurationResolver.resolve(normalizedModels)
                await MainActor.run {
                    guard discoveryRequestID == requestID else { return }
                    guard model.canApplyProviderOperation(operation),
                          configurationFingerprint == fingerprint else {
                        isFetching = false
                        return
                    }
                    discoveryFingerprint = fingerprint
                    discoveryOperation = operation
                    modelDrafts = resolved.map(EditableModelDraft.init(candidate:))
                    selectedDraftIDs = Set(modelDrafts.map(\.id))
                    if ECMAScriptString.trim(serviceName).isEmpty {
                        serviceName = ProviderImportComposer.defaultServiceName(for: normalizedBaseURL)
                    }
                    statusMessage = "已获取 \(resolved.count) 个模型"
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    guard discoveryRequestID == requestID else { return }
                    isFetching = false
                    guard model.canApplyProviderOperation(operation),
                          configurationFingerprint == fingerprint else { return }
                    errorMessage = ConnectionErrorText.describe(error)
                }
            }
        }
    }

    private func importModels() {
        guard let host = currentHost,
              let operation = model.providerOperationContext(for: host) else { return }
        if let importBlocker {
            errorMessage = importBlocker
            return
        }
        guard discoveryFingerprint == configurationFingerprint,
              discoveryOperation == operation else {
            invalidateDiscovery()
            errorMessage = "配置已变化，请重新获取模型"
            return
        }
        let normalizedBaseURL = ECMAScriptString.trim(baseURL)
        let validation = EndpointPolicy.validate(baseUrl: normalizedBaseURL, vendorKey: "custom")
        guard validation.isValid else {
            errorMessage = validation.displayReason
            return
        }
        let selected = selectedDrafts
        guard !selected.isEmpty else {
            errorMessage = "请至少选择一个模型"
            return
        }
        let normalizedAPIKey = ECMAScriptString.trim(apiKey)
        guard !normalizedAPIKey.isEmpty else {
            errorMessage = "请填写 API Key"
            return
        }
        let selectedSpecs = selected.map(\.editedSpec)
        let isFirstProvider = model.currentModelProviders.isEmpty
        let composition = ProviderImportComposer.compose(
            serviceName: serviceName,
            baseURL: normalizedBaseURL,
            apiKey: normalizedAPIKey,
            models: selectedSpecs,
            setDefaultModel: isFirstProvider,
            vendorKey: ProviderImportComposer.vendorKey(
                for: servicePreset.protocolName,
                baseURL: normalizedBaseURL
            ),
            wireProtocol: servicePreset.protocolName
        )
        guard composition.isValid else {
            errorMessage = composition.issues.map(\.description).joined(separator: "\n")
            return
        }
        let input = composition.input
        let payload = composition.payload
        let importFingerprint = configurationFingerprint
        guard let data = try? ProviderImportEncoder.encode(payload) else {
            errorMessage = "提交内容无法编码，请重试"
            return
        }

        isImporting = true
        statusMessage = nil
        errorMessage = nil
        keyWarning = nil
        Task {
            do {
                let receipt = try await connection.importProvider(record: host, payload: data)
                let sourceId = payload.providers[0].sourceId
                await MainActor.run {
                    isImporting = false
                    guard model.canApplyProviderOperation(operation) else { return }
                    switch receipt {
                    case .success(let success):
                        switch success.outcome(forSourceId: sourceId) {
                        case .imported(let providerId):
                            guard model.recordImportedProvider(
                                context: operation,
                                input: input,
                                providerId: providerId,
                                serverDefaultSet: success.defaultSet,
                                hostV2Mirror: true
                            ) else { return }
                            // 服务器已导入后密钥只落本机 Keychain；写入失败必须可见，
                            // 不能只留下一条“已导入”让发送时才失败。
                            if !KeychainStore.saveProviderKey(
                                normalizedAPIKey,
                                hostID: operation.hostID,
                                providerId: providerId
                            ) {
                                keyWarning = "已导入 \(input.models.count) 个模型，但密钥未存上：请重新填写 API Key。"
                            }
                            if configurationFingerprint == importFingerprint {
                                apiKey = ""
                            }
                            statusMessage = "已导入 \(input.models.count) 个模型"
                            if isFirstProvider, success.defaultSet, let firstModel = input.models.first {
                                statusMessage = "已导入 \(input.models.count) 个模型，默认模型为 \(firstModel.alias ?? firstModel.id)"
                            }
                        case .skipped(let reason):
                            errorMessage = "服务器跳过了这条服务：\(reason.clientGuidance)"
                        case .missing:
                            errorMessage = "服务器没有返回导入结果"
                        }
                    case .failure(let failure):
                        errorMessage = "导入失败：\(failure.displayMessage)"
                    case .unparseable(let reason):
                        errorMessage = "无法解析服务器回执：\(reason)"
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    guard model.canApplyProviderOperation(operation) else { return }
                    errorMessage = ConnectionErrorText.describe(error)
                }
            }
        }
    }

}
