import SwiftUI
import PIiOSCore

/// 表单字段：label 在上，错误在下方用 danger 文本，不用红色边框。
/// 输入底为次级表面 + 细描边，获得焦点时由系统光标与选中色表达，不加装饰性描边。
struct PIFormField<Field: View>: View {
    let label: String
    var hint: String? = nil
    var error: String? = nil
    var isPill: Bool = true
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            Text(label)
                .font(PIFont.metaSmall)
                .tracking(0.4)
                .foregroundStyle(PIColor.text2)
            if isPill {
                field()
                    .piFieldChrome()
            } else {
                field()
            }
            if let error {
                Text(error)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 分组内的表单行：统一左右 16pt、上下 12pt，并可选分隔线。
/// 让「表单」和「列表」在同一套间距里，不再一半贴着分组边缘。
struct PIFormRow<Content: View>: View {
    var showsDivider: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
            if showsDivider {
                PIRowDivider()
            }
        }
    }
}

/// 裸输入框的统一外观：次级表面 + 细描边 + 44pt 热区。
struct PIFieldChrome: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(PIFont.body)
            .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
            .padding(.horizontal, PISpacing.s12)
            .padding(.vertical, PISpacing.s8)
            .frame(minHeight: PIMetrics.minHitTarget)
            .background(
                isEnabled ? PIColor.surface2 : PIColor.surface2.opacity(0.6),
                in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
    }
}

extension View {
    /// 给没有包在 `PIFormField` 里的输入框套同一套外观。
    func piFieldChrome() -> some View { modifier(PIFieldChrome()) }
}

/// 多选 chip：未选中是次级表面，选中切到琥珀柔和底并带勾。
struct PISelectableChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(title)
                    .font(PIFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? PIColor.accent : PIColor.text2)
            .padding(.horizontal, PISpacing.s12)
            .padding(.vertical, 8)
            .background(
                isSelected ? PIColor.accentSoft : PIColor.surface2,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? PIColor.accentBorder : PIColor.separator,
                        lineWidth: PIMetrics.hairline
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PIPressableButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 会话权限徽标。
///
/// 枚举来自 `PIiOSCore.RACPPermissionMode`（契约 §3.1 的 `permissionMode` 三值），
/// App 内不再保留第二份定义；title/tint 的展示映射在 `App/CoreAdapters.swift`。
struct PIPermissionBadge: View {
    let mode: RACPPermissionMode

    var body: some View {
        HStack(spacing: PISpacing.s4) {
            Circle()
                .fill(mode.tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(mode.title)
                .font(PIFont.metaSmall.weight(.semibold))
                .foregroundStyle(mode.tint)
        }
        .padding(.horizontal, PISpacing.s8)
        .padding(.vertical, 3)
        .background(mode.tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(mode.tint.opacity(0.28), lineWidth: PIMetrics.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("权限模式：\(mode.title)")
    }
}
