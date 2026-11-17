import SwiftUI

/// 分组容器：iOS Inset Grouped。纯 `surface` 底 + 发丝描边 + 12pt 圆角，零投影。
/// 行之间用 `PIRowDivider` 分隔，最后一行不画分隔线。
struct PIGroup<Content: View>: View {
    let header: String?
    @ViewBuilder let content: () -> Content

    // quiet-v2：没有 footer 参数，是故意的。解释性文字一旦能加，就一定会有。
    init(_ header: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
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
        }
    }
}

/// 分组标题：13pt 半粗、次要文本色，不加刻度、不加字距。
struct PISectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PIFont.section)
            .foregroundStyle(PIColor.text2)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, PISpacing.s4)
    }
}

/// 组内分隔线，颜色取 `separator`，左侧留出内容缩进。
struct PIRowDivider: View {
    var leadingInset: CGFloat = PISpacing.s16

    var body: some View {
        Rectangle()
            .fill(PIColor.separator)
            .frame(height: PIMetrics.hairline)
            .padding(.leading, leadingInset)
    }
}

/// 详情卡：与分组同一套外观，只是内容自绘。
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
    }
}

/// 卡片上的小标题：13pt 次要文本色，等宽/大写/字距全部取消。
struct PICardLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PIFont.caption)
            .foregroundStyle(PIColor.text2)
    }
}
