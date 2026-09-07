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

@Test func installsRelocatesUpdatesAndUninstalls() throws {
    let fixture = try Fixture()
    let first = try fixture.package("custom-v1.0.0")
    _ = try fixture.manager.install(from: first)
    let selected = try #require(try fixture.store.selectedPackage())
    #expect(selected.manifest.version == "custom-v1.0.0")
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
    #expect(fixture.runner.loaded)
    #expect(FileManager.default.isExecutableFile(atPath: fixture.store.command.path))
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.store.agent), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == [fixture.store.persistentExecutable.path, "activate"])
    try FileManager.default.removeItem(at: first)
    #expect(try String(contentsOf: selected.service.deletingLastPathComponent().appendingPathComponent("SwiftBuild_SWBCore.bundle/spec.txt"), encoding: .utf8) == "specification")
    fixture.runner.settings = [:]
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)

    let second = try fixture.package("custom-v1.0.1")
    _ = try fixture.manager.install(from: second)
    let updated = try #require(try fixture.store.selectedPackage())
    #expect(updated.manifest.version == "custom-v1.0.1")
    #expect(try fixture.store.exists(selected.directory))
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == updated.service.path)
    _ = try fixture.manager.install(from: second)
    #expect(try fixture.store.selectedPackage()?.manifest.version == "custom-v1.0.1")
    fixture.runner.xcodeStatus = 1
    #expect(try fixture.manager.status().contains("Installed: custom-v1.0.1"))
    _ = try fixture.manager.uninstall()
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.current))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.agent))
    _ = try fixture.manager.uninstall()
}

@Test func installationFailureRestoresPreviousSelectionAndEnvironment() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let oldSettings = fixture.runner.settings
    fixture.runner.failOnce = ["setenv", "DisableConcurrentDependencyResolution", "0"]
    #expect(throws: ServiceError.self) {
        try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    }
    #expect(try fixture.store.selectedPackage()?.manifest.version == "custom-v1.0.0")
    #expect(fixture.runner.settings == oldSettings)
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.command))
}

@Test func bootstrapFailureLeavesFirstInstallInactiveAndRetryWorks() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    fixture.runner.failOnce = ["bootstrap", fixture.manager.environment.domain, fixture.store.agent.path]
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: package) }
    #expect(try fixture.store.selectedPackage() == nil)
    #expect(fixture.runner.settings.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.agent))
    _ = try fixture.manager.install(from: package)
    #expect(try fixture.store.selectedPackage()?.manifest.version == "custom-v1.0.0")
}

@Test func uninstallFailureRestoresEnvironmentAndLoadedJob() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let settings = fixture.runner.settings
    fixture.runner.failOnce = ["unsetenv", "XCBBUILDSERVICE_PATH"]
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.agent))
    #expect(try fixture.store.exists(fixture.store.root))
}

@Test(arguments: ["XCBBUILDSERVICE_PATH", "SWBBUILDSERVICE_PATH", "DisableConcurrentDependencyResolution"])
func refusesForeignEnvironment(key: String) throws {
    let fixture = try Fixture()
    fixture.runner.settings[key] = "foreign-value"
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: fixture.package("custom-v1.0.0")) }
    #expect(fixture.runner.settings == [key: "foreign-value"])
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(!fixture.runner.loaded)
}

@Test func refusesForeignCommandAndAgent() throws {
    let fixture = try Fixture()
    try fixture.write("do not replace", to: fixture.store.command)
    #expect(throws: (any Error).self) { try fixture.manager.install(from: fixture.package("custom-v1.0.0")) }
    #expect(try String(contentsOf: fixture.store.command, encoding: .utf8) == "do not replace")
    try FileManager.default.removeItem(at: fixture.store.command)
    try fixture.write("foreign plist", to: fixture.store.agent)
    #expect(throws: (any Error).self) { try fixture.manager.install(from: fixture.package("custom-v1.0.1")) }
    #expect(try String(contentsOf: fixture.store.agent, encoding: .utf8) == "foreign plist")
    #expect(fixture.runner.settings.isEmpty)
}

