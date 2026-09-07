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

struct InstallationManager {
    let store: InstallationStore
    let environment: LaunchEnvironment

    func install(from directory: URL) throws -> String {
        try requireUser()
        let package = try ReleasePackage(directory: directory)
        try package.validateForInstallation()
        try package.requireCompatibleHost(using: environment.runner)
        try environment.requireGUI()
        return try store.withInstallationLock {
            let previous = try store.selectedDirectory()
            var launchState = try readLaunchState()
            let service: BuildService = previous == nil ? .custom : launchState.selection
            let hadCommand = try store.exists(store.command)
            let installed = try store.stage(package)
            try Transaction.perform { transaction in
                if launchState.loaded {
                    try environment.bootout()
                    transaction.undo { try environment.bootstrap(store.agent) }
                    launchState.loaded = false
                }
                try store.select(installed.directory)
                transaction.undo { try store.select(previous) }
                if !hadCommand {
                    try store.writeCommand()
                    transaction.undo { try store.remove(store.command) }
                }
                try configure(customPackage: service == .custom ? installed : nil,
                              previous: launchState, transaction: transaction)
            }
            return """
            Installed \(installed.manifest.version) (\(installed.manifest.sourceRevision)).
            Xcode: \(installed.manifest.xcodeVersion) (\(installed.manifest.xcodeBuildVersion))
            Service: \(installed.service.path)
            Command: \(store.command.path)
            Selected service: \(service.rawValue)
            \(Self.restartInstructions)
            """
        }
    }

    func use(_ service: BuildService) throws -> String {
        try requireUser()
        try environment.requireGUI()
        guard let result = try store.withExistingLock(access: .modify, {
            let previous = try readLaunchState()
            let customPackage: ReleasePackage?
            switch service {
            case .custom:
                guard let installed = try store.selectedPackage() else {
                    throw ServiceError("No custom build service is installed. Run install first.")
                }
                try installed.requireCompatibleHost(using: environment.runner)
                customPackage = installed
            case .bundled:
                customPackage = nil
            }
            try Transaction.perform { transaction in
                try configure(customPackage: customPackage, previous: previous, transaction: transaction)
            }
            return "Selected service: \(service.rawValue)\n\(Self.restartInstructions)"
        }) else {
            if service == .custom { throw ServiceError("No custom build service is installed. Run install first.") }
            let state = try readLaunchState()
            guard state.selection == .bundled, state.settings.service == nil else {
                throw ServiceError("Custom settings exist without an installation. Resolve them before selecting bundled.")
            }
            return "Selected service: bundled\n\(Self.restartInstructions)"
        }
        return result
    }

    func activate() throws -> String {
        try requireUser()
        try environment.requireGUI()
        guard let result = try store.withExistingLock(access: .modify, {
            guard try store.selectedService() == .custom else {
                return "Xcode's bundled service is selected; no custom activation is needed."
            }
            guard let selected = try store.selectedPackage() else { throw ServiceError("No custom build service is installed.") }
            try selected.requireCompatibleHost(using: environment.runner)
            let settings = try environment.settings()
            try settings.requireOwnership(in: store)
            try Transaction.perform { transaction in try apply(selected, previous: settings, transaction: transaction) }
            return "Activated \(selected.manifest.version).\n\(Self.restartInstructions)"
        }) else { throw ServiceError("No custom build service is installed.") }
        return result
    }

    func uninstall() throws -> String {
        try requireUser()
        try environment.requireGUI()
        return try store.withExistingLock(access: .modify) {
            let launchState = try readLaunchState()
            let hadCommand = try store.exists(store.command)
            let hadPayloads = try store.exists(store.current) || store.exists(store.versions)
            guard hadPayloads || launchState.selection == .custom || hadCommand || launchState.loaded || launchState.settings.service != nil else {
                try store.removePayloads()
                return "No custom build service is installed."
            }
            let running = try runningProcesses()
            guard !running.contains(where: {
                ["Xcode", "xcodebuild"].contains($0.name) || (Self.serviceNames.contains($0.name) && $0.path.hasPrefix(store.versions.path + "/"))
            }) else {
                throw ServiceError("Xcode, xcodebuild, or an installed custom build service is still running. Quit Xcode, stop command-line builds, and wait for their build services to exit, then retry uninstall.")
            }
            try Transaction.perform { transaction in
                try configure(customPackage: nil, previous: launchState, transaction: transaction)
                if hadCommand {
                    try store.remove(store.command)
                    transaction.undo { try store.writeCommand() }
                }
            }
            // Settings are removed before payloads, so a new Xcode launch cannot
            // select a service whose resources are being deleted.
            try store.removePayloads()
            return "Uninstalled the custom build service. Selected service: bundled\n\(Self.restartInstructions)"
        } ?? "No custom build service is installed."
    }

    func status() throws -> String {
        try environment.requireGUI()
        return try store.withExistingLock(access: .read) {
            try statusReport(installed: store.selectedPackage(), selection: store.selectedService())
        } ?? statusReport(installed: nil, selection: .bundled)
    }

