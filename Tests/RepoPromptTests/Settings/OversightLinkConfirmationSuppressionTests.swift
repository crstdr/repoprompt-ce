import Foundation
@testable import RepoPromptApp
import XCTest

/// The suppression flag is one app-global UI preference. It must default to asking, persist
/// across reloads only after an *accepted* confirmation, and never disturb unrelated settings.
@MainActor
final class OversightLinkConfirmationSuppressionTests: XCTestCase {
    private func makeStore() throws -> (GlobalSettingsStore, GlobalSettingsFileStore, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        let suite = "OversightLinkConfirmationSuppressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (
            GlobalSettingsStore(defaults: defaults, fileStore: fileStore),
            fileStore,
            root,
            defaults,
            suite
        )
    }

    func testSuppressionDefaultsToAskingAndRoundTrips() throws {
        let (store, fileStore, root, defaults, suite) = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        // Unrelated state to prove the write path preserves it.
        store.setShowBuiltInWorkflowCleanupGuidance(false, commit: false)
        store.setAutoEffortEnabled(true, commit: false)

        XCTAssertFalse(store.suppressOversightLinkConfirmation())

        store.setSuppressOversightLinkConfirmation(true)
        XCTAssertTrue(store.suppressOversightLinkConfirmation())
        let written = try fileStore.load()
        XCTAssertEqual(written.scalarPreferences?.agentMode?.suppressOversightLinkConfirmation, true)
        XCTAssertEqual(written.scalarPreferences?.agentMode?.autoEffortEnabled, true)
        XCTAssertEqual(
            written.scalarPreferences?.agentMode?.showBuiltInWorkflowCleanupGuidance,
            false
        )
        XCTAssertEqual(
            GlobalSettingsDocument(scalarPreferences: .init(
                agentMode: .init(suppressOversightLinkConfirmation: true)
            )).requiredSchemaVersion,
            GlobalSettingsDocument.baselineSchemaVersion
        )

        let reloaded = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "\(suite).reload")),
            fileStore: fileStore
        )
        XCTAssertTrue(reloaded.suppressOversightLinkConfirmation())

        // Clearing returns to the baseline scalar shape for older CE builds.
        reloaded.setSuppressOversightLinkConfirmation(false)
        XCTAssertFalse(reloaded.suppressOversightLinkConfirmation())
        XCTAssertNil(try fileStore.load().scalarPreferences?.agentMode?.suppressOversightLinkConfirmation)
        // Unrelated settings survived every write.
        XCTAssertEqual(try fileStore.load().scalarPreferences?.agentMode?.autoEffortEnabled, true)
    }

    /// Cancel, dismissal, and a checked box that was never accepted must not persist anything.
    /// Only an accepted confirmation with the box checked writes the flag.
    func testSuppressionFlagWritesOnlyAfterAcceptedCheckedConfirmation() throws {
        let (store, _, root, defaults, suite) = try makeStore()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        AgentOversightLinkConfirmation.recordOutcome(
            accepted: false,
            suppressionChecked: true,
            settings: store
        )
        XCTAssertFalse(store.suppressOversightLinkConfirmation())

        AgentOversightLinkConfirmation.recordOutcome(
            accepted: true,
            suppressionChecked: false,
            settings: store
        )
        XCTAssertFalse(store.suppressOversightLinkConfirmation())

        AgentOversightLinkConfirmation.recordOutcome(
            accepted: true,
            suppressionChecked: true,
            settings: store
        )
        XCTAssertTrue(store.suppressOversightLinkConfirmation())
        XCTAssertTrue(AgentOversightLinkConfirmation.isSuppressed(settings: store))
    }
}