@Test func refusesExistingJobWithoutOwnedPlist() throws {
    let fixture = try Fixture()
    fixture.runner.loaded = true
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: fixture.package("custom-v1.0.0")) }
    #expect(fixture.runner.loaded)
    #expect(fixture.runner.settings.isEmpty)
}

@Test func refusesSameVersionWithDifferentContents() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    _ = try fixture.manager.install(from: package)
    try fixture.write("changed", to: package.appendingPathComponent("libexec/swift-build/SwiftBuild_SWBCore.bundle/spec.txt"))
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: package) }
    #expect(fixture.runner.loaded)
    let selected = try #require(try fixture.store.selectedPackage())
    #expect(try String(contentsOf: selected.service.deletingLastPathComponent().appendingPathComponent("SwiftBuild_SWBCore.bundle/spec.txt"), encoding: .utf8) == "specification")
}

@Test func validatesExactXcodeBeforeChangingSelection() throws {
    let fixture = try Fixture()
    fixture.runner.xcodeVersion = "Xcode 27.0\nBuild version 27A9999\n"
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: fixture.package("custom-v1.0.0")) }
    #expect(try !fixture.store.exists(fixture.store.root))
    #expect(fixture.runner.settings.isEmpty)
}

@Test func activateRejectsXcodeUpdateWithoutChangingSettings() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    fixture.runner.settings = [:]
    fixture.runner.xcodeVersion = "Xcode 28.0\nBuild version 28A100\n"
    #expect(throws: ServiceError.self) { try fixture.manager.activate() }
    #expect(fixture.runner.settings.isEmpty)
}

@Test func statusDistinguishesSelectedAndRunningServices() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let selected = try #require(try fixture.store.selectedPackage())
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService\n456 \(selected.service.path)\n789 /bin/zsh\n"
    let status = try fixture.manager.status()
    #expect(status.contains("custom release selected for future processes"))
    #expect(status.contains("PID 123: /Applications/Xcode.app"))
    #expect(status.contains("PID 456: \(selected.service.path) [selected release]"))
    #expect(!status.contains("PID 789"))
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.loaded)
}

@Test(arguments: [
    "/someone/elses/service",
    "Library/Developer/CustomXcodeBuildService/versions-other/custom-v1.0.0/libexec/swift-build/SWBBuildServiceBundle",
    "Library/Developer/CustomXcodeBuildService/versions/custom-v1.0.0/libexec/swift-build/another-service",
    "Library/Developer/CustomXcodeBuildService/versions/custom-v1.0.0/extra/libexec/swift-build/SWBBuildServiceBundle",
])
func uninstallPreservesExternallyChangedSettings(path: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let foreign = path.hasPrefix("/") ? path : fixture.store.home.appendingPathComponent(path).path
    fixture.runner.settings["XCBBUILDSERVICE_PATH"] = foreign
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == foreign)
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.root))
}

@Test(arguments: ["/Applications/Xcode.app/Contents/MacOS/Xcode", "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"])
func uninstallRefusesIdleXcodeClient(path: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    fixture.runner.processes = "123 \(path)\n"
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.root))
}

@Test func uninstallPreservesUnrelatedFilesInInstallationRoot() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let foreign = fixture.store.root.appendingPathComponent("my-file")
    try fixture.write("preserve", to: foreign)
    _ = try fixture.manager.uninstall()
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "preserve")
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.agent))
}

@Test(arguments: ["custom-v1.0.0", "custom-v1.0.1"])
func uninstallRemovesReleasesWithGeneratedFiles(version: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    let generated = fixture.store.versions.appendingPathComponent("\(version)/libexec/swift-build/WidgetPreviewExtension.dependency-scan.dia")
    try fixture.write("diagnostics", to: generated)

    _ = try fixture.manager.uninstall()

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.current))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.agent))
}

