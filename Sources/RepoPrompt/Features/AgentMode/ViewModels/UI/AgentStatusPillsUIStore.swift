import Combine
import Foundation
import RepoPromptInstrumentation

struct AgentExecutionLocationProps: Equatable {
    let tabID: UUID
    let selection: AgentModeViewModel.InitialStartLocation
    let indicator: AgentWorktreeIndicator?
    let isInitialSelection: Bool
    let isEnabled: Bool
    let isOperationInProgress: Bool
    let requiresActiveRunConfirmation: Bool
    let disabledReason: String?
}

struct AgentModelRouterPillProps: Equatable {
    let isOn: Bool
    let isAvailable: Bool
    let isRouting: Bool
    let disabledReason: String?
    /// Usage balancing is independent of Jev; the router pill surfaces it as a badge.
    let routedModelDisplayName: String?
    var usageBalancing = false
}

struct AgentAutoEffortPillProps: Equatable {
    let isOn: Bool
    let isAvailable: Bool
    let isJudging: Bool
    let feedback: AutoEffortTurnFeedback?
}

struct AgentRepromptPillProps: Equatable {
    var isOn = false
    var isAvailable = false
    var isPreparing = false
    var modelDisplayName: String?
    var providerID: String?
    var requiresDisclosure = false
    var unavailableReason: String?
}

struct AgentStatusPillsSnapshot: Equatable {
    let currentTabID: UUID?
    let selectedWorkflow: AgentWorkflowDefinition?
    let stagedSlashCommand: AgentStagedSlashCommandProps?
    let selectedAgent: AgentProviderKind
    let autoEditPermissionGuidance: AgentModeViewModel.AutoEditPermissionGuidance?
    let runState: AgentSessionRunState
    let autoEditEnabled: Bool
    let interviewFirst: Bool
    let modelRouter: AgentModelRouterPillProps
    let autoEffort: AgentAutoEffortPillProps
    let executionLocation: AgentExecutionLocationProps?
    let activeAgentSessionID: UUID?
    let activeRunID: UUID?
    /// Cross-window oversight projection for the tab currently on screen.
    ///
    /// It lives in this snapshot so the pill row never has to observe the full view model; the link
    /// bridge owns the values and republishes them from authority change events.
    let monitor: AgentMonitorPillProps
    var reprompt = AgentRepromptPillProps()

    static let empty = AgentStatusPillsSnapshot(
        currentTabID: nil,
        selectedWorkflow: nil,
        stagedSlashCommand: nil,
        selectedAgent: .claudeCode,
        autoEditPermissionGuidance: nil,
        runState: .idle,
        autoEditEnabled: ApplyEditsApprovalStore.globalDefaultAutoEditEnabled(),
        interviewFirst: false,
        modelRouter: AgentModelRouterPillProps(
            isOn: false,
            isAvailable: false,
            isRouting: false,
            disabledReason: "Configure Model Router in Settings.",
            routedModelDisplayName: nil
        ),
        autoEffort: AgentAutoEffortPillProps(
            isOn: false,
            isAvailable: false,
            isJudging: false,
            feedback: nil
        ),
        executionLocation: nil,
        activeAgentSessionID: nil,
        activeRunID: nil,
        monitor: .empty
    )
}

@MainActor
final class AgentStatusPillsUIStore: ObservableObject {
    var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    @Published private(set) var snapshot: AgentStatusPillsSnapshot
    @Published private(set) var revision: UInt64 = 0
    var didPublishPresentation: (() -> Void)?
    var shouldPublishPresentation: (() -> Bool)?
    private(set) var latestSnapshot: AgentStatusPillsSnapshot
    private var latestRevision: UInt64 = 0
    private var isPublishing = false

    init(snapshot: AgentStatusPillsSnapshot = .empty) {
        self.snapshot = snapshot
        latestSnapshot = snapshot
    }

    func update(_ nextSnapshot: AgentStatusPillsSnapshot) {
        if latestSnapshot != nextSnapshot {
            latestSnapshot = nextSnapshot
            latestRevision &+= 1
        } else {
            #if DEBUG
                perfRecorder.recordStoreUpdate("statusPills", published: false)
            #endif
        }
        // A synchronous willSet subscriber may issue a newer update. Finish this assignment
        // before draining that latest value, and fence the separate revision publication too.
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }
        while snapshot != latestSnapshot || revision != latestRevision {
            if snapshot != latestSnapshot {
                guard shouldPublishPresentation?() ?? true else { return }
                snapshot = latestSnapshot
                didPublishPresentation?()
                #if DEBUG
                    perfRecorder.recordStoreUpdate("statusPills", published: true, details: [
                        "revision": String(latestRevision),
                        "runState": String(describing: snapshot.runState),
                        "tabID": perfRecorder.shortID(snapshot.currentTabID)
                    ])
                #endif
                // A willSet subscriber may have requested a newer snapshot. Publish its revision
                // only after that snapshot has actually finished assigning.
                continue
            }
            if revision != latestRevision {
                guard shouldPublishPresentation?() ?? true else { return }
                revision = latestRevision
            }
        }
    }
}
