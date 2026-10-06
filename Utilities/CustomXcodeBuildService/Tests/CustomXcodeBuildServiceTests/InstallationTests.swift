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

import Darwin
import Foundation
import Testing
@testable import CustomXcodeBuildService

@Test func repeatedSelectionDoesNotRequestAnotherClientRestart() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    #expect(try !fixture.manager.use(.custom).contains("Restart Xcode"))
    #expect(try fixture.manager.use(.bundled).contains("Restart Xcode"))
    #expect(try !fixture.manager.use(.bundled).contains("Restart Xcode"))
    #expect(try fixture.manager.use(.custom).contains("Restart Xcode"))
    #expect(try !fixture.manager.activate().contains("Restart Xcode"))
}

@Test(arguments: ["custom", "bundled", "uninstall"])
func repairingServiceEnvironmentRequestsClientRestart(command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let customSettings = fixture.runner.settings
    let output: String
    if command == "custom" {
        fixture.runner.settings = [:]
        output = try fixture.manager.use(.custom)
        #expect(fixture.runner.settings == customSettings)
    } else {
        _ = try fixture.manager.use(.bundled)
        fixture.runner.settings = customSettings
        output = try command == "bundled" ? fixture.manager.use(.bundled) : fixture.manager.uninstall()
        #expect(fixture.runner.settings.isEmpty)
    }
    #expect(output.contains("Restart Xcode"))
    #expect(output.contains("Xcode Service (for MCP)"))
}

@Test func reloadReportsPartiallyCompletedStops() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let installed = try #require(try fixture.store.packagedRelease())
    fixture.runner.processes = "20 \(installed.service.path)\n21 \(installed.service.path)\n"
    fixture.runner.killFailures = ["21"]
    do {
        _ = try fixture.manager.reload()
        Issue.record("Reload must report a failed signal.")
    } catch let error as ServiceError {
        #expect(error.description.contains("PIDs: 20"))
        #expect(error.description.contains("Stopping service 21"))
    }
    #expect(fixture.runner.killedPIDs == ["20"])
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v1.0.0")
}

@Test(arguments: ["XCBBUILDSERVICE_PATH", "SWBBUILDSERVICE_PATH", "DisableConcurrentDependencyResolution"])
func refusesForeignEnvironment(key: String) throws {
    let fixture = try Fixture()
    fixture.runner.settings[key] = "foreign-value"
    #expect(throws: ServiceError.self) { try fixture.enable( fixture.package("v1.0.0")) }
    #expect(fixture.runner.settings == [key: "foreign-value"])
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(!fixture.runner.loaded)
}

@Test func refusesExistingJobWithoutOwnedPlist() throws {
    let fixture = try Fixture()
    fixture.runner.loaded = true
    #expect(throws: ServiceError.self) { try fixture.enable( fixture.package("v1.0.0")) }
    #expect(fixture.runner.loaded)
    #expect(fixture.runner.settings.isEmpty)
}

@Test func activateRestoresCustomSelectionAfterXcodeUpdate() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    fixture.runner.settings = [:]
    fixture.runner.xcodeVersion = "Xcode 28.0\nBuild version 28A100\n"
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == fixture.store.service.path)
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
}

@Test func statusDistinguishesSelectedAndRunningServices() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let selected = try #require(try fixture.store.packagedRelease())
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService\n456 \(selected.service.path)\n789 /bin/zsh\n"
    let status = try fixture.manager.status()
    #expect(status.contains("custom release selected for future processes"))
    #expect(status.contains("PID 123: /Applications/Xcode.app"))
    #expect(status.contains("Selected service: custom"))
    #expect(status.contains("PID 456: \(selected.service.path) [managed custom service]"))
    #expect(!status.contains("PID 789"))
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.loaded)
}

@Test func statusDoesNotRequireAWriteableLockFile() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let lock = fixture.store.root.appendingPathComponent(".lock")
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lock.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }
    #expect(try fixture.manager.status().contains("Installed: v1.0.0"))
}

@Test func failedCustomSelectionRestoresLoginConfigurationBeforeRepair() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    var properties = fixture.store.agentProperties
    properties["RunAtLoad"] = false
    properties["LimitLoadToSessionType"] = "Background"
    properties["StandardOutPath"] = fixture.directory.appendingPathComponent("custom.log").path
    let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try data.write(to: fixture.store.agent)
    try fixture.manager.environment.bootout()
    try fixture.manager.environment.bootstrap(fixture.store.agent)
    let settings = fixture.runner.settings
    fixture.runner.failOnce = ["setenv", "DisableConcurrentDependencyResolution", "0"]

    #expect(throws: ServiceError.self) { try fixture.manager.use(.custom) }

    #expect(try Data(contentsOf: fixture.store.agent) == data)
    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded)
    #expect(fixture.runner.loadedAgent == properties as NSDictionary)
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.agent))
}

@Test func loginActivationDoesNotRewriteOrReloadItsOwnAgent() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let agent = try Data(contentsOf: fixture.store.agent)
    let loaded = fixture.runner.loadedAgent
    let mutations = fixture.runner.launchctlMutations.count
    fixture.runner.settings = [:]

    _ = try fixture.manager.activate()

    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.runner.loadedAgent == loaded)
    #expect(fixture.runner.launchctlMutations.dropFirst(mutations).allSatisfy { $0.first == "setenv" })
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == fixture.store.service.path)
}

