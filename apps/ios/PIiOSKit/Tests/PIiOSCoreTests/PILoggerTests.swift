import Foundation
import XCTest
@testable import PIiOSCore

/// PILogger / PILogFormatter / PILogFrameIntervalTracker 契约测试。
///
/// 覆盖 docs/specs/ios-log-module.md 的 AC-L2/L3/L4/L5/L6/L7/L10/L11，
/// 以及卡顿阈值（AC-L8 的纯判定部分）。
///
/// 确定性约定：
/// - 每个用例使用 UUID 临时目录，tearDown 删除，不写真实 App Support；
/// - 固定 clock = 2026-11-09 21:46:32.123 +08:00；
/// - 时间格式断言显式注入 Asia/Shanghai 时区；
/// - 导出断言统一使用毫秒时间戳格式，避免依赖运行机器的本地时区。
final class PILoggerTests: XCTestCase {
    /// 2026-11-09 21:46:32.123 +08:00 对应的 Unix 秒。
    private static let fixedDate = Date(timeIntervalSince1970: 1_794_231_992.123)
    /// 同一时刻按毫秒取整后的时间戳，即导出里应出现的字面量。
    private static let fixedMilliseconds: Int64 = 1_794_231_992_123
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private var root: URL!
    private var logsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilogger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logsURL = root.appendingPathComponent("logs", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 测试辅助

    private func makeLogger(
        configuration: PILogConfiguration = .default,
        maxFileBytes: Int = PILogger.maxFileBytes,
        maxFileCount: Int = PILogger.maxFileCount
    ) -> PILogger {
        PILogger(
            directoryURL: logsURL,
            configuration: configuration,
            clock: { PILoggerTests.fixedDate },
            maxFileBytes: maxFileBytes,
            maxFileCount: maxFileCount
        )
    }

    private func makeMetadata(
        configuration: PILogConfiguration,
        generatedAt: Date = PILoggerTests.fixedDate
    ) -> PILogExportMetadata {
        PILogExportMetadata(
            appVersion: "2.0.0",
            buildNumber: "99",
            systemVersion: "iOS 17.4",
            deviceModel: "iPhone15,2",
            configuration: configuration,
            generatedAt: generatedAt
        )
    }

    /// 导出断言用配置：毫秒时间戳与运行机器时区无关。
    private func epochConfiguration(level: PILogLevel = .info) -> PILogConfiguration {
        PILogConfiguration(isEnabled: true, level: level, timeFormat: .epochMillis)
    }

    // MARK: - AC-L2 等级过滤

    func testLevelFilteringMatchesConfiguredLevel() {
        let cases: [(PILogLevel, [PILogLevel])] = [
            (.debug, [.debug, .info, .warn]),
            (.info, [.info, .warn]),
            (.warn, [.warn]),
        ]

        for (configured, expectedLevels) in cases {
            let logger = makeLogger(configuration: PILogConfiguration(level: configured))
            for level in PILogLevel.allCases {
                logger.log(level: level, category: "Level", message: "msg-\(level.rawValue)")
            }
            logger.flushSync()

            XCTAssertEqual(
                logger.recentRecords().map(\.level),
                expectedLevels,
                "配置 \(configured.rawValue) 应只保留 \(expectedLevels.map(\.rawValue))"
            )
            XCTAssertEqual(logger.storedRecordCount(), expectedLevels.count)
            for level in PILogLevel.allCases {
                XCTAssertEqual(
                    logger.isEnabled(for: level),
                    expectedLevels.contains(level),
                    "配置 \(configured.rawValue) 的 isEnabled(for: \(level.rawValue)) 应一致"
                )
            }
            logger.clear()
        }
    }

    func testDisabledLoggingDropsNewRecordsButKeepsExistingOnes() {
        let logger = makeLogger()
        logger.log(level: .info, category: "Enabled", message: "关闭前")
        logger.flushSync()

        logger.configure(PILogConfiguration(isEnabled: false, level: .debug, timeFormat: .dateTime))
        XCTAssertFalse(logger.isEnabled(for: .warn))
        logger.log(level: .warn, category: "Disabled", message: "关闭后")
        logger.flushSync()

        XCTAssertEqual(logger.recentRecords().map(\.message), ["关闭前"])
        XCTAssertEqual(logger.storedRecordCount(), 1)
        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains("关闭前"), "关闭日志后已有记录必须保留且可导出")
        XCTAssertFalse(export.contains("关闭后"), "关闭日志后不得产生新记录")
    }

    func testFilteredRecordsNeverReachWriteObserver() {
        let logger = makeLogger(configuration: PILogConfiguration(level: .warn))
        let probe = WriteObserverProbe()
        logger.setWriteObserverForTesting { probe.record($0) }

        logger.log(level: .debug, category: "Filtered", message: "debug")
        logger.log(level: .info, category: "Filtered", message: "info")
        logger.flushSync()

        XCTAssertTrue(probe.capturedLines.isEmpty, "等级过滤必须在入队/写盘前发生")
        XCTAssertEqual(logger.storedRecordCount(), 0)

        logger.log(level: .warn, category: "Filtered", message: "warn")
        logger.flushSync()
        XCTAssertEqual(probe.capturedLines.count, 1)
        logger.setWriteObserverForTesting(nil)
    }

