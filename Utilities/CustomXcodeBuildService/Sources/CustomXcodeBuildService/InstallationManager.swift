import Foundation

struct InstallationManager {
    let store: InstallationStore
    let environment: LaunchEnvironment

    func install(from directory: URL) throws -> String {
        try requireUser()
        let package = try ReleasePackage(directory: directory)
        try package.requireCompatibleHost(using: environment.runner)
        try environment.requireGUI()
        return try store.withLock(create: true) {
            let previous = try store.selectedPackage()
            try store.validateExternalPaths()
            let settings = try environment.settings()
            try settings.requireOwnership(among: store.ownedServicePaths())
            let hadAgent = try store.exists(store.agent)
            let hadCommand = try store.exists(store.command)
            let wasLoaded = try environment.isLoaded()
            guard !wasLoaded || hadAgent else { throw ServiceError("An unrelated job already uses \(InstallationStore.label).") }
            let installed = try store.stage(package)
            try Transaction.perform { transaction in
                if wasLoaded {
                    try environment.bootout()
                    transaction.undo { try environment.bootstrap(store.agent) }
                }
                try store.select(installed)
                transaction.undo { try store.select(previous) }
                if !hadCommand {
                    try store.writeCommand()
                    transaction.undo { try store.remove(store.command) }
                }
                if !hadAgent {
                    try store.writeAgent()
                    transaction.undo { try store.remove(store.agent) }
                }
                try apply(installed, previous: settings, transaction: transaction)
                try environment.bootstrap(store.agent)
            }
            return """
            Installed \(installed.manifest.version) (\(installed.manifest.sourceRevision)).
            Xcode: \(installed.manifest.xcodeVersion) (\(installed.manifest.xcodeBuildVersion))
            Service: \(installed.service.path)
            Command: \(store.command.path)
            Quit and reopen Xcode to use the custom service. All future GUI Xcode
            processes for this user inherit this selection. Existing terminals do not.
            """
        }
    }

    func activate() throws -> String {
        try requireUser()
        try environment.requireGUI()
        return try store.withLock(create: false) {
            guard let selected = try store.selectedPackage() else { throw ServiceError("No custom build service is installed.") }
            try selected.requireCompatibleHost(using: environment.runner)
            let settings = try environment.settings()
            try settings.requireOwnership(among: store.ownedServicePaths())
            try Transaction.perform { transaction in try apply(selected, previous: settings, transaction: transaction) }
            return "Activated \(selected.manifest.version). Quit and reopen Xcode if it was already running."
        }
    }

    func uninstall() throws -> String {
        try requireUser()
        try environment.requireGUI()
        return try store.withLock(create: false) {
            guard try store.exists(store.root) else { return "No custom build service is installed." }
            _ = try store.selectedPackage()
            try store.validateRemoval()
            try store.validateExternalPaths()
            let settings = try environment.settings()
            try settings.requireOwnership(among: store.ownedServicePaths())
            let hadAgent = try store.exists(store.agent)
            let hadCommand = try store.exists(store.command)
            let wasLoaded = try environment.isLoaded()
            guard !wasLoaded || hadAgent else { throw ServiceError("An unrelated job already uses \(InstallationStore.label).") }
            let running = try runningProcesses()
            guard !running.contains(where: {
                ["Xcode", "xcodebuild"].contains($0.name) || (Self.serviceNames.contains($0.name) && $0.path.hasPrefix(store.versions.path + "/"))
            }) else {
                throw ServiceError("Xcode, xcodebuild, or an installed custom build service is still running. Quit Xcode, stop command-line builds, and wait for their build services to exit, then retry uninstall.")
            }
            try Transaction.perform { transaction in
                if wasLoaded {
                    try environment.bootout()
                    transaction.undo { try environment.bootstrap(store.agent) }
                }
                if settings.concurrentResolution != nil {
                    try environment.set("DisableConcurrentDependencyResolution", to: nil)
                    transaction.undo { try environment.set("DisableConcurrentDependencyResolution", to: settings.concurrentResolution) }
                }
                if settings.service != nil {
                    try environment.set("XCBBUILDSERVICE_PATH", to: nil)
                    transaction.undo { try environment.set("XCBBUILDSERVICE_PATH", to: settings.service) }
                }
                if hadAgent {
                    try store.remove(store.agent)
                    transaction.undo { try store.writeAgent() }
                }
                if hadCommand {
                    try store.remove(store.command)
                    transaction.undo { try store.writeCommand() }
                }
            }
            // Settings are removed before payloads, so a new Xcode launch cannot
            // select a service whose resources are being deleted.
            try store.removePayloads()
            return "Uninstalled the custom build service. Reopen Xcode to use its bundled service."
        }
    }

    func status() throws -> String {
        try store.withLock(create: false) { try lockedStatus() }
    }

    private func lockedStatus() throws -> String {
        let selected = try store.selectedPackage()
        try environment.requireGUI()
        let settings = try environment.settings()
        let loaded = try environment.isLoaded()
        let running = try runningProcesses().filter { Self.serviceNames.contains($0.name) }
        var lines = ["Installed: \(selected?.manifest.version ?? "none")"]
        if let selected {
            lines.append("Source: \(selected.manifest.sourceRevision)")
            lines.append("Required Xcode: \(selected.manifest.xcodeVersion) (\(selected.manifest.xcodeBuildVersion))")
            lines.append("Selected service: \(selected.service.path)")
        }
        let active = selected != nil && settings.service == selected?.service.path && settings.concurrentResolution == "0" && settings.legacyService == nil
        lines.append("Launchd selection: \(active ? "custom release selected for future processes" : "not selected or conflicting")")
        lines.append("XCBBUILDSERVICE_PATH: \(settings.service ?? "unset")")
        lines.append("DisableConcurrentDependencyResolution: \(settings.concurrentResolution ?? "unset")")
        lines.append("SWBBUILDSERVICE_PATH: \(settings.legacyService ?? "unset")")
        lines.append("Login job: \(loaded ? "loaded" : "not loaded")")
        lines.append("Running build services: \(running.isEmpty ? "none detected" : "")")
        lines += running.map { "  PID \($0.pid): \($0.path)\($0.path == selected?.service.path ? " [selected release]" : "")" }
        lines.append("Launchd settings do not prove that an already running Xcode uses this release.")
        lines.append("After login, restart Xcode if macOS restored it before the login job ran.")
        return lines.joined(separator: "\n")
    }

    private func requireUser() throws {
        guard environment.userID != 0 else { throw ServiceError("Run as your logged-in user, without sudo.") }
    }

    private func apply(_ selected: ReleasePackage, previous: LaunchEnvironment.Settings, transaction: Transaction) throws {
        try environment.set("XCBBUILDSERVICE_PATH", to: selected.service.path)
        transaction.undo { try environment.set("XCBBUILDSERVICE_PATH", to: previous.service) }
        try environment.set("DisableConcurrentDependencyResolution", to: "0")
        transaction.undo { try environment.set("DisableConcurrentDependencyResolution", to: previous.concurrentResolution) }
    }

    private static let serviceNames = ["SWBBuildService", "SWBBuildServiceBundle", "XCBBuildService"]

    private func runningProcesses() throws -> [(pid: String, path: String, name: String)] {
        let output = try environment.runner.run("/bin/ps", ["-ax", "-ww", "-o", "pid=,comm="]).requireSuccess("ps")
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
