import Foundation

// MARK: - 等级

/// 日志等级。用户可配置的只有这三档（需求原文：info / warn / debug）。
public enum PILogLevel: String, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case debug
    case info
    case warn

    public var id: String { rawValue }

    /// 数值越大越重要；过滤规则：记录等级 < 配置等级时丢弃。
    public var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        }
    }

    /// 写入导出文件 / 列表的固定标签，便于 grep。
    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        }
    }

    /// 设置页显示名。
    public var title: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .warn: return "警告"
        }
    }

    /// 设置页一行解释：说清「会多什么 / 会少什么」，不写「推荐」。
    public var detail: String {
        switch self {
        case .debug: return "记录全部日志，信息最全"
        case .info: return "记录关键状态与警告（默认）"
        case .warn: return "只记录警告与主线程卡顿"
        }
    }

    public static func < (lhs: PILogLevel, rhs: PILogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - 时间格式

/// 时间显示格式。只影响渲染，不影响磁盘上的记录（磁盘统一存毫秒时间戳）。
public enum PILogTimeFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case dateTime = "date_time"
    case iso8601
    case timeOnly = "time_only"
    case epochMillis = "epoch_millis"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dateTime: return "完整时间"
        case .iso8601: return "ISO 8601"
        case .timeOnly: return "仅时间"
        case .epochMillis: return "毫秒时间戳"
        }
    }
}

// MARK: - 配置

/// 可在设置页调整的日志配置，随 `state-v1.json` 持久化。
public struct PILogConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var level: PILogLevel
    public var timeFormat: PILogTimeFormat

    public static let `default` = PILogConfiguration(
        isEnabled: true,
        level: .info,
        timeFormat: .dateTime
    )

    public init(
        isEnabled: Bool = true,
        level: PILogLevel = .info,
        timeFormat: PILogTimeFormat = .dateTime
    ) {
        self.isEnabled = isEnabled
        self.level = level
        self.timeFormat = timeFormat
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case level
        case timeFormat
    }

    /// 容错解码：缺字段 / 未知枚举 / 类型不符都回落到默认值，旧状态文件不会读取失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PILogConfiguration.default
        if let enabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled) {
            isEnabled = enabled
        } else {
            isEnabled = fallback.isEnabled
        }
        if let rawLevel = try? container.decodeIfPresent(String.self, forKey: .level),
           let level = PILogLevel(rawValue: rawLevel) {
            self.level = level
        } else {
            self.level = fallback.level
        }
        if let rawFormat = try? container.decodeIfPresent(String.self, forKey: .timeFormat),
           let format = PILogTimeFormat(rawValue: rawFormat) {
            self.timeFormat = format
        } else {
            self.timeFormat = fallback.timeFormat
        }
    }
}

// MARK: - 记录来源

/// 一条日志的调用点来源，由 `PILog.warn` 通过 `#fileID` / `#function` / `#line` 默认参数捕获。
/// `file` 使用 `#fileID`（如 `PIiOSCore/ConnectionModel.swift`），不含本机绝对路径。
public struct PILogSource: Hashable, Sendable {
    public let file: String
    public let function: String
    public let line: Int

    public init(file: String, function: String, line: Int) {
        self.file = file
        self.function = function
        self.line = line
    }
}

// MARK: - 记录

/// 一条运行日志。`sequence` 为进程内单调序号，用作列表稳定 id。
public struct PILogRecord: Identifiable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: Date
    public let level: PILogLevel
    public let category: String
    public let message: String
    /// 报错来源：只有 `PILog.warn` 会捕获；info/debug 与旧磁盘日志为 nil。
    public let source: PILogSource?

    public var id: UInt64 { sequence }

    public init(
        sequence: UInt64,
        timestamp: Date,
        level: PILogLevel,
        category: String,
        message: String,
        source: PILogSource? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.source = source
    }
}

// MARK: - 记录合并

