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

@Test(arguments: [1, 2])
func installsRelocatesUpdatesAndUninstalls(schemaVersion: Int) throws {
    let fixture = try Fixture()
    let first = try fixture.package("custom-v1.0.0", schemaVersion: schemaVersion)
    _ = try fixture.manager.install(from: first)
    let selected = try #require(try fixture.store.selectedPackage())
    #expect(selected.manifest.version == "custom-v1.0.0")
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
    #expect(fixture.store.ownsService(at: selected.service.path))
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
    #expect(fixture.runner.loaded)
    #expect(FileManager.default.isExecutableFile(atPath: fixture.store.command.path))
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.store.agent), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == [fixture.store.persistentExecutable.path, "activate"])
    try FileManager.default.removeItem(at: first)
    #expect(try String(contentsOf: selected.resources.appendingPathComponent("SwiftBuild_SWBCore.bundle/spec.txt"), encoding: .utf8) == "specification")
    fixture.runner.settings = [:]
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
    _ = try fixture.manager.use(.custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)

    let second = try fixture.package("custom-v1.0.1")
    _ = try fixture.manager.install(from: second)
    let updated = try #require(try fixture.store.selectedPackage())
    #expect(updated.manifest.version == "custom-v1.0.1")
    #expect(updated.manifest.schemaVersion == 2)
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

@Test(arguments: [1, 2])
func installationFailureRestoresPreviousSelectionAndEnvironment(schemaVersion: Int) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0", schemaVersion: schemaVersion))
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

@Test(arguments: ["status", "activate", "use", "reinstall", "update"])
func installedReleaseRemainsUsableAfterBuilds(command: String) throws {
    let fixture = try Fixture()
    let package = try fixture.package("custom-v1.0.0")
    _ = try fixture.manager.install(from: package)
    let previous = try #require(try fixture.store.selectedPackage())
    for path in [
        "libexec/swift-build/WidgetPreviewExtension.dependency-scan.dia",
        "libexec/swift-build/SWBBuildService.bundle/SwiftBuild_SWBCore.bundle/.DS_Store",
    ] {
        try fixture.write("generated", to: previous.directory.appendingPathComponent(path))
    }

    switch command {
    case "status":
        #expect(try fixture.manager.status().contains("Installed: custom-v1.0.0"))
    case "activate":
        fixture.runner.settings = [:]
        _ = try fixture.manager.activate()
    case "use":
        _ = try fixture.manager.use(.bundled)
        _ = try fixture.manager.use(.custom)
    case "reinstall":
        _ = try fixture.manager.install(from: package)
    default:
        _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    }

    let selected = try #require(try fixture.store.selectedPackage())
    #expect(selected.manifest.version == (command == "update" ? "custom-v1.0.1" : "custom-v1.0.0"))
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(previous.directory))
}

@Test(arguments: [
    "generated-file", "malformed-manifest", "", "manifest.json",
    "bin/custom-xcode-build-service", "libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle",
    "libexec/swift-build/SWBBuildService.bundle/SwiftBuild_SWBCore.bundle",
], [false, true])
func updateCanReplaceOrRestoreChangedPreviousRelease(change: String, failUpdate: Bool) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v0.1.1"))
    let previous = try #require(try fixture.store.selectedDirectory())
    let selection = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.current.path)
    let settings = fixture.runner.settings
    switch change {
    case "generated-file":
        try fixture.write("diagnostics", to: previous.appendingPathComponent("libexec/swift-build/WidgetPreviewExtension.dependency-scan.dia"))
    case "malformed-manifest":
        try fixture.write("{broken", to: previous.appendingPathComponent("manifest.json"))
    default:
        try FileManager.default.removeItem(at: previous.appendingPathComponent(change))
    }
    let update = try fixture.package("custom-v0.1.2")

    if failUpdate {
        fixture.runner.failOnce = ["bootstrap", fixture.manager.environment.domain, fixture.store.agent.path]
        #expect(throws: ServiceError.self) { try fixture.manager.install(from: update) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.current.path) == selection)
        #expect(fixture.runner.settings == settings)
    } else {
        _ = try fixture.manager.install(from: update)
        let selected = try #require(try fixture.store.selectedPackage())
        #expect(selected.manifest.version == "custom-v0.1.2")
        #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == selected.service.path)
    }
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.command))
    #expect(try fixture.store.exists(fixture.store.agent))
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

