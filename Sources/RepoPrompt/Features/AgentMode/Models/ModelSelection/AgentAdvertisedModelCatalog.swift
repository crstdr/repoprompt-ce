import Foundation

/// Admission over the already-advertised catalogue, never a discovery or persistence entrypoint.
/// Producers refresh this index while building ordinary picker/list_agents options. A cold or
/// invalidated index fails closed; an oversight request must not warm it on the caller's behalf.
final class AgentAdvertisedModelCatalog: @unchecked Sendable {
    static let shared = AgentAdvertisedModelCatalog()
    private let lock = NSLock()
    private struct Entry {
        let option: AgentModelOption
        let reasoningEffortRaw: String?
    }

    private var optionsByAgent: [AgentProviderKind: [String: Entry]] = [:]

    func record(_ options: [AgentModelOption], for agent: AgentProviderKind) {
        // Decomposition belongs to the producer too: Codex's legacy parser can consult persisted
        // discovery for extended effort suffixes. Never invoke that default parser during admission.
        let index = options.reduce(into: [String: Entry]()) { index, option in
            let effort: String? = if agent == .codexExec {
                CodexModelSpecifier(raw: option.rawValue).reasoningEffort?.rawValue
            } else if agent.usesClaudeTooling {
                ClaudeModelSpecifier(raw: option.rawValue).effortLevel?.rawValue
            } else { nil }
            index[option.rawValue] = Entry(option: option, reasoningEffortRaw: effort)
        }
        lock.withLock { optionsByAgent[agent] = index }
    }

    func invalidate(_ agent: AgentProviderKind) {
        _ = lock.withLock { optionsByAgent.removeValue(forKey: agent) }
    }

    func selection(
        _ modelID: String,
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> Selection {
        guard let id = AgentModelSelectionID.parse(modelID),
              let agent = AgentProviderKind(rawValue: id.agentRaw),
              id.rawValue == modelID
        else { throw AdmissionError.invalidID }
        guard AgentModelCatalog.isAgentAvailable(agent, availability: availability) else {
            throw AdmissionError.unavailable
        }
        let entry: Entry = try lock.withLock {
            guard let index = optionsByAgent[agent] else { throw AdmissionError.catalogueUnavailable }
            guard let option = index[id.modelRaw] else { throw AdmissionError.unadvertised }
            return option
        }
        return Selection(id: id, agent: agent, option: entry.option, reasoningEffortRaw: entry.reasoningEffortRaw)
    }

    struct Selection {
        let id: AgentModelSelectionID
        let agent: AgentProviderKind
        let option: AgentModelOption

        /// Validate the complete encoded ID before decomposing it. Keep native effort encoded so
        /// manually created sessions use the same next-turn baseline as MCP-created sessions.
        var storedModelRaw: String {
            id.modelRaw
        }

        let reasoningEffortRaw: String?
    }

    enum AdmissionError: Error, Equatable {
        case invalidID, unavailable, catalogueUnavailable, unadvertised

        var message: String {
            switch self {
            case .invalidID:
                "model_id must be an exact compound ID from agent_manage.list_agents, not a role."
            case .unavailable:
                "The selected agent is unavailable in the destination window. Refresh agent_manage.list_agents there."
            case .catalogueUnavailable:
                "The in-memory model catalogue is unavailable. Refresh agent_manage.list_agents in the destination window, then retry; this operation does not discover models."
            case .unadvertised:
                "model_id is not in the current advertised catalogue. Refresh agent_manage.list_agents in the destination window and use an exact returned model_id."
            }
        }
    }
}
