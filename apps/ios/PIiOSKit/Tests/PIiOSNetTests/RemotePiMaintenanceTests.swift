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

    func testFindsPiAndNodeInNvmWithoutDefaultAliasAndFnm() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        // Case 1: nvm versions/node without alias/default, pi in newest node version,
        // while another pi wrapper in ~/.local/bin requires `node` on PATH.
        let localBin = home.appendingPathComponent(".local/bin")
        let nvmV20 = home.appendingPathComponent(".nvm/versions/node/v20.11.0/bin")
        let nvmV22 = home.appendingPathComponent(".nvm/versions/node/v22.22.0/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nvmV20, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nvmV22, withIntermediateDirectories: true)

        let fakeNode = nvmV22.appendingPathComponent("node")
        try "#!/bin/sh\nexit 0\n".write(to: fakeNode, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeNode.path)

        let piInNvm = nvmV22.appendingPathComponent("pi")
        try "#!/bin/sh\nnode -e '' >/dev/null 2>&1 || exit 127\nprintf 'v1.6.1\\n'\n".write(to: piInNvm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: piInNvm.path)

        let piWrapper = localBin.appendingPathComponent("pi")
        try "#!/bin/sh\ncommand -v node >/dev/null 2>&1 || exit 127\nprintf '1.6.1\\n'\n".write(to: piWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: piWrapper.path)

        let probe = try run(RemotePiMaintenance.probeScript, home: home)
        XCTAssertEqual(try RemotePiMaintenance.version(from: probe).value, "1.6.1")

        // Case 2: fnm node-versions without default alias.
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".local"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".nvm"))
        let fnmBin = home.appendingPathComponent(".local/share/fnm/node-versions/v22.14.0/installation/bin")
        try FileManager.default.createDirectory(at: fnmBin, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fnmBin.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fnmBin.appendingPathComponent("node").path)
        try "#!/bin/sh\nprintf 'pi 1.8.0\\r\\n'\n".write(to: fnmBin.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fnmBin.appendingPathComponent("pi").path)

        let fnmProbe = try run(RemotePiMaintenance.probeScript, home: home)
        XCTAssertEqual(try RemotePiMaintenance.version(from: fnmProbe).value, "1.8.0")
    }

    func testParsesMultilineAndRejectsUnexpectedVersionOutput() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pi = bin.appendingPathComponent("pi")

        try "#!/bin/sh\nprintf 'Checking updates...\\n1.7.2\\nUpdate ready\\n'\n".write(to: pi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pi.path)
        let multiProbe = try run(RemotePiMaintenance.probeScript, home: home)
        XCTAssertEqual(try RemotePiMaintenance.version(from: multiProbe).value, "1.7.2")

        try "#!/bin/sh\nprintf '1.10.0 unexpected output\\n'\n".write(to: pi, atomically: true, encoding: .utf8)
        let invalidProbe = try run(RemotePiMaintenance.probeScript, home: home)
        XCTAssertThrowsError(try RemotePiMaintenance.version(from: invalidProbe)) {
            guard case RemotePiMaintenanceError.invalidVersion = $0 else { return XCTFail("\($0)") }
        }
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
