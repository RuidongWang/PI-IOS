import Foundation
import XCTest
@testable import PIiOSCore

final class SkillInstallPhaseTests: XCTestCase {
    private func gitRequest(subdir: String = "", ref: String = "", replace: Bool = false) -> SkillInstallRequest {
        SkillInstallRequest(
            sourceType: SkillInstallRequest.gitSourceType,
            location: "https://github.com/example/skills.git",
            subdir: subdir,
            reference: ref,
            replace: replace
        )
    }

    // MARK: - 请求快照

    func testRequestTrimsFieldsAndDropsEmptyOptionals() {
        let request = SkillInstallRequest(
            sourceType: SkillInstallRequest.gitSourceType,
            location: "  https://github.com/example/skills.git  ",
            subdir: "   ",
            reference: "",
            replace: true
        )
        XCTAssertTrue(request.isValid)
        XCTAssertEqual(request.location, "https://github.com/example/skills.git")
        XCTAssertEqual(request.subdir, "")
        XCTAssertEqual(request.reference, "")
        XCTAssertTrue(request.replace)

        let payload = request.sourcePayload()
        XCTAssertEqual(payload.value(at: ["type"])?.stringValue, "git")
        XCTAssertEqual(payload.value(at: ["url"])?.stringValue, "https://github.com/example/skills.git")
        XCTAssertNil(payload.value(at: ["subdir"]), "纯空白 subdir 不能当成「指定了空子目录」")
        XCTAssertNil(payload.value(at: ["path"]), "git 来源不能用目录字段")
    }

    func testDirectoryRequestUsesPathAndKeepsSubdirWhenPresent() {
        let request = SkillInstallRequest(
            sourceType: SkillInstallRequest.directorySourceType,
            location: "/home/user/skills/demo",
            subdir: "skills/demo",
            reference: "main"
        )
        let payload = request.sourcePayload()
        XCTAssertEqual(payload.value(at: ["type"])?.stringValue, "directory")
        XCTAssertEqual(payload.value(at: ["path"])?.stringValue, "/home/user/skills/demo")
        XCTAssertEqual(payload.value(at: ["subdir"])?.stringValue, "skills/demo")
        XCTAssertNil(payload.value(at: ["url"]), "目录来源不能用 git 字段")
        XCTAssertNil(payload.value(at: ["ref"]), "目录来源没有 ref 概念")
    }

    func testEmptySourceIsNotValid() {
        XCTAssertFalse(SkillInstallRequest(sourceType: "git", location: "   ").isValid)
    }

    // MARK: - 状态机

    func testBeginFreezesRequestAndShowsInstallingTitle() {
        var machine = SkillInstallMachine()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.phase.buttonTitle, "安装 Skill")
        XCTAssertFalse(machine.phase.isSubmitting)
        XCTAssertTrue(machine.canStartNewInstall)

        let request = gitRequest(subdir: "skills/demo", ref: "main", replace: true)
        XCTAssertTrue(machine.begin(request))

