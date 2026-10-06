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

struct InstallationStore {
    enum Access {
        case read
        case modify
    }

    static let label = "io.github.lynnswap.custom-xcode-build-service"
    private static let owner = "lynnswap/swift-build custom-xcode-build-service schema 1\n"
    let home: URL
    let packageDirectory: URL
    private let files = FileManager.default
    var root: URL { home.appendingPathComponent("Library/Developer/CustomXcodeBuildService") }
    var versions: URL { root.appendingPathComponent("versions") }
    var staging: URL { root.appendingPathComponent("staging") }
    var current: URL { root.appendingPathComponent("current") }
    var serviceBundle: URL { root.appendingPathComponent("SWBBuildService.bundle") }
    var service: URL { serviceBundle.appendingPathComponent("SWBBuildServiceBundle") }
    var command: URL { home.appendingPathComponent(".local/bin/custom-xcode-build-service") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    // Homebrew's wrapper preserves the opt/libexec executable path in argv[0].
    var homebrewCommand: URL { packageDirectory.deletingLastPathComponent().appendingPathComponent("bin/custom-xcode-build-service") }
    var persistentExecutable: URL { packageDirectory.appendingPathComponent("bin/custom-xcode-build-service") }

    func exists(_ url: URL) throws -> Bool {
        do { _ = try files.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    func withInstallationLock<T>(_ operation: () throws -> T) throws -> T {
        if try !exists(root) { try initializeRoot() }
        return try locked(access: .modify, operation)
    }

    func withExistingLock<T>(access: Access, _ operation: () throws -> T) throws -> T? {
        // Absence is a completed observation: a first installer may publish the
        // root immediately afterward, so an unlocked callback cannot recheck it.
        guard try exists(root) else { return nil }
        return try locked(access: access, operation)
    }

    private func locked<T>(access: Access, _ operation: () throws -> T) throws -> T {
        try requireOwnership()
        let descriptor = Darwin.open(root.appendingPathComponent(".lock").path, (access == .read ? O_RDONLY : O_RDWR) | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ServiceError("Cannot open installation lock: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceError("Cannot lock installation: \(String(cString: strerror(errno)))") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func initializeRoot() throws {
        try ensureDirectory(root.deletingLastPathComponent())
        let candidate = root.deletingLastPathComponent().appendingPathComponent(".CustomXcodeBuildService-initializing-\(UUID().uuidString)")
        try files.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try Data(Self.owner.utf8).write(to: candidate.appendingPathComponent(".owner"), options: .atomic)
            try Data().write(to: candidate.appendingPathComponent(".lock"), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.appendingPathComponent(".lock").path)
            // A normal rename could replace another publisher's directory and
            // strand its waiters on the old lock inode. RENAME_EXCL preserves it.
            if Darwin.renamex_np(candidate.path, root.path, UInt32(RENAME_EXCL)) != 0 {
                let failure = errno
                guard failure == EEXIST else {
                    throw ServiceError("Cannot publish installation directory: \(String(cString: strerror(failure)))")
                }
                try files.removeItem(at: candidate)
            }
        } catch {
            try removeAfterFailure(candidate, error: error)
        }
        try requireOwnership()
    }

    func requireOwnership() throws {
        guard try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
              try files.attributesOfItem(atPath: root.appendingPathComponent(".owner").path)[.type] as? FileAttributeType == .typeRegular,
              try String(contentsOf: root.appendingPathComponent(".owner"), encoding: .utf8) == Self.owner else {
            throw ServiceError("Refusing an unrecognized installation directory: \(root.path)")
        }
    }

    func packagedRelease() throws -> ReleasePackage? {
        guard try exists(packageDirectory.appendingPathComponent("manifest.json")) else { return nil }
        return try ReleasePackage(directory: packageDirectory)
    }

    func validateCommand() throws {
        if try exists(command) {
            guard try files.attributesOfItem(atPath: command.path)[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw ServiceError("Refusing to replace an unrelated command: \(command.path)")
            }
            let destination = try files.destinationOfSymbolicLink(atPath: command.path)
            guard isLegacyCommandTarget(destination) || isHomebrewCommandTarget(destination) else {
                throw ServiceError("Refusing to overwrite an unrelated command: \(command.path)")
            }
        }
    }

    func legacyCommandTarget() throws -> String? {
        guard try exists(command),
              try files.attributesOfItem(atPath: command.path)[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
        let destination = try files.destinationOfSymbolicLink(atPath: command.path)
        return isLegacyCommandTarget(destination) ? destination : nil
    }

    private func isLegacyCommandTarget(_ destination: String) -> Bool {
        // The standalone installer linked through current, rather than one version.
        let parent = command.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : parent.appendingPathComponent(destination)
        let installation = target.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return target.path == installation.appendingPathComponent("current/bin/custom-xcode-build-service").path
            && installation.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
    }

    private func isHomebrewCommandTarget(_ destination: String) -> Bool {
        let parent = command.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : parent.appendingPathComponent(destination)
        // Cleanup recognizes this tool's opt entry even from a local CLI or after
        // brew uninstall; the destination's payload need not still exist.
        return Array(target.standardizedFileURL.pathComponents.suffix(4))
            == ["opt", "custom-xcode-build-service", "bin", "custom-xcode-build-service"]
    }

    func hasStandaloneSelection() throws -> Bool {
        guard let executable = try selectedExecutable() else { return false }
        let package = executable.deletingLastPathComponent().deletingLastPathComponent()
        // Identify the old installer's locations without opening its manifest;
        // migration must also recover a missing or damaged old payload.
        return package.standardizedFileURL.path == current.standardizedFileURL.path
            || package.deletingLastPathComponent().resolvingSymlinksInPath().path == versions.resolvingSymlinksInPath().path
    }

    func selectedService() throws -> BuildService {
        try selectedExecutable() == nil ? .bundled : .custom
    }

    func selectedPackage() throws -> ReleasePackage? {
        guard let executable = try selectedExecutable() else { return nil }
        return try ReleasePackage(directory: executable.deletingLastPathComponent().deletingLastPathComponent())
    }

    func selectedExecutable() throws -> URL? {
        guard try exists(agent) else { return nil }
        // The owned label and activation command survive moving between Homebrew
        // and local builds; the previous executable path need not equal this one.
        guard try files.attributesOfItem(atPath: agent.path)[.type] as? FileAttributeType == .typeRegular,
              let actual = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? [String: Any],
              actual["Label"] as? String == Self.label,
              let arguments = actual["ProgramArguments"] as? [String],
              arguments.count == 2, arguments[1] == "activate",
              URL(fileURLWithPath: arguments[0]).lastPathComponent == "custom-xcode-build-service",
              (actual["Program"] == nil || actual["Program"] as? String == arguments.first),
              actual["BundleProgram"] == nil else {
            throw ServiceError("Refusing to overwrite an unrelated LaunchAgent: \(agent.path)")
        }
        return URL(fileURLWithPath: arguments[0])
    }

    var agentProperties: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [persistentExecutable.path, "activate"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": root.appendingPathComponent("activation.log").path,
            "StandardErrorPath": root.appendingPathComponent("activation.log").path,
        ]
    }

    func serviceBundleLink() throws -> String? {
        guard try exists(serviceBundle) else { return nil }
        return try files.destinationOfSymbolicLink(atPath: serviceBundle.path)
    }

    func setServiceBundleLink(_ destination: String?) throws {
        guard let destination else {
            if try exists(serviceBundle) { try remove(serviceBundle) }
            return
        }
        let temporary = root.appendingPathComponent(".service-\(UUID().uuidString)")
        do {
            try files.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
            guard Darwin.rename(temporary.path, serviceBundle.path) == 0 else {
                throw ServiceError("Cannot update service entry point: \(String(cString: strerror(errno)))")
            }
        } catch {
            try removeAfterFailure(temporary, error: error)
        }
    }

    func writeAgent(preserving previous: Data?) throws -> Bool {
        var properties = agentProperties
        if let previous {
            guard let existing = try PropertyListSerialization.propertyList(from: previous, format: nil) as? [String: Any] else {
                throw ServiceError("Invalid LaunchAgent property list: \(agent.path)")
            }
            for key in ["StandardOutPath", "StandardErrorPath"] {
                properties[key] = existing[key] as? String
            }
            if existing as NSDictionary == properties as NSDictionary {
                return false
            }
        }
        try ensureDirectory(agent.deletingLastPathComponent())
        let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
        return true
    }

    func remove(_ url: URL) throws { try files.removeItem(at: url) }

    func ownsService(at path: String) -> Bool {
        if path == service.path { return true }
        var packages = [packageDirectory]
        if let selected = try? selectedExecutable() {
            packages.append(selected.deletingLastPathComponent().deletingLastPathComponent())
        }
        let service = URL(fileURLWithPath: path).standardizedFileURL
        for package in packages {
            for schema in [1, 2] {
                let executable = package.appendingPathComponent(ReleasePackage.servicePath(schemaVersion: schema))
                if path == executable.path || path == executable.resolvingSymlinksInPath().path { return true }
            }
            let rack = package.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            // An already running process can retain an older Cellar path after opt moves.
            if rack.lastPathComponent == "custom-xcode-build-service", rack.deletingLastPathComponent().lastPathComponent == "Cellar" {
                let components = service.pathComponents
                let prefix = rack.pathComponents
                let suffix = ["libexec"] + ReleasePackage.servicePath(schemaVersion: 2).split(separator: "/").map(String.init)
                if components.count == prefix.count + 1 + suffix.count,
                   Array(components.prefix(prefix.count)) == prefix,
                   Array(components.suffix(suffix.count)) == suffix { return true }
            }
        }
        return [1, 2].contains { schemaVersion in
            let relativePath = ReleasePackage.servicePath(schemaVersion: schemaVersion)
            var version = service
            for _ in relativePath.split(separator: "/") { version.deleteLastPathComponent() }
            return (version == current || version.deletingLastPathComponent().path == versions.path)
                && path == version.appendingPathComponent(relativePath).path
        }
    }

    func removePayloads() throws {
        for url in [serviceBundle, current, versions, staging, root.appendingPathComponent("activation.log")] {
            if try exists(url) { try remove(url) }
        }
        // Keep the lock inode and its owner marker: a waiting invocation may
        // already hold this inode open when uninstall finishes.
    }

    private func removeAfterFailure(_ url: URL, error: any Error) throws -> Never {
        do {
            if try exists(url) { try files.removeItem(at: url) }
        } catch let cleanupError {
            throw ServiceError("\(error)\nCleanup also failed for \(url.path): \(cleanupError)")
        }
        throw error
    }

    private func ensureDirectory(_ directory: URL) throws {
        guard directory.path.hasPrefix(home.path + "/") else {
            guard directory == home else { throw ServiceError("Installation path escapes the user's home.") }
            return
        }
        try ensureDirectory(directory.deletingLastPathComponent())
        if Darwin.mkdir(directory.path, 0o755) != 0 {
            let failure = errno
            guard failure == EEXIST else {
                throw ServiceError("Cannot create installation directory \(directory.path): \(String(cString: strerror(failure)))")
            }
            // User-configured parent links are allowed; managed payload directories stay within the owned root.
            let inspected = directory.path.hasPrefix(root.path + "/") ? directory : directory.resolvingSymlinksInPath()
            guard try files.attributesOfItem(atPath: inspected.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceError("Expected a directory: \(directory.path)")
            }
        }
    }
}
