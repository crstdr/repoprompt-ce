import Foundation
@testable import RepoPromptApp
import RepoPromptInstrumentation
import XCTest

@MainActor
final class AgentSidebarMenuDiagnosticsTests: XCTestCase {
    private enum ProviderLaunch: Error { case refused }

    private final class Sink: AgentSessionLinkCatalogEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentSessionLinkCatalogEvent] = []
        var events: [AgentSessionLinkCatalogEvent] {
            lock.withLock { stored }
        }

        func record(_ event: AgentSessionLinkCatalogEvent) {
            lock.withLock { stored.append(event) }
        }
    }

    private func makeVM(sink: Sink) -> AgentModeViewModel {
        let attempts = LifecycleRecorder()
        let vm = AgentModeViewModel(
            testWindowID: 77,
            codexControllerFactory: { _, _, _, _, _, _ in
                attempts.record("codex")
                return LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            claudeControllerFactory: { _, _, _, _ in
                attempts.record("claude")
                return MonitorFakeNativeController()
            },
            headlessProviderFactory: { _, _ in
                attempts.record("headless")
                return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            },
            acpProviderFactory: { _, _ in
                attempts.record("acp-provider")
                throw ProviderLaunch.refused
            },
            acpControllerFactory: { _, _ in
                attempts.record("acp-controller")
                throw ProviderLaunch.refused
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpRunRoutingCleaner: { _, _, _ in },
            mcpServerEnabler: { false },
            testCatalogDiagnosticsSink: sink
        )
        addTeardownBlock { XCTAssertTrue(attempts.events.isEmpty, "diagnostics must not request a provider") }
        return vm
    }

    func testUnavailableEventSamplesSelectionAndDynamicOwnerWithoutChangingTheGuard() throws {
        let sink = Sink()
        let vm = makeVM(sink: sink)
        var owner: Bool? = true
        vm.sidebarMenuIsRegisteredWindowVM = { owner }
        for (selected, expectedOwner) in [(true, true as Bool?), (false, false as Bool?), (true, nil)] {
            let tabID = UUID()
            owner = expectedOwner
            vm.test_setCurrentTabIDOverride(selected ? tabID : UUID())
            XCTAssertNil(vm.agentSidebarOversightMenuProps(tabID: tabID, expectedSessionID: UUID(), diagnoseUnavailable: true))
            let before = sink.events.count
            XCTAssertNil(vm.agentSidebarOversightMenuProps(tabID: tabID, expectedSessionID: UUID(), diagnoseUnavailable: true))
            XCTAssertEqual(sink.events.count, before, "the existing per-row suppression remains in force")
            guard case let .sidebarMenuUnavailable(reason, _, _, _, _, present, _, current, registered, removed) = try XCTUnwrap(sink.events.last) else {
                return XCTFail("expected the unavailable event")
            }
            XCTAssertEqual(reason, .sessionUUIDMissing)
            XCTAssertFalse(present)
            XCTAssertEqual(current, selected)
            XCTAssertEqual(registered, expectedOwner)
            XCTAssertEqual(removed, false)
        }
    }

    func testRuntimeRemovalHistoryIsBoundedAndUnknownOnlyAfterDistinctOverflow() throws {
        let sink = Sink()
        let vm = makeVM(sink: sink)
        let removedTabs = (0 ..< 128).map { _ in UUID() }
        for tabID in removedTabs {
            _ = vm.session(for: tabID, createIfNeeded: true)
            vm.test_removeSession(tabID: tabID)
        }
        let first = try XCTUnwrap(removedTabs.first)
        _ = vm.session(for: first, createIfNeeded: true)
        vm.test_removeSession(tabID: first)
        XCTAssertEqual(vm.sidebarRemovedRuntimeTabIDs.count, 128)
        XCTAssertFalse(vm.sidebarRuntimeRemovalHistoryOverflowed, "repeated removals do not saturate the history")
        let overflowTab = UUID()
        _ = vm.session(for: overflowTab, createIfNeeded: true)
        vm.test_removeSession(tabID: overflowTab)
        XCTAssertEqual(vm.sidebarRemovedRuntimeTabIDs.count, 128)
        XCTAssertTrue(vm.sidebarRuntimeRemovalHistoryOverflowed)
        for (tabID, expectedRemoved) in [(first, true as Bool?), (overflowTab, nil), (UUID(), nil)] {
            XCTAssertNil(vm.agentSidebarOversightMenuProps(tabID: tabID, expectedSessionID: UUID(), diagnoseUnavailable: true))
            guard case let .sidebarMenuUnavailable(_, _, _, _, _, _, _, _, _, removed) = try XCTUnwrap(sink.events.last) else {
                return XCTFail("expected the unavailable event")
            }
            XCTAssertEqual(removed, expectedRemoved)
        }
    }

    func testUnavailableEventFormattingUsesOnlyHashesAndClosedStateValues() {
        let tabID = UUID()
        let sessionID = UUID()
        for state in [true as Bool?, false, nil] {
            let line = AgentSessionLinkCatalogDiagnostics.sidebarMenuUnavailable(
                reason: .sessionUUIDMissing, windowID: 77, tabID: tabID,
                expectedSessionID: sessionID, currentSessionID: nil, tabPresent: false, bindingNil: false,
                rowIsCurrentTab: true, vmIsRegisteredWindowVM: state, runtimeEntryEverRemoved: state
            )
            let value = state.map(String.init) ?? "unknown"
            XCTAssertTrue(line.hasSuffix("row_is_current_tab=true vm_is_registered_window_vm=\(value) runtime_entry_ever_removed=\(value)"))
            let pattern = "^event=sidebar-menu-unavailable guard=session_uuid_missing window=77 tab=[0-9a-f]{12} expected=[0-9a-f]{12} current=nil same_uuid=false tab_present=false binding_nil=false "
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression))
            XCTAssertFalse(line.lowercased().contains(tabID.uuidString.lowercased()))
            XCTAssertFalse(line.lowercased().contains(sessionID.uuidString.lowercased()))
            XCTAssertFalse(line.contains("/"), "no filesystem paths may enter the event")
        }
    }
}
