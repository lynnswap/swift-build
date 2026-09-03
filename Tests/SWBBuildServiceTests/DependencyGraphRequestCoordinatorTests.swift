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

import SWBBuildService
import SWBProtocol
import SWBUtil
import Synchronization
import Testing

@Suite fileprivate struct DependencyGraphRequestCoordinatorTests {
    @Test
    func coalescesEquivalentIndexRequests() async {
        let coordinator = makeCoordinator()
        let workspace = WorkspaceIdentity()
        let response = makeResponse("shared")
        let operationStarted = WaitCondition()
        let releaseOperation = WaitCondition()
        let activity = ActivityRecorder()
        let recorders = (0..<64).map { _ in OutcomeRecorder() }

        for (index, recorder) in recorders.enumerated() {
            let request = makeRequest(responseChannel: UInt64(index))
            coordinator.submit(
                key: .init(workspaceIdentifier: ObjectIdentifier(workspace), request: request),
                lane: .index,
                priority: .utility
            ) {
                activity.begin("index")
                defer { activity.end("index") }
                operationStarted.signal()
                await releaseOperation.wait()
                return response
            } completion: {
                recorder.record($0)
            }
        }

        await operationStarted.wait()
        releaseOperation.signal()
        await coordinator.waitForQuiescence()

        #expect(activity.startCount("index") == 1)
        for recorder in recorders {
            #expect(recorder.outcomes == [.success(response)])
        }
    }

    @Test
    func serializesDistinctIndexRequestsWithoutBlockingForeground() async {
        let coordinator = makeCoordinator()
        let workspace = WorkspaceIdentity()
        let activity = ActivityRecorder()
        let firstIndexStarted = WaitCondition()
        let releaseFirstIndex = WaitCondition()
        let secondIndexStarted = WaitCondition()
        let releaseSecondIndex = WaitCondition()
        let foregroundStarted = WaitCondition()

        coordinator.submit(
            key: makeKey(workspace: workspace, target: "index-a"),
            lane: .index,
            priority: .utility
        ) {
            activity.begin("index-a")
            defer { activity.end("index-a") }
            firstIndexStarted.signal()
            await releaseFirstIndex.wait()
            return makeResponse("index-a")
        } completion: { _ in
        }

        await firstIndexStarted.wait()

        coordinator.submit(
            key: makeKey(workspace: workspace, target: "index-b"),
            lane: .index,
            priority: .utility
        ) {
            activity.begin("index-b")
            defer { activity.end("index-b") }
            secondIndexStarted.signal()
            await releaseSecondIndex.wait()
            return makeResponse("index-b")
        } completion: { _ in
        }

        coordinator.submit(
            key: makeKey(workspace: workspace, target: "foreground", action: "build"),
            lane: .foreground,
            priority: .userInitiated
        ) {
            activity.begin("foreground")
            defer { activity.end("foreground") }
            foregroundStarted.signal()
            return makeResponse("foreground")
        } completion: { _ in
        }

        await foregroundStarted.wait()
        #expect(activity.startCount("index-b") == 0)

        releaseFirstIndex.signal()
        await secondIndexStarted.wait()
        releaseSecondIndex.signal()
        await coordinator.waitForQuiescence()

        #expect(activity.maximumConcurrentIndexOperations == 1)
        #expect(activity.maximumConcurrentOperations == 2)
    }

    @Test
    func closeCancelsActiveCoalescedAndQueuedRequestsExactlyOnce() async {
        let coordinator = makeCoordinator()
        let workspace = WorkspaceIdentity()
        let activeStarted = WaitCondition()
        let releaseActive = WaitCondition()
        let activity = ActivityRecorder()
        let activeRecorder = OutcomeRecorder()
        let coalescedRecorder = OutcomeRecorder()
        let queuedRecorder = OutcomeRecorder()
        let lateRecorder = OutcomeRecorder()

        let activeKey = makeKey(workspace: workspace, target: "active")
        coordinator.submit(key: activeKey, lane: .index, priority: .utility) {
            activity.begin("active")
            defer { activity.end("active") }
            activeStarted.signal()
            await releaseActive.wait()
            return makeResponse("late-success")
        } completion: {
            activeRecorder.record($0)
        }
        coordinator.submit(key: activeKey, lane: .index, priority: .utility) {
            Issue.record("A coalesced operation must not execute its own body")
            return makeResponse("unexpected")
        } completion: {
            coalescedRecorder.record($0)
        }

        await activeStarted.wait()

        coordinator.submit(
            key: makeKey(workspace: workspace, target: "queued"),
            lane: .index,
            priority: .utility
        ) {
            activity.begin("queued")
            defer { activity.end("queued") }
            return makeResponse("queued")
        } completion: {
            queuedRecorder.record($0)
        }

        let closeTask = _Concurrency.Task {
            await coordinator.close()
        }

        await activeRecorder.received.wait()
        await coalescedRecorder.received.wait()
        await queuedRecorder.received.wait()

        coordinator.submit(
            key: makeKey(workspace: workspace, target: "late"),
            lane: .index,
            priority: .utility
        ) {
            Issue.record("A closed coordinator must not start new work")
            return makeResponse("unexpected")
        } completion: {
            lateRecorder.record($0)
        }
        await lateRecorder.received.wait()

        releaseActive.signal()
        await closeTask.value
        await coordinator.close()

        #expect(activeRecorder.outcomes == [.cancelled])
        #expect(coalescedRecorder.outcomes == [.cancelled])
        #expect(queuedRecorder.outcomes == [.cancelled])
        #expect(lateRecorder.outcomes == [.cancelled])
        #expect(activity.startCount("active") == 1)
        #expect(activity.startCount("queued") == 0)
    }

    @Test
    func keyIgnoresReplyChannelAndIncludesSemanticInputs() {
        let firstWorkspace = WorkspaceIdentity()
        let secondWorkspace = WorkspaceIdentity()
        let firstRequest = makeRequest(responseChannel: 1)
        let secondRequest = makeRequest(responseChannel: 2)

        let first = DependencyGraphRequestCoordinator.Key(workspaceIdentifier: ObjectIdentifier(firstWorkspace), request: firstRequest)
        let sameInputs = DependencyGraphRequestCoordinator.Key(workspaceIdentifier: ObjectIdentifier(firstWorkspace), request: secondRequest)
        let differentWorkspace = DependencyGraphRequestCoordinator.Key(workspaceIdentifier: ObjectIdentifier(secondWorkspace), request: secondRequest)
        let differentTarget = DependencyGraphRequestCoordinator.Key(
            workspaceIdentifier: ObjectIdentifier(firstWorkspace),
            request: makeRequest(responseChannel: 2, target: "different")
        )

        #expect(first == sameInputs)
        #expect(first != differentWorkspace)
        #expect(first != differentTarget)
    }
}

