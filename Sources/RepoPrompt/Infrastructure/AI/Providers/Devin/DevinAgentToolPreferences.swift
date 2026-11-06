import Foundation

enum DevinAgentToolPreferences {
    /// Picker order is `allCases` order.
    enum PermissionLevel: String, CaseIterable {
        case providerDefault
        case normal
        case acceptEdits
        case smart
        case fullApproval

        var displayName: String {
            switch self {
            case .providerDefault:
                "Provider Default"
            case .normal:
                "Normal"
            case .acceptEdits:
                "Accept Edits"
            case .smart:
                "Smart"
            case .fullApproval:
                "Full Approval"
            }
        }

        var detailText: String {
            switch self {
            case .providerDefault:
                "Restore the mode advertised when this Devin session opened."
            case .normal:
                "Use Devin's Code mode. Devin ACP has no separate prompt-for-edits mode."
            case .acceptEdits:
                "Use Devin's Code mode; other actions can still ask for approval."
            case .smart:
                "Use Devin's Smart mode when available for this account."
            case .fullApproval:
                "Use Devin's Bypass mode when permitted by this account."
            }
        }

        var iconName: String {
            switch self {
            case .providerDefault:
                "shield"
            case .normal:
                "shield.lefthalf.filled"
            case .acceptEdits:
                "pencil"
            case .smart:
                "sparkles"
            case .fullApproval:
                "exclamationmark.shield.fill"
            }
        }

        /// Only `fullApproval` removes every approval prompt.
        var isWarning: Bool {
            self == .fullApproval
        }

        /// ACP session mode; nil restores the mode advertised when this session opened.
        var sessionModeID: String? {
            switch self {
            case .providerDefault:
                nil
            case .normal, .acceptEdits:
                "accept-edits"
            case .smart:
                "smart"
            case .fullApproval:
                "bypass"
            }
        }

        /// Missing/blank values mean the explicit provider default. Unknown stored values
        /// fail closed to Normal instead of delegating to a potentially broader Devin default.
        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .providerDefault
            }
            return allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) ?? .normal
        }
    }

    private static let permissionLevelKey = "devinPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let document = secureStore.devinPermissions()
            if secureStore.diagnostic(for: .devin) != nil {
                return .normal
            }
            return document.permissionLevel()
        }
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    /// Resolves the `--permission-mode` for unattended launches from the configured level:
    /// explicit Full Approval → `dangerous`, everything else → `auto`. Unattended runs
    /// cannot surface approval prompts — the headless bridge declines them — so only an
    /// explicit Full Approval escalates; intermediate levels presume a person answers the
    /// residual prompts, and mapping them to `auto` keeps unattended behaviour
    /// deterministic. This feeds the non-ACP one-shot CLI only — `devin acp` ignores the
    /// flag entirely, so headless ACP runs get their level from `sessionModeID` instead.
    static func unattendedLaunchPermissionMode(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> String {
        permissionLevel(defaults: defaults, secureStore: secureStore) == .fullApproval ? "dangerous" : "auto"
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            secureStore.setDevinPermissionLevel(level)
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
