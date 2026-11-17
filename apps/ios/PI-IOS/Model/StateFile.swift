import Foundation

/// 本机状态文件的读写。
///
/// 位置：`Application Support/PIiOS/state-v1.json`
/// 保护等级：写入使用 `.completeFileProtection`（锁屏后不可读）。
/// 不含凭证：密码 / 私钥 / API Key 都不写入本文件。
enum StateFile {
    static let directoryName = "PIiOS"
    static let fileName = "state-v1.json"

    /// All reads and writes share one serial sequence. Explicit synchronous saves
    /// bridge through this queue, while hot-path saves use `saveAsync` and never
    /// block the main actor on disk IO.
    private static let ioQueue = DispatchQueue(
        label: "dev.piios.state-file",
        qos: .utility
    )
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queueKeySetup: Void = {
        ioQueue.setSpecific(key: queueKey, value: 1)
    }()
    private static let resultLock = NSLock()
    private static var latestWriteError: String?

    struct LoadOutcome {
        var state: PersistedState
        /// 读取异常时给界面显示的原因（成功或文件不存在时为 nil）。
        var warning: String?
        /// 原文件未能安全备份时，禁止以空状态覆盖它。
        var canSave: Bool = true
    }

    enum BarrierResult: Sendable {
        case committed
        case failed(String)
    }

    enum StateFileError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "无法定位 Application Support 目录"
            }
        }
    }

    static func directoryURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StateFileError.applicationSupportUnavailable
        }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL() throws -> URL {
        try directoryURL().appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> LoadOutcome {
        return performSync {
            let url: URL
            do {
                url = try fileURL()
            } catch {
                return LoadOutcome(state: .empty, warning: "读取本机设置失败：\(error.localizedDescription)", canSave: false)
            }
            return loadUnlocked(from: url)
        }
    }

    static func load(from url: URL) -> LoadOutcome {
        return performSync { loadUnlocked(from: url) }
    }

    private static func loadUnlocked(from url: URL) -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return LoadOutcome(state: .empty, warning: nil)
            }
            return LoadOutcome(state: .empty, warning: "读取本机设置失败：\(error.localizedDescription)。原文件已保留，请重启应用重试。", canSave: false)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            guard state.version <= PersistedState.supportedVersion else {
                // 未来版本的 schema：当前代码只认识一部分字段，继续读写会丢数据。
                // 禁止保存（canSave=false），并明确提示用户升级 App。
                return LoadOutcome(
                    state: .empty,
                    warning: "本机状态文件来自更高版本的 App（schema v\(state.version)），当前版本只支持 v\(PersistedState.supportedVersion)。为避免丢失数据，已停止写入；请升级 App 后重试。",
                    canSave: false
                )
            }
            return LoadOutcome(state: state, warning: nil)
        } catch {
            // 解析失败不直接覆盖：先把原文件改名备份，再以空数据启动，并如实告知备份文件名。
            let backupName = renameToCorruptBackup(url: url)
            let backupText = backupName.map { "已备份为 \($0)" } ?? "备份失败，原文件保留在原处"
            let warning = "本机状态文件无法解析（\(error.localizedDescription)）。\(backupText)，当前以空数据启动。"
            return LoadOutcome(state: .empty, warning: warning, canSave: backupName != nil)
        }
    }

    static func save(_ state: PersistedState) throws {
        try performSync {
            do {
                try writeUnlocked(state, to: try fileURL())
                recordWriteResult(nil)
            } catch {
                recordWriteResult(error)
                throw error
            }
        }
    }

    static func save(_ state: PersistedState, to url: URL) throws {
        try performSync {
            do {
                try writeUnlocked(state, to: url)
                recordWriteResult(nil)
            } catch {
                recordWriteResult(error)
                throw error
            }
        }
    }

    /// Async save for debounced/hot-path callers. Enqueueing happens before the
    /// first suspension point, so callers observe the same order as invocation.
    static func saveAsync(_ state: PersistedState, to url: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { continuation in
            _ = queueKeySetup
            ioQueue.async {
                do {
                    let target: URL
                    if let url {
                        target = url
                    } else {
                        target = try fileURL()
                    }
                    try writeUnlocked(state, to: target)
                    recordWriteResult(nil)
                    continuation.resume()
                } catch {
                    recordWriteResult(error)
                    continuation.resume(throwing: error)
                }
            }
#if DEBUG
            invokeWriteObserver(.enqueued, url: url)
#endif
        }
    }

    /// Barrier for callers that need previously accepted async writes to finish
    /// even when they did not await each individual save.
    static func waitForPendingWrites() async {
        _ = await waitForPendingWritesResult()
    }

    /// Latest full-snapshot result up to this barrier. A successful write after a
    /// failure recovers the result; a newer accepted failure before the barrier
    /// cannot be hidden by an earlier successful write.
    static func waitForPendingWritesResult() async -> BarrierResult {
        await withCheckedContinuation { continuation in
            _ = queueKeySetup
            ioQueue.async {
                resultLock.lock()
                let error = latestWriteError
                resultLock.unlock()
                if let error {
                    continuation.resume(returning: .failed(error))
                } else {
                    continuation.resume(returning: .committed)
                }
            }
        }
    }

    private static func writeUnlocked(_ state: PersistedState, to url: URL) throws {
#if DEBUG
        invokeWriteObserver(.began, url: url)
        defer { invokeWriteObserver(.finished, url: url) }
#endif
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try invokeBeforeWriteHook(url)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func recordWriteResult(_ error: Error?) {
        resultLock.lock()
        latestWriteError = error?.localizedDescription
        resultLock.unlock()
    }

#if DEBUG
    private static let hookLock = NSLock()
    private static var beforeWriteHook: (@Sendable (URL) throws -> Void)?
    enum WriteStage: Sendable { case enqueued, began, finished }
    private static var writeObserver: (@Sendable (WriteStage, URL?) -> Void)?

    static func setWriteObserverForTesting(_ observer: (@Sendable (WriteStage, URL?) -> Void)?) {
        hookLock.lock(); writeObserver = observer; hookLock.unlock()
    }

    private static func invokeWriteObserver(_ stage: WriteStage, url: URL?) {
        hookLock.lock(); let observer = writeObserver; hookLock.unlock()
        observer?(stage, url)
    }

    static func setBeforeWriteHookForTesting(
        _ hook: (@Sendable (URL) throws -> Void)?
    ) {
        hookLock.lock()
        beforeWriteHook = hook
        hookLock.unlock()
    }

    private static func invokeBeforeWriteHook(_ url: URL) throws {
        hookLock.lock()
        let hook = beforeWriteHook
        hookLock.unlock()
        try hook?(url)
    }
#else
    private static func invokeBeforeWriteHook(_ url: URL) throws {}
#endif

    private static func performSync<T>(_ body: () throws -> T) rethrows -> T {
        _ = queueKeySetup
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try ioQueue.sync(execute: body)
    }

    private static func renameToCorruptBackup(url: URL) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("state-v1.corrupt-\(stamp).json", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup.lastPathComponent
        } catch {
            return nil
        }
    }
}
