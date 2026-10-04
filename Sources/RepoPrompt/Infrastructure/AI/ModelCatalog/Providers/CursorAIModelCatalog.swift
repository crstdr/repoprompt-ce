import Foundation

// SEARCH-HELPER: Cursor model catalogue projection, dynamic membership, canonical identity, legacy aliases
/// Projection of Cursor's discovered model catalogue for Agent Mode UI and MCP surfaces.
///
/// Cursor advertises its full model list *and* each model's parameter metadata through
/// `cursor/list_available_models`. `CursorACPModelPollingService` publishes and persists that
/// snapshot into `AgentACPModelRegistry`, which already resolves live → persisted. This type is
/// the single projection of that resolved snapshot. Each public lookup captures that snapshot once,
/// so any single membership or metadata answer is internally consistent. Consistency is per call,
/// not per multi-call operation: an enumeration that calls repeatedly can straddle a refresh and
/// list a model from one snapshot while reading its parameters from the next. That is benign —
/// applying a model and its parameters stays live-session authoritative — but it is not a
/// whole-operation transaction.
///
/// Two deliberately separate tiers:
/// 1. `canonicalIdentity(_:)` is **pure**: it maps a raw or closed-legacy spelling to a stable
///    identity without consulting the registry. Saved selections and parameter pins route
///    through it, so an identity can never change as the persisted cache warms.
/// 2. `options` / `option(matching:)` / `contains(modelRaw:)` / `parameterSet(for:)` are
///    snapshot-backed membership and metadata. Cached advertisements describe last-known
///    options only; applying a model and its parameters stays live-session authoritative.
enum CursorAIModelCatalog {
    /// Legacy identities CE accepted while the catalogue was compiled in. Closed set: it exists so
    /// already-saved selections and parameter pins keep resolving to the identity they had.
    ///
    /// Two historic sources needed rows, both taken from the removed table and nothing else:
    /// its explicit aliases, and the display spellings whose normalized form differed from the
    /// model's raw ID (`Claude Opus 4.6` → `claude-opus-4.6` vs raw `claude-opus-4-6`, `Codex 5.3`
    /// vs raw `gpt-5.3-codex`). Without those rows a pin saved under a display spelling would
    /// split from the same pin saved under the raw ID once membership stopped canonicalizing it.
    /// Display spellings that already normalize to their raw ID (`Composer 2.5`, `GPT-5.4 Mini`,
    /// `Auto`, …) need no row. Newly advertised models are never aliased: their advertised IDs are
    /// used verbatim, and a spelling for one is admitted only when it normalizes onto that raw ID.
    private static let legacyIdentityAliases: [String: String] = [
        "composer-2": "composer-2.5",
        "cursor-grok-4.5": "grok-4.5",
        "cursor-grok-4.6": "grok-4.6",
        "cursor-grok-4.7": "grok-4.7",
        "claude-haiku-4.5": "claude-haiku-4-5",
        "claude-opus-4.5": "claude-opus-4-5",
        "claude-opus-4.6": "claude-opus-4-6",
        "claude-opus-4.7": "claude-opus-4-7",
        "claude-opus-4.8": "claude-opus-4-8",
        "claude-sonnet-4.5": "claude-sonnet-4-5",
        "claude-sonnet-4.6": "claude-sonnet-4-6",
        "codex-5.3": "gpt-5.3-codex",
        // Cursor advertises its Auto entry as the provider default (`default`). CE's public and
        // saved identity for it stays `auto`; the session layer translates back against the
        // provider's own snapshot at runtime.
        "default": AgentModel.cursorAuto.rawValue
    ]

    private static var autoIdentity: String {
        AgentModel.cursorAuto.rawValue
    }

    /// Auto is pinned first, is CE's only Cursor default, and stays parameter-free: it carries no
    /// advertised selector identity that a saved parameter pin could split against.
    private static var autoOption: AgentModelOption {
        AgentModelOption(
            rawValue: AgentModel.cursorAuto.rawValue,
            displayName: AgentModel.cursorAuto.displayName,
            description: AgentModel.cursorAuto.description,
            isDefault: true
        )
    }

