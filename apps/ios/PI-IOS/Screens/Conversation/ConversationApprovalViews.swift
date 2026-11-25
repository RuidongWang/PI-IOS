import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import CoreTransferable
import ImageIO
import PIiOSCore
import PIiOSNet

extension ConversationScreen {
    // MARK: - 审批（AC-10 / AC-12）

    @ViewBuilder
    var approvalSection: some View {
        ForEach(orderedApprovals, id: \.id) { card in
            let availability = session.availability(for: card.id)
            let isContract = SessionController.isContract(card)
            let canDecide = !(session.isBusy || !connection.state.isOnline)
            let reviewedDigest = reviewedApprovalDigests[card.id].flatMap { $0.revision == card.revision ? $0.digest : nil }
            let canAllow = canDecide && (card.inputByteLength == nil || reviewedDigest != nil)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s12) {
                    HStack(spacing: PISpacing.s8) {
                        // 类型是名词标签，状态用语义色；装饰点删除（quiet-v2 §2）。
                        Text(isContract ? "计划契约" : "权限请求")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                            .accessibilityIdentifier("conversation.approval.\(card.id).kind")
                        Spacer(minLength: PISpacing.s4)
                        if let status = availability.statusText {
                            Text(status)
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.warning)
                        }
                    }
                    Text(summary(of: card))
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if card.inputByteLength != nil {
                        Button("查看完整参数") {
                            approvalFullInput = ApprovalFullInput(id: card.id, title: card.toolName ?? "审批参数", revision: card.revision, card: card)
                        }
                        .font(PIFont.captionStrong)
                        .accessibilityIdentifier("conversation.approval.\(card.id).showFullInput")
                    } else if let full = ApprovalInputPreview.fullText(from: card.payload) {
                        Button("查看完整参数") {
                            approvalFullInput = ApprovalFullInput(
                                id: card.id,
                                title: card.toolName ?? "审批参数",
                                text: full
                            )
                        }
                        .font(PIFont.captionStrong)
                        .accessibilityIdentifier("conversation.approval.\(card.id).showFullInput")
                    }
                    if availability.isActionable {
                        if isContract {
                            HStack(spacing: PISpacing.s8) {
                                PIApprovalPrimaryButton(title: "批准", isEnabled: canDecide) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .approve) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).approve")
                                PIDangerOutlineButton(title: "驳回", isEnabled: canDecide) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .reject) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).reject")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: PISpacing.s8) {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(spacing: PISpacing.s8) {
                                        PIApprovalPrimaryButton(title: "允许一次", isEnabled: canAllow) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowOnce, reviewedInputDigest: reviewedDigest) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowOnce")
                                        PIApprovalSecondaryButton(title: "本会话允许", isEnabled: canAllow) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowSession, reviewedInputDigest: reviewedDigest) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowSession")
                                    }
                                } else {
                                    HStack(spacing: PISpacing.s8) {
                                        PIApprovalPrimaryButton(title: "允许一次", isEnabled: canAllow) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowOnce, reviewedInputDigest: reviewedDigest) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowOnce")
                                        PIApprovalSecondaryButton(title: "本会话允许", isEnabled: canAllow) {
                                            Task { await session.decide(approvalId: card.id, decision: .allowSession, reviewedInputDigest: reviewedDigest) }
                                        }
                                        .accessibilityIdentifier("conversation.approval.\(card.id).allowSession")
                                    }
                                }
                                Divider().padding(.top, PISpacing.s4)
                                PIDangerOutlineButton(title: "拒绝", isEnabled: canDecide) {
                                    Task { await session.decide(approvalId: card.id, decision: .deny) }
                                }
                                .accessibilityIdentifier("conversation.approval.\(card.id).deny")
                            }
                        }
                    } else {
                        Text("已失效，同步后重试")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.approval.\(card.id)")
        }
        ForEach(Array(session.view.expiredApprovalIds).sorted(), id: \.self) { expiredId in
            if session.availability(for: expiredId) == .expired {
                PICard {
                    HStack {
                        Text("审批已失效")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                        Spacer()
                    }
                    .accessibilityIdentifier("conversation.approval.\(expiredId).expired")
                }
            }
        }
    }

    /// 可提交的卡片排在最前：审批卡片区在滚动内容最前面，用户被带过去时第一眼就该能处理它；
    /// 已失效（不在快照里）的卡片沉到后面——AC-14.5 只要求标失效，没有要求保留到达顺序。
    var orderedApprovals: [RACPApprovalRequest] {
        session.pendingApprovals.enumerated()
            .sorted { lhs, rhs in
                let left = session.availability(for: lhs.element.id).isActionable
                let right = session.availability(for: rhs.element.id).isActionable
                if left != right { return left }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func summary(of card: RACPApprovalRequest) -> String {
        // 工具审批必须先让用户看到要执行的命令/参数，再决定是否放行；
        // 只显示工具名会让审批门禁形同虚设。
        var lines: [String] = []
        if let tool = card.toolName { lines.append("工具：\(tool)") }
        if let preview = ApprovalInputPreview.text(from: card.payload) {
            lines.append(preview)
        }
        if !lines.isEmpty { return lines.joined(separator: "\n\n") }
        if let text = card.payload.value(at: ["summary"])?.stringValue { return text }
        if let text = card.payload.value(at: ["detail"])?.stringValue { return text }
        return "服务器没有给出摘要"
    }

    // MARK: - 排队（AC-13）

    @ViewBuilder
    var queueSection: some View {
        if !session.queuedTurns.isEmpty {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                // 总数由常驻状态条表达，这里只标识待发送内容，不重复计数。
                PISectionHeader(text: "待发送")
                    .accessibilityIdentifier("conversation.queueHeader")
                ForEach(session.queuedTurns) { turn in
                    PICard {
                        HStack(spacing: PISpacing.s8) {
                            // 优先显示正文；服务端快照缺正文时显示附件数/排队提示，不显示裸 id。
                            Text(turn.displayText)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .lineLimit(2)
                                .accessibilityIdentifier("conversation.queuedTurnText.\(turn.id)")
                            Spacer(minLength: PISpacing.s8)
                            // 取消是危险动作：danger 文字，不加装饰底色；热区补足 44pt。
                            Button(role: .destructive) {
                                Task { await session.cancelQueued(turnId: turn.id) }
                            } label: {
                                Text("取消")
                                    .font(PIFont.captionStrong)
                                    .foregroundStyle(PIColor.danger)
                                    .frame(minWidth: PIMetrics.minHitTarget, minHeight: PIMetrics.minHitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PIPressableButtonStyle())
                            .disabled(session.isBusy || !connection.state.isOnline)
                            .accessibilityIdentifier("conversation.cancelQueued.\(turn.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conversation.queuedTurn.\(turn.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("conversation.queueSection")
        }
    }


    // MARK: - 恢复路径（模型不可用）

    /// 模型不可用的唯一恢复出口：直达「模型服务」子页（不是设置根页）。
    ///
    /// 上一轮删掉「重新检查」时的理由是「打开模型配置就会重新检查」——那是错的：
    /// 检查只在会话 ID / 模型绑定变化时触发，于是模型服务恢复后横幅会一直挂着，
    /// 而唯一的动作只是把用户丢到设置根页，让他自己再找一次。
    /// 现在点一下就落到 `SettingsRoute.models`，修完回到会话页会自动重查。
    ///
    /// 横幅挂在会话页本身、不在浮层里，所以这里**不**调用 `dismiss()`——那会把会话页
    /// 自己关掉。浮层里的同一入口（会话配置的「模型服务」行）由浮层自己先 `dismiss()`。
    /// 兜底：若配置浮层正开着，先关掉再切根，避免设置页被压在半屏浮层底下。
    func openModelServices() {
        if showingConfig { showingConfig = false }
        model.showSettings(.models)
    }

    /// 恢复路径的有界重查：只在「明确不可用 / 状态未知」时补一次。
    ///
    /// 排除两种状态，避免把一次廉价检查变成服务器压力：
    /// - `.available`：已有可信结论。否则每次开关配置浮层、每次回到会话页都会打一次服务器，
    ///   还会闪一次「正在检查模型可用性」。
    /// - `.checking`：上一次检查还没回来。叠第二次会 `modelAvailabilityGeneration` 自增，
    ///   让先发起的那次返回 `superseded`——并发两次互相覆盖，结论反而更不可信。
    ///
    /// 触发点只有两个：配置浮层关闭、会话页重新出现。没有定时器，也不挂在其它 UI 事件上。
    func recheckModelAvailabilityIfNeeded() {
        switch session.modelAvailability {
        case .unavailable, .unknown:
            Task { await refreshModelAvailability() }
        case .available, .checking:
            return
        }
    }

    var modelAvailabilityContextKey: String {
        "\(connection.currentConnectionGeneration):\(session.attachedSessionId ?? ""):\(session.selectedBindingKey):\(session.openingSessionID ?? "")"
    }

    /// 检查当前会话模型的可用性，并返回显式结果（U11）：`superseded` 表示检查期间
    /// 会话/服务器/模型绑定已经被更新的检查取代，发送方必须放弃这次点击而不是继续发送。
    @discardableResult
    func refreshModelAvailability(reuseRecent: Bool = false) async -> ModelAvailabilityCheckResult {
        guard !Task.isCancelled, session.openingSessionID == nil else { return .superseded }
        if reuseRecent, session.hasRecentModelAvailability() { return .available }
        guard connection.state.isOnline,
              let sessionID = session.attachedSessionId,
              let host = model.currentHost
        else {
            session.markModelAvailabilityUnknown("服务器离线或尚未打开会话")
            return .skipped(reason: "服务器离线或尚未打开会话")
        }
        modelAvailabilityGeneration &+= 1
        let generation = modelAvailabilityGeneration
        let bindingKey = session.selectedBindingKey
        let connectionGeneration = connection.currentConnectionGeneration
        session.markModelAvailabilityChecking()
        do {
            let status = try await connection.adaptorV2BindingStatus(sessionId: sessionID)
            guard generation == modelAvailabilityGeneration,
                  !Task.isCancelled, session.openingSessionID == nil,
                  connection.currentConnectionGeneration == connectionGeneration,
                  model.currentHost?.id == host.id,
                  session.attachedSessionId == sessionID,
                  session.selectedBindingKey == bindingKey
            else { return .superseded }
            session.applyModelAvailability(status)
            return Self.availabilityCheckResult(session.modelAvailability)
        } catch {
            guard !Task.isCancelled, generation == modelAvailabilityGeneration,
                  connection.currentConnectionGeneration == connectionGeneration,
                  session.openingSessionID == nil else { return .superseded }
            let message = ConnectionErrorText.describe(error)
            session.markModelAvailabilityUnknown(message)
            return .failed(reason: message)
        }
    }

    static func availabilityCheckResult(
        _ availability: SessionModelAvailability
    ) -> ModelAvailabilityCheckResult {
        switch availability {
        case .available:
            return .available
        case .checking:
            return .skipped(reason: "正在检查模型可用性")
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .unknown(let reason):
            return .failed(reason: reason)
        }
    }

    var selectedModelLabel: String {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return "模型未绑定" }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return "\(group.name) · \(record.displayName)"
            }
        }
        return "\(providerID) · \(modelID)"
    }
}

/// 模型可用性检查的显式结果（U11）。发送按钮在等待检查后必须能区分
/// 「仍可用」「不可用/失败」与「检查结果已被更新的会话/绑定取代」。
enum ModelAvailabilityCheckResult: Equatable {
    case available
    case unavailable(reason: String)
    case failed(reason: String)
    case skipped(reason: String)
    /// 检查期间会话/服务器/模型绑定已变化，本次结果不再适用于点击时的意图。
    case superseded
}



/// 审批卡“查看完整参数”弹层内容。
struct ApprovalFullInput: Identifiable {
    let id: String
    let title: String
    var text: String? = nil
    var revision: Int? = nil
    var card: RACPApprovalRequest? = nil
}

struct ApprovalInputSheet: View {
    let item: ApprovalFullInput
    let load: (RACPApprovalRequest) async throws -> (text: String, digest: String)
    let finish: (String?) -> Void
    @State private var loaded: (pages: [Substring], digest: String)?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text = item.text {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(PISpacing.s16)
                        .accessibilityIdentifier("conversation.approval.fullInput")
                } else if let loaded {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(loaded.pages.indices, id: \.self) { index in
                            Text(loaded.pages[index])
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PISpacing.s16)
                    .accessibilityIdentifier("conversation.approval.fullInput")
                } else if let failure {
                    PIInlineMessage(kind: .danger, text: failure).padding(PISpacing.s16)
                } else {
                    ProgressView("正在读取完整参数…").padding(PISpacing.s16)
                }
            }
            .navigationTitle(item.title)
            .toolbar {
                if let loaded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("已审阅") { finish(loaded.digest) }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(item.card == nil ? "完成" : "关闭") { finish(nil) }
                }
            }
        }
        .task {
            guard let card = item.card else { return }
            do {
                let result = try await load(card)
                var pages: [Substring] = []
                var start = result.text.startIndex
                while start < result.text.endIndex {
                    let end = result.text.index(start, offsetBy: 4_096, limitedBy: result.text.endIndex) ?? result.text.endIndex
                    pages.append(result.text[start..<end])
                    start = end
                }
                loaded = (pages, result.digest)
            }
            catch { failure = ConnectionErrorText.describe(error) }
        }
    }
}
