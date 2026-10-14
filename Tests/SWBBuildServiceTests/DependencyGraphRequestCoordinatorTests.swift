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

import Dispatch
@testable import SWBBuildService
import SWBCore
import SWBMacro
import SWBProtocol
import SWBTestSupport
import SWBUtil
import Synchronization
import Testing

@Suite(.serialized) fileprivate struct DependencyGraphRequestCoordinatorTests: CoreBasedTests {
    @Test
    func requestInputsReleaseTheOriginalContextAndPreserveItsSnapshot() async throws {
        let snapshot = try await {
            let context = try await contextForTestData(TestWorkspace("Test", projects: []))
            context.updateUserPreferences(.defaultForTesting)
            return (
                inputs: DependencyGraphRequestInputs(workspaceContext: context),
                context: WeakRef(context),
                workspace: context.workspace,
                fs: context.fs,
                userInfo: context.userInfo,
                systemInfo: context.systemInfo,
                userPreferences: context.userPreferences
            )
        }()

        #expect(snapshot.context.instance == nil)
        let restored = snapshot.inputs.makeWorkspaceContext()
        #expect(restored.workspace === snapshot.workspace)
        #expect(restored.fs === snapshot.fs)
        #expect(restored.userInfo == snapshot.userInfo)
        #expect(restored.systemInfo == snapshot.systemInfo)
        #expect(restored.userPreferences == snapshot.userPreferences)
    }

    @Test(arguments: SnapshotMetadata.allCases)
    func requestInputsPreserveMetadataAndSeparateUpdates(_ metadata: SnapshotMetadata) async throws {
        let context = try await contextForTestData(TestWorkspace("Test", projects: []), environment: ["SNAPSHOT_VALUE": "original"])
        context.updateUserPreferences(.defaultForTesting)
        let userInfo = context.userInfo
        let systemInfo = context.systemInfo
        let userPreferences = context.userPreferences
        let inputs = DependencyGraphRequestInputs(workspaceContext: context)
        let request = makeDependencyGraphRequest()
        let originalKey = inputs.requestKey(for: request)

        switch metadata {
        case .userInfo:
            context.updateUserInfo(try #require(userInfo).withAdditionalEnvironment(environment: ["SNAPSHOT_VALUE": "updated"]))
        case .systemInfo:
            let info = try #require(systemInfo)
            context.updateSystemInfo(SystemInfo(operatingSystemVersion: info.operatingSystemVersion, productBuildVersion: info.productBuildVersion + "-updated", nativeArchitecture: info.nativeArchitecture))
        case .userPreferences:
            context.updateUserPreferences(userPreferences.with(enableDebugActivityLogs: true))
        }

        #expect(DependencyGraphRequestInputs(workspaceContext: context).requestKey(for: request) != originalKey)
        let restored = inputs.makeWorkspaceContext()
        #expect(restored.userInfo == userInfo)
        #expect(restored.systemInfo == systemInfo)
        #expect(restored.userPreferences == userPreferences)
        #expect(DependencyGraphRequestInputs(workspaceContext: restored).requestKey(for: request) == originalKey)
    }

    @Test(.requireSDKs(.macOS), arguments: [false, true])
    func identicalPIFAndMetadataReuseIndexSettings(usesAutomaticSDK: Bool) async throws {
        let workspace = makeIndexSettingsWorkspace(buildSettings: usesAutomaticSDK ? ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx"] : [:])
        let context = try await contextForTestData(workspace)
        context.updateUserPreferences(.defaultForTesting)
        let session = Session(context.core, "Test", cachePath: nil)
        session.workspaceContext = context
        let inputs = DependencyGraphRequestInputs(workspaceContext: context)
        let entry = makeIndexContext(session, inputs: inputs)
        let cachedContext = entry.workspaceContext()
        let settings = indexSettings(in: cachedContext)
        #expect(settings.errors.isEmpty)
        #expect(try indexValue(in: settings) == "IndexTarget:Debug")
        entry.finished(using: cachedContext)

        let reappliedContext = WorkspaceContext(core: context.core, workspace: try workspace.load(context.core), fs: context.fs, processExecutionCache: ProcessExecutionCache())
        #expect(reappliedContext.workspace !== context.workspace)
        #expect(reappliedContext.workspace.signature == context.workspace.signature)
        session.workspaceContext = reappliedContext
        reappliedContext.updateUserInfo(try #require(context.userInfo))
        session.invalidateIndexWorkspaceContext(for: \.userInfo, value: reappliedContext.userInfo)
        reappliedContext.updateSystemInfo(try #require(context.systemInfo))
        session.invalidateIndexWorkspaceContext(for: \.systemInfo, value: reappliedContext.systemInfo)
        reappliedContext.updateUserPreferences(context.userPreferences)
        session.invalidateIndexWorkspaceContext(for: \.userPreferences, value: reappliedContext.userPreferences)

        let reappliedInputs = DependencyGraphRequestInputs(workspaceContext: reappliedContext)
        let reappliedEntry = makeIndexContext(session, inputs: reappliedInputs)
        #expect(reappliedEntry === entry)
        #expect(reappliedEntry.workspaceContext() === cachedContext)
        #expect(indexSettings(in: reappliedEntry.workspaceContext()) === settings)

    }

    @Test(.requireSDKs(.macOS))
    func developmentAssetDirectoryChangesInvalidateIndexSettings() async throws {
        let assetPath = Path("/tmp/DevelopmentAssets")
        let workspace = makeIndexSettingsWorkspace(buildSettings: [
            "DEVELOPMENT_ASSET_PATHS": assetPath.str,
            "DEPLOYMENT_POSTPROCESSING": "YES",
        ])
        let context = try await contextForTestData(workspace)
        let session = Session(context.core, "Test", cachePath: nil)
        session.workspaceContext = context
        let inputs = DependencyGraphRequestInputs(workspaceContext: context)
        let entry = makeIndexContext(session, inputs: inputs)
        let cachedContext = entry.workspaceContext()
        let originalSettings = indexSettings(in: cachedContext)
        #expect(originalSettings.globalScope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES) == [assetPath.str])
        entry.finished(using: cachedContext)

        try context.fs.createDirectory(assetPath, recursive: true)
        let updatedEntry = makeIndexContext(session, inputs: inputs)
        #expect(updatedEntry === entry)
        #expect(updatedEntry.workspaceContext() === cachedContext)
        let updatedSettings = indexSettings(in: cachedContext)
        #expect(updatedSettings !== originalSettings)
        #expect(updatedSettings.globalScope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES) == [assetPath.join("*").str])
    }

    @Test(arguments: SnapshotMetadata.allCases)
    func metadataUpdatesInvalidateOnlyChangedIndexInputs(_ metadata: SnapshotMetadata) async throws {
        let context = try await contextForTestData(TestWorkspace("Test", projects: []), environment: ["SNAPSHOT_VALUE": "original"])
        context.updateUserPreferences(.defaultForTesting)
        let session = Session(context.core, "Test", cachePath: nil)
        session.workspaceContext = context
        let originalInputs = DependencyGraphRequestInputs(workspaceContext: context)
        let originalEntry = WeakRef(makeIndexContext(session, inputs: originalInputs))
        let originalContext = WeakRef(try #require(originalEntry.instance).workspaceContext())

        switch metadata {
        case .userInfo:
            context.updateUserInfo(try #require(context.userInfo))
            session.invalidateIndexWorkspaceContext(for: \.userInfo, value: context.userInfo)
        case .systemInfo:
            context.updateSystemInfo(try #require(context.systemInfo))
            session.invalidateIndexWorkspaceContext(for: \.systemInfo, value: context.systemInfo)
        case .userPreferences:
            context.updateUserPreferences(context.userPreferences)
            session.invalidateIndexWorkspaceContext(for: \.userPreferences, value: context.userPreferences)
        }
        #expect(makeIndexContext(session, inputs: originalInputs) === originalEntry.instance)
        #expect(originalContext.instance != nil)

        switch metadata {
        case .userInfo:
            context.updateUserInfo(try #require(context.userInfo).withAdditionalEnvironment(environment: ["SNAPSHOT_VALUE": "updated"]))
            session.invalidateIndexWorkspaceContext(for: \.userInfo, value: context.userInfo)
        case .systemInfo:
            let info = try #require(context.systemInfo)
            context.updateSystemInfo(SystemInfo(operatingSystemVersion: info.operatingSystemVersion, productBuildVersion: info.productBuildVersion + "-updated", nativeArchitecture: info.nativeArchitecture))
            session.invalidateIndexWorkspaceContext(for: \.systemInfo, value: context.systemInfo)
        case .userPreferences:
            context.updateUserPreferences(context.userPreferences.with(enableDebugActivityLogs: true))
            session.invalidateIndexWorkspaceContext(for: \.userPreferences, value: context.userPreferences)
        }
        #expect(originalEntry.instance == nil)
        #expect(originalContext.instance == nil)
        let updatedInputs = DependencyGraphRequestInputs(workspaceContext: context)
        let updatedEntry = makeIndexContext(session, inputs: updatedInputs)
        #expect(updatedEntry.key != originalInputs.requestKey(for: makeDependencyGraphRequest()))
        #expect(updatedEntry.workspaceContext().userInfo == context.userInfo)
        #expect(updatedEntry.workspaceContext().systemInfo == context.systemInfo)
        #expect(updatedEntry.workspaceContext().userPreferences == context.userPreferences)
    }

    @Test(arguments: [false, true])
    func replacedIndexContextsLiveOnlyForActiveRequests(isActive: Bool) async throws {
        let context = try await contextForTestData(TestWorkspace("Original", projects: []))
        let session = Session(context.core, "Test", cachePath: nil)
        session.workspaceContext = context
        let inputs = DependencyGraphRequestInputs(workspaceContext: context)
        let entry = WeakRef(makeIndexContext(session, inputs: inputs))
        let cachedContext = WeakRef(try #require(entry.instance).workspaceContext())
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let blocker = isActive ? nil : await holdQueue(indexQueue)
        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let recorder = OutcomeRecorder()
        let started = WaitCondition()
        let release = WaitCondition()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: inputs.requestKey(for: makeDependencyGraphRequest())) {
            let activeEntry = entry.instance
            let activeContext = activeEntry?.workspaceContext() ?? inputs.makeWorkspaceContext()
            defer { activeEntry?.finished(using: activeContext) }
            started.signal()
            if isActive { await release.wait() }
            #expect(activeContext.userInfo == inputs.userInfo)
            #expect(activeContext.systemInfo == inputs.systemInfo)
            #expect(activeContext.userPreferences == inputs.userPreferences)
            return makeResponse(activeContext.workspace.name)
        } completion: {
            recorder.record($0)
        }

        if isActive {
            await started.wait()
            session.workspaceContext = nil
        } else {
            session.workspaceContext = try await contextForTestData(TestWorkspace("Updated", projects: []))
        }
        #expect((entry.instance != nil) == isActive)
        #expect((cachedContext.instance != nil) == isActive)

        release.signal()
        if let blocker {
            blocker.release.signal()
            try await blocker.task.value
        }
        await coordinator.waitForQuiescence()
        #expect(entry.instance == nil)
        #expect(cachedContext.instance == nil)
        #expect(recorder.outcomes == [.success(makeResponse("Original"))])
    }

    @Test(.requireSDKs(.macOS), arguments: [false, true])
    func sessionsKeepOnlyTheCurrentIndexInputSet(changesWorkspace: Bool) async throws {
        let fixture = makeIndexSettingsWorkspace()
        let context = try await contextForTestData(fixture)
        let session = Session(context.core, "Test", cachePath: nil)
        session.workspaceContext = context
        var snapshots: [DependencyGraphRequestInputs] = []
        var entries: [WeakRef<IndexDependencyGraphContext>] = []
        var contexts: [WeakRef<WorkspaceContext>] = []
        var settings: [WeakRef<Settings>] = []

        for generation in 0..<20 {
            if changesWorkspace {
                let workspace = try TestWorkspace("Generation-\(generation)", projects: fixture.projects).load(context.core)
                session.workspaceContext = try await contextForTestData(workspace, core: context.core, fs: context.fs)
            }
            let inputs = DependencyGraphRequestInputs(workspaceContext: try #require(session.workspaceContext))
            snapshots.append(inputs)
            let configuration = changesWorkspace || generation.isMultiple(of: 2) ? "Debug" : "Release"
            let entry = makeIndexContext(session, inputs: inputs, configuration: configuration)
            let cachedContext = entry.workspaceContext()
            let cachedSettings = indexSettings(in: cachedContext, configuration: configuration)
            #expect(cachedSettings.errors.isEmpty)
            #expect(try indexValue(in: cachedSettings) == "IndexTarget:\(configuration)")
            entry.finished(using: cachedContext)
            entries.append(WeakRef(entry))
            contexts.append(WeakRef(cachedContext))
            settings.append(WeakRef(cachedSettings))
            #expect(entries.dropLast().allSatisfy { $0.instance == nil })
            #expect(contexts.dropLast().allSatisfy { $0.instance == nil })
            #expect(settings.dropLast().allSatisfy { $0.instance == nil })
        }

        #expect(snapshots.count == 20)
        #expect(entries.last?.instance != nil)
        #expect(contexts.last?.instance != nil)
        #expect(settings.last?.instance != nil)
        session.clearIndexWorkspaceContext()
        #expect(entries.allSatisfy { $0.instance == nil })
        #expect(contexts.allSatisfy { $0.instance == nil })
        #expect(settings.allSatisfy { $0.instance == nil })
    }

    @Test(arguments: [false, true])
    func identicalPendingRequestsShareWorkAndReplyToEveryCaller(shouldFail: Bool) async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let blocker = await holdQueue(indexQueue)
        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let key = makeIndexRequestKey(coordinator)
        let activity = ActivityRecorder()
        let replies = SWBMutex<[Int: [DependencyGraphRequestCoordinator.Outcome]]>([:])
        let releasedSnapshots = SWBMutex(0)
        var snapshots: [WeakRef<RequestSnapshot>] = []

        for id in 0..<16 {
            snapshots.append(submitSnapshotRequest(
                coordinator: coordinator,
                key: key,
                shouldFail: shouldFail,
                activity: activity,
                onRelease: { releasedSnapshots.withLock { $0 += 1 } },
                completion: { outcome in
                    replies.withLock { $0[id, default: []].append(outcome) }
                }
            ))
        }

        #expect(snapshots.first?.instance != nil)
        #expect(snapshots.dropFirst().allSatisfy { $0.instance == nil })
        #expect(releasedSnapshots.withLock { $0 } == 15)
        #expect(activity.startCount("index") == 0)

        blocker.release.signal()
        try await blocker.task.value
        await coordinator.waitForQuiescence()

        let expected: DependencyGraphRequestCoordinator.Outcome = shouldFail
            ? .failure("expected")
            : .success(makeResponse("shared"))
        #expect(activity.startCount("index") == 1)
        #expect(replies.withLock { $0.count } == 16)
        #expect(replies.withLock { $0.values.allSatisfy { $0 == [expected] } })
    }

    @Test(arguments: [false, true])
    func distinctSnapshotsAndParametersKeepTheirOwnOutcomes(changesWorkspace: Bool) async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let blocker = await holdQueue(indexQueue)
        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let firstKey = makeIndexRequestKey(coordinator)
        let secondKey = makeIndexRequestKey(
            coordinator,
            workspaceSignature: changesWorkspace ? "updated-workspace" : "workspace",
            configuration: changesWorkspace ? "Debug" : "Release"
        )
        let activity = ActivityRecorder()
        let firstRecorder = OutcomeRecorder()
        let secondRecorder = OutcomeRecorder()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: firstKey) {
            activity.begin("index")
            defer { activity.end("index") }
            return makeResponse("first")
        } completion: {
            firstRecorder.record($0)
        }

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: secondKey) {
            activity.begin("index")
            defer { activity.end("index") }
            throw TestError.expected
        } completion: {
            secondRecorder.record($0)
        }

        blocker.release.signal()
        try await blocker.task.value
        await coordinator.waitForQuiescence()

        #expect(activity.startCount("index") == 2)
        #expect(firstRecorder.outcomes == [.success(makeResponse("first"))])
        #expect(secondRecorder.outcomes == [.failure("expected")])
    }

    @Test
    func aRequestArrivingAfterWorkStartsGetsANewComputation() async {
        let coordinator = makeCoordinator()
        let key = makeIndexRequestKey(coordinator)
        let firstStarted = WaitCondition()
        let releaseFirst = WaitCondition()
        let activity = ActivityRecorder()
        let firstRecorder = OutcomeRecorder()
        let secondRecorder = OutcomeRecorder()
        let followerRecorder = OutcomeRecorder()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            activity.begin("index")
            defer { activity.end("index") }
            firstStarted.signal()
            await releaseFirst.wait()
            return makeResponse("first")
        } completion: {
            firstRecorder.record($0)
        }

        await firstStarted.wait()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            activity.begin("index")
            defer { activity.end("index") }
            return makeResponse("second")
        } completion: {
            secondRecorder.record($0)
        }

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            Issue.record("The pending follower must share the second computation")
            return makeResponse("unexpected")
        } completion: {
            followerRecorder.record($0)
        }

        releaseFirst.signal()
        await coordinator.waitForQuiescence()

        #expect(activity.startCount("index") == 2)
        #expect(firstRecorder.outcomes == [.success(makeResponse("first"))])
        #expect(secondRecorder.outcomes == [.success(makeResponse("second"))])
        #expect(followerRecorder.outcomes == [.success(makeResponse("second"))])
    }

    @Test
    func executesEverySubmittedRequestAndReportsItsOutcome() async {
        let coordinator = makeCoordinator()
        let activity = ActivityRecorder()
        let firstRecorder = OutcomeRecorder()
        let secondRecorder = OutcomeRecorder()
        let firstStarted = WaitCondition()
        let releaseFirst = WaitCondition()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index")
            defer { activity.end("index") }
            firstStarted.signal()
            await releaseFirst.wait()
            return makeResponse("first")
        } completion: {
            firstRecorder.record($0)
        }

        await firstStarted.wait()

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index")
            defer { activity.end("index") }
            throw TestError.expected
        } completion: {
            secondRecorder.record($0)
        }

        releaseFirst.signal()
        await coordinator.waitForQuiescence()

        #expect(activity.startCount("index") == 2)
        #expect(firstRecorder.outcomes == [.success(makeResponse("first"))])
        #expect(secondRecorder.outcomes == [.failure("expected")])
    }

    @Test
    func serializesIndexRequestsAcrossSessionsWithoutBlockingForeground() async {
        let firstCoordinator = DependencyGraphRequestCoordinator()
        let secondCoordinator = DependencyGraphRequestCoordinator()
        let activity = ActivityRecorder()
        let firstIndexStarted = WaitCondition()
        let releaseFirstIndex = WaitCondition()
        let secondIndexStarted = WaitCondition()
        let releaseSecondIndex = WaitCondition()
        let firstForegroundStarted = WaitCondition()
        let secondForegroundStarted = WaitCondition()
        let queuedForegroundStarted = WaitCondition()
        let releaseForeground = WaitCondition()

        firstCoordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index-a")
            defer { activity.end("index-a") }
            firstIndexStarted.signal()
            await releaseFirstIndex.wait()
            return makeResponse("index-a")
        } completion: { _ in
        }

        await firstIndexStarted.wait()

        secondCoordinator.submit(lane: .index, priority: .utility) {
            activity.begin("index-b")
            defer { activity.end("index-b") }
            secondIndexStarted.signal()
            await releaseSecondIndex.wait()
            return makeResponse("index-b")
        } completion: { _ in
        }

        firstCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-a")
            defer { activity.end("foreground-a") }
            firstForegroundStarted.signal()
            await releaseForeground.wait()
            return makeResponse("foreground-a")
        } completion: { _ in
        }

        secondCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-b")
            defer { activity.end("foreground-b") }
            secondForegroundStarted.signal()
            await releaseForeground.wait()
            return makeResponse("foreground-b")
        } completion: { _ in
        }

        await firstForegroundStarted.wait()
        await secondForegroundStarted.wait()

        firstCoordinator.submit(lane: .foreground, priority: .userInitiated) {
            activity.begin("foreground-queued")
            defer { activity.end("foreground-queued") }
            queuedForegroundStarted.signal()
            return makeResponse("foreground-queued")
        } completion: { _ in
        }

        #expect(activity.startCount("index-b") == 0)
        #expect(activity.startCount("foreground-queued") == 0)
        #expect(activity.maximumConcurrentIndexOperations == 1)
        #expect(activity.maximumConcurrentForegroundOperations == 2)
        #expect(activity.maximumConcurrentOperations == 3)

        releaseForeground.signal()
        await queuedForegroundStarted.wait()
        releaseFirstIndex.signal()
        await secondIndexStarted.wait()
        releaseSecondIndex.signal()
        await firstCoordinator.waitForQuiescence()
        await secondCoordinator.waitForQuiescence()

        #expect(activity.maximumConcurrentIndexOperations == 1)
        #expect(activity.maximumConcurrentForegroundOperations == 2)
    }

    @Test
    func closeCancelsActiveAndQueuedRequestsAndWaitsForCompletion() async {
        let coordinator = makeCoordinator()
        let activeStarted = WaitCondition()
        let releaseActive = WaitCondition()
        let cancellationObserved = WaitCondition()
        let activity = ActivityRecorder()
        let sequence = SequenceRecorder()
        let lifecycleDriver = LifecycleDriver()
        let activeRecorder = OutcomeRecorder()
        let queuedRecorder = OutcomeRecorder()
        let queuedFollowerRecorder = OutcomeRecorder()
        let lateRecorder = OutcomeRecorder()
        let queuedKey = makeIndexRequestKey(coordinator)

        coordinator.submit(lane: .index, priority: .utility) {
            activity.begin("active")
            defer { activity.end("active") }
            sequence.record("operation-started")
            activeStarted.signal()
            await withTaskCancellationHandler {
                await releaseActive.wait()
            } onCancel: {
                cancellationObserved.signal()
            }
            sequence.record("operation-finished")
            return makeResponse("late-success")
        } completion: {
            sequence.record("active-reply")
            activeRecorder.record($0)
        }

        await activeStarted.wait()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: queuedKey) {
            activity.begin("queued")
            defer { activity.end("queued") }
            return makeResponse("queued")
        } completion: {
            sequence.record("queued-reply")
            queuedRecorder.record($0)
        }

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: queuedKey) {
            Issue.record("A cancelled merged request must not enter graph construction")
            return makeResponse("unexpected")
        } completion: {
            queuedFollowerRecorder.record($0)
        }

        let closeTask = _Concurrency.Task {
            await lifecycleDriver.close(coordinator, sequence: sequence)
        }

        await cancellationObserved.wait()
        await queuedRecorder.received.wait()
        #expect(activeRecorder.outcomes.isEmpty)

        coordinator.submit(lane: .index, priority: .utility) {
            Issue.record("A closed coordinator must not start new work")
            return makeResponse("unexpected")
        } completion: {
            sequence.record("late-reply")
            lateRecorder.record($0)
        }
        await lateRecorder.received.wait()

        await lifecycleDriver.release(releaseActive, sequence: sequence, event: "release-active")
        await closeTask.value
        await coordinator.close()

        #expect(activeRecorder.outcomes == [.cancelled])
        #expect(queuedRecorder.outcomes == [.cancelled])
        #expect(queuedFollowerRecorder.outcomes == [.cancelled])
        #expect(lateRecorder.outcomes == [.cancelled])
        #expect(activity.startCount("active") == 1)
        #expect(activity.startCount("queued") == 0)
        #expect(sequence.index(of: "operation-finished") < sequence.index(of: "active-reply"))
        #expect(sequence.index(of: "active-reply") < sequence.index(of: "close-returned"))
    }

    @Test
    func closeWaitsForCommittedReplyAndPreservesItsOutcome() async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let blocker = await holdQueue(indexQueue)
        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let key = makeIndexRequestKey(coordinator)
        let releaseReply = DispatchSemaphore(value: 0)
        let replyStarted = WaitCondition()
        let closeStarted = WaitCondition()
        let sequence = SequenceRecorder()
        let recorder = OutcomeRecorder()
        let followerRecorder = OutcomeRecorder()
        let lifecycleDriver = LifecycleDriver()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            makeResponse("success")
        } completion: {
            sequence.record("reply-started")
            replyStarted.signal()
            releaseReply.wait()
            sequence.record("reply-finished")
            recorder.record($0)
        }

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            Issue.record("The pending follower must share the committed response")
            return makeResponse("unexpected")
        } completion: {
            sequence.record("follower-reply-finished")
            followerRecorder.record($0)
        }

        blocker.release.signal()
        try await blocker.task.value

        await replyStarted.wait()

        let closeTask = _Concurrency.Task {
            await lifecycleDriver.close(
                coordinator,
                started: closeStarted,
                sequence: sequence
            )
        }

        await closeStarted.wait()
        await lifecycleDriver.release(releaseReply)
        await recorder.received.wait()
        await closeTask.value

        #expect(recorder.outcomes == [.success(makeResponse("success"))])
        #expect(followerRecorder.outcomes == [.success(makeResponse("success"))])
        #expect(sequence.index(of: "reply-finished") < sequence.index(of: "close-returned"))
        #expect(sequence.index(of: "follower-reply-finished") < sequence.index(of: "close-returned"))
    }

    @Test
    func quiescenceWaitsForOperationAndReplyCompletion() async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let blocker = await holdQueue(indexQueue)
        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let key = makeIndexRequestKey(coordinator)
        let releaseReply = DispatchSemaphore(value: 0)
        let replyStarted = WaitCondition()
        let quiescenceStarted = WaitCondition()
        let sequence = SequenceRecorder()
        let lifecycleDriver = LifecycleDriver()

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            sequence.record("operation-finished")
            return makeResponse("success")
        } completion: { _ in
            sequence.record("reply-started")
            replyStarted.signal()
            releaseReply.wait()
            sequence.record("reply-finished")
        }

        coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
            Issue.record("The pending follower must share the quiescent response")
            return makeResponse("unexpected")
        } completion: { _ in
            sequence.record("follower-reply-finished")
        }

        blocker.release.signal()
        try await blocker.task.value

        await replyStarted.wait()

        let quiescenceTask = _Concurrency.Task {
            await lifecycleDriver.waitForQuiescence(
                of: coordinator,
                started: quiescenceStarted,
                sequence: sequence
            )
        }

        await quiescenceStarted.wait()
        await lifecycleDriver.release(releaseReply)
        await quiescenceTask.value

        #expect(sequence.index(of: "reply-started") < sequence.index(of: "reply-finished"))
        #expect(sequence.index(of: "reply-finished") < sequence.index(of: "quiescence-returned"))
        #expect(sequence.index(of: "follower-reply-finished") < sequence.index(of: "quiescence-returned"))
    }

    @Test
    func closeDoesNotWaitForAnotherSessionsIndexOperation() async throws {
        let indexQueue = AsyncOperationQueue(concurrentTasks: 1)
        let started = WaitCondition()
        let release = WaitCondition()
        let blocker = _Concurrency.Task {
            try await indexQueue.withOperation {
                started.signal()
                await release.wait()
            }
        }
        await started.wait()

        let coordinator = makeCoordinator(indexQueue: indexQueue)
        let recorder = OutcomeRecorder()
        coordinator.submit(lane: .index, priority: .utility) {
            Issue.record("A cancelled queued request must not enter graph construction")
            return makeResponse("unexpected")
        } completion: {
            recorder.record($0)
        }

        await coordinator.close()
        #expect(recorder.outcomes == [.cancelled])
        release.signal()
        try await blocker.value
    }

    @Test
    func deinitRepliesBeforeActiveOperationFinishes() async throws {
        var coordinator: DependencyGraphRequestCoordinator? = makeCoordinator()
        let started = WaitCondition()
        let release = WaitCondition()
        let finished = WaitCondition()
        let recorder = OutcomeRecorder()

        try #require(coordinator).submit(lane: .foreground, priority: .userInitiated) {
            started.signal()
            await release.wait()
            finished.signal()
            return makeResponse("late-success")
        } completion: {
            recorder.record($0)
        }

        await started.wait()
        coordinator = nil
        #expect(recorder.outcomes == [.cancelled])
        release.signal()
        await finished.wait()
    }

    @Test
    func concurrentSubmissionAndCloseReplyExactlyOnce() async {
        let coordinator = makeCoordinator()
        let replyCounts = SWBMutex<[Int: Int]>([:])

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<128 {
                group.addTask {
                    coordinator.submit(lane: id.isMultiple(of: 2) ? .index : .foreground, priority: .medium) {
                        await _Concurrency.Task.yield()
                        return makeResponse(String(id))
                    } completion: { _ in
                        replyCounts.withLock { $0[id, default: 0] += 1 }
                    }
                }
                if id.isMultiple(of: 16) {
                    group.addTask {
                        await coordinator.close()
                    }
                }
            }
        }
        await coordinator.close()

        #expect(replyCounts.withLock { $0.count } == 128)
        #expect(replyCounts.withLock { $0.values.allSatisfy { $0 == 1 } })
    }
}

