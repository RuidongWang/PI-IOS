import SwiftUI
import PIiOSCore

struct SessionExtensionsLink: View {
    @ObservedObject var catalog: ExtensionCatalogModel
    let sessionID: String
    @EnvironmentObject private var connection: ConnectionModel

    private var summary: String {
        if !catalog.context.online { return "上次读取的加载结果" }
        if !catalog.context.sessionSupported { return "服务器版本不支持查看" }
        guard case let .loaded(result) = catalog.sessionState(sessionID) else {
            return catalog.sessionState(sessionID).value == nil ? "查看加载结果" : "上次读取的加载结果"
        }
        guard let snapshot = result.latestAttempt else { return "首次运行后可查看" }
        let prefix = result.runningTurnId == snapshot.turnId ? "本轮" : "最近一次"
        if snapshot.phase == "loading" { return "\(prefix)正在加载" }
        if snapshot.phase == "failed" { return "\(prefix)初始化失败" }
        return "已加载 \(snapshot.loadedCount) 项 · 失败 \(snapshot.failedCount) 项"
    }

    var body: some View {
        PIGroup("扩展") {
            NavigationLink {
                SessionExtensionsScreen(catalog: catalog, sessionID: sessionID)
            } label: {
                PIListRow(title: "会话扩展", subtitle: summary, icon: "puzzlepiece.extension",
                          showsChevron: true, showsDivider: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.config.extensions")
        }
        .task(id: catalog.context) { await connection.refreshSessionExtensions(sessionID) }
    }
}

struct SessionExtensionsScreen: View {
    @ObservedObject var catalog: ExtensionCatalogModel
    let sessionID: String
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel
    @State private var selected: RACPExtensionRuntimeEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                PIGroup {
                    PIListRow(title: model.currentHost?.name ?? "未选择服务器",
                              subtitle: connection.sessions.first(where: { $0.id == sessionID })?.title,
                              icon: "server.rack", showsDivider: false)
                }
                content
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .piDetailNavBar("会话扩展")
        .task(id: catalog.context) { await connection.refreshSessionExtensions(sessionID) }
        .refreshable { await connection.refreshSessionExtensions(sessionID) }
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { ExtensionDetailScreen(runtime: selected) }
        }
        .onChange(of: catalog.context.hostID) { _, _ in selected = nil }
    }

    @ViewBuilder private var content: some View {
        let state = catalog.sessionState(sessionID)
        if catalog.context.online && !catalog.context.sessionSupported {
            ExtensionReadNotice(text: "此服务器版本不支持查看扩展")
        } else if let result = state.value {
            if !result.userLoadingEnabled {
                ExtensionReadNotice(text: "此服务器未启用用户扩展加载")
            }
            if case .loading = state { ExtensionReadNotice(text: "正在读取…") }
            if case .failed = state {
                ExtensionReadNotice(text: "上次读取的数据\(readTime)",
                                    retry: catalog.context.online ? { Task { await connection.refreshSessionExtensions(sessionID) } } : nil)
            }
            if let latest = result.latestAttempt {
                snapshotGroup(latest, title: catalog.context.online ? catalog.sessionResultLabel(sessionID) : "上次记录的加载结果")
            } else {
                ExtensionReadNotice(text: "首次运行后可查看加载结果")
            }
            if let previous = result.previousCompleted,
               previous.id != result.latestAttempt?.id {
                snapshotGroup(previous, title: "上次结果")
            }
        } else if !catalog.context.online {
            ExtensionReadNotice(text: "连接服务器后可查看扩展")
        } else if case let .failed(reason, _) = state {
            ExtensionReadNotice(text: reason, retry: { Task { await connection.refreshSessionExtensions(sessionID) } })
        } else {
            ExtensionReadNotice(text: "正在读取…")
        }
    }

    private var readTime: String {
        guard let date = catalog.lastRead(sessionID) else { return "" }
        return " · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func snapshotGroup(_ snapshot: RACPExtensionSnapshot, title: String) -> some View {
        PIGroup(title) {
            PIListRow(title: snapshot.phase == "loading" ? "扩展正在加载" :
                        snapshot.phase == "failed" ? "本次初始化失败" :
                        snapshot.phase == "ready" ? "已加载 \(snapshot.loadedCount) 项 · 失败 \(snapshot.failedCount) 项" : "加载状态未知",
                      subtitle: ExtensionPresentation.date(snapshot.completedAt ?? snapshot.startedAt),
                      showsDivider: !snapshot.entries.isEmpty || !snapshot.diagnostics.isEmpty)
            ForEach(Array(snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                PIListRow(title: entry.name,
                          subtitle: entry.diagnostics.first?.message ??
                            (entry.loadState == "loaded" ? "\(entry.registeredTools.count) 个工具 · \(entry.activeTools.count) 个采样时启用" : nil),
                          value: ExtensionPresentation.runtimeStatus(entry),
                          showsChevron: true,
                          showsDivider: index < snapshot.entries.count - 1 || !snapshot.diagnostics.isEmpty,
                          action: { selected = entry })
                .accessibilityIdentifier("extensions.entry.\(entry.id)")
            }
            ExtensionDiagnosticsRows(diagnostics: snapshot.diagnostics)
        }
    }
}
