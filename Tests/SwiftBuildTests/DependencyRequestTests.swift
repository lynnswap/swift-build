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
import SwiftBuild
import SWBProtocol
import SwiftBuildTestSupport
import SWBTestSupport
import SWBUtil

@Suite(.requireHostOS(.macOS))
fileprivate struct DependencyClosureTests: CoreBasedTests {
    @Test(arguments: ["build", "indexbuild"])
    func computeDependencyClosureBasic(action: String) async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F1")]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2"), .init("F3")]
                )

                let pif = try TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem
                try await testSession.session.sendPIF(.init(pif))

                let parameters = SWBBuildParameters(action: action, configuration: "Debug", activeRunDestination: .anyiOSDevice)
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, f3Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [f2Target.guid], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [f3Target.guid], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [f3Target.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []
                        ])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: f2Target.guid)], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: f3Target.guid)], buildParameters: parameters, includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: f3Target.guid): []])

                if action == "indexbuild" {
                    try await testSession.session.sendPIF(.init(pif))
                    let expectedGraph: [SWBTargetGUID: [SWBTargetGUID]] = [
                        SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                        SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                        SWBTargetGUID(rawValue: f3Target.guid): [],
                        SWBTargetGUID(rawValue: f1Target.guid): [],
                    ]
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for _ in 0..<16 {
                            group.addTask {
                                let graph = try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: parameters, includeImplicitDependencies: true)
                                #expect(graph == expectedGraph)
                            }
                        }
                        try await group.waitForAll()
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func computeIndexDependencyGraphUsesUpdatedEnvironment() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let firstTarget = TestStandardTarget("First", type: .framework)
                let secondTarget = TestStandardTarget("Second", type: .framework)
                let mainTarget = TestStandardTarget(
                    "Main",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                        "EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES": "$(OMIT_TARGET)",
                    ])],
                    dependencies: [.init("First"), .init("Second")]
                )
                let pif = try TestWorkspace("Test", sourceRoot: temporaryDirectory.path, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test"),
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "macosx"])],
                        targets: [firstTarget, secondTarget, mainTarget]
                    ),
                ]).toObjects().propertyListItem
                try await testSession.session.sendPIF(.init(pif))

                let parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug", activeRunDestination: .anyMac)
                let firstGraph: [SWBTargetGUID: [SWBTargetGUID]] = [
                    SWBTargetGUID(rawValue: mainTarget.guid): [SWBTargetGUID(rawValue: secondTarget.guid)],
                    SWBTargetGUID(rawValue: secondTarget.guid): [],
                ]
                try await testSession.session.setUserInfo(SWBUserInfo.defaultForTesting.with(buildSystemEnvironment: ["OMIT_TARGET": "First"]))
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: mainTarget.guid)], buildParameters: parameters, includeImplicitDependencies: false) == firstGraph)

                try await testSession.session.setUserInfo(SWBUserInfo.defaultForTesting.with(buildSystemEnvironment: ["OMIT_TARGET": "Second"]))
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: mainTarget.guid)], buildParameters: parameters, includeImplicitDependencies: false) == [
                    SWBTargetGUID(rawValue: mainTarget.guid): [SWBTargetGUID(rawValue: firstTarget.guid)],
                    SWBTargetGUID(rawValue: firstTarget.guid): [],
                ])

                try await testSession.session.sendPIF(.init(pif))
                try await testSession.session.setUserInfo(SWBUserInfo.defaultForTesting.with(buildSystemEnvironment: ["OMIT_TARGET": "First"]))
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: mainTarget.guid)], buildParameters: parameters, includeImplicitDependencies: false) == firstGraph)
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func computeDependencyClosureWithPlatformFilters() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F1")]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2", platformFilters: PlatformFilter.macOSFilters), .init("F3", platformFilters: PlatformFilter.iOSFilters)]
                )

                try await testSession.session.sendPIF(.init(TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem))

                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyMac), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice), includeImplicitDependencies: true) ==
                        [f3Target.guid, appTarget.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyMac), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid)],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): []])
            }
        }
    }

    @Test
    func computeDependencyClosureWithImplicitDependencies() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ]),
                        TestFrameworksBuildPhase([.init("F1.framework")])
                    ]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2"), .init("F3")]
                )

                try await testSession.session.sendPIF(.init(TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem))

                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, f3Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: false) ==
                        [f2Target.guid, f3Target.guid, appTarget.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []
                        ])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: false) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [],
                        ])
            }
        }
    }
}