@Test func uninstallPreservesUnrelatedFilesInInstallationRoot() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
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

@Test func unexpectedLaunchctlErrorsAreNotAbsence() throws {
    let fixture = try Fixture()
    fixture.runner.failOnce = ["print", fixture.manager.environment.job]
    #expect(throws: ServiceError.self) { try fixture.manager.status() }
}

@Test func missingDesktopSessionDoesNotRelaunchTheCommand() throws {
    let fixture = try Fixture()
    fixture.runner.failOnce = ["print", "gui/501"]
    #expect(throws: ServiceError.self) {
        try fixture.manager.environment.runInGUI("/tmp/custom-xcode-build-service", arguments: ["install"], currentUserID: 501)
    }
    #expect(fixture.runner.attachedCommands.isEmpty)
    #expect(fixture.runner.launchctlMutations.isEmpty)
}

@Test func unprivilegedCommandsUseTheirActualUserInsteadOfInheritedSudoMetadata() throws {
    #expect(try CustomXcodeBuildService.installationUserID(currentUserID: 501, sudoUserID: "502") == 501)
}

@Test func guiRelaunchDoesNotInstallAsRoot() throws {
    let fixture = try Fixture()
    let environment = LaunchEnvironment(runner: fixture.runner, userID: 0)
    #expect(throws: ServiceError.self) {
        try environment.runInGUI("/tmp/custom-xcode-build-service", arguments: ["install"], currentUserID: 0)
    }
    #expect(fixture.runner.attachedCommands.isEmpty)
}

@Test func attachedProcessKeepsTheCallersProcessGroup() throws {
    let script = "import os, sys; sys.exit(0 if os.getpgrp() == int(sys.argv[1]) else 1)"
    #expect(try ProcessRunner().runAttached("/usr/bin/python3", ["-c", script, String(getpgrp())]) == 0)
}

@Test func attachedProcessReportsSpawnErrors() throws {
    do {
        _ = try ProcessRunner().runAttached("/nonexistent-custom-build-service-test", [])
        Issue.record("A missing executable must fail to launch.")
    } catch let error as NSError {
        #expect(error.domain == NSPOSIXErrorDomain)
        #expect(error.code == Int(ENOENT))
    }
}

@Test func switchesServicesWithoutRemovingReleasesOrStoppingBuilds() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let installed = try #require(try fixture.store.packagedRelease())
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/MacOS/Xcode\n456 \(installed.service.path)\n"

    _ = try fixture.manager.use(.bundled)

    #expect(try fixture.store.selectedService() == .bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.agent))
    #expect(try fixture.store.packagedRelease()?.directory == installed.directory)
    #expect(FileManager.default.isExecutableFile(atPath: fixture.store.persistentExecutable.path))
    let status = try fixture.manager.status()
    #expect(status.contains("Installed: v1.0.0"))
    #expect(status.contains("Selected service: bundled"))
    #expect(status.contains("Launchd selection: bundled"))
    #expect(status.contains("PID 456: \(installed.service.path) [managed custom service]"))
    #expect(!status.contains("do not match the saved selection"))
    let mutations = fixture.runner.launchctlMutations
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.launchctlMutations == mutations)

    _ = try fixture.manager.use(.custom)
    _ = try fixture.manager.use(.custom)

    #expect(try fixture.store.selectedService() == .custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == fixture.store.service.path)
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.agent))
}

@Test func lateActivationRespectsBundledSelectionWithoutInspectingCustomPackageOrOverrides() throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    _ = try fixture.manager.use(.bundled)
    try fixture.write("{broken", to: fixture.store.current.appendingPathComponent("manifest.json"))
    fixture.runner.xcodeStatus = 1
    fixture.runner.settings = ["XCBBUILDSERVICE_PATH": "/another/service"]
    let mutations = fixture.runner.launchctlMutations

    #expect(try fixture.manager.activate().contains("no custom activation is needed"))

    #expect(fixture.runner.settings == ["XCBBUILDSERVICE_PATH": "/another/service"])
    #expect(fixture.runner.launchctlMutations == mutations)
    #expect(!fixture.runner.loaded)
}

