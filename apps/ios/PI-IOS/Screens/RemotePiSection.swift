import SwiftUI
import PIiOSNet

/// 展示当前服务器由 PI-adaptor 自带并返回的 Pi 版本信息。
struct RemotePiSection: View {
    let host: HostRecord

    @EnvironmentObject private var connection: ConnectionModel

    private var activeServerInfo: RACPServerInfo? {
        guard connection.currentCatalogHostID == host.id,
              connection.state.isOnline else {
            return nil
        }
        return connection.info
    }

    private var versionText: String {
        guard let info = activeServerInfo else {
            return "未连接"
        }
        guard let piVersion = info.piVersion, !piVersion.isEmpty else {
            return "未提供"
        }
        return piVersion
    }

    var body: some View {
        PIGroup("Pi") {
            PIListRow(
                title: "Pi 版本",
                subtitle: "由 PI-adaptor 自带并返回",
                value: versionText,
                isEnabled: false,
                showsDivider: false
            )
            .accessibilityIdentifier("servers.pi.version")
        }
    }
}