@Test func failedCommandRemovalRestoresCustomizedLoginConfiguration() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    var properties = fixture.store.agentProperties
    properties["StandardOutPath"] = fixture.directory.appendingPathComponent("custom.log").path
    let agent = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try agent.write(to: fixture.store.agent)
    let settings = fixture.runner.settings
    let commandDirectory = fixture.store.command.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: commandDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandDirectory.path) }

    #expect(throws: (any Error).self) { try fixture.manager.uninstall() }

    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded)
    #expect(try fixture.manager.status().contains("Selected service: custom"))
    #expect(try fixture.store.exists(fixture.store.command))
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
    try fixture.write("changed", to: ReleasePackage(directory: package).resources.appendingPathComponent("SwiftBuild_SWBCore.bundle/spec.txt"))
    #expect(throws: ServiceError.self) { try fixture.manager.install(from: package) }
    #expect(fixture.runner.loaded)
    let selected = try #require(try fixture.store.selectedPackage())
    #expect(try String(contentsOf: selected.resources.appendingPathComponent("SwiftBuild_SWBCore.bundle/spec.txt"), encoding: .utf8) == "specification")
}

@Test func installsWithDifferentXcodeBuild() throws {
    let fixture = try Fixture()
    fixture.runner.xcodeVersion = "Xcode 27.0\nBuild version 27A266a\n"
    let result = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let installed = try #require(try fixture.store.selectedPackage())
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == installed.service.path)
    #expect(try fixture.store.selectedService() == .custom)
    #expect(fixture.runner.loaded)
    #expect(result.contains("Built with Xcode: 27.0 (27A5252f)"))
    #expect(try fixture.manager.status().contains("Built with Xcode: 27.0 (27A5252f)"))
}

@Test func activateRestoresCustomSelectionAfterXcodeUpdate() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    fixture.runner.settings = [:]
    fixture.runner.xcodeVersion = "Xcode 28.0\nBuild version 28A100\n"
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
}

@Test func installationAndSelectionWorkWithoutSelectedXcode() throws {
    let fixture = try Fixture()
    fixture.runner.xcodeStatus = 1
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    _ = try fixture.manager.use(.bundled)
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    #expect(try fixture.store.selectedService() == .bundled)
    _ = try fixture.manager.use(.custom)
    fixture.runner.settings = [:]
    _ = try fixture.manager.activate()
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
    #expect(try fixture.store.selectedService() == .custom)
    #expect(fixture.runner.loaded)
}

@Test func statusDistinguishesSelectedAndRunningServices() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let selected = try #require(try fixture.store.selectedPackage())
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService\n456 \(selected.service.path)\n789 /bin/zsh\n"
    let status = try fixture.manager.status()
    #expect(status.contains("custom release selected for future processes"))
    #expect(status.contains("PID 123: /Applications/Xcode.app"))
    #expect(status.contains("Selected service: custom"))
    #expect(status.contains("PID 456: \(selected.service.path) [installed custom release]"))
    #expect(!status.contains("PID 789"))
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(fixture.runner.loaded)
}

