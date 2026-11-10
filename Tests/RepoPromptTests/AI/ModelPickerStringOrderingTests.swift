import Darwin
import RepoPromptSettingsCore
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class ModelPickerStringOrderingTests: XCTestCase {
    func testScalarOrderingUsesAsciiFoldThenRawScalarTieBreak() {
        XCTAssertEqual(
            ModelPickerStringOrdering.compare("GPT-5", "gpt-5", caseInsensitiveASCII: true),
            .orderedAscending
        )
        XCTAssertEqual(
            ["ı", "i", "I"].sorted { ModelPickerStringOrdering.precedes($0, $1) },
            ["I", "i", "ı"]
        )
    }

    func testSemanticOrderingUsesVersionEffortAndFamilyBeforeDisplayName() {
        let codexModels: [AIModel] = [
            .codexCustom(name: "gpt-5.2-high"),
            .codexCustom(name: "gpt-5.4-fast-high"),
            .codexCustom(name: "gpt-5.4-low")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(codexModels).map(\.modelName), [
            "gpt-5.4-low",
            "gpt-5.4-fast-high",
            "gpt-5.2-high"
        ])

        let customModels: [AIModel] = [
            .customProvider(name: "Aardvark", provider: "custom", model: "zzz-1"),
            .customProvider(name: "Zed", provider: "custom", model: "aaa-1")
        ]
        XCTAssertEqual(AIModel.sortedForPicker(customModels).map(\.modelName), ["aaa-1", "zzz-1"])
    }

    func testDistinctCompatibleClaudeModelsWithEqualSortKeysPreserveInputOrder() {
        let defaults = UserDefaults.standard
        let key = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let implicit = AIModel.claudeCodeModel(specifier: "compatible:glmzai")
        let explicit = AIModel.claudeCodeModel(specifier: "compatible:glmzai:sonnet")
        XCTAssertNotEqual(implicit, explicit)
        XCTAssertNotEqual(implicit.rawValue, explicit.rawValue)
        XCTAssertEqual(implicit.displayName, explicit.displayName)
        XCTAssertFalse(AIModel.pickerSortComparator(implicit, explicit))
        XCTAssertFalse(AIModel.pickerSortComparator(explicit, implicit))
        XCTAssertEqual(AIModel.sortedForPicker([implicit, explicit]), [implicit, explicit])
        XCTAssertEqual(AIModel.sortedForPicker([explicit, implicit]), [explicit, implicit])
    }

    func testIdenticalPickerInputObservesDynamicStoreIdentityChanges() {
        let defaults = UserDefaults.standard
        let key = "CodexDynamicModelRecords"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            _ = CodexDynamicModelStore.load()
        }
        let high = AIModel.codexCustom(name: "gpt-5.5-high")
        let low = AIModel.codexCustom(name: "gpt-5.5-low")
        let input = [high, low]
        CodexDynamicModelStore.save([])
        XCTAssertEqual(AIModel.sortedForPicker(input), [low, high])
        CodexDynamicModelStore.save([
            .init(
                id: "gpt-5.5-high",
                model: "gpt-5.5-high",
                displayName: "Literal Identity",
                description: "",
                isDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            )
        ])
        XCTAssertEqual(AIModel.sortedForPicker(input), [high, low])
        CodexDynamicModelStore.save([])
        XCTAssertEqual(AIModel.sortedForPicker(input), [low, high])
    }

    func testIndexedCodexParsingAndLabelsMatchRecordBasedResolution() {
        var rng = SnapshotRNG()
        let ids = ["future", " FUTURE ", "future-max", "future-high", "gpt-5.6-sol", "gpt-5.6-sol-ultra", "é", "e\u{301}", ""]
        let efforts = ["low", "medium", "high", "max", "maximum", "ultra", "unknown"]
        for _ in 0 ..< 30 {
            let records = (0 ..< 8).map { index in
                let id = ids[Int(rng.next() % UInt64(ids.count))]
                return CodexDynamicModelRecord(
                    id: id, model: id, displayName: index.isMultiple(of: 3) ? "" : "Fixture \(index)", description: "",
                    isDefault: false,
                    supportedReasoningEfforts: [0, 1].map { _ in .init(reasoningEffort: efforts[Int(rng.next() % UInt64(efforts.count))], description: "") },
                    defaultReasoningEffort: index.isMultiple(of: 2) ? "ultra" : nil,
                    serviceTiers: [.init(id: "ultrafast", name: "Special Speed", description: "")]
                )
            }
            let discovery = CodexModelDiscovery(records: records)
            let labels = CodexDynamicModelMapper.displayNameIndex(discovery: discovery)
            let queries = ["", "default", " DEFAULT ", "future-maximum", "gpt-5.1-codex-max-high"]
                + ids.flatMap { id in [id, " \(id.uppercased()) "] + efforts.map { "\(id)-\($0)" } + ["\(id)-ultrafast-high", "\(id)-fast-max"] }
            for raw in queries {
                let indexed = CodexModelSpecifier(raw: raw, discovery: discovery)
                let legacy = CodexModelSpecifier(raw: raw, discoveredRecords: records)
                XCTAssertEqual(indexed, legacy, raw)
                XCTAssertEqual(indexed.baseModel.map { Array($0.utf8) }, legacy.baseModel.map { Array($0.utf8) }, raw)
                XCTAssertEqual(
                    labels[CodexModelIdentity.key(raw)].map { Array($0.utf8) },
                    CodexDynamicModelMapper.displayName(forModelID: raw, records: records).map { Array($0.utf8) }, raw
                )
            }
        }
    }

    func testSnapshotOptionIndexesRetainFirstMatchWhitespaceAndUnicodeRules() {
        for ids in [[" foo ", "foo", "FOO", "STRASSE"], ["Straße", "STRASSE", "é", "e\u{301}", "İ", "i\u{307}", "Σ", "ς"]] {
            let options = ids.enumerated().map { Self.snapshotOption($0.element, "Label \($0.offset)") }
            let queries = ids + [" FOO ", "foo", "straße", "STRASSE", "É", "i", "σ", "", "missing"]
            let labels = AIModelPickerSnapshot.optionLabels(queries: queries, options: options)
            for raw in queries {
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = normalized.isEmpty ? nil : options.first { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }?.displayName
                XCTAssertEqual(labels[raw], expected, raw)
            }
        }
    }

    func testPickerSnapshotReadsEachNeededSourceOnceAndRefreshesNextInvocation() {
        let cases: [(String, (String) -> AIModel)] = [
            ("openCode", { .openCodeCustom(name: $0) }), ("grokBuild", { .grokBuildCustom(name: $0) }),
            ("devin", { .devinCustom(name: $0) }), ("cursor", { .cursorCustom(name: $0) })
        ]
        for (source, make) in cases {
            let fixture = SnapshotFixture()
            fixture.options = [Self.snapshotOption("fixture-1-a", "Model High"), Self.snapshotOption("fixture-1-b", "Model Low")]
            let a = make("fixture-1-a"), b = make("fixture-1-b")
            XCTAssertEqual(AIModel.sortedForPicker([a, b, a], sources: fixture.sources), [b, a, a])
            XCTAssertEqual(fixture.reads, ["codex": 1, source: 1])
            fixture.options = [Self.snapshotOption("fixture-1-a", "Model Low"), Self.snapshotOption("fixture-1-b", "Model High")]
            fixture.reads = [:]
            XCTAssertEqual(AIModel.sortedForPicker([a, b], sources: fixture.sources), [a, b])
            XCTAssertEqual(fixture.reads, ["codex": 1, source: 1])
        }
        let fixture = SnapshotFixture()
        let high = AIModel.codexCustom(name: "gpt-5.5-high"), low = AIModel.codexCustom(name: "gpt-5.5-low")
        XCTAssertEqual(AIModel.sortedForPicker([high, low], sources: fixture.sources), [low, high])
        fixture.records = [.init(id: "gpt-5.5-high", model: "gpt-5.5-high", displayName: "Literal Identity", description: "", isDefault: false)]
        fixture.reads = [:]
        XCTAssertEqual(AIModel.sortedForPicker([high, low], sources: fixture.sources), [high, low])
        XCTAssertEqual(fixture.reads, ["codex": 1])
    }

    func testPickerSnapshotDoesNotReadUnusedSourcesAndCapturesWrappedOllamaOnce() {
        let fixture = SnapshotFixture()
        for input: [AIModel] in [[], [.gpt61Sol], [.gpt61Sol, .openCodeCustom(name: "one")]] {
            _ = AIModel.sortedForPicker(input, sources: fixture.sources)
            XCTAssertTrue(fixture.reads.isEmpty)
        }
        let input: [AIModel] = [.ollama, .openAIServiceTierVariant(base: .ollama, tier: "priority")]
        let snapshot = AIModelPickerSnapshot(models: input, sources: fixture.sources)
        XCTAssertEqual(snapshot.ollamaName, "fixture-ollama")
        XCTAssertEqual(fixture.reads, ["codex": 1, "ollama": 1])
        fixture.reads = [:]
        let projection = AIModel.test_pickerProjection(input, sources: fixture.sources)
        XCTAssertEqual(projection.map(\.name), ["fixture-ollama", "fixture-ollama"])
        XCTAssertEqual(projection.map(\.display), ["local/fixture-ollama", "local/fixture-ollama (Priority)"])
        XCTAssertEqual(projection.map(\.raw), ["ollama_fixture-ollama", "openai_tier__priority__ollama_fixture-ollama"])
        XCTAssertEqual(fixture.reads, ["codex": 1, "ollama": 1])
        fixture.reads = [:]
        XCTAssertEqual(AIModel.sortedForPicker(Array(input.reversed()), sources: fixture.sources), input)
        XCTAssertEqual(fixture.reads, ["codex": 1, "ollama": 1])
    }

    func testPickerSnapshotCapturesCompatibleConfigsAndKeepsTiesStable() {
        let fixture = SnapshotFixture()
        let implicit = AIModel.claudeCodeModel(specifier: "compatible:glmzai")
        let explicit = AIModel.claudeCodeModel(specifier: "compatible:glmzai:sonnet")
        let kimi = AIModel.claudeCodeModel(specifier: "compatible:kimi")
        XCTAssertEqual(AIModel.sortedForPicker([implicit, kimi, explicit], sources: fixture.sources), [implicit, explicit, kimi])
        XCTAssertEqual(fixture.reads, ["config.glmZAI": 1, "config.kimi": 1])
        fixture.configName = "ZZZ Fixture"
        fixture.reads = [:]
        XCTAssertEqual(AIModel.sortedForPicker([explicit, kimi, implicit], sources: fixture.sources), [kimi, explicit, implicit])
        XCTAssertEqual(fixture.reads, ["config.glmZAI": 1, "config.kimi": 1])
    }

    func testSnapshotSortMatchesLegacyForRandomizedQuiescentInputs() {
        var rng = SnapshotRNG()
        let pool: [AIModel] = [
            .gpt61Sol,
            .gpt54Low,
            .codexCustom(name: "gpt-5.5-high"),
            .codexCustom(name: "gpt-5.5-low"),
            .openCodeCustom(name: "missing-high"),
            .grokBuildCustom(name: "missing-low"),
            .devinCustom(name: "missing"),
            .cursorCustom(name: "auto"),
            .claudeCodeModel(specifier: "sonnet"),
            .claudeCodeModel(specifier: "SONNET"),
            .claudeCodeModel(specifier: "future-é"),
            .claudeCodeModel(specifier: "future-e\u{301}"),
            .customProvider(name: "Same", provider: "custom", model: "é"),
            .customProvider(name: "Same", provider: "custom", model: "e\u{301}")
        ]
        // Duplicate the pool so every dynamic provider is eligible for snapshot projection.
        let projectedInput = pool + pool
        let projection = AIModel.test_pickerProjection(projectedInput)
        XCTAssertEqual(projection.map { Array($0.display.utf8) }, projectedInput.map { Array($0.displayName.utf8) })
        for _ in 0 ..< 80 {
            var models = (0 ..< 20).map { _ in pool[Int(rng.next() % UInt64(pool.count))] }
            models.shuffle(using: &rng)
            let expected = AIModel.test_sortedForPickerWithoutSnapshot(models)
            let result = AIModel.sortedForPicker(models)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(Self.exactSpelling(result), Self.exactSpelling(expected))
        }
    }

    func testSnapshotParityWithPopulatedStoresAndRealCursorMatching() throws {
        // A fresh XCTest process isolates registry/admission memory without adding a production
        // override. Both processes restore only these test-host defaults, including on timeout.
        let defaults = UserDefaults.standard
        let keys = ["CodexDynamicModelRecords", "ACPDynamicModelProviders", "ollamaModel", ClaudeCodeCompatibleBackendStore.configsDefaultsKey]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            defaults.synchronize()
            _ = CodexDynamicModelStore.load()
        }
        guard ProcessInfo.processInfo.environment["REPOPROMPT_PICKER_PARITY_CHILD"] == "1" else {
            try runPopulatedParityInChild()
            return
        }
        defaults.removeObject(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
        try assertPopulatedStoreParity()
        print("PICKER_POPULATED_PARITY_OK")
    }

    private func assertPopulatedStoreParity() throws {
        CodexDynamicModelStore.save([
            .init(
                id: "future",
                model: "future",
                displayName: "Future Fixture",
                description: "",
                isDefault: false,
                supportedReasoningEfforts: [.init(reasoningEffort: "high", description: "")], defaultReasoningEffort: nil
            ),
            .init(
                id: "future-high",
                model: "future-high",
                displayName: "Exact Fixture",
                description: "",
                isDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            )
        ])
        UserDefaults.standard.set("fixture-ollama", forKey: "ollamaModel")
        let options = [Self.snapshotOption("fixture-1-a", "Advertised High"), Self.snapshotOption("fixture-1-b", "Advertised Low")]
        for provider in [ACPProviderID.openCode, .grokBuild, .devin] {
            XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
                .init(options: options, currentModelRaw: options[0].rawValue), for: provider
            ))
        }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(CursorDiscoveredCatalogTestSupport.standardSnapshot, for: .cursor))
        let override = "grok-4.6[effort=xhigh,fast=true]"
        let label = try XCTUnwrap(CursorAIModelCatalog.option(matching: override)?.displayName)
        XCTAssertTrue(label.contains("Extra High"))
        XCTAssertTrue(label.contains("Fast"))
        XCTAssertNil(CursorAIModelCatalog.option(matching: "grok-4.6[effort=missing]"))
        XCTAssertEqual(CursorAIModelCatalog.option(matching: "Grok 4.6")?.displayName, "Cursor Grok 4.6")
        XCTAssertEqual(CursorAIModelCatalog.option(matching: "default")?.displayName, AgentModel.cursorAuto.displayName)
        let models: [AIModel] = [
            .codexCustom(name: "future"), .codexCustom(name: "future-high"), .codexCustom(name: "future-fast-high"),
            .openCodeCustom(name: "fixture-1-a"), .openCodeCustom(name: " FIXTURE-1-B "),
            .grokBuildCustom(name: "fixture-1-a"), .grokBuildCustom(name: "fixture-1-b"),
            .devinCustom(name: "fixture-1-a"), .devinCustom(name: "fixture-1-b"),
            .cursorCustom(name: "default"), .cursorCustom(name: "auto"), .cursorCustom(name: "Grok 4.6"),
            .cursorCustom(name: override), .cursorCustom(name: "grok-4.6[effort=missing]"),
            .cursorCustom(name: "composer-2.5[fast=false]"), .cursorCustom(name: "composer-2"),
            .claudeCodeModel(specifier: "compatible:glmzai"), .claudeCodeModel(specifier: "compatible:glmzai:sonnet"),
            .ollama, .openAIServiceTierVariant(base: .ollama, tier: "priority")
        ]
        XCTAssertEqual(models[0].displayName, "CLI·Future Fixture")
        XCTAssertEqual(models[1].displayName, "CLI·Exact Fixture")
        let projection = AIModel.test_pickerProjection(models)
        for (model, fields) in zip(models, projection) {
            XCTAssertEqual(Array(fields.name.utf8), Array(model.modelName.utf8))
            XCTAssertEqual(Array(fields.display.utf8), Array(model.displayName.utf8))
            XCTAssertEqual(Array(fields.raw.utf8), Array(model.rawValue.utf8))
        }
        for model in [AIModel.openCodeCustom(name: "fixture-1-a"), .grokBuildCustom(name: "fixture-1-a"), .devinCustom(name: "fixture-1-a")] {
            XCTAssertEqual(model.displayName, "Advertised High")
        }
        var rng = SnapshotRNG()
        for _ in 0 ..< 30 {
            let input = models.shuffled(using: &rng)
            XCTAssertEqual(Self.exactSpelling(AIModel.sortedForPicker(input)), Self.exactSpelling(AIModel.test_sortedForPickerWithoutSnapshot(input)))
        }
    }

    private func runPopulatedParityInChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "RepoPromptTests.ModelPickerStringOrderingTests/testSnapshotParityWithPopulatedStoresAndRealCursorMatching", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["REPOPROMPT_PICKER_PARITY_CHILD"] = "1"
        process.environment = environment
        let root = try XCTUnwrap(environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let logURL = URL(fileURLWithPath: root).appendingPathComponent("picker-parity-\(UUID().uuidString).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            XCTFail("Populated picker parity child exceeded 60 seconds; log: \(logURL.path)")
        }
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("PICKER_POPULATED_PARITY_OK"), log)
    }

    private static func exactSpelling(_ models: [AIModel]) -> [[[UInt8]]] {
        models.map {
            [String(reflecting: $0), $0.modelName, $0.rawValue, $0.displayName, $0.claudeCodeRuntimeSpecifierRaw ?? ""]
                .map { Array($0.utf8) }
        }
    }

    private static func snapshotOption(_ raw: String, _ label: String) -> AgentModelOption {
        .init(rawValue: raw, displayName: label, description: nil, isDefault: false)
    }

    private struct SnapshotRNG: RandomNumberGenerator {
        var state: UInt64 = 0x5EED
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private final class SnapshotFixture {
        var reads: [String: Int] = [:]
        var records: [CodexDynamicModelRecord] = []
        var options: [AgentModelOption] = []
        var configName: String?
        func hit(_ key: String) {
            reads[key, default: 0] += 1
        }

        var sources: AIModelPickerSnapshot.Sources {
            .init(
                codexRecords: { self.hit("codex")
                    return self.records
                },
                openCodeOptions: { self.hit("openCode")
                    return self.options
                },
                grokBuildOptions: { self.hit("grokBuild")
                    return self.options
                },
                devinOptions: { self.hit("devin")
                    return self.options
                },
                cursorLabels: { self.hit("cursor")
                    return AIModelPickerSnapshot.optionLabels(queries: $0, options: self.options)
                },
                compatibleConfig: { id in
                    self.hit("config.\(id.rawValue)")
                    var config = id.defaultPreset
                    if id == .glmZAI, let name = self.configName { config.displayName = name }
                    return config
                },
                ollamaName: { self.hit("ollama")
                    return "fixture-ollama"
                }
            )
        }
    }

    func testCodexMaxFamilyTokenIsNotParsedAsReasoningEffort() {
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max")
        XCTAssertEqual(base.baseModel, "gpt-5.1-codex-max")
        XCTAssertNil(base.reasoningEffort)

        let high = CodexModelSpecifier(raw: "gpt-5.1-codex-max-high")
        XCTAssertEqual(high.baseModel, "gpt-5.1-codex-max")
        XCTAssertEqual(high.reasoningEffort, .high)
    }

    func testDisplaySuffixStrippingDistinguishesFamilyTokensFromEffortTokens() {
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.6 Sol Fast Ultra"), "GPT-5.6 Sol Fast")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max"), "GPT-5.1 Codex Max")
        XCTAssertEqual(AIModel.stripCodexReasoningSuffix(from: "GPT-5.1 Codex Max High"), "GPT-5.1 Codex Max")
    }

    func testClaudeCodePickerExposesOpus55WithSupportedEfforts() throws {
        let models = AIModel.modelsForProvider(.claudeCode)
        XCTAssertTrue(models.contains(.claudeCodeModel(specifier: "claude-opus-5-5")))
        XCTAssertEqual(
            ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-opus-5-5:xhigh"),
            .claudeCodeModel(specifier: "claude-opus-5-5:xhigh")
        )
        XCTAssertNil(ClaudeCodeAIModelCatalog.validatedModel(specifier: "claude-opus-5-5:ultra"))

        let menu = AIModel.claudeCodeMenu(for: models)
        let group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == "claude-opus-5-5" })
        XCTAssertEqual(group.displayName, "Opus 5.5")
        XCTAssertEqual(group.options.compactMap(\.model.claudeCodeRuntimeSpecifierRaw), [
            "claude-opus-5-5:low",
            "claude-opus-5-5:medium",
            "claude-opus-5-5:high",
            "claude-opus-5-5:xhigh",
            "claude-opus-5-5:max"
        ])

        XCTAssertEqual(AgentModel(rawValue: "claude-opus-5-5"), .claudeOpus55)
        XCTAssertEqual(AgentModel.claudeOpus55.contextWindowTokens, 1_000_000)
        XCTAssertTrue(AgentModel.claudeOpus55.isExtendedContext)
        XCTAssertEqual(
            BestPracticeProfiles.claudeCodeOpusRecommendationLabel,
            "Claude Opus via Claude Code's stable Opus alias (Opus 5.5 on the Anthropic API)"
        )
    }
}

