import Foundation
import XCTest

@testable import PIiOSCore

final class OfflineSessionCacheCipherTests: XCTestCase {
    func testRoundTripsTextIncludingLegacyPlaintext() throws {
        let secret = "构建日志里有敏感路径 /Users/me/secret"
        let sealed = try OfflineCacheCipher.seal(secret)
        XCTAssertTrue(sealed.hasPrefix("enc:v1:"))
        XCTAssertEqual(OfflineCacheCipher.open(sealed), secret)

        // 没有前缀的旧行必须按明文读回，保证旧缓存升级后仍可读。
        XCTAssertEqual(OfflineCacheCipher.open("legacy plaintext"), "legacy plaintext")

        XCTAssertNotEqual(sealed, secret)
    }

    func testOptionalHelpersPreserveNil() throws {
        XCTAssertNil(try OfflineCacheCipher.seal(optional: nil))
        XCTAssertNil(OfflineCacheCipher.open(optional: nil))
        XCTAssertEqual(OfflineCacheCipher.open(optional: try OfflineCacheCipher.seal(optional: "t")), "t")
    }

    func testEncryptionFailureRollsBackAndCanRetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var keyUnavailable = false
        let database = try OfflineSessionCacheSQLite(url: url) { text in
            if keyUnavailable { return try OfflineCacheCipher.seal(text, key: nil) }
            return try OfflineCacheCipher.seal(text)
        }
        let host = UUID()
        let original = OfflineSessionCacheSnapshot(drafts: [
            .init(hostID: host, sessionId: "session", text: "saved", idempotencyKey: "old", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        try database.save(original)
        var changed = original
        changed.drafts[0].text = "sensitive replacement"
        keyUnavailable = true
        XCTAssertThrowsError(try database.saveChanges(from: original, to: changed)) {
            XCTAssertEqual($0 as? OfflineCacheEncryptionError, .unavailable)
        }
        XCTAssertEqual(try database.loadSnapshot(), original)
        keyUnavailable = false
        _ = try database.saveChanges(from: original, to: changed)
        XCTAssertEqual(try database.loadSnapshot(), changed)
    }

    func testUnreadableCiphertextDoesNotLeakAsMessage() {
        // 结构像密文但无法解开：不得把密文当正文暴露出来。
        XCTAssertEqual(OfflineCacheCipher.open("enc:v1:not-valid-base64!!"), "")
        XCTAssertNil(OfflineCacheCipher.openOrNil("enc:v1:not-valid-base64!!"))
        XCTAssertEqual(OfflineCacheCipher.openOrNil("legacy plaintext"), "legacy plaintext")
    }
}