@Test(arguments: ["manifest", "service", "resources", "agent", "manifest-and-agent"])
func statusReportsLiveSettingsWhenInstalledStateIsDamaged(damage: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let installed = try #require(try fixture.store.selectedPackage())
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
        #expect(report.contains("XCBBUILDSERVICE_PATH: \(installed.service.path)"))
        #expect(report.contains("DisableConcurrentDependencyResolution: 0"))
        #expect(report.contains("Login job: loaded"))
        #expect(report.contains("PID 123: \(installed.service.path)"))
        #expect(!report.contains("Installed: none"))
        #expect(!report.contains("Run use custom to reapply it"))
        if damage != "agent" {
            #expect(report.contains(damage.contains("manifest") ? "Installed: unavailable" : "Installed: custom-v1.0.0"))
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
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let installed = try #require(try fixture.store.selectedPackage())
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
        #expect(report.contains("Selected service: custom"))
        #expect(report.contains(["ownership", "lock"].contains(failure) ? "Installed: unavailable" : "Installed: custom-v1.0.0"))
        #expect(report.contains(failure == "processes" ? "Running build services: unavailable" : "PID 123:"))
        #expect(report.contains(failure == "login-job" ? "Login job: unavailable" : "Login job: loaded"))
        if ["background", "domain", "environment"].contains(failure) {
            #expect(report.contains("Launchd selection: unavailable"))
        } else {
            #expect(report.contains("XCBBUILDSERVICE_PATH: \(installed.service.path)"))
        }
    }
    #expect(fixture.runner.launchctlMutations == mutations)
}

@Test func statusDoesNotRequireAWriteableLockFile() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let lock = fixture.store.root.appendingPathComponent(".lock")
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lock.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }
    #expect(try fixture.manager.status().contains("Installed: custom-v1.0.0"))
}

@Test(arguments: ["activate", "use custom", "use bundled"])
func serviceSelectionDoesNotDependOnCleaningInterruptedStaging(command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
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
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    _ = try fixture.manager.use(.bundled)
    fixture.runner.managerName = "Background"
    let mutations = fixture.runner.launchctlMutations
    #expect(try fixture.manager.activate().contains("no custom activation is needed"))
    #expect(fixture.runner.launchctlMutations == mutations)
}

@Test(arguments: ["relative-link", "foreign-link", "foreign-file"])
func selectingServicesDoesNotRequireOrModifyTheCommandLink(command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    try FileManager.default.removeItem(at: fixture.store.command)
    let foreign = fixture.directory.appendingPathComponent("another-command")
    try fixture.write("preserve", to: foreign)
    let destination = command == "relative-link"
        ? "../../Library/Developer/CustomXcodeBuildService/current/bin/custom-xcode-build-service"
        : foreign.path
    if command == "foreign-file" {
        try fixture.write("preserve", to: fixture.store.command)
    } else {
        try FileManager.default.createSymbolicLink(atPath: fixture.store.command.path, withDestinationPath: destination)
    }

    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
    _ = try fixture.manager.use(.custom)
    fixture.runner.settings = [:]
    _ = try fixture.manager.activate()
    #expect(try fixture.manager.status().contains("Selected service: custom"))
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
    if command == "foreign-file" {
        #expect(try String(contentsOf: fixture.store.command, encoding: .utf8) == "preserve")
    } else {
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == destination)
    }
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "preserve")
}

@Test func relativeCommandLinkSupportsUpdatingAndUninstalling() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    try FileManager.default.removeItem(at: fixture.store.command)
    let destination = "../../Library/Developer/CustomXcodeBuildService/current/bin/custom-xcode-build-service"
    try FileManager.default.createSymbolicLink(atPath: fixture.store.command.path, withDestinationPath: destination)

    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    #expect(try fixture.store.selectedPackage()?.manifest.version == "custom-v1.0.1")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == destination)
    _ = try fixture.manager.uninstall()
    #expect(try !fixture.store.exists(fixture.store.command))
    #expect(fixture.runner.settings.isEmpty)
}