    /// Pure, membership-independent identity for a Cursor model spelling.
    ///
    /// Never consults the registry: `AgentModelCatalog.canonicalModelRaw` and
    /// `ACPModelParameterIdentity` depend on this being identical before and after a cache warm.
    static func canonicalIdentity(_ modelRaw: String) -> String {
        let normalized = ACPAIModelCatalog.normalizedCursorModelAlias(modelRaw)
        guard !normalized.isEmpty else { return "" }
        return legacyIdentityAliases[normalized] ?? normalized
    }

    /// Last-known selectable options: Auto first, then every advertised model in the store's
    /// existing canonical order. Before any discovery or cache warm this is Auto-only.
    static var options: [AgentModelOption] {
        projectedOptions(from: resolvedSnapshot())
    }

    /// Persisted Cursor overrides use bracket syntax, while wire model/config calls stay separate.
    struct ModelSpecifier {
        struct Override {
            let configID: String
            let valueRaw: String
        }

        let baseModelRaw: String
        let overrides: [Override]

        init(raw: String) throws {
            // An advertised model ID may itself contain brackets; never parse that exact ID.
            if CursorAIModelCatalog.options.contains(where: { $0.rawValue == raw }) || !raw.contains("[") {
                baseModelRaw = raw
                overrides = []
                return
            }
            guard let start = raw.firstIndex(of: "["), raw.hasSuffix("]") else { throw Self.invalid(raw) }
            baseModelRaw = String(raw[..<start])
            let body = raw[raw.index(after: start) ..< raw.index(before: raw.endIndex)]
            var parsed: [Override] = []
            var ids = Set<String>()
            for pair in body.split(separator: ",", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, Self.canEncode(String(parts[0])), Self.canEncode(String(parts[1])),
                      ids.insert(String(parts[0])).inserted else { throw Self.invalid(raw) }
                parsed.append(.init(configID: String(parts[0]), valueRaw: String(parts[1])))
            }
            guard !baseModelRaw.isEmpty, !baseModelRaw.contains("]"), !parsed.isEmpty else { throw Self.invalid(raw) }
            overrides = parsed
        }

        static func canEncode(_ raw: String) -> Bool {
            !raw.isEmpty && !raw.contains(where: { "[]=,".contains($0) || $0.isWhitespace })
        }

        static func invalid(_ raw: String) -> NSError {
            NSError(domain: "CursorModelSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported Cursor model selection: \(raw)"])
        }

        struct ValidatedOverride {
            let baseModelRaw: String
            let kind: ACPModelParameterKind
            let configID: String
            let valueRaw: String
        }

        func selections(in snapshot: ACPDiscoveredSessionModels?, excludingConfigIDs: Set<String> = [], supersededKinds: Set<ACPModelParameterKind> = [], ignoringUnavailable: Bool = false) throws -> [ValidatedOverride] {
            let inherited = overrides.filter { !excludingConfigIDs.contains($0.configID) }
            guard !inherited.isEmpty else { return [] }
            let identity = CursorAIModelCatalog.canonicalIdentity(baseModelRaw)
            guard identity != AgentModel.cursorAuto.rawValue,
                  let set = snapshot?.modelParameterSets.first(where: { CursorAIModelCatalog.canonicalIdentity($0.baseModelRaw) == identity })
            else { throw Self.invalid(baseModelRaw) }
            return try inherited.compactMap { override in
                guard let definition = set.definition(configID: override.configID) else {
                    if ignoringUnavailable {
                        return nil
                    }
                    throw Self.invalid("\(override.configID)=\(override.valueRaw)")
                }
                if supersededKinds.contains(definition.kind) {
                    return nil
                }
                guard definition.choices.contains(where: { $0.rawValue == override.valueRaw }) else {
                    if ignoringUnavailable {
                        return nil
                    }
                    throw Self.invalid("\(override.configID)=\(override.valueRaw)")
                }
                return .init(baseModelRaw: set.baseModelRaw, kind: definition.kind, configID: definition.configID, valueRaw: override.valueRaw)
            }
        }

