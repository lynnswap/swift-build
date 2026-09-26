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

public import SWBCore
import SWBLibc
import SWBUtil
import Foundation

final public class SwiftDriverCompilationRequirementTaskAction: SwiftDriverJobSchedulingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-compilation-requirement"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let result = await super.performTaskAction(task, dynamicExecutionDelegate: dynamicExecutionDelegate, executionDelegate: executionDelegate, clientDelegate: clientDelegate, outputDelegate: outputDelegate)
        guard result == .succeeded,
              case .prepareForIndexing(_, true) = executionDelegate.buildCommand,
              let driverPayload = (task.payload as? SwiftTaskPayload)?.driverPayload,
              let path = driverPayload.indexExplicitModuleInfoPath else { return result }

        // The scheduler has completed the module jobs successfully, so their inputs can now be reused by indexing.
        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)
            guard let job = plannedBuild.compilationRequirementsPlannedDriverJobs().first(where: {
                $0.driverJob.categorizer.isEmitModule || $0.driverJob.categorizer.isCompile
            }) else { return result }
            let commandLine = try plannedBuild.resolvedCommandLine(for: job)
            let info = IndexExplicitModuleInfo(driverCommandLine: driverPayload.commandLine, compilerVersion: driverPayload.compilerVersion, resolvedArguments: commandLine)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let contents = try ByteString(encoder.encode(info))
            try executionDelegate.fs.createDirectory(path.dirname, recursive: true)
            _ = try executionDelegate.fs.writeIfChanged(path, contents: contents)
        } catch {
            outputDelegate.warning("Unable to write explicit modules index info: \(error)")
        }
        return result
    }

    public override func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        plannedBuild.compilationRequirementsPlannedDriverJobs()
    }

    public override func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        []
    }

    public override func secondaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        if !driverPayload.eagerCompilationEnabled {
            return plannedBuild.afterCompilationPlannedDriverJobs()
        }
        return []
    }

    public override func shouldReportSkippedJobs(driverPayload: SwiftDriverPayload) -> Bool {
        !driverPayload.eagerCompilationEnabled
    }

    public override func copyForConcurrentExecution() -> TaskAction? {
        // Carries a per-execution scheduling state machine and no configuration, so a
        // fresh instance is equivalent and isolates concurrent engines from each other.
        SwiftDriverCompilationRequirementTaskAction()
    }
}
