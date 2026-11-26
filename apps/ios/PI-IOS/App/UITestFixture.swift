import Foundation
import PIiOSCore
import PIiOSNet
#if DEBUG
import CoreGraphics
import CryptoKit
import ImageIO
#endif

/// DEBUG UI-test-only earlier-history page. `delayMilliseconds` keeps the
/// production loading state observable long enough for a user drag to cancel it.
struct UITestEarlierHistoryPage {
    let items: [RACPItem]
    let hasMore: Bool
    let delayMilliseconds: Int
}

/// FROZEN fixture contract: DEBUG + exact PI_IOS_UI_FIXTURE_SCENARIO only.
/// These are synthetic projections, never successful server responses.
/// offline-two-hosts starts on B; online-two-sessions supplies a read-only
/// in-memory catalog for sidebar interactions, without a transport or credentials.
struct UITestFixture {
    struct Catalog {
        let projects: [RACPProjectSummary]
        let sessions: [RACPSessionSummary]
        let info: RACPServerInfo
    }

    var state: PersistedState
    var cache: OfflineSessionCacheSnapshot
    var catalog: Catalog? = nil
    var catalogs: [UUID: Catalog] = [:]
    var sessionSnapshots: [String: RACPSessionView] = [:]
    /// Earlier pages supplied to the DEBUG `SessionController` fixture seam.
    /// Only scenarios exercising history backfill provide pages.
    var earlierHistoryPages: [String: [UITestEarlierHistoryPage]] = [:]
    var providerBindingStatuses: [String: ProviderBindingStatus] = [:]
    var supportsFixtureInterrupt = false
    var adaptorUnitSnapshot: AdaptorUnitSnapshot? = nil
    var connectionState: RACPTunnelState? = nil
    /// 夹具没有真实 RACP 连接；SET-04 需要覆盖「服务器确认后取消配对」的 UI 路径，
    /// 因此由夹具显式声明撤销会成功，而不是让 `revokeThisDevice` 因缺 client 报离线。
    var supportsFixtureRevoke = false
    /// 仅用于模型更新 UI 的内存 Provider；不代表真实 PI-adaptor 已响应。
    var updatableProviders: [RACPV2Provider] = []
    var directTrustPin: DirectTLSTrustPin? = nil
    var connectionStatus: ConnectionStatus? = nil
    var extensionInventory: RACPExtensionInventory? = nil
    var sessionExtensions: [String: RACPSessionExtensions] = [:]
    var extensionReadFailure = false

    /// Delays/failures are available only in the opt-in synthetic UI scenario.
    var sessionOpenBehavior: (delayMilliseconds: Int, failingSessionID: String?)? = nil
    var submissionFailureDelayMilliseconds: Int? = nil
    static var current: Self? {
#if DEBUG
        switch ProcessInfo.processInfo.environment["PI_IOS_UI_FIXTURE_SCENARIO"] {
        case let scenario? where scenario.hasPrefix("extensions-"):
            let allowed = ["extensions-loaded", "extensions-offline", "extensions-unsupported", "extensions-never-run", "extensions-empty", "extensions-error"]
            guard allowed.contains(scenario) else { return nil }
            var fixture = onlineModelConfig()
            ExtensionUITestData.configure(&fixture, scenario: scenario)
            return fixture
        case "offline-two-hosts": return offlineTwoHosts()
        case "empty-state": return emptyState()
        case "offline-cache-205": return offlineCache205()
        case "online-two-sessions": return onlineTwoSessions()
        case "interaction-smoothness":
            var fixture = onlineReadingTwoSessions()
            let hostID = fixture.state.hosts[0].id
            fixture.cache.entries = [OfflineSessionCacheEntry(
                id: "preview-S2", sessionId: "S2", hostID: hostID,
                text: "Cached S2 history", createdAt: Date(timeIntervalSince1970: 1_704_164_640)
            )]
            let environment = ProcessInfo.processInfo.environment
            let delay = environment["PI_IOS_UI_OPEN_DELAY_MS"].flatMap(Int.init) ?? 4_000
            fixture.sessionOpenBehavior = (delay, environment["PI_IOS_UI_FAIL_OPEN"])
            return fixture
        case "interaction-cache-render":
            var fixture = onlineReadingTwoSessions()
            let hostID = fixture.state.hosts[0].id
            let base = Date(timeIntervalSince1970: 1_704_164_640)
            fixture.cache.entries = [
                OfflineSessionCacheEntry(id: "preview-user", sessionId: "S2", hostID: hostID,
                    text: "同步今日数据", createdAt: base, kind: "message", role: "user"),
                OfflineSessionCacheEntry(id: "preview-empty", sessionId: "S2", hostID: hostID,
                    text: "", createdAt: base.addingTimeInterval(1), kind: "message", role: "assistant"),
                OfflineSessionCacheEntry(id: "preview-tool", sessionId: "S2", hostID: hostID,
                    text: "observations 2152\n" + String(repeating: "网络接收错误。", count: 20_000),
                    createdAt: base.addingTimeInterval(2), kind: "tool_call", role: "tool",
                    toolName: "Bash", status: "completed"),
                OfflineSessionCacheEntry(id: "preview-answer", sessionId: "S2", hostID: hostID,
                    text: "**同步完成**", createdAt: base.addingTimeInterval(3), kind: "message", role: "assistant")
            ]
            fixture.sessionOpenBehavior = (500, "S2")
            return fixture
        case "interaction-large-preview":
            var fixture = onlineReadingTwoSessions()
            let hostID = fixture.state.hosts[0].id
            fixture.cache.entries = (0..<3_500).map { index in
                OfflineSessionCacheEntry(id: "large-\(index)", sessionId: "S2", hostID: hostID,
                    text: "Cached history \(index)", createdAt: Date(timeIntervalSince1970: 1_704_164_640 + Double(index)),
                    kind: "message", role: index.isMultiple(of: 35) ? "user" : "assistant", turnId: "turn-\(index / 35)")
            }
            fixture.sessionOpenBehavior = (500, "S2")
            return fixture
        case "interaction-submit":
            var fixture = onlineModelConfig()
            fixture.submissionFailureDelayMilliseconds = 3_000
            return fixture
        case "online-reading-two-sessions": return onlineReadingTwoSessions()
        case "online-stability-history": return onlineStabilityHistory()
        case "stability-images": return onlineStabilityImages()
        case "stability-paging": return onlineStabilityPaging()
        case "online-large-tool-result": return onlineLargeToolResult()
        case "online-tool-result-body": return onlineToolResultBody()
        case "online-tool-batch": return onlineToolBatch()
        case "online-single-tool-turn": return onlineSingleToolTurn()
        case "online-running-tool-turn": return onlineRunningToolTurn()
        case "online-interleaved-tool-turn": return onlineInterleavedToolTurn()
        case "online-markdown-message": return onlineMarkdownMessage()
        case "online-long-history-pending-approval": return onlineLongHistoryPendingApproval()
        case "online-project-lifecycle": return onlineProjectLifecycle()
        case "online-upstream-import": return onlineUpstreamImport()
        case "online-model-config": return onlineModelConfig()
        case "online-model-update": return onlineModelUpdate()
        case "online-queued-turns": return onlineQueuedTurns()
        case "online-host-unit-active": return onlineHostUnitActive()
        case "online-host-unit-stopped": return onlineHostUnitStopped()
        case "online-two-hosts": return onlineTwoHosts()
        case "online-direct-ssh": return onlineDirectSSH()
        case "online-direct-active": return onlineDirectActive()
        default: return nil
        }
#else
        return nil
#endif
    }

#if DEBUG
    static var stabilityControlsEnabled: Bool {
        ProcessInfo.processInfo.environment["PI_IOS_UI_FIXTURE_SCENARIO"] == "online-stability-history"
            && ProcessInfo.processInfo.environment["PI_IOS_UI_STABILITY_CONTROLS"] == "1"
    }

