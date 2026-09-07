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

@Test(arguments: ["../escape", "custom-v1.0.0/../../escape", "custom-v1.0", "custom-v1.0.0\n", "v1.0.0"])
func rejectsInvalidReleaseVersions(version: String) throws {
    let fixture = try Fixture()
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: fixture.package(version)) }
}

@Test func rejectsMalformedAndUnsupportedManifest() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    try fixture.write("{", to: package.appendingPathComponent("manifest.json"))
    #expect(throws: (any Error).self) { try ReleasePackage(directory: package) }
    for changes in [
        ["schemaVersion": 2], ["sourceRevision": "main"], ["architecture": "x86_64"],
        ["xcodeVersion": "26.0"], ["xcodeBuildVersion": "../27A5252f"], ["minimumMacOSVersion": "15.0"],
        ["resourceBundles": []], ["resourceBundles": ["../escape.bundle"]],
        ["resourceBundles": ["SwiftBuild_SWBCore.bundle", "SwiftBuild_SWBCore.bundle"]],
        ["dependencies": [["identity": "swift-tools-support-core", "revision": "main"]]],
    ] as [[String: Any]] {
        #expect(throws: ServiceError.self) {
            try ReleasePackage(directory: fixture.package("custom-v1.0.0", manifestChanges: changes))
        }
    }
}

@Test func rejectsMissingResourcesAndAdditionalFiles() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    try FileManager.default.removeItem(at: package.appendingPathComponent("libexec/swift-build/SwiftBuild_SWBCore.bundle"))
    #expect(throws: (any Error).self) { try fixture.manager.install(from: package) }
    let additional = try fixture.package("custom-v1.0.1")
    try fixture.write("unexpected", to: additional.appendingPathComponent("extra"))
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: additional) }
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func rejectsSymlinksEvenWithinPackage() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("licenses/escape").path, withDestinationPath: fixture.directory.path)
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: package) }
    try FileManager.default.removeItem(at: package.appendingPathComponent("licenses/escape"))
    try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("licenses/link").path, withDestinationPath: "LICENSE.txt")
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: package) }
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func rejectsArchivePathAndNonExecutablePayload() throws {
    let fixture = try Fixture()
    let archive = fixture.directory.appendingPathComponent("release.tar.gz")
    try fixture.write("archive", to: archive)
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: archive) }
    let package = try fixture.package("custom-v1.0.0")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: package.appendingPathComponent("libexec/swift-build/SWBBuildServiceBundle").path)
    #expect(throws: ServiceError.self) { try ReleasePackage(directory: package) }
}

@Test(arguments: [
    "current", "versions", "versions/custom-v1.0.0",
    "versions/custom-v1.0.0/libexec/swift-build/external",
])
func uninstallRemovesOwnedLinksWithoutFollowingDestinations(path: String) throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    _ = try fixture.manager.install(from: package)
    let link = fixture.store.root.appendingPathComponent(path)
    if try fixture.store.exists(link) { try FileManager.default.removeItem(at: link) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)

    _ = try fixture.manager.uninstall()

    #expect(try String(contentsOf: package.appendingPathComponent("licenses/LICENSE.txt"), encoding: .utf8) == "Apache")
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.current))
}

@Test func rejectsSymlinkedInstallationParent() throws {
    let fixture = try Fixture()
    let other = fixture.directory.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.store.home.appendingPathComponent("Library"), withDestinationURL: other)
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: fixture.package("custom-v1.0.0")) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
}

@Test func parserAcceptsOnlyDocumentedCommands() throws {
    #expect(try Command(arguments: []) == .help)
    #expect(try Command(arguments: ["install"]) == .install(package: nil))
    #expect(try Command(arguments: ["install", "--package", "/a path"]) == .install(package: "/a path"))
    #expect(try Command(arguments: ["use", "custom"]) == .use(.custom))
    #expect(try Command(arguments: ["use", "bundled"]) == .use(.bundled))
    for arguments in [["install", "--package"], ["install", "--package", "--help"], ["status", "extra"], ["unknown"],
                      ["use"], ["use", "default"], ["use", "custom", "extra"], ["use", "bundled", "extra"]] {
        #expect(throws: ServiceError.self) { try Command(arguments: arguments) }
    }
}

@Test func processRunnerDrainsBothStreamsAndPreservesExitStatus() throws {
    let result = try ProcessRunner().run("/usr/bin/python3", ["-c", "import os; os.write(1, b'a' * 200000); os.write(2, b'b' * 200000); raise SystemExit(7)"])
    #expect(result.status == 7)
    #expect(result.output.count == 400000)
    #expect(throws: ServiceError.self) { try result.requireSuccess("fixture") }
}