final class Fixture {
    let directory: URL
    let runner = FakeRunner()
    var store: InstallationStore { InstallationStore(home: directory.appendingPathComponent("home"), packageDirectory: directory.appendingPathComponent("opt/custom-xcode-build-service/libexec")) }
    var manager: InstallationManager { InstallationManager(store: store, environment: LaunchEnvironment(runner: runner, userID: 501)) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CustomBuildServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("home"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func package(_ version: String, schemaVersion: Int = 2, manifestChanges: [String: Any] = [:]) throws -> URL {
        let package = directory.appendingPathComponent("Cellar/custom-xcode-build-service/\(UUID().uuidString)/libexec")
        var manifest: [String: Any] = [
            "schemaVersion": schemaVersion, "version": version, "sourceRevision": String(repeating: "a", count: 40),
            "xcodeVersion": "27.0", "xcodeBuildVersion": "27A5252f", "architecture": "arm64", "minimumMacOSVersion": "26.0",
            "resourceBundles": ["SwiftBuild_SWBCore.bundle"],
            "dependencies": [["identity": "swift-tools-support-core", "revision": String(repeating: "b", count: 40)]],
        ]
        manifest.merge(manifestChanges, uniquingKeysWith: { _, new in new })
        try write("placeholder", to: package.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"))
        let resources = schemaVersion == 1 ? "libexec/swift-build" : "libexec/swift-build/SWBBuildService.bundle"
        var executables = ["bin/custom-xcode-build-service", ReleasePackage.servicePath(schemaVersion: schemaVersion)]
        if schemaVersion == 2 {
            executables.append("\(resources)/PlugIns/HostPlatformPlugins.bundle/Contents/MacOS/HostPlatformPlugins")
            for (contents, executable) in [(resources, "SWBBuildServiceBundle"), ("\(resources)/PlugIns/HostPlatformPlugins.bundle/Contents", "HostPlatformPlugins")] {
                let plist = package.appendingPathComponent("\(contents)/Info.plist")
                try write("", to: plist)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable, "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: plist)
            }
        }
        if schemaVersion == 2 {
            try write("signature", to: package.appendingPathComponent("\(resources)/_CodeSignature/CodeResources"))
        }
        for path in executables {
            let executable = package.appendingPathComponent(path)
            try write("#!/bin/sh\nexit 0\n", to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try write("specification", to: package.appendingPathComponent("\(resources)/SwiftBuild_SWBCore.bundle/spec.txt"))
        try write("Apache", to: package.appendingPathComponent("licenses/LICENSE.txt"))
        return package
    }

    func link(_ package: URL) throws {
        let opt = store.packageDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: opt.deletingLastPathComponent(), withIntermediateDirectories: true)
        if try store.exists(opt) { try FileManager.default.removeItem(at: opt) }
        try FileManager.default.createSymbolicLink(at: opt, withDestinationURL: package.deletingLastPathComponent())
    }

    @discardableResult
    func enable(_ package: URL) throws -> String {
        try link(package)
        return try manager.use(.custom)
    }

    func standaloneInstallation(relativeCommandLink: Bool = false) throws -> URL {
        let source = try package("custom-v0.2.6")
        try store.initializeRoot()
        let legacy = store.versions.appendingPathComponent("custom-v0.2.6")
        try FileManager.default.createDirectory(at: store.versions, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: legacy)
        try FileManager.default.createSymbolicLink(at: store.current, withDestinationURL: legacy)
        let command = store.current.appendingPathComponent("bin/custom-xcode-build-service")
        try FileManager.default.createDirectory(at: store.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = relativeCommandLink
            ? "../../Library/Developer/CustomXcodeBuildService/current/bin/custom-xcode-build-service"
            : command.path
        try FileManager.default.createSymbolicLink(atPath: store.command.path, withDestinationPath: destination)
        var properties = store.agentProperties
        properties["ProgramArguments"] = [command.path, "activate"]
        try FileManager.default.createDirectory(at: store.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: store.agent)
        runner.loaded = true
        runner.loadedAgent = properties as NSDictionary
        runner.settings = ["XCBBUILDSERVICE_PATH": try ReleasePackage(directory: legacy).service.path, "DisableConcurrentDependencyResolution": "0"]
        return legacy
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

final class FakeRunner: ProcessRunning {
    var settings: [String: String] = [:]
    var loaded = false
    var loadedAgent: NSDictionary?
    var xcodeVersion = "Xcode 27.0\nBuild version 27A5252f\n"
    var xcodeStatus: Int32 = 0
    var processes = ""
    var processStatus: Int32 = 0
    var killedPIDs: [String] = []
    var killFailures: Set<String> = []
    var failOnce: [String]?
    var managerName = "Aqua"
    var managerUserID = "501"
    var launchctlMutations: [[String]] = []
    var attachedCommands: [[String]] = []
    var attachedStatus: Int32 = 0

    func runAttached(_ executable: String, _ arguments: [String]) throws -> Int32 {
        attachedCommands.append([executable] + arguments)
        return attachedStatus
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        if executable == "/usr/bin/xcodebuild" { return .init(status: xcodeStatus, output: xcodeVersion) }
        if executable == "/bin/ps" {
            guard arguments == ["-U", "501", "-x", "-ww", "-o", "pid=,comm="] else {
                throw ServiceError("Process enumeration must be scoped to the installing user.")
            }
            return .init(status: processStatus, output: processes)
        }
        if executable == "/bin/kill" {
            guard arguments.count == 2, arguments[0] == "-TERM" else { throw ServiceError("Unexpected signal") }
            if killFailures.contains(arguments[1]) { return .init(status: 1, output: "injected signal failure") }
            killedPIDs.append(arguments[1])
            processes = processes.split(separator: "\n").filter { $0.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) != arguments[1] }.joined(separator: "\n")
            return .init(status: 0, output: "")
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
            loadedAgent = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[2])), format: nil) as? NSDictionary
            loaded = true
        case "bootout":
            launchctlMutations.append(arguments)
            guard loaded else { throw ServiceError("Job not loaded") }
            loaded = false
            loadedAgent = nil
        default: throw ServiceError("Unexpected launchctl arguments \(arguments)")
        }
        return .init(status: 0, output: "")
    }
}

@Test func homebrewInstallationIsVisibleBeforeSelectingCustom() throws {
    let fixture = try Fixture()
    try fixture.link(fixture.package("v0.3.0"))
    let report = try fixture.manager.status()
    #expect(report.contains("Installed: v0.3.0"))
    #expect(report.contains("Selected service: bundled"))
    #expect(try !fixture.store.exists(fixture.store.root))
    #expect(fixture.runner.launchctlMutations.isEmpty)
}

@Test func selectionUsesExternalPayloadWithoutCreatingAnotherInstallation() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v0.3.0")
    _ = try fixture.enable(package)
    #expect(try !fixture.store.exists(fixture.store.current))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try !fixture.store.exists(fixture.store.staging))
    #expect(try fixture.store.service.resolvingSymlinksInPath() == ReleasePackage(directory: package).service)
    let agent = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.store.agent), format: nil) as? [String: Any])
    #expect(agent["ProgramArguments"] as? [String] == [fixture.store.persistentExecutable.path, "activate"])
    _ = try fixture.manager.uninstall()
    #expect(try fixture.store.exists(package.appendingPathComponent("manifest.json")))
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v0.3.0")
    #expect(fixture.runner.settings.isEmpty)
}

