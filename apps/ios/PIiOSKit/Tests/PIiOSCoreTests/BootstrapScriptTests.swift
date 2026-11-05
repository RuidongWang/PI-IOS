import Foundation
import XCTest

@testable import PIiOSCore

final class BootstrapScriptTests: XCTestCase {
    private let digest = String(repeating: "0123456789abcdef", count: 4)

    private func configuration(
        target: BootstrapArtifactTarget = .linuxArm64,
        port: Int = 43_871,
        direct: BootstrapDirectConfiguration? = nil
    ) throws -> BootstrapScriptConfiguration {
        let release = try XCTUnwrap(
            PIAdaptorRelease(
                version: "2.0.1",
                target: target,
                baseURL: "https://example.test/pi-adaptor-v2.0.1",
                pinnedChecksum: digest
            )
        )
        return try BootstrapScriptConfiguration(
            release: release,
            attemptId: "boot_20261029T120000Z_a1b2",
            hostArchitecture: target == .linuxArm64 ? "arm64" : "x86_64",
            port: port,
            readyTimeoutSeconds: 90,
            pairTimeoutSeconds: 600,
            stopTimeoutSeconds: 20,
            verifyTimeoutSeconds: 90,
            direct: direct
        )
    }

    func testGeneratedScriptIsPOSIXSyntaxAndEncodesFullWorkflow() throws {
        let script = BootstrapScriptBuilder.build(try configuration())
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("set -eu"))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains(#"ARTIFACT_URL='https://example.test/pi-adaptor-v2.0.1/pi-adaptor-2.0.1-linux-arm64.tar.gz'"#))
        XCTAssertTrue(script.contains(#"CHECKSUM_URL='https://example.test/pi-adaptor-v2.0.1/pi-adaptor-2.0.1-linux-arm64.tar.gz.sha256'"#))
        XCTAssertTrue(script.contains(#"PART="$WORK/$ARTIFACT_NAME.part""#))
        XCTAssertTrue(script.contains("curl -fL -C -"))
        XCTAssertTrue(script.contains("wget -c"))
        XCTAssertTrue(script.contains(#"chmod 600 "$tmp""#))
        XCTAssertTrue(script.contains(#"chmod 700 "$BASE" "$WORK""#))
        XCTAssertTrue(script.contains(#"pair_tmp="$PAIR_JSON.tmp.$$""#))
        XCTAssertTrue(script.contains(#"chmod 600 "$pair_tmp""#))
        XCTAssertTrue(script.contains(#">"$WORK/pair.fifo""#))
        XCTAssertFalse(script.contains(#">"$log" 2>"$err""#), "令牌 stdout 不得写入持久日志")
        XCTAssertTrue(script.contains(#"setsid"#) == false, "后台脱离由 runner 的 launch 命令负责")

        let expectedOrder = [
            #"step "probe""#,
            #"progress "resolve""#,
            #"progress "download""#,
            #"progress "verify""#,
            #"progress "extract""#,
            #"progress "activate""#,
            #"progress "write-unit""#,
            #"progress "start-pair""#,
            #"step "pair""#,
            #"progress "stop-manual""#,
            #"progress "start-unit""#,
            #"progress "verify-device""#,
            #"step "done""#,
        ]
        let positions = expectedOrder.map { script.range(of: $0)?.lowerBound }
        for position in positions {
            XCTAssertNotNil(position)
        }
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())

        let verifyHash = try XCTUnwrap(script.range(of: #"actual_sha256=$(sha256_of "$PART")"#)?.lowerBound)
        let install = try XCTUnwrap(script.range(of: #""$unpack/$BUNDLE_DIR/scripts/install.sh" --install"#)?.lowerBound)
        XCTAssertLessThan(verifyHash, install, "sha256 验证必须先于 current 切换")

        let execStartLine = script.components(separatedBy: .newlines)
            .first(where: { $0.contains("ExecStart=") })
        XCTAssertNotNil(execStartLine)
        XCTAssertFalse(execStartLine?.contains("--pair") ?? true)
        XCTAssertTrue(script.contains("--pair \\\n"))

        try assertShellParses(script)
    }

    func testStateFilePathPermissionsAndUnitContractAreExplicit() throws {
        let script = BootstrapScriptBuilder.build(try configuration(target: .linuxX64))
        XCTAssertTrue(script.contains(#"STATE="$WORK/state.json""#))
        XCTAssertTrue(script.contains(#"printf '{"version":1,"attemptId":"%s","step":"%s","status":"%s",' "$ATTEMPT_ID" "$next_step" "$status""#))
        XCTAssertTrue(script.contains(#"chmod 600 "$tmp""#))
        XCTAssertTrue(script.contains(#"BASE="$HOME/.pi-adaptor""#))
        XCTAssertTrue(script.contains(#"unit_path="$unit_dir/$UNIT_NAME""#))
        XCTAssertTrue(script.contains(#"systemctl --user daemon-reload"#))
        XCTAssertTrue(script.contains(#"loginctl enable-linger"#))
        XCTAssertTrue(script.contains(#"systemctl --user enable "$UNIT_NAME""#))
        XCTAssertTrue(script.contains(#"ExecStart="%s" "%s/current/dist/main.js""#))
        XCTAssertTrue(script.contains(#"systemctl --user start "$UNIT_NAME""#))
        XCTAssertTrue(script.contains(#"systemctl --user is-active --quiet "$UNIT_NAME""#))
        XCTAssertTrue(script.contains(#"\"reason\":\"$details_reason\""#))
    }

    func testEnablementIsRecordedAndRolledBack() throws {
        let script = BootstrapScriptBuilder.build(try configuration())
        let daemonReload = try XCTUnwrap(script.range(of: #"systemctl --user daemon-reload"#)?.lowerBound)
        // 安装流程里的 enable 紧跟在“只 start 不 enable”注释之后；
        // 前面回滚函数里也有同名命令，必须用注释锚定。
        let installEnable = try XCTUnwrap(script.range(of: #"# 只 start 不 enable 的话"#)?.lowerBound)
        let startUnit = try XCTUnwrap(script.range(of: #"progress "start-unit""#)?.lowerBound)
        XCTAssertLessThan(daemonReload, installEnable)
        XCTAssertLessThan(installEnable, startUnit)
        XCTAssertTrue(script.contains(#"systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 || die "unit-failed""#))
        // 安装前记录原 enable 状态，回滚时按原状态恢复。
        XCTAssertTrue(script.contains(#"PREVIOUS_SERVICE_ENABLED=$(systemctl --user is-enabled "$UNIT_NAME""#))
        XCTAssertTrue(script.contains(#"restore_service_enablement || { ROLLBACK_STEP="restore-enablement"; rollback_ok=0; }"#))
        XCTAssertTrue(script.contains(#"TRANSACTION_ENABLED="$WORK/transaction.service-enabled""#))
        try assertShellParses(script)
    }

    func testFailuresSurfaceServerDiagnosticsAndNeverMaskOriginalCode() throws {
        let script = BootstrapScriptBuilder.build(try configuration())

        // Node 与架构诊断必须在下载之前完成，否则 Node 太旧只会在
        // install.sh 内部报 install-failed。
        let archProbe = try XCTUnwrap(script.range(of: #"SERVER_ARCH=$(uname -m"#)?.lowerBound)
        let nodeProbe = try XCTUnwrap(script.range(of: #""$node_path" -e"#)?.lowerBound)
        let resolve = try XCTUnwrap(script.range(of: #"progress "resolve""#)?.lowerBound)
        XCTAssertLessThan(archProbe, resolve)
        XCTAssertLessThan(nodeProbe, resolve)
        // 恢复上次未完成的事务时也要带上诊断。
        let recovery = try XCTUnwrap(script.range(of: #"if [ -f "$TRANSACTION_ACTIVE" ]"#)?.lowerBound)
        XCTAssertLessThan(archProbe, recovery)
        // 事务里记录的 previous 已被删除或本身无效时按 none 回滚。
        XCTAssertTrue(script.contains(#"previous="none""#))
        XCTAssertTrue(script.contains(#"previous_path="invalid""#))
        // current 若是同名目录，先移到隐藏名字再让回滚脚本清理。
        XCTAssertTrue(script.contains(#"mv "$link" "$BASE/.$name.invalid.$$""#))
        // 绝对路径的 current 目标统一成 releases/... 再判断。
        XCTAssertTrue(script.contains(#"previous=${previous#"$BASE"/}"#))
        XCTAssertTrue(script.contains(#"die "missing-node""#))
        XCTAssertTrue(script.contains(#"die "node-too-old""#))

        XCTAssertTrue(script.contains(#"\"rollbackStep\":\"$ROLLBACK_STEP\""#))
        XCTAssertTrue(script.contains(#"\"serverArch\":\"$SERVER_ARCH\""#))
        XCTAssertTrue(script.contains(#"\"nodeVersion\":\"$NODE_VERSION\""#))

        // 悬空的 current 指向已删除的版本目录时按 none 回滚，避免回滚脚本
        // 因为“previous 不存在”而失败。
        XCTAssertTrue(script.contains(#"PREVIOUS_CURRENT_TARGET="none""#))
        XCTAssertTrue(script.contains(#"if [ -d "$BASE/$previous" ] && [ ! -L "$BASE/$previous" ]"#))
        XCTAssertTrue(script.contains(#"rm -f "$current_link""#))

        // install.sh 的 stderr JSON 里带着真实原因，必须提取出来而不是丢掉。
        XCTAssertTrue(script.contains(#"2>"$WORK/install.error""#))
        XCTAssertTrue(script.contains(#"script_failure_reason "$WORK/install.error""#))
        XCTAssertTrue(script.contains(#"2>"$WORK/verify.error""#))
        XCTAssertTrue(script.contains(#"2>"$WORK/rollback.error""#))

        // 回滚失败只作为附加信息，原始失败码必须保留。
        XCTAssertTrue(script.contains(#"FAILURE_REASON="${failure_code}（回滚失败${ROLLBACK_STEP:+：$ROLLBACK_STEP}${ROLLBACK_REASON:+，$ROLLBACK_REASON}）""#))
        XCTAssertTrue(script.contains(#"ROLLBACK_REASON=$(script_failure_reason "$WORK/rollback.error")"#))
        XCTAssertTrue(script.contains(#"\"originalStep\":\"$failure_code\""#))
        XCTAssertTrue(script.contains(#"restore_service_enablement || { ROLLBACK_STEP="restore-enablement"; rollback_ok=0; }"#))

        try assertShellParses(script)
    }

    func testArtifactResumeAndFailurePrecisionArePresent() throws {
        let script = BootstrapScriptBuilder.build(try configuration())
        let download = try XCTUnwrap(script.range(of: #"resume_download "$ARTIFACT_URL" "$PART" &"#)?.lowerBound)
        let checksum = try XCTUnwrap(script.range(of: #"actual_sha256=$(sha256_of "$PART")"#)?.lowerBound)
        let currentSwitch = try XCTUnwrap(script.range(of: #""$unpack/$BUNDLE_DIR/scripts/install.sh" --install"#)?.lowerBound)
        XCTAssertLessThan(download, checksum)
        XCTAssertLessThan(checksum, currentSwitch)
        for code in [
            "missing-tar", "missing-sha256-tool", "bootstrap-permissions",
            "stage-failed", "download-failed", "checksum-mismatch", "extract-failed",
            "unexpected-archive-layout", "install-failed", "installed-verification-failed",
            "missing-node", "missing-bash", "node-too-old", "host-stop-timeout", "host-start-failed",
            "host-exited", "ready-timeout", "receipt-failed", "artifact-permissions",
            "pair-failed", "unit-failed", "verify-device-failed",
        ] {
            XCTAssertTrue(script.contains(#"die "\#(code)""#), code)
        }
        XCTAssertTrue(script.contains(#"PI_HOST_BOOTSTRAP_FAILED no-home"#))
    }

    func testDirectBootstrapGeneratesSingleLeafAndCapturesAttemptTrustWithoutBreakingLoopback() throws {
        let direct = try BootstrapDirectConfiguration(
            directName: "host.example",
            directPort: 9443,
            loopbackPort: 43_871
        )
        let script = BootstrapScriptBuilder.build(try configuration(direct: direct))
        XCTAssertTrue(script.contains("openssl req -x509 -newkey rsa:3072"))
        XCTAssertTrue(script.contains("basicConstraints=critical,CA:FALSE"))
        XCTAssertTrue(script.contains("extendedKeyUsage=serverAuth"))
        XCTAssertTrue(script.contains("subjectAltName=$DIRECT_SAN"))
        XCTAssertTrue(script.contains("chmod 600 \"$tls_staging/direct-key.pem\""))
        XCTAssertTrue(script.contains("tls_staging=\"$DIRECT_TLS.staging.$$\""))
        XCTAssertTrue(script.contains("openssl pkey -in \"$tls_staging/direct-key.pem\" -check"))
        XCTAssertFalse(script.contains("rm -f \"$DIRECT_TLS/direct-cert.pem\" \"$DIRECT_TLS/direct-key.pem\""))
        XCTAssertTrue(script.contains("PI_ADAPTOR_DIRECT_ENABLED=\"$DIRECT_ACTIVE\""))
        XCTAssertTrue(script.contains("PI_ADAPTOR_DIRECT_PORT=\"$DIRECT_PORT\""))
        XCTAssertTrue(script.contains("'PI_HOST_DIRECT_TRUST '*)"))
        XCTAssertTrue(script.contains("chmod 600 \"$trust_tmp\""))
        XCTAssertTrue(script.contains("DIRECT_ACTIVE=0"), "direct 失败不得阻断 loopback")
        try assertShellParses(script)

        let invalid = [
            "wss://host.example", "host.example/path", "user@host.example", "host.example?token=x",
        ]
        for name in invalid + ["::::", "2001:db8:::1", "fe80::1%lo0"] {
            XCTAssertThrowsError(try BootstrapDirectConfiguration(
                directName: name, directPort: 9443, loopbackPort: 43_871
            ), name)
        }
        XCTAssertNoThrow(try BootstrapDirectConfiguration(
            directName: "2001:db8::1", directPort: 9443, loopbackPort: 43_871
        ))
        XCTAssertThrowsError(try BootstrapDirectConfiguration(
            directName: "host.example", directPort: 43_871, loopbackPort: 43_871
        ))
    }

    func testAttemptIdPortAndTimeoutsRejectUnsafeValues() throws {
        let release = try XCTUnwrap(
            PIAdaptorRelease(
                version: "2.0.1",
                target: .linuxX64,
                baseURL: "https://example.test/releases",
                pinnedChecksum: digest
            )
        )
        for attempt in ["", "has space", "quote'bad", "../escape", String(repeating: "a", count: 97)] {
            XCTAssertThrowsError(
                try BootstrapScriptConfiguration(
                    release: release,
                    attemptId: attempt,
                    hostArchitecture: "x86_64",
                    port: 43_871
                )
            ) {
                XCTAssertEqual($0 as? BootstrapScriptError, .invalidAttemptId)
            }
        }
        for port in [0, -1, 65_536] {
            XCTAssertThrowsError(
                try BootstrapScriptConfiguration(
                    release: release,
                    attemptId: "attempt",
                    hostArchitecture: "x86_64",
                    port: port
                )
            ) {
                XCTAssertEqual($0 as? BootstrapScriptError, .invalidPort)
            }
        }
        XCTAssertThrowsError(
            try BootstrapScriptConfiguration(
                release: release,
                attemptId: "attempt",
                hostArchitecture: "x86_64",
                port: 43_871,
                pairingLifetimeMilliseconds: 10_000
            )
        ) {
            XCTAssertEqual($0 as? BootstrapScriptError, .invalidPairingLifetime)
        }
        XCTAssertThrowsError(
            try BootstrapScriptConfiguration(
                release: release,
                attemptId: "attempt",
                hostArchitecture: "x86_64",
                port: 43_871,
                readyTimeoutSeconds: 0
            )
        ) {
            XCTAssertEqual($0 as? BootstrapScriptError, .invalidTimeout)
        }
    }

    func testRemoteCommandsUseSingleProbeBackgroundLaunchAndOwnerOnlyFiles() {
        XCTAssertTrue(BootstrapRemoteCommand.probe.contains("uname -s"))
        XCTAssertTrue(BootstrapRemoteCommand.probe.contains("uname -m"))
        XCTAssertEqual(BootstrapRemoteCommand.probe.components(separatedBy: "uname").count - 1, 2)
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("setsid nohup"))
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("command -v setsid"))
        XCTAssertTrue(BootstrapRemoteCommand.launch.contains("cd \"$work\" || exit 1"))
        XCTAssertTrue(BootstrapRemoteCommand.installScript.contains("umask 077"))
        XCTAssertTrue(BootstrapRemoteCommand.writePairingOK.contains("chmod 600"))
        XCTAssertTrue(BootstrapRemoteCommand.writeVerificationOK.contains("chmod 600"))
    }

    func testPairingMaterialValidationAndRedaction() throws {
        let material = try BootstrapPairingMaterial(
            token: "ppt2." + "valid-token",
            expiresAt: 1_234,
            host: "127.0.0.1",
            port: 43_871
        )
        XCTAssertFalse(material.redactedDescription.contains(material.token))

        for token in ["", "ppt2.", "pdt2.bad", "ppt1." + "legacy-token", "ppt2.has space", "ppt2.quote\""] {
            XCTAssertThrowsError(
                try BootstrapPairingMaterial(
                    token: token,
                    expiresAt: 0,
                    host: "127.0.0.1",
                    port: 43_871
                )
            )
        }
        XCTAssertThrowsError(
            try BootstrapPairingMaterial(
                token: "ppt2." + "valid-token",
                expiresAt: 0,
                host: "0.0.0.0",
                port: 43_871
            )
        )
        XCTAssertNoThrow(
            try BootstrapPairingMaterial(
                token: "ppt1." + "legacy-token",
                expiresAt: 0,
                host: "127.0.0.1",
                port: 43_871,
                allowLegacyPPT1: true
            )
        )
    }

    private func assertShellParses(_ script: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-ios-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bootstrap.sh")
        try Data(script.utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", file.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "POSIX 语法检查失败：\(message)")
    }
}
