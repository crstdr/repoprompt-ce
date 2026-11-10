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
