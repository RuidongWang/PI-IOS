import SwiftUI

/// 本机外观偏好（screens.md S-03「本机外观」）。默认跟随系统，存 `@AppStorage`，与服务器配置无关。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "pi.appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var detail: String {
        switch self {
        case .system: return "随系统的浅色 / 深色设置变化"
        case .light: return "始终使用浅色"
        case .dark: return "始终使用深色"
        }
    }

    /// 交给 `.preferredColorScheme`；跟随系统时为 nil。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 外观偏好的单一事实源（DEF-R4-002）。
///
/// 之前浮层与根视图各持一份 `@AppStorage`：写入只保证落 `UserDefaults`，
/// 另一份 storage 不一定在同一帧收到变更，于是出现「选中标记动了、界面没变」。
/// 改为全局共享一个 store：选择即写 `mode`（同步持久化到原 storage key），
/// 根视图 `preferredColorScheme` 立即随 `@Published` 更新。
@MainActor
final class AppearanceStore: ObservableObject {
    @Published var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        let raw = defaults.string(forKey: AppearanceMode.storageKey)
        self.mode = AppearanceMode(rawValue: raw ?? "") ?? .system
    }
}
