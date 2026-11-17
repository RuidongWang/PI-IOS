import SwiftUI
import UIKit

/// 颜色 token —— 「静 / Quiet · 冷灰蓝」。契约见 `apps/ios/design/quiet-v2.md`。
///
/// 所有页面只引用这里的语义色。浅色、深色与 Increase Contrast 均由
/// UIKit dynamic provider 按传入 traits 解析；Soft 色不使用透明度合成。
enum PIColor {
    // MARK: 底色与表面

    static let page = dynamic(light: 0xF4F6F9, dark: 0x0F141B)
    /// 兼容旧调用：页面底。
    static let bg = page
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x171E27)
    static let surface2 = dynamic(light: 0xEDF1F5, dark: 0x202936)
    /// 禁用图标底与少量内嵌控件，不承载普通文本。
    static let surface3 = dynamic(light: 0xE3E9F0, dark: 0x2B3542)
    /// 纯装饰发丝线；必要控件边界使用 separatorStrong。
    static let separator = dynamic(
        light: 0xD9E0E8, dark: 0x303B49,
        lightHighContrast: 0xB4C0CE, darkHighContrast: 0x536377
    )
    static let separatorStrong = dynamic(
        light: 0x748295, dark: 0x899AAF,
        lightHighContrast: 0x5E6B7C, darkHighContrast: 0xA7B7CA
    )

    // MARK: 文本

    static let text = dynamic(light: 0x18202B, dark: 0xF0F3F7)
    static let text2 = dynamic(
        light: 0x4B5667, dark: 0xB4BECB,
        lightHighContrast: 0x323C49, darkHighContrast: 0xD5DCE5
    )
    static let text3 = dynamic(
        light: 0x5F6B7A, dark: 0x96A3B4,
        lightHighContrast: 0x465160, darkHighContrast: 0xC0CAD6
    )

    // MARK: 可交互（唯一强调色）

    /// 主按钮、可点文字、选中态。**不得用于装饰**。
    static let accent = dynamic(light: 0x315FD5, dark: 0x9DB8FF)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x101623)
    static let accentSoft = dynamic(light: 0xE8EEFC, dark: 0x223454)
    static let accentBorder = accent
    static let accentBright = accent

    // MARK: 状态（只表达状态）

    static let danger = dynamic(light: 0xA92835, dark: 0xFF918B)
    static let warning = dynamic(light: 0x754500, dark: 0xE7B96A)
    static let success = dynamic(light: 0x146344, dark: 0x72C9A5)
    static let dangerSoft = dynamic(light: 0xFCECEF, dark: 0x3B2329)
    static let warningSoft = dynamic(light: 0xFAF0DC, dark: 0x382E1E)
    static let successSoft = dynamic(light: 0xE7F3ED, dark: 0x1D352D)

    // MARK: 浮层

    static let scrim = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.36, darkAlpha: 0.52)
    static let cardShadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0, darkAlpha: 0)
    static let floatingShadow = dynamic(light: 0x101923, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.28)

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        lightHighContrast: UInt32? = nil,
        darkHighContrast: UInt32? = nil,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHighContrast = traits.accessibilityContrast == .high
            let rgb = isDark
                ? (isHighContrast ? darkHighContrast ?? dark : dark)
                : (isHighContrast ? lightHighContrast ?? light : light)
            return UIColor(rgb: rgb).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 字号层级 token。
///
/// 取舍：只有「机器数据」（路径、端口、指纹、模型 ID）用等宽，让它在视觉上退后一层；
/// 不做字距、不做全大写——那两样是让界面显得「设计过」的噪音，不是信息。
enum PIFont {
    // 用**语义字号**而不是 Font.system(size:)：默认档位下像素完全一致，
    // 但会随 Dynamic Type 缩放。固定 size 在「大号文字」下不放大，
    // 等于把需要看清关键状态的人挡在门外。
    /// 根页大标题 28
    static let rootTitle = Font.title.weight(.bold)
    /// 浮层标题 20
    static let display = Font.title3.weight(.semibold)
    /// 子页标题 17
    static let navTitle = Font.headline
    /// 列表行主文本 17
    static let listTitle = Font.body
    /// 正文 16
    static let body = Font.callout
    /// 按钮 16
    static let button = Font.callout.weight(.semibold)
    /// 次要数据 13
    static let caption = Font.footnote
    static let captionStrong = Font.footnote.weight(.semibold)
    /// 状态、计数 12
    static let meta = Font.caption
    static let metaSmall = Font.caption2
    /// 等宽元信息：ID、路径、端口、模型标识。
    static let metaMono = Font.system(.caption, design: .monospaced)
    static let codeMono = Font.system(.footnote, design: .monospaced)
    /// 计数、进度。
    static let number = Font.callout.weight(.semibold).monospacedDigit()
    /// 分组标题 13。
    static let section = Font.footnote.weight(.semibold)
}

/// 间距阶梯 token：4 / 8 / 12 / 16 / 24 / 32。
enum PISpacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
}

/// 圆角 token：控件 8、分组 12、浮层 16。
enum PIRadius {
    static let control: CGFloat = 8
    static let group: CGFloat = 12
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
}

/// 动效 token：只为表达状态变化，180–240ms。
enum PIMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let standard = Animation.easeInOut(duration: 0.22)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

/// 尺寸与安全区 token。
enum PIMetrics {
    /// 浮层吸底动作区为 home indicator 预留的底部留白。
    static let safeBottom: CGFloat = 22
    /// 页面边距 16pt。
    static let pageMargin: CGFloat = 16
    /// 卡片内边距 16pt。
    static let cardPadding: CGFloat = 16
    /// 触达目标不小于 44×44。
    static let minHitTarget: CGFloat = 44
    /// 列表行最小高度 48pt。
    static let listRowMinHeight: CGFloat = 48
    /// 侧边栏会话行最小高度 48pt。
    static let sidebarRowMinHeight: CGFloat = 48
    /// 侧边栏宽度。
    static let sidebarWidth: CGFloat = 320
    static let hairline: CGFloat = 1
}

// MARK: - 页面容器

/// 页面背景：纯色分组底，不画渐变、不画顶光。
struct PIPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(PIColor.page.ignoresSafeArea())
    }
}

extension View {
    func piPageBackground() -> some View { modifier(PIPageBackground()) }
}

// 导航栏沿用系统外观：大标题与玻璃工具栏已经足够克制，自绘会和大标题布局冲突。
