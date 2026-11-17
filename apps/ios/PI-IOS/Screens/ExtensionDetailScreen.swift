import SwiftUI
import UIKit
import PIiOSCore

struct ExtensionDetailScreen: View {
    private let inventory: RACPExtensionInventoryEntry?
    private let runtime: RACPExtensionRuntimeEntry?
    @State private var copied = false

    init(inventory: RACPExtensionInventoryEntry) { self.inventory = inventory; self.runtime = nil }
    init(runtime: RACPExtensionRuntimeEntry) { self.inventory = nil; self.runtime = runtime }

    private var name: String { inventory?.name ?? runtime?.name ?? "扩展" }
    private var diagnostics: [RACPExtensionDiagnostic] { inventory?.diagnostics ?? runtime?.diagnostics ?? [] }
    private var version: String? { inventory?.configuredVersion ?? runtime?.configuredVersion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                PIGroup("扩展信息") {
                    PIListRow(title: name, subtitle: inventory.map(ExtensionPresentation.inventoryStatus)
                                ?? runtime.map(ExtensionPresentation.runtimeStatus), showsDivider: version != nil)
                    if let version { PIListRow(title: "配置版本", subtitle: version, showsDivider: false) }
                }
                if let inventory {
                    PIGroup("来源") {
                        PIListRow(title: "服务器配置", subtitle: inventory.entryPath)
                        PIListRow(title: copied ? "已复制入口路径" : "复制入口路径", icon: "doc.on.doc", showsDivider: false, action: {
                            UIPasteboard.general.string = inventory.entryPath
                            copied = true
                        })
                        .accessibilityIdentifier("extensions.copyPath")
                    }
                }
                if let runtime {
                    PIGroup("注册工具") {
                        if runtime.registeredTools.isEmpty {
                            PIListRow(title: "未注册工具", showsDivider: false)
                        }
                        ForEach(Array(runtime.registeredTools.enumerated()), id: \.offset) { index, tool in
                            PIListRow(title: tool, value: runtime.activeTools.contains(tool) ? "采样时启用" : "采样时未启用",
                                      showsDivider: index < runtime.registeredTools.count - 1)
                        }
                    }
                    if !runtime.registeredCommands.isEmpty {
                        PIGroup("注册命令") {
                            ForEach(Array(runtime.registeredCommands.enumerated()), id: \.offset) { index, command in
                                PIListRow(title: command, subtitle: "尚未接入手机调用",
                                          showsDivider: index < runtime.registeredCommands.count - 1)
                            }
                        }
                    }
                }
                if !diagnostics.isEmpty {
                    PIGroup("诊断") {
                        ExtensionDiagnosticsRows(diagnostics: diagnostics)
                        PIListRow(title: copied ? "已复制" : "复制诊断", icon: "doc.on.doc", showsDivider: false, action: {
                            UIPasteboard.general.string = diagnostics.map { "[\($0.stage)] \($0.code): \($0.message)" }.joined(separator: "\n")
                            copied = true
                        })
                        .accessibilityIdentifier("extensions.copyDiagnostics")
                    }
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .piDetailNavBar("扩展详情")
    }
}

struct ExtensionDiagnosticsRows: View {
    let diagnostics: [RACPExtensionDiagnostic]

    var body: some View {
        ForEach(Array(diagnostics.enumerated()), id: \.offset) { index, diagnostic in
            PIListRow(title: diagnostic.message,
                      subtitle: "\(stageLabel(diagnostic.stage)) · \(ExtensionPresentation.date(diagnostic.occurredAt))",
                      icon: diagnostic.severity == "error" ? "exclamationmark.triangle" : "info.circle",
                      iconTint: diagnostic.severity == "error" ? PIColor.danger : PIColor.warning,
                      showsDivider: index < diagnostics.count - 1)
        }
    }

    private func stageLabel(_ stage: String) -> String {
        switch stage {
        case "validation": return "入口检查"
        case "load": return "加载"
        case "startup": return "初始化"
        case "runtime": return "运行"
        case "cleanup": return "清理"
        default: return "诊断"
        }
    }
}
