import CryptoKit
import Foundation
import XCTest

@testable import PIiOSCore

/// Runs the generated POSIX script against isolated fake curl/systemd. The
/// installed package uses the production installer from apps/pi-adaptor/scripts.
final class BootstrapScriptIntegrationTests: XCTestCase {
    private let pairingToken = "ppt2." + "integration-token"
    private let attemptId = "boot_integration"

    func testInstallsImmutablePIAdaptorReleaseAndStartsNewUnit() throws {
        let environment = try makeEnvironment()
        try writeExecutable(
            #"""
            #!/bin/sh
            case "${3:-}" in
              "$HOME"/.pi-adaptor/.bootstrap/attempts/*/state.json)
                if grep -q '"step":"done","status":"ok"' "$2"; then
                  [ "$2" = "$HOME/.pi-adaptor/.bootstrap/transaction.active" ] || exit 1
                fi
                ;;
            esac
            exec /bin/mv "$@"
            """#,
            to: environment.root.appendingPathComponent("fake-bin/mv")
        )
        let legacyRoot = environment.home
            .appendingPathComponent(".pi-desktop/pi-host", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyRoot.appendingPathComponent("pi-host.js"))
        try Data("0.21.0  old  manifest\n".utf8)
            .write(to: legacyRoot.appendingPathComponent(".release.sha256"))

        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(process) }
        try completePairingHandshake(environment: environment, process: process)

        let failureOutput = try capturedFailure(environment)
        XCTAssertEqual(process.terminationStatus, 0, failureOutput)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.status, .ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.workDirectory.appendingPathComponent("transaction.active").path))
        XCTAssertEqual(try permissions(environment.stateURL), 0o600)
        XCTAssertEqual(try permissions(environment.workDirectory), 0o700)

        let current = environment.installRoot.appendingPathComponent("current")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: current.path),
            "releases/2.0.1-\(environment.assetSha256)"
        )
        let package = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: current.appendingPathComponent("package.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(package["name"] as? String, "@pi-ios/pi-adaptor")
        XCTAssertEqual(package["version"] as? String, "2.0.1")

        let unit = try String(
            contentsOf: environment.home.appendingPathComponent(
                ".config/systemd/user/pi-adaptor.service"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(unit.contains("Description=PI-adaptor"))
        XCTAssertTrue(unit.contains("current/dist/main.js"))
        XCTAssertFalse(unit.contains(".pi-desktop/pi-host"))
        XCTAssertFalse(unit.contains("--pair"))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path
            )
        )
        XCTAssertEqual(try serviceEnablement(environment), "enabled\n")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("pi-host.js").path),
            "legacy data must remain isolated and untouched"
        )

        let pairURL = environment.attemptDirectory.appendingPathComponent("pair.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairURL.path))
        for output in try persistedOutputs(environment) {
            XCTAssertFalse(output.contains(pairingToken), "pairing token must never be logged")
        }
    }

    func testOpenSSLFailureDuringSANChangeKeepsOldIdentityAndLoopbackSucceeds() throws {
        let environment = try makeEnvironment(opensslFails: true, existingDirectIdentity: true)
        let direct = try BootstrapDirectConfiguration(
            directName: "new.example",
            directPort: 9443,
            loopbackPort: 43_871
        )
        let process = try launch(
            script: generatedScript(environment, direct: direct),
            environment: environment
        )
        defer { terminateIfNeeded(process) }
        try completePairingHandshake(environment: environment, process: process)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.status, .ok)
        let tls = environment.installRoot.appendingPathComponent("tls", isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: tls.appendingPathComponent("direct-cert.pem")), Data("old-cert".utf8))
        XCTAssertEqual(try Data(contentsOf: tls.appendingPathComponent("direct-key.pem")), Data("old-key".utf8))
        XCTAssertEqual(try Data(contentsOf: tls.appendingPathComponent("direct-name")), Data("old.example\n".utf8))
        let unit = try String(
            contentsOf: environment.home.appendingPathComponent(".config/systemd/user/pi-adaptor.service"),
            encoding: .utf8
        )
        XCTAssertTrue(unit.contains("PI_ADAPTOR_DIRECT_ENABLED=0"))
    }

    func testScopedAttemptPublishesDirectTrustAndRollbackRestoresTLSIdentity() throws {
        let environment = try makeEnvironment(
            piAdaptorInitiallyActive: true, piAdaptorEnableState: "enabled-runtime", existingDirectIdentity: true
        )
        let previous = try installCurrentFixture("2.0.0", in: environment)
        let direct = try BootstrapDirectConfiguration(directName: "new.example", directPort: 9443, loopbackPort: 43_871)
        let process = try launch(script: generatedScript(environment, direct: direct), environment: environment)
        defer { terminateIfNeeded(process) }

        let trustFile = environment.attemptDirectory.appendingPathComponent("direct-trust.json")
        let trust = try BootstrapDirectTrust.parse(data: waitForFile(trustFile, timeout: 10), expectedAttemptId: attemptId)
        XCTAssertEqual(trust.hostId, "host_fake")
        let tls = environment.installRoot.appendingPathComponent("tls")
        let cert = tls.appendingPathComponent("direct-cert.pem")
        let key = tls.appendingPathComponent("direct-key.pem")
        XCTAssertEqual(try Data(contentsOf: cert), Data("new-cert".utf8))
        XCTAssertEqual(try Data(contentsOf: key), Data("new-key".utf8))

        try writeMarker("ok", to: environment.attemptDirectory.appendingPathComponent("pair.result"))
        try waitForState(environment.stateURL, timeout: 10, matching: { $0.step == .verifyDevice })
        XCTAssertEqual(try serviceEnablement(environment), "enabled\n")
        try writeMarker("failed", to: environment.attemptDirectory.appendingPathComponent("verify.result"))
        try waitForExit(process, timeout: 10)

        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .verifyDeviceFailed)
        XCTAssertEqual(state.error?.value(at: ["details", "rollback"])?.stringValue, "succeeded")
        XCTAssertEqual(try serviceEnablement(environment), "enabled-runtime\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: environment.installRoot.appendingPathComponent("current").path), previous)
        XCTAssertEqual(try Data(contentsOf: cert), Data("old-cert".utf8))
        XCTAssertEqual(try Data(contentsOf: key), Data("old-key".utf8))
        XCTAssertEqual(try Data(contentsOf: tls.appendingPathComponent("direct-name")), Data("old.example\n".utf8))
    }

    func testDownloadFailureResumesAndDoesNotSwitchCurrent() throws {
        let environment = try makeEnvironment(downloadMode: "fail-once")
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(first, timeout: 10)
        XCTAssertNotEqual(first.terminationStatus, 0)
        let firstState = try decodeState(environment.stateURL)
        XCTAssertEqual(firstState.step, .download)
        XCTAssertEqual(firstState.failureCode, .downloadFailed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )

        let second = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailureOutput)
        XCTAssertEqual(try decodeState(environment.stateURL).step, .done)
    }

    func testDowngradeIsBlockedBeforeDownloadEvenForForceReinstall() throws {
        let environment = try makeEnvironment(piAdaptorInitiallyActive: true)
        let previous = try installCurrentFixture("2.0.10", in: environment)
        let current = environment.installRoot.appendingPathComponent("current")
        let process = try launch(script: generatedScript(environment, force: true), environment: environment)
        defer { terminateIfNeeded(process) }
        try waitForExit(process, timeout: 10)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .downgradeBlocked)
        XCTAssertEqual(state.failureDetails?.actualVersion, "2.0.10")
        XCTAssertEqual(state.failureDetails?.expectedVersion, "2.0.1")
        XCTAssertEqual(try downloadCount(environment), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: environment.workDirectory.appendingPathComponent(environment.artifactName + ".sha256").path
        ))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path))
    }

    func testDowngradeIsBlockedWhenTheActiveInvocationIsNewerThanCurrent() throws {
        let environment = try makeEnvironment(piAdaptorInitiallyActive: true, runningVersion: "2.0.10")
        let previous = try installCurrentFixture("2.0.0", in: environment)
        let process = try launch(script: generatedScript(environment), environment: environment)
        defer { terminateIfNeeded(process) }
        try waitForExit(process, timeout: 10)

        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .downgradeBlocked)
        XCTAssertEqual(state.failureDetails?.actualVersion, "2.0.10")
        XCTAssertEqual(try downloadCount(environment), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: environment.installRoot.appendingPathComponent("current").path), previous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path))
    }

    func testUnverifiableActiveInvocationStopsBeforeDownload() throws {
        let environment = try makeEnvironment(piAdaptorInitiallyActive: true, runningVersion: nil)
        let process = try launch(script: generatedScript(environment), environment: environment)
        defer { terminateIfNeeded(process) }
        try waitForExit(process, timeout: 10)

        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .runningVersionUnknown)
        XCTAssertEqual(try downloadCount(environment), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path))
    }

    func testRecoveryKeepsAnAttemptThatPublishedSuccessBeforeCleanup() throws {
        let environment = try makeEnvironment(piAdaptorInitiallyActive: true)
        let previous = try installCurrentFixture("2.0.10", in: environment)
        let completed = environment.workDirectory.appendingPathComponent("attempts/boot_previous")
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try Data(#"{"version":1,"attemptId":"boot_previous","step":"done","status":"ok","error":null}"#.appending("\n").utf8)
            .write(to: completed.appendingPathComponent("state.json"))
        let activeTransaction = environment.workDirectory.appendingPathComponent("transaction.active")
        try writeMarker("boot_previous", to: activeTransaction)

        let process = try launch(script: generatedScript(environment), environment: environment)
        defer { terminateIfNeeded(process) }
        try waitForExit(process, timeout: 10)

        XCTAssertEqual(try decodeState(environment.stateURL).failureCode, .downgradeBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeTransaction.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: environment.installRoot.appendingPathComponent("current").path), previous)
    }

    func testSecondAttemptIsBusyAndCannotChangeTheFirstAttempt() throws {
        let environment = try makeEnvironment()
        func command(_ operation: String, id: String, input: URL? = nil) throws -> Int32 {
            try runProcess(
                "/bin/sh", arguments: ["-c", BootstrapRemoteCommand.scoped(operation, attemptId: id)],
                environment: environment.processEnvironment, input: input
            ).status
        }
        XCTAssertEqual(try command(BootstrapRemoteCommand.installScript, id: attemptId, input: generatedScript(environment)), 0)
        addTeardownBlock {
            let lock = environment.workDirectory.appendingPathComponent("active.lock")
            guard FileManager.default.fileExists(atPath: lock.path) else { return }
            _ = try command(BootstrapRemoteCommand.cancel, id: self.attemptId)
            let deadline = Date().addingTimeInterval(10)
            while FileManager.default.fileExists(atPath: lock.path) {
                guard Date() < deadline else { throw IntegrationError.timeout("detached bootstrap exit") }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        XCTAssertEqual(try command(BootstrapRemoteCommand.launch, id: attemptId), 0)
        let pairURL = environment.attemptDirectory.appendingPathComponent("pair.json")
        let firstPair = try waitForFile(pairURL, timeout: 10)
        let logURL = environment.attemptDirectory.appendingPathComponent("bootstrap.log")
        let firstLog = try Data(contentsOf: logURL)
        let activePID = environment.workDirectory.appendingPathComponent("active.lock/pid")
        let firstPID = try Data(contentsOf: activePID)

        let secondId = "boot_other"
        XCTAssertEqual(try command(BootstrapRemoteCommand.installScript, id: secondId, input: generatedScript(environment, attemptId: secondId)), 0)
        XCTAssertEqual(try command(BootstrapRemoteCommand.cancel, id: secondId), 0)
        XCTAssertEqual(try command(BootstrapRemoteCommand.launch, id: secondId), 75)
        XCTAssertEqual(try Data(contentsOf: pairURL), firstPair)
        XCTAssertTrue(try Data(contentsOf: logURL).starts(with: firstLog))
        XCTAssertEqual(try Data(contentsOf: activePID), firstPID)
        XCTAssertEqual(try decodeState(environment.stateURL).attemptId, attemptId)

        XCTAssertEqual(try command(BootstrapRemoteCommand.writePairingOK, id: attemptId), 0)
        try waitForState(environment.stateURL, timeout: 10, matching: { $0.step == .verifyDevice })
        XCTAssertEqual(try command(BootstrapRemoteCommand.writeVerificationOK, id: attemptId), 0)
        try waitForState(environment.stateURL, timeout: 10, matching: { $0.status == .ok })
        XCTAssertEqual(try downloadCount(environment), 1)
    }

    func testChecksumMismatchLeavesNoCurrentOrStage() throws {
        let environment = try makeEnvironment(validChecksum: false)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 8)
        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.step, .resolve)
        XCTAssertEqual(state.failureCode, .checksumMismatch)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: environment.installRoot.path
        ).filter { $0.hasPrefix(".stage.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testForceReinstallDownloadsAgainAndKeepsTargetVersion() throws {
        let environment = try makeEnvironment()
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try completePairingHandshake(environment: environment, process: first)
        let firstFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(first.terminationStatus, 0, firstFailureOutput)
        XCTAssertEqual(try downloadCount(environment), 1)

        let second = try launch(
            script: generatedScript(environment, force: true),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailureOutput = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailureOutput)
        XCTAssertEqual(try downloadCount(environment), 2)

        let current = environment.installRoot.appendingPathComponent("current")
        let installedVersion = try String(
            contentsOf: current.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        XCTAssertTrue(installedVersion.contains(#""version":"2.0.1""#))
    }

    func testVerifiedReceiptReusesImmutableReleaseWithoutDownloading() throws {
        let environment = try makeEnvironment()
        let first = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try completePairingHandshake(environment: environment, process: first)
        let firstFailure = try capturedFailure(environment)
        XCTAssertEqual(first.terminationStatus, 0, firstFailure)
        XCTAssertEqual(try downloadCount(environment), 1)

        let second = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(second) }
        try completePairingHandshake(environment: environment, process: second)
        let secondFailure = try capturedFailure(environment)
        XCTAssertEqual(second.terminationStatus, 0, secondFailure)
        XCTAssertEqual(try downloadCount(environment), 1)

        let receiptData = try Data(
            contentsOf: environment.workDirectory.appendingPathComponent("install-receipt.json")
        )
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
        )
        XCTAssertEqual(receipt["bundleDirectory"] as? String, environment.release.bundleDirectoryName)
        XCTAssertEqual(receipt["version"] as? String, "2.0.1")
        XCTAssertEqual(receipt["target"] as? String, "linux-arm64")
    }

    func testLegacyPPT1IsRejectedAndTransactionRollsBack() throws {
        let environment = try makeEnvironment(tokenPrefix: "ppt1")
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 15)
        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        XCTAssertEqual(
            state.error?.value(at: ["details", "reason"])?.stringValue,
            "legacy-pairing-token"
        )
        XCTAssertEqual(try serviceEnablement(environment), "disabled\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testLegacyUnitIsStoppedOnlyWhenItOccupiesTheTargetPort() throws {
        let environment = try makeEnvironment(legacyConflict: true)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        defer { terminateIfNeeded(process) }
        try completePairingHandshake(environment: environment, process: process)

        let failure = try capturedFailure(environment)
        XCTAssertEqual(process.terminationStatus, 0, failure)
        XCTAssertEqual(try decodeState(environment.stateURL).step, .done)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
    }

    func testLegacyConflictIsRestoredAfterFailedInstall() throws {
        let environment = try makeEnvironment(tokenPrefix: "ppt1", legacyConflict: true)
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 15)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(legacyUnits.first?.value(at: ["unit"])?.stringValue, "pi-host.service")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.installRoot.appendingPathComponent("current").path
            )
        )
    }

    func testLegacyEnabledRuntimeIsDisabledAndRestoredExactly() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            legacyEnableState: "enabled-runtime"
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnableState"])?.stringValue,
            "enabled-runtime"
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnabled"])?.boolValue,
            true
        )
        XCTAssertEqual(
            try String(
                contentsOf: environment.home.appendingPathComponent(".fake-legacy-enable-state"),
                encoding: .utf8
            ),
            "enabled-runtime\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
    }

    func testLinkedLegacyUnitIsStoppedWithoutChangingEnableState() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            legacyEnableState: "linked"
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .pairFailed)
        let legacyUnits = try XCTUnwrap(
            state.error?.value(at: ["details", "legacyUnits"])?.arrayValue
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnableState"])?.stringValue,
            "linked"
        )
        XCTAssertEqual(
            legacyUnits.first?.value(at: ["originalEnabled"])?.boolValue,
            false
        )
        XCTAssertEqual(
            try String(
                contentsOf: environment.home.appendingPathComponent(".fake-legacy-enable-state"),
                encoding: .utf8
            ),
            "linked\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-active").path
            )
        )
    }

    func testRollbackReportsFailureAndPreservesTransactionWhenServiceStopFails() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            failPiAdaptorStop: true,
            piAdaptorInitiallyActive: true
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .unknown("rollback-failed"))
        XCTAssertEqual(
            state.error?.value(at: ["details", "rollback"])?.stringValue,
            "failed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-pi-adaptor-active").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testRollbackReportsFailureWhenLegacyRestoreCannotComplete() throws {
        let environment = try makeEnvironment(
            tokenPrefix: "ppt1",
            legacyConflict: true,
            failLegacyRestore: true
        )
        let process = try launch(
            script: generatedScript(environment),
            environment: environment
        )
        try waitForExit(process, timeout: 20)

        XCTAssertNotEqual(process.terminationStatus, 0)
        let state = try decodeState(environment.stateURL)
        XCTAssertEqual(state.failureCode, .unknown("rollback-failed"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: environment.home.appendingPathComponent(".fake-legacy-enabled").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: environment.workDirectory.appendingPathComponent("transaction.active").path
            )
        )
    }

    func testInstallerRejectsPreviousTargetTraversalWithoutDeletingVictim() throws {
        let environment = try makeEnvironment()
        let releases = environment.installRoot.appendingPathComponent("releases", isDirectory: true)
        let victim = environment.installRoot.appendingPathComponent("victim", isDirectory: true)
        let marker = victim.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            atPath: environment.installRoot.appendingPathComponent("current").path,
            withDestinationPath: "releases/../victim"
        )

        let bundle = environment.root
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(environment.release.bundleDirectoryName, isDirectory: true)
        let manifestDigest = sha256(try Data(contentsOf: bundle.appendingPathComponent("SHA256SUMS")))
        let installer = repositoryRoot().appendingPathComponent("apps/pi-adaptor/scripts/install.sh")

        let install = try runProcess(
            "/bin/bash",
            arguments: [
                installer.path,
                "--install",
                "--bundle", bundle.path,
                "--home", environment.installRoot.path,
                "--version", "2.0.1",
                "--target", "linux-arm64",
                "--asset-sha256", environment.assetSha256,
                "--" + "manifest-sha256", manifestDigest,
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(install.status, 5, install.stderr)
        XCTAssertTrue(install.stderr.contains("canonical release directory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: releases.path), [])

        let rollback = try runProcess(
            "/bin/bash",
            arguments: [
                installer.path,
                "--rollback",
                "--home", environment.installRoot.path,
                "--previous-current-target", "releases/../victim",
                "--failed-install-dir", "none",
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(rollback.status, 8, rollback.stderr)
        XCTAssertTrue(rollback.stderr.contains("canonical release directory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStandaloneInstallerRestoresCurrentWhenReceiptCannotBePublished() throws {
        let environment = try makeEnvironment()
        let previous = try installCurrentFixture("2.0.0", in: environment)
        let receipt = environment.workDirectory.appendingPathComponent("install-receipt.json", isDirectory: true)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        let bundle = environment.root.appendingPathComponent("source/\(environment.release.bundleDirectoryName)")
        let manifestDigest = sha256(try Data(contentsOf: bundle.appendingPathComponent("SHA256SUMS")))
        let install = try runProcess(
            "/bin/bash",
            arguments: [
                repositoryRoot().appendingPathComponent("apps/pi-adaptor/scripts/install.sh").path,
                "--install", "--bundle", bundle.path, "--home", environment.installRoot.path,
                "--version", "2.0.1", "--target", "linux-arm64", "--asset-sha256", environment.assetSha256,
                "--manifest-sha256", manifestDigest,
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(install.status, 6, install.stderr)
        XCTAssertTrue(install.stderr.contains("could not publish receipt"))
        let current = environment.installRoot.appendingPathComponent("current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), previous)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receipt.path).isEmpty)
    }

    func testStandaloneRollbackCannotChangeCurrentWhileBootstrapHoldsTheLock() throws {
        let environment = try makeEnvironment()
        let process = try launch(script: generatedScript(environment), environment: environment)
        defer { terminateIfNeeded(process) }
        _ = try waitForFile(environment.attemptDirectory.appendingPathComponent("pair.json"), timeout: 15)
        let rollback = try runProcess(
            "/bin/bash",
            arguments: [
                repositoryRoot().appendingPathComponent("apps/pi-adaptor/scripts/install.sh").path,
                "--rollback", "--home", environment.installRoot.path,
                "--previous-current-target", "none", "--failed-install-dir", "none",
            ],
            environment: environment.processEnvironment
        )
        XCTAssertEqual(rollback.status, 5, rollback.stderr)
        XCTAssertTrue(rollback.stderr.contains("another installation owns the install lock"))
        let current = environment.installRoot.appendingPathComponent("current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), "releases/2.0.1-\(environment.assetSha256)")
        try completePairingHandshake(environment: environment, process: process)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Isolated environment

    private struct Environment {
        let root: URL
        let home: URL
        let installRoot: URL
        let workDirectory: URL
        let attemptDirectory: URL
        let stateURL: URL
        let stdoutURL: URL
        let stderrURL: URL
        let release: PIAdaptorRelease
        let assetSha256: String
        let artifactName: String
        let processEnvironment: [String: String]
    }

    private func makeEnvironment(
        validChecksum: Bool = true,
        downloadMode: String = "ok",
        tokenPrefix: String = "ppt2",
        legacyConflict: Bool = false,
        legacyEnableState: String = "enabled",
        failPiAdaptorStop: Bool = false,
        failLegacyRestore: Bool = false,
        piAdaptorInitiallyActive: Bool = false,
        piAdaptorEnableState: String = "disabled",
        runningVersion: String? = "2.0.0",
        opensslFails: Bool = false,
        existingDirectIdentity: Bool = false
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-ios-bootstrap-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let fakeBin = root.appendingPathComponent("fake-bin", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let placeholder = try XCTUnwrap(
            PIAdaptorRelease(
                version: "2.0.1",
                target: .linuxArm64,
                baseURL: "https://example.test/pi-adaptor-v2.0.1",
                pinnedChecksum: String(repeating: "0", count: 64)
            )
        )
        let bundle = source.appendingPathComponent(placeholder.bundleDirectoryName, isDirectory: true)
        let dist = bundle.appendingPathComponent("dist", isDirectory: true)
        let scripts = bundle.appendingPathComponent("scripts", isDirectory: true)
        let modules = bundle.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(
            #"{"name":"@pi-ios/pi-adaptor","version":"2.0.1","private":true,"type":"module"}"#.utf8
        ).write(to: bundle.appendingPathComponent("package.json"))
        try Data("// fake PI-adaptor entry\n".utf8)
            .write(to: dist.appendingPathComponent("main.js"))
        try Data().write(to: modules.appendingPathComponent(".keep"))
        try FileManager.default.copyItem(
            at: repositoryRoot().appendingPathComponent("apps/pi-adaptor/scripts/install.sh"),
            to: scripts.appendingPathComponent("install.sh")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scripts.appendingPathComponent("install.sh").path
        )
        try writeChecksumManifest(root: bundle)

        let artifactURL = source.appendingPathComponent(placeholder.artifactName)
        try runTool(
            "/usr/bin/tar",
            arguments: [
                "-czf", artifactURL.path,
                "-C", source.path,
                placeholder.bundleDirectoryName,
            ]
        )
        let digest = sha256(try Data(contentsOf: artifactURL))
        let release = try XCTUnwrap(
            PIAdaptorRelease(
                version: "2.0.1",
                target: .linuxArm64,
                baseURL: "https://example.test/pi-adaptor-v2.0.1",
                pinnedChecksum: digest
            )
        )
        let checksum = validChecksum
            ? "\(digest)  \(release.artifactName)\n"
            : "\(String(repeating: "0", count: 64))  \(release.artifactName)\n"
        let checksumURL = source.appendingPathComponent(release.artifactName + ".sha256")
        try Data(checksum.utf8).write(to: checksumURL)

        let requestedToken = tokenPrefix == "ppt1"
            ? "ppt1." + "legacy-token"
            : pairingToken
        let realNode = try XCTUnwrap(findExecutable("node"))
        let python = try XCTUnwrap(findExecutable("python3"))
        try writeExecutable(
            #"""
            #!/bin/sh
            case "$*" in
              '-n -E 75 9'|'-n 9') ;;
              *) exit 1 ;;
            esac
            exec "$REAL_PYTHON" -c '
            import fcntl, sys
            try:
                fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(75)
            '
            """#,
            to: fakeBin.appendingPathComponent("flock")
        )
        try writeExecutable("#!/bin/sh\nexec \"$@\"\n", to: fakeBin.appendingPathComponent("setsid"))
        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            case "${1:-}" in
              -e|-p) exec "$REAL_NODE" "$@" ;;
            esac
            case "$*" in
              *dist/main.js*)
                if [ "${PI_ADAPTOR_DIRECT_ENABLED:-0}" = 1 ]; then
                  "$REAL_NODE" -e '
                    const fs = require("node:fs");
                    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
                    if (state.status === "running") {
                      const trust = { schemaVersion: 1, attemptId: state.attemptId, hostId: "host_fake",
                        certificateSha256: "a".repeat(64), notBefore: "2026-01-01T00:00:00Z", notAfter: "2099-01-01T00:00:00Z" };
                      console.log("PI_HOST_DIRECT_TRUST " + JSON.stringify(trust));
                    }
                  ' "$PI_ADAPTOR_HOME/.bootstrap/state.json"
                fi
                printf '%s\n' 'PI_HOST_READY {"hostId":"host_fake","host":"127.0.0.1","port":43871,"version":"2.0.1"}'
                printf '%s\n' 'PI_HOST_PAIRING_TOKEN {"token":"\#(requestedToken)","expiresAt":1893456000000}'
                trap 'exit 0' HUP INT TERM
                while :; do sleep 1; done
                ;;
              *) exec "$REAL_NODE" "$@" ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("node")
        )

        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            destination=""
            url=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) shift; destination=$1 ;;
                http*) url=$1 ;;
              esac
              shift
            done
            [ -n "$destination" ]
            case "$url" in
              *.sha256) cp "$FAKE_CHECKSUM" "$destination" ;;
              *)
                source_bytes=$(wc -c <"$FAKE_ARTIFACT" | tr -d ' ')
                if [ "${FAKE_DOWNLOAD_MODE:-ok}" = "fail-once" ] &&
                   [ ! -f "$HOME/.fake-download-failed" ]; then
                  : >"$HOME/.fake-download-failed"
                  head -c $((source_bytes / 2)) "$FAKE_ARTIFACT" >"$destination"
                  exit 22
                fi
                if [ -f "$destination" ]; then
                  existing=$(wc -c <"$destination" | tr -d ' ')
                  if [ "$existing" -lt "$source_bytes" ]; then
                    tail -c +$((existing + 1)) "$FAKE_ARTIFACT" >>"$destination"
                  else
                    cp "$FAKE_ARTIFACT" "$destination"
                  fi
                else
                  cp "$FAKE_ARTIFACT" "$destination"
                fi
                printf '%s\n' ok >>"$FAKE_DOWNLOAD_COUNT"
                ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("curl")
        )
        try writeExecutable(
            "#!/bin/sh\ncase \"${1:-}\" in\n  -m) printf 'aarch64\\n' ;;\n  -s) printf 'Linux\\n' ;;\n  *) printf 'Linux\\n' ;;\nesac\n",
            to: fakeBin.appendingPathComponent("uname")
        )

        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            [ "${FAKE_OPENSSL_FAIL:-0}" != 1 ] || exit 1
            case "$1" in
              req)
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    -keyout) shift; printf '%s' new-key >"$1" ;;
                    -out) shift; printf '%s' new-cert >"$1" ;;
                  esac
                  shift
                done
                ;;
              pkey) exit 0 ;;
              x509) printf '%s\n' 'CA:FALSE' ;;
              *) exit 1 ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("openssl")
        )

        try writeExecutable(
            #"""
            #!/bin/sh
            set -eu
            active="$HOME/.fake-pi-adaptor-active"
            enabled="$HOME/.fake-pi-adaptor-enable-state"
            legacy_active="$HOME/.fake-legacy-active"
            legacy_enabled="$HOME/.fake-legacy-enabled"
            legacy_enable_state="$HOME/.fake-legacy-enable-state"
            fail_stop=\#(failPiAdaptorStop ? "1" : "0")
            fail_legacy_restore=\#(failLegacyRestore ? "1" : "0")
            case "$*" in
              "--user daemon-reload") exit 0 ;;
              "--user stop pi-adaptor.service")
                [ "$fail_stop" = 0 ] || exit 1
                rm -f "$active"
                exit 0
                ;;
              "--user is-active --quiet pi-adaptor.service") [ -f "$active" ] ;;
              "--user is-active pi-adaptor.service")
                if [ -f "$active" ]; then printf '%s\n' active; else printf '%s\n' inactive; exit 3; fi
                ;;
              "--user show pi-adaptor.service --property=MainPID --property=InvocationID")
                printf '%s\n' 'MainPID=1234' 'InvocationID=0123456789abcdef0123456789abcdef'
                ;;
              "--user is-enabled pi-adaptor.service")
                state=$(cat "$enabled")
                printf '%s\n' "$state"
                [ "$state" != disabled ]
                ;;
              "--user enable pi-adaptor.service") printf '%s\n' enabled >"$enabled" ;;
              "--user enable --runtime pi-adaptor.service") printf '%s\n' enabled-runtime >"$enabled" ;;
              "--user disable pi-adaptor.service") printf '%s\n' disabled >"$enabled" ;;
              "--user start pi-adaptor.service") : >"$active" ;;
              "--user stop pi-host.service") rm -f "$legacy_active"; exit 0 ;;
              "--user disable pi-host.service")
                rm -f "$legacy_enabled"
                printf '%s\n' disabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user disable --runtime pi-host.service")
                rm -f "$legacy_enabled"
                printf '%s\n' disabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user enable pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_enabled"
                printf '%s\n' enabled >"$legacy_enable_state"
                exit 0
                ;;
              "--user enable --runtime pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_enabled"
                printf '%s\n' enabled-runtime >"$legacy_enable_state"
                exit 0
                ;;
              "--user start pi-host.service")
                [ "$fail_legacy_restore" = 0 ] || exit 1
                : >"$legacy_active"
                exit 0
                ;;
              "--user is-enabled pi-host.service")
                state=$(cat "$legacy_enable_state" 2>/dev/null || printf 'disabled')
                printf '%s\n' "$state"
                [ "$state" != disabled ]
                ;;
              "--user is-enabled pi-host-v2.service") exit 1 ;;
              "--user show pi-host.service --property=ActiveState")
                if [ -f "$legacy_active" ]; then
                  printf '%s\n' 'ActiveState=active'
                else
                  printf '%s\n' 'ActiveState=inactive'
                fi
                exit 0
                ;;
              "--user show pi-host-v2.service --property=ActiveState")
                printf '%s\n' 'ActiveState=inactive'
                exit 0
                ;;
              "--user show pi-host.service --property=ExecStart")
                printf '%s\n' 'ExecStart={ path=/usr/bin/node ; argv[]=/usr/bin/node pi-host.js --port 43871 }'
                exit 0
                ;;
              "--user show pi-host-v2.service --property=ExecStart")
                printf '%s\n' 'ExecStart='
                exit 0
                ;;
              *) exit 0 ;;
            esac
            """#,
            to: fakeBin.appendingPathComponent("systemctl")
        )
        try Data("\(piAdaptorEnableState)\n".utf8).write(to: home.appendingPathComponent(".fake-pi-adaptor-enable-state"))
        try writeExecutable(
            #"""
            #!/bin/sh
            [ "$*" = "--user-unit=pi-adaptor.service --boot --no-pager --output=cat --grep=^PI_HOST_READY  --lines=1 _PID=1234 _SYSTEMD_INVOCATION_ID=0123456789abcdef0123456789abcdef" ] || exit 1
            [ -n "${FAKE_RUNNING_VERSION:-}" ] || exit 1
            printf 'PI_HOST_READY {"version":"%s"}\n' "$FAKE_RUNNING_VERSION"
            """#,
            to: fakeBin.appendingPathComponent("journalctl")
        )
        if legacyConflict {
            try Data().write(to: home.appendingPathComponent(".fake-legacy-active"))
            if legacyEnableState == "enabled" {
                try Data().write(to: home.appendingPathComponent(".fake-legacy-enabled"))
            }
            try Data("\(legacyEnableState)\n".utf8).write(
                to: home.appendingPathComponent(".fake-legacy-enable-state")
            )
        }
        if piAdaptorInitiallyActive {
            try Data().write(to: home.appendingPathComponent(".fake-pi-adaptor-active"))
        }
        try writeExecutable(
            """
            #!/bin/sh
            case "$1" in
              show-user) printf '%s\\n' '\(piAdaptorInitiallyActive ? "yes" : "no")' ;;
              enable-linger) [ '\(piAdaptorInitiallyActive ? "1" : "0")' = 0 ] ;;
              *) exit 1 ;;
            esac
            """,
            to: fakeBin.appendingPathComponent("loginctl")
        )

        let downloadCount = root.appendingPathComponent("download-count")
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["HOME"] = home.path
        processEnvironment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["FAKE_ARTIFACT"] = artifactURL.path
        processEnvironment["FAKE_CHECKSUM"] = checksumURL.path
        processEnvironment["FAKE_DOWNLOAD_MODE"] = downloadMode
        processEnvironment["FAKE_DOWNLOAD_COUNT"] = downloadCount.path
        processEnvironment["REAL_NODE"] = realNode.path
        processEnvironment["REAL_PYTHON"] = python.path
        processEnvironment["FAKE_OPENSSL_FAIL"] = opensslFails ? "1" : "0"
        processEnvironment["FAKE_RUNNING_VERSION"] = runningVersion

        let installRoot = home.appendingPathComponent(".pi-adaptor", isDirectory: true)
        if existingDirectIdentity {
            let tls = installRoot.appendingPathComponent("tls", isDirectory: true)
            try FileManager.default.createDirectory(at: tls, withIntermediateDirectories: true)
            try Data("old-cert".utf8).write(to: tls.appendingPathComponent("direct-cert.pem"))
            try Data("old-key".utf8).write(to: tls.appendingPathComponent("direct-key.pem"))
            try Data("old.example\n".utf8).write(to: tls.appendingPathComponent("direct-name"))
        }
        let workDirectory = installRoot.appendingPathComponent(".bootstrap", isDirectory: true)
        let attemptDirectory = workDirectory.appendingPathComponent("attempts/\(attemptId)", isDirectory: true)
        return Environment(
            root: root,
            home: home,
            installRoot: installRoot,
            workDirectory: workDirectory,
            attemptDirectory: attemptDirectory,
            stateURL: attemptDirectory.appendingPathComponent("state.json"),
            stdoutURL: root.appendingPathComponent("script.stdout"),
            stderrURL: root.appendingPathComponent("script.stderr"),
            release: release,
            assetSha256: digest,
            artifactName: release.artifactName,
            processEnvironment: processEnvironment
        )
    }

    private func installCurrentFixture(_ version: String, in environment: Environment) throws -> String {
        let previous = "releases/\(version)-" + String(repeating: "a", count: 64)
        let directory = environment.installRoot.appendingPathComponent(previous)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":"\#(version)"}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        let current = environment.installRoot.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: previous)
        return previous
    }

    private func generatedScript(
        _ environment: Environment,
        force: Bool = false,
        direct: BootstrapDirectConfiguration? = nil,
        attemptId: String? = nil
    ) throws -> URL {
        let configuration = try BootstrapScriptConfiguration(
            release: environment.release,
            attemptId: attemptId ?? self.attemptId,
            hostArchitecture: "arm64",
            port: 43_871,
            readyTimeoutSeconds: 15,
            pairTimeoutSeconds: 15,
            stopTimeoutSeconds: 5,
            verifyTimeoutSeconds: 15,
            force: force,
            direct: direct
        )
        let url = environment.root.appendingPathComponent("bootstrap-\(UUID().uuidString).sh")
        try Data(BootstrapScriptBuilder.build(configuration).utf8).write(to: url)
        return url
    }

    private func launch(script: URL, environment: Environment) throws -> Process {
        let stdout = try FileHandle(forWritingTo: createEmptyFile(environment.stdoutURL))
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: createEmptyFile(environment.stderrURL))
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = environment.processEnvironment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        addTeardownBlock { self.terminateIfNeeded(process) }
        return process
    }

    private func serviceEnablement(_ environment: Environment) throws -> String {
        try String(contentsOf: environment.home.appendingPathComponent(".fake-pi-adaptor-enable-state"), encoding: .utf8)
    }

    private func createEmptyFile(_ url: URL) throws -> URL {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func completePairingHandshake(
        environment: Environment,
        process: Process
    ) throws {
        let pairURL = environment.attemptDirectory.appendingPathComponent("pair.json")
        let pairData = try waitForFile(pairURL, timeout: 30)
        let material = try JSONDecoder().decode(BootstrapPairingMaterial.self, from: pairData)
        XCTAssertEqual(material.token, pairingToken)
        XCTAssertEqual(material.expiresAt, 1_893_456_000_000)
        XCTAssertEqual(material.host, "127.0.0.1")
        XCTAssertEqual(material.port, 43_871)
        XCTAssertEqual(try permissions(pairURL), 0o600)
        try writeMarker("ok", to: environment.attemptDirectory.appendingPathComponent("pair.result"))

        try waitForState(
            environment.stateURL,
            timeout: 30,
            matching: { $0.step == .verifyDevice }
        )
        try writeMarker("ok", to: environment.attemptDirectory.appendingPathComponent("verify.result"))
        try waitForExit(process, timeout: 30)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw IntegrationError.timeout(url.lastPathComponent)
    }

    private func waitForState(
        _ url: URL,
        timeout: TimeInterval,
        matching predicate: (BootstrapStateFile) -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? decodeState(url), predicate(state) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw IntegrationError.timeout("state")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            throw IntegrationError.timeout("script exit")
        }
    }

    private func decodeState(_ url: URL) throws -> BootstrapStateFile {
        try JSONDecoder().decode(BootstrapStateFile.self, from: Data(contentsOf: url))
    }

    private func writeMarker(_ value: String, to url: URL) throws {
        try Data("\(value)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func downloadCount(_ environment: Environment) throws -> Int {
        let url = environment.root.appendingPathComponent("download-count")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .count
    }

    private func persistedOutputs(_ environment: Environment) throws -> [String] {
        // Required logs must be readable; only a genuinely absent optional file
        // may be treated as empty. A blanket `try?` would let an I/O error skip
        // the "token must not leak" negative assertions.
        func readRequired(_ url: URL) throws -> String {
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch CocoaError.fileReadNoSuchFile {
                return ""
            }
        }
        let pairErrorURL = environment.attemptDirectory.appendingPathComponent("pair.err")
        var pairError = ""
        do {
            pairError = try String(contentsOf: pairErrorURL, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            pairError = ""
        }
        return [try readRequired(environment.stdoutURL), try readRequired(environment.stderrURL), pairError]
    }

    private func capturedFailure(_ environment: Environment) throws -> String {
        try persistedOutputs(environment).joined(separator: "\n")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writeChecksumManifest(root: URL) throws {
        var entries: [(String, String)] = []
        func visit(_ directory: URL, prefix: String) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in children {
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if values.isSymbolicLink == true {
                    throw IntegrationError.symlink(url.path)
                }
                let relative = prefix.isEmpty
                    ? url.lastPathComponent
                    : "\(prefix)/\(url.lastPathComponent)"
                if values.isDirectory == true {
                    try visit(url, prefix: relative)
                } else if relative != "SHA256SUMS" {
                    entries.append((relative, sha256(try Data(contentsOf: url))))
                }
            }
        }
        try visit(root, prefix: "")
        entries.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        let text = entries.map { "\($0.1)  \($0.0)\n" }.joined()
        try Data(text.utf8).write(to: root.appendingPathComponent("SHA256SUMS"))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private func findExecutable(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IntegrationError.toolFailed(executable, process.terminationStatus)
        }
    }

    private func runProcess(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        input: URL? = nil
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let input { process.standardInput = try FileHandle(forReadingFrom: input) }
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    private func terminateIfNeeded(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private enum IntegrationError: Error {
        case timeout(String)
        case toolFailed(String, Int32)
        case symlink(String)
    }
}