        func replacing(configID: String, valueRaw: String?) -> String? {
            guard Self.canEncode(configID), valueRaw.map(Self.canEncode) ?? true else { return nil }
            var values = overrides.filter { $0.configID != configID }
            if let valueRaw {
                values.append(.init(configID: configID, valueRaw: valueRaw))
            }
            return values.isEmpty ? baseModelRaw : baseModelRaw + "[" + values.map { "\($0.configID)=\($0.valueRaw)" }.joined(separator: ",") + "]"
        }
    }

    static func contains(modelRaw: String) -> Bool {
        option(matching: modelRaw) != nil
    }

    static func option(matching modelRaw: String) -> AgentModelOption? {
        if let specifier = try? ModelSpecifier(raw: modelRaw), !specifier.overrides.isEmpty,
           let base = option(matching: specifier.baseModelRaw),
           let selections = try? specifier.selections(in: resolvedSnapshot())
        {
            let labels = selections.map { selection in
                parameterSet(for: base.rawValue)?.definition(configID: selection.configID)?.choices.first(where: { $0.rawValue == selection.valueRaw })?.displayName ?? selection.valueRaw
            }
            return AgentModelOption(rawValue: modelRaw, displayName: base.displayName + " · " + labels.joined(separator: " · "), description: base.description, isDefault: false)
        }
        let identity = canonicalIdentity(modelRaw)
        guard !identity.isEmpty else { return nil }
        if identity == autoIdentity {
            return autoOption
        }
        guard let snapshot = resolvedSnapshot(),
              let discovered = discoveredOption(matching: identity, in: snapshot)
        else {
            return nil
        }
        return projectedOption(discovered)
    }

    static func parameterSet(for modelRaw: String) -> ACPModelParameterSet? {
        let baseModelRaw = (try? ModelSpecifier(raw: modelRaw).baseModelRaw) ?? modelRaw
        let identity = canonicalIdentity(baseModelRaw)
        guard !identity.isEmpty, identity != autoIdentity else { return nil }
        guard let snapshot = resolvedSnapshot(),
              let discovered = discoveredOption(matching: identity, in: snapshot)
        else {
            return nil
        }
        let discoveredIdentity = canonicalIdentity(discovered.rawValue)
        return snapshot.modelParameterSets.first {
            canonicalIdentity($0.baseModelRaw) == discoveredIdentity
        }
    }

    private static func resolvedSnapshot() -> ACPDiscoveredSessionModels? {
        AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)
    }

    private static func projectedOptions(from snapshot: ACPDiscoveredSessionModels?) -> [AgentModelOption] {
        guard let snapshot else { return [autoOption] }
        var seenIdentities: Set<String> = [autoIdentity]
        var projected: [AgentModelOption] = [autoOption]
        for option in snapshot.options where !isAutoOption(option) {
            let identity = canonicalIdentity(option.rawValue)
            guard !identity.isEmpty, seenIdentities.insert(identity).inserted else { continue }
            projected.append(projectedOption(option))
        }
        return projected
    }

    /// Advertised raw IDs only, matched through the pure identity (which also resolves the closed
    /// historical aliases).
    ///
    /// Membership deliberately does **not** accept an arbitrary advertised display name. Doing so
    /// admitted spellings that `canonicalIdentity` maps to a different identity than the advertised
    /// raw ID — for any future model whose display name carries a dot where the wire ID carries a
    /// dash (`Claude Opus 9.1` vs `claude-opus-9-1`). The selection would persist under the dotted
    /// identity while its parameter pins are keyed off the advertised raw, so `effectiveSelections`
    /// would silently drop the user's explicit pin at dispatch. Every CE surface (picker,
    /// `list_agents`, MCP admission) emits advertised raw IDs, and the display spellings CE
    /// historically accepted are covered by `legacyIdentityAliases`.
    private static func discoveredOption(
        matching identity: String,
        in snapshot: ACPDiscoveredSessionModels
    ) -> AgentModelOption? {
        snapshot.options.first {
            !isAutoOption($0) && canonicalIdentity($0.rawValue) == identity
        }
    }

    private static func projectedOption(_ option: AgentModelOption) -> AgentModelOption {
        AgentModelOption(
            rawValue: option.rawValue,
            displayName: option.displayName,
            description: option.description ?? "Available through Cursor Agent.",
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: option.supportedReasoningEfforts,
            defaultReasoningEffort: option.defaultReasoningEffort,
            effortVariant: option.effortVariant
        )
    }

    /// Mirrors the session controller's Auto detection so the provider's Auto entry is projected
    /// as CE's single pinned `auto` option instead of appearing twice.
    private static func isAutoOption(_ option: AgentModelOption) -> Bool {
        canonicalIdentity(option.rawValue) == autoIdentity
            || canonicalIdentity(option.displayName) == autoIdentity
    }
}
