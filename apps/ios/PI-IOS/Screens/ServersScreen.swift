import SwiftUI
import Security
import PIiOSNet
import UniformTypeIdentifiers

/// S-04 服务器（子页）。新增与编辑共用一张表单。
///
/// 本页现在真的会连一次服务器：「保存并测试连接」= 写入本机记录 + 凭证进 Keychain +
/// 一次真实 SSH 握手/认证/`exec`；首次连接会先停在指纹核对（AC-02.1）。
/// 配对使用 `pi-adaptor` 输出的一次性令牌；安装入口转到真实 bootstrap 状态机。
struct ServersScreen: View {
    let hostID: UUID?
    let push: (SettingsRoute) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = HostDraft()
    /// 首次「保存」创建记录后把它记下来，让表单转入该记录的编辑态：否则第二次
    /// 保存（例如首次连接测试失败后改了信息再存）会再调用一次 `addHost`，
    /// 生成重复的本机记录。
    @State private var createdHostID: UUID?
    @State private var errors = HostDraftErrors.none
    @State private var didLoadHost = false
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var isPairing = false
    @State private var isDeleting = false
    @State private var pairingToken = ""
    @State private var pairingMessage: String?
    /// 已有设备令牌时，是否展开「使用新的一次性令牌重新配对」表单（U17）。
    @State private var isRepairingWithNewToken = false
    @State private var resultMessage: String?
    /// 是否正在打开系统文件选择器。
    @State private var isPickingKey = false
    /// 选择私钥文件时的失败原因（不可读 / 格式不支持 / 空文件 / 过大）。
    @State private var keyFileError: String?
    /// 私钥文件选不进来时的兜底通道：直接把私钥文本粘贴进来。
    @State private var isPastingKey = false
    @State private var pastedKeyText = ""
    @State private var pasteKeyError: String?

    /// 当前表单绑定的记录 id：优先本页刚创建的记录，其次是从外层传入的编辑目标。
    private var activeHostID: UUID? { createdHostID ?? hostID }

    private var existingHost: HostRecord? {
        guard let activeHostID else { return nil }
        return model.hosts.first(where: { $0.id == activeHostID })
    }

    private var isEditing: Bool { activeHostID != nil }

    private var account: String? {
        let username = draft.username.piTrimmed
        let host = draft.host.piTrimmed
        guard !username.isEmpty, !host.isEmpty else { return nil }
        return KeychainStore.account(username: username, host: host, port: Int(draft.port.piTrimmed) ?? 22)
    }