@Test(arguments: [BuildService.custom, .bundled])
func homebrewUpgradePreservesSelectionAndReloadRecognizesTheOldCellar(selected: BuildService) throws {
    let fixture = try Fixture()
    let old = try fixture.package("v0.3.0")
    _ = try fixture.enable(old)
    _ = try fixture.manager.use(selected)
    let settings = fixture.runner.settings
    let oldExecutable = try ReleasePackage(directory: old).service
    fixture.runner.processes = "20 \(oldExecutable.path)\n30 /other/SWBBuildServiceBundle\n"
    let new = try fixture.package("v0.3.1")
    try fixture.link(new)
    #expect(try fixture.store.selectedService() == selected)
    #expect(fixture.runner.settings == settings)
    _ = try fixture.manager.reload()
    #expect(fixture.runner.killedPIDs == (selected == .custom ? ["20"] : []))
    try FileManager.default.removeItem(at: old.deletingLastPathComponent())
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v0.3.1")
    #expect(try fixture.store.service.resolvingSymlinksInPath() == ReleasePackage(directory: new).service)
}

@Test(arguments: [false, true])
func setupMigratesStandaloneSelectionAndCommand(relativeCommandLink: Bool) throws {
    let fixture = try Fixture()
    let legacy = try fixture.standaloneInstallation(relativeCommandLink: relativeCommandLink)
    fixture.runner.processes = "20 \(try ReleasePackage(directory: legacy).service.path)\n"
    let package = try fixture.package("v0.3.3")

    let output = try fixture.enable(package)

    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try fixture.store.exists(legacy))
    #expect(try fixture.store.selectedPackage()?.manifest.version == "v0.3.3")
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == fixture.store.service.path)
    #expect(fixture.runner.loaded)
    #expect(fixture.runner.killedPIDs.isEmpty)
    #expect(output.contains("Restart Xcode"))
    #expect(try !fixture.manager.use(.custom).contains("Restart Xcode"))
}

@Test(arguments: [false, true])
func setupPreservesUnrelatedCommand(symbolicLink: Bool) throws {
    let fixture = try Fixture()
    let target = fixture.directory.appendingPathComponent("other-command")
    if symbolicLink {
        try fixture.write("unrelated", to: target)
        try FileManager.default.createDirectory(at: fixture.store.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.store.command, withDestinationURL: target)
    } else {
        try fixture.write("unrelated", to: fixture.store.command)
    }

    _ = try fixture.enable(fixture.package("v0.3.3"))

    #expect(try String(contentsOf: fixture.store.command, encoding: .utf8) == "unrelated")
    if symbolicLink {
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == target.path)
    }
    #expect(try fixture.store.selectedPackage()?.manifest.version == "v0.3.3")
}

@Test func failedLegacyCommandRemovalRestoresStandaloneSelection() throws {
    let fixture = try Fixture()
    let legacy = try fixture.standaloneInstallation()
    let settings = fixture.runner.settings
    let agent = try Data(contentsOf: fixture.store.agent)
    let commandTarget = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path)
    let directory = fixture.store.command.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
    try fixture.link(fixture.package("v0.3.3"))

    #expect(throws: (any Error).self) { try fixture.manager.use(.custom) }

    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded)
    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == commandTarget)
    #expect(try fixture.store.exists(legacy))
    #expect(try !fixture.store.exists(fixture.store.serviceBundle))
}

