import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import CoreTransferable
import ImageIO
import PIiOSCore
import PIiOSNet

extension ConversationScreen {
    // MARK: - 输入栏

    var composer: some View {
        // Read the main-actor-isolated admission into a plain value once: the
        // PhotosPicker label runs in a Sendable closure and must not touch
        // `session` directly (Swift 6).
        let allowsAttachments = session.sendAdmission.isAllowed
        return VStack(alignment: .leading, spacing: PISpacing.s8) {
            composerConfigurationChips
            if isReadingPhotos {
                ProgressView("正在处理图片 \(photoReadCompletedCount)/\(photoReadTotalCount)",
                             value: Double(photoReadCompletedCount), total: Double(max(1, photoReadTotalCount)))
                    .font(PIFont.meta)
                    .accessibilityIdentifier("composer.photoReadProgress")
            }
            if let notice = photoReadFailureNotice {
                HStack(alignment: .top, spacing: PISpacing.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.warning)
                        .accessibilityHidden(true)
                    Text(notice)
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("composer.photoReadFailure")
                    Spacer(minLength: PISpacing.s4)
                    if photoReadNeedsConfirmation {
                        // U16：部分失败时不允许无提示发送子集，必须显式确认。
                        Button("仍要发送已读取的图片") {
                            photoReadAcknowledged = true
                        }
                        .font(PIFont.metaSmall.weight(.semibold))
                        .foregroundStyle(PIColor.accent)
                        .accessibilityIdentifier("composer.confirmPartialPhotos")
                    } else if photoReadSucceededCount == 0 {
                        // 全部失败：给出明确的关闭入口，保留“失败可见”而不是静默跳过。
                        Button("知道了") {
                            photoReadFailureCount = 0
                        }
                        .font(PIFont.metaSmall.weight(.semibold))
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("composer.dismissPhotoReadFailure")
                    }
                }
            }
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PISpacing.s8) {
                        ForEach(session.pendingAttachments, id: \.id) { attachment in
                            HStack(spacing: PISpacing.s4) {
                                Image(systemName: "photo")
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Button {
                                    session.removeAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除附件")
                                .accessibilityIdentifier("composer.removeAttachment.\(attachment.id)")
                            }
                            .font(PIFont.meta)
                            .padding(.horizontal, PISpacing.s8)
                            .padding(.vertical, PISpacing.s4)
                            .background(PIColor.surface2, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: PISpacing.s8) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(allowsAttachments ? PIColor.text : PIColor.text3)
                        .frame(width: 36, height: 36)
                        .background(PIColor.surface3, in: Circle())
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Circle())
                }
                .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                .accessibilityLabel("添加图片附件")
                .accessibilityHint("最多选择 10 张 JPEG、PNG 或 WebP 图片")
                .onChange(of: selectedPhotos) { items in
                    guard !items.isEmpty else { return }
                    let selection = session.attachmentSelectionGeneration
                    let photoSelection = UUID()
                    photoSelectionID = photoSelection
                    photoReadFailureCount = 0
                    photoReadSucceededCount = 0
                    photoReadAcknowledged = false
                    isReadingPhotos = true
                    photoReadCompletedCount = 0
                    photoReadTotalCount = items.count
                    Task {
                        var failed = 0
                        var succeeded = 0
                        for item in items {
                            guard session.attachmentSelectionGeneration == selection,
                                  photoSelectionID == photoSelection else { break }
                            // U16：读取失败不再静默跳过；计数后在输入栏上方明确呈现，
                            defer {
                                if photoSelectionID == photoSelection { photoReadCompletedCount += 1 }
                            }
                            // 部分失败必须确认后才能发送已读取的子集。
                            let data: Data
                            do {
                                guard let loaded = try await item.loadTransferable(type: Data.self) else {
                                    failed += 1
                                    continue
                                }
                                data = loaded
                            } catch {
                                failed += 1
                                continue
                            }
                            guard let mime = imageMimeType(data) else {
                                // 不支持解码的格式（例如 HEIC）不能直接标成 JPEG。
                                failed += 1
                                continue
                            }
                            let ext = mime == "image/png" ? "png" : (mime == "image/webp" ? "webp" : "jpg")
                            let added = await session.addImage(
                                data: data,
                                mimeType: mime,
                                fileName: "photo-\(UUID().uuidString).\(ext)"
                            )
                            if added { succeeded += 1 } else { failed += 1 }
                        }
                        guard session.attachmentSelectionGeneration == selection,
                              photoSelectionID == photoSelection else {
                            if photoSelectionID == photoSelection { isReadingPhotos = false }
                            return
                        }
                        isReadingPhotos = false
                        photoReadFailureCount = failed
                        photoReadSucceededCount = succeeded
                        photoReadAcknowledged = false
                        selectedPhotos = []
                    }
                }
                // 占位文字自己画、自己对齐：原生 placeholder 跟着输入框内部基线走，
                // 单行时看起来比左右按钮低一点。输入框固定 44pt 高后，占位和实际
                // 文字都在这条中线上，空态、输入态、换行态不会各偏各的。
                TextField("", text: $session.draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .frame(minHeight: PIMetrics.minHitTarget)
                    .overlay(alignment: .leading) {
                        if session.draftText.isEmpty {
                            Text("给 Agent 的指令")
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text3)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                    .accessibilityLabel("给 Agent 的指令")
                    .accessibilityIdentifier("conversation.composer")
                Button {
                    if showsAbortButton {
                        Task { await session.interrupt() }
                    } else {
                        guard !isSubmitting, let intent = session.makeSendIntent() else { return }
                        let submission = UUID()
                        submissionID = submission
                        scrollToBottomRequest &+= 1
                        // U11：点击瞬间冻结发送意图；模型可用性检查可能等待网络，
                        // 期间切换会话/模型或继续编辑都由 send(expected:) 拒绝，不会误发。
                        let instruction = session.trimmedDraft
                        let isFirstInstruction = session.view.items.isEmpty
                        // Freeze the title target at click time. Reading it after the
                        // send await could generate a title for a newly switched session.
                        let titleSessionID = session.attachedSessionId
                        let titleHostID = model.currentHost?.id
                        let titleGeneration = connection.currentConnectionGeneration
                        Task {
                            defer {
                                if submissionID == submission { submissionID = nil }
                            }
                            let check = await refreshModelAvailability(reuseRecent: true)
                            guard check != .superseded else { return }
                            await session.send(expected: intent)
                            if submissionID == submission { submissionID = nil }
                            // 新建会话不再预填标题：首条指令成功发出后由 AI 生成。
                            if isFirstInstruction, session.trimmedDraft.isEmpty,
                               let titleSessionID, let titleHostID {
                                await generateTitleIfNeeded(
                                    instruction: instruction,
                                    hostID: titleHostID,
                                    sessionID: titleSessionID,
                                    connectionGeneration: titleGeneration
                                )
                            }
                        }
                    }
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(PIColor.onAccent)
                        } else {
                            Image(systemName: showsAbortButton ? "stop.fill" : "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                        .foregroundStyle(sendButtonEnabled ? PIColor.onAccent : PIColor.text3)
                        .frame(width: 36, height: 36)
                        .background(
                            (sendButtonEnabled || isSubmitting)
                                ? (showsAbortButton ? PIColor.danger : PIColor.accent)
                                : PIColor.surface3,
                            in: Circle()
                        )
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Circle())
                }
                .disabled(!sendButtonEnabled)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier(showsAbortButton ? "conversation.interrupt" : "conversation.send")
                .accessibilityLabel(isSubmitting ? "正在提交" : (showsAbortButton ? "中止" : "发送"))
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(
                PIColor.surface2,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PIColor.separatorStrong, lineWidth: PIMetrics.hairline)
            )
            .shadow(color: PIColor.floatingShadow, radius: 14, y: 5)
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, PISpacing.s8)
        .background(PIColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(height: PIMetrics.hairline)
        }
    }

