import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

/// 真实服务器「连接建立后立即断开」复现探针（默认跳过）。
///
/// 走 App 真实层：`ConnectionModel.connect` → `RACPClient`（SSH + direct-tcpip + WS + RACP），
/// 与真机启动时相同的自动重连与状态流；在线后按 AppModel 的路径 attach 最近会话。
///
/// ```
/// PI_SSH_HOST=... PI_SSH_USER=ubuntu PI_SSH_KEY=... PI_HOST_PORT=19445 \
///   PI_PAIR_TOKEN=ppt2... xcodebuild ... -only-testing:PI-IOSTests/RealAppConnectionTests test
/// ```
@MainActor
final class RealAppConnectionTests: XCTestCase {
    func testAppLayerConnectionStaysOnline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let hostName = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"],
              let portRaw = env["PI_HOST_PORT"],
              let hostPort = Int(portRaw),
              let pairToken = env["PI_PAIR_TOKEN"]
        else {
            throw XCTSkip("未设置 PI_SSH_HOST / PI_SSH_USER / PI_SSH_KEY / PI_HOST_PORT / PI_PAIR_TOKEN")
        }
        let sshPort = Int(env["PI_SSH_PORT"] ?? "22") ?? 22
        let keyText = try String(contentsOfFile: keyPath, encoding: .utf8)
        let request = SSHConnectionRequest(
            host: hostName,
            port: sshPort,
            username: user,
            credential: .privateKey(openSSHText: keyText, passphrase: nil),
            pinnedHostKey: nil
        )
        let transport = try await SSHTransport.connect(request, confirmer: TestConfirmer(), timeout: 20)
        let pair = try await RACPClient.pairOnce(
            using: transport,
            hostPort: hostPort,
            pairingToken: pairToken,
            clientVersion: "0.0.3"
        )
        await transport.close()
        print("APP-PROBE pair deviceId=\(pair.deviceId.prefix(8))")

        let host = HostRecord(
            id: UUID(),
            name: "real-probe",
            host: hostName,
            port: sshPort,
            username: user,
            authKind: .privateKey,
            createdAt: Date(),
            isCurrent: true,
            pairedAt: Date(),
            tunnelUpAt: nil,
            hostPort: hostPort,
            keyFileName: "probe",
            installReceipt: nil
        )
        let account = KeychainStore.account(username: user, host: hostName, port: sshPort)
        XCTAssertTrue(KeychainStore.saveCredential(
            .privateKey(openSSHText: keyText, passphrase: nil),
            kind: .privateKey,
            account: account
        ))
        XCTAssertTrue(KeychainStore.savePairing(
            deviceId: pair.deviceId,
            deviceToken: pair.deviceToken,
            hostID: host.id
        ))
        defer {
            KeychainStore.deleteCredential(account: account)
            KeychainStore.deleteDeviceToken(hostID: host.id, legacyAccount: account, deleteLegacy: false)
        }

        let model = ConnectionModel()
        model.setCacheHostID(host.id)
        await model.connect(record: host)

        let started = Date()
        var wasOnline = false
        var dropCount = 0
        var didAttach = false
        var hostKeyTrust = 0
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let prompt = model.hostKeyPrompt, hostKeyTrust < 2 {
                hostKeyTrust += 1
                model.respondHostKey(.trust, operationID: prompt.operationID)
            }
            let state = model.state
            let phase = model.connectionStatus.phase
            if state.isOnline {
                if !wasOnline {
                    print(String(format: "APP-PROBE ONLINE +%.1fs", Date().timeIntervalSince(started)))
                }
                wasOnline = true
                if !didAttach {
                    didAttach = true
                    _ = await model.refreshRemote()
                    if let session = model.sessions.first {
                        await model.session.attach(sessionId: session.id)
                        print("APP-PROBE attached session=\(session.id.prefix(8))")
                    }
                }
            } else if wasOnline {
                dropCount += 1
                print(String(format: "APP-PROBE DROP +%.1fs state=%@ phase=%@ lastError=%@",
                             Date().timeIntervalSince(started),
                             String(describing: state),
                             String(describing: phase),
                             model.lastError ?? "-"))
                wasOnline = false
            }
        }
        let diagnostics = ConnectionDiagnostics.shared.snapshot()
        for event in diagnostics {
            print("APP-DIAG \(event.kind.rawValue) detail=\(event.detail ?? "-") phase=\(event.phase ?? "-") category=\(event.category?.rawValue ?? "-") close=\(event.closeCode.map(String.init) ?? "-") elapsed=\(event.elapsedMs.map(String.init) ?? "-")")
        }
        print("APP-PROBE final=\(model.state) phase=\(model.connectionStatus.phase) drops=\(dropCount) lastError=\(model.lastError ?? "-")")
        XCTAssertTrue(model.state.isOnline, "观察期结束时应仍在线，实际：\(model.state)")
        await model.disconnect()
        XCTAssertEqual(dropCount, 0, "App 层连接在 60 秒观察期内断开 \(dropCount) 次")
    }
}

private struct TestConfirmer: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
