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
package import SWBCore
package import SWBProtocol
package import SWBUtil
import Synchronization

package final class DependencyGraphRequestCoordinator: Sendable {
    package struct Key: Equatable, Sendable {
        private let workspaceIdentifier: ObjectIdentifier
        private let targetGUIDs: [TargetGUID]
        private let buildParameters: BuildParametersMessagePayload
        private let includeImplicitDependencies: Bool
        private let dependencyScope: DependencyScopeMessagePayload

        package init(workspaceContext: WorkspaceContext, request: NonBlockingComputeDependencyGraphRequest) {
            self.init(workspaceIdentifier: ObjectIdentifier(workspaceContext), request: request)
        }

        package init(workspaceIdentifier: ObjectIdentifier, request: NonBlockingComputeDependencyGraphRequest) {
            self.workspaceIdentifier = workspaceIdentifier
            self.targetGUIDs = request.targetGUIDs
            self.buildParameters = request.buildParameters
            self.includeImplicitDependencies = request.includeImplicitDependencies
            self.dependencyScope = request.dependencyScope
        }
    }

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
        let key: Key
        let lane: Lane
        let task: _Concurrency.Task<Void, Never>
        var completions: [Completion]
    }

    private struct DrainingTask: Sendable {
        let task: _Concurrency.Task<Void, Never>
        var taskReachedFinish: Bool
        var repliesFinished: Bool
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
        cancelAll()
    }

    package func submit(
        key: Key,
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

            if let existingID = state.operations.first(where: { $0.value.key == key })?.key {
                state.operations[existingID]!.completions.append(completion)
                return false
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
            state.operations[id] = Operation(key: key, lane: lane, task: task, completions: [completion])
            return false
        }

        if shouldCancelImmediately {
            completion(.cancelled)
        }
    }

    package func cancelAll() {
        _ = cancelOperations(where: { _ in true }, close: false)
    }

    package func close() async {
        let tasks = cancelOperations(where: { _ in true }, close: true)
        for task in tasks {
            await task.value
        }
        await waitForQuiescence()
    }

    package func waitForQuiescence() async {
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
        let completions = state.withLock { state -> [Completion] in
            if let operation = state.operations.removeValue(forKey: id) {
                state.drainingTasks[id] = DrainingTask(task: operation.task, taskReachedFinish: true, repliesFinished: false)
                return operation.completions
            }

            if var drainingTask = state.drainingTasks[id] {
                drainingTask.taskReachedFinish = true
                if drainingTask.repliesFinished {
                    state.drainingTasks.removeValue(forKey: id)
                } else {
                    state.drainingTasks[id] = drainingTask
                }
            }
            return []
        }
        for completion in completions {
            completion(outcome)
        }
        if !completions.isEmpty {
            markRepliesFinished(for: [id])
        }
    }

    private func cancelOperations(
        where shouldCancel: (Operation) -> Bool,
        close: Bool
    ) -> [_Concurrency.Task<Void, Never>] {
        let cancelled = state.withLock { state -> (ids: [UUID], tasks: [_Concurrency.Task<Void, Never>], completions: [Completion]) in
            if close {
                state.acceptsNewOperations = false
            }

            var cancelledIDs: [UUID] = []
            var tasks: [_Concurrency.Task<Void, Never>] = []
            var completions: [Completion] = []
            let ids = state.operations.compactMap { id, operation in
                shouldCancel(operation) ? id : nil
            }
            for id in ids {
                guard let operation = state.operations.removeValue(forKey: id) else {
                    continue
                }
                cancelledIDs.append(id)
                tasks.append(operation.task)
                completions.append(contentsOf: operation.completions)
                state.drainingTasks[id] = DrainingTask(task: operation.task, taskReachedFinish: false, repliesFinished: false)
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
                drainingTask.repliesFinished = true
                if drainingTask.taskReachedFinish {
                    state.drainingTasks.removeValue(forKey: id)
                } else {
                    state.drainingTasks[id] = drainingTask
                }
            }
        }
    }
}
