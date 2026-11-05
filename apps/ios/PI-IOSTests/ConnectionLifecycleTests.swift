import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    func testDisconnectInvalidatesActiveAndCandidateBeforeDelayedFlush() async throws {
        let model = ConnectionModel()
        let host = makeHost()
        let oldClient = makeClient()
        let candidate = makeClient()
        model.installConnectionPiecesForTesting(
            oldClient: oldClient,
            candidate: candidate,
            hostID: host.id
        )
        model.disconnectFlushDelayForTesting = 0.2
        let generation = model.connectionGenerationForTesting

        let disconnect = Task { await model.disconnect() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.activeClient)
        XCTAssertNil(model.candidateClientForTesting)
        XCTAssertEqual(model.connectionGenerationForTesting, generation + 1)
        XCTAssertFalse(model.state.isOnline)
        XCTAssertEqual(model.connectionStatus.phase, .offline)
        await disconnect.value
    }

    func testCandidateFailureDoesNotForceDroppedOldClientOnline() async {
        let model = ConnectionModel()
        let host = makeHost()
        let oldClient = makeClient()
        let candidate = makeClient()
        model.installConnectionPiecesForTesting(
            oldClient: oldClient,
            candidate: candidate,
            hostID: host.id
        )
        // The real old client is already offline, while the stale UI says online.
        let stream = AsyncStream<RACPClientUpdate> { continuation in
            continuation.yield(.state(.online))
            continuation.finish()
        }
        await model.runDirectCandidateForTesting(candidate: candidate, stream: stream, record: host)
        XCTAssertFalse(model.state.isOnline)
        XCTAssertEqual(model.connectionStatus.phase, .offline)
        await oldClient.stop()
        await candidate.stop()
    }

    func testCancellationAfterCandidatePointerExchangeCannotRestoreOnline() async throws {
        let model = ConnectionModel()
        let host = makeHost()
        let oldClient = makeClient()
        let candidate = makeClient()
        await oldClient.setOnlineForTesting()
        model.installConnectionPiecesForTesting(oldClient: oldClient, candidate: candidate, hostID: host.id)
        model.skipCandidateRestoreForTesting = true
        model.candidatePostPromotionDelayForTesting = 0.2
        let task = Task {
            await model.runDirectCandidateForTesting(
                candidate: candidate,
                stream: onlineStream(),
                record: host
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        await model.disconnect()
        await task.value
        XCTAssertNil(model.activeClient)
        XCTAssertFalse(model.state.isOnline)
        XCTAssertEqual(model.connectionStatus.phase, .offline)
    }

    func testOldSSHFailureBeforePromotionBlocksCandidate() async {
        let model = ConnectionModel()
        let host = makeHost()
        let oldClient = makeClient()
        let candidate = makeClient()
        await oldClient.setOnlineForTesting()
        model.installConnectionPiecesForTesting(oldClient: oldClient, candidate: candidate, hostID: host.id)
        model.skipCandidateRestoreForTesting = true
        model.beforeOldStatusCheckForTesting = {
            await oldClient.setOfflineForTesting()
        }
        await model.runDirectCandidateForTesting(
            candidate: candidate,
            stream: onlineStream(),
            record: host
        )
        XCTAssertFalse(model.state.isOnline)
        await oldClient.stop()
        await candidate.stop()
    }

    func testRetryBootstrapDirectDoesNotRunInstallOrPair() async throws {
        let model = ConnectionModel()
        let host = makeHost()
        let outcome = makeInstallOutcome(host: host)
        let trust = try makeTrust(hostId: "host_1", pin: String(repeating: "a", count: 64))
        model.installBootstrapRetryOutcomeForTesting(
            hostID: host.id,
            outcome: outcome,
            trust: trust
        )
        var calls = 0
        model.retryBootstrapDirectHandlerForTesting = { record, candidateTrust, expectedHostId in
            calls += 1
            XCTAssertEqual(record.id, host.id)
            XCTAssertEqual(candidateTrust, trust)
            XCTAssertEqual(expectedHostId, "host_1")
            return (true, nil)
        }
        var events: [String] = []
        model.clearDirectTrustExecutorForTesting = { attemptId in
            events.append("clear:\(attemptId)")
        }
        model.transportCloseExecutorForTesting = {
            events.append("close")
        }
        let result = await model.retryBootstrapDirect(record: host, attemptId: outcome.attemptId)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.installAdaptorCallCountForTesting, 0)
        XCTAssertEqual(result?.directVerified, true)
        XCTAssertEqual(events, ["clear:\(outcome.attemptId)", "close"])
    }

    func testDirectPinIsCommittedOnlyAfterValidationAndFailurePreservesOldPin() async throws {
        let model = ConnectionModel()
        let host = makeHost()
        defer {
            KeychainStore.deleteDirectTLSTrustPin(hostID: host.id)
            KeychainStore.deleteDeviceToken(hostID: host.id, legacyAccount: "", deleteLegacy: false)
        }
        XCTAssertTrue(KeychainStore.savePairing(deviceId: "device_1", deviceToken: "pdt" + "2.lifecycle-test", hostID: host.id))
        let oldPin = DirectTLSTrustPin(
            hostId: "host_1",
            certificateSHA256: String(repeating: "a", count: 64),
            authorizedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(KeychainStore.saveDirectTLSTrustPin(oldPin, hostID: host.id))
        let newTrust = try makeTrust(hostId: "host_1", pin: String(repeating: "b", count: 64))

        model.bootstrapDirectValidationHandlerForTesting = { (false, "tlsTrust") }
        _ = await model.attemptBootstrapDirectForTesting(
            record: host,
            endpoint: host.directEndpoint ?? "",
            trust: newTrust,
            expectedHostId: "host_1"
        )
        XCTAssertEqual(KeychainStore.loadDirectTLSTrustPin(hostID: host.id), oldPin)

        model.bootstrapDirectValidationHandlerForTesting = { (true, nil) }
        _ = await model.attemptBootstrapDirectForTesting(
            record: host,
            endpoint: host.directEndpoint ?? "",
            trust: newTrust,
            expectedHostId: "host_1"
        )
        XCTAssertEqual(
            KeychainStore.loadDirectTLSTrustPin(hostID: host.id)?.certificateSHA256,
            String(repeating: "b", count: 64)
        )
    }

    func testDirectEndpointChangeRequiresReconnectAndSSHOnlyClearsTrustBeforeClose() async throws {
        let record = makeHost()
        var changed = HostDraft(record: record)
        changed.directEndpoint = "wss://changed.example:9443/v1/racp/ws"
        XCTAssertTrue(HostValidator.directConfigurationChanged(record, changed))
        let unchanged = HostDraft(record: record)
        XCTAssertFalse(HostValidator.directConfigurationChanged(record, unchanged))

        let model = ConnectionModel()
        let outcome = makeInstallOutcome(host: record)
        model.installBootstrapRetryOutcomeForTesting(hostID: record.id, outcome: outcome, trust: nil)
        var events: [String] = []
        model.clearDirectTrustExecutorForTesting = { attemptId in
            events.append("clear:\(attemptId)")
        }
        model.transportCloseExecutorForTesting = {
            events.append("close")
        }
        await model.completeInstallSSHOnly(hostID: record.id, attemptId: outcome.attemptId)
        XCTAssertEqual(events, ["clear:\(outcome.attemptId)", "close"])
    }

    private func onlineStream() -> AsyncStream<RACPClientUpdate> {
        AsyncStream { continuation in
            continuation.yield(.state(.online))
            continuation.finish()
        }
    }

    private func makeTrust(hostId: String, pin: String) throws -> BootstrapDirectTrust {
        let json = "{\"schemaVersion\":1,\"attemptId\":\"attempt_1\",\"hostId\":\"\(hostId)\",\"certificateSha256\":\"\(pin)\",\"notBefore\":\"2026-01-01T00:00:00Z\",\"notAfter\":\"2099-01-01T00:00:00Z\"}"
        return try BootstrapDirectTrust.parse(data: Data(json.utf8), expectedAttemptId: "attempt_1")
    }

    private func makeInstallOutcome(host: HostRecord) -> AdaptorInstallRunOutcome {
        let state = BootstrapStateFile(
            attemptId: "attempt_1",
            step: .done,
            status: .ok,
            host: BootstrapHostInfo(platform: "linux", arch: "arm64"),
            artifact: nil,
            service: nil,
            error: nil,
            updatedAt: "2026-01-01T00:00:00Z"
        )
        return AdaptorInstallRunOutcome(
            result: .failed(BootstrapRunFailure(state: state, code: .unitFailed)),
            releaseVersion: "1",
            attemptId: "attempt_1",
            releaseSource: nil,
            adaptorHostId: "host_1",
            directEndpoint: host.directEndpoint,
            directVerified: false,
            directError: "tlsTrust",
            requiresSSHOnlyConfirmation: true
        )
    }

    private func makeHost() -> HostRecord {
        HostRecord(
            id: UUID(),
            name: "Lifecycle",
            host: "localhost",
            port: 22,
            username: "pi",
            authKind: .password,
            createdAt: Date(),
            isCurrent: true,
            pairedAt: Date(),
            hostPort: 1,
            directEndpoint: "wss://localhost:9443/v1/racp/ws",
            adaptorHostId: "host_1"
        )
    }

    private func makeClient() -> RACPClient {
        RACPClient(
            configuration: RACPConfiguration(ssh: nil, hostPort: nil, deviceToken: nil),
            confirmer: LifecycleRejectHost()
        )
    }
}

private struct LifecycleRejectHost: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .reject
    }
}
