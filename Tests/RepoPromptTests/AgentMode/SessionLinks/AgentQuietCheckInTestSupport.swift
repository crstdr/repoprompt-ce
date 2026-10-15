import Foundation
@_spi(TestSupport) @testable import RepoPromptApp

/// Small source/lifecycle fixture shared by pure quiet tests and later native replay fixtures.
@MainActor
struct AgentQuietCheckInFixture {
    var ledger = AgentRunQuietLedger()
    let owner = AgentRunOwnership(binding: AgentRunBindingIdentity(tabID: UUID(), persistentSessionID: UUID()))
    let wakeID = UUID()
    let startKey = 10

    mutating func begin(provider: AgentSessionLinkPromptProviderContext = .codexExec, routine: Bool = true) {
        ledger.begin(owner: owner, startKey: startKey, provider: provider)
        if routine { ledger.markRoutineWake(owner: owner, wakeID: wakeID) }
    }

    func rows(_ texts: [String], kind: AgentChatItemKind = .assistant) -> [AgentChatItem] {
        texts.enumerated().map { offset, text in
            AgentChatItem(kind: kind, text: text, sequenceIndex: startKey + offset)
        }
    }

    @discardableResult
    mutating func seal(
        _ rows: [AgentChatItem] = [],
        state: AgentSessionRunState = .completed,
        normal: Bool = true,
        successor: Bool = false,
        complete: Bool = true
    ) -> AgentRunQuietLedger.Seal? {
        ledger.settle(
            owner: owner,
            terminalState: state,
            classifiesQuietCheckIn: normal,
            hasSuccessor: successor,
            endKey: rows.last?.sequenceIndex ?? startKey - 1,
            rangeIsComplete: complete,
            rows: rows
        )
    }
}
