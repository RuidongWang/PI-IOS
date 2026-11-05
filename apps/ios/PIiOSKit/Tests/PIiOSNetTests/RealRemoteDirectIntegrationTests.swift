import Foundation
import XCTest
import PIiOSCore

@testable import PIiOSNet

/// Opt-in real-server direct transport probe.
///
/// Environment:
/// - `PI_SSH_HOST`, `PI_SSH_PORT`, `PI_SSH_USER`, `PI_SSH_KEY`
/// - `PI_REAL_DIRECT_LOOPBACK_PORT` (temporary adaptor loopback port used only for pairing)
/// - `PI_REAL_DIRECT_URL`, `PI_REAL_DIRECT_HOST_ID`, `PI_REAL_DIRECT_SHA256`
/// - `PI_REAL_PAIR_TOKEN` (one-shot ppt2 pairing token, never logged)
///
/// SSH is used only to submit the one-shot pairing exchange. The direct RACP
/// connection below has no SSH transport and must reach online(.direct) on its own.
final class RealRemoteDirectIntegrationTests: XCTestCase {
    func testRemoteDirectReachesOnlineAndListsProjectsWithoutSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["PI_REAL_DIRECT_URL"],
              let endpoint = URL(string: rawURL),
              let hostId = environment["PI_REAL_DIRECT_HOST_ID"],
              let pin = environment["PI_REAL_DIRECT_SHA256"] else {
            throw XCTSkip("未配置真实远端 direct 集成环境")
        }
        let deviceToken: String
        if let preissued = environment["PI_REAL_DEVICE_TOKEN"] {
            deviceToken = preissued
        } else {
            guard let host = environment["PI_SSH_HOST"],
                  let user = environment["PI_SSH_USER"],
                  let keyPath = environment["PI_SSH_KEY"],
                  let rawLoopbackPort = environment["PI_REAL_DIRECT_LOOPBACK_PORT"],
                  let loopbackPort = Int(rawLoopbackPort),
                  let pairToken = environment["PI_REAL_PAIR_TOKEN"] else {
                throw XCTSkip("未配置真实远端 direct 配对环境")
            }
            let key = try String(contentsOfFile: keyPath, encoding: .utf8)
            let ssh = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: host,
                    port: Int(environment["PI_SSH_PORT"] ?? "22") ?? 22,
                    username: user,
                    credential: .privateKey(openSSHText: key, passphrase: nil),
                    pinnedHostKey: nil
                ),
                confirmer: RejectUnexpectedRemoteDirectSSH(),
                timeout: 20
            )
            do {
                let paired = try await RACPClient.pairOnce(
                    using: ssh,
                    hostPort: loopbackPort,
                    pairingToken: pairToken,
                    clientVersion: "0.0.2",
                    deviceLabel: "remote-direct-integration"
                )
                deviceToken = paired.deviceToken
            } catch {
                await ssh.close()
                throw error
            }
            await ssh.close()
        }
        XCTAssertTrue(deviceToken.hasPrefix("pdt2."))

        let configuration = RACPConfiguration(
            ssh: nil,
            hostPort: nil,
            deviceToken: deviceToken,
            connectionPreference: .directPreferred,
            direct: DirectRACPConfiguration(
                endpoint: endpoint,
                certificateSHA256: pin,
                adaptorHostId: hostId
            )
        )
        let client = RACPClient(
            configuration: configuration,
            confirmer: RejectUnexpectedRemoteDirectSSH()
        )
        do {
            await client.start()
            let status = try await Self.waitForDirectOnline(client)
            XCTAssertEqual(status.activeRoute, .direct)
            XCTAssertNil(status.directFailure)
            XCTAssertNil(status.sshFailure)
            try await client.ping()
            let projects = try await client.listProjects(timeout: 10)
            XCTAssertTrue(projects.isEmpty, "临时 adaptor 数据目录不应包含预存项目")
            await client.stop()
        } catch {
            await client.stopBestEffort()
            throw error
        }
        let stopped = await client.connectionStatus()
        XCTAssertEqual(stopped.phase, .offline)
    }

    private static func waitForDirectOnline(
        _ client: RACPClient,
        timeout: TimeInterval = 30
    ) async throws -> ConnectionStatus {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var status = await client.connectionStatus()
        while status.phase != .online(.direct), ContinuousClock.now < deadline {
            if status.phase == .failed {
                throw RemoteDirectIntegrationError(description: "真实远端 direct 失败：\(status)")
            }
            try await Task.sleep(for: .milliseconds(50))
            status = await client.connectionStatus()
        }
        guard status.phase == .online(.direct) else {
            throw RemoteDirectIntegrationError(description: "等待真实远端 direct online 超时：\(status)")
        }
        return status
    }
}

private struct RemoteDirectIntegrationError: Error, CustomStringConvertible {
    let description: String
}

private struct RejectUnexpectedRemoteDirectSSH: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .reject
    }
}
