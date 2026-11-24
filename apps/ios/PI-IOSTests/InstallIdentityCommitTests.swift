import Combine
import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

/// U15: the installation must re-check the frozen target before promoting its token.
final class InstallIdentityCommitTests: XCTestCase {
    func testSnapshotMatchesEveryFrozenIdentityField() {
        let base = makeTarget()
        XCTAssertTrue(base.matches(base))

        XCTAssertFalse(base.matches(makeTarget(hostID: UUID())))
        XCTAssertFalse(base.matches(makeTarget(host: "other.example")))
        XCTAssertFalse(base.matches(makeTarget(sshPort: 2222)))
        XCTAssertFalse(base.matches(makeTarget(username: "root")))
        // The loopback port can be discovered during the install and is not an
        // identity field; a manual edit bumps identityGeneration instead.
        XCTAssertTrue(base.matches(makeTarget(hostPort: 45_000)))
        XCTAssertTrue(base.matches(makeTarget(hostPort: nil)))
        XCTAssertFalse(base.matches(makeTarget(directEndpoint: nil)))
        XCTAssertFalse(base.matches(makeTarget(identityGeneration: 1)))
    }

    func testCommitPolicyRejectsChangedIdentityAndDifferentAdaptorHostId() {
        let expected = makeTarget()
        XCTAssertTrue(
            BootstrapInstallCommitPolicy.canCommit(
                expected: expected,
                current: expected,
                existingAdaptorHostId: nil,
                committedAdaptorHostId: "host_new"
            )
        )
        XCTAssertTrue(
            BootstrapInstallCommitPolicy.canCommit(
                expected: expected,
                current: expected,
                existingAdaptorHostId: "host_new",
                committedAdaptorHostId: "host_new"
            )
        )
        XCTAssertFalse(
            BootstrapInstallCommitPolicy.canCommit(
                expected: expected,
                current: makeTarget(identityGeneration: 1),
                existingAdaptorHostId: nil,
                committedAdaptorHostId: "host_new"
            )
        )
        // The record was re-paired to a different PI-adaptor: the old token must
        // never replace the newer pairing even if the SSH identity still matches.
        XCTAssertFalse(
            BootstrapInstallCommitPolicy.canCommit(
                expected: expected,
                current: expected,
                existingAdaptorHostId: "host_b",
                committedAdaptorHostId: "host_a"
            )
        )
    }

    private func makeTarget(
        hostID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        host: String = "pi.example",
        sshPort: Int = 22,
        username: String = "pi",
        hostPort: Int? = 44_271,
        directEndpoint: String? = "wss://pi.example:9443/v1/racp/ws",
        identityGeneration: Int = 0
    ) -> InstallTargetSnapshot {
        InstallTargetSnapshot(
            hostID: hostID,
            host: host,
            sshPort: sshPort,
            username: username,
            hostPort: hostPort,
            directEndpoint: directEndpoint,
            identityGeneration: identityGeneration
        )
    }
}

