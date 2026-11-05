import SwiftUI
import UIKit

/// 颜色 token —— 「石墨信号 / Graphite Signal」。
///
/// 设计口径：这是一台远程仪表，不是聊天玩具。页面底是暖石墨（浅色为暖纸），
/// 面板分层靠明度而不是重投影；强调色只有一种琥珀信号色，其余语义色只表达状态。
/// 浅色 / 深色各一套精确 hex，语义名保持不变，页面只引用 token。
enum PIColor {
    // MARK: 底色与表面

    /// 页面顶部底色（渐变起点）。
    static let bgTop = dynamic(light: 0xF5F2EB, dark: 0x12161C)
    /// 页面底部底色（渐变终点）。
    static let bgBottom = dynamic(light: 0xEDE8DE, dark: 0x090C10)
    /// 兼容旧调用：页面背景主色。
    static let bg = bgTop
    /// 列表、卡片、浮层。
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x171C23)
    /// 次级表面：输入框、配置 chip、次级按钮。
    static let surface2 = dynamic(light: 0xEDE9E0, dark: 0x20262F)
    /// 三级表面：内嵌卡片、分段控件槽底。
    static let surface3 = dynamic(light: 0xE4DED2, dark: 0x29303A)
    /// 分隔线 / 描边。
    static let separator = dynamic(light: 0xDCD6CA, dark: 0x2C333D)
    /// 强描边：焦点、选中轮廓。
    static let separatorStrong = dynamic(light: 0xC9C2B4, dark: 0x3A4350)

    // MARK: 文本

    static let text = dynamic(light: 0x1A1D21, dark: 0xEDEFF2)
    static let text2 = dynamic(light: 0x5F6670, dark: 0x9AA4B2)
    static let text3 = dynamic(light: 0x8A8F98, dark: 0x6F7A88)

    // MARK: 信号色

    /// 主操作、选中、可交互强调。
    static let accent = dynamic(light: 0xA86500, dark: 0xF2A33C)
    /// 强调色的更亮一档，用于深色下的文字/图标。
    static let accentBright = dynamic(light: 0x8A5200, dark: 0xFFC46B)
    /// 实心强调色按钮上的文字。
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x17120A)
    /// 选中行、用户气泡的柔和强调底。
    static let accentSoft = dynamic(light: 0xF5E6CE, dark: 0x342A19)
    /// 强调色描边。
    static let accentBorder = dynamic(light: 0xE2C595, dark: 0x5A4726)

    static let danger = dynamic(light: 0xB83A3A, dark: 0xE5675E)
    static let dangerSoft = dynamic(light: 0xF8E4E1, dark: 0x3A2323)
    static let warning = dynamic(light: 0x8A6400, dark: 0xE0BC5C)
    static let warningSoft = dynamic(light: 0xF7EFD8, dark: 0x342D18)
    static let success = dynamic(light: 0x1F7A5C, dark: 0x48C7A3)
    static let successSoft = dynamic(light: 0xE1F2EB, dark: 0x1B332B)

    /// 遮罩（侧边栏 / 浮层背后的压暗层）。
    static let scrim = Color.black.opacity(0.5)
    /// 卡片轻投影：深色下几乎不可见，浅色下给表面一点离地感。
    static let cardShadow = Color.black.opacity(0.06)
    /// 浮层 / 输入条的投影。
    static let floatingShadow = Color.black.opacity(0.16)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: dynamicUIColor(light: light, dark: dark))
    }

    fileprivate static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        }
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
/// 取舍：标题更重、更紧，元信息更小、更克制；技术性内容（ID、路径、计数、端口）
/// 统一切到等宽字体，让「机器数据」和「人话」在视觉上分层。
enum PIFont {
    /// 根页大标题 30 / 36 · 700
    static let rootTitle = Font.system(size: 30, weight: .bold)
    /// 卡片主标题 / 浮层标题 24 / 30 · 700
    static let display = Font.system(size: 24, weight: .bold)
    /// 导航与详情标题 20 / 26 · 600
    static let navTitle = Font.system(size: 20, weight: .semibold)
    /// 列表主文本 15 / 21 · 600
    static let listTitle = Font.system(size: 15, weight: .semibold)
    /// 正文 15 / 25 · Regular
    static let body = Font.system(size: 15, weight: .regular)
    /// 主操作按钮文字 15 · 600
    static let button = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 13, weight: .regular)
    static let captionStrong = Font.system(size: 13, weight: .semibold)
    /// 元信息 12 / 16 · Regular
    static let meta = Font.system(size: 12, weight: .regular)
    static let metaSmall = Font.system(size: 11, weight: .regular)
    /// 等宽元信息：ID、路径、端口、模型标识。
    static let metaMono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let codeMono = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// 大号数字：计数、进度。
    static let number = Font.system(size: 15, weight: .semibold).monospacedDigit()
    /// 分组标题：中文正常大小写，加强字距形成仪器刻度感。
    static let section = Font.system(size: 12, weight: .semibold)
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

/// 圆角 token：控件 10、分组 14、详情卡 18、底部浮层 24。
enum PIRadius {
    static let control: CGFloat = 10
    static let group: CGFloat = 14
    static let card: CGFloat = 18
    static let sheet: CGFloat = 24
}

/// 动效 token：只为表达状态变化，180–240ms。
enum PIMotion {
    static let quick = Animation.easeOut(duration: 0.18)
    static let standard = Animation.easeInOut(duration: 0.22)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

/// 尺寸与安全区 token。
enum PIMetrics {
    /// --safe-bottom：浮层吸底动作区为 home indicator 预留的底部留白
    static let safeBottom: CGFloat = 22
    /// 页面边距 18–22pt
    static let pageMargin: CGFloat = 18
    /// 卡片内边距 18pt
    static let cardPadding: CGFloat = 18
    /// 触达目标不小于 44×44
    static let minHitTarget: CGFloat = 44
    /// 列表双行至少 62pt
    static let listRowMinHeight: CGFloat = 62
    /// 侧边栏会话行至少 56pt
    static let sidebarRowMinHeight: CGFloat = 56
    /// 侧边栏宽度（iPhone 16 Pro 402pt 画布下留出遮罩区）
    static let sidebarWidth: CGFloat = 320
    /// 输入条/正文使用的轻阴影
    static let hairline: CGFloat = 1
}

// MARK: - 页面容器

/// 页面背景：石墨渐变压底 + 顶部琥珀微光。内容自绘卡片，不依赖 List 系统默认底色。
struct PIPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                LinearGradient(
                    colors: [PIColor.bgTop, PIColor.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [PIColor.accent.opacity(0.07), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 460
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func piPageBackground() -> some View { modifier(PIPageBackground()) }
}

// 导航栏沿用系统外观：iOS 26 的玻璃工具按钮与大标题已经足够克制，
// 自绘会和大标题布局冲突（实测会吞掉根页大标题），因此只统一内容层 token。