final class AIModelSemanticMemoTests: XCTestCase {
    private final class Fixture {
        var records: [CodexDynamicModelRecord] = []
        var label = "Fixture High"
        var ollama = "fixture"
        var reads: [String: Int] = [:]
        var configName = "Backend"
        func options(_ id: String) -> [AgentModelOption] {
            reads[id, default: 0] += 1
            return [.init(rawValue: "fixture-1", displayName: label, description: nil, isDefault: false)]
        }

        var sources: AIModelPickerSnapshot.Sources {
            .init(
                codexRecords: { self.reads["codex", default: 0] += 1
                    return self.records
                },
                openCodeOptions: { self.options("open") },
                grokBuildOptions: { self.options("grok") },
                devinOptions: { self.options("devin") },
                cursorLabels: { queries in
                    self.reads["cursor", default: 0] += 1
                    return Dictionary(uniqueKeysWithValues: queries.map { ($0, self.label) })
                },
                compatibleConfig: { id in
                    self.reads["config", default: 0] += 1
                    var config = id.defaultPreset
                    config.displayName = self.configName
                    return config
                },
                ollamaName: { self.reads["ollama", default: 0] += 1
                    return self.ollama
                }
            )
        }
    }

    private func bytes(_ models: [AIModel]) -> [[UInt8]] {
        models.map { Array(String(reflecting: $0).utf8) }
    }

