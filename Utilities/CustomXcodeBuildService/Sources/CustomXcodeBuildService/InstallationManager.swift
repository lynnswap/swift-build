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

    func reload() throws -> String {
        try requireUser()
        return try store.withExistingLock(access: .modify) {
            try reloadInstalledService()
        } ?? "No custom build service is installed."
    }

    // The caller holds the installation lock across replacement and service reload.
    private func reloadInstalledService() throws -> String {
        guard try store.selectedService() == .custom else {
            return "Xcode's bundled service is selected; no custom reload is needed."
        }
        guard let installed = try store.selectedPackage() else {
            throw ServiceError("No packaged service is available. Reinstall with Homebrew.")
        }
        try installed.validateForUse()
        let running = try runningProcesses().filter { Self.serviceNames.contains($0.name) && store.ownsService(at: $0.path) }
        try Transaction.perform { transaction in
            try updateServiceBundleLink(installed, transaction: transaction)
        }
        var stopped: [String] = []
        var failures: [String] = []
        for process in running {
            do {
                // The original process may already have exited while updating the link.
                guard try runningProcesses().contains(where: { $0.pid == process.pid && $0.path == process.path }) else { continue }
                let result = try environment.runner.run("/bin/kill", ["-TERM", process.pid])
                if result.status != 0 {
                    guard try runningProcesses().contains(where: { $0.pid == process.pid && $0.path == process.path }) else { continue }
                    _ = try result.requireSuccess("Stopping service \(process.pid)")
                }
                stopped.append(process.pid)
            } catch { failures.append(String(describing: error)) }
        }
        let report = "Installed service: \(installed.manifest.version). Sent termination to managed service PIDs: \(stopped.isEmpty ? "none" : stopped.joined(separator: ", ")). Xcode clients start the updated service on demand. Retry any in-flight requests that were interrupted."
        guard failures.isEmpty else { throw ServiceError(report + "\nReload failures: " + failures.joined(separator: "; ")) }
        return report
    }

    func use(_ service: BuildService) throws -> String {
        try requireUser()
        try environment.requireGUI()
        if service == .custom {
            guard let package = try store.packagedRelease() else {
                throw ServiceError("No packaged service is available. Reinstall with Homebrew.")
            }
            try package.validateForUse()
            return try store.withInstallationLock { try select(service) }
        }
        if let result = try store.withExistingLock(access: .modify, { try select(service) }) { return result }
        let previous = try readLaunchState()
        if previous.selection == .bundled, previous.settings.service == nil { return "Selected service: bundled" }
        return try store.withInstallationLock { try select(service) }
    }

    func migrateStandalone() throws -> String {
        try requireUser()
        return try store.withExistingLock(access: .modify) {
            if try store.hasStandaloneSelection() {
                try environment.requireGUI()
                return try select(.custom, preserveCommandPath: true)
            }
            guard let previous = try store.legacyCommandTarget() else {
                return "No standalone migration needed. The selected service is unchanged."
            }
            try Transaction.perform { transaction in
                try retireLegacyCommand(previous, preservePath: true, transaction: transaction)
            }
            return "The old command path now follows Homebrew. The selected service and legacy payloads are unchanged."
        } ?? "No standalone installation found. Run custom-xcode-build-service use custom to select this service."
    }

    private func retireLegacyCommand(_ previous: String, preservePath: Bool, transaction: Transaction) throws {
        try store.remove(store.command)
        transaction.undo {
            try FileManager.default.createSymbolicLink(atPath: store.command.path, withDestinationPath: previous)
        }
        if preservePath {
            try FileManager.default.createSymbolicLink(at: store.command, withDestinationURL: store.persistentExecutable)
            transaction.undo { try store.remove(store.command) }
        }
    }

    private func select(_ service: BuildService, preserveCommandPath: Bool = false) throws -> String {
        let previous = try readLaunchState()
        let customPackage: ReleasePackage?
        switch service {
        case .custom:
            guard let installed = try store.packagedRelease() else {
                throw ServiceError("No custom build service is installed. Reinstall with Homebrew.")
            }
            try installed.validateForUse()
            customPackage = installed
        case .bundled:
            customPackage = nil
        }
        let legacyCommandTarget: String?
        if service == .custom {
            legacyCommandTarget = try store.legacyCommandTarget()
        } else {
            legacyCommandTarget = nil
        }
        try Transaction.perform { transaction in
            try configure(customPackage: customPackage, previous: previous, transaction: transaction)
            if let legacyCommandTarget {
                try retireLegacyCommand(legacyCommandTarget, preservePath: preserveCommandPath, transaction: transaction)
            }
        }
        let report = "Selected service: \(service.rawValue)"
        let selectedServicePath = service == .custom ? store.service.path : nil
        let selectionChanged = previous.selection != service || previous.settings.service != selectedServicePath || legacyCommandTarget != nil
        return selectionChanged ? report + "\n" + Self.clientRestartInstructions : report
    }

    func activate() throws -> String {
        try requireUser()
        guard let result = try store.withExistingLock(access: .modify, {
            guard try store.selectedService() == .custom else {
                return "Xcode's bundled service is selected; no custom activation is needed."
            }
            try environment.requireGUI()
            guard let selected = try store.selectedPackage() else { throw ServiceError("No custom build service is installed.") }
            try selected.validateForUse()
            let settings = try environment.settings()
            try settings.requireOwnership(in: store)
            try Transaction.perform { transaction in try apply(selected, previous: settings, transaction: transaction) }
            return "Activated \(selected.manifest.version) for newly started clients."
        }) else { throw ServiceError("No custom build service is installed.") }
        return result
    }

    func uninstall() throws -> String {
        try requireUser()
        return try store.withExistingLock(access: .modify) {
            try environment.requireGUI()
            try store.validateCommand()
            let launchState = try readLaunchState()
            let hadCommand = try store.exists(store.command)
            let oldCommandTarget = hadCommand ? try FileManager.default.destinationOfSymbolicLink(atPath: store.command.path) : ""
            let hadPayloads = try store.exists(store.current) || store.exists(store.versions)
            guard hadPayloads || launchState.selection == .custom || hadCommand || launchState.loaded || launchState.settings.service != nil else {
                try store.removePayloads()
                return "No custom build service is installed."
            }
            let running = try runningProcesses()
            guard !running.contains(where: {
                ["Xcode", "xcodebuild"].contains($0.name) || (Self.serviceNames.contains($0.name) && store.ownsService(at: $0.path))
            }) else {
                throw ServiceError("Xcode, xcodebuild, or an installed custom build service is still running. Quit Xcode, stop command-line builds, and wait for their build services to exit, then retry uninstall.")
            }
            try Transaction.perform { transaction in
                try configure(customPackage: nil, previous: launchState, transaction: transaction)
                if hadCommand {
                    try store.remove(store.command)
                    transaction.undo { try FileManager.default.createSymbolicLink(atPath: store.command.path, withDestinationPath: oldCommandTarget) }
                }
            }
            // Settings are removed before payloads, so a new Xcode launch cannot
            // select a service whose resources are being deleted.
            try store.removePayloads()
            let report = "Removed user settings and legacy payloads. Selected service: bundled. Homebrew files are unchanged; run brew uninstall custom-xcode-build-service to remove them."
            return launchState.selection == .custom || launchState.settings.service != nil ? report + "\n" + Self.clientRestartInstructions : report
        } ?? "No custom build service is installed."
    }

    func status() throws -> String {
        // Homebrew owns the payload; our lock only protects per-user selection.
        let installed = Result { try store.packagedRelease() }
        let selection: Result<BuildService, any Error>
        let selectedPackage: Result<ReleasePackage?, any Error>
        do {
            let snapshot = try store.withExistingLock(access: .read) {
                (Result { try store.selectedService() }, Result { try store.selectedPackage() })
            }
            selection = snapshot?.0 ?? Result { try store.selectedService() }
            selectedPackage = snapshot?.1 ?? Result { try store.selectedPackage() }
        } catch {
            selection = .failure(error)
            selectedPackage = .failure(error)
        }
        return try statusReport(installed: installed, selection: selection, selectedPackage: selectedPackage)
    }

    private func statusReport(installed: Result<ReleasePackage?, any Error>, selection: Result<BuildService, any Error>, selectedPackage: Result<ReleasePackage?, any Error>) throws -> String {
        var lines: [String] = []
        var issues: [String] = []
        let package: ReleasePackage?
        switch installed {
        case .success(let value):
            package = value
            lines.append("Installed: \(value?.manifest.version ?? "none")")
        case .failure(let error):
            package = nil
            lines.append("Installed: unavailable")
            issues.append("Installation error: \(error)")
        }
        let selectedService: BuildService?
        switch selection {
        case .success(let value):
            selectedService = value
            lines.append("Selected service: \(value.rawValue)")
        case .failure(let error):
            selectedService = nil
            lines.append("Selected service: unavailable")
            issues.append("Selection error: \(error)")
        }
        let selected: ReleasePackage?
        switch selectedPackage {
        case .success(let value):
            selected = value
            if let value {
                lines.append("Selected custom package: \(value.manifest.version) (\(value.directory.path))")
                do { try value.validateForUse() }
                catch { issues.append("Selected package error: \(error)") }
            }
        case .failure(let error):
            selected = nil
            lines.append("Selected custom package: unavailable")
            issues.append("Selected package error: \(error)")
        }
        if let package {
            lines.append("Source: \(package.manifest.sourceRevision)")
            lines.append("Built with Xcode: \(package.manifest.xcodeVersion) (\(package.manifest.xcodeBuildVersion))")
            lines.append("Installed custom service: \(store.service.path)")
            do {
                try package.validateForUse()
                guard selectedService != .custom || FileManager.default.isExecutableFile(atPath: store.service.path) else {
                    throw ServiceError("The fixed service entry point is missing or not executable. Run use custom to repair it.")
                }
            }
            catch { issues.append("Installation error: \(error)") }
        }
        do {
            try environment.requireGUI()
            let settings = try environment.settings()
            let active = selected != nil && settings.service == store.service.path && settings.concurrentResolution == "0" && settings.legacyService == nil
            let noOverrides = settings.service == nil && settings.concurrentResolution == nil && settings.legacyService == nil
            let applied: String
            if noOverrides {
                applied = "bundled (no custom launchd settings)"
            } else if !issues.isEmpty {
                applied = "unverified (installed release or selection unavailable)"
            } else {
                applied = active ? "custom release selected for future processes" : "conflicting or incomplete custom settings"
            }
            lines.append("Launchd selection: \(applied)")
            if issues.isEmpty, let selectedService, !(selectedService == .custom ? active : noOverrides) {
                lines.append("Launchd settings do not match the saved selection. Run use \(selectedService.rawValue) to reapply it.")
            }
            lines.append("XCBBUILDSERVICE_PATH: \(settings.service ?? "unset")")
            lines.append("DisableConcurrentDependencyResolution: \(settings.concurrentResolution ?? "unset")")
            lines.append("SWBBUILDSERVICE_PATH: \(settings.legacyService ?? "unset")")
        } catch {
            lines.append("Launchd selection: unavailable")
            issues.append("Launchd environment error: \(error)")
        }
        do { lines.append("Login job: \(try environment.isLoaded() ? "loaded" : "not loaded")") }
        catch {
            lines.append("Login job: unavailable")
            issues.append("Login job error: \(error)")
        }
        do {
            let running = try runningProcesses().filter { Self.serviceNames.contains($0.name) }
            lines.append("Running build services: \(running.isEmpty ? "none detected" : "")")
            lines += running.map { "  PID \($0.pid): \($0.path)\(store.ownsService(at: $0.path) ? " [managed custom service]" : "")" }
        } catch {
            lines.append("Running build services: unavailable")
            issues.append("Process inspection error: \(error)")
        }
        lines += issues
        lines.append("Launchd settings do not prove that an already running Xcode uses this release.")
        lines.append("Existing service processes keep their loaded code until reloaded. Switching services requires refreshing the clients' environment.")
        let report = lines.joined(separator: "\n")
        guard issues.isEmpty else { throw ServiceError(report) }
        return report
    }

    private func requireUser() throws {
        guard environment.userID != 0 else { throw ServiceError("Installation management must run as the invoking user, not root.") }
    }

    private struct LaunchState {
        let selection: BuildService
        var loaded: Bool
        let settings: LaunchEnvironment.Settings
    }

    private func readLaunchState() throws -> LaunchState {
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
        if previous.loaded {
            try environment.bootout()
            transaction.undo { try environment.bootstrap(store.agent) }
        }
        if let customPackage {
            let agent = try store.exists(store.agent) ? Data(contentsOf: store.agent) : nil
            if try store.writeAgent(preserving: agent) {
                transaction.undo {
                    if let agent {
                        try agent.write(to: store.agent, options: .atomic)
                    } else {
                        try store.remove(store.agent)
                    }
                }
            }
            try apply(customPackage, previous: previous.settings, transaction: transaction)
            try environment.bootstrap(store.agent)
            transaction.undo { try environment.bootout() }
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
                let agent = try Data(contentsOf: store.agent)
                try store.remove(store.agent)
                transaction.undo { try agent.write(to: store.agent, options: .atomic) }
            }
        }
    }

    private static let clientRestartInstructions = """
    Restart Xcode, Xcode Service (for MCP), terminal applications, and AI agent applications to use this selection.
    Start terminal-based agents from the restarted terminal so they inherit the new environment.
    """

    private func apply(_ selected: ReleasePackage, previous: LaunchEnvironment.Settings, transaction: Transaction) throws {
        try updateServiceBundleLink(selected, transaction: transaction)
        try environment.set("XCBBUILDSERVICE_PATH", to: store.service.path)
        transaction.undo { try environment.set("XCBBUILDSERVICE_PATH", to: previous.service) }
        try environment.set("DisableConcurrentDependencyResolution", to: "0")
        transaction.undo { try environment.set("DisableConcurrentDependencyResolution", to: previous.concurrentResolution) }
    }

    private func updateServiceBundleLink(_ selected: ReleasePackage, transaction: Transaction) throws {
        let previous = try store.serviceBundleLink()
        // Point at the whole bundle: both the client and Bundle.main need to find
        // plugins and resources relative to the executable's launch path.
        if previous == selected.resources.path { return }
        try store.setServiceBundleLink(selected.resources.path)
        transaction.undo { try store.setServiceBundleLink(previous) }
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
