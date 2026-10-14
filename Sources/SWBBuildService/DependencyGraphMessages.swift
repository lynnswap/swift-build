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
    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
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
        let buildGraph = try await constructTargetDependencyGraph(for: message.targetGUIDs.map(TargetGUID.init(rawValue:)), in: workspaceContext, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
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
        let buildGraph = try await constructTargetDependencyGraph(for: message.targetGUIDs, in: workspaceContext, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope)
        var adjacencyList: [TargetGUID: [TargetGUID]] = [:]
        for configuredTarget in buildGraph.allTargets {
            adjacencyList[TargetGUID(rawValue: configuredTarget.target.guid), default: []].append(contentsOf: buildGraph.dependencies(of: configuredTarget).map { TargetGUID(rawValue: $0.target.guid) })
        }
        return DependencyGraphResponse(adjacencyList: adjacencyList)
    }
}


// Index requests can outlive PIF replacement. Retain their inputs without the old context's caches.
package struct DependencyGraphRequestInputs: Sendable {
    private let core: Core
    private let workspace: SWBCore.Workspace
    private let fs: any FSProxy
    private let userInfo: UserInfo?
    private let systemInfo: SystemInfo?
    private let userPreferences: UserPreferences

    package init(workspaceContext: WorkspaceContext) {
        core = workspaceContext.core
        workspace = workspaceContext.workspace
        fs = workspaceContext.fs
        userInfo = workspaceContext.userInfo
        systemInfo = workspaceContext.systemInfo
        userPreferences = workspaceContext.userPreferences
    }

    package func requestKey(for message: NonBlockingComputeDependencyGraphRequest) -> DependencyGraphRequestCoordinator.IndexRequestKey {
        .init(core: ObjectIdentifier(core), fs: ObjectIdentifier(fs), workspaceSignature: workspace.signature, userInfo: userInfo, systemInfo: systemInfo, userPreferences: userPreferences, request: .init(sessionHandle: message.sessionHandle, targetGUIDs: message.targetGUIDs, buildParameters: message.buildParameters, includeImplicitDependencies: message.includeImplicitDependencies, dependencyScope: message.dependencyScope))
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

        let priority: _Concurrency.TaskPriority
        let indexRequestKey: DependencyGraphRequestCoordinator.IndexRequestKey?
        let operation: @Sendable () async throws -> DependencyGraphResponse
        if buildParameters.action == .indexBuild {
            priority = .utility
            let inputs = DependencyGraphRequestInputs(workspaceContext: workspaceContext)
            indexRequestKey = inputs.requestKey(for: message)
            operation = {
                try await computeDependencyGraphResponse(for: message, in: inputs.makeWorkspaceContext())
            }
        } else {
            priority = .userInitiated
            indexRequestKey = nil
            operation = {
                try await computeDependencyGraphResponse(for: message, in: workspaceContext)
            }
        }

        session.dependencyGraphRequestCoordinator.submit(lane: buildParameters.action == .indexBuild ? .index : .foreground, priority: priority, indexRequestKey: indexRequestKey, operation: operation) { outcome in
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
