import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionLanePolicyTests: XCTestCase {
    func testCapCountsOnlyDistinctLiveLinkedLanesCreatedByCaller() {
        XCTAssertEqual(AgentSessionLanePolicy.agentSessionLaneMaximumCount, 8)
        let creator = UUID()
        let otherCreator = UUID()
        let owned = UUID()
        let other = UUID()
        let ordinary = UUID()
        let orphan = UUID()
        let provenance: [UUID: UUID] = [owned: creator, other: otherCreator, orphan: creator]
        XCTAssertEqual(
            AgentSessionLanePolicy.linkedCreatedLaneCount(
                targetSessionIDs: [owned, owned, other, ordinary],
                creatorSessionID: creator,
                createdBy: { provenance[$0] }
            ),
            1,
            "an unlinked orphan and a duplicate grant target consume no extra slot"
        )
    }

    @MainActor
    func testEveryRoleUsesItsEffectiveRoleDefaultAndMappedEffort() throws {
        let workspaceID = UUID()
        let overrides = Dictionary(
            uniqueKeysWithValues: AgentModelCatalog.TaskLabelKind.allCases.map {
                ($0.rawValue, "codexExec:gpt-5.4-high")
            }
        )
        let settings = AgentModelsProfileRoleDefaultsStore(overrides: overrides)
        let availability = AgentModelCatalog.AvailabilityContext()
        for role in AgentModelCatalog.TaskLabelKind.allCases {
            let selected = try AgentSessionLanePolicy.resolveRole(
                role.rawValue,
                availability: availability,
                workspaceID: workspaceID,
                settingsStore: settings
            )
            XCTAssertEqual(selected.role, role)
            XCTAssertEqual(selected.agentRaw, AgentProviderKind.codexExec.rawValue)
            XCTAssertEqual(selected.modelRaw, "gpt-5.4-high")
            XCTAssertEqual(selected.reasoningEffortRaw, "high")
        }
    }

    @MainActor
    func testFreshHandoffDestinationDoesNotInheritCreatorProvenance() {
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        let destination = viewModel.session(for: UUID())
        destination.createdByOverseerSessionID = UUID()
        viewModel.markSessionAsFreshlyCreated(destination)
        XCTAssertNil(destination.createdByOverseerSessionID)
        XCTAssertNil(AgentSession(id: UUID()).createdByOverseerSessionID)
    }

    @MainActor
    func testUnmappedOrUnusableRolesFailClosedWithoutSubstitution() {
        let availability = AgentModelCatalog.AvailabilityContext()
        let workspaceID = UUID()
        let badOverride = AgentModelsProfileRoleDefaultsStore(overrides: ["pair": "no-such-provider:model"])
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: badOverride
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "unrecognized",
            availability: availability,
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
        XCTAssertThrowsError(try AgentSessionLanePolicy.resolveRole(
            "pair",
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: false
            ),
            workspaceID: workspaceID
        )) { error in
            XCTAssertEqual(error as? AgentSessionLanePolicy.RoleResolutionError, .roleUnavailable)
        }
    }
}
