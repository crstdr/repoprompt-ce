import SwiftUI

// MARK: - Scroll Driver Seam

/// Placement used when scrolling a transcript block into view.
enum TranscriptScrollBlockPlacement: Equatable {
    case top
    case center

    var unitPoint: UnitPoint {
        switch self {
        case .top:
            .top
        case .center:
            .center
        }
    }
}

/// Everything the transcript scroll container must be able to do on behalf of the
/// scroll engine. All programmatic transcript scrolling funnels through a driver, so
/// alternative containers (for example a virtualized `NSTableView`) can replace the
/// SwiftUI `ScrollViewProxy` implementation without touching engine policy.
@MainActor
protocol TranscriptScrollDriver {
    /// Scrolls so the live bottom of the transcript is visible.
    func scrollToBottom(animated: Bool)

    /// Scrolls so the block with `blockID` is placed at `placement` in the viewport.
    /// No-ops when the container does not currently host that block.
    func scrollToBlock(id blockID: String, placement: TranscriptScrollBlockPlacement, animated: Bool)
}

/// Reports a scroll container sends back to the scroll engine. The SwiftUI container
/// derives these from `onScrollGeometryChange` / `onScrollPhaseChange`; other
/// containers produce the same events from their native scroll notifications.
enum TranscriptScrollDriverEvent: Equatable {
    /// Scroll geometry changed (offset, content size or viewport size).
    case metricsChanged(AgentTranscriptScrollMetrics)
    /// The user/system scroll phase changed. `metrics` is the geometry at the
    /// moment of the transition.
    case phaseChanged(AgentTranscriptUserScrollPhase, metrics: AgentTranscriptScrollMetrics)
}

struct TranscriptBottomRevealRevisionFence {
    let revision: Int
    let allowsRevisionMismatch: Bool

    func permits(_ currentRevision: Int) -> Bool {
        allowsRevisionMismatch || revision == currentRevision
    }
}

/// One admitted request. The pane owns the tasks and applies the resulting scroll action.
struct TranscriptBottomReveal<Scope: Equatable, EntryID: Equatable> {
    static var revealDelay: Duration {
        .milliseconds(24)
    }

    static var deadline: Duration {
        .milliseconds(300)
    }

    enum Event {
        case reveal(UUID)
        case deadline(UUID)
        case row(TranscriptBottomRevealFrame, viewport: CGSize)
        case tail(TranscriptBottomRevealFrame)
    }

    enum Action: Equatable {
        case ignore, cancel, reveal, finish
    }

    let id: UUID
    private(set) var witnessID = UUID()
    let scope: Scope
    private(set) var entryID: EntryID
    let revisionFence: TranscriptBottomRevealRevisionFence

    init(id: UUID = UUID(), scope: Scope, entryID: EntryID, revisionFence: TranscriptBottomRevealRevisionFence) {
        self.id = id
        self.scope = scope
        self.entryID = entryID
        self.revisionFence = revisionFence
    }

    mutating func retarget(scope: Scope, entryID: EntryID?) -> Bool {
        guard self.scope == scope, revisionFence.allowsRevisionMismatch, let entryID else { return false }
        if self.entryID != entryID {
            self.entryID = entryID
            witnessID = UUID()
        }
        return true
    }

    func action(for event: Event, scope: Scope, entryID: EntryID?, revision: Int, canScroll: Bool) -> Action {
        switch event {
        case let .deadline(id):
            guard self.id == id else { return .ignore }
        // Layout may not run in a hidden or busy window. Preserve the original landing
        // when the request still owns the pane, even without a last-row witness.
        case let .reveal(id):
            guard witnessID == id, self.entryID == entryID, self.scope == scope, canScroll else { return .ignore }
        case let .row(frame, viewport):
            guard frame.isVisible(in: viewport), accepts(frame, entryID: entryID, revision: revision) else { return .ignore }
        case let .tail(frame):
            guard frame.frame.minY <= 0, accepts(frame, entryID: entryID, revision: revision) else { return .ignore }
        }
        guard self.scope == scope, canScroll, revisionFence.permits(revision) else { return .cancel }
        if case .reveal = event { return .reveal }
        return .finish
    }

    private func accepts(_ frame: TranscriptBottomRevealFrame, entryID: EntryID?, revision: Int) -> Bool {
        frame.requestID == witnessID && frame.presentationRevision == revision && self.entryID == entryID
    }
}

struct TranscriptBottomRevealFrame: Equatable {
    let requestID: UUID
    let presentationRevision: Int
    let frame: CGRect

    func isVisible(in viewport: CGSize) -> Bool {
        frame.height > 0 && !frame.intersection(CGRect(origin: .zero, size: viewport)).isEmpty
    }
}

enum TranscriptBottomRevealFrameKey: PreferenceKey {
    static let coordinateSpace = "agentTranscript.bottomRevealViewport"
    static var defaultValue: TranscriptBottomRevealFrame? {
        nil
    }

    static func reduce(value: inout TranscriptBottomRevealFrame?, nextValue: () -> TranscriptBottomRevealFrame?) {
        value = nextValue() ?? value
    }
}

struct TranscriptBottomRevealWitness: ViewModifier {
    let requestID: UUID?
    var presentationRevision = 0

    func body(content: Content) -> some View {
        content.background {
            if let requestID {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TranscriptBottomRevealFrameKey.self,
                        value: .init(
                            requestID: requestID,
                            presentationRevision: presentationRevision,
                            frame: geometry.frame(in: .named(TranscriptBottomRevealFrameKey.coordinateSpace))
                        )
                    )
                }
            }
        }
    }
}

// MARK: - SwiftUI ScrollViewProxy Driver

/// `TranscriptScrollDriver` backed by a SwiftUI `ScrollViewProxy`. Scroll targets are
/// the `.id(_:)` values applied to transcript block rows plus the bottom sentinel.
struct SwiftUITranscriptScrollDriver: TranscriptScrollDriver {
    /// `.id(_:)` of the zero-height view placed after the last transcript row.
    static let bottomTargetID = "bottomTarget"

    let proxy: ScrollViewProxy

    func scrollToBottom(animated: Bool) {
        perform(animated: animated) {
            proxy.scrollTo(Self.bottomTargetID, anchor: .bottom)
        }
    }

    func revealBottomEntry(id: AnyHashable, animated: Bool = false) {
        perform(animated: animated) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    func scrollToBlock(id blockID: String, placement: TranscriptScrollBlockPlacement, animated: Bool) {
        perform(animated: animated) {
            proxy.scrollTo(blockID, anchor: placement.unitPoint)
        }
    }

    private func perform(animated: Bool, _ scroll: () -> Void) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scroll()
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scroll()
            }
        }
    }
}
