//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
package import SWBProtocol
package import SWBUtil
import Synchronization

package final class DependencyGraphRequestCoordinator: Sendable {
    package enum Lane: Sendable {
        case index
        case foreground
    }

    package enum Outcome: Equatable, Sendable {
        case success(DependencyGraphResponse)
        case failure(String)
        case cancelled
    }

    package typealias Completion = @Sendable (Outcome) -> Void

    private struct Operation: Sendable {
        let task: _Concurrency.Task<Void, Never>
        let completion: Completion
    }

    private struct DrainingTask: Sendable {
        let task: _Concurrency.Task<Void, Never>
        var operationFinished: Bool
        var replyFinished: Bool
    }

    private struct State: ~Copyable {
        var acceptsNewOperations = true
        var operations: [UUID: Operation] = [:]
        var drainingTasks: [UUID: DrainingTask] = [:]
    }

    // Index graph requests are background work and can arrive from multiple sessions at once.
    // Keep a process-wide admission limit while allowing foreground graphs to proceed independently.
    private static let sharedIndexQueue = AsyncOperationQueue(concurrentTasks: 1)

    private let state = SWBMutex(State())
    private let indexQueue: AsyncOperationQueue
    private let foregroundQueue: AsyncOperationQueue

    package init(indexQueue: AsyncOperationQueue? = nil, foregroundQueue: AsyncOperationQueue? = nil) {
        self.indexQueue = indexQueue ?? Self.sharedIndexQueue
        self.foregroundQueue = foregroundQueue ?? AsyncOperationQueue(concurrentTasks: 1)
    }

    deinit {
        _ = beginClose()
    }

    package func submit(
        lane: Lane,
        priority: _Concurrency.TaskPriority,
        operation: @escaping @Sendable () async throws -> DependencyGraphResponse,
        completion: @escaping Completion
    ) {
        let id = UUID()
        let queue =
            switch lane {
            case .index: indexQueue
            case .foreground: foregroundQueue
            }
        let shouldCancelImmediately = state.withLock { state -> Bool in
            guard state.acceptsNewOperations else {
                return true
            }

            let task = _Concurrency.Task<Void, Never>(priority: priority) { [weak self] in
                let outcome: Outcome
                do {
                    let response = try await queue.withOperation {
                        try _Concurrency.Task.checkCancellation()
                        let response = try await operation()
                        try _Concurrency.Task.checkCancellation()
                        return response
                    }
                    outcome = .success(response)
                } catch is _Concurrency.CancellationError {
                    outcome = .cancelled
                } catch {
                    outcome = .failure(String(describing: error))
                }
                self?.finish(id: id, outcome: outcome)
            }
            state.operations[id] = Operation(task: task, completion: completion)
            return false
        }

        if shouldCancelImmediately {
            completion(.cancelled)
        }
    }

    package func close() async {
        let tasks = beginClose()
        for task in tasks {
            await task.value
        }
        await waitForQuiescence()
    }

    package func waitForQuiescence() async {
        // Operations remain tracked until both graph construction and the terminal reply
        // callback have finished. The Task may still be returning from its final
        // bookkeeping call after it is removed from this state.
        // ServiceHostConnection processes requests serially, so production callers cannot
        // submit more work while awaiting this method. It is not an admission barrier for
        // arbitrary concurrent callers.
        while true {
            let tasks = state.withLock { state in
                Array(state.operations.values.map(\.task)) + Array(state.drainingTasks.values.map(\.task))
            }
            if tasks.isEmpty {
                return
            }
            for task in tasks {
                await task.value
            }
        }
    }

    private func finish(id: UUID, outcome: Outcome) {
        let completion = state.withLock { state -> Completion? in
            if let operation = state.operations.removeValue(forKey: id) {
                state.drainingTasks[id] = DrainingTask(task: operation.task, operationFinished: true, replyFinished: false)
                return operation.completion
            }

            if var drainingTask = state.drainingTasks[id] {
                drainingTask.operationFinished = true
                if drainingTask.replyFinished {
                    state.drainingTasks.removeValue(forKey: id)
                } else {
                    state.drainingTasks[id] = drainingTask
                }
            }
            return nil
        }
        if let completion {
            completion(outcome)
            markRepliesFinished(for: [id])
        }
    }

    private func beginClose() -> [_Concurrency.Task<Void, Never>] {
        let cancelled = state.withLock { state -> (ids: [UUID], tasks: [_Concurrency.Task<Void, Never>], completions: [Completion]) in
            state.acceptsNewOperations = false

            var cancelledIDs: [UUID] = []
            var tasks: [_Concurrency.Task<Void, Never>] = []
            var completions: [Completion] = []
            let ids = Array(state.operations.keys)
            for id in ids {
                guard let operation = state.operations.removeValue(forKey: id) else {
                    continue
                }
                cancelledIDs.append(id)
                tasks.append(operation.task)
                completions.append(operation.completion)
                state.drainingTasks[id] = DrainingTask(task: operation.task, operationFinished: false, replyFinished: false)
            }
            return (cancelledIDs, tasks, completions)
        }

        for task in cancelled.tasks {
            task.cancel()
        }
        for completion in cancelled.completions {
            completion(.cancelled)
        }
        markRepliesFinished(for: cancelled.ids)
        return cancelled.tasks
    }

    private func markRepliesFinished(for ids: [UUID]) {
        state.withLock { state in
            for id in ids {
                guard var drainingTask = state.drainingTasks[id] else {
                    continue
                }
                drainingTask.replyFinished = true
                if drainingTask.operationFinished {
                    state.drainingTasks.removeValue(forKey: id)
                } else {
                    state.drainingTasks[id] = drainingTask
                }
            }
        }
    }
}