@Test(arguments: [false, true])
func commandOwnershipUsesThePhysicalContainingDirectory(owned: Bool) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let physical = fixture.directory.appendingPathComponent("redirected/bin")
    try FileManager.default.createDirectory(at: physical.deletingLastPathComponent(), withIntermediateDirectories: true)
    let logical = fixture.store.command.deletingLastPathComponent()
    try FileManager.default.moveItem(at: logical, to: physical)
    try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: physical)
    try FileManager.default.removeItem(at: fixture.store.command)
    let destination = (owned ? "../../home/" : "../../")
        + "Library/Developer/CustomXcodeBuildService/current/bin/custom-xcode-build-service"
    try FileManager.default.createSymbolicLink(atPath: fixture.store.command.path, withDestinationPath: destination)
    let foreign = fixture.directory.appendingPathComponent("Library/Developer/CustomXcodeBuildService/current/bin/custom-xcode-build-service")
    try fixture.write("preserve foreign command", to: foreign)
    let update = try fixture.package("custom-v1.0.1")

    if owned {
        _ = try fixture.manager.install(from: update)
        #expect(try fixture.store.selectedPackage()?.manifest.version == "custom-v1.0.1")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == destination)
        _ = try fixture.manager.uninstall()
        #expect(try !fixture.store.exists(fixture.store.command))
    } else {
        #expect(try String(contentsOf: fixture.store.command, encoding: .utf8) == "preserve foreign command")
        let settings = fixture.runner.settings
        let mutations = fixture.runner.launchctlMutations
        #expect(throws: ServiceError.self) { try fixture.manager.install(from: update) }
        #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.store.command.path) == destination)
        #expect(fixture.runner.settings == settings)
        #expect(fixture.runner.launchctlMutations == mutations)
        _ = try fixture.manager.use(.bundled)
        #expect(fixture.runner.settings.isEmpty)
    }
    #expect(try String(contentsOf: foreign, encoding: .utf8) == "preserve foreign command")
}

@Test func customizedLoginLoggingDoesNotBlockServiceManagement() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    var properties = fixture.store.agentProperties
    let log = fixture.directory.appendingPathComponent("custom-activation.log")
    properties["StandardOutPath"] = log.path
    properties["StandardErrorPath"] = log.path
    properties["Program"] = fixture.store.persistentExecutable.path
    let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try data.write(to: fixture.store.agent)
    try fixture.write("preserve log", to: log)

    #expect(try fixture.manager.status().contains("Selected service: custom"))
    fixture.runner.settings = [:]
    _ = try fixture.manager.activate()
    _ = try fixture.manager.use(.custom)
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    properties["Program"] = nil
    let saved = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.store.agent), format: nil) as? NSDictionary)
    #expect(saved == properties as NSDictionary)
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.agent))
    _ = try fixture.manager.use(.custom)
    try data.write(to: fixture.store.agent)
    _ = try fixture.manager.uninstall()
    #expect(try !fixture.store.exists(fixture.store.agent))
    #expect(try String(contentsOf: log, encoding: .utf8) == "preserve log")
}

@Test(arguments: ["missing-run-at-load", "disabled-run-at-load", "missing-session", "background-session", "keep-alive", "interval"], ["use", "update"])
func applyingCustomRestoresLoginActivationAndPreservesLogging(change: String, command: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    var properties = fixture.store.agentProperties
    let log = fixture.directory.appendingPathComponent("custom.log").path
    properties["StandardOutPath"] = log
    switch change {
    case "missing-run-at-load": properties["RunAtLoad"] = nil
    case "disabled-run-at-load": properties["RunAtLoad"] = false
    case "missing-session": properties["LimitLoadToSessionType"] = nil
    case "background-session": properties["LimitLoadToSessionType"] = "Background"
    case "keep-alive": properties["KeepAlive"] = true
    default: properties["StartInterval"] = 10
    }
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: fixture.store.agent)
    try fixture.manager.environment.bootout()
    try fixture.manager.environment.bootstrap(fixture.store.agent)
    #expect(fixture.runner.loadedAgent == properties as NSDictionary)

    switch command {
    case "use": _ = try fixture.manager.use(.custom)
    default: _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    }

    let saved = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.store.agent), format: nil) as? [String: Any])
    #expect(saved["RunAtLoad"] as? Bool == true)
    #expect(saved["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(saved["StandardOutPath"] as? String == log)
    #expect(saved["KeepAlive"] == nil)
    #expect(saved["StartInterval"] == nil)
    #expect(fixture.runner.loadedAgent == saved as NSDictionary)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.settings.isEmpty)
}