    /// 用 ImageIO 判定真实格式，不能按扩展名或「非 PNG 即 JPEG」猜测。
    /// 只接受上传协议支持的 JPEG/PNG/WebP；HEIC 等返回 nil 由调用方明确拒绝。
    func imageMimeType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.jpeg", "public.jpeg-2000": return "image/jpeg"
        case "public.png": return "image/png"
        case "org.webmproject.webp": return "image/webp"
        default: return nil
        }
    }

    /// 发送按钮可用性：附件部分读取失败且未确认时禁止发送（U16）。
    var canTapSend: Bool {
        session.canSend && !session.isBusy && !isSubmitting && !isReadingPhotos && !photoReadNeedsConfirmation
    }

    /// 输入框为空且会话有任务正在执行时，发送按钮切换成中止按钮；
    /// 一旦输入了内容（文字或附件），仍然保留发送按钮，点击即排队。
    var showsAbortButton: Bool {
        session.isTurnRunning
            && session.trimmedDraft.isEmpty
            && session.pendingAttachments.isEmpty
    }

    var sendButtonEnabled: Bool {
        !isSubmitting && (showsAbortButton
            ? session.canInterrupt && !session.isBusy
            : canTapSend)
    }

    /// 最近一次选图的读取失败提示；`nil` 表示没有失败。
    var photoReadFailureNotice: String? {
        guard photoReadFailureCount > 0 else { return nil }
        if photoReadSucceededCount > 0 {
            return "\(photoReadFailureCount) 张图片读取失败，已读取 \(photoReadSucceededCount) 张"
        }
        return "全部图片读取失败（\(photoReadFailureCount) 张），请重新选择图片。"
    }

    /// 部分失败且未确认：必须显式确认才能发送已读取的子集。
    var photoReadNeedsConfirmation: Bool {
        photoReadFailureCount > 0 && photoReadSucceededCount > 0 && !photoReadAcknowledged
    }

    /// 保留异常时直接打开会话模型配置的入口；无绑定文案只改成中性名称，不复述错误。
    var composerModelLabel: String {
        if selectedModelLabel == "模型未绑定" {
            switch session.modelAvailability {
            case .unavailable, .unknown:
                return "会话模型"
            default:
                break
            }
        }
        return selectedModelLabel
    }

    var composerConfigurationChips: some View {
        HStack(spacing: PISpacing.s8) {
            // 会话模式 / 权限模式不再压在输入框上方：它们仍可在「会话操作 →
            // 会话配置」里查看与切换，输入区只保留与本次发送直接相关的模型信息。
            Spacer(minLength: PISpacing.s4)
            configurationChip(
                title: composerModelLabel,
                tint: PIColor.text2,
                identifier: "composer.modelChip",
                systemImage: "cpu",
                maxWidth: 190,
                alignment: .trailing
            )
            if session.thinkingLevel != nil, selectedModelDeclaresThinking {
                configurationChip(
                    title: session.thinkingLevel?.rawValue ?? "",
                    tint: PIColor.text2,
                    identifier: "composer.thinkingChip",
                    systemImage: "brain.head.profile"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func configurationChip(
        title: String,
        tint: Color,
        identifier: String,
        systemImage: String? = nil,
        maxWidth: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Button {
            showingConfig = true
        } label: {
            HStack(spacing: PISpacing.s4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 0 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .font(PIFont.metaSmall.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, PISpacing.s8)
            .frame(minHeight: 30)
            .frame(maxWidth: maxWidth, alignment: alignment)
            // 输入区已有唯一外框，模型入口作为轻量文本控件，不再叠第二层胶囊描边。
            // 视觉 30pt 高，热区补足到 44pt（spec AC-7）。
            .padding(.vertical, (PIMetrics.minHitTarget - 30) / 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            session.isTurnRunning
                || session.isBusy
                || !connection.state.isOnline
                || session.attachedSessionId == nil
        )
        .accessibilityIdentifier(identifier)
        .accessibilityHint(
            session.isTurnRunning
                ? "等待当前轮次结束后才能切换"
                : (session.isBusy ? "等待当前操作完成" : "打开会话配置")
        )
    }

    /// 收起键盘：输入框没有 `@FocusState`，直接让当前第一响应者 resign。
    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    var selectedModelDeclaresThinking: Bool {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return false }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return !record.thinkingLevels.isEmpty
            }
        }
        return false
    }

    /// 新建会话的首条指令发出后，让服务器用当前模型生成一个短标题。
    ///
    /// 已经是用户命名 / 已生成过标题的会话不会再调用；旧版 PI-adaptor 没有
    /// `session/suggest-title` 时会退回指令首行，避免会话一直叫「New session」。
    func generateTitleIfNeeded(
        instruction: String,
        hostID: UUID,
        sessionID: String,
        connectionGeneration: Int
    ) async {
        guard model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID,
              connection.currentConnectionGeneration == connectionGeneration
        else { return }
        let current = model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: sessionID,
            fallback: session.attachedSummary?.title ?? ""
        )
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCurrent.isEmpty
            || normalizedCurrent == "New session"
            || normalizedCurrent == "新会话"
        else { return }

        // 没有绑定的 provider/model 时不调用服务器：直接用指令首行兜底，
        // 不让新会话一直停留在「新会话」。
        var title: String?
        if let providerID = session.selectedProviderId,
           let modelID = session.selectedModelId {
            let credential = session.providerCredential?(providerID)
            let binding = credential?.baseURL.flatMap { baseURL in
                baseURL.isEmpty ? nil : RACPProviderKeyBinding(providerId: providerID, baseUrl: baseURL)
            }
            do {
                title = try await connection.suggestSessionTitle(
                    sessionId: sessionID,
                    instruction: instruction,
                    providerId: providerID,
                    modelId: modelID,
                    apiKey: binding == nil ? nil : credential?.value,
                    providerBinding: binding,
                    thinkingLevel: session.thinkingLevel?.rawValue
                )
            } catch {
                title = nil
            }
        }
        let cleaned = sanitizedTitle(title) ?? localFallbackTitle(instruction)
        guard !cleaned.isEmpty else { return }
        // The user may have renamed the session or switched away while the
        // suggestion was in flight; never overwrite a manual title.
        guard model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID,
              connection.currentConnectionGeneration == connectionGeneration
        else { return }
        let latest = model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: sessionID,
            fallback: session.attachedSummary?.title ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard latest.isEmpty || latest == "New session" || latest == "新会话" else { return }
        guard model.renameSession(hostID: hostID, sessionID: sessionID, title: cleaned) else { return }
        // 本机标题先生效；服务器写入失败不回滚本机名称，下次打开仍能看到。
        try? await connection.renameSession(sessionId: sessionID, title: cleaned)
    }

    func sanitizedTitle(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’。.，,：:；;"))
        value = value.replacingOccurrences(of: "\n", with: " ")
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count <= 30 ? collapsed : String(collapsed.prefix(30)) + "…"
    }

    func localFallbackTitle(_ instruction: String) -> String {
        let firstLine = instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? instruction
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        return collapsed.count <= 24 ? collapsed : String(collapsed.prefix(24)) + "…"
    }

}

private struct AttachmentReadSource {
    let key: AttachmentImageKey
    let read: AttachmentImageLoader.Read

    static func current(attachment: RACPV2Attachment, hostID: UUID?, client: RACPClient?) -> Self? {
        guard let hostID else { return nil }
        if let client {
            return Self(
                key: AttachmentImageKey(hostID: hostID, connectionID: ObjectIdentifier(client), attachment: attachment),
                read: { offset, length in
                    try await client.readImageAttachment(attachmentId: attachment.id, offset: offset, length: length)
                }
            )
        }
#if DEBUG
        if let fixture = UITestFixture.stabilityImageSource(attachment: attachment, hostID: hostID) {
            return Self(key: fixture.key, read: fixture.read)
        }
#endif
        return nil
    }
}

struct AttachmentThumbnailView: View {
    let attachment: RACPV2Attachment
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDetail = false
    @State private var loadID = UUID()

    private var source: AttachmentReadSource? {
        AttachmentReadSource.current(attachment: attachment, hostID: model.currentHost?.id, client: connection.activeClient)
    }

    private var key: AttachmentImageKey? { source?.key }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(PIRadius.control)
                    .onTapGesture { showingDetail = true }
                    .accessibilityLabel("查看图片")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("conversation.attachment.\(attachment.id)")
            } else if isLoading {
                ProgressView().frame(height: 100)
            } else if loadFailed {
                Label("图片加载失败", systemImage: "exclamationmark.triangle")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.danger)
                    .accessibilityIdentifier("conversation.attachment.\(attachment.id).error")
            } else {
                Label(attachment.fileName, systemImage: "photo")
                    .font(PIFont.meta)
                    .padding(PISpacing.s8)
                    .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control))
            }
        }
        .task(id: key) { await loadImage() }
        .onChange(of: key) { _, newKey in
            if newKey == nil {
                showingDetail = false
            }
        }
        .onDisappear {
            loadID = UUID()
            uiImage = nil
            isLoading = false
            showingDetail = false
        }
        .sheet(isPresented: $showingDetail) {
            if let source {
                AttachmentImageDetail(attachment: attachment, key: source.key, read: source.read, session: connection.session)
            } else {
                Color.clear
                    .onAppear { showingDetail = false }
            }
        }
    }

    private func loadImage() async {
        let requestID = UUID()
        loadID = requestID
        uiImage = nil
        loadFailed = false
        isLoading = false
        guard let source else { return }
        let key = source.key
        isLoading = true
        defer { if loadID == requestID { isLoading = false } }
        do {
            let bitmap = try await AttachmentImageLoader.shared.thumbnail(key: key, attachment: attachment, read: source.read)
            guard !Task.isCancelled, loadID == requestID, self.key == key else { return }
            uiImage = UIImage(cgImage: bitmap.image)
        } catch is CancellationError {
            // A disappearing row has no failure to present.
        } catch {
            guard !Task.isCancelled, loadID == requestID, self.key == key else { return }
            loadFailed = true
        }
    }
}

