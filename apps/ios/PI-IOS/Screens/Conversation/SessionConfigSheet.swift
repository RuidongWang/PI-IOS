import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import CoreTransferable
import ImageIO
import PIiOSCore
import PIiOSNet

/// 只在有值时套 identifier：避免空字符串标识混进无障碍树。
private struct PIOptionalIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier, !identifier.isEmpty {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

extension View {
    func piOptionalIdentifier(_ identifier: String?) -> some View {
        modifier(PIOptionalIdentifier(identifier: identifier))
    }
}

// MARK: - 会话配置（AC-07）

struct SessionConfigSheet: View {
    @ObservedObject var session: SessionController
    let groups: [ProviderModelGroup]
    let diagnostics: [ModelGroupingDiagnostic]
    let extensionSessionID: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    private var selectedBinding: ModelRecord? {
        flatten(groups).first {
            $0.providerId == session.selectedProviderId && $0.modelId == session.selectedModelId
        }
    }

    private var configLocked: Bool { session.isTurnRunning || session.isBusy }
    private var configEnabled: Bool { !configLocked && session.isOnline && session.attachedSessionId != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    if !diagnostics.isEmpty {
                        PIInlineMessage(
                            kind: .warning,
                            text: "模型清单有重复记录：\(diagnostics.map(\.message).joined(separator: "\n"))"
                        )
                    }
                    if configLocked {
                        PIInlineMessage(kind: .warning, text: "当前轮次仍在运行：本轮结束后可切换。")
                    } else if !session.isOnline {
                        PIInlineMessage(kind: .warning, text: "服务器离线，恢复连接后才能提交。")
                    }
                    if let sessionID = extensionSessionID {
                        SessionExtensionsLink(catalog: model.connection.extensions, sessionID: sessionID)
                    }
                    // quiet-v2 §6.3：配置组不再用 footer 解释协议名。单选控件用勾选表达状态，
                    // 选择即提交，用户从行本身就能读懂。
                    PIGroup("权限模式") {
                        let modes = RACPPermissionMode.allCases
                        ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                            configOptionRow(
                                title: mode.title,
                                isSelected: session.permissionMode == mode,
                                showsDivider: index != modes.count - 1,
                                identifier: "conversation.config.permission.\(mode.rawValue)"
                            ) {
                                Task { await session.configure(permissionMode: mode) }
                            }
                        }
                    }
                    PIGroup("会话模式") {
                        let modes = RACPSessionMode.allCases
                        ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                            configOptionRow(
                                title: mode.title,
                                isSelected: session.sessionMode == mode,
                                showsDivider: index != modes.count - 1,
                                identifier: "conversation.config.mode.\(mode.rawValue)"
                            ) {
                                Task { await session.configure(mode: mode) }
                            }
                        }
                    }
                    PIGroup("模型") {
                        if groups.isEmpty {
                            // quiet-v2：原来是一行禁用说明（"先到 设置 → 模型服务 导入模型"），
                            // 属于用文案补布局。改成可点的出口：状态写在副标题，动作在行本身。
                            PIListRow(
                                title: "模型服务",
                                subtitle: "没有可用模型",
                                showsChevron: true,
                                showsDivider: false,
                                action: {
                                    // 浮层自己先关，再走同一条深链：落到「模型服务」子页，
                                    // 不是设置根页——用户已经选了「模型服务」，不该再找一次。
                                    dismiss()
                                    model.showSettings(.models)
                                }
                            )
                            .accessibilityIdentifier("conversation.openModelServices")
                        } else {
                            ForEach(groups.indices, id: \.self) { groupIndex in
                                let group = groups[groupIndex]
                                Text(group.name)
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                                    .padding(.horizontal, PISpacing.s16)
                                    .padding(.top, groupIndex == 0 ? 0 : PISpacing.s8)
                                ForEach(group.models.indices, id: \.self) { modelIndex in
                                    let record = group.models[modelIndex]
                                    PIListRow(
                                        title: record.displayName,
                                        subtitle: modelSubtitle(record),
                                        value: isSelected(record) ? "当前" : nil,
                                        isEnabled: configEnabled,
                                        showsDivider: !(groupIndex == groups.count - 1 && modelIndex == group.models.count - 1),
                                        action: { select(record) }
                                    )
                                    .accessibilityIdentifier("conversation.config.model.\(record.modelId)")
                                }
                            }
                        }
                    }
                    if let selectedBinding, !selectedBinding.thinkingLevels.isEmpty {
                        PIGroup("思考档位") {
                            let levels = selectedBinding.thinkingLevels
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, raw in
                                configOptionRow(
                                    title: raw,
                                    isSelected: session.thinkingLevel?.rawValue == raw,
                                    showsDivider: index != levels.count - 1,
                                    identifier: "conversation.config.thinking.\(raw)"
                                ) {
                                    Task { await select(selectedBinding, thinking: RACPThinkingLevel(rawValue: raw)) }
                                }
                            }
                        }
                    }
                    if let notice = session.thinkingFallbackNotice {
                        PIInlineMessage(kind: .info, text: "档位已调整：\(notice)")
                    }
                    if let error = session.lastError {
                        PIInlineMessage(kind: .danger, text: "配置未生效：\(error)")
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("会话配置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 单选行：勾选即状态。footer 删掉后，选中态就是唯一的约束表达。
    @ViewBuilder
    private func configOptionRow(
        title: String,
        isSelected: Bool,
        showsDivider: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        PIOptionRow(
            title: title,
            isSelected: isSelected,
            showsDivider: showsDivider,
            action: action
        )
        .disabled(!configEnabled)
        .accessibilityIdentifier(identifier)
    }

    private func isSelected(_ record: ModelRecord) -> Bool {
        record.providerId == session.selectedProviderId && record.modelId == session.selectedModelId
    }

    private func modelSubtitle(_ record: ModelRecord) -> String {
        var parts = [record.modelId]
        if let context = record.contextWindow {
            parts.append("\(compactModelTokens(context)) ctx")
        }
        if let output = record.maxTokens {
            parts.append("\(compactModelTokens(output)) output")
        }
        if !record.thinkingLevels.isEmpty {
            parts.append("思考 \(record.thinkingLevels.joined(separator: "/"))")
        }
        return parts.joined(separator: " · ")
    }

    private func compactModelTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }

    private func select(_ record: ModelRecord, thinking: RACPThinkingLevel? = nil) {
        guard let providerId = record.providerId else { return }
        let levels = record.thinkingLevels.compactMap(RACPThinkingLevel.init(rawValue:))
        let support = ThinkingLevelSupport(
            declared: levels,
            defaultLevel: record.defaultThinkingLevel.flatMap(RACPThinkingLevel.init(rawValue:))
        )
        Task {
            await session.configure(
                providerId: providerId,
                modelId: record.modelId,
                thinkingLevel: thinking,
                thinkingSupport: support
            )
        }
    }
}

/// 在发出历史请求前同步记录旧行位置；工具分组跨页重组时，新行也能沿用同一像素基准。
