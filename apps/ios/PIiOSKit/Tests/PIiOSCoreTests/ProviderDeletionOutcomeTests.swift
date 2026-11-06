import Foundation
import XCTest
@testable import PIiOSCore

final class ProviderDeletionOutcomeTests: XCTestCase {
    private let providerID = "6f1c2a3e-4b5d-4c7e-8f90-a1b2c3d4e5f6"
    private let targetProviderID = "0a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d"

    private func summary(
        effect: ProviderRemoveEffect,
        defaultMoved: ProviderDefaultMove? = nil,
        remainingEligible: Int = 1
    ) -> ProviderRemoveSummary {
        ProviderRemoveSummary(
            providerId: providerID,
            effect: effect,
            secretCleared: true,
            defaultMoved: defaultMoved,
            remaining: remainingEligible,
            remainingEligible: remainingEligible
        )
    }

    // MARK: - 回执 → 统一结果

    func testSuccessReceiptMapsToSuccess() {
        let moved = ProviderDefaultMove.moved(providerId: targetProviderID, modelId: "model/a")
        let receipt = ProviderRemoveReceipt.success(
            summary(effect: .deleted, defaultMoved: moved)
        )
        guard case .success(let parsed) = ProviderDeletionOutcome(receipt: receipt) else {
            return XCTFail("成功回执应映射为 .success")
        }
        XCTAssertEqual(parsed?.defaultMoved, moved)
    }

    func testNotFoundFailureMapsToIdempotentAlreadyAbsent() {
        let outcome = ProviderDeletionOutcome(receipt: .failure(.notFound))
        XCTAssertEqual(outcome, .alreadyAbsent)
        XCTAssertTrue(outcome.isCompleted)
        XCTAssertTrue(outcome.removesLocalRecord)
        XCTAssertTrue(outcome.clearsLocalKey)
        XCTAssertFalse(outcome.keepsRecoveryContext)
        XCTAssertFalse(outcome.needsAttention)
    }

    func testBusinessFailureKeepsRecoveryContext() {
        let outcome = ProviderDeletionOutcome(receipt: .failure(.removeFailed))
        XCTAssertEqual(outcome, .failure(.removeFailed))
        XCTAssertFalse(outcome.isCompleted)
        XCTAssertFalse(outcome.removesLocalRecord)
        XCTAssertFalse(outcome.clearsLocalKey)
        XCTAssertTrue(outcome.keepsRecoveryContext)
    }

    func testUnparseableKeepsRecoveryContext() {
        let outcome = ProviderDeletionOutcome(receipt: .unparseable(reason: "no marker"))
        XCTAssertEqual(outcome, .unparseable(reason: "no marker"))
        XCTAssertFalse(outcome.isCompleted)
        XCTAssertTrue(outcome.keepsRecoveryContext)
    }

    func testDefaultTransferOrderUnknownIsCompletedButNeedsAttention() {
        let receipt = ProviderRemoveReceipt.defaultTransferOrderUnknown(
            removedProviderId: providerID,
            secretCleared: true
        )
        let outcome = ProviderDeletionOutcome(receipt: receipt)
        XCTAssertEqual(
            outcome,
            .defaultTransferOrderUnknown(removedProviderId: providerID, secretCleared: true)
        )
        XCTAssertTrue(outcome.isCompleted)
        XCTAssertTrue(outcome.removesLocalRecord)
        XCTAssertTrue(outcome.needsAttention)
        XCTAssertFalse(outcome.keepsRecoveryContext)
    }

    func testBlockedOutcomeNeverClearsLocalState() {
        for reason in [ProviderDeletionBlockReason.offline, .hostChanged] {
            let outcome = ProviderDeletionOutcome.blocked(reason)
            XCTAssertFalse(outcome.isCompleted)
            XCTAssertTrue(outcome.keepsRecoveryContext)
        }
    }

    // MARK: - 用户语言

