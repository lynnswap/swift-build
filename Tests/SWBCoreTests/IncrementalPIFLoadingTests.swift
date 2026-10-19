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

import Foundation
import Testing
import SWBCore
import SWBUtil
import SWBTestSupport
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBMacro

/// Test of the incremental PIF loading mechanisms.
@Suite(.serialized) fileprivate struct IncrementalPIFLoadingTests {
    @Test
    func basics() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let testWorkspace2 = TestWorkspace("bWorkspace", projects: [testProject])

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: nil)

        allStatistics.zero()

        // Load the first workspace.
        do {

            // We expect two entries in the PIF data.
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObject = pifObjects[2]

            // Initiate a loading session.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [testWorkspace.signature])

            // Add the workspace data.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [testProject.signature])

            // Add the project data.
            try session.add(object: projectObject)
            #expect(session.missingObjects.map{ $0.signature } == [testTarget.signature])

            // Add the target data.
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Load the workspace.
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)
        }

        // Reset the stats.
        allStatistics.zero()

        // Load a second workspace, which shares the project.
        do {
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]

            // Initiate a loading session.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            #expect(session.missingObjects.map{ $0.signature } == [testWorkspace2.signature])

            // Add the workspace data, which should complete all the necessary objects.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Check we error out if we try to add something that isn't required.
            #expect(throws: (any Error).self) {
                try session.add(object: workspaceObject)
            }
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Load the workspace.
            let workspace = try session.load()

            #expect(workspace.name == "bWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 1)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 1)
        }
    }

    @Test
    func brokenCache() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let fs = PseudoFS()
        let cachePath = Path.root.join("tmp")

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: cachePath, fs: fs)
        let pifObjects = try testWorkspace.toObjects()
        #expect(pifObjects.count == 3)
        let workspaceObject = pifObjects[0]
        let projectObject = pifObjects[1]
        let targetObject = pifObjects[2]

        // Load the pif.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{$0}.count == 1)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // We should not get any missing object when we load again.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // Remove one of the cache directory.
        do {
            let workspaceCachePath = cachePath.join("workspace")
            try fs.removeDirectory(workspaceCachePath)
        }

        // Load again after breaking the integrity of a cache directory.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            // We should have missingObjects.
            #expect(incrementalLoader.loadedObjectCount == 2)
            #expect(session.missingObjects.map{$0}.count == 1)

            // Add the workspace object back.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // Remove the full cache and load again
        try fs.removeDirectory(cachePath)
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            // We should have missingObjects.
            #expect(incrementalLoader.loadedObjectCount == 2)
            #expect(session.missingObjects.map{$0}.count == 1)

            // Add the objects back.
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }
    }

    @Test
    func persistence() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let testWorkspace2 = TestWorkspace("bWorkspace", projects: [testProject])

        let fs = PseudoFS()

        allStatistics.zero()

        // Transfer the first workspace.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObject = pifObjects[2]
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)
        }

        allStatistics.zero()

        // Load the first workspace again.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 0)
        }

        allStatistics.zero()

        // Load a second workspace, which shares the project.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "bWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 1)
        }
    }

    @Test(arguments: [false, true])
    func refreshesParentsWithUnchangedSignatures(useDiskCache: Bool) throws {
        let workspaceSignature = "WORKSPACE@v11_stable"
        let projectSignature = "PROJECT@v11_stable"
        let stableTargetSignature = "TARGET@v11_stable"
        let oldTargetSignature = "TARGET@v11_old"
        let newTargetSignature = "TARGET@v11_new"
        let fs = PseudoFS()
        let cachePath: Path? = useDiskCache ? Path.root.join("tmp/PIFCache") : nil

        func makeLoader() -> IncrementalPIFLoader {
            IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: cachePath, fs: fs, refreshParentObjects: true)
        }

        func objects(targetSignature: String, version: String, workspaceName: String = "aWorkspace") -> [PropertyListItem] {
            [
                .plDict([
                    "type": "workspace", "signature": .plString(workspaceSignature),
                    "contents": .plDict([
                        "guid": "workspace", "name": .plString(workspaceName), "path": "/tmp/aWorkspace.xcworkspace",
                        "projects": .plArray([.plString(projectSignature)]),
                    ]),
                ]),
                .plDict([
                    "type": "project", "signature": .plString(projectSignature),
                    "contents": .plDict([
                        "guid": "project", "path": "/tmp/aProject.xcodeproj",
                        "targets": .plArray([.plString(targetSignature), .plString(stableTargetSignature)]),
                        "groupTree": .plDict(["guid": "group", "type": "group", "name": "Sources", "sourceTree": "PROJECT_DIR", "path": "/tmp"]),
                        "buildConfigurations": .plArray([]), "defaultConfigurationName": "Debug",
                    ]),
                ]),
                .plDict([
                    "type": "target", "signature": .plString(targetSignature),
                    "contents": .plDict([
                        "guid": "target", "name": "PackageTarget", "type": "aggregate",
                        "buildConfigurations": .plArray([.plDict(["name": "Debug", "buildSettings": .plDict(["SWIFT_USER_MODULE_VERSION": .plString(version)])])]),
                        "buildPhases": .plArray([]), "dependencies": .plArray([]),
                    ]),
                ]),
                .plDict([
                    "type": "target", "signature": .plString(stableTargetSignature),
                    "contents": .plDict([
                        "guid": "stable-target", "name": "StableTarget", "type": "aggregate",
                        "buildConfigurations": .plArray([]), "buildPhases": .plArray([]), "dependencies": .plArray([]),
                    ]),
                ]),
            ]
        }

        func transfer(_ objects: [PropertyListItem], to loader: IncrementalPIFLoader, expectedTargets: Set<String>) throws -> SWBCore.Workspace {
            let session = loader.startLoading(workspaceSignature: workspaceSignature)
            #expect(session.missingObjects.map { $0.signature } == [workspaceSignature])
            try session.add(object: objects[0])
            #expect(session.missingObjects.map { $0.signature } == [projectSignature])
            try session.add(object: objects[1])
            #expect(Set(session.missingObjects.map { $0.signature }) == expectedTargets)
            for object in objects.dropFirst(2) {
                guard case let .plDict(dictionary) = object, case let .plString(signature)? = dictionary["signature"] else {
                    Issue.record("expected a target PIF object")
                    continue
                }
                if expectedTargets.contains(signature) {
                    try session.add(object: object)
                }
            }
            #expect(Array(session.missingObjects).isEmpty)
            return try session.load()
        }

        let loader = makeLoader()
        let original = try transfer(objects(targetSignature: oldTargetSignature, version: "1.0"), to: loader, expectedTargets: [oldTargetSignature, stableTargetSignature])
        let updatedLoader = useDiskCache ? makeLoader() : loader
        let updatedObjects = objects(targetSignature: newTargetSignature, version: "1.1")
        let updated = try transfer(updatedObjects, to: updatedLoader, expectedTargets: [newTargetSignature])
        #expect(updated !== original)
        #expect(updated.projects[0] !== original.projects[0])
        #expect(updated.projects[0].targets[0].guid == original.projects[0].targets[0].guid)
        #expect(updated.projects[0].targets[0].signature == newTargetSignature)
        let settings = try #require(updated.projects[0].targets[0].buildConfigurations.first).buildSettings
        #expect(MacroEvaluationScope(table: settings).evaluate(BuiltinMacros.SWIFT_USER_MODULE_VERSION) == "1.1")
        if !useDiskCache {
            #expect(updated.projects[0].targets[1] === original.projects[0].targets[1])
        }

        let unchanged = try transfer(updatedObjects, to: updatedLoader, expectedTargets: [])
        #expect(unchanged === updated)

        let renamed = try transfer(objects(targetSignature: newTargetSignature, version: "1.1", workspaceName: "Renamed"), to: updatedLoader, expectedTargets: [])
        #expect(renamed !== updated)
        #expect(renamed.name == "Renamed")
        #expect(renamed.projects[0] === updated.projects[0])
    }

    @Test
    func refreshesUnchangedBinaryParentsWithoutReplacingWorkspace() throws {
        let target = TestAggregateTarget("aTarget")
        let project = TestProject("aProject", groupTree: TestGroup("Sources"), targets: [target])
        let workspace = TestWorkspace("aWorkspace", projects: [project])
        let objects = try workspace.toObjects()
        let loader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: nil, refreshParentObjects: true)

        let firstSession = loader.startLoading(workspaceSignature: workspace.signature)
        for object in objects {
            try firstSession.add(object: object)
        }
        let first = try firstSession.load()

        let secondSession = loader.startLoading(workspaceSignature: workspace.signature)
        try secondSession.add(object: objects[0])
        try secondSession.add(object: objects[1])
        #expect(Array(secondSession.missingObjects).isEmpty)
        #expect(try secondSession.load() === first)
    }

    /// Check that references are rewired correctly on incremental loading.
    @Test
    func projectReferences() throws {
        let testTargetA = TestStandardTarget(
            "aTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["foo.c"])])
        let testTargetB = TestStandardTarget(
            "bTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["bar.c"])])
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", children: [TestFile("foo.c"), TestFile("bar.c"), TestFile("baz.c")]),
            targets: [testTargetA, testTargetB])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: nil)

        allStatistics.zero()

        // Load the first workspace.
        do {
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 4)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObjectA = pifObjects[2]
            let targetObjectB = pifObjects[3]

            // Load the workspace.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObjectA)
            try session.add(object: targetObjectB)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])
            #expect(workspace.projects.flatMap{ $0.targets }.map{ $0.name } == ["aTarget", "bTarget"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 4)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 4)
        }

        // Reset the stats.
        allStatistics.zero()

        // Load with a new project but shared targetA.
        let testTargetB2 = TestStandardTarget(
            "bTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["baz.c"])])
        let testProject2 = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", children: [TestFile("foo.c"), TestFile("bar.c"), TestFile("baz.c")]),
            targets: [testTargetA, testTargetB2])
        let testWorkspace2 = TestWorkspace("aWorkspace", projects: [testProject2])

        // Load a second workspace with the new target.
        do {
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 4)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObjectB = pifObjects[3]

            // Load the workspace.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObjectB)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])
            #expect(workspace.projects.flatMap{ $0.targets }.map{ $0.name } == ["aTarget", "bTarget"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)

            // Validate that the file references are consistent.
            var knownReferences = Set<SWBCore.FileReference>()
            func visit(_ ref: SWBCore.Reference) {
                switch ref {
                case let asGroup as SWBCore.FileGroup:
                    asGroup.children.forEach(visit)
                case let asFile as SWBCore.FileReference:
                    knownReferences.insert(asFile)
                default:
                    fatalError("unexpected reference: \(ref)")
                }
            }
            for project in workspace.projects {
                knownReferences.removeAll()
                visit(project.groupTree)
                for case let target as SWBCore.BuildPhaseTarget in project.targets {
                    for case let phase as SWBCore.BuildPhaseWithBuildFiles in target.buildPhases {
                        for buildFile in phase.buildFiles {
                            switch buildFile.buildableItem {
                            case .reference(let guid):
                                let ref = try #require(workspace.lookupReference(for: guid) as? SWBCore.FileReference)
                                #expect(knownReferences.contains(ref), "unexpected target reference: \(ref)")
                            case .targetProduct(_):
                                continue
                            case .namedReference:
                                Issue.record("unexpected named reference")
                            }
                        }
                    }
                }
            }
        }
    }
}