    func testConfigureKeepsPendingBatchOnDisk() throws {
        let logger = makeLogger()
        logger.log(level: .info, category: "Pending", message: "排刷前")

        // configure 立即生效，但不能丢掉已入队的待写批次（契约 §5.4）。
        logger.configure(PILogConfiguration(isEnabled: false, level: .info, timeFormat: .dateTime))
        logger.flushSync()

        XCTAssertEqual(logger.storedRecordCount(), 1)
        let stored = try storedJSONLines(in: logsURL.appendingPathComponent("piios.log"))
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: - AC-L3 时间格式

    func testFormatterRendersAllFourTimeFormatsExactly() {
        let date = Self.fixedDate

        XCTAssertEqual(
            PILogFormatter.timeText(date, format: .dateTime, timeZone: Self.shanghai),
            "2026-11-09 21:46:32.123"
        )
        XCTAssertEqual(
            PILogFormatter.timeText(date, format: .iso8601, timeZone: Self.shanghai),
            "2026-11-09T21:46:32.123+08:00"
        )
        XCTAssertEqual(
            PILogFormatter.timeText(date, format: .timeOnly, timeZone: Self.shanghai),
            "21:46:32.123"
        )
        XCTAssertEqual(
            PILogFormatter.timeText(date, format: .epochMillis, timeZone: Self.shanghai),
            "1794231992123"
        )

        // 固定行格式：`<time> [<LEVEL>] [<category>] <message>`。
        let record = PILogRecord(
            sequence: 7,
            timestamp: date,
            level: .warn,
            category: "Format",
            message: "hello"
        )
        XCTAssertEqual(
            PILogFormatter.line(record, timeFormat: .iso8601, timeZone: Self.shanghai),
            "2026-11-09T21:46:32.123+08:00 [WARN] [Format] hello"
        )
        XCTAssertEqual(
            PILogFormatter.line(record, timeFormat: .timeOnly, timeZone: Self.shanghai),
            "21:46:32.123 [WARN] [Format] hello"
        )
    }

    // MARK: - AC-L4 落盘与重启

    func testWritesFrozenJSONLSchemaAndSurvivesRelaunch() throws {
        let logger = makeLogger()
        logger.log(level: .info, category: "Persist", message: "第一条")
        logger.log(level: .warn, category: "Persist", message: "second line")
        logger.log(level: .debug, category: "Persist", message: "被 info 等级过滤")
        logger.flushSync()

        XCTAssertEqual(logger.storedRecordCount(), 2)
        XCTAssertEqual(logger.storedFileCount(), 1)

        // 磁盘格式（契约 §3）：基础字段 `{"t":<毫秒>,"l":"...","c":"...","m":"..."}`；
        // warn 捕获到调用点时追加可选 `f`/`fn`/`ln`（本用例经 logger.log 记录，无来源，保持旧格式）。
        let fileURL = logsURL.appendingPathComponent("piios.log")
        let objects = try storedJSONLines(in: fileURL)
        XCTAssertEqual(objects.count, 2)
        let first = try XCTUnwrap(objects.first)
        XCTAssertEqual(Set(first.keys), Set(["t", "l", "c", "m"]))
        XCTAssertEqual((first["t"] as? NSNumber)?.int64Value, Self.fixedMilliseconds)
        XCTAssertEqual(first["l"] as? String, "info")
        XCTAssertEqual(first["c"] as? String, "Persist")
        XCTAssertEqual(first["m"] as? String, "第一条")
        let second = try XCTUnwrap(objects.last)
        XCTAssertEqual(second["l"] as? String, "warn")
        XCTAssertEqual(second["m"] as? String, "second line")

        // 重启：同目录新实例不需要任何内存状态即可读回。
        let relaunched = PILogger(directoryURL: logsURL)
        XCTAssertEqual(relaunched.storedRecordCount(), 2)
        let export = relaunched.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains("记录条数：2"))
        XCTAssertTrue(export.contains("1794231992123 [INFO] [Persist] 第一条"))
        XCTAssertTrue(export.contains("1794231992123 [WARN] [Persist] second line"))
        let firstRange = try XCTUnwrap(export.range(of: "第一条"))
        let secondRange = try XCTUnwrap(export.range(of: "second line"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound, "导出顺序应为旧→新")
    }

    func testJSONLKeepsNewlinesAndQuotesInsideMessage() throws {
        let logger = makeLogger()
        let message = "第一行 \"引号\"\n第二行"
        logger.log(level: .info, category: "Escape", message: message)
        logger.flushSync()

        let fileURL = logsURL.appendingPathComponent("piios.log")
        let raw = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        let rawLines = raw.split(separator: "\n").map(String.init)
        XCTAssertEqual(rawLines.count, 1, "消息内换行必须由 JSON 编码，JSONL 仍是一行一条记录")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(rawLines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["m"] as? String, message)

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains(message), "导出时消息按原样输出（换行保留在消息内）")
    }

    func testOversizedMessageUsesSameNormalizedRecordForMemoryDiskMergeAndExport() throws {
        let logger = makeLogger()
        let marker = "…（日志过长已截断）"
        let prefix = String(repeating: "a", count: 64 * 1024 - 3)
        let original = prefix + "日志" + String(repeating: "b", count: 128)
        XCTAssertGreaterThan(original.utf8.count, 64 * 1024)

        logger.log(level: .info, category: "Truncation", message: original)
        logger.flushSync()

        let recent = try XCTUnwrap(logger.recentRecords().first)
        let stored = try XCTUnwrap(logger.storedRecords().first)
        XCTAssertEqual(recent.message, stored.message, "内存与磁盘必须使用同一份规范化消息")
        XCTAssertEqual(recent.message.utf8.count, 64 * 1024 + marker.utf8.count)
        XCTAssertTrue(recent.message.hasSuffix("日\(marker)"), "UTF-8 边界必须保留完整字符")
        XCTAssertFalse(recent.message.contains("b"), "64 KiB 之后的原始尾部不得保留")
        XCTAssertFalse(recent.message.contains("\u{FFFD}"))

        let merged = PILogRecordMerge.merge(stored: [stored], recent: [recent])
        XCTAssertEqual(merged.count, 1, "同一条规范化记录落盘后不得被 merge 成两条")

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertEqual(export.components(separatedBy: marker).count - 1, 1, "截断标记不得重复")
    }

