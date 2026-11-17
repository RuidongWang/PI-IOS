import Foundation
import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

/// 日志配置随 `state-v1.json` 持久化的测试。
///
/// 覆盖：
/// - AC-L12：旧状态文件没有 `logConfiguration` 字段时回落默认配置，其它字段正常；
/// - AC-L2/L3：AppModel 的日志 setter 立即生效并写盘，重新解码后保持。
///
/// 所有用例只用 UUID 临时目录（状态文件 + 日志目录），不碰真实 App Support。
final class LogConfigurationPersistenceTests: XCTestCase {
    private var root: URL!
    private var stateURL: URL!
    private var logsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateURL = root.appendingPathComponent(StateFile.fileName, isDirectory: false)
        logsURL = root.appendingPathComponent("logs", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - AC-L12 旧状态文件容错解码

    func testLegacyStateFileWithoutLogConfigurationDecodesToDefault() throws {
        let hostID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let legacy = """
        {
          "version": 1,
          "hosts": [{
            "id": "\(hostID.uuidString)",
            "name": "Legacy",
            "host": "192.0.2.10",
            "port": 22,
            "username": "pi",
            "authKind": "password",
            "createdAt": "2024-01-01T00:00:00Z",
            "isCurrent": true,
            "hostPort": 33381
          }],
          "offlineCacheLimit": 500,
          "lastSessionId": "session_legacy",
          "lastProjectId": "project_legacy",
          "readingPositionsByHost": {
            "\(hostID.uuidString)": {
              "session_legacy": {"lastVisibleItemID": "item-1", "isNearBottom": false}
            }
          }
        }
        """
        try Data(legacy.utf8).write(to: stateURL)

        let outcome = StateFile.load(from: stateURL)
        XCTAssertNil(outcome.warning, "缺日志配置字段不应导致读取失败")
        XCTAssertTrue(outcome.canSave)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateURL.path),
            "缺字段的旧状态文件不应被当成损坏文件备份"
        )

        // 缺字段回落默认：开启 / info / 完整时间。
        XCTAssertEqual(outcome.state.logConfiguration, .default)
        XCTAssertTrue(outcome.state.logConfiguration.isEnabled)
        XCTAssertEqual(outcome.state.logConfiguration.level, .info)
        XCTAssertEqual(outcome.state.logConfiguration.timeFormat, .dateTime)

        // 其它字段保持正常。
        XCTAssertEqual(outcome.state.version, 1)
        XCTAssertEqual(outcome.state.offlineCacheLimit, 500)
        XCTAssertEqual(outcome.state.lastSessionId, "session_legacy")
        XCTAssertEqual(outcome.state.lastProjectId, "project_legacy")
        let host = try XCTUnwrap(outcome.state.hosts.first)
        XCTAssertEqual(host.id, hostID)
        XCTAssertEqual(host.hostPort, 33381)
        XCTAssertEqual(
            outcome.state.readingPositionsByHost[hostID.uuidString]?["session_legacy"]?.lastVisibleItemID,
            "item-1"
        )
    }

    func testUnknownOrMistypedLogConfigurationFieldsFallBackIndividually() throws {
        // isEnabled 类型不符 → 默认 true；level 是未知枚举 → 默认 info；timeFormat 合法 → 保留。
        let legacy = """
        {
          "version": 1,
          "logConfiguration": {
            "isEnabled": "yes",
            "level": "trace",
            "timeFormat": "iso8601"
          }
        }
        """
        try Data(legacy.utf8).write(to: stateURL)

        let outcome = StateFile.load(from: stateURL)
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(
            outcome.state.logConfiguration,
            PILogConfiguration(isEnabled: true, level: .info, timeFormat: .iso8601)
        )
    }

    /// 顶层形状被手改成非对象时只回落默认值，整份状态文件不能被判为损坏（否则丢 hosts）。
    func testNonObjectLogConfigurationFallsBackWithoutLosingOtherState() throws {
        for raw in ["\"on\"", "1", "[]"] {
            let legacy = """
            {"version":1,"hosts":[],"offlineCacheLimit":321,"logConfiguration":\(raw)}
            """
            try Data(legacy.utf8).write(to: stateURL)

            let outcome = StateFile.load(from: stateURL)
            XCTAssertNil(outcome.warning, "logConfiguration=\(raw) 不应导致状态文件读取失败")
            XCTAssertTrue(outcome.canSave)
            XCTAssertEqual(outcome.state.logConfiguration, .default, "logConfiguration=\(raw) 回落默认")
            XCTAssertEqual(outcome.state.offlineCacheLimit, 321, "其它字段必须保留")
        }
    }

    // MARK: - AC-L2 / AC-L3 配置持久化

    @MainActor
    func testLogSettersPersistConfigurationToStateFile() async throws {
        // 注入临时目录里的 PILogger，避免写真实 App Support 的日志目录。
        let logStore = PILogger(directoryURL: logsURL)
        let model = AppModel(seed: PersistedState(), stateFileURL: stateURL, logStore: logStore)
        XCTAssertEqual(model.logConfiguration, .default)

        model.setLogLevel(.warn)
        model.setLogTimeFormat(.timeOnly)
        model.setLoggingEnabled(false)

        let expected = PILogConfiguration(isEnabled: false, level: .warn, timeFormat: .timeOnly)
        XCTAssertEqual(model.logConfiguration, expected, "setter 必须立即更新 @Published 配置")
        XCTAssertEqual(logStore.configuration, expected, "setter 必须立即 configure 日志内核")

        let flushed = await model.flushPersistentState()
        XCTAssertTrue(flushed)
        XCTAssertNil(model.saveError)

        // 重新从同一 URL 解码：落盘配置必须正确。
        let outcome = StateFile.load(from: stateURL)
        XCTAssertNil(outcome.warning)
        XCTAssertEqual(outcome.state.logConfiguration, expected)

        // 直接检查落盘 JSON 的字段名与枚举原始值（防止 Codable 键名/原始值漂移）。
        let data = try Data(contentsOf: stateURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persisted = try XCTUnwrap(object["logConfiguration"] as? [String: Any])
        XCTAssertEqual(persisted["isEnabled"] as? Bool, false)
        XCTAssertEqual(persisted["level"] as? String, "warn")
        XCTAssertEqual(persisted["timeFormat"] as? String, "time_only")

        // 模拟重启：用同一状态文件的内容重新构造 AppModel，配置保持。
        let relaunched = AppModel(
            seed: StateFile.load(from: stateURL).state,
            stateFileURL: stateURL,
            logStore: PILogger(directoryURL: logsURL)
        )
        XCTAssertEqual(relaunched.logConfiguration, expected)

        // 收尾：把注入 logger 的待写批次落盘，避免测试结束后残留后台写盘任务。
        logStore.flushSync()
    }

    func testLogExportWriterCreatesReadableUTF8TextFile() throws {
        let expected = "PI-IOS 运行日志\n记录条数：2\n---\n第一条\nsecond line\n"
        let fileURL = try LogExportFileWriter.write(expected)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(fileURL.pathExtension, "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
    }
}
