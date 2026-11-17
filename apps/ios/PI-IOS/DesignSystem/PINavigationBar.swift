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

/// 实心主按钮外观：禁用态由**环境** `isEnabled` 决定。
///
/// 为什么放在 ButtonStyle 里：`Button` 的禁用态只存在于环境，调用方用 `.disabled(...)`
/// 时视图本体读不到。放在 style 里读，`isEnabled:` 参数与 `.disabled()` 两条路径
/// 就只有一个真相，不会出现「看着能按其实按不了」。
struct PIFilledButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 46
    var fill: Color = PIColor.accent

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? PIColor.onAccent : PIColor.text2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .background(
                isEnabled ? fill : PIColor.surface2,
                in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
            )
            .opacity(isEnabled && configuration.isPressed ? 0.82 : 1)
            .scaleEffect(isEnabled && configuration.isPressed ? 0.985 : 1)
            .animation(PIMotion.quick, value: configuration.isPressed)
    }
}

/// 次级按钮外观：表面色底 + 发丝描边；禁用态同样读环境。
struct PISecondaryButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 46

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? PIColor.text : PIColor.text2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
            .opacity(isEnabled && configuration.isPressed ? 0.82 : 1)
            .scaleEffect(isEnabled && configuration.isPressed ? 0.985 : 1)
            .animation(PIMotion.quick, value: configuration.isPressed)
    }
}

/// 主操作按钮：强调色实心 + 反色文字。禁用态由环境 `isEnabled` 决定。
struct PIPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.button)
        }
        .buttonStyle(PIFilledButtonStyle())
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
        }
        .buttonStyle(PISecondaryButtonStyle())
        .disabled(!isEnabled)
    }
}

/// 审批卡主决策按钮：accent 实心、整宽、44pt 热区；禁用时改用中性表面。
struct PIApprovalPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.onAccent : PIColor.text2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    isEnabled ? PIColor.accent : PIColor.surface2,
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
                .foregroundStyle(isEnabled ? PIColor.text : PIColor.text2)
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
                .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text2)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    PIColor.surface2,
                    in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(isEnabled ? PIColor.danger.opacity(0.45) : PIColor.separator, lineWidth: PIMetrics.hairline)
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
                            .foregroundStyle(PIColor.text)
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
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.listRowMinHeight)
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