    // MARK: - AC-L5 导出格式

    func testEmptyExportContainsFrozenHeaderAndPlaceholder() {
        let logger = makeLogger()
        let export = logger.exportText(
            metadata: makeMetadata(
                configuration: PILogConfiguration(isEnabled: true, level: .warn, timeFormat: .epochMillis)
            )
        )
        let expected = [
            "PI-IOS 运行日志",
            "导出时间：1794231992123",
            "应用版本：2.0.0 (99)",
            "系统版本：iOS 17.4",
            "设备：iPhone15,2",
            "日志等级：WARN",
            "时间格式：毫秒时间戳",
            "记录条数：0",
            "---",
            "（暂无日志）",
        ].joined(separator: "\n") + "\n"

        XCTAssertEqual(export, expected)
        XCTAssertFalse(export.contains("\r\n"), "导出固定使用 \\n 行尾")
    }

    func testExportHeaderCountAndLineFormatForStoredRecords() {
        let logger = makeLogger()
        logger.log(level: .info, category: "Export", message: "first")
        logger.log(level: .warn, category: "Export", message: "second")
        logger.log(level: .debug, category: "Export", message: "filtered")
        logger.flushSync()

        let export = logger.exportText(
            metadata: makeMetadata(configuration: epochConfiguration(level: .warn))
        )
        let expected = [
            "PI-IOS 运行日志",
            "导出时间：1794231992123",
            "应用版本：2.0.0 (99)",
            "系统版本：iOS 17.4",
            "设备：iPhone15,2",
            "日志等级：WARN",
            "时间格式：毫秒时间戳",
            "记录条数：2",
            "---",
            "1794231992123 [INFO] [Export] first",
            "1794231992123 [WARN] [Export] second",
        ].joined(separator: "\n") + "\n"

        XCTAssertEqual(export, expected)
    }

    func testExportBeyondFiveHundredIncludesFirstAndLastRecords() throws {
        let totalRecords = 520
        let logger = makeLogger()
        for index in 1...totalRecords {
            logger.log(
                level: .info,
                category: "ExportAll",
                message: String(format: "export-%04d", index)
            )
        }

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        let firstLine = "\(Self.fixedMilliseconds) [INFO] [ExportAll] export-0001"
        let lastLine = "\(Self.fixedMilliseconds) [INFO] [ExportAll] export-0520"
        XCTAssertTrue(export.contains("记录条数：\(totalRecords)"))
        let firstRange = try XCTUnwrap(export.range(of: firstLine))
        let lastRange = try XCTUnwrap(export.range(of: lastLine))
        XCTAssertLessThan(firstRange.lowerBound, lastRange.lowerBound)
    }

    func testChangingTimeFormatRerendersExistingRecords() {
        let logger = makeLogger()
        logger.log(level: .info, category: "Switch", message: "旧记录")
        logger.flushSync()

        // 旧记录先按完整时间导出。
        let dateTimeExport = logger.exportText(
            metadata: makeMetadata(
                configuration: PILogConfiguration(isEnabled: true, level: .info, timeFormat: .dateTime)
            )
        )
        XCTAssertTrue(dateTimeExport.contains("时间格式：完整时间"))
        XCTAssertTrue(dateTimeExport.contains("[INFO] [Switch] 旧记录"))

        // 只改导出时的时间格式，磁盘上的旧记录按新格式重新渲染。
        let epochExport = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(epochExport.contains("时间格式：毫秒时间戳"))
        XCTAssertTrue(epochExport.contains("1794231992123 [INFO] [Switch] 旧记录"))
        XCTAssertFalse(epochExport.contains("2026-11-09"), "毫秒时间戳格式不应再出现日期文本")
    }

    // MARK: - AC-L11 轮转