        XCTAssertEqual(machine.phase, .installing(request))
        XCTAssertEqual(machine.phase.request, request, "安装阶段必须持有点击时冻结的请求快照")
        XCTAssertTrue(machine.phase.isSubmitting)
        XCTAssertFalse(machine.canStartNewInstall)
        XCTAssertEqual(machine.phase.buttonTitle, "正在安装…")
        XCTAssertNil(machine.phase.statusMessage)
    }

    func testDuplicateBeginWhileInstallingIsIgnored() {
        var machine = SkillInstallMachine()
        let first = gitRequest(subdir: "skills/a")
        XCTAssertTrue(machine.begin(first))

        // 第二次点击（更慢的渲染 / 用户连点）必须被吞掉，不能发出第二个安装请求。
        let second = gitRequest(subdir: "skills/b", replace: true)
        XCTAssertFalse(machine.begin(second))
        XCTAssertEqual(machine.phase, .installing(first), "在途请求不能被后来的点击替换")
    }

    func testDuplicateBeginDuringListRefreshIsIgnored() {
        var machine = SkillInstallMachine()
        XCTAssertTrue(machine.begin(gitRequest()))
        machine.installSucceeded()
        XCTAssertEqual(machine.phase, .refreshingList)
        XCTAssertTrue(machine.phase.isSubmitting, "安装成功但列表还没刷新完，仍不能再次提交")
        XCTAssertFalse(machine.begin(gitRequest(subdir: "other")))
        XCTAssertEqual(machine.phase, .refreshingList)
    }

    func testBeginRejectsInvalidSource() {
        var machine = SkillInstallMachine()
        XCTAssertFalse(machine.begin(SkillInstallRequest(sourceType: "git", location: "  ")))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testInstallFailureKeepsSourceAndAllowsRetry() {
        var machine = SkillInstallMachine()
        let request = gitRequest()
        XCTAssertTrue(machine.begin(request))
        machine.installFailed("网络超时")

        XCTAssertEqual(machine.phase, .failed(message: "网络超时"))
        XCTAssertEqual(machine.phase.statusMessage, "网络超时")
        XCTAssertFalse(machine.phase.isSubmitting)
        XCTAssertTrue(machine.canStartNewInstall, "失败后必须能用同一份来源重试")
        XCTAssertEqual(machine.phase.buttonTitle, "重试安装")

        XCTAssertTrue(machine.begin(request), "重试要复用同一份来源快照")
        XCTAssertEqual(machine.phase, .installing(request))
    }

    func testInstallSuccessThenListRefreshSuccessClearsSource() {
        var machine = SkillInstallMachine()
        XCTAssertTrue(machine.begin(gitRequest()))
        machine.installSucceeded()
        XCTAssertTrue(machine.listRefreshSucceeded(), "安装成功且列表刷新成功才允许清空来源")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.canStartNewInstall)
        XCTAssertEqual(machine.phase.buttonTitle, "安装 Skill")
    }

    func testInstallSuccessButListRefreshFailureIsPartialSuccess() {
        var machine = SkillInstallMachine()
        let request = gitRequest()
        XCTAssertTrue(machine.begin(request))
        machine.installSucceeded()
        machine.listRefreshFailed("列表读取超时")

        XCTAssertEqual(machine.phase, .installedListStale(message: "列表读取超时"))
        XCTAssertTrue(machine.phase.isInstalledPendingListRefresh)
        XCTAssertEqual(machine.phase.statusMessage, "列表读取超时")
        XCTAssertFalse(machine.phase.isSubmitting)
        XCTAssertNotEqual(
            machine.phase,
            .failed(message: "列表读取超时"),
            "安装已经成功，不能落成安装失败状态"
        )
        XCTAssertEqual(
            machine.phase.buttonTitle,
            "安装 Skill",
            "已安装成功时按钮不能写成「重新安装」，避免引导重复安装"
        )

        // 用户点「重新读取列表」后成功：这时才清空来源。
        XCTAssertTrue(machine.listRefreshSucceeded())
        XCTAssertEqual(machine.phase, .idle)
    }

    func testDismissStaleNoticeReturnsToIdleWithoutClearingDecision() {
        var machine = SkillInstallMachine()
        XCTAssertTrue(machine.begin(gitRequest()))
        machine.installSucceeded()
        machine.listRefreshFailed("列表读取超时")
        machine.dismissStaleNotice()
        XCTAssertEqual(machine.phase, .idle)
    }

    func testOutOfOrderTransitionsAreNoOps() {
        var machine = SkillInstallMachine()

        // 没有在途安装时收到回执：不能凭空进入 refreshingList / failed。
        machine.installSucceeded()
        XCTAssertEqual(machine.phase, .idle)
        machine.installFailed("孤儿失败")
        XCTAssertEqual(machine.phase, .idle)
        machine.listRefreshFailed("孤儿刷新失败")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.listRefreshSucceeded())

        // 安装失败后收到刷新结果同样不能把状态改成 idle。
        XCTAssertTrue(machine.begin(gitRequest()))
        machine.installFailed("网络超时")
        XCTAssertFalse(machine.listRefreshSucceeded())
        XCTAssertEqual(machine.phase, .failed(message: "网络超时"))
    }
}
