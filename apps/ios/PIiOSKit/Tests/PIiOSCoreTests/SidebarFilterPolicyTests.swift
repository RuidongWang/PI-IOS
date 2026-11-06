import Foundation
import XCTest
@testable import PIiOSCore

final class SidebarFilterPolicyTests: XCTestCase {
    func testNormalizedQueryTrimsAndLowercases() {
        XCTAssertEqual(SidebarFilterPolicy.normalizedQuery("  Alpha  "), "alpha")
        XCTAssertEqual(SidebarFilterPolicy.normalizedQuery("\n\t"), "")
        XCTAssertEqual(SidebarFilterPolicy.normalizedQuery(""), "")
        XCTAssertEqual(SidebarFilterPolicy.normalizedQuery("修复 登录"), "修复 登录")
    }

    func testMatchesWithoutQueryAlwaysHits() {
        XCTAssertTrue(SidebarFilterPolicy.matches(title: "任意", projectName: "任意项目", query: ""))
    }

    func testMatchesTitleCaseInsensitively() {
        XCTAssertTrue(
            SidebarFilterPolicy.matches(title: "Alpha One", projectName: "Workspace", query: "alpha")
        )
        XCTAssertTrue(
            SidebarFilterPolicy.matches(title: "alpha one", projectName: "Workspace", query: "ALPHA")
        )
        XCTAssertFalse(
            SidebarFilterPolicy.matches(title: "Beta One", projectName: "Workspace", query: "alpha")
        )
    }

    func testMatchesProjectNameKeepsEverySession() {
        // 项目名命中时，组内每个会话都应命中（与在线既有行为一致：搜项目名能看到该项目全部会话）。
        let query = "workspace"
        XCTAssertTrue(
            SidebarFilterPolicy.matches(title: "随便的标题", projectName: "Fixture Workspace", query: query)
        )
    }

    func testKeepsGroupRules() {
        XCTAssertTrue(
            SidebarFilterPolicy.keepsGroup(projectName: "Workspace", sessionTitles: [], query: "")
        )
        XCTAssertTrue(
            SidebarFilterPolicy.keepsGroup(
                projectName: "Fixture Workspace",
                sessionTitles: ["Alpha One"],
                query: "fixture"
            )
        )
        XCTAssertTrue(
            SidebarFilterPolicy.keepsGroup(
                projectName: "Workspace",
                sessionTitles: ["Alpha One", "Beta Two"],
                query: "beta"
            )
        )
        XCTAssertFalse(
            SidebarFilterPolicy.keepsGroup(
                projectName: "Workspace",
                sessionTitles: ["Alpha One"],
                query: "gamma"
            )
        )
    }

    func testSearchForcesExpansionAndRestoresUserCollapse() {
        XCTAssertFalse(
            SidebarFilterPolicy.isCollapsed(storedCollapsed: true, query: "alpha"),
            "搜索时必须展开，否则命中内容被折叠隐藏"
        )
        XCTAssertTrue(
            SidebarFilterPolicy.isCollapsed(storedCollapsed: true, query: ""),
            "清空搜索后恢复用户原来的折叠状态"
        )
        XCTAssertFalse(SidebarFilterPolicy.isCollapsed(storedCollapsed: false, query: ""))
    }

    func testCollapseToggleOnlyWithoutQuery() {
        XCTAssertTrue(SidebarFilterPolicy.canToggleGroup(query: ""))
        XCTAssertFalse(SidebarFilterPolicy.canToggleGroup(query: "alpha"))
    }

    func testOfflineEmptyMessageDistinguishesNoCacheFromNoMatch() {
        XCTAssertEqual(
            SidebarFilterPolicy.offlineEmptyMessage(hasCachedSessions: false, query: ""),
            "尚未连接服务器，本机也没有缓存的历史。",
            "没有缓存时保持既有文案"
        )
        XCTAssertEqual(
            SidebarFilterPolicy.offlineEmptyMessage(hasCachedSessions: false, query: "alpha"),
            "尚未连接服务器，本机也没有缓存的历史。"
        )
        XCTAssertEqual(
            SidebarFilterPolicy.offlineEmptyMessage(hasCachedSessions: true, query: "alpha"),
            "本机缓存中无匹配。",
            "有缓存但没命中必须与「没有缓存」区分"
        )
        XCTAssertEqual(
            SidebarFilterPolicy.offlineEmptyMessage(hasCachedSessions: true, query: ""),
            "尚未连接服务器，本机也没有缓存的历史。",
            "无查询时不引入新文案"
        )
    }
}
