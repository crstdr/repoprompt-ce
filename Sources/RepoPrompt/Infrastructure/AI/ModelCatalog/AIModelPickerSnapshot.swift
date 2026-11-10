import Foundation

/// Read dependencies before comparisons; discard every index when this sort returns.
/// Projections are valid only for this input's same-provider groups with at least two entries.
/// Keep Requirements.include and AIModel's picker projections synchronized, including wrapped bases;
/// this is not a reusable snapshot for menus or arbitrary models. Its parser memo stays synchronous.
final class AIModelPickerSnapshot {
    struct Sources {
        var codexRecords: () -> [CodexDynamicModelRecord]
        var openCodeOptions: () -> [AgentModelOption]
        var grokBuildOptions: () -> [AgentModelOption]
        var devinOptions: () -> [AgentModelOption]
        var cursorLabels: ([String]) -> [String: String]
        var compatibleConfig: (ClaudeCodeCompatibleBackendID) -> ClaudeCodeCompatibleBackendConfig
        var ollamaName: () -> String

        static var live: Self {
            Self(
                codexRecords: { CodexDynamicModelStore.load() },
                openCodeOptions: { ACPAIModelCatalog.openCodeModelOptionsFromStore() },
                grokBuildOptions: { ACPAIModelCatalog.grokBuildModelOptionsFromStore() },
                devinOptions: { ACPAIModelCatalog.devinModelOptionsFromStore() },
                cursorLabels: { CursorAIModelCatalog.pickerDisplayNames(for: $0) },
                compatibleConfig: { ClaudeCodeCompatibleBackendStore.shared.config(for: $0) },
                ollamaName: { UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.1" }
            )
        }
    }

    let discovery: CodexModelDiscovery
    let codexLabels: [String: String]
    let openCodeLabels: [String: String]
    let grokBuildLabels: [String: String]
    let devinLabels: [String: String]
    let cursorLabels: [String: String]
    let compatibleConfigs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig]
    let ollamaName: String?
    private let providers: [AIModel: AIProviderType]
    private let claudeLabels: [[UInt8]: String]
    private var parsed: [[UInt8]: CodexModelSpecifier] = [:]

    init(models: [AIModel], sources: Sources) {
        var providers: [AIModel: AIProviderType] = [:]
        var counts: [AIProviderType: Int] = [:]
        for model in models {
            let provider = providers[model] ?? model.providerType
            providers[model] = provider
            counts[provider, default: 0] += 1
        }
        self.providers = providers
        var needed = Requirements()
        var needsCodexSemanticDiscovery = false
        for model in models where counts[providers[model]!, default: 0] > 1 {
            // Legacy effort parsing uses Codex discovery even for non-Codex semantic lanes.
            needsCodexSemanticDiscovery = needsCodexSemanticDiscovery || providers[model] != .claudeCode
            needed.include(model)
        }
        discovery = CodexModelDiscovery(records: needsCodexSemanticDiscovery ? sources.codexRecords() : [])
        codexLabels = needed.codexLabels ? CodexDynamicModelMapper.displayNameIndex(discovery: discovery) : [:]
        openCodeLabels = Self.labels(queries: needed.openCode, load: sources.openCodeOptions)
        grokBuildLabels = Self.labels(queries: needed.grokBuild, load: sources.grokBuildOptions)
        devinLabels = Self.labels(queries: needed.devin, load: sources.devinOptions)
        cursorLabels = needed.cursor.isEmpty ? [:] : sources.cursorLabels(Array(needed.cursor))
        var configs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig] = [:]
        for id in ClaudeCodeCompatibleBackendID.allCases where needed.configs.contains(id) {
            configs[id] = sources.compatibleConfig(id)
        }
        compatibleConfigs = configs
        var claudeLabels: [[UInt8]: String] = [:]
        for specifier in needed.claude where claudeLabels[Array(specifier.utf8)] == nil {
            claudeLabels[Array(specifier.utf8)] = ClaudeCodeAIModelCatalog.displayName(for: specifier, configs: configs)
        }
        self.claudeLabels = claudeLabels
        ollamaName = needed.ollama ? sources.ollamaName() : nil
    }

    func provider(for model: AIModel) -> AIProviderType {
        providers[model]!
    }

    func claudeLabel(for specifier: String) -> String {
        // Byte keys retain spelling even when AIModel's native identity normalizes it.
        claudeLabels[Array(specifier.utf8)]!
    }

    func specifier(_ raw: String) -> CodexModelSpecifier {
        let key = Array(raw.utf8)
        if let value = parsed[key] { return value }
        let value = CodexModelSpecifier(raw: raw, discovery: discovery)
        parsed[key] = value
        return value
    }

    private static func labels(queries: Set<String>, load: () -> [AgentModelOption]) -> [String: String] {
        // Filter before loading: blank-only requests must not read a source.
        let nonempty = queries.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonempty.isEmpty else { return [:] }
        return optionLabels(queries: Array(nonempty), options: load())
    }

    /// ASCII IDs use a first-wins index. Unusual Unicode IDs retain Foundation's exact matching
    /// during preparation; all subsequent sort lookups use the resulting query table.
    static func optionLabels(queries: [String], options: [AgentModelOption]) -> [String: String] {
        func ascii(_ value: String) -> Bool {
            value.unicodeScalars.allSatisfy { $0.value < 128 }
        }
        let asciiOptions = options.allSatisfy { ascii($0.rawValue) }
        var indexed: [String: String] = [:]
        if asciiOptions {
            for option in options where indexed[option.rawValue.lowercased()] == nil {
                indexed[option.rawValue.lowercased()] = option.displayName
            }
        }
        var result: [String: String] = [:]
        for raw in queries {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if asciiOptions, ascii(normalized) {
                result[raw] = indexed[normalized.lowercased()]
            } else if let option = options.first(where: { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }) {
                result[raw] = option.displayName
            }
        }
        return result
    }

    private struct Requirements {
        var codexLabels = false
        var openCode = Set<String>()
        var grokBuild = Set<String>()
        var devin = Set<String>()
        var cursor = Set<String>()
        var claude: [String] = []
        var configs = Set<ClaudeCodeCompatibleBackendID>()
        var ollama = false

        mutating func include(_ model: AIModel) {
            // Every mutable branch of AIModel.pickerDisplayName must be prepared here.
            switch model {
            case let .openAIServiceTierVariant(base, _): include(base)
            case .codexCustom: codexLabels = true
            case let .openCodeCustom(raw): openCode.insert(raw)
            case let .grokBuildCustom(raw): grokBuild.insert(raw)
            case let .devinCustom(raw): devin.insert(raw)
            case let .cursorCustom(raw): cursor.insert(raw)
            case let .claudeCodeModel(raw):
                claude.append(raw)
                if let id = ClaudeCodeAIModelCatalog.compatibleBackendID(referencedBy: raw) { configs.insert(id) }
            case .ollama: ollama = true
            default: break
            }
        }
    }
}
