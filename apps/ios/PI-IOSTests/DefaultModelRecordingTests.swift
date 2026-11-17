import Foundation
import XCTest
import PIiOSCore

@testable import PI_IOS

/// 默认模型是 host 级单选项：用户点「设为默认」后必须真正落到本机记录，
/// 而不是被本机旧默认覆盖；编辑服务信息等旁路操作也不能顺手改默认。
///
/// 回归的是真实故障：ModelProviderDetailSheet 的「设为默认」在写本机记录时，
/// `AppModel.recordImportedProvider` 用 previousDefault 覆盖了这次明确选择，
/// 详情页本地快照看似切换、退出后设置页仍是旧默认。
@MainActor
final class DefaultModelRecordingTests: XCTestCase {
    private var root: URL!
    private var stateURL: URL!
    private var logStore: PILogger!
    private let hostID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateURL = root.appendingPathComponent(StateFile.fileName)
        logStore = PILogger(directoryURL: root.appendingPathComponent("logs", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 用户明确选择

    func testExplicitDefaultUpdatesRecordAndMovesHostDefault() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro", "alpha-mini"]),
            provider("prv_beta", defaultModel: nil, models: ["beta-basic"]),
        ])
        let target = try XCTUnwrap(model.storedProvider(hostID: hostID, providerId: "prv_beta"))

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: createInput(provider: target, defaultModelId: "beta-basic"),
            providerId: "prv_beta",
            serverDefaultSet: false,
            legacyProviderId: nil,
            hostV2Mirror: true
        ))

        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_beta")?.defaultModelId,
            "beta-basic",
            "点「设为默认」后本机记录必须切到新模型"
        )
        XCTAssertNil(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "同一 Host 上只能有一个默认模型：旧默认必须让位"
        )
        XCTAssertTrue(model.defaultModelLabel.contains("Beta Models"), "设置页标签应显示新默认：\(model.defaultModelLabel)")

        let reloaded = StateFile.load(from: stateURL)
        XCTAssertEqual(
            reloaded.state.modelProviders.first { $0.providerId == "prv_beta" }?.defaultModelId,
            "beta-basic",
            "默认模型必须写进 state 文件，重启后仍生效"
        )
        XCTAssertNil(
            reloaded.state.modelProviders.first { $0.providerId == "prv_alpha" }?.defaultModelId
        )
    }

    func testExplicitDefaultWinsOverStalePreviousDefaultWithinSameProvider() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro", "alpha-mini"]),
        ])

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: ProviderCreateInput(
                name: "Alpha Models",
                vendorKey: "custom",
                type: "openai_compatible",
                protocol: "openai_completions",
                authKind: "api_key",
                baseUrl: "https://alpha.invalid",
                models: [spec("alpha-pro"), spec("alpha-mini")],
                defaultModelId: "alpha-mini"
            ),
            providerId: "prv_alpha",
            serverDefaultSet: false,
            hostV2Mirror: true
        ))

        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "alpha-mini",
            "同一 provider 内切默认也必须生效，不能被旧默认覆盖"
        )
    }

    // MARK: - 旁路操作不得改默认

    func testEditingServiceWithoutExplicitDefaultKeepsDefaultUnchanged() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro"]),
            provider("prv_beta", defaultModel: nil, models: ["beta-basic"]),
        ])
        let target = try XCTUnwrap(model.storedProvider(hostID: hostID, providerId: "prv_beta"))

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: createInput(provider: target, defaultModelId: nil),
            providerId: "prv_beta",
            serverDefaultSet: true,
            legacyProviderId: nil,
            hostV2Mirror: true
        ))

        XCTAssertNil(
            model.storedProvider(hostID: hostID, providerId: "prv_beta")?.defaultModelId,
            "编辑一条本来没有默认的服务，不能把首项模型变成默认"
        )
        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "alpha-pro",
            "已有默认模型不得被旁路操作抢走"
        )
    }

    func testRemovingDefaultModelFallsBackWithinSameProvider() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro", "alpha-mini"]),
        ])

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: ProviderCreateInput(
                name: "Alpha Models",
                vendorKey: "custom",
                type: "openai_compatible",
                protocol: "openai_completions",
                authKind: "api_key",
                baseUrl: "https://alpha.invalid",
                models: [spec("alpha-mini")],
                defaultModelId: nil
            ),
            providerId: "prv_alpha",
            serverDefaultSet: false,
            hostV2Mirror: true
        ))

        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "alpha-mini",
            "原默认模型被移出清单时，默认项应在同一 provider 内转移"
        )
    }

    func testInvalidExplicitDefaultKeepsPreviousDefault() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro"]),
        ])

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: ProviderCreateInput(
                name: "Alpha Models",
                vendorKey: "custom",
                type: "openai_compatible",
                protocol: "openai_completions",
                authKind: "api_key",
                baseUrl: "https://alpha.invalid",
                models: [spec("alpha-pro")],
                defaultModelId: "ghost-model"
            ),
            providerId: "prv_alpha",
            serverDefaultSet: false,
            hostV2Mirror: true
        ))

        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "alpha-pro",
            "不存在的显式默认必须被忽略，保留本机原默认"
        )
    }

    // MARK: - 新会话默认绑定

    func testDefaultSelectionExposesProviderModelAndThinking() throws {
        var alpha = provider("prv_alpha", defaultModel: "alpha-mini", models: ["alpha-pro", "alpha-mini"])
        alpha.models[0].thinkingLevels = ["off", "low"]
        alpha.models[0].defaultThinkingLevel = nil
        alpha.models[1].thinkingLevels = ["off", "low"]
        alpha.models[1].defaultThinkingLevel = "low"
        alpha.models[1].alias = "Alpha Mini"
        let model = makeModel(providers: [alpha])

        let selection = try XCTUnwrap(model.defaultModelSelection)
        XCTAssertEqual(selection.providerId, "prv_alpha")
        XCTAssertEqual(selection.modelId, "alpha-mini")
        XCTAssertEqual(selection.thinkingLevel, "low")
        XCTAssertTrue(selection.label.contains("Alpha Mini"))
        XCTAssertEqual(model.defaultModelSelectionForNewSession?.modelId, "alpha-mini")
    }

    func testLegacyOnlyProviderIsNotUsedForNewSessionBinding() {
        var legacy = provider("prv_legacy", defaultModel: "legacy-mini", models: ["legacy-mini"])
        legacy.hostV2Mirror = false
        let model = makeModel(providers: [legacy])

        XCTAssertEqual(model.defaultModelLabel, "未配置")
        XCTAssertNil(
            model.defaultModelSelectionForNewSession,
            "只存在旧 SSH 存储的服务不能作为新会话绑定，否则会话一创建就不可用"
        )
    }

    // MARK: - 首条导入

    func testFirstProviderImportUsesServerDefaultModel() throws {
        let model = makeModel(providers: [])

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: ProviderCreateInput(
                name: "First Models",
                vendorKey: "custom",
                type: "openai_compatible",
                protocol: "openai_completions",
                authKind: "api_key",
                baseUrl: "https://first.invalid",
                models: [spec("first-a"), spec("first-b")],
                defaultModelId: nil
            ),
            providerId: "prv_first",
            serverDefaultSet: true,
            hostV2Mirror: true
        ))

        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_first")?.defaultModelId,
            "first-a",
            "首条导入且服务端设置默认时，本机应有一个默认模型"
        )
    }

    func testSecondProviderImportDoesNotStealDefault() throws {
        let model = makeModel(providers: [
            provider("prv_alpha", defaultModel: "alpha-pro", models: ["alpha-pro"]),
        ])

        XCTAssertTrue(model.recordImportedProvider(
            context: try operationContext(model),
            input: ProviderCreateInput(
                name: "Beta Models",
                vendorKey: "custom",
                type: "openai_compatible",
                protocol: "openai_completions",
                authKind: "api_key",
                baseUrl: "https://beta.invalid",
                models: [spec("beta-basic")],
                defaultModelId: nil
            ),
            providerId: "prv_beta",
            serverDefaultSet: true,
            hostV2Mirror: true
        ))

        XCTAssertNil(
            model.storedProvider(hostID: hostID, providerId: "prv_beta")?.defaultModelId,
            "第二条服务导入不能抢走已有默认"
        )
        XCTAssertEqual(
            model.storedProvider(hostID: hostID, providerId: "prv_alpha")?.defaultModelId,
            "alpha-pro"
        )
    }

    // MARK: - Helpers

    private func makeModel(providers: [StoredModelProvider]) -> AppModel {
        let host = HostRecord(
            id: hostID,
            name: "Test Host",
            host: "127.0.0.1",
            port: 22,
            username: "tester",
            authKind: .password,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCurrent: true,
            pairedAt: nil
        )
        let seed = PersistedState(hosts: [host], modelProviders: providers)
        return AppModel(seed: seed, stateFileURL: stateURL, logStore: logStore)
    }

    private func operationContext(_ model: AppModel) throws -> ProviderOperationContext {
        let host = try XCTUnwrap(model.currentHost)
        return try XCTUnwrap(model.providerOperationContext(for: host))
    }

    private func createInput(
        provider: StoredModelProvider,
        defaultModelId: String?
    ) -> ProviderCreateInput {
        ProviderCreateInput(
            name: provider.name,
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_completions",
            authKind: "api_key",
            baseUrl: provider.baseURL,
            models: provider.models.map(\.providerSpec),
            defaultModelId: defaultModelId
        )
    }

    private func provider(
        _ providerId: String,
        defaultModel: String?,
        models: [String]
    ) -> StoredModelProvider {
        StoredModelProvider(
            providerId: providerId,
            hostV2Mirror: true,
            hostID: hostID,
            name: providerId == "prv_alpha" ? "Alpha Models" : "Beta Models",
            baseURL: "https://\(providerId).invalid",
            apiStyle: "chat_completions",
            models: models.map { StoredModelBinding(spec: spec($0)) },
            defaultModelId: defaultModel,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func spec(_ id: String) -> ProviderModelSpec {
        ProviderModelSpec(
            id: id,
            contextWindow: 128_000,
            maxTokens: 8_192,
            thinkingLevels: ["off", "low"],
            alias: id
        )
    }
}