@Test(arguments: [
    "versions",
    "versions/custom-v1.0.0",
    "versions/custom-v1.0.0/manifest.json",
    "versions/custom-v1.0.0/bin/custom-xcode-build-service",
    "versions/custom-v1.0.0/libexec/swift-build/SWBBuildServiceBundle",
    "versions/custom-v1.0.0/libexec/swift-build/SwiftBuild_SWBCore.bundle",
])
func uninstallRemovesIncompleteInstallation(missingPath: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    try FileManager.default.removeItem(at: fixture.store.root.appendingPathComponent(missingPath))

    _ = try fixture.manager.uninstall()

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
    #expect(try !fixture.store.exists(fixture.store.current))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.agent))
}

@Test func uninstallDoesNotReadInstalledManifest() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    try fixture.write("{broken", to: fixture.store.versions.appendingPathComponent("custom-v1.0.0/manifest.json"))

    _ = try fixture.manager.uninstall()

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.versions))
}

@Test func uninstallClearsOwnedSettingsAfterPayloadsWereRemoved() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    fixture.runner.loaded = false
    try fixture.store.remove(fixture.store.agent)
    try fixture.store.remove(fixture.store.command)
    try fixture.store.removePayloads()

    _ = try fixture.manager.uninstall()

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
}

@Test func unexpectedLaunchctlErrorsAreNotAbsence() throws {
    let fixture = try Fixture()
    fixture.runner.failOnce = ["print", fixture.manager.environment.job]
    #expect(throws: ServiceError.self) { try fixture.manager.status() }
}

@Test func reconcilesPreviouslyOwnedEnvironmentAfterInterruptedUpdate() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let previousSettings = fixture.runner.settings
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    let selected = try #require(try fixture.store.selectedPackage())
    fixture.runner.settings = previousSettings
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
}

@Test func uninstallAndReinstallPreserveLockInodeForWaitingInvocations() throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    _ = try fixture.manager.install(from: package)
    let lock = fixture.store.root.appendingPathComponent(".lock")
    let inode = try #require(FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
    _ = try fixture.manager.uninstall()
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path)) == [".owner", ".lock"])
    _ = try fixture.manager.install(from: package)
    #expect(try FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber == inode)
}

@Test func rootAndNonGUIInstallationAreRefused() throws {
    let fixture = try Fixture()
    let root = InstallationManager(store: fixture.store, environment: LaunchEnvironment(runner: fixture.runner, userID: 0))
    #expect(throws: ServiceError.self) { try root.install(from: fixture.package("custom-v1.0.0")) }
    fixture.runner.failOnce = ["print", fixture.manager.environment.domain]
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: fixture.package("custom-v1.0.1")) }
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test(arguments: ["Background", "System", "wrongUID"], ["install", "activate", "uninstall", "status"])
func rejectsForeignLaunchdContextBeforeFilesystemAndEnvironmentChanges(context: String, command: String) throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    if command != "install" {
        _ = try fixture.manager.install(from: package)
        try fixture.write("keep pending bytes", to: fixture.store.staging.appendingPathComponent("incomplete"))
    }
    let settings = fixture.runner.settings
    let loaded = fixture.runner.loaded
    let mutations = fixture.runner.launchctlMutations
    fixture.runner.managerName = context == "wrongUID" ? "Aqua" : context
    fixture.runner.managerUserID = context == "wrongUID" ? "502" : "501"

    #expect(throws: ServiceError.self) {
        switch command {
        case "install": _ = try fixture.manager.install(from: package)
        case "activate": _ = try fixture.manager.activate()
        case "uninstall": _ = try fixture.manager.uninstall()
        default: _ = try fixture.manager.status()
        }
    }

    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded == loaded)
    #expect(fixture.runner.launchctlMutations == mutations)
    if command == "install" {
        #expect(try !fixture.store.exists(fixture.store.root))
    } else {
        #expect(try String(contentsOf: fixture.store.staging.appendingPathComponent("incomplete"), encoding: .utf8) == "keep pending bytes")
    }
}