@Test func legacyCleanupUsesTheNewCLIWithoutDeletingHomebrewFiles() throws {
    let fixture = try Fixture()
    let old = try fixture.package("custom-v0.2.6")
    try fixture.store.initializeRoot()
    try FileManager.default.copyItem(at: old, to: fixture.store.current)
    let oldCommand = fixture.store.current.appendingPathComponent("bin/custom-xcode-build-service")
    try FileManager.default.createDirectory(at: fixture.store.command.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.store.command, withDestinationURL: oldCommand)
    var properties = fixture.store.agentProperties
    properties["ProgramArguments"] = [oldCommand.path, "activate"]
    try FileManager.default.createDirectory(at: fixture.store.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: fixture.store.agent)
    fixture.runner.loaded = true
    fixture.runner.settings = ["XCBBUILDSERVICE_PATH": fixture.store.service.path, "DisableConcurrentDependencyResolution": "0"]
    let new = try fixture.package("v0.3.0")
    try fixture.link(new)
    _ = try fixture.manager.uninstall()
    #expect(try !fixture.store.exists(fixture.store.current))
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try fixture.store.exists(new))
    #expect(fixture.runner.settings.isEmpty)
    _ = try fixture.manager.use(.custom)
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v0.3.0")
}

@Test func bundledRecoveryDoesNotRequireAnIntactHomebrewPackage() throws {
    let fixture = try Fixture()
    let package = try fixture.package("v0.3.0")
    _ = try fixture.enable(package)
    try FileManager.default.removeItem(at: package)
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
}

@Test func parserUsesHomebrewForInstallation() throws {
    #expect(try Command(arguments: ["--version"]) == .version)
    #expect(try Command(arguments: ["uninstall"]) == .uninstall)
    for arguments in [["install"], ["install", "--package", "/tmp/package"], ["use"], ["use", "other"], ["status", "extra"]] {
        #expect(throws: ServiceError.self) { try Command(arguments: arguments) }
    }
}

@Test(arguments: ["manifest", "service", "resources", "agent", "manifest-and-agent"])
func statusReportsLiveSettingsWhenInstalledStateIsDamaged(damage: String) throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let installed = try #require(try fixture.store.packagedRelease())
    fixture.runner.processes = "123 \(installed.service.path)\n"
    let settings = fixture.runner.settings
    let mutations = fixture.runner.launchctlMutations
    if damage.contains("manifest") {
        try fixture.write("{broken", to: installed.directory.appendingPathComponent("manifest.json"))
    }
    if damage.contains("agent") {
        try fixture.write("invalid plist", to: fixture.store.agent)
    }
    if damage == "service" { try FileManager.default.removeItem(at: installed.service) }
    if damage == "resources" {
        try FileManager.default.removeItem(at: installed.resources.appendingPathComponent("SwiftBuild_SWBCore.bundle"))
    }

    do {
        _ = try fixture.manager.status()
        Issue.record("Incomplete status must retain a failing result.")
    } catch let error as ServiceError {
        let report = error.description
        #expect(report.contains("XCBBUILDSERVICE_PATH: \(fixture.store.service.path)"))
        #expect(report.contains("DisableConcurrentDependencyResolution: 0"))
        #expect(report.contains("Login job: loaded"))
        #expect(report.contains("PID 123: \(installed.service.path)"))
        #expect(!report.contains("Installed: none"))
        #expect(!report.contains("Run use custom to reapply it"))
        if damage != "agent" {
            #expect(report.contains(damage.contains("manifest") ? "Installed: unavailable" : "Installed: v1.0.0"))
            #expect(report.contains("Installation error:"))
        }
        if damage.contains("agent") {
            #expect(report.contains("Selected service: unavailable"))
            #expect(report.contains("Selection error:"))
        } else {
            #expect(report.contains("Selected service: custom"))
        }
    }
    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.launchctlMutations == mutations)
}


@Test(arguments: ["background", "domain", "environment", "login-job", "processes", "ownership", "lock"])
func statusPreservesOtherObservationsWhenOneSourceFails(failure: String) throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let installed = try #require(try fixture.store.packagedRelease())
    fixture.runner.processes = "123 \(installed.service.path)\n"
    let mutations = fixture.runner.launchctlMutations
    switch failure {
    case "background": fixture.runner.managerName = "Background"
    case "domain": fixture.runner.failOnce = ["print", "gui/501"]
    case "environment": fixture.runner.failOnce = ["getenv", "XCBBUILDSERVICE_PATH"]
    case "login-job": fixture.runner.failOnce = ["print", fixture.manager.environment.job]
    case "processes": fixture.runner.processStatus = 5
    case "ownership": try fixture.write("unrecognized", to: fixture.store.root.appendingPathComponent(".owner"))
    default: try FileManager.default.removeItem(at: fixture.store.root.appendingPathComponent(".lock"))
    }
    do {
        _ = try fixture.manager.status()
        Issue.record("Incomplete status must retain a failing result.")
    } catch let error as ServiceError {
        let report = error.description
        #expect(report.contains(["ownership", "lock"].contains(failure) ? "Selected service: unavailable" : "Selected service: custom"))
        #expect(report.contains("Installed: v1.0.0"))
        #expect(report.contains(failure == "processes" ? "Running build services: unavailable" : "PID 123:"))
        #expect(report.contains(failure == "login-job" ? "Login job: unavailable" : "Login job: loaded"))
        if ["background", "domain", "environment"].contains(failure) {
            #expect(report.contains("Launchd selection: unavailable"))
        } else {
            #expect(report.contains("XCBBUILDSERVICE_PATH: \(fixture.store.service.path)"))
        }
    }
    #expect(fixture.runner.launchctlMutations == mutations)
}


