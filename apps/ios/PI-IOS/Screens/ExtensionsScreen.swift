import SwiftUI
import PIiOSCore

struct ExtensionsScreen: View {
    @ObservedObject var catalog: ExtensionCatalogModel
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @State private var selected: RACPExtensionInventoryEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                PIGroup {
                    PIListRow(title: model.currentHost?.name ?? "未选择服务器", icon: "server.rack", showsDivider: false)
                }
                content
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .piDetailNavBar("扩展")
        .task(id: catalog.context) { await connection.refreshExtensionInventory() }
        .refreshable { await connection.refreshExtensionInventory() }
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { ExtensionDetailScreen(inventory: selected) }
        }
        .onChange(of: catalog.context.hostID) { _, _ in selected = nil }
    }

    @ViewBuilder private var content: some View {
        if catalog.context.hostID == nil {
            ExtensionReadNotice(text: "选择服务器后可查看扩展")
        } else if catalog.context.online && !catalog.context.inventorySupported {
            ExtensionReadNotice(text: "此服务器版本不支持查看扩展")
        } else if let inventory = catalog.inventory.value {
            PIGroup("加载设置") {
                PIListRow(title: inventory.userLoadingEnabled ? "用户扩展加载已启用" : "此服务器未启用用户扩展加载",
                          subtitle: "配置与扩展代码变更在服务器重启后生效", showsDivider: false)
            }
            PIGroup("已配置 · \(inventory.entries.count) 项") {
                if inventory.entries.isEmpty {
                    PIListRow(title: "尚未配置用户扩展", showsDivider: false)
                } else {
                    ForEach(Array(inventory.entries.enumerated()), id: \.element.id) { index, entry in
                        PIListRow(title: entry.name, subtitle: ExtensionPresentation.inventoryStatus(entry),
                                  icon: "puzzlepiece.extension", showsChevron: true,
                                  showsDivider: index < inventory.entries.count - 1,
                                  action: { selected = entry })
                        .accessibilityIdentifier("extensions.entry.\(entry.id)")
                    }
                }
            }
            if case .loading = catalog.inventory { ExtensionReadNotice(text: "正在读取…") }
            if case .failed = catalog.inventory {
                ExtensionReadNotice(text: "上次读取的数据 · \(ExtensionPresentation.date(inventory.capturedAt))",
                                    retry: catalog.context.online ? { Task { await connection.refreshExtensionInventory() } } : nil)
            }
        } else if !catalog.context.online {
            ExtensionReadNotice(text: "连接服务器后可查看扩展")
        } else if case let .failed(reason, _) = catalog.inventory {
            ExtensionReadNotice(text: reason, retry: { Task { await connection.refreshExtensionInventory() } })
        } else {
            ExtensionReadNotice(text: "正在读取…")
        }
    }
}

struct ExtensionReadNotice: View {
    let text: String
    var retry: (() -> Void)? = nil

    var body: some View {
        PIGroup {
            PIListRow(title: text, showsDivider: retry != nil)
                .accessibilityIdentifier("extensions.state")
            if let retry {
                PIListRow(title: "重新读取", icon: "arrow.clockwise", showsDivider: false, action: retry)
                    .accessibilityIdentifier("extensions.listRetry")
            }
        }
    }
}

enum ExtensionPresentation {
    static func inventoryStatus(_ entry: RACPExtensionInventoryEntry) -> String {
        if !entry.enabled { return "已停用" }
        switch entry.entryState {
        case "missing": return "入口文件不存在"
        case "unreadable": return "入口不可读取"
        case "duplicate": return "入口重复"
        case "valid": break
        default: return "入口状态未知"
        }
        switch entry.compatibility {
        case "headless-reviewed": return "已启用 · 已声明适配服务器运行"
        case "requires-ui": return "未适配 · 需要界面交互"
        default: return "未适配 · 兼容性待确认"
        }
    }

    static func runtimeStatus(_ entry: RACPExtensionRuntimeEntry) -> String {
        switch entry.loadState {
        case "loaded": return "已加载"
        case "failed": return "加载失败"
        case "skipped":
            switch entry.skipReason {
            case "host-disabled": return "已跳过 · 服务器未启用加载"
            case "entry-disabled": return "已跳过 · 已停用"
            case "not-adapted": return "已跳过 · 未适配"
            default: return "已跳过"
            }
        default: return "加载状态未知"
        }
    }

    static func date(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
        return date?.formatted(date: .abbreviated, time: .shortened) ?? raw
    }
}
