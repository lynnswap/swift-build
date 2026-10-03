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
import Testing
@testable import CustomXcodeBuildService

@Test(arguments: ["../escape", "v1.0.0/../../escape", "v1.0.0\n", "", ".", ".."])
func rejectsInvalidReleaseVersions(version: String) throws {
    let fixture = try Fixture()
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: fixture.package(version)) }
}

@Test(arguments: ["Info.plist", "PlugIns/HostPlatformPlugins.bundle/Contents/Info.plist"])
func installationStillRequiresBundlePropertyLists(path: String) throws {
    let fixture = try Fixture()
    let package = try ReleasePackage(directory: fixture.package("v1.0.0"))
    try FileManager.default.removeItem(at: package.resources.appendingPathComponent(path))
    #expect(throws: (any Error).self) { try fixture.enable( package.directory) }
    #expect(fixture.runner.launchctlMutations.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func rejectsMalformedAndUnsupportedManifest() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v1.0.0")
    try fixture.write("{", to: package.appendingPathComponent("manifest.json"))
    #expect(throws: (any Error).self) { try ReleasePackage(directory: package) }
    for changes in [
        ["schemaVersion": 3],
        ["resourceBundles": []], ["resourceBundles": ["../escape.bundle"]],
    ] as [[String: Any]] {
        #expect(throws: ServiceError.self) {
            try ReleasePackage(directory: fixture.package("v1.0.0", manifestChanges: changes))
        }
    }
}

@Test func rejectsMissingResources() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v1.0.0")
    try FileManager.default.removeItem(at: package.appendingPathComponent("libexec/swift-build/SWBBuildService.bundle/SwiftBuild_SWBCore.bundle"))
    #expect(throws: (any Error).self) { try fixture.enable( package) }
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func installsWithAdditionalRegularFilesInAnExtractedPackage() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v1.0.0")
    for path in [".DS_Store", "bin/.DS_Store", "libexec/.DS_Store", "libexec/swift-build/.DS_Store", "libexec/swift-build/SWBBuildService.bundle/.DS_Store"] {
        try fixture.write("Finder metadata", to: package.appendingPathComponent(path))
    }
    _ = try fixture.enable( package)
    let installed = try #require(try fixture.store.selectedPackage())
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == fixture.store.service.path)
    #expect(fixture.runner.loaded)
}

@Test func buildRecordsDoNotRestrictUseOfAnInstalledPackage() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v1.0.0", manifestChanges: [
        "sourceRevision": "local source", "xcodeVersion": "27.1 beta", "xcodeBuildVersion": "local build",
        "minimumMacOSVersion": "26.1", "dependencies": [],
    ])
    _ = try fixture.enable( package)
    _ = try fixture.manager.activate()
    #expect(try fixture.manager.status().contains("Built with Xcode: 27.1 beta (local build)"))
}

@Test func missingHostPluginStopsInstallationBeforeChangingSelection() throws {
    let fixture = try Fixture()
    let package = try ReleasePackage(directory: fixture.package("v1.0.0"))
    try FileManager.default.removeItem(at: package.hostPlugin)
    #expect(throws: (any Error).self) { try fixture.enable( package.directory) }
    #expect(fixture.runner.settings.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func buildMetadataDoesNotRestrictInstallationToAnXcodeVersion() throws {
    let fixture = try Fixture()
    fixture.runner.xcodeStatus = 1
    _ = try fixture.enable( fixture.package("v1.0.0", manifestChanges: [
        "xcodeVersion": "26.6", "xcodeBuildVersion": "17F113",
    ]))
    #expect(try fixture.manager.status().contains("Built with Xcode: 26.6 (17F113)"))
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
}

@Test func rejectsArchivePathAndNonExecutablePayload() throws {
    let fixture = try Fixture()
    let archive = fixture.directory.appendingPathComponent("release.tar.gz")
    try fixture.write("archive", to: archive)
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: archive) }
    let package = try fixture.package("v1.0.0")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: package.appendingPathComponent("libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle").path)
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: package).validateForUse() }
}

@Test(arguments: [
    "current", "versions", "versions/v1.0.0",
    "versions/v1.0.0/libexec/swift-build/external",
])
func uninstallRemovesOwnedLinksWithoutFollowingDestinations(path: String) throws {
    let fixture = try Fixture()
    let package = try fixture.package("v1.0.0")
    _ = try fixture.enable( package)
    let link = fixture.store.root.appendingPathComponent(path)
    if try fixture.store.exists(link) { try FileManager.default.removeItem(at: link) }
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)

    _ = try fixture.manager.uninstall()

    #expect(try String(contentsOf: package.appendingPathComponent("licenses/LICENSE.txt"), encoding: .utf8) == "Apache")
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.current))
}

@Test func processRunnerDrainsBothStreamsAndPreservesExitStatus() throws {
    let result = try ProcessRunner().run("/usr/bin/python3", ["-c", "import os; os.write(1, b'a' * 200000); os.write(2, b'b' * 200000); raise SystemExit(7)"])
    #expect(result.status == 7)
    #expect(result.output.count == 400000)
    #expect(throws: ServiceError.self) { try result.requireSuccess("fixture") }
}