@Test(arguments: ["activate", "use custom", "use bundled"])
func serviceSelectionDoesNotDependOnCleaningInterruptedStaging(command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.enable( fixture.package("v1.0.0"))
    let pending = fixture.store.staging.appendingPathComponent("pending")
    try fixture.write("pending bytes", to: pending)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.store.staging.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.store.staging.path) }
    switch command {
    case "activate": _ = try fixture.manager.activate()
    case "use custom": _ = try fixture.manager.use(.custom)
    default: _ = try fixture.manager.use(.bundled)
    }
    #expect(try fixture.store.selectedService() == (command == "use bundled" ? .bundled : .custom))
    #expect(try String(contentsOf: pending, encoding: .utf8) == "pending bytes")
}


@Test func unusedActivationAndAbsentUninstallDoNotRequireAGUISession() throws {
    let fixture = try Fixture()
    fixture.runner.managerName = "Background"
    #expect(try fixture.manager.uninstall() == "No custom build service is installed.")
    fixture.runner.managerName = "Aqua"
    _ = try fixture.enable( fixture.package("v1.0.0"))
    _ = try fixture.manager.use(.bundled)
    fixture.runner.managerName = "Background"
    let mutations = fixture.runner.launchctlMutations
    #expect(try fixture.manager.activate().contains("no custom activation is needed"))
    #expect(fixture.runner.launchctlMutations == mutations)
}


@Test(arguments: [Int32(0), 1, 130], [UInt32(0), 501])
func guiRelaunchDropsAdministratorCredentialsAndPreservesArgumentsAndExitStatus(status: Int32, currentUserID: UInt32) throws {
    let fixture = try Fixture()
    fixture.runner.managerName = "Background"
    fixture.runner.attachedStatus = status
    let executable = "/tmp/release with spaces/bin/custom-xcode-build-service"
    let arguments = ["use", "custom"]

    #expect(try fixture.manager.environment.runInGUI(executable, arguments: arguments, currentUserID: currentUserID) == status)

    let prefix = currentUserID == 0 ? [] : ["/usr/bin/sudo", "--"]
    #expect(fixture.runner.attachedCommands == [prefix + [
        "/bin/launchctl", "asuser", "501",
        "/usr/bin/sudo", "-H", "-u", "#501", "--", executable,
    ] + arguments])
    #expect(fixture.runner.launchctlMutations.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.root))
}


@Test(arguments: ["501", "502"])
func sudoInstallationTargetsTheInvokingUser(uid: String) throws {
    #expect(try CustomXcodeBuildService.installationUserID(currentUserID: 0, sudoUserID: uid) == UInt32(uid))
}


@Test(arguments: [nil, "0", "", "invalid", "-1", "4294967296"] as [String?])
func rootInstallationRequiresAnIdentifiableNonRootInvokingUser(uid: String?) {
    #expect(throws: ServiceError.self) {
        try CustomXcodeBuildService.installationUserID(currentUserID: 0, sudoUserID: uid)
    }
}


@Test(arguments: [false, true])
func attachedProcessPreservesFailureStatus(terminated: Bool) throws {
    // Swift Testing workers can block signals. The fixture explicitly terminates
    // itself so this tests exit-status handling independently of that mask.
    let script = """
    import os, signal, sys
    if sys.argv[1] == "true":
        signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGTERM])
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)
    sys.exit(7)
    """
    let status = try ProcessRunner().runAttached("/usr/bin/python3", ["-c", script, String(terminated)])
    #expect(status == (terminated ? 143 : 7))
}


@Test func selectionCanMoveBetweenOwnedHomebrewAndLocalBuilds() throws {
    let fixture = try Fixture()
    _ = try fixture.enable(fixture.package("v0.3.0"))
    let local = try fixture.package("v0.0.0-local")
    let store = InstallationStore(home: fixture.store.home, packageDirectory: local)
    let manager = InstallationManager(store: store, environment: fixture.manager.environment)
    _ = try manager.use(.custom)
    #expect(try store.service.resolvingSymlinksInPath() == ReleasePackage(directory: local).service)
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
}

@Test func foreignLoginProgramIsNotOverwritten() throws {
    let fixture = try Fixture()
    _ = try fixture.enable(fixture.package("v0.3.0"))
    var properties = fixture.store.agentProperties
    properties["ProgramArguments"] = ["/bin/sh", "activate"]
    let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try data.write(to: fixture.store.agent)
    #expect(throws: ServiceError.self) { try fixture.manager.use(.bundled) }
    #expect(try Data(contentsOf: fixture.store.agent) == data)
}

