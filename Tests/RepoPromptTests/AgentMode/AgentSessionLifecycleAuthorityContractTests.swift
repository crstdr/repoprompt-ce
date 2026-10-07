import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionLifecycleAuthorityContractTests: XCTestCase {
    func testCanonicalPresenceRearmsMissingWorkspaceRepair() {
        let authority = AgentSessionLifecycleAuthority()
        let tab = ComposeTabState(isPinned: true)
        let workspace = WorkspaceModel(name: "Protected", repoPaths: [], composeTabs: [tab], activeComposeTabID: tab.id)
        let claim = AgentSessionLifecycleAuthority.ProtectionClaim(
            identity: .init(workspaceID: workspace.id, tabID: tab.id, sessionID: nil, persistentBindingGeneration: nil, bindingTransitionGeneration: 0),
            tab: tab, isLive: false, isActive: true, isPinned: true, hasActiveRun: false
        )
        func reconcile(_ projected: [WorkspaceModel], baseline: AgentSessionLifecycleAuthority.ProjectionRepairBaseline) -> AgentSessionLifecycleAuthority.ProjectionOutcome {
            authority.reconcileProjection(projectedWorkspaces: projected, currentWorkspaces: [workspace], claims: [claim], repairBaselines: [workspace.id: baseline])
        }
        XCTAssertEqual(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs, [workspace.id])
        XCTAssertTrue(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs.isEmpty)
        XCTAssertTrue(reconcile([workspace], baseline: .working(revision: 1, digest: "restored")).newlyRequiredRepairWorkspaceIDs.isEmpty)
        XCTAssertEqual(reconcile([], baseline: .absent).newlyRequiredRepairWorkspaceIDs, [workspace.id])
    }

    func testAlreadySavedWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testPersistedTargetWorkspaceIsAdmittedWhenBindingIsCurrent() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: workspaceID,
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .commit
        )
    }

    func testRejectedPersistenceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .rejected(reason: "save rejected"),
                targetWorkspaceID: UUID(),
                bindingStillCurrent: true
            ),
            .rollback(.workspacePersistenceRejected)
        )
    }

    func testStaleBindingRollsBackAfterAcceptedPersistence() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .notRequired(workspaceID: workspaceID),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: false
            ),
            .rollback(.sessionIdentityChanged)
        )
    }

    func testPersistedDifferentWorkspaceRollsBack() {
        let authority = AgentSessionLifecycleAuthority()
        let workspaceID = UUID()

        XCTAssertEqual(
            authority.decideAdmission(
                persistence: .persisted(
                    workspaceID: UUID(),
                    stateVersion: 7
                ),
                targetWorkspaceID: workspaceID,
                bindingStillCurrent: true
            ),
            .rollback(.workspaceChanged)
        )
    }
}
