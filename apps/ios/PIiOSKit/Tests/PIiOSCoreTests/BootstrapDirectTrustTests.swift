import Foundation
import XCTest
@testable import PIiOSCore

final class BootstrapDirectTrustTests: XCTestCase {
    func testValidTrustMetadataParsesStrictly() throws {
        let trust = try BootstrapDirectTrust.parse(
            data: Data(validJSON.utf8),
            expectedAttemptId: "boot_test"
        )
        XCTAssertEqual(trust.schemaVersion, 1)
        XCTAssertEqual(trust.hostId, "host_uuid")
        XCTAssertEqual(trust.certificateSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(trust.attemptId, "boot_test")
        XCTAssertLessThan(trust.notBefore, trust.notAfter)
    }

    func testWrongAttemptPinShapeExtraFieldOversizeAndInvalidUTF8AreRejected() throws {
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data(validJSON.utf8), expectedAttemptId: "older_attempt"
        ))
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data(validJSON.replacingOccurrences(
                of: String(repeating: "a", count: 64),
                with: "ABC"
            ).utf8),
            expectedAttemptId: "boot_test"
        ))
        let extra = validJSON.replacingOccurrences(
            of: "\"schemaVersion\":1,",
            with: "\"schemaVersion\":1,\"endpoint\":\"wss://untrusted\","
        )
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data(extra.utf8), expectedAttemptId: "boot_test"
        ))
        let booleanSchema = validJSON.replacingOccurrences(
            of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"
        )
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data(booleanSchema.utf8), expectedAttemptId: "boot_test"
        ))
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data(repeating: 0x20, count: 4097), expectedAttemptId: "boot_test"
        ))
        XCTAssertThrowsError(try BootstrapDirectTrust.parse(
            data: Data([0xFF]), expectedAttemptId: "boot_test"
        ))
    }

    func testReadCommandChecksOwnerRegularFilePermissionsAndSizeAndClearIsAttemptScoped() {
        let read = BootstrapRemoteCommand.readDirectTrust(attemptId: "boot_test")
        XCTAssertTrue(read.contains("direct-trust.json"))
        XCTAssertTrue(read.contains("stat -c %u"))
        XCTAssertTrue(read.contains("stat -c %a"))
        XCTAssertTrue(read.contains("stat -c %s"))
        XCTAssertTrue(read.contains("4096"))
        XCTAssertTrue(read.contains("[ ! -L"))
        let clear = BootstrapRemoteCommand.clearDirectTrust(attemptId: "boot_test")
        XCTAssertTrue(clear.contains("direct-trust.json"))
        XCTAssertTrue(clear.contains("boot_test"))
        XCTAssertTrue(clear.contains("rm -f"))
    }

    private let validJSON = """
    {"schemaVersion":1,"attemptId":"boot_test","hostId":"host_uuid","certificateSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","notBefore":"2026-11-05T00:00:00Z","notAfter":"2028-02-08T00:00:00Z"}
    """
}
