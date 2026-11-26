//
//  Debouncer.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-07-19.
//

import Foundation

/// Coalesces delayed work items so only the latest runs, unless explicitly canceled.
final class WorkItemGate {
    private let lock = DispatchQueue(label: "WorkItemGate.lock")
    private var generation: UInt64 = 0

    private func nextToken() -> UInt64 {
        lock.sync {
            generation &+= 1
            return generation
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.sync { generation == token }
    }

    @discardableResult
    func makeWorkItem(action: @escaping () -> Void) -> DispatchWorkItem {
        let token = nextToken()
        return DispatchWorkItem { [weak self] in
            guard let self, isCurrent(token) else { return }
            action()
        }
    }

    @discardableResult
    func schedule(on queue: DispatchQueue = .main, after delay: TimeInterval = 0, action: @escaping () -> Void) -> DispatchWorkItem {
        let item = makeWorkItem(action: action)
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            queue.async(execute: item)
        }
        return item
    }

    func cancel() {
        _ = nextToken()
    }
}

@MainActor
final class ProgrammaticScrollGate {
    private let workGate = WorkItemGate()
    private var scheduledScrollWorkItem: DispatchWorkItem?
    private var settleWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0
    private(set) var isInFlight = false

    func schedule(
        after delay: TimeInterval = 0,
        settleAfter settleDelay: TimeInterval = 0.25,
        onSettled: (() -> Void)?,
        action: @escaping () -> Void
    ) {
        schedule(after: delay, settleAfter: settleDelay, onSettled: onSettled, deferredAction: { finish in
            action()
            finish()
        })
    }

    func schedule(
        after delay: TimeInterval,
        settleAfter settleDelay: TimeInterval,
        onSettled: (() -> Void)?,
        deferredAction: @escaping (@escaping () -> Void) -> Void
    ) {
        cancelPendingWork(resetInFlight: false)
        let generation = generation
        isInFlight = true
        scheduledScrollWorkItem = workGate.schedule(after: delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            deferredAction { [weak self] in
                guard let self, self.generation == generation, settleWorkItem == nil else { return }
                settleWorkItem = workGate.schedule(after: max(0, settleDelay)) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    isInFlight = false
                    onSettled?()
                }
            }
        }
    }

    func schedule(
        after delay: TimeInterval = 0,
        settleAfter settleDelay: TimeInterval = 0.25,
        action: @escaping () -> Void
    ) {
        schedule(after: delay, settleAfter: settleDelay, onSettled: nil, action: action)
    }

    func cancel() {
        cancelPendingWork(resetInFlight: true)
    }

    private func cancelPendingWork(resetInFlight: Bool) {
        generation &+= 1
        scheduledScrollWorkItem?.cancel()
        settleWorkItem?.cancel()
        workGate.cancel()
        scheduledScrollWorkItem = nil
        settleWorkItem = nil
        if resetInFlight {
            isInFlight = false
        }
    }
}

class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?
    private let workGate = WorkItemGate()

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func debounce(action: @escaping () -> Void) {
        workItem?.cancel()
        workItem = workGate.schedule(after: delay) {
            action()
        }
    }
}

import Combine

func debounce<T>(_ duration: TimeInterval = 0.3) -> Publishers.Debounce<PassthroughSubject<T, Never>, DispatchQueue> {
    let subject = PassthroughSubject<T, Never>()
    return subject.debounce(for: .seconds(duration), scheduler: DispatchQueue.main)
}