    func testRandomizedLocalFirstParityAndExactHitVerification() {
        let fixture = Fixture()
        let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
        let pool: [AIModel] = [
            .gpt61Sol,
            .gpt54Low,
            .codexCustom(name: "future-high"),
            .codexCustom(name: "future-low"),
            .openCodeCustom(name: "fixture-1"),
            .openCodeCustom(name: "missing"),
            .grokBuildCustom(name: "fixture-1"),
            .grokBuildCustom(name: "missing"),
            .devinCustom(name: "fixture-1"),
            .devinCustom(name: "missing"),
            .cursorCustom(name: "auto"),
            .cursorCustom(name: "fixture-1"),
            .ollama,
            .openAIServiceTierVariant(base: .ollama, tier: "priority"),
            .openAIServiceTierVariant(base: .codexCustom(name: "future-high"), tier: "flex"),
            .customProvider(name: "Same", provider: "custom", model: "é"),
            .customProvider(name: "Same", provider: "custom", model: "e\u{301}"),
            .openaiCustomReasoning(name: "fixture", effort: .high),
            .azureCustom(name: "fixture"),
            .claudeCodeModel(specifier: "SONNET"),
            .claudeCodeModel(specifier: "sonnet"),
            .openAIServiceTierVariant(base: .claudeCodeModel(specifier: "sonnet"), tier: "priority")
        ]
        var state: UInt64 = 17
        for _ in 0 ..< 60 {
            var input = pool
            for index in input.indices.reversed() {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                input.swapAt(index, Int(state % UInt64(index + 1)))
            }
            let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
            XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
        }
        XCTAssertGreaterThan(memo.statistics().hits, 0)
    }