private actor LifecycleDriver {
    func close(
        _ coordinator: DependencyGraphRequestCoordinator,
        started: WaitCondition? = nil,
        sequence: SequenceRecorder
    ) async {
        started?.signal()
        await coordinator.close()
        sequence.record("close-returned")
    }

    func waitForQuiescence(
        of coordinator: DependencyGraphRequestCoordinator,
        started: WaitCondition,
        sequence: SequenceRecorder
    ) async {
        started.signal()
        await coordinator.waitForQuiescence()
        sequence.record("quiescence-returned")
    }

    func release(_ condition: WaitCondition, sequence: SequenceRecorder? = nil, event: String? = nil) {
        if let sequence, let event {
            sequence.record(event)
        }
        condition.signal()
    }

    func release(_ semaphore: DispatchSemaphore) {
        semaphore.signal()
    }
}

private enum TestError: Error, CustomStringConvertible {
    case expected

    var description: String {
        "expected"
    }
}

fileprivate enum SnapshotMetadata: CaseIterable, Sendable {
    case userInfo, systemInfo, userPreferences
}

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

private final class SequenceRecorder: Sendable {
    private let events = SWBMutex<[String]>([])

    func record(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func index(of event: String) -> Int {
        events.withLock { events in
            events.firstIndex(of: event) ?? Int.max
        }
    }
}

private final class ActivityRecorder: Sendable {
    private struct State {
        var active: Set<String> = []
        var starts: [String: Int] = [:]
        var maximumConcurrentIndexOperations = 0
        var maximumConcurrentForegroundOperations = 0
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
            state.maximumConcurrentForegroundOperations = max(
                state.maximumConcurrentForegroundOperations,
                state.active.filter { $0.hasPrefix("foreground") }.count
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

    var maximumConcurrentForegroundOperations: Int {
        state.withLock { $0.maximumConcurrentForegroundOperations }
    }

    var maximumConcurrentOperations: Int {
        state.withLock { $0.maximumConcurrentOperations }
    }
}

private func makeCoordinator(
    indexQueue: AsyncOperationQueue = AsyncOperationQueue(concurrentTasks: 1),
    foregroundQueue: AsyncOperationQueue = AsyncOperationQueue(concurrentTasks: 1)
) -> DependencyGraphRequestCoordinator {
    DependencyGraphRequestCoordinator(indexQueue: indexQueue, foregroundQueue: foregroundQueue)
}

private func makeResponse(_ target: String) -> DependencyGraphResponse {
    let target = TargetGUID(rawValue: target)
    return DependencyGraphResponse(adjacencyList: [target: []])
}

private func holdQueue(_ queue: AsyncOperationQueue) async -> (release: WaitCondition, task: _Concurrency.Task<Void, any Error>) {
    let started = WaitCondition()
    let release = WaitCondition()
    let task = _Concurrency.Task {
        try await queue.withOperation {
            started.signal()
            await release.wait()
        }
    }
    await started.wait()
    return (release, task)
}

private func makeIndexRequestKey(
    _ owner: DependencyGraphRequestCoordinator,
    workspaceSignature: String = "workspace",
    configuration: String = "Debug"
) -> DependencyGraphRequestCoordinator.IndexRequestKey {
    let message = makeDependencyGraphRequest(configuration: configuration)
    return DependencyGraphRequestCoordinator.IndexRequestKey(
        core: ObjectIdentifier(owner),
        fs: ObjectIdentifier(owner),
        workspaceSignature: workspaceSignature,
        userInfo: nil,
        systemInfo: nil,
        userPreferences: .defaultForTesting,
        request: ComputeDependencyGraphRequest(
            sessionHandle: message.sessionHandle,
            targetGUIDs: message.targetGUIDs,
            buildParameters: message.buildParameters,
            includeImplicitDependencies: message.includeImplicitDependencies,
            dependencyScope: message.dependencyScope
        )
    )
}

private func makeDependencyGraphRequest(configuration: String = "Debug") -> NonBlockingComputeDependencyGraphRequest {
    NonBlockingComputeDependencyGraphRequest(
        sessionHandle: "session",
        responseChannel: 1,
        targetGUIDs: [TargetGUID(rawValue: "target")],
        buildParameters: BuildParametersMessagePayload(
            action: "indexbuild",
            configuration: configuration,
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

private func makeIndexContext(_ session: Session, inputs: DependencyGraphRequestInputs, configuration: String = "Debug") -> IndexDependencyGraphContext {
    session.indexDependencyGraphContext(for: inputs, key: inputs.requestKey(for: makeDependencyGraphRequest(configuration: configuration)))
}

private func makeIndexSettingsWorkspace(buildSettings: [String: String] = [:]) -> TestWorkspace {
    TestWorkspace("Test", projects: [
        TestProject("Project", groupTree: TestGroup("Files"), buildConfigurations: [
            TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"].merging(buildSettings, uniquingKeysWith: { _, value in value })),
            TestBuildConfiguration("Release", buildSettings: ["SDKROOT": "macosx"].merging(buildSettings, uniquingKeysWith: { _, value in value })),
        ], targets: [
            TestStandardTarget("IndexTarget", type: .commandLineTool, buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: ["INDEX_VALUE": "$(TARGET_NAME):$(CONFIGURATION)"]),
                TestBuildConfiguration("Release", buildSettings: ["INDEX_VALUE": "$(TARGET_NAME):$(CONFIGURATION)"]),
            ]),
        ]),
    ])
}

private func indexSettings(in context: WorkspaceContext, configuration: String = "Debug") -> Settings {
    BuildRequestContext(workspaceContext: context).getCachedSettings(BuildParameters(action: .indexBuild, configuration: configuration, activeRunDestination: .macOS), target: context.workspace.projects[0].targets[0])
}

private func indexValue(in settings: Settings) throws -> String {
    settings.globalScope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("INDEX_VALUE")))
}

private final class RequestSnapshot: Sendable {
    let response = makeResponse("shared")
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

private func submitSnapshotRequest(
    coordinator: DependencyGraphRequestCoordinator,
    key: DependencyGraphRequestCoordinator.IndexRequestKey,
    shouldFail: Bool,
    activity: ActivityRecorder,
    onRelease: @escaping @Sendable () -> Void,
    completion: @escaping DependencyGraphRequestCoordinator.Completion
) -> WeakRef<RequestSnapshot> {
    let snapshot = RequestSnapshot(onRelease: onRelease)
    coordinator.submit(lane: .index, priority: .utility, indexRequestKey: key) {
        activity.begin("index")
        defer { activity.end("index") }
        if shouldFail { throw TestError.expected }
        return snapshot.response
    } completion: { completion($0) }
    return WeakRef(snapshot)
}