@Test func failedCustomSelectionRestoresLoginConfigurationBeforeRepair() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
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
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let agent = try Data(contentsOf: fixture.store.agent)
    let loaded = fixture.runner.loadedAgent
    let mutations = fixture.runner.launchctlMutations.count
    fixture.runner.settings = [:]

    _ = try fixture.manager.activate()

    #expect(try Data(contentsOf: fixture.store.agent) == agent)
    #expect(fixture.runner.loadedAgent == loaded)
    #expect(fixture.runner.launchctlMutations.dropFirst(mutations).allSatisfy { $0.first == "setenv" })
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
}

@Test(arguments: ["Program", "BundleProgram", "ProgramArguments", "Label"])
func unrelatedLoginProgramIsPreservedWhenItsOtherSettingsMatch(key: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    var properties = fixture.store.agentProperties
    if key == "ProgramArguments" {
        properties[key] = [fixture.store.persistentExecutable.path, "uninstall"]
    } else {
        properties[key] = "/another/program"
    }
    let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    try data.write(to: fixture.store.agent)
    let settings = fixture.runner.settings
    let mutations = fixture.runner.launchctlMutations

    #expect(throws: ServiceError.self) { try fixture.manager.use(.bundled) }
    #expect(throws: ServiceError.self) { try fixture.manager.use(.custom) }
    #expect(throws: ServiceError.self) { try fixture.manager.uninstall() }
    #expect(try Data(contentsOf: fixture.store.agent) == data)
    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.launchctlMutations == mutations)
}

@Test(arguments: [
    "/someone/elses/service",
    "Library/Developer/CustomXcodeBuildService/versions-other/custom-v1.0.0/libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle",
    "Library/Developer/CustomXcodeBuildService/versions/custom-v1.0.0/libexec/swift-build/another-service",
    "Library/Developer/CustomXcodeBuildService/versions/custom-v1.0.0/extra/libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle",
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
    "versions/custom-v1.0.0/libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle",
    "versions/custom-v1.0.0/libexec/swift-build/SWBBuildService.bundle/SwiftBuild_SWBCore.bundle",
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

@Test(arguments: [Int32(0), 1, 130], [UInt32(0), 501])
func guiRelaunchDropsAdministratorCredentialsAndPreservesArgumentsAndExitStatus(status: Int32, currentUserID: UInt32) throws {
    let fixture = try Fixture()
    fixture.runner.managerName = "Background"
    fixture.runner.attachedStatus = status
    let executable = "/tmp/release with spaces/bin/custom-xcode-build-service"
    let arguments = ["install", "--package", "/tmp/package 'with' $literal characters"]

    #expect(try fixture.manager.environment.runInGUI(executable, arguments: arguments, currentUserID: currentUserID) == status)

    let prefix = currentUserID == 0 ? [] : ["/usr/bin/sudo", "--"]
    #expect(fixture.runner.attachedCommands == [prefix + [
        "/bin/launchctl", "asuser", "501",
        "/usr/bin/sudo", "-H", "-u", "#501", "--", executable,
    ] + arguments])
    #expect(fixture.runner.launchctlMutations.isEmpty)
    #expect(try !fixture.store.exists(fixture.store.root))
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

@Test(arguments: ["exit 7", "kill -TERM $$"])
func attachedProcessPreservesFailureStatus(script: String) throws {
    #expect(try ProcessRunner().runAttached("/bin/sh", ["-c", script]) == (script == "exit 7" ? 7 : 143))
}

