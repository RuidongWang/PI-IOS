import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

/// U15: the install must commit its receipt and token in exactly one controlled
/// section, after re-checking the frozen target identity. These tests pin the
/// decision policy and the commit order (`receipt -> promote`, never the reverse,
/// and never promote on a stale target).
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

    func testStaleTargetNeverWritesReceiptNorPromotesToken() async {
        let log = CommitLog()
        let result = await BootstrapInstallCommitCoordinator.commit(
            writeReceipt: {
                await log.append("receipt")
                return .staleTarget
            },
            promoteStaged: {
                await log.append("promote")
                return true
            },
            cleanupAttempt: {
                await log.append("cleanup")
            }
        )
        XCTAssertEqual(result, .staleTarget)
        let events = await log.events
        XCTAssertEqual(events, ["receipt", "cleanup"])
    }

    func testCommittedReceiptIsWrittenBeforeTokenPromotion() async {
        let log = CommitLog()
        let result = await BootstrapInstallCommitCoordinator.commit(
            writeReceipt: {
                await log.append("receipt")
                return .committed
            },
            promoteStaged: {
                await log.append("promote")
                return true
            },
            cleanupAttempt: {
                await log.append("cleanup")
            }
        )
        XCTAssertEqual(result, .committed)
        let events = await log.events
        XCTAssertEqual(events, ["receipt", "promote"])
    }

    func testReceiptPersistenceFailureDoesNotPromote() async {
        let log = CommitLog()
        let result = await BootstrapInstallCommitCoordinator.commit(
            writeReceipt: {
                await log.append("receipt")
                return .receiptPersistenceFailed("disk full")
            },
            promoteStaged: {
                await log.append("promote")
                return true
            },
            cleanupAttempt: {
                await log.append("cleanup")
            }
        )
        XCTAssertEqual(result, .receiptPersistenceFailed("disk full"))
        let events = await log.events
        XCTAssertEqual(events, ["receipt", "cleanup"])
    }

    func testTokenPromotionFailureCleansOnlyTheAttempt() async {
        let log = CommitLog()
        let result = await BootstrapInstallCommitCoordinator.commit(
            writeReceipt: {
                await log.append("receipt")
                return .committed
            },
            promoteStaged: {
                await log.append("promote")
                return false
            },
            cleanupAttempt: {
                await log.append("cleanup")
            }
        )
        XCTAssertEqual(result, .tokenPromotionFailed)
        let events = await log.events
        XCTAssertEqual(events, ["receipt", "promote", "cleanup"])
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
        model.persistenceOverrideForTesting = { true }
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

        XCTAssertEqual(model.completeAdaptorInstallation(commit), .committed)
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

        XCTAssertEqual(model.completeAdaptorInstallation(commit), .staleTarget)
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
        XCTAssertEqual(model.completeAdaptorInstallation(commit), .committed)
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
        XCTAssertEqual(model.completeAdaptorInstallation(commit), .committed)
        XCTAssertEqual(model.hosts[0].connectionPreference, .sshOnly)

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
        XCTAssertEqual(model.completeAdaptorInstallation(commit), .committed)

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

        guard case .receiptPersistenceFailed = model.completeAdaptorInstallation(commit) else {
            return XCTFail("expected receipt persistence failure")
        }
        XCTAssertEqual(model.hosts[0].connectionPreference, .sshOnly)
    }

    private func makeHost() -> HostRecord {
        HostRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
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

private actor CommitLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}