/// 日志页展示层的合并器：把「磁盘快照」与「本次运行的内存记录」合成一份旧→新的预览。
///
/// 为什么需要它：重启后磁盘里是历史、内存里只有本次运行的新记录；日志关闭后内存为空，
/// 但磁盘里的历史仍在。任何一份单独覆盖另一份，用户都会看到「记录丢失」——磁盘其实有数据。
///
/// 规则：
/// 1. 按（毫秒时间戳、等级、分类、消息、来源）去重：同一条记录落盘后同时出现在磁盘与内存时只保留一份；
/// 2. 按毫秒时间戳升序；同一毫秒保持输入顺序（磁盘快照在前、内存记录在后），保证每秒刷新顺序稳定；
/// 3. 默认保留全部；显式 `limit > 0` 时只取末尾 N 条，`limit <= 0` 返回空。
///
/// 合并结果是纯展示投影：`sequence` 由记录内容重新推导（见 `identity(for:)`）。
/// 磁盘记录的 sequence 只是读取顺序的兜底值（1..N），直接拿来做 `ForEach` 的 id
/// 会与本次运行的进程内序号撞车，出现重复 id。
public enum PILogRecordMerge {
    public static func merge(
        stored: [PILogRecord],
        recent: [PILogRecord],
        limit: Int? = nil
    ) -> [PILogRecord] {
        if let limit, limit <= 0 { return [] }

        var seen = Set<MergeKey>()
        var combined: [(key: MergeKey, record: PILogRecord)] = []
        combined.reserveCapacity(stored.count + recent.count)
        for record in stored {
            let key = MergeKey(record)
            guard seen.insert(key).inserted else { continue }
            combined.append((key, record))
        }
        for record in recent {
            let key = MergeKey(record)
            guard seen.insert(key).inserted else { continue }
            combined.append((key, record))
        }

        // `sorted` 不保证稳定：显式用原始下标决定同一毫秒内的次序，合并结果逐帧一致。
        let ordered = combined.enumerated().sorted { lhs, rhs in
            if lhs.element.key.milliseconds != rhs.element.key.milliseconds {
                return lhs.element.key.milliseconds < rhs.element.key.milliseconds
            }
            return lhs.offset < rhs.offset
        }
        return ordered.suffix(limit ?? ordered.count).map { element in
            let record = element.element.record
            return PILogRecord(
                sequence: identity(for: element.element.key),
                timestamp: record.timestamp,
                level: record.level,
                category: record.category,
                message: record.message,
                source: record.source
            )
        }
    }

    /// 去重键：毫秒时间戳 + 等级 + 分类 + 消息 + 来源。
    /// 来源必须参与：同一毫秒内不同调用点可能打出完全相同的 category/message。
    private struct MergeKey: Hashable {
        let milliseconds: Int64
        let level: PILogLevel
        let category: String
        let message: String
        let source: PILogSource?

        init(_ record: PILogRecord) {
            milliseconds = Int64((record.timestamp.timeIntervalSince1970 * 1000).rounded(.down))
            level = record.level
            category = record.category
            message = record.message
            source = record.source
        }
    }

    /// 由记录内容推导稳定 id（FNV-1a 64）。不用 `Hasher`：它的种子每个进程不同，
    /// 同一份历史在重启前后会拿到不同 id；这里只要求「同一内容 → 同一 id」，供 `ForEach` 使用。
    private static func identity(for key: MergeKey) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func appendField(_ field: String) {
            // 长度前缀按 UTF-8 字节数编码，字段里的 `|`、`:` 等不再产生歧义。
            for byte in "\(field.utf8.count):".utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
            for byte in field.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
        }
        appendField(String(key.milliseconds))
        appendField(key.level.rawValue)
        appendField(key.category)
        appendField(key.message)
        // 有无来源必须先区分，否则 nil 与 source 字段恰好为空串时 identity 会碰撞。
        appendField(key.source == nil ? "0" : "1")
        if let source = key.source {
            appendField(source.file)
            appendField(source.function)
            appendField(String(source.line))
        }
        return hash == 0 ? 1 : hash
    }
}

// MARK: - 导出元信息

/// 导出 txt 的头部信息。由 App 层提供（内核不依赖 UIKit）。
public struct PILogExportMetadata: Equatable, Sendable {
    public var appVersion: String
    public var buildNumber: String
    public var systemVersion: String
    public var deviceModel: String
    public var configuration: PILogConfiguration
    /// 导出时刻。注入以便测试可复现。
    public var generatedAt: Date
    public var buildIdentity: String?

