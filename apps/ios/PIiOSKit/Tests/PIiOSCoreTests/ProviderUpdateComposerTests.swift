import XCTest

@testable import PIiOSCore

final class ProviderUpdateComposerTests: XCTestCase {
    func testUpdatesAllModelsWithoutReplacingSecretOrProviderIdentity() throws {
        let existing = try Self.provider()
        let models = [
            Self.model(id: "alpha-next", alias: "Alpha Next", context: 300_000, output: 24_000),
            Self.model(id: "alpha-mini", alias: "Alpha Mini", context: 32_000, output: 4_096),
        ]
        let result = ProviderUpdateComposer.compose(existing: existing, input: ProviderUpdateInput(
            name: " Alpha Updated ", baseURL: " https://alpha.invalid/v2 ",
            apiKey: "  ", models: models, defaultModelID: "removed-model"
        ))

        XCTAssertTrue(result.isValid, "\(result.issues)")
        let fields = try XCTUnwrap(result.fields.objectValue)
        XCTAssertNil(fields["apiKey"], "密钥留空必须省略 apiKey，让 PI-adaptor 保留原密钥")
        XCTAssertEqual(fields["vendorKey"], .string("original-vendor"))
        XCTAssertEqual(fields["protocol"], .string("openai_completions"))
        XCTAssertEqual(fields["authKind"], .string("api_key"))
        let encoded = try XCTUnwrap(fields["models"]?.arrayValue)
            .map { try RACPV2ProviderModel.decoded(from: $0) }
        XCTAssertEqual(encoded.map(\.id), ["alpha-next", "alpha-mini"])
        XCTAssertEqual(encoded[0].displayName, "Alpha Next")
        XCTAssertEqual(encoded[0].contextWindow, 300_000)
        XCTAssertEqual(encoded[0].maxTokens, 24_000)
        XCTAssertEqual(encoded[0].thinkingLevels, ["off", "low", "high"])
        XCTAssertEqual(encoded[0].defaultThinkingLevel, "high")
        XCTAssertTrue(encoded[0].supportsImages)
        XCTAssertEqual(result.input.defaultModelID, "alpha-next")
    }

    func testPreservesUneditedSecondModelAndDefaultModel() throws {
        let existing = try Self.provider()
        let composition = ProviderUpdateComposer.compose(existing: existing, input: ProviderUpdateInput(
            name: "Alpha", baseURL: existing.baseUrl, apiKey: nil,
            models: existing.models.map(ProviderUpdateComposer.modelSpec),
            defaultModelID: "second"
        ))

        XCTAssertTrue(composition.isValid, "\(composition.issues)")
        let models = try XCTUnwrap(composition.fields.objectValue?["models"]?.arrayValue)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[1].value(at: ["contextWindow"]), .number(65_536))
        XCTAssertEqual(models[1].value(at: ["maxTokens"]), .number(4_096))
        XCTAssertEqual(models[1].value(at: ["defaultThinkingLevel"]), .string("low"))
        XCTAssertEqual(composition.input.defaultModelID, "second")
    }

    func testRejectsDuplicateModelsAndInvalidThinkingDefault() throws {
        let existing = try Self.provider()
        var duplicate = Self.model(id: "same", alias: "same", context: 128_000, output: 8_192)
        duplicate.thinkingLevels = ["off", "low"]
        duplicate.defaultThinkingLevel = "high"
        let composition = ProviderUpdateComposer.compose(existing: existing, input: ProviderUpdateInput(
            name: "Alpha", baseURL: existing.baseUrl,
            models: [duplicate, duplicate], defaultModelID: "same"
        ))

        XCTAssertFalse(composition.isValid)
        XCTAssertTrue(composition.issues.contains { $0.kind == .duplicateValue })
        XCTAssertTrue(composition.issues.contains { $0.kind == .defaultNotInList })
    }

    func testExplicitWhitespaceSecretIsRejectedRatherThanSilentlyRetained() throws {
        let existing = try Self.provider()
        let composition = ProviderUpdateComposer.compose(existing: existing, input: ProviderUpdateInput(
            name: existing.name, baseURL: existing.baseUrl, apiKey: " \t ",
            models: existing.models.map(ProviderUpdateComposer.modelSpec)
        ))

        XCTAssertFalse(composition.isValid)
        XCTAssertTrue(composition.issues.contains { $0.path.hasSuffix(".secretValue") })
        XCTAssertNil(composition.fields.objectValue?["apiKey"])
    }


    func testModelSpecPreservesSecondaryModelCapabilities() throws {
        let model = try Self.provider().models[1]
        let spec = ProviderUpdateComposer.modelSpec(model)
        XCTAssertEqual(spec.contextWindow, 65_536)
        XCTAssertEqual(spec.maxTokens, 4_096)
        XCTAssertEqual(spec.thinkingLevels, ["off", "low"])
        XCTAssertEqual(spec.defaultThinkingLevel, "low")
        XCTAssertEqual(spec.alias, "Second")
        XCTAssertEqual(spec.supportsImages, false)
    }

    private static func model(id: String, alias: String, context: Int, output: Int) -> ProviderModelSpec {
        ProviderModelSpec(
            id: id, contextWindow: context, maxTokens: output,
            thinkingLevels: ["off", "low", "high"], defaultThinkingLevel: "high",
            alias: alias, supportsImages: true
        )
    }

    private static func provider() throws -> RACPV2Provider {
        try JSONDecoder().decode(RACPV2Provider.self, from: Data(#"""
        {
            "id":"prv_1","name":"Alpha","vendorKey":"original-vendor",
            "type":"openai_compatible","protocol":"openai_completions",
            "baseUrl":"https://alpha.invalid/v1","authKind":"api_key",
            "hasApiKey":true,"isDefault":true,"models":[
                {"id":"first","displayName":"First","contextWindow":200000,
                 "maxTokens":8192,"thinkingLevels":["off","high"],
                 "defaultThinkingLevel":"high","supportsImages":false},
                {"id":"second","displayName":"Second","contextWindow":65536,
                 "maxTokens":4096,"thinkingLevels":["off","low"],
                 "defaultThinkingLevel":"low","supportsImages":false}
            ],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"
        }
        """#.utf8))
    }
}