    func testChangedInputsAndSourceReadsOnWarmHits() {
        let fixture = Fixture()
        let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
        let input: [AIModel] = [
            .openCodeCustom(name: "fixture-1"),
            .openCodeCustom(name: "fixture-1-low"),
            .ollama,
            .openAIServiceTierVariant(base: .ollama, tier: "priority")
        ]
        for label in ["Fixture High", "Fixture Low", "é", "e\u{301}"] {
            fixture.label = label
            fixture.ollama = label
            for _ in 0 ..< 2 {
                fixture.reads = [:]
                let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
                fixture.reads = [:]
                XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
                XCTAssertEqual(fixture.reads, ["codex": 1, "open": 1, "ollama": 1])
            }
        }
        let high = AIModel.codexCustom(name: "future-high"), low = AIModel.codexCustom(name: "future-low")
        for records: [CodexDynamicModelRecord] in [[], [.init(id: "future-high", model: "future-high", displayName: "Exact", description: "", isDefault: false)], []] {
            fixture.records = records
            let expected = AIModel.test_sortedForPicker([high, low], sources: fixture.sources, memo: nil)
            XCTAssertEqual(bytes(AIModel.test_sortedForPicker([high, low], sources: fixture.sources, memo: memo)), bytes(expected))
        }
        // Availability/sign-out cannot resurrect models: the actual input still owns membership.
        XCTAssertTrue(AIModel.test_sortedForPicker([], sources: fixture.sources, memo: memo).isEmpty)
    }

