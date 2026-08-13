import Foundation

/// Global dashboard ordering preference. Raw values are stable `UserDefaults` compatibility keys.
enum AgentMonitorDashboardSortMode: String, CaseIterable, Identifiable {
    static let preferenceKey = "agentMonitor.dashboard.sortMode"

    case smart
    case recentActivity = "recent_activity"
    case name

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .smart: "Smart"
        case .recentActivity: "Recent activity"
        case .name: "Name"
        }
    }

    static func resolved(preferenceRawValue: String?) -> AgentMonitorDashboardSortMode {
        preferenceRawValue.flatMap(Self.init(rawValue:)) ?? .smart
    }
}

/// Pure, deterministic ordering for outbound dashboard rows.
enum AgentMonitorDashboardSortPolicy {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    static func sorted(
        _ rows: [AgentMonitorPillProps.Outbound],
        mode: AgentMonitorDashboardSortMode
    ) -> [AgentMonitorPillProps.Outbound] {
        rows.sorted { lhs, rhs in
            compare(lhs, rhs, mode: mode)
        }
    }

    private static func compare(
        _ lhs: AgentMonitorPillProps.Outbound,
        _ rhs: AgentMonitorPillProps.Outbound,
        mode: AgentMonitorDashboardSortMode
    ) -> Bool {
        if lhs.triageState != rhs.triageState {
            return lhs.triageState == .active
        }

        switch mode {
        case .smart:
            if lhs.triageState == .active {
                let lhsRank = smartRank(lhs.status)
                let rhsRank = smartRank(rhs.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            }
            if let result = compareActivity(lhs.lastActivityAt, rhs.lastActivityAt) { return result }
            if let result = compareName(lhs.displayName, rhs.displayName) { return result }
        case .recentActivity:
            if let result = compareActivity(lhs.lastActivityAt, rhs.lastActivityAt) { return result }
            if let result = compareName(lhs.displayName, rhs.displayName) { return result }
        case .name:
            if let result = compareName(lhs.displayName, rhs.displayName) { return result }
            if let result = compareActivity(lhs.lastActivityAt, rhs.lastActivityAt) { return result }
        }

        let lhsTarget = lhs.targetSessionID.uuidString
        let rhsTarget = rhs.targetSessionID.uuidString
        if lhsTarget != rhsTarget { return lhsTarget < rhsTarget }
        return lhs.linkID.uuidString < rhs.linkID.uuidString
    }

    private static func smartRank(_ status: AgentMonitorLinkStatus) -> Int {
        switch status {
        case .awaitingUser: 0
        case .idle: 1
        case .running: 2
        case .unavailable: 3
        }
    }

    /// `nil` means equal and the caller should continue to the next deterministic key.
    private static func compareActivity(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            lhs > rhs
        case (_?, nil):
            true
        case (nil, _?):
            false
        case (nil, nil), (_?, _?):
            nil
        }
    }

    /// `nil` means equal after fixed-locale case/diacritic folding.
    private static func compareName(_ lhs: String, _ rhs: String) -> Bool? {
        let lhsFolded = lhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
        let rhsFolded = rhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
        guard lhsFolded != rhsFolded else { return nil }
        return lhsFolded < rhsFolded
    }
}