private final class WorkspaceIdentity {}

private final class OutcomeRecorder: Sendable {
    let received = WaitCondition()
    private let storage = SWBMutex<[DependencyGraphRequestCoordinator.Outcome]>([])

    var outcomes: [DependencyGraphRequestCoordinator.Outcome] {
        storage.withLock { $0 }
    }

    func record(_ outcome: DependencyGraphRequestCoordinator.Outcome) {
        storage.withLock { $0.append(outcome) }
        received.signal()
    }
}

private final class ActivityRecorder: Sendable {
    private struct State {
        var active: Set<String> = []
        var starts: [String: Int] = [:]
        var maximumConcurrentIndexOperations = 0
        var maximumConcurrentOperations = 0
    }

    private let state = SWBMutex(State())

    func begin(_ name: String) {
        state.withLock { state in
            state.active.insert(name)
            state.starts[name, default: 0] += 1
            state.maximumConcurrentIndexOperations = max(
                state.maximumConcurrentIndexOperations,
                state.active.filter { $0.hasPrefix("index") }.count
            )
            state.maximumConcurrentOperations = max(state.maximumConcurrentOperations, state.active.count)
        }
    }

    func end(_ name: String) {
        state.withLock { state in
            #expect(state.active.remove(name) != nil)
        }
    }

    func startCount(_ name: String) -> Int {
        state.withLock { $0.starts[name, default: 0] }
    }

    var maximumConcurrentIndexOperations: Int {
        state.withLock { $0.maximumConcurrentIndexOperations }
    }

    var maximumConcurrentOperations: Int {
        state.withLock { $0.maximumConcurrentOperations }
    }
}

private func makeCoordinator() -> DependencyGraphRequestCoordinator {
    DependencyGraphRequestCoordinator(
        indexQueue: AsyncOperationQueue(concurrentTasks: 1),
        foregroundQueue: AsyncOperationQueue(concurrentTasks: 1)
    )
}

private func makeKey(
    workspace: WorkspaceIdentity,
    target: String,
    action: String = "indexbuild"
) -> DependencyGraphRequestCoordinator.Key {
    .init(
        workspaceIdentifier: ObjectIdentifier(workspace),
        request: makeRequest(responseChannel: 0, target: target, action: action)
    )
}

private func makeRequest(
    responseChannel: UInt64,
    target: String = "target",
    action: String = "indexbuild"
) -> NonBlockingComputeDependencyGraphRequest {
    NonBlockingComputeDependencyGraphRequest(
        sessionHandle: "session",
        responseChannel: responseChannel,
        targetGUIDs: [TargetGUID(rawValue: target)],
        buildParameters: BuildParametersMessagePayload(
            action: action,
            configuration: "Debug",
            activeRunDestination: nil,
            activeArchitecture: nil,
            arenaInfo: nil,
            overrides: SettingsOverridesMessagePayload(
                synthesized: [:],
                commandLine: [:],
                commandLineConfigPath: nil,
                commandLineConfig: [:],
                environmentConfigPath: nil,
                environmentConfig: [:],
                toolchainOverride: nil
            )
        ),
        includeImplicitDependencies: true,
        dependencyScope: .workspace
    )
}

private func makeResponse(_ target: String) -> DependencyGraphResponse {
    let target = TargetGUID(rawValue: target)
    return DependencyGraphResponse(adjacencyList: [target: []])
}
