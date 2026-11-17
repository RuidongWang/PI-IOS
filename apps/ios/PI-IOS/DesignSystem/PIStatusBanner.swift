import SwiftUI

/// 常驻状态条：用 `.safeAreaInset(edge: .top)` 或页面内容顶部放置，不随滚动隐藏。
///
/// quiet-v2：底色回到中性表面，只有图标和标题行带状态色——状态要的是「一眼看到」，
/// 不是给整块区域刷色。
enum PIStatusKind {
    case info
    case warning
    case danger
    case success

    var tint: Color {
        switch self {
        case .info: return PIColor.text2
        case .warning: return PIColor.warning
        case .danger: return PIColor.danger
        case .success: return PIColor.success
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}

struct PIStatusBanner: View {
    let kind: PIStatusKind
    let text: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: PISpacing.s12) {
            Image(systemName: kind.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                // 正文用文本色：状态色只留给图标和圆点。
                // 13pt 的 green/orange 落在浅色底上对比度不足，读不清等于没写。
                Text(text)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.accent)
                            .frame(minHeight: PIMetrics.minHitTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // 只合并文本列。整条横幅 `.combine` 会把里面的按钮并进同一条无障碍元素，
            // 读屏就无法按「按钮」聚焦到它——自动化点得到，不代表用户找得到。
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(PISpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.30), lineWidth: PIMetrics.hairline)
        )
        .accessibilityElement(children: .contain)
    }
}

/// 空态：一句话 + 一个动作。不再有解释段。
struct PIEmptyState: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionIdentifier: String? = nil
    var icon: String = "tray"

    init(
        title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        actionIdentifier: String? = nil,
        icon: String = "tray"
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
        self.actionIdentifier = actionIdentifier
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            HStack(spacing: PISpacing.s12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
                Text(title)
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(PIFont.button)
                        .foregroundStyle(PIColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: PIMetrics.minHitTarget)
                        .background(PIColor.accent, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                }
                .buttonStyle(PIPressableButtonStyle())
                .modifier(PIEmptyStateActionIdentifier(identifier: actionIdentifier))
            }
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

private struct PIEmptyStateActionIdentifier: ViewModifier {
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
