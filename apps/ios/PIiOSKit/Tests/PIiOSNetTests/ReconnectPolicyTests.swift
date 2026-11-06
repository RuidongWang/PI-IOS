import XCTest
@testable import PIiOSNet

/// 自动重连纪律：认证失败/端口被拒这类“重试也没用”的失败必须停止重连，
/// 否则会持续冲击 sshd（MaxStartups / fail2ban），把用户后续的正常连接一起封掉。
///
/// 但握手期 EOF（`.closedByPeer`）是**瞬时**的：移动网络切换、NAT 超时、sshd
/// MaxStartups 都会造成它。S6 把它移出确定性集合，否则一次网络抖动在三次之后
/// 就会永久停连，只能靠用户手点「连接」恢复。
final class ReconnectPolicyTests: XCTestCase {
    func testConnectionStageFailuresAreDetected() {
        for error in [
            SSHTransportError.tunnelRefused(phase: "打开 direct-tcpip 通道", detail: "refused"),
            SSHTransportError.authenticationFailed,
            SSHTransportError.hostKeyAlgorithmUnsupported,
            SSHTransportError.hostKeyUnreadable,
        ] {
            XCTAssertTrue(RACPClient.isConnectionStageFailure(error), "\(error) 应停止自动重连")
        }
    }

    func testTransientFailuresStillRetry() {
        XCTAssertFalse(RACPClient.isConnectionStageFailure(SSHTransportError.timedOut("SSH 握手与认证")))
        XCTAssertFalse(RACPClient.isConnectionStageFailure(SSHTransportError.networkFailure(phase: "建立 TCP 连接", detail: "unreachable")))
        XCTAssertFalse(RACPClient.isConnectionStageFailure(RACPClientError.notConnected))
        // S6：握手期 EOF 属于瞬时失败，三次后不得永久停连。
        XCTAssertFalse(
            RACPClient.isConnectionStageFailure(SSHTransportError.closedByPeer(phase: "SSH 握手与认证")),
            "closedByPeer 是瞬时失败，不能计入「连续 3 次确定性失败」"
        )
    }

    func testRetryStopsAfterThreeConsecutiveStageFailures() {
        // 与 runLoop 里的一致：第 3 次即停止。
        XCTAssertEqual(RACPClient.maxConnectionStageFailures, 3)
    }
}
