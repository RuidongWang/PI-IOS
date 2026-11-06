import XCTest
import PIiOSCore
import PIiOSNet

@testable import PI_IOS

/// U13：`saveAndTest` 点击瞬间冻结的提交快照必须是值拷贝，并且校验、凭证与身份判断
/// 都只读冻结值。这组用例把「不改实时 draft」这条约定钉在纯策略层。
final class HostSaveIntentTests: XCTestCase {
    func testFreezeCopiesDraftSoLaterFormEditsDoNotLeakIntoSubmission() {
        var live = makeDraft(host: "a.example.com", port: "22", username: "pi")
        live.secret = "old-password"
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: true)
        let intent = HostSaveIntent.freeze(
            hostID: existing.id,
            draft: live,
            existing: existing,
            account: "pi@a.example.com:22",
            credential: .password("old-password")
        )

        // 点击之后用户继续把表单改成 B（真实界面在保存期间禁用相关字段，这里模拟最坏情况）。
        live.host = "b.example.com"
        live.port = "2222"
        live.username = "other"
        live.authKind = .privateKey
        live.secret = "-----BEGIN OPENSSH PRIVATE KEY-----"
        live.passphrase = "changed"
        live.hostPort = "9999"
        live.connectionPreference = .directPreferred

        XCTAssertEqual(intent.draft.host, "a.example.com")
        XCTAssertEqual(intent.draft.port, "22")
        XCTAssertEqual(intent.draft.username, "pi")
        XCTAssertEqual(intent.draft.authKind, .password)
        XCTAssertEqual(intent.account, "pi@a.example.com:22")
        XCTAssertEqual(intent.credential, .password("old-password"))
        XCTAssertEqual(intent.validationErrors, HostDraftErrors.none)
        XCTAssertEqual(intent.displayName, "a.example.com")
        XCTAssertTrue(intent.requiresReconnect)
    }

    func testValidationUsesFrozenDraftNotLiveForm() {
        var live = makeDraft(host: "", port: "22", username: "pi")
        live.secret = "pw"
        let intent = HostSaveIntent.freeze(
            hostID: nil,
            draft: live,
            existing: nil,
            account: "account",
            credential: .password("pw")
        )

        live.host = "fixed.example.com"
        live.secret = ""

        XCTAssertNotNil(intent.validationErrors.host)
        XCTAssertFalse(intent.validationErrors.isValid)
        // 新增记录必须填凭证：口径同样来自点击时。
        XCTAssertTrue(intent.requiresSecret)
    }

    func testEditingCurrentHostWithNewIdentityRequiresReconnect() {
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: true)
        var draft = HostDraft(record: existing)
        draft.host = "b.example.com"
        let intent = HostSaveIntent.freeze(
            hostID: existing.id,
            draft: draft,
            existing: existing,
            account: "account",
            credential: .password("pw")
        )
        XCTAssertTrue(intent.identity?.connectionIdentityChanged(by: intent.draft) == true)
        XCTAssertTrue(intent.requiresReconnect)
        XCTAssertFalse(intent.requiresSecret)
    }

    func testEditingCurrentHostWithNewCredentialRequiresReconnectEvenIfIdentitySame() {
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: true)
        var draft = HostDraft(record: existing)
        draft.secret = "new-password"
        let intent = HostSaveIntent.freeze(
            hostID: existing.id,
            draft: draft,
            existing: existing,
            account: "account",
            credential: .password("new-password")
        )
        XCTAssertFalse(intent.identity?.connectionIdentityChanged(by: intent.draft) == true)
        XCTAssertTrue(intent.requiresReconnect)
    }

    func testDisplayNameOnlyChangeDoesNotRequireReconnect() {
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: true)
        var draft = HostDraft(record: existing)
        draft.name = "书房服务器"
        let intent = HostSaveIntent.freeze(
            hostID: existing.id,
            draft: draft,
            existing: existing,
            account: "account",
            credential: .password("pw")
        )
        XCTAssertFalse(intent.requiresReconnect)
    }

    func testChangingNonCurrentHostDoesNotRequireReconnect() {
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: false)
        var draft = HostDraft(record: existing)
        draft.host = "b.example.com"
        let intent = HostSaveIntent.freeze(
            hostID: existing.id,
            draft: draft,
            existing: existing,
            account: "account",
            credential: .password("pw")
        )
        XCTAssertFalse(intent.requiresReconnect)
    }

    func testNewRecordNeverRequiresReconnect() {
        var draft = makeDraft(host: "a.example.com", port: "22", username: "pi")
        draft.secret = "pw"
        let intent = HostSaveIntent.freeze(
            hostID: nil,
            draft: draft,
            existing: nil,
            account: "account",
            credential: .password("pw")
        )
        XCTAssertNil(intent.identity)
        XCTAssertFalse(intent.requiresReconnect)
        XCTAssertTrue(intent.requiresSecret)
    }

    func testIdentityGateSkipsValidationWhenNoReconnectIsRequired() {
        let intent = makeIntent(requiresReconnect: false)
        XCTAssertTrue(intent.canApplyIdentityChange(identityGeneration: nil, isValid: { _ in false }))
    }

    func testIdentityGateAbortsWhenReconnectNeededButGenerationMissing() {
        let intent = makeIntent(requiresReconnect: true)
        XCTAssertFalse(intent.canApplyIdentityChange(identityGeneration: nil, isValid: { _ in true }))
    }

    func testIdentityGateRechecksCurrentGeneration() {
        let intent = makeIntent(requiresReconnect: true)
        XCTAssertTrue(intent.canApplyIdentityChange(identityGeneration: 7, isValid: { $0 == 7 }))
        XCTAssertFalse(intent.canApplyIdentityChange(identityGeneration: 7, isValid: { $0 == 8 }))
    }

    // MARK: - Helpers

    private func makeIntent(requiresReconnect: Bool) -> HostSaveIntent {
        var draft = makeDraft(host: "a.example.com", port: "22", username: "pi")
        draft.secret = "pw"
        let existing = makeHost(host: "a.example.com", port: 22, username: "pi", isCurrent: true)
        return HostSaveIntent(
            hostID: existing.id,
            draft: draft,
            account: "account",
            credential: .password("pw"),
            requiresReconnect: requiresReconnect,
            requiresSecret: false,
            identity: HostSaveIntent.Identity(record: existing)
        )
    }

    private func makeDraft(host: String, port: String, username: String) -> HostDraft {
        var draft = HostDraft()
        draft.host = host
        draft.port = port
        draft.username = username
        return draft
    }

    private func makeHost(host: String, port: Int, username: String, isCurrent: Bool) -> HostRecord {
        HostRecord(
            id: UUID(),
            name: host,
            host: host,
            port: port,
            username: username,
            authKind: .password,
            createdAt: Date(),
            isCurrent: isCurrent,
            pairedAt: nil,
            tunnelUpAt: nil,
            hostPort: nil,
            keyFileName: nil
        )
    }
}
