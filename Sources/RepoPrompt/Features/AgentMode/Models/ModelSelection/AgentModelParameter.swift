import Foundation
import RepoPromptSettingsCore

enum ACPModelParameterResolver {
    static func resolve(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection],
        workspacePath: String? = nil,
        openCodeParameters: OpenCodeACPModelParameterSnapshot? = nil
    ) -> [ACPResolvedModelParameter] {
        guard let parameterSet = parameterSet(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            workspacePath: workspacePath,
            openCodeParameters: openCodeParameters
        ) else { return [] }
        return resolve(
            parameterSet: parameterSet,
            providerID: providerID,
            persistedSelections: providerID == .cursor
                ? effectiveSelections(providerID: providerID, selectedModelRaw: selectedModelRaw, persistedSelections: persistedSelections)
                : persistedSelections
        )
    }

    private static func resolve(
        parameterSet: ACPModelParameterSet,
        providerID: ACPProviderID,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPResolvedModelParameter] {
        parameterSet.parameters.sorted { $0.kind.sortOrder < $1.kind.sortOrder }.compactMap { definition in
            let definitionIdentity = ACPModelParameterIdentity(
                providerID: providerID,
                baseModelRaw: parameterSet.baseModelRaw,
                kind: definition.kind
            )
            let saved = persistedSelections.last { selection in
                selection.identity == definitionIdentity
            }
            // Show unsupported saved intent, not a default the next run will never use.
            let savedChoice = saved.flatMap { selection in
                definition.choice(matching: selection.valueRaw)
                    ?? (
                        providerID == .openCode || providerID == .devin || providerID == .cursor
                            ? ACPModelParameterChoice(rawValue: selection.valueRaw, displayName: selection.valueRaw)
                            : nil
                    )
            }
            guard let selectedChoice = savedChoice ?? definition.choice(matching: definition.currentValueRaw)
            else { return nil }
            return .init(
                baseModelRaw: parameterSet.baseModelRaw,
                definition: definition,
                selectedChoice: selectedChoice
            )
        }
    }

    static func parameterSet(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        workspacePath: String? = nil,
        openCodeParameters: OpenCodeACPModelParameterSnapshot? = nil
    ) -> ACPModelParameterSet? {
        switch providerID {
        case .cursor:
            CursorAIModelCatalog.parameterSet(for: selectedModelRaw)
        case .openCode:
            openCodeParameterSet(
                selectedModelRaw: selectedModelRaw,
                workspacePath: workspacePath,
                observation: openCodeParameters
            )
        case .devin:
            devinParameterSet(selectedModelRaw: selectedModelRaw)
        default:
            nil
        }
    }

    private static func devinParameterSet(selectedModelRaw: String) -> ACPModelParameterSet? {
        let identity = ACPModelParameterIdentity.canonicalBaseModelRaw(selectedModelRaw, providerID: .devin)
        let matches = AgentACPModelRegistry.shared.resolvedSnapshot(for: .devin)?.modelParameterSets.filter {
            ACPModelParameterIdentity.canonicalBaseModelRaw($0.baseModelRaw, providerID: .devin) == identity
        } ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    /// Accept OpenCode metadata only when the observation is `.available`, its key matches the
    /// requested normalized workspace+model exactly, and the advertised set matches that model
    /// unambiguously. Missing or mismatched context yields no parameter set — never a fall back
    /// to the provider-global registry, whose per-provider snapshot cannot represent the
    /// demand-scoped `(workspace, model)` authority.
    private static func openCodeParameterSet(
        selectedModelRaw: String,
        workspacePath: String?,
        observation: OpenCodeACPModelParameterSnapshot?
    ) -> ACPModelParameterSet? {
        guard let observation,
              case let .available(parameterSet) = observation.state
        else { return nil }
        let targetIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            selectedModelRaw,
            providerID: .openCode
        )
        // Compare the constructed expected key directly; `observation.key`'s fields are already
        // canonical at construction, so re-canonicalizing them would be a no-op. Key equality
        // covers both the canonical model identity and the normalized workspace.
        let expectedKey = OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: selectedModelRaw)
        guard observation.key == expectedKey else { return nil }
        guard ACPModelParameterIdentity.canonicalBaseModelRaw(
            parameterSet.baseModelRaw,
            providerID: .openCode
        ) == targetIdentity else { return nil }
        return parameterSet
    }

    static func effectiveSelections(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPModelParameterSelection] {
        var selections = persistedSelections
        if providerID == .cursor,
           let specifier = try? CursorAIModelCatalog.ModelSpecifier(raw: selectedModelRaw),
           let encoded = try? specifier.selections(in: AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor), ignoringUnavailable: true)
        {
            // A later explicit chip/session write supersedes the model-string's inherited pin.
            selections = ACPModelParameterSelection.normalized(encoded.map { ACPModelParameterSelection(providerID: .cursor, baseModelRaw: $0.baseModelRaw, kind: $0.kind, configID: $0.configID, valueRaw: $0.valueRaw) } + persistedSelections)
        }
        return ACPModelParameterSelection.selections(
            for: providerID,
            activeBaseModelRaw: selectedModelRaw,
            from: selections
        )
    }
}
