import Foundation
import XCTest
@testable import PIiOSNet

/// Real direct RACP discovery smoke test. No SSH credential or SSH exec is used.
final class RealModelDiscoveryTests: XCTestCase {
    func testRemoteModelDiscoveryUsesActiveDirectRACP() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpointRaw = env["PI_DIRECT_ENDPOINT"],
              let endpoint = URL(string: endpointRaw),
              let deviceToken = env["PI_DIRECT_DEVICE_TOKEN"],
              let certificateSHA256 = env["PI_DIRECT_CERTIFICATE_SHA256"],
              let adaptorHostId = env["PI_DIRECT_HOST_ID"],
              let url = env["PI_MODEL_DISCOVERY_URL"],
              let apiKey = env["PI_MODEL_DISCOVERY_KEY"]
        else {
            throw XCTSkip("未配置 direct RACP 模型发现环境变量")
        }
        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: nil,
                hostPort: nil,
                deviceToken: deviceToken,
                connectionPreference: .directPreferred,
                direct: DirectRACPConfiguration(
                    endpoint: endpoint,
                    certificateSHA256: certificateSHA256,
                    adaptorHostId: adaptorHostId
                )
            ),
            confirmer: RejectDirectDiscoveryHostKey()
        )
        defer { Task { await client.stop() } }
        let updates = await client.start()
        var isOnline = false
        for await update in updates {
            if case .state(.online) = update {
                isOnline = true
                break
            }
        }
        guard isOnline else { throw RACPClientError.notConnected }

        let models = try await RemoteProviderOperations.discoverModels(
            client: client,
            requestURL: url,
            apiKey: apiKey
        )
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { !$0.modelId.isEmpty })
    }
}

private struct RejectDirectDiscoveryHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .reject
    }
}