    public init(
        appVersion: String,
        buildNumber: String,
        systemVersion: String,
        deviceModel: String,
        configuration: PILogConfiguration,
        generatedAt: Date = Date(),
        buildIdentity: String? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.configuration = configuration
        self.generatedAt = generatedAt
        self.buildIdentity = buildIdentity
    }
}

// MARK: - 格式化

/// 记录与导出共用的时间/行格式化。所有入口都走这里，避免列表与导出口径不一致。
public enum PILogFormatter {
    private static let cache = PILogFormatterCache()

    public static func timeText(
        _ date: Date,
        format: PILogTimeFormat,
        timeZone: TimeZone = .current
    ) -> String {
        switch format {
        case .epochMillis:
            return String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
        case .dateTime:
            return cache.string(from: date, pattern: "yyyy-MM-dd HH:mm:ss.SSS", timeZone: timeZone)
        case .timeOnly:
            return cache.string(from: date, pattern: "HH:mm:ss.SSS", timeZone: timeZone)
        case .iso8601:
            return cache.isoString(from: date, timeZone: timeZone)
        }
    }

    /// 固定格式：`<time> [<LEVEL>] [<category>] <message>`；
    /// warn 记录且捕获到来源时，在 category 与 message 之间插入 `[<file>:<function>:<line>]`。
    public static func line(
        _ record: PILogRecord,
        timeFormat: PILogTimeFormat,
        timeZone: TimeZone = .current
    ) -> String {
        let time = timeText(record.timestamp, format: timeFormat, timeZone: timeZone)
        let sourceText: String
        if record.level == .warn, let source = record.source {
            sourceText = " [\(source.file):\(source.function):\(source.line)]"
        } else {
            sourceText = ""
        }
        return "\(time) [\(record.level.label)] [\(record.category)]\(sourceText) \(record.message)"
    }
}

/// DateFormatter 缓存：按键复用，避免一次导出几千行时反复构造成本器。
private final class PILogFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var dateFormatters: [String: DateFormatter] = [:]
    private var isoFormatters: [String: ISO8601DateFormatter] = [:]

    func string(from date: Date, pattern: String, timeZone: TimeZone) -> String {
        let key = "\(pattern)|\(timeZone.identifier)"
        lock.lock()
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.calendar = Calendar(identifier: .gregorian)
            created.timeZone = timeZone
            created.dateFormat = pattern
            dateFormatters[key] = created
            formatter = created
        }
        lock.unlock()
        return formatter.string(from: date)
    }

    func isoString(from date: Date, timeZone: TimeZone) -> String {
        let key = timeZone.identifier
        lock.lock()
        let formatter: ISO8601DateFormatter
        if let cached = isoFormatters[key] {
            formatter = cached
        } else {
            let created = ISO8601DateFormatter()
            created.timeZone = timeZone
            created.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            isoFormatters[key] = created
            formatter = created
        }
        lock.unlock()
        return formatter.string(from: date)
    }
}

// MARK: - 卡顿判定

/// 纯函数式帧间隔判定：供主线程显示器调用，也便于单测。
/// `ingest` 返回超过阈值的实际毫秒数；未超过返回 nil。
public struct PILogFrameIntervalTracker: Sendable {
    public var thresholdMilliseconds: Double
    private var lastTimestamp: Double?

    public init(thresholdMilliseconds: Double = 150) {
        self.thresholdMilliseconds = thresholdMilliseconds
        self.lastTimestamp = nil
    }

    public mutating func ingest(timestamp: Double) -> Double? {
        guard let last = lastTimestamp else {
            lastTimestamp = timestamp
            return nil
        }
        // 时间回退时不推进基准，避免下一次正常帧被算成一次虚假的长间隔。
        guard timestamp > last else { return nil }
        lastTimestamp = timestamp
        let elapsed = (timestamp - last) * 1000
        return elapsed > thresholdMilliseconds ? elapsed : nil
    }

    public mutating func reset() {
        lastTimestamp = nil
    }
}

// MARK: - 日志内核

