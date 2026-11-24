import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

final class RemotePiMaintenanceTests: XCTestCase {
    func testReadsAndUpgradesTheAccountPiWithoutUpdatingExtensions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let versionFile = home.appendingPathComponent("version")
        let calls = home.appendingPathComponent("calls")
        let executable = bin.appendingPathComponent("pi")
        try "1.9.0\n".write(to: versionFile, atomically: true, encoding: .utf8)
        try #"""
        #!/bin/sh
        case "$*" in
          --version) cat "$HOME/version" ;;
          'update --help') printf '%s\n' '--self --no-approve' ;;
          'update --self --no-approve')
            printf '%s\n' "$*" >> "$HOME/calls"
            printf '1.10.0\n' > "$HOME/version"
            printf 'Updated Pi\n'
            ;;
          *) exit 99 ;;
        esac
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let latest = try RemotePiMaintenance.latestVersion(from: Data(#"{"version":"1.10.0"}"#.utf8))
        let probe = try run(RemotePiMaintenance.probeScript, home: home)
        let installed = try RemotePiMaintenance.version(from: probe)
        XCTAssertEqual(installed.value, "1.9.0")
        XCTAssertTrue(installed.needsUpgrade(to: latest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
        XCTAssertThrowsError(try RemotePiMaintenance.verifiedVersion(from: probe, toAtLeast: latest)) {
            guard case RemotePiMaintenanceError.updateUnverified = $0 else { return XCTFail("\($0)") }
        }

        let upgrade = RemotePiMaintenance.upgradeScript(from: installed)
        let result = try run(upgrade, home: home)
        XCTAssertEqual(try RemotePiMaintenance.verifiedVersion(from: result, toAtLeast: latest), latest)
        XCTAssertEqual(try RemotePiMaintenance.version(from: run(RemotePiMaintenance.probeScript, home: home)), latest)
        let stale = try run(upgrade, home: home)
        XCTAssertThrowsError(try RemotePiMaintenance.version(from: stale)) {
            guard case RemotePiMaintenanceError.versionChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "update --self --no-approve\n")
    }

    func testOrdersStableVersionsAndRejectsInvalidOfficialMetadata() throws {
        let stable = try XCTUnwrap(RemotePiVersion("1.10.0"))
        XCTAssertTrue(try XCTUnwrap(RemotePiVersion(" v1.10.0-rc.1\n")).needsUpgrade(to: stable))
        XCTAssertFalse(try XCTUnwrap(RemotePiVersion("1.10.0+local")).needsUpgrade(to: stable))
        XCTAssertFalse(try XCTUnwrap(RemotePiVersion("1.11.0")).needsUpgrade(to: stable))
        XCTAssertNil(RemotePiVersion("1.10.0 unexpected output"))
        XCTAssertThrowsError(try RemotePiMaintenance.latestVersion(from: Data(#"{"version":"2.0.0-beta.1"}"#.utf8)))
    }

    private func run(_ script: String, home: URL) throws -> SSHExecResult {
        let path = home.appendingPathComponent("command.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return SSHExecResult(exitStatus: Int(process.terminationStatus), stdout: stdout.fileHandleForReading.readDataToEndOfFile(), stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }
}
