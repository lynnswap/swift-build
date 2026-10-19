//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBBuildSystem
package import SWBCore
package import SWBProtocol
import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil
import Synchronization

final private class ResolverDelegate: TargetDependencyResolverDelegate {
    var cancelled: Bool { false }
    func emit(_ diagnostic: Diagnostic) {
        _diagnosticsEngine.emit(diagnostic)
    }
    func updateProgress(statusMessage: String, showInLog: Bool) {}
    let diagnosticContext: DiagnosticContextData = .init(target: nil)
    private var _diagnosticsEngine: DiagnosticsEngine = DiagnosticsEngine()
    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }
    var hasErrors: Bool {
        _diagnosticsEngine.hasErrors
    }
    var diagnostics: [Diagnostic] {
        _diagnosticsEngine.diagnostics
    }
    init() {
    }
}

private func constructTargetDependencyGraph(for targetGUIDs: [TargetGUID], in workspaceContext: WorkspaceContext, buildParameters: BuildParametersMessagePayload, includeImplicitDependencies: Bool, dependencyScope: DependencyScopeMessagePayload) async throws -> TargetDependencyGraph {
    var targets: [SWBCore.Target] = []
    for guid in targetGUIDs {
        guard let target = workspaceContext.workspace.target(for: guid.rawValue) else {
            throw MsgParserError.missingTarget(guid: guid.rawValue)
        }
        targets.append(target)
    }
    let parameters = try BuildParameters(from: buildParameters, core: workspaceContext.core)
    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext, cacheSettings: true)
    let delegate = ResolverDelegate()

    let scope: DependencyScope
    switch dependencyScope {
    case .workspace:
        scope = .workspace
    case .buildRequest:
        scope = .buildRequest
    }
    let buildGraph = await TargetDependencyGraph(workspaceContext: workspaceContext,
                                      buildRequest: BuildRequest(parameters: parameters,
                                                                 buildTargets: targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, dependencyScope: scope,
                                                                 continueBuildingAfterErrors: false,
                                                                 hideShellScriptEnvironment: true,
                                                                 useParallelTargets: false,
                                                                 useImplicitDependencies: includeImplicitDependencies,
                                                                 useDryRun: false),
                                      buildRequestContext: buildRequestContext,
                                      delegate: delegate)
    if delegate.hasErrors {
        throw StubError.error("unable to get target build graph:\n" + delegate.diagnostics.map { $0.formatLocalizedDescription(.debug) }.joined(separator: "\n"))
    }
    return buildGraph
}

struct ComputeDependencyClosureMsg: MessageHandler {
    func handle(request: Request, message: ComputeDependencyClosureRequest) async throws -> StringListResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let inputs = DependencyGraphRequestInputs(workspaceContext: workspaceContext)
        let graphRequest = ComputeDependencyGraphRequest(sessionHandle: message.sessionHandle, targetGUIDs: message.targetGUIDs.map(TargetGUID.init(rawValue:)), buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
        let reusableContext = session.dependencyGraphContext(for: inputs, key: inputs.requestKey(for: graphRequest))
        let context = reusableContext.acquireWorkspaceContext()
        defer { reusableContext.finished(using: context) }
        let buildGraph = try await constructTargetDependencyGraph(for: graphRequest.targetGUIDs, in: context, buildParameters: graphRequest.buildParameters, includeImplicitDependencies: graphRequest.includeImplicitDependencies, dependencyScope: graphRequest.dependencyScope)
        let guids = buildGraph.allTargets.map(\.target.guid)
        return StringListResponse(guids)
    }
}

// Maintained for message format compatibility only.
struct ComputeDependencyGraphMsg: MessageHandler {
    func handle(request: Request, message: ComputeDependencyGraphRequest) async throws -> DependencyGraphResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let inputs = DependencyGraphRequestInputs(workspaceContext: workspaceContext)
        let reusableContext = session.dependencyGraphContext(for: inputs, key: inputs.requestKey(for: message))
        let context = reusableContext.acquireWorkspaceContext()
        defer { reusableContext.finished(using: context) }
        let buildGraph = try await constructTargetDependencyGraph(for: message.targetGUIDs, in: context, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
        var adjacencyList: [TargetGUID: [TargetGUID]] = [:]
        for configuredTarget in buildGraph.allTargets {
            adjacencyList[TargetGUID(rawValue: configuredTarget.target.guid), default: []].append(contentsOf: buildGraph.dependencies(of: configuredTarget).map { TargetGUID(rawValue: $0.target.guid) })
        }
        return DependencyGraphResponse(adjacencyList: adjacencyList)
    }
}