@MainActor
final class AppModelInstallCommitTests: XCTestCase {
    func testMatchingTargetCommitsReceiptOnceAndExposesInstallState() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        var promoted = false
        var persisted = 0
        model.persistenceOverrideForTesting = {
            XCTAssertTrue(promoted)
            persisted += 1
            return true
        }
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        let commit = BootstrapPairingCommit(
            target: target,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: "wss://pi.example:9443/v1/racp/ws"
        )

        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: {
            XCTAssertNil(model.hosts[0].pairedAt)
            XCTAssertNil(model.hosts[0].installReceipt)
            promoted = true
            return true
        }), .committed)
        XCTAssertEqual(persisted, 1)
        XCTAssertEqual(model.hosts[0].hostPort, 44_271)
        XCTAssertEqual(model.hosts[0].adaptorHostId, "host_new")
        XCTAssertNotNil(model.hosts[0].pairedAt)
        XCTAssertEqual(model.hosts[0].installReceipt?.attemptId, "attempt-a")
        XCTAssertEqual(model.hosts[0].installReceipt?.hostPort, 44_271)
        XCTAssertEqual(model.hosts[0].directEndpoint, "wss://pi.example:9443/v1/racp/ws")

        // A second commit of the same attempt must not duplicate the receipt path:
        // it sees the same target generation and would only rewrite identical data.
        // The screen no longer calls this a second time; assert the receipt count is 1.
        XCTAssertNotNil(model.hosts[0].installReceipt)
    }

    func testChangedTargetReturnsStaleAndWritesNothing() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        let stale = InstallTargetSnapshot(
            hostID: target.hostID,
            host: "other.example",
            sshPort: target.sshPort,
            username: target.username,
            hostPort: target.hostPort,
            directEndpoint: target.directEndpoint,
            identityGeneration: target.identityGeneration
        )
        let commit = BootstrapPairingCommit(
            target: stale,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: nil
        )

        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: {
            XCTFail("a stale install must not promote its credential")
            return true
        }), .staleTarget)
        XCTAssertNil(model.hosts[0].hostPort)
        XCTAssertNil(model.hosts[0].pairedAt)
        XCTAssertNil(model.hosts[0].installReceipt)
        XCTAssertNil(model.hosts[0].adaptorHostId)
    }

    func testIdentityEditBumpsGenerationAndInvalidatesFrozenTarget() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let frozen = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))

        var draft = HostDraft(record: host)
        draft.username = "another-user"
        XCTAssertTrue(model.updateHost(id: host.id, with: draft))
        XCTAssertGreaterThan(
            model.installIdentityGeneration(forHostID: host.id),
            frozen.identityGeneration
        )

        let commit = BootstrapPairingCommit(
            target: frozen,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: nil
        )
        XCTAssertEqual(model.completeAdaptorInstallation(commit), .staleTarget)
        XCTAssertNil(model.hosts[0].installReceipt)
    }

    func testDiscoveredLoopbackPortDoesNotInvalidateTheFrozenTarget() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        XCTAssertNil(model.hosts[0].hostPort)

        // The install discovers the loopback port over SSH before the commit.
        model.applyDiscoveredHostPort(hostID: host.id, port: 44_271)
        XCTAssertEqual(model.hosts[0].hostPort, 44_271)
        XCTAssertEqual(
            model.installIdentityGeneration(forHostID: host.id),
            target.identityGeneration
        )

        let commit = BootstrapPairingCommit(
            target: target,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: nil
        )
        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: { true }), .committed)
        XCTAssertEqual(model.hosts[0].installReceipt?.hostPort, 44_271)
    }

    func testVerifiedDirectRouteAfterCommitPromotesDirectPreference() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let endpoint = "wss://pi.example:9443/v1/racp/ws"
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        let commit = BootstrapPairingCommit(
            target: target,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: endpoint
        )
        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: { true }), .committed)
        XCTAssertEqual(model.hosts[0].connectionPreference, .sshOnly)

        // Register cleanup before the first write; a partial failure must not
        // leave a scoped Keychain entry behind.
        defer {
            _ = KeychainStore.deleteDirectTLSTrustPin(hostID: host.id)
            _ = KeychainStore.deleteDeviceToken(
                hostID: host.id,
                legacyAccount: KeychainStore.account(
                    username: host.username,
                    host: host.host,
                    port: host.port
                ),
                deleteLegacy: false
            )
        }
        let keychainReady = KeychainStore.savePairing(
            deviceId: "dev_install",
            deviceToken: "pdt2." + "test",
            hostID: host.id
        ) && KeychainStore.saveDirectTLSTrustPin(
            DirectTLSTrustPin(
                hostId: "host_new",
                certificateSHA256: String(repeating: "a", count: 64),
                authorizedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            hostID: host.id
        )
        guard keychainReady else {
            throw XCTSkip("模拟器 Keychain 不可写，跳过 direct 偏好提升用例")
        }

        XCTAssertTrue(model.markDirectVerified(
            id: host.id,
            endpoint: endpoint,
            adaptorHostId: "host_new"
        ))
        XCTAssertEqual(model.hosts[0].connectionPreference, .directPreferred)
        XCTAssertEqual(
            KeychainStore.loadDirectTLSTrustPin(hostID: host.id)?.hostId,
            "host_new"
        )
    }

    func testDirectVerificationFailureLeavesSSHOnlyAndKeepsDiagnostics() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let endpoint = "wss://pi.example:9443/v1/racp/ws"
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        let commit = BootstrapPairingCommit(
            target: target,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: endpoint
        )
        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: { true }), .committed)

        // Direct failed before saving a pin: the preference must stay sshOnly and
        // the endpoint/diagnostic fields remain available for the retry view.
        XCTAssertFalse(model.markDirectVerified(
            id: host.id,
            endpoint: endpoint,
            adaptorHostId: "host_new"
        ))
        XCTAssertEqual(model.hosts[0].connectionPreference, .sshOnly)
        XCTAssertEqual(model.hosts[0].directEndpoint, endpoint)
    }

    func testReceiptPersistenceFailureReturnsFailureWithoutCommittingDirectPreference() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { false }
        let target = try XCTUnwrap(model.hosts.first.map(model.installTargetSnapshot(for:)))
        let commit = BootstrapPairingCommit(
            target: target,
            adaptorHostId: "host_new",
            port: 44_271,
            version: "0.0.2",
            attemptId: "attempt-a",
            releaseSource: nil,
            directEndpoint: "wss://pi.example:9443/v1/racp/ws"
        )

        guard case .receiptPersistenceFailed = model.completeAdaptorInstallation(commit, promoteStaged: { true }) else {
            return XCTFail("expected receipt persistence failure")
        }
        XCTAssertEqual(model.hosts[0].connectionPreference, .sshOnly)
    }

    func testFailedKeychainPromotionDoesNotRecordPairing() throws {
        let host = makeHost()
        let model = AppModel(seed: PersistedState(hosts: [host]))
        var writes = 0
        model.persistenceOverrideForTesting = {
            writes += 1
            return true
        }
        let commit = BootstrapPairingCommit(
            target: model.installTargetSnapshot(for: host), adaptorHostId: "host_new",
            port: 44_271, version: "0.0.6", attemptId: "attempt-a", releaseSource: .latest, directEndpoint: nil
        )
        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: { false }), .tokenPromotionFailed)
        XCTAssertEqual(model.hosts[0], host)
        XCTAssertEqual(model.hosts[0].pairingText, "未配对")
        XCTAssertEqual(writes, 0)
    }

    func testPromotedCredentialRecoversReceiptOnReload() throws {
        let host = makeHost()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stateURL = directory.appendingPathComponent("state-v1.json")
        let initial = PersistedState(hosts: [host])
        let attempt = "receipt-recovery"
        let token = "pdt2." + "test-receipt-recovery"
        defer {
            KeychainStore.clearStagedPairing(hostID: host.id, attemptId: attempt)
            KeychainStore.deleteDeviceToken(
                hostID: host.id, legacyAccount: host.address, deleteLegacy: false
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try StateFile.save(initial, to: stateURL)
        let model = AppModel(seed: initial, stateFileURL: stateURL)
        model.persistenceOverrideForTesting = { false }
        let commit = BootstrapPairingCommit(
            target: model.installTargetSnapshot(for: host), adaptorHostId: "host_new",
            port: 44_271, version: "0.0.6", attemptId: attempt, releaseSource: .fallback, directEndpoint: nil
        )
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_install", deviceToken: token, hostID: host.id, attemptId: attempt, targetPort: commit.port
        ))
        guard case .receiptPersistenceFailed = model.completeAdaptorInstallation(commit) else {
            return XCTFail("expected receipt persistence failure")
        }
        XCTAssertNil(model.hosts[0].pairedAt)
        XCTAssertNil(StateFile.load(from: stateURL).state.hosts[0].installReceipt)
        XCTAssertEqual(KeychainStore.pendingInstall(hostID: host.id)?.attemptId, attempt)

        let recovered = AppModel(stateFileURL: stateURL)
        XCTAssertNotNil(recovered.hosts[0].pairedAt)
        XCTAssertEqual(recovered.hosts[0].hostPort, commit.port)
        XCTAssertEqual(recovered.hosts[0].installReceipt?.releaseSource, .fallback)
        XCTAssertEqual(StateFile.load(from: stateURL).state.hosts[0].installReceipt?.attemptId, attempt)
        XCTAssertEqual(KeychainStore.loadDeviceToken(hostID: host.id), token)
        XCTAssertNil(KeychainStore.pendingInstall(hostID: host.id))
    }

    func testReconnectWaitsForThePromotedCredentialAndNewPortToMatch() async throws {
        var host = makeHost()
        host.hostPort = 19_445
        host.pairedAt = Date()
        host.adaptorHostId = "host_reinstall"
        let model = AppModel(seed: PersistedState(hosts: [host]))
        var canSave = false
        model.persistenceOverrideForTesting = { canSave }
        let commit = BootstrapPairingCommit(
            target: model.installTargetSnapshot(for: host), adaptorHostId: "host_reinstall",
            port: 44_271, version: "0.0.6", attemptId: "receipt-reconnect", releaseSource: .latest, directEndpoint: nil
        )
        defer {
            KeychainStore.deleteDeviceToken(hostID: host.id, legacyAccount: host.address, deleteLegacy: false)
        }
        XCTAssertTrue(KeychainStore.savePairing(deviceId: "dev_old", deviceToken: "pdt2.old-token", hostID: host.id))
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_new", deviceToken: "pdt2.new-token", hostID: host.id,
            attemptId: commit.attemptId, targetPort: commit.port
        ))
        guard case .receiptPersistenceFailed = model.completeAdaptorInstallation(commit) else {
            return XCTFail("expected receipt persistence failure")
        }

        let recoveryRequired = RACPTunnelState.offline(reason: "配对记录待恢复：请重新连接以重试保存。")
        let pending = expectation(description: "connection stops until the pending receipt can be saved")
        let observation = model.connection.$state.filter { $0 == recoveryRequired }.prefix(1).sink { _ in pending.fulfill() }
        defer { observation.cancel() }
        await model.setCurrentHost(id: host.id, waitForOnline: false)
        await fulfillment(of: [pending], timeout: 3)
        XCTAssertEqual(model.connection.state, recoveryRequired)
        XCTAssertEqual(model.currentHost?.hostPort, host.hostPort)
        XCTAssertEqual(KeychainStore.pendingInstall(hostID: host.id)?.attemptId, commit.attemptId)

        canSave = true
        await model.setCurrentHost(id: host.id, waitForOnline: false)
        XCTAssertEqual(model.currentHost?.hostPort, commit.port)
        XCTAssertEqual(model.currentHost?.installReceipt?.attemptId, commit.attemptId)
        XCTAssertEqual(KeychainStore.loadDeviceToken(hostID: host.id), "pdt2.new-token")
        XCTAssertNil(KeychainStore.pendingInstall(hostID: host.id))
    }

    func testReplacedPairingRevocationWaitsForReceiptAndRetriesOnFailure() async throws {
        let host = makeHost()
        let hostID = host.id
        let connection = ConnectionModel()
        let target = InstallTargetSnapshot(
            hostID: host.id, host: host.host, sshPort: host.port, username: host.username,
            hostPort: 19_445, directEndpoint: nil, identityGeneration: 0
        )
        let commit = BootstrapPairingCommit(
            target: target, adaptorHostId: "host_reinstall", port: 44_271, version: "0.0.6",
            attemptId: "revoke-after-receipt", releaseSource: .latest, directEndpoint: nil
        )
        let previousToken = "pdt2." + "retired-fixture"
        let replacementToken = "pdt2." + "replacement-fixture"
        defer {
            KeychainStore.clearStagedPairing(hostID: hostID, attemptId: commit.attemptId)
            KeychainStore.deleteDeviceToken(hostID: hostID, legacyAccount: host.address, deleteLegacy: false)
        }
        XCTAssertTrue(KeychainStore.savePairing(deviceId: "dev_old", deviceToken: previousToken, hostID: hostID))
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_new", deviceToken: replacementToken, hostID: hostID,
            attemptId: commit.attemptId, targetPort: commit.port
        ))
        XCTAssertTrue(KeychainStore.promoteStagedPairing(
            hostID: hostID, attemptId: commit.attemptId, pendingInstall: commit
        ))
        var calls = 0
        connection.bootstrapRevocationHandlerForTesting = { port, deviceID, token, expectedHostID in
            XCTAssertEqual(port, commit.port)
            XCTAssertEqual(deviceID, "dev_old")
            XCTAssertEqual(token, replacementToken)
            XCTAssertEqual(expectedHostID, commit.adaptorHostId)
            calls += 1
            return calls == 1 ? .unknown : .revoked
        }

        await connection.recoverReplacedPairings(record: host, port: commit.port, adaptorHostId: commit.adaptorHostId)
        XCTAssertEqual(calls, 0)
        KeychainStore.clearPendingInstall(hostID: hostID, attemptId: commit.attemptId)
        await connection.recoverReplacedPairings(record: host, port: commit.port, adaptorHostId: "different_host")
        XCTAssertEqual(calls, 0)
        await connection.recoverReplacedPairings(record: host, port: commit.port, adaptorHostId: commit.adaptorHostId)
        XCTAssertEqual(KeychainStore.pendingPairingRevocations(hostID: hostID, activeToken: replacementToken).map(\.deviceId), ["dev_old"])
        await connection.recoverReplacedPairings(record: host, port: commit.port, adaptorHostId: commit.adaptorHostId)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(KeychainStore.pendingPairingRevocations(hostID: hostID, activeToken: replacementToken).isEmpty)
        XCTAssertEqual(KeychainStore.loadDeviceId(hostID: hostID), "dev_new")
    }

    func testAbandonedPairingCredentialSurvivesUnconfirmedRevocation() async {
        let host = makeHost()
        let connection = ConnectionModel()
        let attempt = "abandoned-attempt"
        let activeToken = "pdt2." + "active-fixture"
        let stagedToken = "pdt2." + "abandoned-fixture"
        defer {
            KeychainStore.clearStagedPairing(hostID: host.id, attemptId: attempt)
            KeychainStore.deleteDeviceToken(hostID: host.id, legacyAccount: host.address, deleteLegacy: false)
        }
        XCTAssertTrue(KeychainStore.savePairing(deviceId: "dev_active", deviceToken: activeToken, hostID: host.id))
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_abandoned", deviceToken: stagedToken, hostID: host.id,
            attemptId: attempt, targetPort: 44_271
        ))
        var calls = 0
        connection.bootstrapRevocationHandlerForTesting = { port, deviceID, token, _ in
            XCTAssertEqual(port, 44_271)
            XCTAssertEqual(deviceID, "dev_abandoned")
            XCTAssertEqual(token, stagedToken)
            calls += 1
            return calls == 1 ? .failed : .revoked
        }
        await connection.recoverStagedPairings(record: host)
        XCTAssertEqual(KeychainStore.loadStagedPairing(hostID: host.id, attemptId: attempt)?.deviceId, "dev_abandoned")
        await connection.recoverStagedPairings(record: host)
        XCTAssertEqual(calls, 2)
        XCTAssertNil(KeychainStore.loadStagedPairing(hostID: host.id, attemptId: attempt))
        XCTAssertEqual(KeychainStore.loadDeviceId(hostID: host.id), "dev_active")
    }

    func testPromotionDoesNotRetireCredentialBoundToDifferentAdaptor() {
        let hostID = UUID()
        let firstAttempt = "already-paired"
        let secondAttempt = "different-adaptor"
        let firstToken = "pdt2." + "first-fixture"
        let secondToken = "pdt2." + "second-fixture"
        defer {
            KeychainStore.clearStagedPairing(hostID: hostID, attemptId: firstAttempt)
            KeychainStore.clearStagedPairing(hostID: hostID, attemptId: secondAttempt)
            KeychainStore.deleteDeviceToken(hostID: hostID, legacyAccount: "fixture", deleteLegacy: false)
        }
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_first", deviceToken: firstToken, hostID: hostID, attemptId: firstAttempt, targetPort: 19_445
        ))
        XCTAssertTrue(KeychainStore.promoteStagedPairing(
            hostID: hostID, attemptId: firstAttempt, verifiedAdaptorHostId: "host_first"
        ))
        XCTAssertTrue(KeychainStore.saveStagedPairing(
            deviceId: "dev_second", deviceToken: secondToken, hostID: hostID, attemptId: secondAttempt, targetPort: 44_271
        ))
        XCTAssertTrue(KeychainStore.promoteStagedPairing(
            hostID: hostID, attemptId: secondAttempt, verifiedAdaptorHostId: "host_second"
        ))
        XCTAssertTrue(KeychainStore.pendingPairingRevocations(hostID: hostID, activeToken: secondToken).isEmpty)
        XCTAssertEqual(KeychainStore.loadDeviceId(hostID: hostID), "dev_second")
    }

    func testLeavingInstallationResolvesPendingDirectAuthorization() async throws {
        let coordinator = InstallAdaptorCoordinator()
        let json = """
        {"schemaVersion":1,"attemptId":"audit-direct","hostId":"host_reinstall",
         "certificateSha256":"\(String(repeating: "a", count: 64))",
         "notBefore":"2026-01-01T00:00:00Z","notAfter":"2099-01-01T00:00:00Z"}
        """
        let trust = try BootstrapDirectTrust.parse(data: Data(json.utf8), expectedAttemptId: "audit-direct")
        let finished = expectation(description: "authorization caller unblocked after leaving the page")
        Task { @MainActor in
            let authorized = await coordinator.requestDirectAuthorization(trust)
            XCTAssertFalse(authorized)
            finished.fulfill()
        }
        await Task.yield()
        XCTAssertEqual(coordinator.pendingDirectTrust, trust)

        coordinator.cancel()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertNil(coordinator.pendingDirectTrust)
    }

    func testSSHOnlyReinstallClearsThePreviouslyVerifiedDirectRoute() {
        var host = makeHost()
        host.directEndpoint = "wss://pi.example:9443/v1/racp/ws"
        host.connectionPreference = .directPreferred
        host.adaptorHostId = "host_reinstall"
        let model = AppModel(seed: PersistedState(hosts: [host]))
        model.persistenceOverrideForTesting = { true }
        let commit = BootstrapPairingCommit(
            target: model.installTargetSnapshot(for: host), adaptorHostId: "host_reinstall",
            port: 44_271, version: "0.0.6", attemptId: "ssh-only", releaseSource: .latest, directEndpoint: nil
        )

        XCTAssertEqual(model.completeAdaptorInstallation(commit, promoteStaged: { true }), .committed)
        XCTAssertNil(model.currentHost?.directEndpoint)
        XCTAssertEqual(model.currentHost?.connectionPreference, .sshOnly)
    }

    private func makeHost() -> HostRecord {
        HostRecord(
            id: UUID(),
            name: "Install",
            host: "pi.example",
            port: 22,
            username: "pi",
            authKind: .password,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isCurrent: true
        )
    }
}