/// 运行日志内核：等级过滤、内存记录、JSONL 落盘与轮转、导出文本生成。
///
/// 线程约定（契约 §5）：
/// - `log()` 只做内存操作 + 向后台队列排刷，绝不在这里做磁盘 IO；
/// - 所有文件读写都在私有串行队列上执行；
/// - 写盘失败静默丢弃该批次，不让日志本身把 App 弄崩。
public final class PILogger: @unchecked Sendable {
    /// 单个日志文件上限 1MiB。
    public static let maxFileBytes = 1_048_576
    /// 最多保留 3 个文件（当前 + 2 个轮转）。
    public static let maxFileCount = 3
    /// 当前日志文件名；轮转为 `piios.1.log` / `piios.2.log`。
    public static let fileName = "piios.log"

    /// 待写批次达到该条数时立即排刷，否则最多等 `autoFlushInterval`。
    private static let immediateFlushLineCount = 64
    private static let autoFlushInterval: TimeInterval = 0.5
    private static let maxDrainPasses = 8

    public let directoryURL: URL

    private let maxFileBytes: Int
    private let maxFileCount: Int
    private let clock: @Sendable () -> Date
    private let ioQueue: DispatchQueue
    private let ioQueueKey = DispatchSpecificKey<UInt8>()

    private let stateLock = NSLock()
    private var config: PILogConfiguration
    private var sequence: UInt64 = 0
    private var recent: [PILogRecord] = []
    private var pendingLines: [String] = []
    private var flushScheduled = false
    private var writeObserver: (@Sendable ([String]) -> Void)?

    public init(
        directoryURL: URL,
        configuration: PILogConfiguration = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        maxFileBytes: Int = PILogger.maxFileBytes,
        maxFileCount: Int = PILogger.maxFileCount
    ) {
        self.directoryURL = directoryURL
        self.config = configuration
        self.clock = clock
        self.maxFileBytes = max(1, maxFileBytes)
        self.maxFileCount = max(1, maxFileCount)
        self.ioQueue = DispatchQueue(label: "dev.piios.log-io", qos: .utility)
        self.ioQueue.setSpecific(key: ioQueueKey, value: 1)
    }

    // MARK: 配置

