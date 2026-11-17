import Foundation
import XCTest
@testable import PIiOSCore

final class PILogBuildIdentityTests: XCTestCase {
    func testSameVersionExportsCanIdentifyDifferentBinaries() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = PILogger(directoryURL: directory)
        var metadata = PILogExportMetadata(appVersion: "0.0.4", buildNumber: "11",
            systemVersion: "27", deviceModel: "test", configuration: .default,
            generatedAt: Date(timeIntervalSince1970: 0), buildIdentity: "binary-one")
        let first = logger.exportText(metadata: metadata)
        metadata.buildIdentity = "binary-two"
        let second = logger.exportText(metadata: metadata)
        XCTAssertTrue(first.contains("构建标识：binary-one"))
        XCTAssertTrue(second.contains("构建标识：binary-two"))
        metadata.buildIdentity = nil
        XCTAssertFalse(logger.exportText(metadata: metadata).contains("构建标识："))
    }
}
