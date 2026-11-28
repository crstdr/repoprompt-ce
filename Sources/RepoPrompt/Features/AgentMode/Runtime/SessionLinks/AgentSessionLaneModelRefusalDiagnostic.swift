import os
import RepoPromptAIContracts

enum AgentSessionLaneModelRefusalDiagnostic {
    enum Stage: String {
        case initialResolution = "initial_resolution"
        case preAllocationRevalidation = "pre_allocation_revalidation"
    }

    enum Reason {
        case admission(AgentModelCatalogRuntime.AdmissionError)
        case selectionChanged

        var code: String {
            switch self {
            case let .admission(error): error.diagnosticCode
            case .selectionChanged: "model_selection_changed"
            }
        }
    }

    private static let log = OSLog(subsystem: "com.repoprompt.ce", category: "LaneModelAdmission")

    static func record(
        stage: Stage, reason: Reason, provider: AgentProviderKind?, windowID: Int,
        emit: (String) -> Void = { os_log("%{public}@", log: log, type: .default, $0) }
    ) {
        emit("Lane model refused stage=\(stage.rawValue) reason=\(reason.code) provider=\(provider?.rawValue ?? "unknown") destination_window=\(windowID)")
    }
}