    /// 线程安全快照。
    public var configuration: PILogConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return config
    }

    public func configure(_ configuration: PILogConfiguration) {
        stateLock.lock()
        config = configuration
        stateLock.unlock()
    }

    public func isEnabled(for level: PILogLevel) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return config.isEnabled && level.rank >= config.level.rank
    }

    // MARK: 记录

    public func log(
        level: PILogLevel,
        category: String,
        message: @autoclosure () -> String,
        source: PILogSource? = nil
    ) {
        stateLock.lock()
        guard config.isEnabled, level.rank >= config.level.rank else {
            stateLock.unlock()
            return
        }
        let timestamp = clock()
        let text = Self.normalizedMessage(message())
        sequence &+= 1
        let record = PILogRecord(
            sequence: sequence,
            timestamp: timestamp,
            level: level,
            category: category,
            message: text,
            source: source
        )
        recent.append(record)
        pendingLines.append(Self.encodeLine(record))

        let shouldFlushNow = pendingLines.count >= Self.immediateFlushLineCount
        var needsScheduledFlush = false
        if shouldFlushNow {
            flushScheduled = true
        } else if !flushScheduled {
            flushScheduled = true
            needsScheduledFlush = true
        }
        stateLock.unlock()

        if shouldFlushNow {
            ioQueue.async { [weak self] in self?.drainPending() }
        } else if needsScheduledFlush {
            ioQueue.asyncAfter(deadline: .now() + Self.autoFlushInterval) { [weak self] in
                self?.drainPending()
            }
        }
    }

    /// 立即返回，只把「尽快落盘」排到后台队列。
    public func flush() {
        ioQueue.async { [weak self] in self?.drainPending() }
    }

    /// 等当前待写批次写完；即使从主线程调用，写盘也只在后台串行队列执行（AC-L10）。
    public func flushSync() {
        runOnIOQueue {
            self.drainPending()
        }
    }

    public func recentRecords(limit: Int? = nil) -> [PILogRecord] {
        if let limit, limit <= 0 { return [] }
        stateLock.lock()
        defer { stateLock.unlock() }
        if let limit, recent.count > limit {
            return Array(recent.suffix(limit))
        }
        return recent
    }

    // MARK: 存储查询 / 清理

    /// 已落盘记录（旧→新），默认读取全部；显式 limit 可用于局部投影。不读内存缓冲。
    public func storedRecords(limit: Int? = nil) -> [PILogRecord] {
        if let limit, limit <= 0 { return [] }
        return runOnIOQueue {
            let records = self.readStoredRecords()
            if let limit, records.count > limit {
                return Array(records.suffix(limit))
            }
            return records
        }
    }

    public func storedRecordCount() -> Int {
        runOnIOQueue { self.readStoredLines().count }
    }

    public func storedFileCount() -> Int {
        runOnIOQueue {
            self.allFileURLs().filter { FileManager.default.fileExists(atPath: $0.path) }.count
        }
    }

    public func storedByteCount() -> Int {
        runOnIOQueue {
            self.allFileURLs().reduce(into: 0) { total, url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                total += size
            }
        }
    }

    public func clear() {
        runOnIOQueue {
            self.stateLock.lock()
            self.pendingLines.removeAll(keepingCapacity: false)
            self.recent.removeAll(keepingCapacity: false)
            self.flushScheduled = false
            // sequence 不归零：契约要求进程内单调唯一，ForEach 的 id 依赖它。
            self.stateLock.unlock()
            let fileManager = FileManager.default
            for url in self.allFileURLs() {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: 导出

    /// 导出 txt 全文。调用方负责放到后台线程（可能读取 MB 级文件）。
    /// `timeZone` 仅供测试注入；App 使用当前时区。
    public func exportText(
        metadata: PILogExportMetadata,
        timeZone: TimeZone = .current
    ) -> String {
        runOnIOQueue {
            // 有界一致快照：只写导出开始时的 pending 批次；回调期间的新记录留待下批。
            self.stateLock.lock()
            let lines = self.pendingLines
            self.pendingLines.removeAll(keepingCapacity: true)
            self.flushScheduled = false
            let observer = self.writeObserver
            self.stateLock.unlock()

            if !lines.isEmpty {
                do {
                    try self.appendLines(lines)
                } catch {
                    // 与普通 drain 一致：写盘失败静默丢弃该批次，observer 仍收到通知。
                }
                observer?(lines)
            }
            let records = self.readStoredRecords()
            return self.renderExport(metadata: metadata, records: records, timeZone: timeZone)
        }
    }

    // MARK: 测试桩

    /// 记录每次实际写盘的行（在写盘所在线程回调）。用于验证「IO 不在主线程」。
    public func setWriteObserverForTesting(_ observer: (@Sendable ([String]) -> Void)?) {
        stateLock.lock()
        writeObserver = observer
        stateLock.unlock()
    }

    // MARK: - 内部：串行队列执行

    /// 在专用串行队列上同步执行并等待。若调用方已经在该队列上，直接执行，
    /// 避免死锁。用 async + 信号量而不是 `sync`：`sync` 在队列空闲时会在调用线程
    /// 上执行代码块，主线程调用时磁盘 IO 就落回主线程，违反 AC-L10。
    private func runOnIOQueue<T>(_ body: @escaping @Sendable () -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            return body()
        }
        let box = IOQueueResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        ioQueue.async {
            box.store(body())
            semaphore.signal()
        }
        semaphore.wait()
        return box.load()
    }

    // MARK: - 内部：内存 → 磁盘

    private func drainPending() {
        for _ in 0..<Self.maxDrainPasses {
            stateLock.lock()
            let lines = pendingLines
            pendingLines.removeAll(keepingCapacity: true)
            flushScheduled = false
            let observer = writeObserver
            stateLock.unlock()

            guard !lines.isEmpty else { return }
            do {
                try appendLines(lines)
            } catch {
                // 写盘失败静默丢弃：日志系统不能因为磁盘问题拖垮 App。
            }
            observer?(lines)
        }
        // 连续写仍追不上时，确保后续批次还会被排刷。
        stateLock.lock()
        let hasPending = !pendingLines.isEmpty
        if hasPending, !flushScheduled {
            flushScheduled = true
            stateLock.unlock()
            ioQueue.asyncAfter(deadline: .now() + Self.autoFlushInterval) { [weak self] in
                self?.drainPending()
            }
            return
        }
        stateLock.unlock()
    }

    private func appendLines(_ lines: [String]) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let currentURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)

        // Write line-by-line in bounded chunks. A single batch larger than the
        // file budget is rotated through multiple files instead of overflowing
        // the nominal 1 MiB cap.
        var chunk = Data()
        func flushChunk() throws {
            guard !chunk.isEmpty else { return }
            let currentSize = fileSize(at: currentURL)
            if currentSize > 0, currentSize + chunk.count > maxFileBytes {
                try rotateFiles()
            }
            if !fileManager.fileExists(atPath: currentURL.path) {
                fileManager.createFile(atPath: currentURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let startOffset = try handle.offset()
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                try? handle.truncate(atOffset: startOffset)
                throw error
            }
            chunk.removeAll(keepingCapacity: true)
        }
        chunk.reserveCapacity(min(maxFileBytes, lines.count * 96))
        for line in lines {
            chunk.append(Data((line + "\n").utf8))
            if chunk.count >= maxFileBytes / 2 {
                try flushChunk()
            }
        }
        try flushChunk()
    }

    private func rotateFiles() throws {
        let fileManager = FileManager.default
        guard maxFileCount > 1 else {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(Self.fileName))
            return
        }
        let rotated = (1...(maxFileCount - 1)).map {
            directoryURL.appendingPathComponent("piios.\($0).log", isDirectory: false)
        }
        // 删最旧
        if let oldest = rotated.last, fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        // 从新到旧后移：.1 -> .2，当前 -> .1
        for index in stride(from: rotated.count - 1, through: 1, by: -1) {
            let source = rotated[index - 1]
            let target = rotated[index]
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: source, to: target)
        }
        let current = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
        if fileManager.fileExists(atPath: current.path) {
            try fileManager.moveItem(at: current, to: rotated[0])
        }
    }

    private func allFileURLs() -> [URL] {
        var urls: [URL] = []
        if maxFileCount > 1 {
            for index in stride(from: maxFileCount - 1, through: 1, by: -1) {
                urls.append(directoryURL.appendingPathComponent("piios.\(index).log", isDirectory: false))
            }
        }
        urls.append(directoryURL.appendingPathComponent(Self.fileName, isDirectory: false))
        return urls
    }

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    private func readStoredRecords() -> [PILogRecord] {
        var records: [PILogRecord] = []
        for url in allFileURLs() {
            // 用 Data + String(decoding:)：崩溃/断电可能截断中文多字节，
            // 非法字节替换为 U+FFFD 后只让该行解码失败，不能整份文件跳过。
            guard let data = try? Data(contentsOf: url) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let record = Self.decodeLine(String(rawLine), fallbackSequence: records.count + 1) else {
                    continue
                }
                records.append(record)
            }
        }
        return records
    }

    private func readStoredLines() -> [String] {
        var lines: [String] = []
        for url in allFileURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
                if Self.decodeLine(String(rawLine), fallbackSequence: lines.count + 1) != nil {
                    lines.append(String(rawLine))
                }
            }
        }
        return lines
    }

    private func renderExport(
        metadata: PILogExportMetadata,
        records: [PILogRecord],
        timeZone: TimeZone
    ) -> String {
        let format = metadata.configuration.timeFormat
        var lines: [String] = []
        lines.append("PI-IOS 运行日志")
        lines.append("导出时间：\(PILogFormatter.timeText(metadata.generatedAt, format: format, timeZone: timeZone))")
        lines.append("应用版本：\(metadata.appVersion) (\(metadata.buildNumber))")
        if let buildIdentity = metadata.buildIdentity { lines.append("构建标识：\(buildIdentity)") }
        lines.append("系统版本：\(metadata.systemVersion)")
        lines.append("设备：\(metadata.deviceModel)")
        lines.append("日志等级：\(metadata.configuration.level.label)")
        lines.append("时间格式：\(format.title)")
        lines.append("记录条数：\(records.count)")
        lines.append("---")
        if records.isEmpty {
            lines.append("（暂无日志）")
        } else {
            for record in records {
                lines.append(PILogFormatter.line(record, timeFormat: format, timeZone: timeZone))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 内部：JSONL 编解码

    private struct StoredLine: Codable {
        let t: Int64
        let l: String
        let c: String
        let m: String
        /// 可选调用点来源。旧日志没有这三个字段，解码时缺省 nil；nil 时编码省略，保持旧行格式不变。
        let f: String?
        let fn: String?
        let ln: Int?
    }

    /// 消息在进入 recent/pending 前统一截断，保证内存、磁盘、merge 与导出使用同一内容。
    private static let maxStoredMessageBytes = 64 * 1024
    private static let truncationMarker = "…（日志过长已截断）"

    private static func normalizedMessage(_ message: String) -> String {
        guard message.utf8.count > maxStoredMessageBytes else { return message }
        var truncated = ""
        truncated.reserveCapacity(maxStoredMessageBytes + truncationMarker.utf8.count)
        for character in message {
            if truncated.utf8.count + String(character).utf8.count > maxStoredMessageBytes {
                break
            }
            truncated.append(character)
        }
        return truncated + truncationMarker
    }

    private static func encodeLine(_ record: PILogRecord) -> String {
        let stored = StoredLine(
            t: Int64((record.timestamp.timeIntervalSince1970 * 1000).rounded(.down)),
            l: record.level.rawValue,
            c: record.category,
            m: record.message,
            f: record.source?.file,
            fn: record.source?.function,
            ln: record.source?.line
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stored)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeLine(_ line: String, fallbackSequence: Int) -> PILogRecord? {
        guard let data = line.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredLine.self, from: data),
              let level = PILogLevel(rawValue: stored.l)
        else { return nil }
        // 三个字段必须齐全才算有效来源；旧日志缺字段或半截字段一律降级为 nil，不影响整行读取。
        let source: PILogSource?
        if let file = stored.f, let function = stored.fn, let line = stored.ln {
            source = PILogSource(file: file, function: function, line: line)
        } else {
            source = nil
        }
        return PILogRecord(
            sequence: UInt64(max(1, fallbackSequence)),
            timestamp: Date(timeIntervalSince1970: Double(stored.t) / 1000),
            level: level,
            category: stored.c,
            message: stored.m,
            source: source
        )
    }
}

private final class IOQueueResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Never>?

    func store(_ value: T) {
        lock.lock()
        result = .success(value)
        lock.unlock()
    }

    func load() -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let result else { fatalError("IOQueueResultBox 未写入结果") }
        switch result {
        case .success(let value): return value
        }
    }
}