@Test(arguments: ["reload", "activate"])
func anotherCLIReappliesTheSavedPackageWithoutChangingSelection(command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.enable(fixture.package("v0.3.0"))
    let local = try fixture.package("v0.0.0-local")
    let localStore = InstallationStore(home: fixture.store.home, packageDirectory: local)
    let localManager = InstallationManager(store: localStore, environment: fixture.manager.environment)
    _ = try localManager.use(.custom)
    let agent = try Data(contentsOf: fixture.store.agent)
    let localService = try ReleasePackage(directory: local).service
    fixture.runner.processes = "20 \(localService.path)\n"
    if command == "reload" {
        _ = try fixture.manager.reload()
        #expect(fixture.runner.killedPIDs == ["20"])
    } else {
        fixture.runner.settings = [:]
        _ = try fixture.manager.activate()
        #expect(fixture.runner.killedPIDs.isEmpty)
    }
    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.store.service.resolvingSymlinksInPath() == localService)
    #expect(try fixture.store.selectedPackage()?.manifest.version == "v0.0.0-local")
    let status = try fixture.manager.status()
    #expect(status.contains("Installed: v0.3.0"))
    #expect(status.contains("Selected custom package: v0.0.0-local"))
}

@Test func localCLIReloadsAnUpgradedHomebrewSelectionAfterOldKegCleanup() throws {
    let fixture = try Fixture()
    let old = try fixture.package("v0.3.0")
    _ = try fixture.enable(old)
    let oldService = try ReleasePackage(directory: old).service
    try fixture.link(fixture.package("v0.3.1"))
    try FileManager.default.removeItem(at: old.deletingLastPathComponent())
    let local = fixture.directory.appendingPathComponent("local-build/payload")
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.package("v0.0.0-local"), to: local)
    let store = InstallationStore(home: fixture.store.home, packageDirectory: local)
    let manager = InstallationManager(store: store, environment: fixture.manager.environment)
    fixture.runner.processes = "20 \(oldService.path)\n30 /other/Cellar/custom-xcode-build-service/0.3.0/libexec/libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle\n"
    let agent = try Data(contentsOf: store.agent)
    _ = try manager.reload()
    #expect(fixture.runner.killedPIDs == ["20"])
    #expect(try Data(contentsOf: store.agent) == agent)
    #expect(try store.selectedPackage()?.manifest.version == "v0.3.1")
}

@Test(arguments: [false, true])
func installerMigratesStandaloneAndPreservesExistingCommandPath(relativeCommandLink: Bool) throws {
    let fixture = try Fixture()
    let legacy = try fixture.standaloneInstallation(relativeCommandLink: relativeCommandLink)
    fixture.runner.processes = "20 \(try ReleasePackage(directory: legacy).service.path)\n"
    try fixture.link(fixture.package("v0.4.0"))

    #expect(try fixture.manager.migrateStandalone().contains("Selected service: custom"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == fixture.store.homebrewCommand.path)
    #expect(try fixture.store.selectedPackage()?.manifest.version == "v0.4.0")
    #expect(try fixture.store.exists(legacy))
    #expect(fixture.runner.killedPIDs.isEmpty)
    #expect(try fixture.manager.migrateStandalone().contains("No standalone migration needed"))
    fixture.runner.processes = ""
    _ = try fixture.manager.uninstall()
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v0.4.0")
}

@Test func installerPreservesBundledSelectionWhileMigratingTheCommand() throws {
    let fixture = try Fixture()
    let legacy = try fixture.standaloneInstallation()
    _ = try fixture.manager.use(.bundled)
    try fixture.link(fixture.package("v0.4.0"))
    fixture.runner.failOnce = ["managername"]

    _ = try fixture.manager.migrateStandalone()
    #expect(try fixture.store.selectedService() == .bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try fixture.store.exists(legacy))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == fixture.store.homebrewCommand.path)
}

@Test func installerPreservesLocalCustomSelection() throws {
    let fixture = try Fixture()
    let local = try fixture.package("v0.0.0-local")
    let localStore = InstallationStore(home: fixture.store.home, packageDirectory: local)
    let localManager = InstallationManager(store: localStore, environment: fixture.manager.environment)
    _ = try localManager.use(.custom)
    try fixture.link(fixture.package("v0.4.0"))
    let agent = try Data(contentsOf: fixture.store.agent)
    let settings = fixture.runner.settings
    _ = try fixture.manager.migrateStandalone()
    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.runner.settings == settings)
    #expect(try !fixture.store.exists(fixture.store.command))
}

@Test func installerWithoutStandaloneDoesNotCreateUserSettings() throws {
    let fixture = try Fixture()
    try fixture.link(fixture.package("v0.4.0"))
    _ = try fixture.manager.migrateStandalone()
    #expect(try !fixture.store.exists(fixture.store.root))
    #expect(fixture.runner.settings.isEmpty)
}

@Test func failedInstallerMigrationRestoresStandaloneSelectionAndCommand() throws {
    let fixture = try Fixture()
    _ = try fixture.standaloneInstallation()
    try fixture.link(fixture.package("v0.4.0"))
    let agent = try Data(contentsOf: fixture.store.agent)
    let settings = fixture.runner.settings
    let command = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path)
    fixture.runner.failOnce = ["setenv", "DisableConcurrentDependencyResolution", "0"]
    #expect(throws: ServiceError.self) { try fixture.manager.migrateStandalone() }
    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.runner.settings == settings)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == command)
}

