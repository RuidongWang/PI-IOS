import SwiftUI

/// 列表行：可选图标 + 标题 + 第二行说明 + 右侧值与 chevron。
/// 双行时行高不小于 62pt；图标作为装饰不进入无障碍标签。
struct PIListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var icon: String? = nil
    var iconTint: Color = PIColor.text2
    var isEnabled: Bool = true
    var showsChevron: Bool = false
    var showsDivider: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            if let action, isEnabled {
                Button(action: action) { content }
                    .buttonStyle(PIPressableButtonStyle())
                    .accessibilityElement(children: .combine)
            } else {
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
            }
            if showsDivider {
                PIRowDivider()
            }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: PISpacing.s12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isEnabled ? iconTint : PIColor.text3)
                    .frame(width: 30, height: 30)
                    .background(
                        (isEnabled ? iconTint : PIColor.text3).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text(title)
                    .font(PIFont.listTitle)
                    .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: PISpacing.s8)
            if let value {
                Text(value)
                    .font(PIFont.meta)
                    .monospacedDigit()
                    .foregroundStyle(isEnabled ? PIColor.text2 : PIColor.text3)
            }
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
        .frame(minHeight: PIMetrics.listRowMinHeight)
        .contentShape(Rectangle())
    }
}

extension PIListRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        icon: String? = nil,
        iconTint: Color = PIColor.text2,
        isEnabled: Bool = true,
        showsChevron: Bool = false,
        showsDivider: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            value: value,
            icon: icon,
            iconTint: iconTint,
            isEnabled: isEnabled,
            showsChevron: showsChevron,
            showsDivider: showsDivider,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

/// 危险操作行：文字用 danger，点击后走二次确认。
/// 禁用时给出原因，不做「可点击但无作用」的按钮。
struct PIDangerRow: View {
    let title: String
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    var showsDivider: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(role: .destructive, action: action) {
                HStack(spacing: PISpacing.s12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text3)
                        .frame(width: 30, height: 30)
                        .background(
                            (isEnabled ? PIColor.danger : PIColor.text3).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text3)
                        if let disabledReason, !isEnabled {
                            Text(disabledReason)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityElement(children: .combine)
            if showsDivider {
                PIRowDivider()
            }
        }
    }
}

/// 成功提示（toast）：表面色卡片 + 轻投影，仅成功提示。
struct PIToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct PIToastView: View {
    let toast: PIToast

    var body: some View {
        HStack(spacing: PISpacing.s8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PIColor.success)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
        .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .shadow(color: PIColor.floatingShadow, radius: 18, y: 8)
        .padding(.horizontal, PIMetrics.pageMargin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