// MARK: - 全局入口

/// 全局日志入口：埋点只调这三行，不持有实例。
public enum PILog {
    public static let shared = PILogger(directoryURL: defaultDirectoryURL())

    /// 测试专用：注入临时目录 logger，避免单测写入真实 Application Support。
    /// 生产代码不设置；仅 `@testable import PIiOSCore` 的测试可见。
    static var sharedLoggerForTesting: PILogger?

    private static var activeLogger: PILogger { sharedLoggerForTesting ?? shared }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard activeLogger.isEnabled(for: .debug) else { return }
        activeLogger.log(level: .debug, category: category, message: message())
    }

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        guard activeLogger.isEnabled(for: .info) else { return }
        activeLogger.log(level: .info, category: category, message: message())
    }

    /// 警告级日志会自动捕获调用点：`#fileID`（不含绝对路径）、`#function`、`#line`，
    /// 便于用户导出日志后直接定位报错代码。info/debug 不捕获来源。
    public static func warn(
        _ category: String,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard activeLogger.isEnabled(for: .warn) else { return }
        activeLogger.log(
            level: .warn,
            category: category,
            message: message(),
            source: PILogSource(file: file, function: function, line: line)
        )
    }

    /// `Application Support/PIiOS/logs`（与 state-v1.json 同父目录）。
    public static func defaultDirectoryURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("PIiOS", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }
}