@Test(arguments: ["Background", "System", "wrongUID"], ["install", "activate", "uninstall", "status", "use custom", "use bundled"])
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

    do {
        switch command {
        case "install": _ = try fixture.manager.install(from: package)
        case "activate": _ = try fixture.manager.activate()
        case "uninstall": _ = try fixture.manager.uninstall()
        case "use custom": _ = try fixture.manager.use(.custom)
        case "use bundled": _ = try fixture.manager.use(.bundled)
        default: _ = try fixture.manager.status()
        }
        Issue.record("A foreign launchd context must not change the installation.")
    } catch {
        if command == "status" {
            #expect(error is ServiceError)
        } else {
            #expect(error is LaunchEnvironment.GUIRequired)
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

@Test func switchesServicesWithoutRemovingReleasesOrStoppingBuilds() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let installed = try #require(try fixture.store.selectedPackage())
    fixture.runner.processes = "123 /Applications/Xcode.app/Contents/MacOS/Xcode\n456 \(installed.service.path)\n"

    _ = try fixture.manager.use(.bundled)

    #expect(try fixture.store.selectedService() == .bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.agent))
    #expect(try fixture.store.selectedPackage()?.directory == installed.directory)
    #expect(FileManager.default.isExecutableFile(atPath: fixture.store.command.path))
    let status = try fixture.manager.status()
    #expect(status.contains("Installed: custom-v1.0.0"))
    #expect(status.contains("Selected service: bundled"))
    #expect(status.contains("Launchd selection: bundled"))
    #expect(status.contains("PID 456: \(installed.service.path) [installed custom release]"))
    #expect(!status.contains("do not match the saved selection"))
    let mutations = fixture.runner.launchctlMutations
    _ = try fixture.manager.use(.bundled)
    #expect(fixture.runner.launchctlMutations == mutations)

    _ = try fixture.manager.use(.custom)
    _ = try fixture.manager.use(.custom)

    #expect(try fixture.store.selectedService() == .custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == installed.service.path)
    #expect(fixture.runner.settings["DisableConcurrentDependencyResolution"] == "0")
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.exists(fixture.store.agent))
}

@Test(arguments: ["custom-v1.0.0", "custom-v1.0.1"])
func installingPreservesBundledSelection(version: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let oldPackage = try #require(try fixture.store.selectedPackage())
    _ = try fixture.manager.use(.bundled)

    let output = try fixture.manager.install(from: fixture.package(version))

    #expect(output.contains("Selected service: bundled"))
    #expect(try fixture.store.selectedPackage()?.manifest.version == version)
    #expect(try fixture.store.selectedService() == .bundled)
    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try !fixture.store.exists(fixture.store.agent))
    #expect(try fixture.store.exists(oldPackage.directory))
    #expect(FileManager.default.isExecutableFile(atPath: fixture.store.command.path))
    _ = try fixture.manager.use(.custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
}

@Test func lateActivationRespectsBundledSelectionWithoutInspectingCustomPackageOrOverrides() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
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

@Test(arguments: ["manifest.json", "libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle", "bin/custom-xcode-build-service"])
func selectingBundledWorksAfterXcodeUpdateAndPayloadDamage(missingPath: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    try FileManager.default.removeItem(at: fixture.store.current.appendingPathComponent(missingPath))
    fixture.runner.xcodeStatus = 1

    _ = try fixture.manager.use(.bundled)

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try fixture.store.selectedService() == .bundled)
    #expect(try fixture.store.exists(fixture.store.current))
}

