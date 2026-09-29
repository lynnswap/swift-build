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

import Testing
import SWBUtil
import SWBCore
import SWBTestSupport

@Suite(.performance)
fileprivate struct CorePerfTests: PerfTests {
    @Test
    func specRegistrationPerf() async throws {
        try await measure {
            try await Core.perfTestSpecRegistration()
        }
    }

    @Test
    func completeSpecLoadingPerf() async throws {
        try await measure {
            try await Core.perfTestSpecLoading()
        }
    }
}

@Suite(.performance, .requireSDKs(.macOS))
fileprivate struct ImplicitDependencyLookupPerfTests: CoreBasedTests, PerfTests {
    @Test
    func explicitProductStemLookups() async throws {
        let core = try await getCore()
        let explicitNames = (0..<1000).map { "Explicit\($0)" }
        let linkedNames = (0..<300).map { "Unmatched\($0)" } + ["Implicit"]
        let workspace = try TestWorkspace("Workspace", projects: [
            TestProject("Project", groupTree: TestGroup("Files", children: linkedNames.map {
                TestFile("\($0).ideplugin/Contents/MacOS/\($0)", fileType: "compiled.mach-o.dylib")
            }), buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"]),
            ], targets: [
                TestStandardTarget("App", type: .application, buildPhases: [
                    TestFrameworksBuildPhase(linkedNames.map { TestBuildFile($0) }),
                ], dependencies: explicitNames.map { TestTargetDependency($0) }),
                TestStandardTarget("Implicit", type: .bundle, productReferenceName: "Implicit.ideplugin"),
            ] + explicitNames.map {
                TestStandardTarget($0, type: .framework, productReferenceName: "\($0).framework")
            })
        ]).load(core)
        let context = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        let parameters = BuildParameters(configuration: "Debug")
        let app = BuildRequest.BuildTargetInfo(parameters: parameters, target: workspace.projects[0].targets[0])
        let request = BuildRequest(parameters: parameters, buildTargets: [app], continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        try await measure {
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
            let elapsed = try await SuspendingClock.suspending.measure {
                let graph = await TargetDependencyGraph(workspaceContext: context, buildRequest: request, buildRequestContext: BuildRequestContext(workspaceContext: context), delegate: delegate)
                #expect(graph.allTargets.count == explicitNames.count + 2)
                let configuredApp = try #require(graph.allTargets.first { $0.target == app.target })
                #expect(Set(graph.dependencies(of: configuredApp).map { $0.target.name }) == Set(explicitNames + ["Implicit"]))
            }
            delegate.checkNoDiagnostics()
            perfPrint("Implicit dependency stems (1000 explicit products, 301 linked files): \(elapsed)")
        }
    }
}