    /// Immutable synthetic image source; only this exact scenario can inject it.
    /// Thumbnail and detail still run the production chunk/validate/decode loader.
    private final class ImageConnectionToken: @unchecked Sendable {}
    private static let imageConnectionToken = ImageConnectionToken()
    private static let stabilityImageBytes: Data = {
        guard let context = CGContext(data: nil, width: 2_048, height: 768,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            preconditionFailure("cannot create stability image fixture")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 768))
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, "public.png" as CFString, 1, nil) else {
            preconditionFailure("cannot encode stability image fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return bytes as Data
    }()
    private static let stabilityImageAttachment = makeAttachment(
        id: "stability-image-1", sessionId: "S1", kind: "input",
        fileName: "stability-original.png", mimeType: "image/png",
        byteLength: stabilityImageBytes.count,
        sha256: SHA256.hash(data: stabilityImageBytes).map { String(format: "%02x", $0) }.joined(),
        state: "ready", createdAt: "2024-01-01T00:00:00Z"
    )

    static func stabilityImageSource(
        attachment: RACPV2Attachment, hostID: UUID
    ) -> (key: AttachmentImageKey, read: AttachmentImageLoader.Read)? {
        guard ProcessInfo.processInfo.environment["PI_IOS_UI_FIXTURE_SCENARIO"] == "stability-images",
              attachment == stabilityImageAttachment else { return nil }
        return (
            AttachmentImageKey(hostID: hostID, connectionID: ObjectIdentifier(imageConnectionToken), attachment: attachment),
            { offset, length in
                try Task.checkCancellation()
                let bytes = stabilityImageBytes
                let end = min(bytes.count, offset + length)
                guard offset >= 0, offset <= end else { throw AttachmentImageError.invalidChunk }
                return Self.makeAttachmentReadResult(
                    attachment: stabilityImageAttachment,
                    dataBase64: bytes.subdata(in: offset..<end).base64EncodedString(),
                    eof: end == bytes.count
                )
            }
        )
    }

    /// Wire types are `Codable`-only (no public memberwise init); fixtures must
    /// build them through the production decoding path.
    static func makeAttachment(
        id: String, sessionId: String, kind: String, fileName: String,
        mimeType: String, byteLength: Int, sha256: String, state: String,
        createdAt: String
    ) -> RACPV2Attachment {
        let object: [String: Any] = [
            "id": id, "sessionId": sessionId, "kind": kind, "fileName": fileName,
            "mimeType": mimeType, "byteLength": byteLength, "sha256": sha256,
            "state": state, "createdAt": createdAt
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        do {
            return try JSONDecoder().decode(RACPV2Attachment.self, from: data)
        } catch {
            preconditionFailure("fixture attachment must decode: \(error)")
        }
    }

    /// Wire types are `Codable`-only (no public memberwise init); fixtures must
    /// build the read result through the production decoding path.
    static func makeAttachmentReadResult(
        attachment: RACPV2Attachment,
        dataBase64: String,
        eof: Bool
    ) -> RACPV2AttachmentReadResult {
        let encoded = (try? JSONEncoder().encode(attachment)) ?? Data()
        let attachmentObject = (try? JSONSerialization.jsonObject(with: encoded)) ?? [:]
        let object: [String: Any] = [
            "attachment": attachmentObject,
            "dataBase64": dataBase64,
            "eof": eof
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        do {
            return try JSONDecoder().decode(RACPV2AttachmentReadResult.self, from: data)
        } catch {
            preconditionFailure("fixture read result must decode: \(error)")
        }
    }

    private static func onlineStabilityImages() -> Self {
        var fixture = onlineTwoSessions()
        guard var snapshot = fixture.sessionSnapshots["S1"] else { return fixture }
        let metadata = stabilityImageAttachment
        snapshot.items = [RACPItem(id: "stability-image-message", payload: .object([
            "id": .string("stability-image-message"),
            "role": .string("user"),
            "text": .string("Stability image fixture"),
            "attachments": .array([.object([
                "id": .string(metadata.id), "sessionId": .string(metadata.sessionId),
                "kind": .string(metadata.kind), "fileName": .string(metadata.fileName),
                "mimeType": .string(metadata.mimeType), "byteLength": .number(Double(metadata.byteLength)),
                "sha256": .string(metadata.sha256), "state": .string(metadata.state),
                "createdAt": .string(metadata.createdAt),
            ])]),
        ]))]
        fixture.sessionSnapshots["S1"] = snapshot
        return fixture
    }

    /// 真正的首次启动空态：不受模拟器上残留的 state-v1.json 影响（G-01）。
    private static func emptyState() -> Self {
        Self(state: PersistedState(), cache: OfflineSessionCacheSnapshot())
    }

    private static func onlineReadingTwoSessions() -> Self {
        var fixture = onlineTwoSessions()
        for summary in fixture.catalog!.sessions {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-reading-\(summary.id)", sequence: 40)
            snapshot.items = (1...40).map { index in
                let number = String(format: "%03d", index)
                let id = "reading-\(summary.id)-\(number)"
                return RACPItem(id: id, payload: .object([
                    "id": .string(id),
                    "role": .string("assistant"),
                    "text": .string("Reading \(summary.id) item \(number)\nStable synthetic history for reading-position verification.\nThis message belongs only to \(summary.id)."),
                ]))
            }
            fixture.sessionSnapshots[summary.id] = snapshot
        }
        return fixture
    }

    /// 1,500 条混合历史：普通轮次 + 多中间项工具批次，用来验证锚点映射在真实
    /// SwiftUI LazyVStack 路径上的首/中/末可达性与阅读位置恢复。
    private static func onlineStabilityHistory() -> Self {
        var fixture = onlineTwoSessions()
        guard let summary = fixture.catalog?.sessions.first(where: { $0.id == "S1" }) else {
            return fixture
        }
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-stability-history", sequence: 1_500)

        var items: [RACPItem] = []
        items.reserveCapacity(1_500)
        var index = 1

        func nextNumber() -> String {
            defer { index += 1 }
            return String(format: "%04d", index)
        }

        func item(_ id: String, role: String, text: String, toolName: String? = nil) -> RACPItem {
            var payload: [String: JSONValue] = [
                "id": .string(id),
                "role": .string(role),
                "text": .string(text),
            ]
            if let toolName {
                payload["itemType"] = .string("tool")
                payload["kind"] = .string("tool")
                payload["toolName"] = .string(toolName)
                payload["status"] = .string("completed")
            }
            return RACPItem(id: id, payload: .object(payload))
        }

        func addSimpleTurn() {
            let number = nextNumber()
            items.append(item(
                "stability-\(number)-user",
                role: "user",
                text: "Stability user \(number)"
            ))
            items.append(item(
                "stability-\(number)-tool",
                role: "tool",
                text: "Stability tool \(number)",
                toolName: "bash"
            ))
            items.append(item(
                "stability-\(number)-final",
                role: "assistant",
                text: "Stability final \(number)"
            ))
        }

        func addGroupedTurn() {
            let number = nextNumber()
            items.append(item(
                "stability-\(number)-user",
                role: "user",
                text: "Stability user \(number)"
            ))
            for offset in 1...2 {
                items.append(item(
                    "stability-\(number)-tool-\(offset)",
                    role: "tool",
                    text: "Stability tool \(number)-\(offset)",
                    toolName: offset == 1 ? "bash" : "grep"
                ))
                items.append(item(
                    "stability-\(number)-mid-\(offset)",
                    role: "assistant",
                    text: "Stability mid \(number)-\(offset)"
                ))
            }
            items.append(item(
                "stability-\(number)-final",
                role: "assistant",
                text: "Stability final \(number)"
            ))
        }

        for _ in 0..<490 { addSimpleTurn() }
        for _ in 0..<5 { addGroupedTurn() }
        precondition(items.count == 1_500, "stability fixture must contain exactly 1,500 items")
        snapshot.items = items
        let start = ProcessInfo.processInfo.environment["PI_IOS_UI_STABILITY_START"]
        if start == "group", let index = snapshot.items.firstIndex(where: { $0.id == "stability-0248-final" }) {
            // Opt-in fold regression: make a two-tool group in the middle of the
            // same 1,500 IDs. A group only four turns from the end can legitimately
            // enter the 96pt near-bottom zone when compact rows collapse.
            let id = snapshot.items[index].id
            snapshot.items[index] = item(id, role: "tool", text: "Stability second tool 0248", toolName: "grep")
        }
        fixture.sessionSnapshots[summary.id] = snapshot
        if let hostID = fixture.state.hosts.first(where: { $0.isCurrent })?.id {
            let target: String?
            switch start {
            case "oldest": target = "stability-0001-user"
            case "before-middle": target = "stability-0246-user"
            case "middle": target = "stability-0248-user"
            case "group": target = "stability-0248-tool"
            default: target = nil
            }
            if let target {
                fixture.state.readingPositionsByHost[hostID.uuidString, default: [:]][summary.id] =
                    ConversationReadingPosition(lastVisibleItemID: target, isNearBottom: false)
            }
        }
        return fixture
    }

    /// 前插分页夹具：当前页与第一张上一页都只含同一轮的工具片段，第二张
    /// 上一页才带任务起点。loader 必须暂存两页并一次发布五项；跨页后三条
    /// 工具合并为一行，原阅读位置保持不动。页面延迟让半轮可见性可被观察。
    private static func onlineStabilityPaging() -> Self {
        var fixture = onlineTwoSessions()
        guard let summary = fixture.catalog?.sessions.first(where: { $0.id == "S1" }),
              let hostID = fixture.state.hosts.first(where: { $0.isCurrent })?.id
        else { return fixture }

        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 2
        snapshot.replayComplete = true
        snapshot.hasMoreHistory = true
        snapshot.cursor = RACPCursor(epoch: "fixture-stability-paging", sequence: 100)

        func item(
            _ id: String,
            role: String,
            text: String,
            toolName: String? = nil,
            turnID: String? = nil
        ) -> RACPItem {
            var payload: [String: JSONValue] = [
                "id": .string(id),
                "role": .string(role),
                "text": .string(text),
            ]
            if let toolName {
                payload["itemType"] = .string("tool")
                payload["kind"] = .string("tool")
                payload["toolName"] = .string(toolName)
                payload["status"] = .string("completed")
            }
            if let turnID {
                payload["turnId"] = .string(turnID)
            }
            return RACPItem(id: id, payload: .object(payload))
        }

        // Current page starts in the middle of a turn: two tools form the legacy
        // fallback group, then the final reply closes the segment.
        var items: [RACPItem] = [
            item("paging-tool-2", role: "tool", text: "Paging tool 2", toolName: "bash", turnID: "paging-turn-1"),
            item("paging-tool-3", role: "tool", text: "Paging tool 3", toolName: "grep", turnID: "paging-turn-1"),
            item("paging-final-1", role: "assistant", text: "Paging boundary final 01", turnID: "paging-turn-1"),
        ]
        for index in 1...40 {
            let number = String(format: "%02d", index)
            items.append(item(
                "paging-newer-\(number)",
                role: "user",
                text: "Paging newer \(number)"
            ))
        }
        snapshot.items = items
        fixture.sessionSnapshots[summary.id] = snapshot

        // This nearer page still has no user boundary and must never reach view.
        let toolOnlyPage = [
            item("paging-tool-1", role: "tool", text: "Paging tool 1", toolName: "bash", turnID: "paging-turn-1"),
        ]
        var boundaryPage: [RACPItem] = []
        for index in 1...3 {
            let number = String(format: "%02d", index)
            boundaryPage.append(item(
                "paging-earlier-\(number)",
                role: "user",
                text: "Paging earlier \(number)"
            ))
        }
        boundaryPage.append(item(
            "paging-user-1",
            role: "user",
            text: "Paging boundary user 01",
            turnID: "paging-turn-1"
        ))
        fixture.earlierHistoryPages[summary.id] = [
            UITestEarlierHistoryPage(
                items: toolOnlyPage,
                hasMore: true,
                delayMilliseconds: 1_200
            ),
            UITestEarlierHistoryPage(
                items: boundaryPage,
                hasMore: false,
                delayMilliseconds: 3_000
            ),
        ]
        fixture.state.readingPositionsByHost[hostID.uuidString, default: [:]][summary.id] =
            ConversationReadingPosition(
                lastVisibleItemID: "paging-tool-2",
                isNearBottom: false
            )
        return fixture
    }

    private static func onlineLargeToolResult() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-large-tool", sequence: 1)
        let text = String(repeating: "0123456789abcdef", count: 256 * 1024)
        snapshot.items = [
            RACPItem(id: "large-tool", payload: .object([
                "id": .string("large-tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("large-shell"),
                "status": .string("completed"),
                "text": .string(text),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 长历史 + 一张待审批卡片：审批卡片区在滚动内容最前面，而自动滚动一律滚到最底部。
    /// 这个夹具复刻真实故障现场——工具卡片写着「工具执行中…」，审批卡却被顶出视口上千点，
    /// 用户没法点头，工具就永远是「执行中」。
    private static func onlineLongHistoryPendingApproval() -> Self {
        var fixture = onlineReadingTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        guard var snapshot = fixture.sessionSnapshots[summary.id] else { return fixture }
        snapshot.runningTurnId = "turn-pending-approval"
        snapshot.pendingApprovals = [
            try! RACPApprovalRequest(payload: .object([
                "id": .string("approval-bash-1"),
                "revision": .number(7),
                "kind": .string("tool"),
                "title": .string("bash"),
                "toolName": .string("bash"),
                "input": .object(["command": .string("echo test")])
            ]))
        ]
        snapshot.items.append(
            RACPItem(id: "call_pending", payload: .object([
                "id": .string("call_pending"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "content": .object([
                    "itemId": .string("call_pending"),
                    "toolName": .string("bash"),
                    "input": .object(["command": .string("echo test")])
                ])
            ]))
        )
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }


    /// 工具卡片正文（回归：卡片只显示「服务器没有返回工具输出正文。」）。
    ///
    /// 载荷按契约 §7.2 的真实帧形状给：`toolName` 来自 `tool.started`，
    /// 正文来自 `tool.completed` 的 `result`（Pi 的 `AgentToolResult`），
    /// 两条信息都落在同一条 `item.id` 上。
    private static func onlineToolResultBody() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-tool-body", sequence: 2)
        snapshot.items = [
            // 已完成：正文只存在于 content.result.content[].text。
            RACPItem(id: "call_done", payload: .object([
                "id": .string("call_done"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
                "turnId": .string("turn_1"),
                "content": .object([
                    "itemId": .string("call_done"),
                    "status": .string("completed"),
                    "result": .object([
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("hello-from-tool")])
                        ])
                    ])
                ])
            ])),
            // 运行中：还没有任何输出，卡片不得声称「服务器没有返回工具输出正文。」。
            RACPItem(id: "call_running", payload: .object([
                "id": .string("call_running"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "turnId": .string("turn_1"),
                "content": .object([
                    "itemId": .string("call_running"),
                    "toolName": .string("bash"),
                    "input": .object(["command": .string("sleep 30")])
                ])
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 批量工具调用 + 最终回复：连续 6 次 bash 调用应汇总成一条默认折叠的分组，
    /// 最终回复保持原样展示。用于验证折叠数量、展开/收起与分组摘要。
    private static func onlineToolBatch() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-tool-batch", sequence: 6)
        var items: [RACPItem] = (1...6).map { index in
            let id = "batch_tool_\(index)"
            return RACPItem(id: id, payload: .object([
                "id": .string(id),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
                "turnId": .string("turn_batch"),
                "text": .string("batch-output-\(index)"),
            ]))
        }
        items.append(RACPItem(id: "batch_final", payload: .object([
            "id": .string("batch_final"),
            "role": .string("assistant"),
            "text": .string("以下是 CPU 分析："),
        ])))
        snapshot.items = items
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 单次工具调用 + 最终回复：单次调用也必须折叠成一行，最终回复始终可见。
    private static func onlineSingleToolTurn() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-single-tool", sequence: 3)
        snapshot.items = [
            RACPItem(id: "single_user", payload: .object([
                "id": .string("single_user"),
                "role": .string("user"),
                "text": .string("帮我看看磁盘"),
            ])),
            RACPItem(id: "single_tool", payload: .object([
                "id": .string("single_tool"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
                "turnId": .string("turn_single"),
                "text": .string("single-output"),
            ])),
            RACPItem(id: "single_final", payload: .object([
                "id": .string("single_final"),
                "role": .string("assistant"),
                "text": .string("磁盘检查完成。"),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 运行中的单次工具调用（尚无最终回复）：整轮生命周期内都必须能折叠。
    private static func onlineRunningToolTurn() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-running-tool", sequence: 2)
        snapshot.runningTurnId = "turn_running"
        snapshot.items = [
            RACPItem(id: "running_user", payload: .object([
                "id": .string("running_user"),
                "role": .string("user"),
                "text": .string("检查一下磁盘"),
            ])),
            RACPItem(id: "running_tool", payload: .object([
                "id": .string("running_tool"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("running"),
                "turnId": .string("turn_running"),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 同一轮里被 Agent 过渡消息隔开的多次工具调用：中间过程合并成一个分组。
    private static func onlineInterleavedToolTurn() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-interleaved-tool", sequence: 5)
        snapshot.items = [
            RACPItem(id: "inter_user", payload: .object([
                "id": .string("inter_user"),
                "role": .string("user"),
                "text": .string("分析一下磁盘和内存"),
            ])),
            RACPItem(id: "inter_tool_1", payload: .object([
                "id": .string("inter_tool_1"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
                "turnId": .string("turn_interleaved"),
                "text": .string("disk-output"),
            ])),
            RACPItem(id: "inter_message", payload: .object([
                "id": .string("inter_message"),
                "role": .string("assistant"),
                "text": .string("磁盘看完了，接着看内存。"),
            ])),
            RACPItem(id: "inter_tool_2", payload: .object([
                "id": .string("inter_tool_2"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("grep"),
                "status": .string("completed"),
                "turnId": .string("turn_interleaved"),
                "text": .string("memory-output"),
            ])),
            RACPItem(id: "inter_final", payload: .object([
                "id": .string("inter_final"),
                "role": .string("assistant"),
                "text": .string("磁盘和内存都正常。"),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// Agent 消息的 Markdown 渲染（回归：标题、粗体、行内代码、表格、列表、围栏代码块
    /// 曾被纯 Text 原样画成 `##`、`**`、`|`、```` ``` ````）。
    private static func onlineMarkdownMessage() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-markdown", sequence: 4)
        let text = """
        ## 磁盘信息

        **磁盘使用情况（df -h）**

        | 文件系统 | 大小 | 使用率 |
        | --- | --- | --- |
        | /dev/sda1 | 194G | 23% |

        - `sda1` — 199.9G 主磁盘
        - 剩余约 **150G** 可用

        ```bash
        df -h
        ```
        """
        snapshot.items = [
            RACPItem(id: "markdown-user-message", payload: .object([
                "id": .string("markdown-user-message"),
                "role": .string("user"),
                "text": .string("请用 Markdown 展示磁盘信息"),
            ])),
            RACPItem(id: "markdown-message", payload: .object([
                "id": .string("markdown-message"),
                "role": .string("assistant"),
                "text": .string(text),
            ])),
            // Keep the empty tool in its own turn so it cannot pull the Markdown
            // response above into a collapsed tool-run group.
            RACPItem(id: "markdown-empty-tool-user", payload: .object([
                "id": .string("markdown-empty-tool-user"),
                "role": .string("user"),
                "text": .string("执行一个无输出工具"),
            ])),
            // No `text`: copy tests must not mistake kind/toolName for a raw body.
            RACPItem(id: "markdown-empty-tool", payload: .object([
                "id": .string("markdown-empty-tool"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    private static func onlineProjectLifecycle() -> Self {
        let hostID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projects = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"P1","label":"Alpha Workspace","archived":false},{"id":"P2","label":"Beta Workspace","archived":false}]}"#.utf8)
        ).projects
        let sessions = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"S1","title":"Alpha One","projectId":"P1","status":"idle","revision":1},{"id":"S2","title":"Alpha Two","projectId":"P1","status":"idle","revision":1},{"id":"S3","title":"Beta One","projectId":"P2","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let host = HostRecord(
            id: hostID,
            name: "Fixture Lifecycle PI-adaptor",
            host: "fixture-lifecycle.invalid",
            port: 22,
            username: "fixture",
            authKind: .privateKey,
            createdAt: time,
            isCurrent: true,
            pairedAt: time,
            installReceipt: AdaptorInstallReceipt(
                version: "0.0.1",
                hostPort: 43_871,
                attemptId: "fixture-install",
                completedAt: time
            )
        )
        let state = PersistedState(
            hosts: [host],
            lastSessionId: "S1",
            lastProjectId: "P1",
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostID, projectID: "P1", path: "/fixture/alpha",
                    name: "Alpha Workspace", createdAt: time, updatedAt: time
                ),
                StoredProjectBinding(
                    hostID: hostID, projectID: "P2", path: "/fixture/beta",
                    name: "Beta Workspace", createdAt: time, updatedAt: time
                ),
            ],
            sessionBindings: sessions.enumerated().map { index, session in
                StoredSessionBinding(
                    hostID: hostID,
                    sessionID: session.id,
                    projectID: session.projectId,
                    messageCount: index + 1,
                    lastActivityAt: time.addingTimeInterval(Double(index) * 60),
                    lastKnownRevision: 1,
                    updatedAt: time
                )
            },
            lastSessionByHost: [hostID.uuidString: "S1"],
            lastProjectByHost: [hostID.uuidString: "P1"]
        )
        var fixture = Self(
            state: state,
            cache: OfflineSessionCacheSnapshot(),
            catalog: Catalog(
                projects: projects,
                sessions: sessions,
                info: RACPServerInfo(
                    protocolVersion: "1",
                    serverName: "Fixture Lifecycle",
                    serverVersion: "fixture-only",
                    hostId: hostID.uuidString,
                    connectionId: "fixture-lifecycle",
                    roles: []
                )
            )
        )
        for summary in sessions {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-lifecycle-\(summary.id)", sequence: 1)
            snapshot.items = [
                RACPItem(id: "fixture-lifecycle-item-\(summary.id)", payload: .object([
                    "id": .string("fixture-lifecycle-item-\(summary.id)"),
                    "role": .string("assistant"),
                    "text": .string("Lifecycle history for \(summary.id)"),
                ])),
            ]
            fixture.sessionSnapshots[summary.id] = snapshot
        }
        return fixture
    }

    private static func onlineUpstreamImport() -> Self {
        let fixture = onlineProjectLifecycle()
        var state = fixture.state
        state.projectBindings = []
        state.sessionBindings = []
        state.lastProjectByHost = [:]
        state.lastSessionByHost = [:]
        state.lastProjectId = nil
        state.lastSessionId = nil
        return Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            sessionSnapshots: fixture.sessionSnapshots
        )
    }

    private static func onlineModelUpdate() -> Self {
        let fixture = onlineProjectLifecycle()
        var state = fixture.state
        let hostID = state.hosts[0].id
        let pro = ProviderModelSpec(
            id: "alpha-pro", contextWindow: 200_000, maxTokens: 8_192,
            thinkingLevels: ["off", "low", "high"], defaultThinkingLevel: "low",
            alias: "Alpha Pro", supportsDocuments: true
        )
        let mini = ProviderModelSpec(
            id: "alpha-mini", contextWindow: 128_000, maxTokens: 4_096,
            thinkingLevels: ["off", "low"], defaultThinkingLevel: nil,
            alias: "Alpha Mini"
        )
        // 第二条非默认服务：用于回归「编辑非默认服务的模型参数不能抢走全局默认」。
        let beta = ProviderModelSpec(
            id: "beta-basic", contextWindow: 32_000, maxTokens: 4_096,
            thinkingLevels: [], alias: "Beta Basic"
        )
        state.modelProviders = [
            StoredModelProvider(
                providerId: "prv_alpha", hostID: hostID,
                name: "Alpha Models", baseURL: "https://alpha.invalid",
                apiStyle: "chat_completions",
                models: [StoredModelBinding(spec: pro), StoredModelBinding(spec: mini)],
                defaultModelId: "alpha-pro",
                importedAt: Date(timeIntervalSince1970: 1_704_164_640)
            ),
            StoredModelProvider(
                providerId: "prv_beta", hostID: hostID,
                name: "Beta Models", baseURL: "https://beta.invalid",
                apiStyle: "chat_completions",
                models: [StoredModelBinding(spec: beta)],
                defaultModelId: nil,
                importedAt: Date(timeIntervalSince1970: 1_704_164_000)
            ),
        ]
        return Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            sessionSnapshots: fixture.sessionSnapshots,
            updatableProviders: [try! JSONDecoder().decode(RACPV2Provider.self, from: Data(#"""
            {
                "id":"prv_alpha","name":"Alpha Models","vendorKey":"custom",
                "type":"openai_compatible","protocol":"openai_completions",
                "baseUrl":"https://alpha.invalid","authKind":"api_key",
                "hasApiKey":true,"isDefault":true,"models":[{
                    "id":"alpha-pro","displayName":"Alpha Pro",
                    "contextWindow":200000,"maxTokens":8192,
                    "thinkingLevels":["off","low","high"],
                    "defaultThinkingLevel":"low","supportsImages":false
                },{
                    "id":"alpha-mini","displayName":"Alpha Mini",
                    "contextWindow":128000,"maxTokens":4096,
                    "thinkingLevels":["off","low"],
                    "supportsImages":false
                }],
                "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"
            }
            """#.utf8)), try! JSONDecoder().decode(RACPV2Provider.self, from: Data(#"""
            {
                "id":"prv_beta","name":"Beta Models","vendorKey":"custom-beta",
                "type":"openai_compatible","protocol":"openai_completions",
                "baseUrl":"https://beta.invalid","authKind":"api_key",
                "hasApiKey":true,"isDefault":false,"models":[{
                    "id":"beta-basic","displayName":"Beta Basic",
                    "contextWindow":32000,"maxTokens":4096,
                    "thinkingLevels":[],"supportsImages":false
                }],
                "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"
            }
            """#.utf8))]
        )
    }


    private static func onlineModelConfig() -> Self {
        let fixture = onlineProjectLifecycle()
        var state = fixture.state
        let hostID = state.hosts[0].id
        state.modelProviders = [
            StoredModelProvider(
                providerId: "prv_alpha",
                hostID: hostID,
                name: "Alpha Models",
                baseURL: "https://alpha.invalid",
                apiStyle: "chat_completions",
                models: [
                    StoredModelBinding(spec: ProviderModelSpec(
                        id: "alpha-pro",
                        contextWindow: 200_000,
                        maxTokens: 8_192,
                        thinkingLevels: ["off", "low", "high"],
                        defaultThinkingLevel: "low",
                        alias: "Alpha Pro"
                    )),
                ],
                defaultModelId: "alpha-pro",
                importedAt: Date(timeIntervalSince1970: 1_704_164_640)
            ),
            StoredModelProvider(
                providerId: "prv_beta",
                hostID: hostID,
                name: "Beta Models",
                baseURL: "https://beta.invalid",
                apiStyle: "chat_completions",
                models: [
                    StoredModelBinding(spec: ProviderModelSpec(
                        id: "beta-basic",
                        contextWindow: 32_000,
                        maxTokens: 4_096,
                        thinkingLevels: [],
                        alias: "Beta Basic"
                    )),
                ],
                defaultModelId: "beta-basic",
                importedAt: Date(timeIntervalSince1970: 1_704_164_640)
            ),
        ]
        var snapshots = fixture.sessionSnapshots
        if var running = snapshots["S2"] {
            running.activeItems = [
                RACPItem(id: "running-s2", payload: .object([
                    "id": .string("running-s2"),
                    "role": .string("assistant"),
                    "text": .string("S2 is running"),
                ])),
            ]
            running.runningTurnId = "turn-s2"
            snapshots["S2"] = running
        }
        return Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            sessionSnapshots: snapshots,
            providerBindingStatuses: [
                "S1": ProviderBindingStatus(
                    sessionId: "S1",
                    pinnedProviderId: "prv_alpha",
                    pinnedModelId: "alpha-pro",
                    pinnedThinkingLevel: "low",
                    effectiveProviderId: "prv_alpha",
                    effectiveModelId: "alpha-pro",
                    available: true,
                    unavailableReason: nil,
                    unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
                "S2": ProviderBindingStatus(
                    sessionId: "S2",
                    pinnedProviderId: "prv_beta",
                    pinnedModelId: "beta-basic",
                    pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_beta",
                    effectiveModelId: "beta-basic",
                    available: true,
                    unavailableReason: nil,
                    unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
            ],
            supportsFixtureInterrupt: true
        )
    }

    /// S1 正在运行 + 两条排队指令（一条有正文，一条只有附件数）：
    /// 验证「排队中（N）」、正文/附件数回退、取消按钮与输入栏排队提示可见。
    /// 排队项正文来自服务端快照的可选字段，夹具按 `QueuedTurn` 投影直接构造。
    private static func onlineQueuedTurns() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        guard var snapshot = fixture.sessionSnapshots[summary.id] else { return fixture }
        snapshot.runningTurnId = "turn-running-s1"
        snapshot.activeItems = [
            RACPItem(id: "fixture-queued-running-s1", payload: .object([
                "id": .string("fixture-queued-running-s1"),
                "role": .string("assistant"),
                "text": .string("S1 is running"),
            ])),
        ]
        snapshot.queuedTurns = [
            QueuedTurn(id: "turn-queued-1", text: "检查磁盘使用率"),
            QueuedTurn(id: "turn-queued-2", attachmentCount: 2),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    private static func onlineHostUnitActive() -> Self {
        var fixture = onlineProjectLifecycle()
        fixture.adaptorUnitSnapshot = AdaptorUnitSnapshot(
            loadState: "loaded",
            activeState: "active",
            unitFileState: "enabled"
        )
        fixture.connectionState = .online
        return fixture
    }

    private static func onlineHostUnitStopped() -> Self {
        var fixture = onlineProjectLifecycle()
        fixture.adaptorUnitSnapshot = AdaptorUnitSnapshot(
            loadState: "loaded",
            activeState: "inactive",
            unitFileState: "disabled"
        )
        fixture.connectionState = .offline(reason: "pi-adaptor systemd unit inactive")
        return fixture
    }

    private static func onlineDirectSSH() -> Self {
        directFixture(route: .ssh)
    }

    private static func onlineDirectActive() -> Self {
        directFixture(route: .direct)
    }

    private static func directFixture(route: ConnectionRoute) -> Self {
        var fixture = onlineProjectLifecycle()
        var state = fixture.state
        var host = state.hosts[0]
        host.directEndpoint = "wss://host.example:9443/v1/racp/ws"
        host.adaptorHostId = "host_fixture_direct"
        host.connectionPreference = .directPreferred
        state.hosts = [host]
        var configured = Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            catalogs: fixture.catalogs,
            sessionSnapshots: fixture.sessionSnapshots,
            providerBindingStatuses: fixture.providerBindingStatuses,
            adaptorUnitSnapshot: fixture.adaptorUnitSnapshot,
            connectionState: .online,
            updatableProviders: fixture.updatableProviders,
            directTrustPin: DirectTLSTrustPin(
                hostId: "host_fixture_direct",
                certificateSHA256: String(repeating: "a", count: 64),
                authorizedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            connectionStatus: ConnectionStatus(
                phase: .online(route),
                activeRoute: route
            )
        )
        configured.connectionState = .online
        return configured
    }

    private static func onlineTwoHosts() -> Self {
        let hostA = UUID(uuidString: "AAAAAAAA-1111-AAAA-1111-AAAAAAAAAAAA")!
        let hostB = UUID(uuidString: "BBBBBBBB-2222-BBBB-2222-BBBBBBBBBBBB")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let hosts = [
            HostRecord(
                id: hostA, name: "Fixture Online PI-adaptor A", host: "fixture-oa.invalid",
                port: 22, username: "fixture", authKind: .privateKey,
                createdAt: time, isCurrent: false, pairedAt: time
            ),
            HostRecord(
                id: hostB, name: "Fixture Online PI-adaptor B", host: "fixture-ob.invalid",
                port: 22, username: "fixture", authKind: .privateKey,
                createdAt: time, isCurrent: true, pairedAt: time
            ),
        ]
        let projectA = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"A-project","label":"PI-adaptor A Project","archived":false}]}"#.utf8)
        ).projects
        let projectB = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"B-project","label":"PI-adaptor B Project","archived":false}]}"#.utf8)
        ).projects
        let sessionA = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"A-session","title":"PI-adaptor A Session","projectId":"A-project","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let sessionB = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"B-session","title":"PI-adaptor B Session","projectId":"B-project","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let catalogA = Catalog(
            projects: projectA, sessions: sessionA,
            info: RACPServerInfo(
                protocolVersion: "1", serverName: "Fixture Online A",
                serverVersion: "fixture-only", hostId: hostA.uuidString,
                connectionId: "fixture-online-a", roles: []
            )
        )
        let catalogB = Catalog(
            projects: projectB, sessions: sessionB,
            info: RACPServerInfo(
                protocolVersion: "1", serverName: "Fixture Online B",
                serverVersion: "fixture-only", hostId: hostB.uuidString,
                connectionId: "fixture-online-b", roles: []
            )
        )
        let state = PersistedState(
            hosts: hosts,
            modelProviders: [
                StoredModelProvider(
                    providerId: "prv_host_a",
                    hostID: hostA,
                    name: "PI-adaptor A Models",
                    baseURL: "https://host-a.invalid",
                    apiStyle: "chat_completions",
                    models: [StoredModelBinding(spec: ProviderModelSpec(
                        id: "model-a", contextWindow: 32_000, maxTokens: 4_096,
                        thinkingLevels: [], alias: "Model A"
                    ))],
                    defaultModelId: "model-a",
                    importedAt: time
                ),
                StoredModelProvider(
                    providerId: "prv_host_b",
                    hostID: hostB,
                    name: "PI-adaptor B Models",
                    baseURL: "https://host-b.invalid",
                    apiStyle: "chat_completions",
                    models: [StoredModelBinding(spec: ProviderModelSpec(
                        id: "model-b", contextWindow: 64_000, maxTokens: 8_096,
                        thinkingLevels: [], alias: "Model B"
                    ))],
                    defaultModelId: "model-b",
                    importedAt: time
                ),
            ],
            lastSessionId: "B-session",
            lastProjectId: "B-project",
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostA, projectID: "A-project", path: "/fixture/a",
                    name: "PI-adaptor A Project", createdAt: time, updatedAt: time
                ),
                StoredProjectBinding(
                    hostID: hostB, projectID: "B-project", path: "/fixture/b",
                    name: "PI-adaptor B Project", createdAt: time, updatedAt: time
                ),
            ],
            sessionBindings: [
                StoredSessionBinding(
                    hostID: hostA, sessionID: "A-session", projectID: "A-project",
                    lastActivityAt: time, lastKnownRevision: 1, updatedAt: time
                ),
                StoredSessionBinding(
                    hostID: hostB, sessionID: "B-session", projectID: "B-project",
                    lastActivityAt: time, lastKnownRevision: 1, updatedAt: time
                ),
            ],
            lastSessionByHost: [hostA.uuidString: "A-session", hostB.uuidString: "B-session"],
            lastProjectByHost: [hostA.uuidString: "A-project", hostB.uuidString: "B-project"]
        )
        var snapshots: [String: RACPSessionView] = [:]
        for (summary, title) in [(sessionA[0], "PI-adaptor A Session"), (sessionB[0], "PI-adaptor B Session")] {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-\(summary.id)", sequence: 1)
            snapshot.items = [
                RACPItem(id: "\(summary.id)-item", payload: .object([
                    "id": .string("\(summary.id)-item"),
                    "role": .string("assistant"),
                    "text": .string("\(title) history"),
                ])),
            ]
            snapshots[summary.id] = snapshot
        }
        return Self(
            state: state,
            cache: OfflineSessionCacheSnapshot(),
            catalogs: [hostA: catalogA, hostB: catalogB],
            sessionSnapshots: snapshots,
            providerBindingStatuses: [
                "A-session": ProviderBindingStatus(
                    sessionId: "A-session", pinnedProviderId: "prv_host_a",
                    pinnedModelId: "model-a", pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_host_a", effectiveModelId: "model-a",
                    available: true, unavailableReason: nil, unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
                "B-session": ProviderBindingStatus(
                    sessionId: "B-session", pinnedProviderId: "prv_host_b",
                    pinnedModelId: "model-b", pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_host_b", effectiveModelId: "model-b",
                    available: true, unavailableReason: nil, unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
            ]
        )
    }

    private static func onlineTwoSessions() -> Self {
        let hostID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projectID = "fixture-online-project"
        let projects = try! JSONDecoder().decode(RACPProjectListResult.self, from: Data(#"{"projects":[{"id":"fixture-online-project","label":"Fixture Workspace","archived":false}]}"#.utf8)).projects
        let sessions = try! JSONDecoder().decode(RACPSessionListResult.self, from: Data(#"{"sessions":[{"id":"S1","title":"Fixture S1 Alpha","projectId":"fixture-online-project","status":"idle","revision":1},{"id":"S2","title":"Fixture S2 Beta","projectId":"fixture-online-project","status":"running","revision":1}]}"#.utf8)).sessions
        let host = HostRecord(
            id: hostID, name: "Fixture Online PI-adaptor", host: "fixture-online.invalid",
            port: 22, username: "fixture", authKind: .privateKey,
            createdAt: time, isCurrent: true, pairedAt: time
        )
        let state = PersistedState(
            hosts: [host], lastSessionId: "S1", lastProjectId: projectID,
            projectBindings: [StoredProjectBinding(
                hostID: hostID, projectID: projectID, path: "/fixture/online",
                name: "Fixture Workspace", createdAt: time, updatedAt: time
            )],
            sessionBindings: sessions.enumerated().map { index, session in
                StoredSessionBinding(
                    hostID: hostID, sessionID: session.id, projectID: projectID,
                    messageCount: index + 1,
                    lastActivityAt: time.addingTimeInterval(Double(index) * 60),
                    lastKnownRevision: 1, updatedAt: time
                )
            },
            lastSessionByHost: [hostID.uuidString: "S1"],
            lastProjectByHost: [hostID.uuidString: projectID]
        )
        var fixture = Self(
            state: state, cache: OfflineSessionCacheSnapshot(),
            catalog: Catalog(
                projects: projects, sessions: sessions,
                info: RACPServerInfo(
                    protocolVersion: "1", serverName: "UI Fixture",
                    serverVersion: "fixture-only", hostId: hostID.uuidString,
                    connectionId: "fixture-connection", roles: [],
                    piVersion: "1.6.0"
                )
            )
        )
        fixture.supportsFixtureRevoke = true
        for summary in sessions {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-online-\(summary.id)", sequence: 1)
            snapshot.items = [
                RACPItem(id: "fixture-online-item-\(summary.id)", payload: .object([
                    "id": .string("fixture-online-item-\(summary.id)"),
                    "role": .string("assistant"),
                    "text": .string("Fixture history for \(summary.id)"),
                ])),
            ]
            if summary.id == "S2" {
                snapshot.activeItems = [
                    RACPItem(id: "fixture-online-running-s2", payload: .object([
                        "id": .string("fixture-online-running-s2"),
                        "role": .string("assistant"),
                        "text": .string("S2 is running"),
                    ])),
                ]
                snapshot.runningTurnId = "turn-s2"
            }
            fixture.sessionSnapshots[summary.id] = snapshot
        }
        return fixture
    }
#endif

    private static func offlineTwoHosts() -> Self {
#if DEBUG
        let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let originalTime = Date(timeIntervalSince1970: 1_704_164_640)
        var state = PersistedState()
        var cache = OfflineSessionCacheSnapshot()

        for (hostID, suffix) in [(hostA, "A"), (hostB, "B")] {
            let projectID = "fixture-project-\(suffix)"
            let sessionID = "fixture-session-\(suffix)"
            state.hosts.append(HostRecord(
                id: hostID,
                name: "Fixture PI-adaptor \(suffix)",
                host: "fixture-\(suffix.lowercased()).invalid",
                port: 22,
                username: "fixture",
                authKind: .privateKey,
                createdAt: originalTime,
                isCurrent: hostID == hostB,
                pairedAt: originalTime
            ))
            state.projectBindings.append(StoredProjectBinding(
                hostID: hostID, projectID: projectID, path: "/fixture/\(suffix)",
                name: "Fixture Project \(suffix)",
                createdAt: originalTime, updatedAt: originalTime
            ))
            state.lastProjectByHost[hostID.uuidString] = projectID
            state.lastSessionByHost[hostID.uuidString] = sessionID

            for id in [sessionID, "fixture-shared-session"] {
                let shared = id == "fixture-shared-session"
                let title = "Fixture \(suffix) \(shared ? "shared" : "private") title"
                // The newest cache row intentionally differs from lastSessionByHost.
                let time = originalTime.addingTimeInterval(shared ? 60 : 0)
                state.sessionBindings.append(StoredSessionBinding(
                    hostID: hostID, sessionID: id, projectID: projectID,
                    titleOverride: title, lastActivityAt: time, updatedAt: time
                ))
                cache.entries.append(OfflineSessionCacheEntry(
                    id: "fixture-item", sessionId: id, hostID: hostID,
                    text: "Fixture \(suffix) \(shared ? "shared" : "private") history", createdAt: time
                ))
                if hostID == hostB && !shared {
                    // 无正文工具行：复制结果应为空，不得拿显示 fallback 冒充原文。
                    cache.entries.append(OfflineSessionCacheEntry(
                        id: "fixture-empty-tool", sessionId: id, hostID: hostID,
                        text: "", createdAt: time.addingTimeInterval(1),
                        kind: "tool", role: "tool", toolName: "bash", sequence: 8
                    ))
                }
                cache.cursors.append(OfflineSessionCursor(
                    hostID: hostID, sessionId: id, epoch: "fixture-\(suffix)",
                    sequence: 7, updatedAt: time
                ))
                cache.approvals.append(OfflineSessionApproval(
                    id: "fixture-approval", sessionId: id, hostID: hostID,
                    payload: .object(["summary": .string("Fixture \(suffix) approval")]),
                    revision: 7, status: "pending", decision: nil, createdAt: time
                ))
                cache.drafts.append(OfflineSessionDraft(
                    hostID: hostID, sessionId: id, text: "Fixture \(suffix) unsent draft",
                    idempotencyKey: "fixture-\(suffix)-\(id)", updatedAt: time
                ))
            }
        }
        state.lastSessionId = state.lastSessionByHost[hostB.uuidString]
        state.lastProjectId = state.lastProjectByHost[hostB.uuidString]
        return Self(state: state, cache: cache)
#else
        fatalError("UI test fixtures are unavailable in release builds")
#endif
    }

    private static func offlineCache205() -> Self {
#if DEBUG
        let hostID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projectID = "fixture-cache-project"
        let sessionID = "fixture-cache-session"
        let host = HostRecord(
            id: hostID,
            name: "Fixture Cache PI-adaptor",
            host: "fixture-cache.invalid",
            port: 22,
            username: "fixture",
            authKind: .privateKey,
            createdAt: time,
            isCurrent: true,
            pairedAt: time
        )
        var state = PersistedState(
            hosts: [host],
            lastSessionId: sessionID,
            lastProjectId: projectID,
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostID,
                    projectID: projectID,
                    path: "/fixture/cache",
                    name: "Fixture Cache Project",
                    createdAt: time,
                    updatedAt: time
                ),
            ],
            sessionBindings: [
                StoredSessionBinding(
                    hostID: hostID,
                    sessionID: sessionID,
                    projectID: projectID,
                    lastActivityAt: time,
                    updatedAt: time
                ),
            ],
            lastSessionByHost: [hostID.uuidString: sessionID],
            lastProjectByHost: [hostID.uuidString: projectID]
        )
        state.offlineCacheLimit = 200
        var cache = OfflineSessionCacheSnapshot()
        // 205 个完整轮次，每轮 user + assistant 并共享 turnId。默认保留 200 轮，
        // 因而 001…005 必须整轮淘汰，006…205 必须整轮保留。
        cache.entries = (1...205).flatMap { index in
            let number = String(format: "%03d", index)
            let turnID = "cache-turn-\(number)"
            return [
                OfflineSessionCacheEntry(
                    id: "cache-user-\(number)",
                    sessionId: sessionID,
                    hostID: hostID,
                    text: "Cache item \(number)",
                    createdAt: time.addingTimeInterval(Double(index * 2)),
                    role: "user",
                    sequence: index * 2,
                    turnId: turnID
                ),
                OfflineSessionCacheEntry(
                    id: "cache-assistant-\(number)",
                    sessionId: sessionID,
                    hostID: hostID,
                    text: "Cache reply \(number)",
                    createdAt: time.addingTimeInterval(Double(index * 2 + 1)),
                    role: "assistant",
                    sequence: index * 2 + 1,
                    turnId: turnID
                ),
            ]
        }
        cache.cursors = [
            OfflineSessionCursor(
                hostID: hostID,
                sessionId: sessionID,
                epoch: "fixture-cache",
                sequence: 410,
                updatedAt: time
            ),
        ]
        return Self(state: state, cache: cache)
#else
        fatalError("UI test fixtures are unavailable in release builds")
#endif
    }
}