@Test func uninstallWithoutInstallationIsNoOpWhileXcodeRuns() throws {
    let fixture = try Fixture()
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/MacOS/Xcode\n"
    #expect(try fixture.manager.uninstall() == "No custom build service is installed.")
    #expect(fixture.runner.launchctlMutations.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.root))
    #expect(try fixture.manager.status().contains("Installed: none"))
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func repeatedUninstallWithRetainedLockIsNoOpWhileXcodeRuns() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    _ = try fixture.manager.uninstall()
    let mutations = fixture.runner.launchctlMutations
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/MacOS/Xcode\n"
    #expect(try fixture.manager.uninstall() == "No custom build service is installed.")
    #expect(fixture.runner.launchctlMutations == mutations)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path)) == [".owner", ".lock"])
}

final class Fixture {
    let directory: URL
    let runner = FakeRunner()
    var store: InstallationStore { InstallationStore(home: directory.appendingPathComponent("home")) }
    var manager: InstallationManager { InstallationManager(store: store, environment: LaunchEnvironment(runner: runner, userID: 501)) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomBuildServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func package(_ version: String, manifestChanges: [String: Any] = [:]) throws -> URL {
        let package = directory.appendingPathComponent(UUID().uuidString)
        var manifest: [String: Any] = [
            "schemaVersion": 1, "version": version, "sourceRevision": String(repeating: "a", count: 40),
            "xcodeVersion": "27.0", "xcodeBuildVersion": "27A5252f", "architecture": "arm64", "minimumMacOSVersion": "26.0",
            "resourceBundles": ["SwiftBuild_SWBCore.bundle"],
            "dependencies": [["identity": "swift-tools-support-core", "revision": String(repeating: "b", count: 40)]],
        ]
        manifest.merge(manifestChanges, uniquingKeysWith: { _, new in new })
        try write("placeholder", to: package.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        for path in ["bin/custom-xcode-build-service", "libexec/swift-build/SWBBuildServiceBundle"] {
            let executable = package.appendingPathComponent(path)
            try write("#!/bin/sh\nexit 0\n", to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try write("specification", to: package.appendingPathComponent("libexec/swift-build/SwiftBuild_SWBCore.bundle/spec.txt"))
        try write("Apache", to: package.appendingPathComponent("licenses/LICENSE.txt"))
        return package
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

final class FakeRunner: ProcessRunning {
    var settings: [String: String] = [:]
    var loaded = false
    var xcodeVersion = "Xcode 27.0\nBuild version 27A5252f\n"
    var xcodeStatus: Int32 = 0
    var processes = ""
    var failOnce: [String]?
    var managerName = "Aqua"
    var managerUserID = "501"
    var launchctlMutations: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        if executable == "/usr/bin/uname" { return .init(status: 0, output: "arm64\n") }
        if executable == "/usr/bin/xcodebuild" { return .init(status: xcodeStatus, output: xcodeVersion) }
        if executable == "/bin/ps" {
            guard arguments == ["-U", "501", "-x", "-ww", "-o", "pid=,comm="] else {
                throw ServiceError("Process enumeration must be scoped to the installing user.")
            }
            return .init(status: 0, output: processes)
        }
        guard executable == "/bin/launchctl" else { throw ServiceError("Unexpected command \(executable)") }
        if arguments == failOnce { failOnce = nil; return .init(status: 5, output: "injected failure") }
        switch arguments[0] {
        case "managername": return .init(status: 0, output: managerName + "\n")
        case "manageruid": return .init(status: 0, output: managerUserID + "\n")
        case "getenv": return .init(status: 0, output: settings[arguments[1]].map { $0 + "\n" } ?? "")
        case "setenv":
            launchctlMutations.append(arguments)
            settings[arguments[1]] = arguments[2]
        case "unsetenv":
            launchctlMutations.append(arguments)
            settings[arguments[1]] = nil
        case "print":
            if arguments[1].split(separator: "/").count == 3 {
                return .init(status: loaded ? 0 : 113, output: "")
            }
        case "bootstrap":
            launchctlMutations.append(arguments)
            guard !loaded else { throw ServiceError("Job already loaded") }
            loaded = true
        case "bootout":
            launchctlMutations.append(arguments)
            guard loaded else { throw ServiceError("Job not loaded") }
            loaded = false
        default: throw ServiceError("Unexpected launchctl arguments \(arguments)")
        }
        return .init(status: 0, output: "")
    }
}
