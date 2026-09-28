import Foundation

/// A provider follow-up and its separately typed, locally restorable draft. Provider text
/// may mix local and managed ACP steering; its contents never establish draft authorship.
struct AgentRunPendingInstruction: Equatable, ExpressibleByStringLiteral {
    let providerText: String
    let localDraftText: String?

    init(providerText: String, localDraftText: String?) {
        self.providerText = providerText
        self.localDraftText = localDraftText
    }

    init(stringLiteral value: String) {
        self.init(providerText: value, localDraftText: value)
    }

    static func providerOnly(_ text: String) -> Self {
        Self(providerText: text, localDraftText: nil)
    }
}
