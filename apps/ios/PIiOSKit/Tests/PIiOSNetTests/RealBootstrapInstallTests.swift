import Foundation
import XCTest
@testable import PIiOSCore
@testable import PIiOSNet

/// Opt-in end-to-end installation against a disposable Linux account.
///
/// Required environment:
/// - `PI_BOOTSTRAP_SSH_HOST`, `PI_BOOTSTRAP_SSH_USER`, `PI_BOOTSTRAP_SSH_KEY`
/// - `PI_BOOTSTRAP_PORT` (the loopback port installed into the user unit)
/// - `PI_BOOTSTRAP_RELEASE_BASE_URL` (directory containing both bundles and `.sha256`)
/// Optionally set `PI_BOOTSTRAP_DIRECT_PORT` and `PI_BOOTSTRAP_DIRECT_ENDPOINT` to verify pinned Direct.
final class RealBootstrapInstallTests: XCTestCase {
    func testInstallsPairsStartsUnitAndVerifiesDeviceToken() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_BOOTSTRAP_SSH_HOST"],
              let user = env["PI_BOOTSTRAP_SSH_USER"],
              let keyPath = env["PI_BOOTSTRAP_SSH_KEY"],
              let rawPort = env["PI_BOOTSTRAP_PORT"],
              let port = Int(rawPort) else {
            throw XCTSkip("未配置真实 bootstrap 安装环境")
        }
        let releaseBaseURL = env["PI_BOOTSTRAP_RELEASE_BASE_URL"]
            ?? PIAdaptorRelease.defaultPatchedBaseURL

        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let sshAuth = SSHCredential.privateKey(openSSHText: key, passphrase: nil)
        let transport = try await SSHTransport.connect(
            SSHConnectionRequest(
                host: host,
                port: Int(env["PI_SSH_PORT"] ?? "22") ?? 22,
                username: user,
                credential: sshAuth,
                pinnedHostKey: nil
            ),
            confirmer: AcceptBootstrapHostKey(),
            timeout: 20
        )
        defer { Task { await transport.close() } }

        let probe = try await transport.exec(BootstrapRemoteCommand.probe, timeout: 15)
        XCTAssertEqual(probe.exitStatus, 0)
        let identity = try parseProbe(probe.stdoutText)
        let decision = BootstrapPlatformProbe.decide(
            unameSystem: identity.platform,
            unameMachine: identity.architecture
        )
        let target = try XCTUnwrap(decision.target)
        let release = try XCTUnwrap(
            PIAdaptorRelease.patched(target: target, baseURL: releaseBaseURL)
        )
        let attempt = "real-\(UUID().uuidString.lowercased())"
        let directEndpoint = env["PI_BOOTSTRAP_DIRECT_ENDPOINT"].flatMap(URL.init(string:))
        let direct = try env["PI_BOOTSTRAP_DIRECT_PORT"].flatMap(Int.init).map { directPort in
            try BootstrapDirectConfiguration(directName: host, directPort: directPort, loopbackPort: port)
        }
        let configuration = try BootstrapScriptConfiguration(
            release: release,
            attemptId: attempt,
            hostArchitecture: identity.architecture,
            port: port,
            readyTimeoutSeconds: 120,
            pairTimeoutSeconds: 180,
            stopTimeoutSeconds: 30,
            verifyTimeoutSeconds: 120,
            direct: direct
        )

        let runner = BootstrapRunner(
            transport: transport,
            pairing: BootstrapInstallPairingAdapter(),
            verifier: BootstrapInstallVerificationAdapter(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 1,
                overallTimeout: 10 * 60,
                stallThreshold: 3 * 60,
                commandTimeout: 30,
                pairingCallbackTimeout: 120,
                verificationCallbackTimeout: 60
            )
        )
        let result = try await runner.run(
            configuration: configuration,
            deviceLabel: "PI-IOS real bootstrap test",
            keepTransportOpen: direct != nil
        )

        guard case let .succeeded(success) = result else {
            return XCTFail("真实安装未成功：\(result)")
        }
        XCTAssertEqual(success.state.step, .done)
        XCTAssertEqual(success.state.status, .ok)
        XCTAssertEqual(success.state.service?.state, "active")
        XCTAssertEqual(success.port, port)
        XCTAssertFalse(success.device.deviceToken.isEmpty)
        if direct != nil {
            let endpoint = try XCTUnwrap(directEndpoint)
            let output = try await transport.exec(BootstrapRemoteCommand.readDirectTrust(attemptId: attempt), timeout: 15)
            XCTAssertEqual(output.exitStatus, 0)
            let trust = try BootstrapDirectTrust.parse(data: output.stdout, expectedAttemptId: attempt)
            let client = RACPClient(configuration: RACPConfiguration(
                ssh: nil, hostPort: nil, deviceToken: success.device.deviceToken, connectionPreference: .directPreferred,
                direct: DirectRACPConfiguration(endpoint: endpoint, certificateSHA256: trust.certificateSHA256, adaptorHostId: trust.hostId)
            ), confirmer: AcceptBootstrapHostKey())
            defer { Task { await client.stopBestEffort() } }
            let updates = await client.start()
            for await update in updates {
                if case .state(.online) = update {
                    try await client.ping()
                    print("CASE Linux bootstrap pinned direct PASS")
                    return
                }
                if case .state(.offline(let reason)) = update {
                    return XCTFail("Direct 首验失败：\(reason ?? "连接关闭")")
                }
            }
            XCTFail("Direct 首验未完成")
        }
    }

    private func parseProbe(_ stdout: String) throws -> (platform: String, architecture: String) {
        var platform: String?
        var architecture: String?
        for line in stdout.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "platform" { platform = pair[1] }
            if pair[0] == "arch" { architecture = pair[1] }
        }
        guard let platform, let architecture else {
            throw BootstrapRunnerError.malformedProbe
        }
        return (platform, architecture)
    }
}

private struct AcceptBootstrapHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        TestHostKeyPolicy.confirm(key)
    }
}
