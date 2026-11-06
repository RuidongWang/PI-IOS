import XCTest
import PIiOSNet

@testable import PI_IOS

/// U17：有设备令牌时提供「用新一次性令牌重新配对」；失败被拒绝时把入口置顶；
/// 撤销语义保持不变（策略只读连接状态，不碰凭证）。
final class PairingEntryPolicyTests: XCTestCase {
    func testTokenHolderWithoutAuthFailureGetsRepairEntryButNotPromoted() {
        let policy = PairingEntryPolicy(hasDeviceToken: true, isPaired: true, authFailure: .none)
        XCTAssertTrue(policy.showsRepairEntry)
        XCTAssertFalse(policy.isRepairPromoted)
        XCTAssertEqual(policy.repairActionTitle, "使用新的一次性令牌重新配对")
        XCTAssertTrue(policy.repairExplanation.contains("重新配对"))
        XCTAssertFalse(policy.settingsRepairTitle.contains("失效"))
        XCTAssertFalse(policy.shouldShowSettingsRepairRow)
    }

    func testUnauthorizedWithTokenPromotesRepair() {
        let policy = PairingEntryPolicy(
            hasDeviceToken: true,
            isPaired: true,
            authFailure: .tokenUnauthorized
        )
        XCTAssertTrue(policy.showsRepairEntry)
        XCTAssertTrue(policy.isRepairPromoted)
        XCTAssertTrue(policy.repairTitle.contains("令牌已失效"))
        XCTAssertTrue(policy.repairExplanation.contains("旧设备令牌不会被覆盖"))
        XCTAssertTrue(policy.repairExplanation.contains("撤销"))
        XCTAssertTrue(policy.shouldShowSettingsRepairRow)
        XCTAssertTrue(policy.settingsRepairTitle.contains("失效"))
    }

    func testDeviceRevokedWithTokenPromotesRepairWithDistinctTitle() {
        let policy = PairingEntryPolicy(
            hasDeviceToken: true,
            isPaired: true,
            authFailure: .deviceRevoked
        )
        XCTAssertTrue(policy.isRepairPromoted)
        XCTAssertTrue(policy.repairTitle.contains("撤销"))
        XCTAssertTrue(policy.repairExplanation.contains("服务器侧撤销"))
        XCTAssertTrue(policy.shouldShowSettingsRepairRow)
    }

    func testWithoutDeviceTokenThereIsNoRepairEntry() {
        let policy = PairingEntryPolicy(hasDeviceToken: false, isPaired: false, authFailure: .none)
        XCTAssertFalse(policy.showsRepairEntry)
        XCTAssertFalse(policy.isRepairPromoted)
        // 未配对时设置页仍给出配对入口；这是原有行为。
        XCTAssertTrue(policy.shouldShowSettingsRepairRow)
    }

    func testUnauthorizedWithoutTokenIsNotPromoted() {
        let policy = PairingEntryPolicy(
            hasDeviceToken: false,
            isPaired: false,
            authFailure: .tokenUnauthorized
        )
        XCTAssertFalse(policy.isRepairPromoted)
        XCTAssertFalse(policy.showsRepairEntry)
    }

    // MARK: - 失败分类（只读 ConnectionStatus）

    func testDefaultStatusHasNoAuthFailure() {
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: ConnectionStatus()), .none)
    }

    func testDirectUnauthorizedIsTokenFailure() {
        var status = ConnectionStatus()
        status.directFailure = RouteFailure(
            route: .direct,
            phase: .authenticating(.direct),
            category: .authentication
        )
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: status), .tokenUnauthorized)
    }

    func testDirectDeviceRevokedWins() {
        var status = ConnectionStatus()
        status.directFailure = RouteFailure(
            route: .direct,
            phase: .online(.direct),
            category: .deviceRevoked
        )
        status.sshFailure = RouteFailure(
            route: .ssh,
            phase: .verifyingIdentity(.ssh),
            category: .authentication
        )
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: status), .deviceRevoked)
    }

    func testSSHAuthenticationStageFailureIsCredentialProblemNotToken() {
        var status = ConnectionStatus()
        status.sshFailure = RouteFailure(
            route: .ssh,
            phase: .authenticating(.ssh),
            category: .authentication
        )
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: status), .none)
    }

    func testSSHIdentityStageUnauthorizedIsTokenFailure() {
        var status = ConnectionStatus()
        status.sshFailure = RouteFailure(
            route: .ssh,
            phase: .verifyingIdentity(.ssh),
            category: .authentication
        )
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: status), .tokenUnauthorized)
    }

    func testSSHDeviceRevokedIsPromoted() {
        var status = ConnectionStatus()
        status.sshFailure = RouteFailure(
            route: .ssh,
            phase: .verifyingIdentity(.ssh),
            category: .deviceRevoked
        )
        XCTAssertEqual(PairingEntryPolicy.authFailure(from: status), .deviceRevoked)
        let policy = PairingEntryPolicy(
            hasDeviceToken: true,
            isPaired: true,
            authFailure: PairingEntryPolicy.authFailure(from: status)
        )
        XCTAssertTrue(policy.isRepairPromoted)
    }
}