    func testRotationKeepsAtMostMaxFileCountAndDropsOldestContent() throws {
        let maxFileBytes = 300
        let totalRecords = 40
        let logger = makeLogger(maxFileBytes: maxFileBytes)

        for index in 1...totalRecords {
            logger.log(
                level: .info,
                category: "Rotate",
                message: String(format: "msg-%04d", index)
            )
            // 单条一批落盘，确保按契约「写入后超过上限即轮转」逐批触发。
            logger.flushSync()
            XCTAssertLessThanOrEqual(logger.storedFileCount(), PILogger.maxFileCount)
        }

        XCTAssertEqual(logger.storedFileCount(), PILogger.maxFileCount)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: logsURL.path))
        XCTAssertEqual(names, Set(["piios.log", "piios.1.log", "piios.2.log"]))
        XCTAssertLessThanOrEqual(
            logger.storedByteCount(),
            maxFileBytes * PILogger.maxFileCount,
            "三个文件的总字节数不能超过轮转上限（不无限增长）"
        )

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains("记录条数：\(logger.storedRecordCount())"))
        XCTAssertFalse(export.contains("msg-0001"), "最旧内容必须被淘汰")

        let messages = rotatedMessageNumbers(in: export)
        XCTAssertEqual(messages, messages.sorted(), "导出顺序应为旧→新")
        XCTAssertEqual(messages.last, totalRecords, "最新一条必须保留")
        XCTAssertGreaterThan(messages.count, 0)
        XCTAssertLessThan(messages.count, totalRecords, "轮转后保留条数应小于总写入条数")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(messages.first), 2, "至少最旧一条已被淘汰")
    }

    func testMaxFileCountOneKeepsSingleCurrentFile() throws {
        let logger = makeLogger(maxFileBytes: 120, maxFileCount: 1)
        for index in 1...10 {
            logger.log(level: .info, category: "Small", message: "m\(index)")
            logger.flushSync()
        }
        XCTAssertEqual(logger.storedFileCount(), 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: logsURL.path)
        XCTAssertEqual(names, ["piios.log"], "maxFileCount=1 只保留当前文件")
        XCTAssertTrue(
            logger.exportText(metadata: makeMetadata(configuration: epochConfiguration())).contains("m10"),
            "最新一条必须保留"
        )
    }

    func testRecentRecordsDefaultReturnsEveryRecordBeyondFiveHundred() {
        let totalRecords = 560
        let logger = makeLogger()
        for index in 1...totalRecords {
            logger.log(
                level: .info,
                category: "RecentAll",
                message: String(format: "memory-%04d", index)
            )
        }

        let records = logger.recentRecords()
        XCTAssertEqual(records.count, totalRecords)
        XCTAssertEqual(records.first?.message, "memory-0001")
        XCTAssertEqual(records.last?.message, "memory-0560")
        XCTAssertEqual(
            logger.recentRecords(limit: 2).map(\.message),
            ["memory-0559", "memory-0560"],
            "显式 limit 仍只投影最新 N 条"
        )
        XCTAssertTrue(logger.recentRecords(limit: 0).isEmpty)
        XCTAssertTrue(logger.recentRecords(limit: -1).isEmpty)
    }

    func testStoredRecordsAfterRelaunchDefaultReturnsEveryRecordBeyondFiveHundred() {
        let totalRecords = 540
        let logger = makeLogger()
        for index in 1...totalRecords {
            logger.log(
                level: .info,
                category: "StoredAll",
                message: String(format: "disk-%04d", index)
            )
        }
        logger.flushSync()

        let relaunched = PILogger(directoryURL: logsURL)
        let records = relaunched.storedRecords()
        XCTAssertEqual(records.count, totalRecords)
        XCTAssertEqual(records.first?.message, "disk-0001")
        XCTAssertEqual(records.last?.message, "disk-0540")
    }

    func testStoredRecordsReturnsOldestToNewestLimitedSlice() {
        let logger = makeLogger()
        for index in 1...5 {
            logger.log(level: .info, category: "Recent", message: "r\(index)")
        }
        logger.flushSync()
        XCTAssertEqual(logger.storedRecords(limit: 2).map(\.message), ["r4", "r5"])
        XCTAssertEqual(logger.storedRecords(limit: 99).count, 5)
        XCTAssertTrue(logger.storedRecords(limit: 0).isEmpty)
        XCTAssertTrue(logger.storedRecords(limit: -1).isEmpty)
    }

    func testExportSkipsInvalidUTF8LineWithoutDroppingWholeFile() throws {
        let logger = makeLogger()
        logger.log(level: .info, category: "Corrupt", message: "有效行")
        logger.flushSync()

        // 模拟崩溃/断电把中文多字节截断：追加半个「中」的 UTF-8 与换行。
        let fileURL = logsURL.appendingPathComponent("piios.log")
        var data = try Data(contentsOf: fileURL)
        data.append(contentsOf: [0xE4, 0xB8])
        data.append(contentsOf: Array("\n".utf8))
        try data.write(to: fileURL)

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains("有效行"), "坏行只跳过自己，不能丢掉整份文件")
        XCTAssertTrue(export.contains("记录条数：1"))
    }

    func testExportSnapshotDefersConcurrentWritesToNextBatch() {
        let logger = makeLogger()
        let probe = ConcurrentExportProbe(maximumPasses: 8)
        logger.setWriteObserverForTesting { _ in
            if let message = probe.nextMessage() {
                logger.log(level: .info, category: "ExportRace", message: message)
            }
        }
        defer { logger.setWriteObserverForTesting(nil) }
        logger.log(level: .info, category: "ExportRace", message: "initial")

        let firstExport = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertEqual(probe.observedPasses, 1)
        XCTAssertEqual(logger.recentRecords().count, 2)
        XCTAssertTrue(firstExport.contains("记录条数：1"), "首批快照只包含导出开始时已 pending 的记录")
        XCTAssertFalse(firstExport.contains("concurrent-1"), "observer 期间的新记录必须留到下一批")

        logger.flushSync()
        XCTAssertEqual(probe.observedPasses, 8)
        let nextExport = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertEqual(logger.recentRecords().count, 9)
        XCTAssertTrue(nextExport.contains("记录条数：9"), "后续普通 drain 不得丢掉有限并发记录")
        XCTAssertTrue(nextExport.contains("concurrent-8"))
    }

    func testExportReturnsBoundedSnapshotWithContinuousProducer() {
        let logger = makeLogger()
        let probe = ContinuousExportProbe()
        logger.setWriteObserverForTesting { _ in
            if let message = probe.nextMessage() {
                logger.log(level: .info, category: "ExportLiveness", message: message)
            }
        }
        let metadata = makeMetadata(configuration: epochConfiguration())
        let finished = DispatchSemaphore(value: 0)
        logger.log(level: .info, category: "ExportLiveness", message: "initial")
        DispatchQueue.global(qos: .utility).async {
            let text = logger.exportText(metadata: metadata)
            probe.store(text)
            finished.signal()
        }

        let completed = finished.wait(timeout: .now() + 1) == .success
        probe.stop()
        if !completed {
            _ = finished.wait(timeout: .now() + 2)
        }
        logger.setWriteObserverForTesting(nil)

        XCTAssertTrue(completed, "持续生产者下 export 必须有界返回")
        guard completed else { return }
        XCTAssertTrue(probe.exportedText.contains("记录条数：1"))
        XCTAssertFalse(probe.exportedText.contains("continuous-1"))
        XCTAssertEqual(probe.messageCount, 1, "导出只写首批；回调产生的一条记录留待下批")
    }

    // MARK: - 报错来源（warn 调用点）

    /// warn 必须通过 `#fileID` / `#function` / `#line` 自动捕获调用点；
    /// 来源段只出现在 warn 行，info/debug 保持旧格式。
    func testWarnCapturesCallSiteAndFormatsSourceOnlyForWarn() throws {
        let logger = makeLogger()
        PILog.sharedLoggerForTesting = logger
        defer { PILog.sharedLoggerForTesting = nil }

        let expectedLine = emitWarningForSourceTest("warn 定位")

        let record = try XCTUnwrap(logger.recentRecords().last)
        XCTAssertEqual(record.level, .warn)
        XCTAssertEqual(record.message, "warn 定位")
        let source = try XCTUnwrap(record.source, "PILog.warn 必须自动捕获调用点")
        XCTAssertEqual(source.file, #fileID, "来源文件应为调用点所在文件")
        XCTAssertTrue(source.file.hasSuffix("PILoggerTests.swift"), "实际 file=\(source.file)")
        XCTAssertTrue(source.function.contains("emitWarningForSourceTest"), "实际 function=\(source.function)")
        XCTAssertEqual(source.line, expectedLine)

        XCTAssertEqual(
            PILogFormatter.line(record, timeFormat: .epochMillis, timeZone: Self.shanghai),
            "1794231992123 [WARN] [SourceTest] [\(source.file):\(source.function):\(source.line)] warn 定位"
        )

        // 落盘再读取：JSONL 必须带可选 f/fn/ln，导出文本包含来源段。
        logger.flushSync()
        let object = try XCTUnwrap(
            storedJSONLines(in: logsURL.appendingPathComponent("piios.log")).last
        )
        XCTAssertEqual(object["f"] as? String, source.file)
        XCTAssertEqual(object["fn"] as? String, source.function)
        XCTAssertEqual((object["ln"] as? NSNumber)?.intValue, source.line)

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration(level: .warn)))
        XCTAssertTrue(export.contains("[\(source.file):\(source.function):\(source.line)] warn 定位"))

        // info/debug 即使调用方手工构造了 source，也渲染成旧格式。
        let info = PILogRecord(
            sequence: 99,
            timestamp: Self.fixedDate,
            level: .info,
            category: "SourceTest",
            message: "info",
            source: source
        )
        XCTAssertEqual(
            PILogFormatter.line(info, timeFormat: .epochMillis, timeZone: Self.shanghai),
            "1794231992123 [INFO] [SourceTest] info"
        )
    }

    /// 旧 JSONL 没有 f/fn/ln：整行仍可解码（source = nil），导出保持旧格式。
    func testLegacyJSONLWithoutSourceFieldsDecodesAndExportsOldFormat() throws {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let legacyLine = #"{"t":1794231992123,"l":"warn","c":"Legacy","m":"旧日志无来源"}"# + "\n"
        try legacyLine.write(
            to: logsURL.appendingPathComponent("piios.log"),
            atomically: true,
            encoding: .utf8
        )

        let logger = PILogger(directoryURL: logsURL)
        let record = try XCTUnwrap(logger.storedRecords().first)
        XCTAssertEqual(record.level, .warn)
        XCTAssertNil(record.source, "缺 f/fn/ln 的旧日志必须降级为 source=nil，而不是整行丢弃")
        XCTAssertEqual(record.message, "旧日志无来源")

        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration(level: .warn)))
        XCTAssertTrue(export.contains("1794231992123 [WARN] [Legacy] 旧日志无来源"))
        XCTAssertFalse(export.contains("[Legacy] ["), "旧日志不得凭空出现来源段")
    }

    /// 只有捕获到来源的 warn 行才写 f/fn/ln；source 为 nil 时保持旧的 JSON 字段集合。
    func testJSONLSourceFieldsAreOptionalAndRoundTrip() throws {
        let logger = makeLogger()
        let source = PILogSource(
            file: "PIiOSCore/Diagnostics/PILogging.swift",
            function: "warn(_:_:file:function:line:)",
            line: 42
        )
        logger.log(level: .warn, category: "Schema", message: "带来源", source: source)
        logger.log(level: .info, category: "Schema", message: "无来源")
        logger.flushSync()

        let objects = try storedJSONLines(in: logsURL.appendingPathComponent("piios.log"))
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(Set(objects[0].keys), Set(["t", "l", "c", "m", "f", "fn", "ln"]))
        XCTAssertEqual(
            Set(objects[1].keys),
            Set(["t", "l", "c", "m"]),
            "source 为 nil 时不得写可选字段，保持旧行格式"
        )
        XCTAssertEqual(objects[0]["f"] as? String, source.file)
        XCTAssertEqual(objects[0]["fn"] as? String, source.function)
        XCTAssertEqual((objects[0]["ln"] as? NSNumber)?.intValue, 42)

        let records = logger.storedRecords()
        XCTAssertEqual(records[0].source, source)
        XCTAssertNil(records[1].source)
    }

    /// 同一毫秒、同等级/分类/消息但来源不同：不得误合并，identity 也不得碰撞。
    func testMergeDistinguishesDifferentSourcesAndDeduplicatesSameSource() {
        let sourceA = PILogSource(file: "A.swift", function: "a()", line: 10)
        let sourceB = PILogSource(file: "B.swift", function: "b()", line: 20)
        let stored = [
            makeRecord(sequence: 1, milliseconds: 9_000, level: .warn, message: "同毫秒同文案", source: sourceA),
        ]
        let recent = [
            makeRecord(sequence: 2, milliseconds: 9_000, level: .warn, message: "同毫秒同文案", source: sourceB),
            makeRecord(sequence: 3, milliseconds: 9_000, level: .warn, message: "同毫秒同文案", source: sourceA),
        ]

        let merged = PILogRecordMerge.merge(stored: stored, recent: recent, limit: 50)
        XCTAssertEqual(merged.count, 2, "来源不同不得合并；来源相同的磁盘/内存记录只保留一份")
        XCTAssertEqual(merged.map(\.source), [sourceA, sourceB])
        XCTAssertEqual(Set(merged.map(\.id)).count, 2, "不同来源的 identity 不得碰撞")

        let noSource = PILogRecordMerge.merge(
            stored: [makeRecord(sequence: 1, milliseconds: 1_000, message: "无来源")],
            recent: [makeRecord(sequence: 2, milliseconds: 1_000, message: "无来源")]
        )
        XCTAssertEqual(noSource.count, 1, "旧日志（无来源）仍按原口径去重")
    }

    // MARK: - AC-L7 清空

    func testClearRemovesMemoryAndDiskRecords() {
        let logger = makeLogger()
        logger.log(level: .info, category: "Clear", message: "待清空 1")
        logger.log(level: .warn, category: "Clear", message: "待清空 2")
        logger.flushSync()
        XCTAssertEqual(logger.storedRecordCount(), 2)
        XCTAssertEqual(logger.storedFileCount(), 1)

        logger.clear()

        XCTAssertTrue(logger.recentRecords().isEmpty)
        XCTAssertEqual(logger.storedRecordCount(), 0)
        XCTAssertEqual(logger.storedFileCount(), 0)
        XCTAssertEqual(logger.storedByteCount(), 0)
        let export = logger.exportText(metadata: makeMetadata(configuration: epochConfiguration()))
        XCTAssertTrue(export.contains("记录条数：0"))
        XCTAssertTrue(export.contains("（暂无日志）"))
        XCTAssertFalse(export.contains("待清空"))

        // 清空后仍可继续记录（AC-L7 只要求清空，不要求停用）。
        logger.log(level: .info, category: "Clear", message: "清空后")
        logger.flushSync()
        XCTAssertEqual(logger.storedRecordCount(), 1)
    }

    // MARK: - AC-L10 写盘线程

    /// 常规路径：主线程 `log()` 只入队，写盘由后台串行队列执行。
    func testAsyncFlushWritesOffMainThread() {
        let logger = makeLogger()
        let probe = WriteObserverProbe()
        logger.setWriteObserverForTesting { probe.record($0) }

        logger.log(level: .info, category: "Thread", message: "主线程只入队")
        logger.flush()

        XCTAssertTrue(probe.waitForWrite(timeout: 2), "后台写盘回调超时")
        XCTAssertEqual(probe.capturedLines.count, 1)
        XCTAssertFalse(probe.observedOnMainThread, "AC-L10：写盘不得在主线程执行")
        logger.setWriteObserverForTesting(nil)
    }

    /// 显式同步路径：主线程调用 `flushSync()` 时，落盘也只在后台串行队列执行（AC-L10）。
    @MainActor
    func testFlushSyncFromMainThreadWritesOffMainThread() {
        let logger = makeLogger()
        let probe = WriteObserverProbe()
        logger.setWriteObserverForTesting { probe.record($0) }

        logger.log(level: .info, category: "Thread", message: "主线程 flushSync")
        logger.flushSync()

        XCTAssertEqual(probe.capturedLines.count, 1)
        XCTAssertFalse(probe.observedOnMainThread, "AC-L10：主线程调用 flushSync 也不得在主线程落盘")
        logger.setWriteObserverForTesting(nil)
    }

    /// 退后台路径：App 用 `Task.detached` 调 `flushSync()`，落盘仍不在主线程。
    func testFlushSyncFromBackgroundThreadWritesOffMainThread() {
        let logger = makeLogger()
        let probe = WriteObserverProbe()
        logger.setWriteObserverForTesting { probe.record($0) }

        DispatchQueue.global(qos: .utility).async {
            logger.log(level: .warn, category: "Thread", message: "后台落盘")
            logger.flushSync()
        }

        XCTAssertTrue(probe.waitForWrite(timeout: 2), "后台 flushSync 写盘回调超时")
        XCTAssertFalse(probe.observedOnMainThread)
        logger.setWriteObserverForTesting(nil)
    }

    // MARK: - 卡顿阈值

    func testFrameIntervalTrackerReportsOnlyStallsAboveThreshold() throws {
        var tracker = PILogFrameIntervalTracker()
        XCTAssertEqual(tracker.thresholdMilliseconds, 150)

        XCTAssertNil(tracker.ingest(timestamp: 10.0), "第一帧只建立基准")
        XCTAssertNil(tracker.ingest(timestamp: 10.1), "100ms 未超过 150ms 阈值")

        let stall = tracker.ingest(timestamp: 10.34)
        XCTAssertEqual(try XCTUnwrap(stall), 240, accuracy: 0.001, "超阈值应返回实际毫秒数")

        tracker.reset()
        XCTAssertNil(tracker.ingest(timestamp: 20.0), "reset 后第一帧重新建立基准")
        XCTAssertNil(tracker.ingest(timestamp: 20.1), "150ms 以下不记录")
        XCTAssertNil(tracker.ingest(timestamp: 20.05), "时间回退不误报")

        var strict = PILogFrameIntervalTracker(thresholdMilliseconds: 50)
        XCTAssertEqual(strict.thresholdMilliseconds, 50)
        XCTAssertNil(strict.ingest(timestamp: 0))
        XCTAssertEqual(try XCTUnwrap(strict.ingest(timestamp: 0.1)), 100, accuracy: 0.001)
    }

    // MARK: - 日志页合并（磁盘快照 + 内存记录）

    /// 重启场景：磁盘是上一次运行的历史，内存只有本次运行的新记录，合并后两者都必须出现。
    /// 这里刻意让新进程的 sequence 从 1 开始，与磁盘级联兜底序号重叠（真实场景）。
    func testMergeRelaunchKeepsStoredHistoryAndNewSessionRecords() {
        let stored = [
            makeRecord(sequence: 1, milliseconds: 1_000, message: "旧-1"),
            makeRecord(sequence: 2, milliseconds: 2_000, message: "旧-2"),
            makeRecord(sequence: 3, milliseconds: 3_000, message: "旧-3"),
        ]
        let recent = [
            makeRecord(sequence: 1, milliseconds: 4_000, message: "新-1"),
            makeRecord(sequence: 2, milliseconds: 5_000, message: "新-2"),
        ]

        let merged = PILogRecordMerge.merge(stored: stored, recent: recent, limit: 50)

        XCTAssertEqual(
            merged.map(\.message),
            ["旧-1", "旧-2", "旧-3", "新-1", "新-2"],
            "重启后磁盘历史与本次运行的新记录都必须保留"
        )
        XCTAssertEqual(merged.map(\.timestamp), merged.map(\.timestamp).sorted(), "合并结果按时间升序")
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "合并结果用于 ForEach，id 必须唯一")
    }

    func testMergeDefaultReturnsEveryRecordBeyondFiveHundred() {
        let stored = (1...320).map { index in
            makeRecord(
                sequence: UInt64(index),
                milliseconds: Int64(index) * 1_000,
                message: String(format: "merged-%04d", index)
            )
        }
        let recent = (321...560).map { index in
            makeRecord(
                sequence: UInt64(index),
                milliseconds: Int64(index) * 1_000,
                message: String(format: "merged-%04d", index)
            )
        }

        let merged = PILogRecordMerge.merge(stored: stored, recent: recent)
        XCTAssertEqual(merged.count, 560)
        XCTAssertEqual(merged.first?.message, "merged-0001")
        XCTAssertEqual(merged.last?.message, "merged-0560")
    }

    /// 日志关闭场景：内存为空、磁盘有历史。只读内存会让页面变「暂无日志」，合并后必须继续显示历史。
    func testMergeKeepsStoredHistoryWhenMemoryIsEmptyAfterDisable() {
        let stored = [
            makeRecord(sequence: 1, milliseconds: 1_000, message: "关闭前 1"),
            makeRecord(sequence: 2, milliseconds: 2_000, message: "关闭前 2"),
        ]

        let merged = PILogRecordMerge.merge(stored: stored, recent: [], limit: 50)

        XCTAssertEqual(merged.map(\.message), ["关闭前 1", "关闭前 2"], "关闭日志后已有记录必须继续显示")
        XCTAssertEqual(merged.count, 2)
    }

    /// 重叠去重：同一条记录既已落盘、又还在内存记录里时只能出现一次；
    /// 去重键含等级/分类/消息，同毫秒不同内容仍然是两条。
    func testMergeDeduplicatesOverlappingStoredAndRecentRecords() {
        let stored = [
            makeRecord(sequence: 1, milliseconds: 1_000, message: "第一条"),
            makeRecord(sequence: 2, milliseconds: 2_000, message: "第二条"),
        ]
        let recent = [
            makeRecord(sequence: 7, milliseconds: 2_000, message: "第二条"),
            makeRecord(sequence: 8, milliseconds: 3_000, message: "第三条"),
        ]

        let merged = PILogRecordMerge.merge(stored: stored, recent: recent, limit: 50)

        XCTAssertEqual(merged.map(\.message), ["第一条", "第二条", "第三条"])
        XCTAssertEqual(merged.filter { $0.message == "第二条" }.count, 1, "磁盘与内存重叠的记录只能保留一条")
        XCTAssertEqual(Set(merged.map(\.id)).count, 3)

        let sameMillisecondDifferentLevel = PILogRecordMerge.merge(
            stored: [makeRecord(sequence: 1, milliseconds: 4_000, level: .info, message: "同毫秒")],
            recent: [makeRecord(sequence: 2, milliseconds: 4_000, level: .warn, message: "同毫秒")],
            limit: 50
        )
        XCTAssertEqual(sameMillisecondDifferentLevel.count, 2, "等级不同不算重复")

        // 磁盘只存毫秒，内存 timestamp 可能带亚毫秒：同一毫秒同内容必须视为同一条。
        let subMillisecond = PILogRecordMerge.merge(
            stored: [makeRecord(sequence: 1, milliseconds: 5_000, message: "同一毫秒")],
            recent: [PILogRecord(
                sequence: 9,
                timestamp: Date(timeIntervalSince1970: 5.0009),
                level: .info,
                category: "Merge",
                message: "同一毫秒"
            )],
            limit: 50
        )
        XCTAssertEqual(subMillisecond.count, 1, "去重按毫秒时间戳，亚毫秒差异不产生重复行")
    }

    func testMergeIdentityDoesNotCollideWhenFieldsContainDelimiter() {
        let recent = [
            makeRecord(sequence: 1, milliseconds: 9_000, category: "A|B", message: "C"),
            makeRecord(sequence: 2, milliseconds: 9_000, category: "A", message: "B|C"),
        ]

        let merged = PILogRecordMerge.merge(stored: [], recent: recent)
        XCTAssertEqual(merged.count, 2, "不同 category/message 的记录必须都保留")
        XCTAssertEqual(merged.map(\.category), ["A|B", "A"])
        XCTAssertEqual(Set(merged.map(\.id)).count, 2, "字段中的分隔符不得造成 identity 碰撞")
    }

    /// 显式 limit：只保留最新 N 条；非正数返回空。
    func testMergeLimitKeepsNewestRecordsAndHandlesNonPositiveLimit() {
        let recent = (1...5).map { index in
            makeRecord(sequence: UInt64(index), milliseconds: Int64(index) * 1_000, message: "r\(index)")
        }

        XCTAssertEqual(
            PILogRecordMerge.merge(stored: [], recent: recent, limit: 2).map(\.message),
            ["r4", "r5"],
            "limit 取末尾（最新）N 条"
        )
        XCTAssertEqual(PILogRecordMerge.merge(stored: [], recent: recent, limit: 99).count, 5)
        XCTAssertTrue(PILogRecordMerge.merge(stored: [], recent: recent, limit: 0).isEmpty)
        XCTAssertTrue(PILogRecordMerge.merge(stored: [], recent: recent, limit: -3).isEmpty)
        XCTAssertTrue(PILogRecordMerge.merge(stored: [], recent: [], limit: 50).isEmpty)
    }

    /// 顺序稳定性：同一输入重复合并逐条相等；同一毫秒保持输入顺序（磁盘在前、内存之后）。
    func testMergeOrderIsStableForRecordsInTheSameMillisecond() {
        let stored = [makeRecord(sequence: 1, milliseconds: 9_000, message: "磁盘")]
        let recent = [
            makeRecord(sequence: 2, milliseconds: 9_000, message: "内存一"),
            makeRecord(sequence: 3, milliseconds: 5_000, message: "内存早"),
        ]

        let first = PILogRecordMerge.merge(stored: stored, recent: recent, limit: 50)
        let second = PILogRecordMerge.merge(stored: stored, recent: recent, limit: 50)

        XCTAssertEqual(first, second, "同一输入重复合并必须逐条相等（每秒刷新不抖动）")
        XCTAssertEqual(
            first.map(\.message),
            ["内存早", "磁盘", "内存一"],
            "同一毫秒内保持输入顺序：磁盘快照在前、内存记录在后"
        )
        XCTAssertEqual(Set(first.map(\.id)).count, 3)
    }

    // MARK: - 私有工具

    /// 在固定行调用 `PILog.warn`，返回该 warn 调用所在行号，供来源断言。
    private func emitWarningForSourceTest(_ message: String) -> Int {
        let expectedLine = #line + 1
        PILog.warn("SourceTest", message)
        return expectedLine
    }

    /// 构造合并测试用记录：毫秒时间戳直接换算，不依赖运行机器时区。
    private func makeRecord(
        sequence: UInt64,
        milliseconds: Int64,
        level: PILogLevel = .info,
        category: String = "Merge",
        message: String,
        source: PILogSource? = nil
    ) -> PILogRecord {
        PILogRecord(
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
            level: level,
            category: category,
            message: message,
            source: source
        )
    }

    /// 读取 JSONL 文件并逐行解析为 JSON 对象；空行/坏行不计入。
    private func storedJSONLines(in url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var objects: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                objects.append(object)
            }
        }
        return objects
    }

    /// 从导出文本的 `---` 之后提取 `msg-XXXX` 序号，保持文件顺序。
    private func rotatedMessageNumbers(in export: String) -> [Int] {
        let lines = export.components(separatedBy: "\n")
        guard let separatorIndex = lines.firstIndex(of: "---") else { return [] }
        return lines[(separatorIndex + 1)...].compactMap { line in
            guard let value = line.components(separatedBy: " ").last,
                  value.hasPrefix("msg-")
            else { return nil }
            return Int(value.dropFirst(4))
        }
    }
}

