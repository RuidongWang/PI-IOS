import Darwin
import Foundation
import XCTest

@testable import PIiOSNet

final class RealDirectWSSIntegrationTests: XCTestCase {
    func testRealDirectWSSAuthenticatesAndListsProjectsWithoutSSH() async throws {
        let environment = ProcessInfo.processInfo.environment
        for tool in ["node", "pnpm", "openssl"] {
            guard DirectIOSServerProcess.executable(named: tool, environment: environment) != nil else {
                throw XCTSkip("缺少 \(tool)，无法执行本地真实 iOS↔adaptor WSS 集成测试")
            }
        }
        let pnpm = try XCTUnwrap(
            DirectIOSServerProcess.executable(named: "pnpm", environment: environment)
        )
        let repositoryRoot = Self.repositoryRoot
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent("apps/pi-adaptor/package.json").path
            ),
            "#filePath 推导的 repo 根目录无效：\(repositoryRoot.path)"
        )

        let launched = try DirectIOSServerProcess.launch(
            repositoryRoot: repositoryRoot,
            pnpm: pnpm,
            environment: environment
        )
        let server = launched.server
        defer { server.close() }
        let fixture = launched.payload

        let endpoint = try XCTUnwrap(
            URL(string: "wss://127.0.0.1:\(fixture.directPort)/v1/racp/ws")
        )
        let configuration = RACPConfiguration(
            ssh: nil,
            hostPort: nil,
            deviceToken: fixture.deviceToken,
            connectionPreference: .directPreferred,
            direct: DirectRACPConfiguration(
                endpoint: endpoint,
                certificateSHA256: fixture.certificateSha256,
                adaptorHostId: fixture.hostId
            )
        )
        // 生产 LiveRACPConnectionFactory 会创建 DirectRACPWebSocket；这里不注入任何 socket/factory。
        let client = RACPClient(
            configuration: configuration,
            confirmer: RejectUnexpectedDirectIntegrationSSH()
        )

        do {
            await client.start()
            let status = try await Self.waitForDirectOnline(client)
            XCTAssertEqual(status.activeRoute, .direct)
            XCTAssertNil(status.directFailure)
            XCTAssertNil(status.sshFailure)

            // online(.direct) 的前置已经包含真实 WSS 上的认证 ping、pong 和 ping.hostId 核对。
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

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func waitForDirectOnline(
        _ client: RACPClient,
        timeout: TimeInterval = 20
    ) async throws -> ConnectionStatus {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var status = await client.connectionStatus()
        while status.phase != .online(.direct), ContinuousClock.now < deadline {
            if status.phase == .failed {
                throw DirectIOSServerError(description: "真实 direct 连接失败，最后状态：\(status)")
            }
            try await Task.sleep(for: .milliseconds(20))
            status = await client.connectionStatus()
        }
        guard status.phase == .online(.direct) else {
            throw DirectIOSServerError(description: "等待真实 direct online 超时，最后状态：\(status)")
        }
        return status
    }
}

private struct RejectUnexpectedDirectIntegrationSSH: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .reject
    }
}

private struct DirectIOSServerError: Error, CustomStringConvertible {
    let description: String
}

private final class DirectIOSServerProcess: @unchecked Sendable {
    struct Payload: Decodable {
        let hostId: String
        let directPort: Int
        let certificateSha256: String
        let deviceToken: String

        func validate() throws {
            guard !hostId.isEmpty,
                  (1...65_535).contains(directPort),
                  certificateSha256.count == 64,
                  certificateSha256 == certificateSha256.lowercased(),
                  certificateSha256.allSatisfy(\.isHexDigit),
                  deviceToken.hasPrefix("pdt2."),
                  !deviceToken.contains(where: \.isWhitespace)
            else {
                throw DirectIOSServerError(description: "Node fixture 首行 JSON 字段无效")
            }
        }
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var startupResult: Result<Payload, Error>?
    private var launched = false
    private var closed = false

    static func executable(named name: String, environment: [String: String]) -> URL? {
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for component in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = component.isEmpty ? "." : String(component)
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func launch(
        repositoryRoot: URL,
        pnpm: URL,
        environment: [String: String]
    ) throws -> (server: DirectIOSServerProcess, payload: Payload) {
        let server = DirectIOSServerProcess()
        server.configure(repositoryRoot: repositoryRoot, pnpm: pnpm, environment: environment)
        do {
            try server.process.run()
            server.lock.withLock { server.launched = true }
        } catch {
            throw DirectIOSServerError(description: "无法启动 pnpm fixture：\(error.localizedDescription)")
        }

        guard server.startupSemaphore.wait(timeout: .now() + 30) == .success else {
            server.close()
            throw DirectIOSServerError(description: "等待 Node fixture 首行 JSON 超时")
        }
        do {
            let payload = try server.payloadAfterStartup()
            server.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return (server, payload)
        } catch {
            server.close()
            throw error
        }
    }

    func close() {
        let wasLaunched = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return launched
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        guard wasLaunched else { return }

        if process.isRunning {
            process.terminate() // SIGTERM：Node fixture 关闭两个 listener 并删除临时目录。
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func configure(
        repositoryRoot: URL,
        pnpm: URL,
        environment: [String: String]
    ) {
        process.executableURL = pnpm
        process.arguments = [
            "--dir", "apps/pi-adaptor",
            "exec", "tsx", "test/fixtures/direct-ios-server.ts",
        ]
        process.currentDirectoryURL = repositoryRoot
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.lock.withLock { self.stderrBuffer.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            self?.completeStartup(.failure(DirectIOSServerError(
                description: "Node fixture 在输出启动 JSON 前退出（status \(process.terminationStatus)）"
            )))
        }
    }

    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else {
            completeStartup(.failure(DirectIOSServerError(
                description: "Node fixture stdout 在首行 JSON 前关闭\(stderrSummary())"
            )))
            return
        }
        let firstLine: Data? = lock.withLock {
            stdoutBuffer.append(data)
            guard let newline = stdoutBuffer.firstIndex(of: 0x0A) else { return nil }
            return Data(stdoutBuffer.prefix(upTo: newline))
        }
        guard let firstLine else { return }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: firstLine)
            try payload.validate()
            completeStartup(.success(payload))
        } catch {
            completeStartup(.failure(DirectIOSServerError(
                description: "无法解析 Node fixture 首行 JSON：\(error.localizedDescription)"
            )))
        }
    }

    private func completeStartup(_ result: Result<Payload, Error>) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard startupResult == nil else { return false }
            startupResult = result
            return true
        }
        if shouldSignal { startupSemaphore.signal() }
    }

    private func payloadAfterStartup() throws -> Payload {
        let result = lock.withLock { startupResult }
        guard let result else {
            throw DirectIOSServerError(description: "Node fixture 启动结果缺失")
        }
        do {
            return try result.get()
        } catch {
            throw DirectIOSServerError(
                description: "\(error.localizedDescription)\(stderrSummary())"
            )
        }
    }

    private func stderrSummary() -> String {
        let text = lock.withLock {
            String(decoding: stderrBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return "" }
        return "；stderr：\(text.suffix(4_000))"
    }
}