    func testSuccessPresentationExplainsAllThreeStages() {
        let outcome = ProviderDeletionOutcome(receipt: .success(
            summary(
                effect: .deleted,
                defaultMoved: .moved(providerId: targetProviderID, modelId: "model/a")
            )
        ))
        let stages = ProviderDeletionStages(
            v2Requested: true,
            v2Removed: true,
            legacyCleared: true,
            localRecordRemoved: true,
            localKeyCleared: true
        )
        let presentation = ProviderDeletionPresenter.present(
            outcome: outcome,
            stages: stages,
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertEqual(presentation.headline, "已删除模型服务「DeepSeek」")
        XCTAssertTrue(presentation.message.contains("服务器已删除记录与密钥"))
        XCTAssertTrue(presentation.message.contains("默认模型已转给"))
        XCTAssertTrue(presentation.message.contains("旧版服务记录也已一并清理"))
        XCTAssertTrue(presentation.message.contains("本机记录已清理"))
        XCTAssertTrue(presentation.message.contains("本机密钥已清除"))
    }

    func testSuccessWithoutLegacyDoesNotClaimLegacyCleanup() {
        let outcome = ProviderDeletionOutcome.success(summary: nil)
        let presentation = ProviderDeletionPresenter.present(
            outcome: outcome,
            stages: ProviderDeletionStages(
                v2Requested: true,
                v2Removed: true,
                localRecordRemoved: true,
                localKeyCleared: true
            ),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertTrue(presentation.message.contains("已从 PI-adaptor 删除"))
        XCTAssertFalse(presentation.message.contains("旧版服务"))
    }

    func testAlreadyAbsentPresentationUsesUserLanguage() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .alreadyAbsent,
            stages: ProviderDeletionStages(v2AlreadyAbsent: true, localRecordRemoved: true, localKeyCleared: true),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertTrue(presentation.message.contains("服务器上已不存在该记录"))
        XCTAssertTrue(presentation.message.contains("原本已没有这条记录"))
    }

    func testDefaultTransferOrderUnknownPresentationNeedsAttention() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .defaultTransferOrderUnknown(
                removedProviderId: providerID,
                secretCleared: true
            ),
            stages: ProviderDeletionStages(v2Removed: true, legacyCleared: true),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .needsAttention)
        XCTAssertEqual(presentation.headline, "已删除模型服务「DeepSeek」")
        XCTAssertTrue(presentation.message.contains("默认模型因创建时间不可比未转移"))
        XCTAssertTrue(presentation.message.contains("旧版服务记录也已一并清理"))
    }

    func testSecretNotClearedVariantIsExplained() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .defaultTransferOrderUnknown(
                removedProviderId: providerID,
                secretCleared: false
            ),
            stages: ProviderDeletionStages(v2Removed: true, legacyCleared: true),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .needsAttention)
        XCTAssertTrue(presentation.message.contains("密钥未清除"))
    }

    func testFailurePresentationKeepsRecoveryContextVisible() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .failure(.removeFailed),
            stages: ProviderDeletionStages(v2Requested: true),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .failure)
        XCTAssertNil(presentation.headline)
        XCTAssertTrue(presentation.message.contains(ProviderRemoveFailureCode.removeFailed.displayMessage))
        XCTAssertTrue(presentation.message.contains("本机映射与密钥线索已保留"))
    }

    func testUnparseablePresentationKeepsRecoveryContextVisible() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .unparseable(reason: "PI_HOST_REMOVED 的 JSON 无法解析"),
            stages: ProviderDeletionStages(),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(presentation.tone, .failure)
        XCTAssertTrue(presentation.message.contains("服务器回执无法解析"))
        XCTAssertTrue(presentation.message.contains("本机映射与密钥线索已保留"))
    }

    func testBlockedPresentationsAreDistinct() {
        let offline = ProviderDeletionPresenter.present(
            outcome: .blocked(.offline),
            stages: ProviderDeletionStages(),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(offline.tone, .failure)
        XCTAssertTrue(offline.message.contains("服务器离线"))

        let switched = ProviderDeletionPresenter.present(
            outcome: .blocked(.hostChanged),
            stages: ProviderDeletionStages(),
            providerName: "DeepSeek"
        )
        XCTAssertEqual(switched.tone, .failure)
        XCTAssertTrue(switched.message.contains("已切换"))
        XCTAssertNotEqual(offline.message, switched.message)
    }

    func testKeyClearFailureIsReportedInsteadOfPretendedSuccess() {
        let presentation = ProviderDeletionPresenter.present(
            outcome: .success(summary: summary(effect: .deleted)),
            stages: ProviderDeletionStages(
                v2Removed: true,
                localRecordRemoved: true,
                localKeyCleared: false
            ),
            providerName: "DeepSeek"
        )
        XCTAssertTrue(presentation.message.contains("本机密钥未能清除"))
    }

    func testSummaryTextKeepsExistingWordingForDefaultMove() {
        XCTAssertEqual(
            ProviderDeletionPresenter.summaryText(
                summary(effect: .absent)
            ),
            "服务器上已不存在该记录；本机残留记录已清理，本次没有再次执行删除。"
        )
        let noRemaining = ProviderDeletionPresenter.summaryText(
            summary(effect: .deleted, defaultMoved: .notMoved(reason: "no_remaining"), remainingEligible: 0)
        )
        XCTAssertTrue(noRemaining.contains("已无剩余模型服务"))
        XCTAssertTrue(noRemaining.contains("当前已无可用模型服务"))
    }
}
