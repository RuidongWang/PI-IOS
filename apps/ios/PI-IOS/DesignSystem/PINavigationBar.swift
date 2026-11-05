import SwiftUI

/// 导航栏（design-system.md §3 `NavBar` / §6 `.nav` → `.navigationTitle` + `.toolbar`）。
/// 根页：标题 + 左上千斤顶（≡）+ 右侧最多 1 个操作；子页：标题 + 系统 `‹` 返回。
struct PIRootNavBarModifier<Trailing: View>: ViewModifier {
    let title: String
    var displayMode: NavigationBarItem.TitleDisplayMode = .large
    let onMenu: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(displayMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(PIColor.text)
                            .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("打开侧边栏")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    trailing()
                }
            }
    }
}

struct PIDetailNavBarModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// 根页导航栏：左上 ≡ 打开侧边栏，右侧最多一个操作。
    /// 默认大标题；页面自己已有常驻状态区时用 `.inline`，避免大标题随内嵌滚动视图
    /// 下拉进出、压在状态区上。
    func piRootNavBar<Trailing: View>(
        _ title: String,
        displayMode: NavigationBarItem.TitleDisplayMode = .large,
        onMenu: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(
            PIRootNavBarModifier(
                title: title,
                displayMode: displayMode,
                onMenu: onMenu,
                trailing: trailing
            )
        )
    }

    /// 根页导航栏（无右侧操作）。
    func piRootNavBar(_ title: String, onMenu: @escaping () -> Void) -> some View {
        piRootNavBar(title, onMenu: onMenu) { EmptyView() }
    }

    /// 子页 / 流程页导航栏：系统返回按钮回到来源。
    func piDetailNavBar(_ title: String) -> some View {
        modifier(PIDetailNavBarModifier(title: title))
    }
}

/// 全局按压反馈：轻缩放 + 压暗，统一所有自绘按钮的手感。
struct PIPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(PIMotion.quick, value: configuration.isPressed)
    }
}

/// 主操作按钮：琥珀实心 + 深色文字（深色模式为近黑字，浅色模式白字）。
struct PIPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.button)
                .foregroundStyle(isEnabled ? PIColor.onAccent : PIColor.onAccent.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .fill(isEnabled ? PIColor.accent : PIColor.accent.opacity(0.38))
                )
                .shadow(
                    color: isEnabled ? PIColor.accent.opacity(0.22) : .clear,
                    radius: 10,
                    y: 4
                )
        }
        .buttonStyle(PIPressableButtonStyle())
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
        .disabled(!isEnabled)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// 次级操作：--surface-2 底、细描边、主文本色。
struct PISecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.button)
                .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
                )
        }
        .buttonStyle(PIPressableButtonStyle())
        .disabled(!isEnabled)
    }
}

/// 行内补充动作：小号琥珀胶囊，用在状态横幅下方的「去项目页」「选择其他模型」这类次级入口。
struct PIGhostChipButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: PISpacing.s4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(PIFont.captionStrong)
            }
            .foregroundStyle(PIColor.accent)
            .padding(.horizontal, PISpacing.s12)
            .padding(.vertical, 7)
            .background(PIColor.accentSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(PIColor.accentBorder, lineWidth: PIMetrics.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PIPressableButtonStyle())
    }
}

/// 审批卡主决策按钮：琥珀实心、整宽、44pt 热区。
struct PIApprovalPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.onAccent : PIColor.onAccent.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    (isEnabled ? PIColor.accent : PIColor.accent.opacity(0.38)),
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
        }
        .buttonStyle(PIPressableButtonStyle())
        .disabled(!isEnabled)
    }
}

/// 审批卡次级决策按钮：surface2 底、主文本色。
struct PIApprovalSecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
                )
        }
        .buttonStyle(PIPressableButtonStyle())
        .disabled(!isEnabled)
    }
}

/// 审批卡危险决策按钮：danger 描边 + danger 文字，与安全动作视觉不共位。
struct PIDangerOutlineButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    (isEnabled ? PIColor.dangerSoft.opacity(0.5) : Color.clear),
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(isEnabled ? PIColor.danger : PIColor.separator, lineWidth: 1.2)
                )
        }
        .buttonStyle(PIPressableButtonStyle())
        .disabled(!isEnabled)
    }
}

/// 单选行（外观、离线缓存上限等浮层使用）：整行可点，选中态用柔和强调底 + 勾选。
struct PIOptionRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    var showsDivider: Bool = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(alignment: .center, spacing: PISpacing.s12) {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(isSelected ? PIColor.accent : PIColor.text)
                        if let subtitle {
                            Text(subtitle)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: PISpacing.s8)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PIColor.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, PISpacing.s12)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    isSelected ? PIColor.accentSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
                .padding(.horizontal, PISpacing.s4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            if showsDivider {
                PIRowDivider()
            }
        }
    }
}