    private var pinnedHostKey: SSHHostKey? {
        guard let account else { return nil }
        return KeychainStore.loadHostKey(account: account)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                statusBanner
                if let host = existingHost, pairingPolicy(for: host).isRepairPromoted {
                    promotedRepairSection(for: host)
                }
                connectionGroup
                if let host = existingHost {
                    directSection(for: host)
                }
                authGroup
                saveButton
                if let host = existingHost {
                    fingerprintSection(for: host)
                    pairingSection(for: host)
                    RemotePiSection(host: host)
                        .id(host.address)
                    dangerSection(for: host)
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        // 键盘弹出时会挡住「保存并测试连接」：滚动即收起键盘，
        // 避免点了保存却没触发校验。
        .scrollDismissesKeyboard(.immediately)
        .piPageBackground()
        .piDetailNavBar("服务器")
        .onAppear(perform: loadHostIfNeeded)
        // 指纹核对浮层统一由 AppRootView 呈现（DEF-R4-004）：指纹变化可能在后台重连时
        // 触发，不能只在服务器页可见时才有入口。
        // 用就地打开的选择器而不是 `.fileImporter`：复制型选择器会把系统判定为 package 的
        // `.key`（Keynote 类型）置灰，导致私钥文件选不中；选择器本身由透明宿主控制器模态
        // 弹出（把它内嵌成 sheet 内容时，真机上会「看得见但选不中」）。
        .sheet(isPresented: $isPickingKey) {
            PrivateKeyDocumentPicker(
                onPick: { result in
                    if case let .success(url) = result { importKeyFile(url) }
                    isPickingKey = false
                },
                onCancel: { isPickingKey = false }
            )
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $isPastingKey) {
            pasteKeySheet
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let hostID = activeHostID else {
                    dismiss()
                    return
                }
                let name = existingHost?.name ?? "服务器"
                isDeleting = true
                Task { @MainActor in
                    defer { isDeleting = false }
                    if await model.deleteHost(id: hostID) {
                        model.showToast("已删除「\(name)」的本机记录")
                        dismiss()
                    } else {
                        model.showToast(model.saveError ?? "服务器已切换，本次删除未执行")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // R7：只说后果（会失去什么），不写安抚句。
            // 两句各承担一个决定：①本机清什么、凭证在共用 SSH 账户时保留；
            // ②服务器端设备授权不随之撤销（否则用户会以为删除等于吊销）。
            Text(
                "只清本机记录、配对与缓存。\n"
                    + "共用同一 SSH 账户的其他记录会保留凭证；不会撤销服务器授权。"
            )
        }
    }

    /// R7：标题说清对象，message 说清后果。
    private var deleteTitle: String {
        "删除「\(existingHost?.name ?? "这台服务器")」的本机记录？"
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusBanner: some View {
        if connection.isTesting || isSaving {
            PIStatusBanner(kind: .info, text: "正在测试连接")
        }
    }

    // MARK: - 表单

    private var connectionGroup: some View {
        PIGroup("连接") {
            formRow {
                PIFormField(
                    label: "名称",
                    error: errors.name
                ) {
                    TextField("可选，默认用地址", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("servers.name")
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "地址",
                    error: errors.host
                ) {
                    TextField("192.168.1.10", text: $draft.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("servers.host")
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "SSH 端口",
                    error: errors.port
                ) {
                    TextField("22", text: $draft.port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("servers.port")
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "用户名",
                    error: errors.username
                ) {
                    TextField("pi", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("servers.username")
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "PI-adaptor 端口",
                    error: errors.hostPort
                ) {
                    TextField("自动探测", text: $draft.hostPort)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("servers.adaptorPort")
                }
            }
        }
        // U13：保存期间禁止再改连接身份。点击「保存并测试连接」时已冻结整份提交快照，
        // 再让这些字段变化只会误导用户以为新值属于本次提交。
        .disabled(isSaving)
    }

    private var authGroup: some View {
        PIGroup("认证") {
            formRow {
                PIFormField(label: "认证方式", isPill: false) {
                    Picker("认证方式", selection: $draft.authKind) {
                        ForEach(AuthKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("servers.authKind")
                }
            }
            PIRowDivider()
            formRow {
                switch draft.authKind {
                case .password:
                    PIFormField(
                        label: "密码",
                        error: errors.secret
                    ) {
                        SecureField(passwordPlaceholder, text: $draft.secret)
                            .textContentType(.password)
                            .accessibilityIdentifier("servers.password")
                    }
                case .privateKey:
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        PIFormField(
                            label: "私钥文件",
                            error: errors.secret
                        ) {
                            HStack(spacing: PISpacing.s8) {
                                Text(draft.keyFileName ?? (draft.secret.isEmpty ? "未选择文件" : "已载入私钥内容"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("servers.keyFileName")
                                Spacer(minLength: PISpacing.s8)
                                Button(draft.secret.isEmpty ? "选择文件" : "重新选择") {
                                    isPickingKey = true
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("servers.pickKey")
                                // 兜底通道：真机上系统选择器读不到文件时，直接把私钥文本粘进来。
                                Button("粘贴") {
                                    pasteKeyError = nil
                                    isPastingKey = true
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("servers.pasteKey")
                            }
                        }
                        if let message = keyFileError {
                            Text(message)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let info = try? SSHPrivateKeyParser.info(openSSHPrivateKey: draft.secret) {
                            Text(
                                "识别到 \(info.displayName)"
                                    + (info.bits > 0 ? " \(info.bits) 位" : "")
                                    + (info.isEncrypted
                                        ? "，已加密（\(info.cipherName)）：请填写下面的私钥口令"
                                        : "，未加密")
                            )
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if !draft.secret.isEmpty {
                            Button("移除已选择的私钥") {
                                draft.secret = ""
                                draft.keyFileName = nil
                                keyFileError = nil
                            }
                            .buttonStyle(.borderless)
                            .font(PIFont.caption)
                            .accessibilityIdentifier("servers.removeKey")
                        }
                        PIFormField(
                            label: "私钥口令（可选）",
                            error: errors.passphrase
                        ) {
                            SecureField("私钥口令", text: $draft.passphrase)
                                .textContentType(.newPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("servers.passphrase")
                        }
                    }
                }
            }
        }
        // U13：认证方式与凭证同样在保存期间冻结，避免「提交 A、界面显示 B」。
        .disabled(isSaving)
    }

    /// R4：约束写进控件——编辑态留空表示沿用 Keychain 里的旧凭证，不再单独写一行说明。
    private var passwordPlaceholder: String {
        isEditing ? "留空沿用已保存凭证" : "服务器登录密码"
    }

    private var saveButton: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIPrimaryButton(
                title: isSaving ? "正在测试连接…" : "保存并测试连接",
                isEnabled: !isSaving && !isPairing && !isDeleting,
                identifier: "servers.saveAndTest"
            ) {
                saveAndTest()
            }
            if isSaving {
                Text("保存中")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .accessibilityIdentifier("servers.saveFrozenHint")
            }
            if let resultMessage {
                PIInlineMessage(kind: .info, text: "测试结果：\(resultMessage)")
            }
        }
    }

    private func formRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
    }

    // MARK: - 指纹

    private func fingerprintSection(for host: HostRecord) -> some View {
        // 展示与删除必须绑定同一个「已保存身份」。之前展示用 draft 账号、删除用
        // host 账号：编辑用户名/地址/端口后，两个账号都有 pin 时会显示新账号指纹
        // 却删除旧账号 pin，甚至影响共用旧账号的其他记录。
        let savedAccount = KeychainStore.account(
            username: host.username,
            host: host.host,
            port: host.port
        )
        let pinned = KeychainStore.loadHostKey(account: savedAccount)
        return PIGroup("主机指纹") {
            if let pinned {
                PIListRow(
                    title: "已固定",
                    subtitle: pinned.fingerprint,
                    icon: "checkmark.shield",
                    iconTint: PIColor.success,
                    isEnabled: false,
                    showsDivider: true
                )
                PIListRow(
                    title: "移除旧指纹后重新核对",
                    icon: "arrow.counterclockwise",
                    showsChevron: true,
                    showsDivider: false,
                    action: {
                        connection.removeHostKeyPin(
                            account: savedAccount,
                            address: host.address,
                            previousFingerprint: pinned.fingerprint
                        )
                        model.showToast("已移除旧指纹；下次连接需要重新核对")
                    }
                )
                .accessibilityIdentifier("servers.removeHostKey")
            } else {
                PIListRow(
                    title: "尚未固定",
                    icon: "shield.slash",
                    iconTint: PIColor.warning,
                    isEnabled: false,
                    showsDivider: false
                )
            }
        }
    }

    private func directPin(for host: HostRecord) -> DirectTLSTrustPin? {
        UITestFixture.current?.directTrustPin ?? KeychainStore.loadDirectTLSTrustPin(hostID: host.id)
    }

    private func directStatus(for host: HostRecord) -> ConnectionStatus {
        connection.currentCatalogHostID == host.id ? connection.connectionStatus : ConnectionStatus()
    }

    private func canRetryDirect(_ host: HostRecord) -> Bool {
        directStatus(for: host).activeRoute == .ssh
            && connection.state.isOnline
            && directPin(for: host) != nil
            && host.adaptorHostId != nil
            && HostValidator.canonicalDirectEndpoint(host.directEndpoint ?? "") != nil
    }

    private func directSection(for host: HostRecord) -> some View {
        DirectConnectionSection(
            endpoint: $draft.directEndpoint,
            preference: draft.connectionPreference,
            status: directStatus(for: host),
            adaptorHostId: host.adaptorHostId,
            trustPin: directPin(for: host),
            isTrustAuthorized: directPin(for: host) != nil,
            endpointError: errors.directEndpoint,
            isBusy: isSaving || isPairing,
            canAuthorize: host.pairedAt != nil,
            authorizationDisabledReason: host.pairedAt == nil ? "请先完成可信 SSH 配对" : nil,
            canRetryDirect: canRetryDirect(host),
            retryDisabledReason: "仅当 SSH 在线且 endpoint、pin、hostId 已验证时可重试",
            onPreferenceChange: changeDirectPreference,
            onAuthorize: { push(.installAdaptor(host.id)) },
            onRetryDirect: {
                Task { await connection.retryDirect(record: host) }
            }
        )
    }

    private func changeDirectPreference(_ preference: ConnectionPreference) {
        guard let host = existingHost else { return }
        switch preference {
        case .sshOnly:
            draft.connectionPreference = .sshOnly
            model.setConnectionPreference(id: host.id, preference: .sshOnly)
            Task { await model.setCurrentHost(id: host.id) }
        case .directPreferred:
            if directStatus(for: host).activeRoute == .direct {
                draft.connectionPreference = .directPreferred
                return
            }
            guard canRetryDirect(host) else {
                pairingMessage = "请先保存合法 endpoint，并经可信 SSH 授权 pin 与 hostId"
                return
            }
            draft.connectionPreference = .directPreferred
            Task { await connection.retryDirect(record: host) }
        }
    }

    // MARK: - PI-adaptor 连接与危险区

    private func pairingPolicy(for host: HostRecord) -> PairingEntryPolicy {
        PairingEntryPolicy(
            hasDeviceToken: KeychainStore.loadDeviceToken(hostID: host.id) != nil,
            isPaired: host.pairedAt != nil,
            authFailure: pairingAuthFailure(for: host)
        )
    }

    /// 认证失败分类只对「当前服务器」有效：连接状态属于当前 RACP 连接。
    private func pairingAuthFailure(for host: HostRecord) -> PairingAuthFailure {
        guard connection.currentCatalogHostID == host.id else { return .none }
        return PairingEntryPolicy.authFailure(from: connection.connectionStatus)
    }

    /// U17：连接被服务器拒绝（令牌失效 / 设备撤销）时，把就地重新配对入口提到页面最前面并解释。
    @ViewBuilder
    private func promotedRepairSection(for host: HostRecord) -> some View {
        let policy = pairingPolicy(for: host)
        PIStatusBanner(
            kind: .danger,
            text: policy.repairTitle,
            detail: policy.repairExplanation,
            actionTitle: isRepairingWithNewToken ? nil : policy.repairActionTitle,
            action: { isRepairingWithNewToken = true }
        )
        .accessibilityIdentifier("servers.pairing.repairBanner")
        if isRepairingWithNewToken {
            PIGroup("重新配对") {
                pairingTokenForm(for: host, actionTitle: repairButtonTitle)
                    .accessibilityIdentifier("servers.pairing.repairForm")
            }
        }
    }

    private func pairingSection(for host: HostRecord) -> some View {
        let policy = pairingPolicy(for: host)
        return PIGroup("PI-adaptor 连接") {
            PIListRow(
                title: "安装或修复 PI-adaptor",
                icon: "shippingbox",
                iconTint: PIColor.accent,
                isEnabled: !isSaving && !isPairing && !isDeleting,
                showsChevron: true,
                showsDivider: true,
                action: { push(.installAdaptor(host.id)) }
            )
            .accessibilityIdentifier("servers.install")
            if policy.hasDeviceToken {
                PIListRow(
                    title: "已保存设备令牌",
                    subtitle: connection.state.displayText,
                    icon: "key",
                    iconTint: PIColor.success,
                    isEnabled: false,
                    showsDivider: true
                )
                .accessibilityIdentifier("servers.pairing.tokenState")
                PIListRow(
                    title: "连接 PI-adaptor",
                    subtitle: host.hostPort.map { "127.0.0.1:\($0)" },
                    icon: "bolt",
                    iconTint: PIColor.accent,
                    isEnabled: !isSaving && !isPairing && !isDeleting,
                    showsChevron: true,
                    showsDivider: true,
                    action: { connectExisting(host) }
                )
                .accessibilityIdentifier("servers.connect")
                // U17：有设备令牌时也提供「使用新的一次性令牌重新配对」。
                // 失败被拒绝时该入口已在页面顶部展开，这里不再重复一份表单。
                if policy.showsRepairEntry, !policy.isRepairPromoted {
                    if isRepairingWithNewToken {
                        pairingTokenForm(for: host, actionTitle: repairButtonTitle)
                            .accessibilityIdentifier("servers.pairing.repairForm")
                    } else {
                        PIListRow(
                            title: policy.repairActionTitle,
                            subtitle: policy.repairRowSubtitle,
                            icon: "arrow.triangle.2.circlepath",
                            iconTint: PIColor.warning,
                            isEnabled: !isSaving && !isPairing && !isDeleting,
                            showsChevron: true,
                            showsDivider: false,
                            action: { isRepairingWithNewToken = true }
                        )
                        .accessibilityIdentifier("servers.pairing.repair")
                    }
                }
            } else {
                pairingTokenForm(for: host, actionTitle: "配对并连接")
                    .accessibilityIdentifier("servers.pairing.form")
            }
            if let pairingMessage {
                Text(pairingMessage)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PISpacing.s16)
                    .padding(.vertical, PISpacing.s12)
                    .accessibilityIdentifier("servers.pairing.message")
            }
        }
    }

    /// 同一套令牌表单：首次配对与「用新令牌重新配对」共用，不新建页面。
    private func pairingTokenForm(for host: HostRecord, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIFormField(
                label: "一次性配对令牌"
            ) {
                SecureField("ppt2.…", text: $pairingToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isPairing || isSaving)
                    .accessibilityIdentifier("servers.pairing.token")
            }
            PIPrimaryButton(
                title: actionTitle,
                isEnabled: !isPairing && !isSaving && !isDeleting,
                identifier: "servers.pairing.submit"
            ) {
                pairAndConnect(host)
            }
            .disabled(pairingToken.piTrimmed.isEmpty)
            if isPairing {
                Text("正在配对")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
    }

    private var repairButtonTitle: String {
        isPairing ? "正在配对…" : "重新配对并连接"
    }

    private func pairAndConnect(_ host: HostRecord) {
        guard !isPairing, !isSaving, !isDeleting else { return }
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            pairingMessage = "本机没有可用凭证：请先保存并测试连接"
            return
        }
        // U17：令牌在成功前不丢弃——失败时用户不需要重新输入，旧设备令牌也不被覆盖
        // （`ConnectionModel.pair` 只在服务器确认成功后写 Keychain）。
        let token = pairingToken.piTrimmed
        guard !token.isEmpty else {
            pairingMessage = "请先输入新的一次性配对令牌"
            return
        }
        isPairing = true
        pairingMessage = nil
        let operationGeneration = model.beginHostOperation(hostID: host.id)
        Task {
            do {
                try await connection.pair(
                    record: host,
                    credential: credential,
                    pairingToken: token
                )
                model.markHostPaired(id: host.id)
                await MainActor.run {
                    pairingToken = ""
                    isRepairingWithNewToken = false
                    pairingMessage = "配对成功；设备令牌已保存"
                }
                if model.canApplyHostOperation(operationGeneration, hostID: host.id) {
                    await model.setCurrentHost(id: host.id)
                } else {
                    await MainActor.run {
                        pairingMessage = "配对成功；当前服务器已切换，未自动连接"
                    }
                }
            } catch {
                await MainActor.run {
                    // 失败只报原因与下一步：旧设备令牌仍保留，本次输入也留在输入框里可重试。
                    pairingMessage = "配对失败：\(ConnectionErrorText.describe(error))；"
                        + "旧设备令牌仍保留，可重试；令牌过期请重启 PI-adaptor 取新令牌"
                }
                if model.canApplyHostOperation(operationGeneration, hostID: host.id),
                   let current = model.currentHost {
                    await model.setCurrentHost(id: current.id)
                }
            }
            await MainActor.run { isPairing = false }
        }
    }

    private func connectExisting(_ host: HostRecord) {
        pairingMessage = nil
        Task {
            await model.setCurrentHost(id: host.id)
        }
    }

    private func dangerSection(for host: HostRecord) -> some View {
        PIGroup("危险操作") {
            PIDangerRow(
                title: "删除这台服务器",
                isEnabled: !isSaving && !isPairing && !isDeleting,
                action: { showDeleteConfirm = true }
            )
            .accessibilityIdentifier("servers.delete")
        }
    }

    // MARK: - 行为

    private func loadHostIfNeeded() {
        guard !didLoadHost else { return }
        didLoadHost = true
        if let host = existingHost {
            draft = HostDraft(record: host)
        }
    }

    // MARK: - 私钥文件

    /// 读取并校验所选私钥文件。
    ///
    /// iOS 的沙盒约束：外部文件只在选择回调期间可访问（security-scoped），所以这里一次性读入内存，
    /// 校验通过后只保留「文件名 + 私钥文本」。连接时用 Keychain 里的内容，不再依赖原文件路径。
    ///
    /// `url` 由选择器在委托回调里复制到沙盒临时目录，所以这里读到的是普通文件：
    /// 不再有 file provider 安全作用域过期的问题，读完顺手把这份临时副本删掉。
    private func importKeyFile(_ url: URL) {
        defer {
            let directory = url.deletingLastPathComponent()
            if directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do {
            let file = try SSHPrivateKeyFileLoader.load(contentsOf: url)
            draft.secret = file.text
            draft.keyFileName = file.fileName
            errors.secret = nil
            keyFileError = file.info.isEncrypted && draft.passphrase.isEmpty
                ? "这把私钥带口令保护（\(file.info.cipherName)）：请填写下面的私钥口令"
                : nil
        } catch let error as SSHPrivateKeyFileError {
            // 读不到 / 空 / 过大 / 不是私钥：只报原因，不覆盖已选或已保存的私钥。
            keyFileError = error.description
        } catch {
            keyFileError = "读取私钥文件失败：\(error.localizedDescription)"
        }
    }

    /// 粘贴私钥的兜底通道（真机上系统选择器读不到文件时用）。
    ///
    /// 与文件选择同一条校验路径（`SSHPrivateKeyFileLoader.load`），所以格式错误、
    /// 带 WiFi 口令提示等行为完全一致。文本只在内存里流转，进 Keychain，不落盘、不写日志。
    private var pasteKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedKeyText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("servers.pasteKey.text")
                    // 错误只作为一行原因出现在输入框下面；quiet-v2 不再用分组 footer 承载说明。
                    // 独立标识：弹层固定有「私钥全文…」标题，按“含私钥”查文本会把标题
                    // 当成错误提示，导致导入完全不生效也能通过。
                    if let message = pasteKeyError {
                        Text(message)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("servers.pasteKey.error")
                    }
                } header: {
                    Text("私钥全文（以 -----BEGIN 开头）")
                }
            }
            .scrollContentBackground(.hidden)
            .piPageBackground()
            .navigationTitle("粘贴私钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPastingKey = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { applyPastedKey() }
                        .accessibilityIdentifier("servers.pasteKey.import")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyPastedKey() {
        defer { pastedKeyText = "" }
        let trimmed = pastedKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pasteKeyError = "先粘贴私钥全文。"
            return
        }
        do {
            let file = try SSHPrivateKeyFileLoader.load(
                fileName: "pasted-key",
                data: Data(trimmed.utf8)
            )
            draft.secret = file.text
            draft.keyFileName = file.fileName
            errors.secret = nil
            pasteKeyError = nil
            keyFileError = file.info.isEncrypted && draft.passphrase.isEmpty
                ? "这把私钥带口令保护（\(file.info.cipherName)）：请填写下面的私钥口令"
                : nil
            isPastingKey = false
        } catch let error as SSHPrivateKeyFileError {
            pasteKeyError = error.description
        } catch {
            pasteKeyError = "导入失败：\(error.localizedDescription)"
        }
    }

    private func saveAndTest() {
        guard !isSaving, !isPairing, !isDeleting else { return }

        // U13：点击瞬间冻结整份提交快照。之后校验、Keychain 账号、凭证、身份变化判断、
        // 记录更新与连接测试一律只读 `intent`，不再读实时 `draft` / 实时记录。
        let submittedDraft = draft
        let submittedExisting = existingHost
        let submittedIsEditing = isEditing
        let submittedRequiresSecret = !submittedIsEditing
            || submittedExisting?.authKind != submittedDraft.authKind
        let validation = HostValidator.validate(
            submittedDraft,
            requiresSecret: submittedRequiresSecret
        )
        errors = validation
        guard validation.isValid else { return }

        let submittedHostID = activeHostID
        let account = KeychainStore.account(
            username: submittedDraft.username.piTrimmed,
            host: submittedDraft.host.piTrimmed,
            port: Int(submittedDraft.port.piTrimmed) ?? submittedExisting?.port ?? 22
        )
        let typed = submittedDraft.secret.piTrimmed
        let credential: SSHCredential?
        if typed.isEmpty {
            credential = KeychainStore.loadCredential(account: account)
        } else {
            credential = submittedDraft.authKind == .password
                ? .password(submittedDraft.secret)
                : .privateKey(
                    openSSHText: submittedDraft.secret,
                    passphrase: submittedDraft.passphrase.isEmpty ? nil : submittedDraft.passphrase
                )
        }
        guard let credential else {
            errors.secret = submittedDraft.authKind == .password ? "请填写服务器密码" : "请粘贴私钥内容"
            resultMessage = nil
            return
        }

        let intent = HostSaveIntent.freeze(
            hostID: submittedHostID,
            draft: submittedDraft,
            existing: submittedExisting,
            account: account,
            credential: credential
        )
        isSaving = true
        resultMessage = nil
        Task { @MainActor in
            defer { isSaving = false }

            var identityGeneration: Int?
            if intent.requiresReconnect, let hostID = intent.hostID {
                identityGeneration = await model.prepareHostIdentityChange(id: hostID)
            }
            defer {
                if let hostID = intent.hostID, let identityGeneration {
                    model.finishHostIdentityChange(id: hostID, generation: identityGeneration)
                }
            }

            // 代次核验之一（记录更新前）：准备阶段丢失代次说明服务器已被切走，不得再写记录。
            if let hostID = intent.hostID,
               !intent.canApplyIdentityChange(
                   identityGeneration: identityGeneration,
                   isValid: { model.canApplyHostIdentityChange(id: hostID, generation: $0) }
               ) {
                resultMessage = "服务器已切换：本次保存未提交，请重新保存一次"
                return
            }

            let record: HostRecord
            if let hostID = intent.hostID {
                guard model.updateHost(id: hostID, with: intent.draft),
                      let updated = model.hosts.first(where: { $0.id == hostID })
                else {
                    // 记录没更新成功就不测试：避免界面、Keychain 与测试结果分属不同记录。
                    errors = intent.validationErrors
                    resultMessage = model.saveError ?? "本机记录更新失败：本次没有测试连接"
                    return
                }
                record = updated
            } else {
                guard let added = model.addHost(intent.draft) else {
                    errors = intent.validationErrors
                    resultMessage = model.saveError ?? "本机记录保存失败：本次没有测试连接"
                    return
                }
                // 转入该记录的编辑态：再次保存必须更新它，而不是新建第二条。
                self.createdHostID = added.id
                record = added
            }

            // 代次核验之二（连接测试前）：记录更新期间服务器被切走就不发起测试连接。
            if let hostID = intent.hostID,
               !intent.canApplyIdentityChange(
                   identityGeneration: identityGeneration,
                   isValid: { model.canApplyHostIdentityChange(id: hostID, generation: $0) }
               ) {
                resultMessage = "服务器已切换：记录已按本次提交保存，但未测试连接"
                return
            }

            if !typed.isEmpty {
                let status = KeychainStore.saveCredentialStatus(
                    intent.credential,
                    kind: intent.draft.authKind,
                    account: intent.account
                )
                guard status == errSecSuccess else {
                    errors.secret = KeychainStore.describe(status)
                    resultMessage = "服务器记录已保存，凭证未能写入 Keychain"
                    return
                }
            }

            let message = await connection.testConnection(record: record, credential: intent.credential)
            if intent.requiresReconnect,
               let hostID = intent.hostID,
               let identityGeneration,
               message.hasPrefix("SSH 连接成功"),
               model.canApplyHostIdentityChange(id: hostID, generation: identityGeneration) {
                await model.setCurrentHost(id: hostID)
            }
            resultMessage = message
            model.showToast("已保存「\(intent.displayName)」")
        }
    }
}

// MARK: - 指纹核对页（S-04「核对指纹」）

struct HostKeyConfirmSheet: View {
    let prompt: HostKeyPrompt
    let onConfirm: (HostKeyConfirmation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text(prompt.status == .firstUse ? "核对主机指纹" : "主机指纹已变化")
                    .font(PIFont.navTitle)
                    .foregroundStyle(PIColor.text)
                Text(prompt.address)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            }

            if case .changed(let pinned) = prompt.status {
                PIStatusBanner(
                    kind: .danger,
                    text: "指纹与固定记录不一致，连接已被拒绝",
                    detail: "原指纹：\(pinned.fingerprint)。若确实重装过服务器，先在服务器页移除旧指纹，再重新核对。"
                )
            }

            PIGroup("SHA256 指纹") {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    Text(prompt.key.fingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(PIColor.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("算法：\(prompt.key.algorithm)　请与服务器 `ssh-keygen -lf` 的输出逐字比对。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
            }

            Spacer(minLength: 0)

            if case .changed = prompt.status {
                // DEF-R4-004 / AC-02.2：指纹变化不提供「信任」入口，只能取消连接。
                PIPrimaryButton(title: "取消（不建立连接）") {
                    onConfirm(.reject)
                    dismiss()
                }
            } else {
                PIPrimaryButton(title: "指纹一致，信任这台服务器") {
                    onConfirm(.trust)
                    dismiss()
                }
                .accessibilityIdentifier("servers.hostKey.trust")
                PISecondaryButton(title: "取消（不建立连接）") {
                    onConfirm(.reject)
                    dismiss()
                }
                .accessibilityIdentifier("servers.hostKey.cancel")
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .piPageBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
        .interactiveDismissDisabled()
    }
}
