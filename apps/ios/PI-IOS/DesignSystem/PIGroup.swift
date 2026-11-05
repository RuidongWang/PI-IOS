import SwiftUI

/// 分组容器：--surface 底、--separator 细边、14pt 圆角，普通分组只给极轻投影。
/// 行之间用 `PIRowDivider` 分隔，最后一行不画分隔线。
struct PIGroup<Content: View>: View {
    let header: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            if let header {
                PISectionHeader(text: header)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
            .shadow(color: PIColor.cardShadow, radius: 10, y: 3)
            if let footer {
                Text(footer)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PISpacing.s4)
            }
        }
    }
}

/// 分组标题：中文正常大小写；左侧一条短琥珀刻度，给页面一点「仪表分区」的辨识度。
struct PISectionHeader: View {
    let text: String

    var body: some View {
        HStack(spacing: PISpacing.s8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(PIColor.accent)
                .frame(width: 3, height: 12)
                .accessibilityHidden(true)
            Text(text)
                .font(PIFont.section)
                .tracking(0.6)
                .foregroundStyle(PIColor.text2)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, PISpacing.s4)
    }
}

/// 组内分隔线，颜色取 --separator，左侧留出内容缩进。
struct PIRowDivider: View {
    var leadingInset: CGFloat = PISpacing.s16

    var body: some View {
        Rectangle()
            .fill(PIColor.separator)
            .frame(height: PIMetrics.hairline)
            .padding(.leading, leadingInset)
    }
}

/// 详情卡 / 说明卡：18pt 圆角，--separator 描边，极轻投影。
struct PICard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            content()
        }
        .padding(PIMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .shadow(color: PIColor.cardShadow, radius: 12, y: 4)
    }
}

/// 卡片上的小标题：等宽大写英文或中文短标签，统一「仪表读数」气质。
struct PICardLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PIFont.metaSmall)
            .tracking(1.0)
            .foregroundStyle(PIColor.text3)
    }
}