// MARK: - 测试桩

/// 在有限的连续写盘 pass 中各追加一条日志，确定性覆盖 export 的 drain 上限。
private final class ConcurrentExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumPasses: Int
    private var passes = 0

    init(maximumPasses: Int) {
        self.maximumPasses = maximumPasses
    }

    func nextMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard passes < maximumPasses else { return nil }
        passes += 1
        return "concurrent-\(passes)"
    }

    var observedPasses: Int {
        lock.lock()
        defer { lock.unlock() }
        return passes
    }
}

/// 持续在写盘回调中生产日志；停止后放行旧实现，避免 RED 留下失控后台循环。
private final class ContinuousExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var count = 0
    private var text = ""

    func nextMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        count += 1
        return "continuous-\(count)"
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func store(_ export: String) {
        lock.lock()
        text = export
        lock.unlock()
    }

    var messageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var exportedText: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

/// 线程安全的写盘观察记录器：回调发生在写盘线程，由测试线程读取断言。
private final class WriteObserverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var lines: [String] = []
    private var wroteOnMainThread = false

    func record(_ newLines: [String]) {
        lock.lock()
        lines.append(contentsOf: newLines)
        if Thread.isMainThread {
            wroteOnMainThread = true
        }
        lock.unlock()
        semaphore.signal()
    }

    /// 等待至少一次写盘回调；返回是否在超时前收到。
    func waitForWrite(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    var capturedLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var observedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wroteOnMainThread
    }
}
