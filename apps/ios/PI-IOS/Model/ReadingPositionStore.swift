import Foundation
import PIiOSCore

/// Lightweight persistence for per-session reading scroll positions.
/// Stored separately from `state-v1.json` so frequent scroll position saves
/// do not rewrite the full host/project/provider configuration file.
enum ReadingPositionStore {
    private static let ioQueue = DispatchQueue(label: "dev.piios.reading-positions-io", qos: .utility)

    static var defaultFileURL: URL? {
        guard let stateURL = try? StateFile.fileURL() else { return nil }
        return stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("reading-positions-v1.json", isDirectory: false)
    }

    static func load(from url: URL? = defaultFileURL) -> [String: [String: ConversationReadingPosition]]? {
        ioQueue.sync { loadUnlocked(from: url) }
    }

    private static func loadUnlocked(from url: URL?) -> [String: [String: ConversationReadingPosition]]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: [String: ConversationReadingPosition]].self, from: data)
    }

    @discardableResult
    static func save(
        _ positions: [String: [String: ConversationReadingPosition]],
        to url: URL? = defaultFileURL
    ) -> Bool {
        ioQueue.sync { saveUnlocked(positions, to: url) }
    }

    static func enqueueSave(
        _ positions: [String: [String: ConversationReadingPosition]],
        to url: URL? = defaultFileURL
    ) {
        ioQueue.async {
            _ = saveUnlocked(positions, to: url)
        }
    }

    static func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume()
            }
        }
    }

    static func saveAsync(
        _ positions: [String: [String: ConversationReadingPosition]],
        to url: URL? = defaultFileURL
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: saveUnlocked(positions, to: url))
            }
        }
    }

    private static func saveUnlocked(
        _ positions: [String: [String: ConversationReadingPosition]],
        to url: URL?
    ) -> Bool {
        guard let url else { return false }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(positions)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            PILog.warn("StateFile", "阅读位置保存失败：\(error.localizedDescription)")
            return false
        }
    }
}