    func testClaudeAndUnusedGroupsDoNotPrepareMemo() {
        let fixture = Fixture()
        let memo = AIModelSemanticMemo(recording: true)
        for input: [AIModel] in [[], [.gpt61Sol], [.gpt61Sol, .ollama], [.claudeCodeModel(specifier: "sonnet"), .claudeCodeModel(specifier: "opus")]] {
            _ = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
        }
        XCTAssertEqual(memo.statistics().states, 0)
        XCTAssertEqual(memo.statistics().entries, 0)
    }

    func testCompatibleConfigExcludedAndNativeEqualSpellingPreserved() {
        let fixture = Fixture()
        let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
        let a = AIModel.customProvider(name: "Same", provider: "custom", model: "é")
        let b = AIModel.customProvider(name: "Same", provider: "custom", model: "e\u{301}")
        XCTAssertEqual(a, b)
        for input in [[a, b], [b, a], [a, b], [b, a]] {
            let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
            XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
        }
        let input = [a, b, .claudeCodeModel(specifier: "compatible:glmzai"), .claudeCodeModel(specifier: "compatible:glmzai:sonnet")]
        _ = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
        let previous = memo.statistics()
        fixture.configName = "Changed config"
        fixture.reads = [:]
        let actual = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
        XCTAssertEqual(fixture.reads["config"], 1)
        XCTAssertEqual(memo.statistics().states, previous.states)
        XCTAssertGreaterThan(memo.statistics().hits, previous.hits)
        XCTAssertEqual(bytes(actual), bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)))
    }

    func testCollisionEvictionPurgeAndStaleTokens() throws {
        let memo = AIModelSemanticMemo(limits: .init(entries: 4, states: 2, bytes: 4096, contentBytes: 1024, entryBytes: 1024), recording: true)
        let a = try XCTUnwrap(memo.test_content(Data([1, 2, 3])))
        memo.test_insert("A", token: a, model: .gpt61Sol)
        XCTAssertEqual(memo.test_lookup(token: a, model: .gpt61Sol), "A")
        let b = try XCTUnwrap(memo.test_content(Data([1, 9, 3]))) // forced equal hash and equal length
        XCTAssertNil(memo.test_lookup(token: b, model: .gpt61Sol))
        memo.test_insert("B", token: b, model: .gpt61Sol)
        XCTAssertEqual(memo.statistics().states, 2)
        XCTAssertTrue(try XCTUnwrap(memo.test_content(Data([1, 2, 3]))) === a)
        XCTAssertTrue(try XCTUnwrap(memo.test_content(Data([1, 9, 3]))) === b)
        XCTAssertEqual(memo.test_lookup(token: a, model: .gpt61Sol), "A")
        XCTAssertEqual(memo.test_lookup(token: b, model: .gpt61Sol), "B")
        _ = try XCTUnwrap(memo.test_content(Data([1, 8, 3])))
        memo.test_insert("stale", token: a, model: .gpt61Sol)
        XCTAssertNil(memo.test_lookup(token: a, model: .gpt61Sol))
        XCTAssertEqual(memo.test_lookup(token: b, model: .gpt61Sol), "B")
        memo.purge()
        let replacement = try XCTUnwrap(memo.test_content(Data([1, 9, 3])))
        memo.test_insert("stale", token: b, model: .gpt61Sol)
        XCTAssertNil(memo.test_lookup(token: replacement, model: .gpt61Sol))
        XCTAssertNil(memo.test_lookup(token: a, model: .gpt61Sol))
    }

    func testBoundsAndWholeStateRecency() throws {
        let memo = AIModelSemanticMemo(limits: .init(entries: 2, states: 2, bytes: 4096, contentBytes: 128, entryBytes: 1024), recording: true)
        XCTAssertNil(memo.test_content(Data(repeating: 0, count: 129)))
        let a = try XCTUnwrap(memo.test_content(Data([1])))
        memo.test_insert("A", token: a, model: .gpt61Sol)
        memo.test_insert("B", token: a, model: .gpt54Low)
        memo.test_insert("Rejected", token: a, model: .gpt41)
        XCTAssertEqual(memo.statistics().entries, 2)
        XCTAssertEqual(memo.test_lookup(token: a, model: .gpt61Sol), "A")
        let b = try XCTUnwrap(memo.test_content(Data([2])))
        memo.test_insert("B", token: b, model: .gpt41)
        XCTAssertNil(memo.test_lookup(token: a, model: .gpt61Sol))
        XCTAssertLessThanOrEqual(memo.statistics().entries, 2)
        XCTAssertLessThanOrEqual(memo.statistics().chargedBytes, 4096)
        memo.purge()
        XCTAssertEqual(memo.statistics().chargedBytes, 0)
        XCTAssertEqual(memo.statistics().states, 0)
    }

    func testSmallCustomByteBudgetsRejectWithoutEvictingLiveEntries() throws {
        for budget in [1, 255, 256] {
            let memo = AIModelSemanticMemo(limits: .init(bytes: budget), recording: true)
            XCTAssertNil(memo.test_content(Data([1])))
            XCTAssertEqual(memo.statistics().states, 0)
            XCTAssertEqual(memo.statistics().chargedBytes, 0)
        }
        let memo = AIModelSemanticMemo(limits: .init(entries: 8, states: 2, bytes: 1024, contentBytes: 1024, entryBytes: 2048), recording: true)
        let a = try XCTUnwrap(memo.test_content(Data([1])))
        let b = try XCTUnwrap(memo.test_content(Data([2])))
        memo.test_insert("B", token: b, model: .gpt61Sol)
        let before = memo.statistics()
        memo.test_insert(String(repeating: "x", count: 500), token: a, model: .gpt61Sol)
        XCTAssertEqual(memo.statistics().states, before.states)
        XCTAssertEqual(memo.statistics().chargedBytes, before.chargedBytes)
        XCTAssertEqual(memo.statistics().evictions, 0)
        XCTAssertEqual(memo.test_lookup(token: b, model: .gpt61Sol), "B")
        XCTAssertNil(memo.test_lookup(token: a, model: .gpt61Sol))
    }

    func testEveryLabelSourceAndOversizedBypass() {
        let fixture = Fixture()
        let factories: [(String) -> AIModel] = [{ .openCodeCustom(name: $0) }, { .grokBuildCustom(name: $0) }, { .devinCustom(name: $0) }, { .cursorCustom(name: $0) }]
        for make in factories {
            let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
            let input = [make("fixture-1"), make("fixture-1-low")]
            for label in ["Model High", "Model Low", "é", "e\u{301}"] {
                fixture.label = label
                let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
                XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
                _ = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
            }
            XCTAssertGreaterThan(memo.statistics().hits, 0)
        }
        let memo = AIModelSemanticMemo(limits: .init(entries: 8, states: 2, bytes: 4096, contentBytes: 128, entryBytes: 512), recording: true)
        fixture.label = String(repeating: "x", count: 129)
        let input: [AIModel] = [.openCodeCustom(name: "fixture-1"), .openCodeCustom(name: "missing")]
        XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)))
        XCTAssertEqual(memo.statistics().states, 0)
    }

    func testOrderedCodexCapabilityAndLabelChangesPreserveParity() {
        let fixture = Fixture()
        let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
        func record(_ id: String = "future", label: String = "Future", efforts: [String] = ["low", "max"], defaultEffort: String? = "low") -> CodexDynamicModelRecord {
            .init(
                id: id,
                model: id,
                displayName: label,
                description: "",
                isDefault: false,
                supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") },
                defaultReasoningEffort: defaultEffort
            )
        }
        let input: [AIModel] = [.codexCustom(name: "future"), .codexCustom(name: "future-max"), .codexCustom(name: "future-high"), .openaiCustom(name: "future-max"), .gpt61Sol]
        let first = record(label: "First", efforts: ["max"])
        let second = record(label: "Second", efforts: ["ultra"])
        for records in [[], [record()], [record(defaultEffort: "max")], [record(efforts: ["max", "low"])], [record(label: "Future High")], [record(), record("future-max")], [first, second], [second, first]] {
            fixture.records = records
            for _ in 0 ..< 2 {
                let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
                XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
            }
        }
        XCTAssertEqual(memo.statistics().states, 8)
        XCTAssertGreaterThan(memo.statistics().hits, 0)
    }

    func testOmittedCodexFieldsOnWarmMemoForCodexAndNonCodexNames() {
        let fixture = Fixture()
        func record(model: String = "wire-alpha-2", label: String = "Stable", isDefault: Bool = false, tiers: [CodexModelServiceTier] = []) -> CodexDynamicModelRecord {
            .init(
                id: "future",
                model: model,
                displayName: label,
                description: "",
                isDefault: isDefault,
                supportedReasoningEfforts: [.init(reasoningEffort: "max", description: "")],
                defaultReasoningEffort: "max",
                serviceTiers: tiers
            )
        }
        let names = ["future-ultrafast-high", "future-ultrafast-max", "future-max", "default", "wire-beta-9-ultrafast-high"]
        let codex = names.map { AIModel.codexCustom(name: $0) }
        let nonCodex = names.map { AIModel.openaiCustom(name: $0) }
        for input in [codex, nonCodex, codex + nonCodex] {
            let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
            fixture.records = [record()]
            _ = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
            let warm = memo.statistics()
            for changed in [record(tiers: [.init(id: "ultrafast", name: "Ultrafast", description: "Published tier")]), record(model: "wire-beta-9"), record(isDefault: true)] {
                fixture.records = [changed]
                let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
                XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
                XCTAssertEqual(memo.statistics().states, warm.states)
                XCTAssertEqual(memo.statistics().misses, warm.misses)
            }
            XCTAssertGreaterThan(memo.statistics().hits, warm.hits)
        }
        // With no Codex comparison, even display-name/model fallback text is irrelevant to parsing.
        let nonCodexMemo = AIModelSemanticMemo(recording: true, verifyHits: true)
        fixture.records = [record(label: "")]
        _ = AIModel.test_sortedForPicker(nonCodex, sources: fixture.sources, memo: nonCodexMemo)
        let warm = nonCodexMemo.statistics()
        for changed in [record(model: "wire-beta-9", label: ""), record(label: "Different High")] {
            fixture.records = [changed]
            let expected = AIModel.test_sortedForPicker(nonCodex, sources: fixture.sources, memo: nil)
            XCTAssertEqual(bytes(AIModel.test_sortedForPicker(nonCodex, sources: fixture.sources, memo: nonCodexMemo)), bytes(expected))
            XCTAssertEqual(nonCodexMemo.statistics().misses, warm.misses)
            XCTAssertEqual(nonCodexMemo.statistics().states, 1)
        }
        // Blank preferred labels make model a real Codex display dependency: the resolved map invalidates.
        let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
        let input: [AIModel] = [.codexCustom(name: "future"), .codexCustom(name: "future-max")]
        fixture.records = [record(label: "")]
        let previousLabels = CodexDynamicModelMapper.displayNameIndex(discovery: .init(records: fixture.records))
        _ = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)
        let before = memo.statistics()
        fixture.records = [record(model: "wire-beta-9", label: "")]
        XCTAssertNotEqual(CodexDynamicModelMapper.displayNameIndex(discovery: .init(records: fixture.records)), previousLabels)
        let expected = AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: nil)
        XCTAssertEqual(bytes(AIModel.test_sortedForPicker(input, sources: fixture.sources, memo: memo)), bytes(expected))
        XCTAssertEqual(memo.statistics().states, 2)
        XCTAssertGreaterThan(memo.statistics().misses, before.misses)
    }

    func testConcurrentEvictionWithOutstandingTokens() throws {
        let memo = AIModelSemanticMemo(limits: .init(entries: 8, states: 1), recording: true)
        let token = try XCTUnwrap(memo.test_content(Data([1])))
        memo.test_insert("A", token: token, model: .gpt61Sol)
        let arrived = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let done = expectation(description: "evicted token released")
        DispatchQueue.global().async {
            XCTAssertEqual(memo.test_lookup(token: token, model: .gpt61Sol), "A")
            arrived.signal()
            guard resume.wait(timeout: .now() + 5) == .success else { XCTFail("eviction barrier timed out")
                done.fulfill()
                return
            }
            XCTAssertNil(memo.test_lookup(token: token, model: .gpt61Sol))
            memo.test_insert("stale", token: token, model: .gpt54Low)
            done.fulfill()
        }
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)
        let replacement = try XCTUnwrap(memo.test_content(Data([2])))
        memo.test_insert("B", token: replacement, model: .gpt61Sol)
        resume.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(memo.test_lookup(token: replacement, model: .gpt61Sol), "B")
        XCTAssertNil(memo.test_lookup(token: replacement, model: .gpt54Low))

        final class Stress: @unchecked Sendable {
            let memo = AIModelSemanticMemo(limits: .init(entries: 8, states: 2, bytes: 4096), recording: true)
            let lock = NSLock()
            var failures = 0
            func run(_ worker: Int) {
                for round in 0 ..< 32 {
                    let id = UInt8((worker + round) % 3)
                    guard let token = memo.test_content(Data([id])) else { lock.withLock { failures += 1 }
                        continue
                    }
                    let expected = "state-\(id)"
                    memo.test_insert(expected, token: token, model: .gpt61Sol)
                    if let actual = memo.test_lookup(token: token, model: .gpt61Sol), actual != expected { lock.withLock { failures += 1 } }
                }
            }
        }
        let stress = Stress()
        DispatchQueue.concurrentPerform(iterations: 32) { stress.run($0) }
        XCTAssertEqual(stress.failures, 0)
        XCTAssertGreaterThan(stress.memo.statistics().evictions, 0)
        XCTAssertLessThanOrEqual(stress.memo.statistics().states, 2)
        XCTAssertLessThanOrEqual(stress.memo.statistics().entries, 8)
        XCTAssertLessThanOrEqual(stress.memo.statistics().chargedBytes, 4096)
    }

    func testConcurrentSortsUseImmutableCapturedValues() {
        final class Work: @unchecked Sendable {
            let memo = AIModelSemanticMemo(recording: true, verifyHits: true)
            let input: [AIModel] = [.gpt61Sol, .gpt54Low, .codexCustom(name: "future-high"), .codexCustom(name: "future-low")]
            let lock = NSLock()
            var failures = 0
            func run() {
                let sources = AIModelPickerSnapshot.Sources(codexRecords: { [] }, openCodeOptions: { [] }, grokBuildOptions: { [] }, devinOptions: { [] }, cursorLabels: { _ in [:] }, compatibleConfig: { $0.defaultPreset }, ollamaName: { "fixture" })
                let expected = AIModel.test_sortedForPicker(input, sources: sources, memo: nil)
                let actual = AIModel.test_sortedForPicker(input, sources: sources, memo: memo)
                if actual.map({ Array(String(reflecting: $0).utf8) }) != expected.map({ Array(String(reflecting: $0).utf8) }) { lock.withLock { failures += 1 } }
            }
        }
        let work = Work()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in work.run() }
        XCTAssertEqual(work.failures, 0)
        XCTAssertEqual(work.memo.statistics().entries, work.input.count)
        XCTAssertLessThanOrEqual(work.memo.statistics().chargedBytes, work.memo.limits.bytes)
    }

    func testConcurrentDuplicateMissAndPurgeBarrier() throws {
        let memo = AIModelSemanticMemo(recording: true)
        let token = try XCTUnwrap(memo.test_content(Data([7])))
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            memo.test_insert("same", token: token, model: .gpt61Sol)
        }
        XCTAssertEqual(memo.statistics().entries, 1)
        XCTAssertEqual(memo.statistics().inserts, 1)
        let arrived = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let done = expectation(description: "stale insertion returned")
        DispatchQueue.global().async {
            arrived.signal()
            resume.wait()
            memo.test_insert("old", token: token, model: .gpt54Low)
            done.fulfill()
        }
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)
        memo.purge()
        resume.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(memo.statistics().entries, 0)
        XCTAssertEqual(memo.statistics().chargedBytes, 0)
    }
}