private struct AttachmentImageDetail: View {
    let attachment: RACPV2Attachment
    let key: AttachmentImageKey
    let read: AttachmentImageLoader.Read
    @ObservedObject var session: SessionController
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: AttachmentImageContent?
    @State private var failed = false

    private var isCurrent: Bool {
        session.attachedSessionId == key.sessionID
            && AttachmentReadSource.current(attachment: attachment, hostID: model.currentHost?.id,
                                            client: connection.activeClient)?.key == key
    }

    var body: some View {
        NavigationStack {
            VStack {
                if let content {
                    let image = Image(uiImage: UIImage(cgImage: content.bitmap.image))
                    image.resizable().scaledToFit().padding()
                        .accessibilityIdentifier("conversation.attachment.detailImage")
                        .accessibilityLabel("原图")
#if DEBUG
                    Text(verbatim: "width=\(content.bitmap.image.width),height=\(content.bitmap.image.height),bytes=\(content.original.count)")
                        .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                        .accessibilityIdentifier("conversation.attachment.debugDetailContent")
#endif
                    shareLink(for: content, previewImage: image)
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .accessibilityIdentifier("conversation.attachment.shareOriginal")
                } else if failed {
                    Label("图片加载失败", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("正在读取原图…")
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { dismiss() }
                    .accessibilityIdentifier("conversation.attachment.closeDetail")
            }
        }
        .task(id: isCurrent) {
            guard isCurrent else { content = nil; dismiss(); return }
            do {
                let loaded = try await AttachmentImageLoader.shared.detail(attachment: attachment, read: read)
                guard !Task.isCancelled, isCurrent else { return }
                content = loaded
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, isCurrent { failed = true }
            }
        }
        .onDisappear { content = nil }
    }

    @ViewBuilder
    private func shareLink(
        for content: AttachmentImageContent,
        previewImage: Image
    ) -> some View {
        let format = AttachmentShareFormat(
            mimeType: attachment.mimeType,
            fileName: attachment.fileName
        )
        let fileName = format.normalizedFileName(attachment.fileName)
        let preview = SharePreview(fileName, image: previewImage)
        switch format {
        case .png:
            ShareLink(
                item: AttachmentOriginal<PNGOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        case .jpeg:
            ShareLink(
                item: AttachmentOriginal<JPEGOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        case .webp:
            ShareLink(
                item: AttachmentOriginal<WebPOriginalContentType>(
                    data: content.original,
                    fileName: fileName
                ),
                preview: preview
            ) {
                shareLabel
            }
        }
    }

    private var shareLabel: some View {
        Label("保存或分享图片", systemImage: "square.and.arrow.up")
    }
}