@Test func selectingCustomRequiresAnInstalledReleaseAndWorksAfterXcodeUpdate() throws {
    let fixture = try Fixture()
    #expect(throws: ServiceError.self) { try fixture.manager.use(.custom) }
    #expect(try !fixture.store.exists(fixture.store.root))
    _ = try fixture.manager.use(.bundled)
    #expect(try !fixture.store.exists(fixture.store.root))
    #expect(fixture.runner.launchctlMutations.isEmpty)
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    _ = try fixture.manager.use(.bundled)
    fixture.runner.xcodeVersion = "Xcode 28.0\nBuild version 28A100\n"
    _ = try fixture.manager.use(.custom)
    #expect(try fixture.store.selectedService() == .custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == (try fixture.store.selectedPackage()?.service.path))
    #expect(fixture.runner.loaded)
    _ = try fixture.manager.uninstall()
    _ = try fixture.manager.use(.bundled)
    #expect(throws: ServiceError.self) { try fixture.manager.use(.custom) }
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path)) == [".owner", ".lock"])
}

@Test(arguments: ["bootout", "DisableConcurrentDependencyResolution", "XCBBUILDSERVICE_PATH"])
func failedBundledSelectionRestoresCustomSelection(failure: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let settings = fixture.runner.settings
    fixture.runner.failOnce = failure == "bootout" ? ["bootout", fixture.manager.environment.job] : ["unsetenv", failure]

    #expect(throws: ServiceError.self) { try fixture.manager.use(.bundled) }

    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.loaded)
    #expect(try fixture.store.selectedService() == .custom)
    #expect(try fixture.store.exists(fixture.store.command))
}

@Test(arguments: ["bootstrap", "XCBBUILDSERVICE_PATH", "DisableConcurrentDependencyResolution"])
func failedCustomSelectionRestoresBundledSelection(failure: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let installed = try #require(try fixture.store.selectedPackage())
    _ = try fixture.manager.use(.bundled)
    fixture.runner.failOnce = failure == "bootstrap"
        ? ["bootstrap", fixture.manager.environment.domain, fixture.store.agent.path]
        : ["setenv", failure, failure == "XCBBUILDSERVICE_PATH" ? installed.service.path : "0"]

    #expect(throws: ServiceError.self) { try fixture.manager.use(.custom) }

    #expect(fixture.runner.settings.isEmpty)
    #expect(!fixture.runner.loaded)
    #expect(try fixture.store.selectedService() == .bundled)
    #expect(try fixture.store.selectedPackage()?.directory == installed.directory)
    _ = try fixture.manager.use(.custom)
    #expect(fixture.runner.settings["XCBBUILDSERVICE_PATH"] == installed.service.path)
}

@Test(arguments: [BuildService.custom, .bundled], ["environment", "plist", "job"])
func selectionRefusesForeignConfiguration(service: BuildService, conflict: String) throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    switch conflict {
    case "environment": fixture.runner.settings["XCBBUILDSERVICE_PATH"] = "/another/service"
    case "plist": try fixture.write("foreign plist", to: fixture.store.agent)
    default: try fixture.store.remove(fixture.store.agent)
    }
    let settings = fixture.runner.settings
    let mutations = fixture.runner.launchctlMutations

    #expect(throws: (any Error).self) { try fixture.manager.use(service) }

    #expect(fixture.runner.settings == settings)
    #expect(fixture.runner.launchctlMutations == mutations)
    #expect(fixture.runner.loaded)
}

@Test func statusAndUpdateReconcileOwnedEnvironmentWithBundledSelection() throws {
    let fixture = try Fixture()
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.0"))
    let staleSettings = fixture.runner.settings
    _ = try fixture.manager.use(.bundled)
    fixture.runner.settings = staleSettings

    let status = try fixture.manager.status()
    #expect(status.contains("Selected service: bundled"))
    #expect(status.contains("Launchd selection: custom release selected for future processes"))
    #expect(status.contains("Run use bundled to reapply it"))
    _ = try fixture.manager.install(from: fixture.package("custom-v1.0.1"))
    #expect(fixture.runner.settings.isEmpty)
    #expect(try fixture.store.selectedService() == .bundled)
    #expect(!fixture.runner.loaded)
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

    func package(_ version: String, schemaVersion: Int = 2, manifestChanges: [String: Any] = [:]) throws -> URL {
        let package = directory.appendingPathComponent(UUID().uuidString)
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
