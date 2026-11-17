import XCTest

@testable import PIiOSNet

/// 测试用私钥 fixture 的读取器。
///
/// fixture 全部由 `ssh-keygen` 在开发机上临时生成（见 Fixtures/README.md），
/// 不是任何真实服务器使用的密钥；口令统一是 `pi-test-passphrase`。
/// Host-key policy for opt-in real-server tests. Tests must supply the
/// fingerprint obtained out of band (PI_SSH_KNOWN_HOST_KEY); otherwise the
/// connection is rejected instead of silently trusting any key.
enum TestHostKeyPolicy {
    static func confirm(_ key: SSHHostKey) -> HostKeyConfirmation {
        let expected = ProcessInfo.processInfo.environment["PI_SSH_KNOWN_HOST_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected, !expected.isEmpty else { return .reject }
        return key.fingerprint == expected ? .trust : .reject
    }
}

enum SSHFixture {
    static let passphrase = "pi-test-passphrase"

    static func text(_ name: String) throws -> String {
        let raw = try data(name)
        let text = String(decoding: raw, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func data(_ name: String) throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: nil),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url) { return data }
        }
        XCTFail("找不到 fixture \(name)，bundle 路径：\(Bundle.module.bundlePath)")
        throw FixtureError.missing(name)
    }

    /// 对应的 `.pub` 文件里前两段（算法名 + base64 公钥）。
    static func publicKeyLine(_ name: String) throws -> String {
        let line = try text("\(name).key.pub")
        return line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    enum FixtureError: Error { case missing(String) }
}