    private func statusReport(installed: ReleasePackage?, selection: BuildService) throws -> String {
        let settings = try environment.settings()
        let loaded = try environment.isLoaded()
        let running = try runningProcesses().filter { Self.serviceNames.contains($0.name) }
        var lines = ["Installed: \(installed?.manifest.version ?? "none")", "Selected service: \(selection.rawValue)"]
        if let installed {
            lines.append("Source: \(installed.manifest.sourceRevision)")
            lines.append("Required Xcode: \(installed.manifest.xcodeVersion) (\(installed.manifest.xcodeBuildVersion))")
            lines.append("Installed custom service: \(installed.service.path)")
        }
        let active = installed != nil && settings.service == installed?.service.path && settings.concurrentResolution == "0" && settings.legacyService == nil
        let noOverrides = settings.service == nil && settings.concurrentResolution == nil && settings.legacyService == nil
        let applied = active ? "custom release selected for future processes" : (noOverrides ? "bundled (no custom launchd settings)" : "conflicting or incomplete custom settings")
        lines.append("Launchd selection: \(applied)")
        if !(selection == .custom ? active : noOverrides) {
            lines.append("Launchd settings do not match the saved selection. Run use \(selection.rawValue) to reapply it.")
        }
        lines.append("XCBBUILDSERVICE_PATH: \(settings.service ?? "unset")")
        lines.append("DisableConcurrentDependencyResolution: \(settings.concurrentResolution ?? "unset")")
        lines.append("SWBBUILDSERVICE_PATH: \(settings.legacyService ?? "unset")")
        lines.append("Login job: \(loaded ? "loaded" : "not loaded")")
        lines.append("Running build services: \(running.isEmpty ? "none detected" : "")")
        lines += running.map { "  PID \($0.pid): \($0.path)\($0.path == installed?.service.path ? " [installed custom release]" : "")" }
        lines.append("Launchd settings do not prove that an already running Xcode uses this release.")
        lines.append(Self.restartInstructions)
        return lines.joined(separator: "\n")
    }

    private func requireUser() throws {
        guard environment.userID != 0 else { throw ServiceError("Run as your logged-in user, without sudo.") }
    }

    private struct LaunchState {
        let selection: BuildService
        var loaded: Bool
        let settings: LaunchEnvironment.Settings
    }

    private func readLaunchState() throws -> LaunchState {
        try store.validateExternalPaths()
        let selection = try store.selectedService()
        let settings = try environment.settings()
        try settings.requireOwnership(in: store)
        let loaded = try environment.isLoaded()
        guard !loaded || selection == .custom else {
            throw ServiceError("An unrelated job already uses \(InstallationStore.label).")
        }
        return LaunchState(selection: selection, loaded: loaded, settings: settings)
    }

    private func configure(customPackage: ReleasePackage?, previous: LaunchState,
                           transaction: Transaction) throws {
        if previous.loaded && customPackage == nil {
            try environment.bootout()
            transaction.undo { try environment.bootstrap(store.agent) }
        }
        if let customPackage {
            if previous.selection == .bundled {
                try store.writeAgent()
                transaction.undo { try store.remove(store.agent) }
            }
            try apply(customPackage, previous: previous.settings, transaction: transaction)
            if !previous.loaded {
                try environment.bootstrap(store.agent)
                transaction.undo { try environment.bootout() }
            }
        } else {
            if previous.settings.concurrentResolution != nil {
                try environment.set("DisableConcurrentDependencyResolution", to: nil)
                transaction.undo { try environment.set("DisableConcurrentDependencyResolution", to: previous.settings.concurrentResolution) }
            }
            if previous.settings.service != nil {
                try environment.set("XCBBUILDSERVICE_PATH", to: nil)
                transaction.undo { try environment.set("XCBBUILDSERVICE_PATH", to: previous.settings.service) }
            }
            if previous.selection == .custom {
                try store.remove(store.agent)
                transaction.undo { try store.writeAgent() }
            }
        }
    }

    private static let restartInstructions = """
    Quit and reopen Xcode, terminal applications, and AI agent applications to use
    this selection. Start terminal-based agents from the restarted terminal.
    Existing processes keep their previous environment; no applications or builds were stopped.
    """

    private func apply(_ selected: ReleasePackage, previous: LaunchEnvironment.Settings, transaction: Transaction) throws {
        try environment.set("XCBBUILDSERVICE_PATH", to: selected.service.path)
        transaction.undo { try environment.set("XCBBUILDSERVICE_PATH", to: previous.service) }
        try environment.set("DisableConcurrentDependencyResolution", to: "0")
        transaction.undo { try environment.set("DisableConcurrentDependencyResolution", to: previous.concurrentResolution) }
    }

    private static let serviceNames = ["SWBBuildService", "SWBBuildServiceBundle", "XCBBuildService"]

    private func runningProcesses() throws -> [(pid: String, path: String, name: String)] {
        let output = try environment.runner.run("/bin/ps", ["-U", String(environment.userID), "-x", "-ww", "-o", "pid=,comm="]).requireSuccess("ps")
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard columns.count == 2 else { return nil }
            let path = String(columns[1]).trimmingCharacters(in: .whitespaces)
            let executable = URL(fileURLWithPath: path).lastPathComponent
            return (String(columns[0]), path, executable)
        }
    }
}

private final class Transaction {
    private var reversals: [() throws -> Void] = []
    func undo(_ operation: @escaping () throws -> Void) { reversals.append(operation) }

    static func perform(_ operation: (Transaction) throws -> Void) throws {
        let transaction = Transaction()
        do { try operation(transaction) }
        catch {
            var failures: [String] = []
            for reversal in transaction.reversals.reversed() {
                do { try reversal() }
                catch { failures.append(String(describing: error)) }
            }
            guard failures.isEmpty else {
                throw ServiceError("\(error)\nRollback also failed: \(failures.joined(separator: "; ")). Run status and resolve these errors before retrying.")
            }
            throw error
        }
    }
}