// Queued requests can outlive PIF replacement. Retain their inputs without the old context's caches.
package struct DependencyGraphRequestInputs: Sendable {
    private let core: Core
    private let workspace: SWBCore.Workspace
    private let fs: any FSProxy
    package let userInfo: UserInfo?
    package let systemInfo: SystemInfo?
    package let userPreferences: UserPreferences

    package init(workspaceContext: WorkspaceContext) {
        core = workspaceContext.core
        workspace = workspaceContext.workspace
        fs = workspaceContext.fs
        userInfo = workspaceContext.userInfo
        systemInfo = workspaceContext.systemInfo
        userPreferences = workspaceContext.userPreferences
    }

    package func requestKey(for message: ComputeDependencyGraphRequest) -> DependencyGraphRequestCoordinator.RequestKey {
        .init(core: ObjectIdentifier(core), fs: ObjectIdentifier(fs), workspace: ObjectIdentifier(workspace), workspaceSignature: workspace.signature, userInfo: userInfo, systemInfo: systemInfo, userPreferences: userPreferences, request: message)
    }

    package func requestKey(for message: NonBlockingComputeDependencyGraphRequest) -> DependencyGraphRequestCoordinator.RequestKey {
        requestKey(for: .init(sessionHandle: message.sessionHandle, targetGUIDs: message.targetGUIDs, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope))
    }

    package func makeWorkspaceContext() -> WorkspaceContext {
        let context = WorkspaceContext(core: core, workspace: workspace, fs: fs, processExecutionCache: ProcessExecutionCache())
        if let userInfo {
            context.updateUserInfo(userInfo)
        }
        if let systemInfo {
            context.updateSystemInfo(systemInfo)
        }
        context.updateUserPreferences(userPreferences)
        return context
    }
}

// A session owns one current input set. Queued requests only weakly reference this owner.
package final class DependencyGraphContext: Sendable {
    package let inputs: DependencyGraphRequestInputs
    package let key: DependencyGraphRequestCoordinator.RequestKey
    private struct State: ~Copyable {
        var workspaceContext: WorkspaceContext?
        var isInUse = false
    }

    private let state = SWBMutex(State())

    package init(inputs: DependencyGraphRequestInputs, key: DependencyGraphRequestCoordinator.RequestKey) {
        self.inputs = inputs
        self.key = key
    }

    package func acquireWorkspaceContext() -> WorkspaceContext {
        state.withLock { state in
            // A concurrent query must not borrow settings before the first query has
            // established whether its SDK and filesystem inputs permit reuse.
            if state.isInUse { return inputs.makeWorkspaceContext() }
            let context = state.workspaceContext ?? inputs.makeWorkspaceContext()
            state.workspaceContext = context
            state.isInUse = true
            return context
        }
    }

    package func finished(using context: WorkspaceContext) {
        state.withLock { state in
            guard state.workspaceContext === context else { return }
            state.isInUse = false
            // Some settings inputs and context-specific SDK registries are not signature-validated.
            // Preserve their per-request freshness instead of reusing those contexts.
            if context.settingsRequireFreshContext || context.sdkRegistry.hasCustomSDKs {
                state.workspaceContext = nil
            }
        }
    }
}

private func computeDependencyGraphResponse(for message: NonBlockingComputeDependencyGraphRequest, in workspaceContext: WorkspaceContext) async throws -> DependencyGraphResponse {
    let buildGraph = try await constructTargetDependencyGraph(for: message.targetGUIDs, in: workspaceContext, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
    try _Concurrency.Task.checkCancellation()
    var adjacencyList: [TargetGUID: [TargetGUID]] = [:]
    for configuredTarget in buildGraph.allTargets {
        try _Concurrency.Task.checkCancellation()
        adjacencyList[TargetGUID(rawValue: configuredTarget.target.guid), default: []].append(contentsOf: buildGraph.dependencies(of: configuredTarget).map { TargetGUID(rawValue: $0.target.guid) })
    }
    return DependencyGraphResponse(adjacencyList: adjacencyList)
}

struct NonBlockingComputeDependencyGraphMsg: MessageHandler {
    func handle(request: Request, message: NonBlockingComputeDependencyGraphRequest) async throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildParameters = try BuildParameters(from: message.buildParameters, core: workspaceContext.core)

        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "compute_dependency_graph")

        let isIndexRequest = buildParameters.action == .indexBuild
        let inputs = DependencyGraphRequestInputs(workspaceContext: workspaceContext)
        let key = inputs.requestKey(for: message)
        let reusableContext = WeakRef(session.dependencyGraphContext(for: inputs, key: key))
        let operation: @Sendable () async throws -> DependencyGraphResponse = {
            if let reusableContext = reusableContext.instance {
                let context = reusableContext.acquireWorkspaceContext()
                defer { reusableContext.finished(using: context) }
                return try await computeDependencyGraphResponse(for: message, in: context)
            }
            return try await computeDependencyGraphResponse(for: message, in: inputs.makeWorkspaceContext())
        }

        session.dependencyGraphRequestCoordinator.submit(lane: isIndexRequest ? .index : .foreground, priority: isIndexRequest ? .utility : .userInitiated, indexRequestKey: isIndexRequest ? key : nil, operation: operation) { outcome in
            switch outcome {
            case .success(let response):
                requestForReply.reply(response)
            case .failure(let description):
                requestForReply.reply(ErrorResponse("unable to compute dependency graph: \(description)"))
            case .cancelled:
                requestForReply.reply(VoidResponse())
            }
        }

        return VoidResponse()
    }
}
