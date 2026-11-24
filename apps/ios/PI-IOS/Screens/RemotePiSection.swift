import SwiftUI
import PIiOSCore
import PIiOSNet

struct RemotePiSection: View {
    let host: HostRecord
    let isEnabled: Bool

    @EnvironmentObject private var connection: ConnectionModel
    @State private var installed: RemotePiVersion?
    @State private var latest: RemotePiVersion?
    @State private var activity: Activity?
    @State private var message: String?
    @State private var hasError = false
    @State private var showsUpgradeConfirmation = false

    private enum Activity { case checking, upgrading }

    private var canAct: Bool { isEnabled && activity == nil }
    private var canUpgrade: Bool {
        guard canAct, let installed, let latest else { return false }
        return installed.needsUpgrade(to: latest)
    }

    var body: some View {
        PIGroup("Pi CLI") {
            PIListRow(title: "服务器版本", value: installed?.value ?? "未查询", isEnabled: false)
                .accessibilityIdentifier("servers.pi.installed")
            PIListRow(title: "官方最新版本", value: latest?.value ?? "未查询", isEnabled: false)
                .accessibilityIdentifier("servers.pi.latest")
            PIListRow(
                title: activity == .checking ? "正在查询版本…" : "查询 Pi 版本",
                icon: "arrow.clockwise",
                isEnabled: canAct,
                action: { Task { await checkVersions() } }
            )
            .accessibilityIdentifier("servers.pi.check")
            PIListRow(
                title: activity == .upgrading ? "正在升级 Pi…" : "升级 Pi",
                icon: "arrow.down.circle",
                isEnabled: canUpgrade,
                showsDivider: message != nil,
                action: { showsUpgradeConfirmation = true }
            )
            .accessibilityIdentifier("servers.pi.upgrade")
            if let message {
                PIInlineMessage(kind: hasError ? .danger : .success, text: message)
                    .padding(.horizontal, PISpacing.s16)
                    .padding(.vertical, PISpacing.s12)
                    .accessibilityIdentifier("servers.pi.status")
            }
        }
        .confirmationDialog("升级「\(host.name)」上的 Pi CLI？", isPresented: $showsUpgradeConfirmation, titleVisibility: .visible) {
            if let installed, let latest {
                Button("确认升级") { Task { await upgrade(from: installed, toAtLeast: latest) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let installed, let latest {
                Text("当前版本 \(installed.value)，官方版本 \(latest.value)。将使用此服务器账户下的 Pi 自更新命令，并在完成后验证版本。")
            }
        }
    }

    private func checkVersions() async {
        guard canAct else { return }
        activity = .checking
        defer { activity = nil }
        message = nil
        installed = nil
        latest = nil
        do {
            let current = try await connection.installedPiVersion(record: host)
            installed = current
            let stable = try await RemotePiMaintenance.latestVersion()
            latest = stable
            if !current.needsUpgrade(to: stable) {
                hasError = false
                message = "服务器版本已达到官方最新版本。"
            }
        } catch {
            hasError = true
            message = ConnectionErrorText.describe(error)
        }
    }

    private func upgrade(from expected: RemotePiVersion, toAtLeast target: RemotePiVersion) async {
        guard canUpgrade, installed == expected, latest == target else { return }
        activity = .upgrading
        defer { activity = nil }
        message = nil
        do {
            let verified = try await connection.upgradePiCLI(record: host, from: expected, toAtLeast: target)
            installed = verified
            hasError = false
            message = "已升级到 Pi \(verified.value)。"
        } catch {
            installed = nil
            hasError = true
            message = ConnectionErrorText.describe(error)
        }
    }
}
