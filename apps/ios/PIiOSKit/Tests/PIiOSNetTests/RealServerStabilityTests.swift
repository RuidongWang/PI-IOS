import XCTest
@testable import PIiOSNet

/// 真实服务器连接稳定性探针（默认跳过）。
///
/// 用与 App 完全相同的 SSH + direct-tcpip + WebSocket + RACP 栈：
/// 1) 用一次性配对令牌换设备令牌；
/// 2) 用设备令牌重建 RACP 连接；
/// 3) 观察 60 秒内是否保持 `online`，并打印每次状态变化与诊断事件。
///
/// ```
/// PI_SSH_HOST=... PI_SSH_USER=ubuntu PI_SSH_KEY=... PI_HOST_PORT=19446 \
///   PI_PAIR_TOKEN=ppt2... swift test --filter RealServerStabilityTests
/// ```
final class RealServerStabilityTests: XCTestCase {
    func testRealServerConnectionStaysOnline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
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
            host: host,
            port: sshPort,
            username: user,
            credential: .privateKey(openSSHText: keyText, passphrase: nil),
            pinnedHostKey: nil
        )
        let transport = try await SSHTransport.connect(
            request,
            confirmer: ProbeHostKeyConfirmer(),
            timeout: 20
        )
        let pair = try await RACPClient.pairOnce(
            using: transport,
            hostPort: hostPort,
            pairingToken: pairToken,
            clientVersion: "0.0.3"
        )
        print("PROBE pair ok deviceId=\(pair.deviceId.prefix(8))")
        await transport.close()

        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: request,
                hostPort: hostPort,
                deviceToken: pair.deviceToken,
                clientVersion: "0.0.3"
            ),
            confirmer: ProbeHostKeyConfirmer()
        )
        let statusStream = await client.statusStream()
        let statusTask = Task {
            for await status in statusStream {
                print("PROBE phase=\(status.phase) route=\(String(describing: status.activeRoute)) sshFailure=\(String(describing: status.sshFailure?.category))")
            }
        }
        let updates = await client.start()
        let updateTask = Task {
            for await update in updates {
                switch update {
                case .state(let state):
                    print("PROBE state=\(state)")
                case .ready(let info):
                    print("PROBE ready server=\(info.serverName)/\(info.serverVersion) hostId=\(info.hostId ?? "-")")
                case .error(let code, _):
                    print("PROBE error=\(code)")
                case .hostSnapshot(let projects, let sessions):
                    print("PROBE snapshot projects=\(projects.count) sessions=\(sessions.count)")
                default:
                    break
                }
            }
        }
        defer {
            statusTask.cancel()
            updateTask.cancel()
        }

        let started = Date()
        var wasOnline = false
        var dropCount = 0
        var onlineSince: Date?
        var didAttach = false
        var firstGeneration: UUID?
        var reconnectGeneration: UUID?
        var sawSocketInterruption = false
        var restartRequested = false
        let restartIsolatedHost = env["PI_RESTART_ISOLATED_HOST"] == "1"
        if restartIsolatedHost {
            guard let isolatedPID = env["PI_ISOLATED_HOST_PID"], Int(isolatedPID) != nil,
                  let isolatedPIDFile = env["PI_ISOLATED_HOST_PID_FILE"] else {
                throw XCTSkip("重启探针需要隔离实例 PID 与专用 PID 文件")
            }
            XCTAssertTrue(isolatedPID.allSatisfy(\.isNumber))
            XCTAssertTrue(isolatedPIDFile.hasPrefix("/tmp/"))
        }
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let state = await client.currentState()
            if state.isOnline {
                if !wasOnline {
                    onlineSince = Date()
                    print(String(format: "PROBE ONLINE +%.1fs", Date().timeIntervalSince(started)))
                }
                wasOnline = true
                if firstGeneration == nil {
                    firstGeneration = await client.connectionStatus().activeGeneration
                }
                if restartIsolatedHost, !restartRequested,
                   let firstGeneration, await client.connectionStatus().activeGeneration == firstGeneration {
                    restartRequested = true
                    print("PROBE restarting isolated host")
                    let isolatedPID = env["PI_ISOLATED_HOST_PID"]!
                    let pidFile = env["PI_ISOLATED_HOST_PID_FILE"]!
                    func sshProbe(_ remoteCommand: String) throws -> Int32 {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                        process.arguments = [
                            "-F", "/dev/null", "-i", keyPath,
                            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                            "-p", String(sshPort), "\(user)@\(host)", remoteCommand
                        ]
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationStatus
                    }
                    let stopped = try sshProbe("test \"$(cat \(pidFile))\" = \(isolatedPID) && kill -TERM \(isolatedPID)")
                    XCTAssertEqual(stopped, 0, "隔离实例正常关闭失败")
                    let restarted = try sshProbe("cd /tmp/pi-ios-release-003/pi-adaptor-0.0.3-linux-x64; nohup node dist/main.js --home /tmp/pi-ios-release-003/home --port 19450 </dev/null >>/tmp/pi-ios-release-003/host.log 2>&1 &")
                    XCTAssertEqual(restarted, 0, "隔离实例重启失败")
                }
                if reconnectGeneration == nil, restartIsolatedHost,
                   let firstGeneration,
                   let generation = await client.connectionStatus().activeGeneration,
                   generation != firstGeneration {
                    reconnectGeneration = generation
                    print("PROBE RECONNECTED new online generation")
                }
                if !didAttach {
                    didAttach = true
                    do {
                        let projects = try await client.listProjects(timeout: 20)
                        print("PROBE projects=\(projects.count)")
                        let sessions = try await client.listSessions(timeout: 20)
                        print("PROBE sessions=\(sessions.count)")
                        if let session = sessions.first {
                            let included = try await client.attach(sessionId: session.id)
                            print("PROBE attach session=\(session.id.prefix(8)) snapshot=\(String(describing: included))")
                        }
                    } catch {
                        print("PROBE attach failed: \(error)")
                    }
                }
            } else if wasOnline {
                dropCount += 1
                print(String(format: "PROBE DROP +%.1fs state=%@", Date().timeIntervalSince(started), String(describing: state)))
                wasOnline = false
            }
        }
        let finalState = await client.currentState()
        let diagnostics = ConnectionDiagnostics.shared.snapshot()
        for event in diagnostics {
            if event.kind == .failure, event.category == .socketInterrupted {
                sawSocketInterruption = true
            }
            print("DIAG \(event.kind.rawValue) detail=\(event.detail ?? "-") phase=\(event.phase ?? "-") route=\(event.route?.rawValue ?? "-") category=\(event.category?.rawValue ?? "-") close=\(event.closeCode.map(String.init) ?? "-") elapsed=\(event.elapsedMs.map(String.init) ?? "-")")
        }
        print("PROBE final=\(finalState) drops=\(dropCount) onlineSince=\(onlineSince.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "-")")
        await client.stop()
        XCTAssertEqual(dropCount, restartIsolatedHost ? 1 : 0, "连接断开次数不符合预期：\(dropCount) 次")
        XCTAssertTrue(finalState.isOnline, "观察期结束时连接应仍为在线，实际：\(finalState)")
        if restartIsolatedHost {
            XCTAssertNotNil(reconnectGeneration, "正常关闭后应使用新的连接代次恢复在线")
            XCTAssertTrue(sawSocketInterruption, "隔离实例关闭应触发传输中断重连，而非终态取消")
        }
    }
}

private struct ProbeHostKeyConfirmer: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