@Test(arguments: ["manifest", "payload", "current"])
func installerRecoversDamagedStandaloneInstallation(damage: String) throws {
    let fixture = try Fixture()
    let legacy = try fixture.standaloneInstallation()
    let missing = damage == "manifest" ? legacy.appendingPathComponent("manifest.json")
        : damage == "payload" ? legacy : fixture.store.current
    try FileManager.default.removeItem(at: missing)
    try fixture.link(fixture.package("v0.4.0"))
    _ = try fixture.manager.migrateStandalone()
    #expect(try fixture.store.selectedPackage()?.manifest.version == "v0.4.0")
}

@Test func localCLIUninstallRecognizesMigratedHomebrewCommand() throws {
    let fixture = try Fixture()
    _ = try fixture.standaloneInstallation()
    try fixture.link(fixture.package("v0.4.0"))
    _ = try fixture.manager.migrateStandalone()
    let localStore = InstallationStore(home: fixture.store.home, packageDirectory: try fixture.package("v0.0.0-local"))
    let localManager = InstallationManager(store: localStore, environment: fixture.manager.environment)
    _ = try localManager.use(.custom)
    _ = try localManager.uninstall()
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v0.4.0")
    #expect(try localStore.packagedRelease()?.manifest.version == "v0.0.0-local")
    #expect(fixture.runner.settings.isEmpty)
}

@Test(arguments: [false, true])
func selectingAnotherMiseVersionOptionallyReloadsThePreviousPackage(reload: Bool) throws {
    let fixture = try Fixture()
    func package(_ version: String) throws -> URL {
        let directory = fixture.directory.appendingPathComponent("mise/installs/github-lynnswap-swift-build/" + version)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.package(version), to: directory)
        return directory
    }
    let old = try package("v0.4.0")
    let oldStore = InstallationStore(home: fixture.store.home, packageDirectory: old)
    let oldManager = InstallationManager(store: oldStore, environment: fixture.manager.environment)
    _ = try oldManager.use(.custom)
    let oldService = try ReleasePackage(directory: old).service
    let unrelated = try ReleasePackage(directory: fixture.package("v0.0.0-local")).service
    fixture.runner.processes = "20 \(oldService.path)\n30 \(unrelated.path)\n"
    let new = try package("v0.4.1")
    let newStore = InstallationStore(home: fixture.store.home, packageDirectory: new)
    let manager = InstallationManager(store: newStore, environment: fixture.manager.environment)
    _ = try manager.use(.custom, reload: reload)
    #expect(try newStore.selectedPackage()?.manifest.version == "v0.4.1")
    #expect(newStore.service.resolvingSymlinksInPath() == (try ReleasePackage(directory: new).service))
    #expect(fixture.runner.killedPIDs == (reload ? ["20"] : []))
    #expect(try newStore.exists(old))
    fixture.runner.killedPIDs = []
    _ = try manager.use(.custom, reload: true)
    #expect(fixture.runner.killedPIDs.isEmpty)
}

@Test func failedSelectionDoesNotStopThePreviousService() throws {
    let fixture = try Fixture()
    let old = try fixture.package("v0.4.0")
    _ = try fixture.enable(old)
    fixture.runner.processes = "20 \(try ReleasePackage(directory: old).service.path)\n"
    fixture.runner.settings["XCBBUILDSERVICE_PATH"] = "/unrelated/service"
    let next = try fixture.package("v0.4.1")
    let store = InstallationStore(home: fixture.store.home, packageDirectory: next)
    let manager = InstallationManager(store: store, environment: fixture.manager.environment)
    #expect(throws: ServiceError.self) { try manager.use(.custom, reload: true) }
    #expect(fixture.runner.killedPIDs.isEmpty)
    #expect(try store.selectedPackage()?.manifest.version == "v0.4.0")
}

@Test func selectingWithReloadReportsTheNewSelectionWhenStoppingFails() throws {
    let fixture = try Fixture()
    let old = try fixture.package("v0.4.0")
    _ = try fixture.enable(old)
    fixture.runner.processes = "20 \(try ReleasePackage(directory: old).service.path)\n"
    fixture.runner.killFailures = ["20"]
    let next = try fixture.package("v0.4.1")
    let store = InstallationStore(home: fixture.store.home, packageDirectory: next)
    let manager = InstallationManager(store: store, environment: fixture.manager.environment)
    do {
        _ = try manager.use(.custom, reload: true)
        Issue.record("The failed termination must be reported.")
    } catch let error as ServiceError {
        #expect(error.description.contains("Selected package: v0.4.1"))
        #expect(error.description.contains("Stopping service 20"))
    }
    #expect(try store.selectedPackage()?.manifest.version == "v0.4.1")
    #expect(fixture.runner.killedPIDs.isEmpty)
}

@Test func parserSupportsExplicitReloadWhileSelectingCustom() throws {
    #expect(try Command(arguments: ["use", "custom", "--reload"]) == .use(.custom, reload: true))
    #expect(throws: ServiceError.self) { try Command(arguments: ["use", "bundled", "--reload"]) }
}
