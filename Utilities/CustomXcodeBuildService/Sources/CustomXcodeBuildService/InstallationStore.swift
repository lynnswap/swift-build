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
    private let files = FileManager.default
    var root: URL { home.appendingPathComponent("Library/Developer/CustomXcodeBuildService") }
    var versions: URL { root.appendingPathComponent("versions") }
    var staging: URL { root.appendingPathComponent("staging") }
    var current: URL { root.appendingPathComponent("current") }
    var command: URL { home.appendingPathComponent(".local/bin/custom-xcode-build-service") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    var persistentExecutable: URL { current.appendingPathComponent("bin/custom-xcode-build-service") }

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
        let descriptor = Darwin.open(root.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ServiceError("Cannot open installation lock: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceError("Cannot lock installation: \(String(cString: strerror(errno)))") }
        defer { flock(descriptor, LOCK_UN) }
        if access != .read { try discardStaging() }
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
            if try exists(candidate) { try files.removeItem(at: candidate) }
            throw error
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

    func selectedPackage() throws -> ReleasePackage? {
        guard try exists(root) else { return nil }
        try requireOwnership()
        guard try exists(current) else { return nil }
        let destination = try files.destinationOfSymbolicLink(atPath: current.path)
        let selected = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : root.appendingPathComponent(destination)).standardizedFileURL
        guard selected.deletingLastPathComponent().path == versions.path else {
            throw ServiceError("The current link points outside the installation's versions directory.")
        }
        let package = try ReleasePackage(directory: selected)
        guard selected.lastPathComponent == package.manifest.version else {
            throw ServiceError("The selected release's directory and manifest version differ.")
        }
        return package
    }

    func validateExternalPaths() throws {
        if try exists(command) {
            guard try files.destinationOfSymbolicLink(atPath: command.path) == persistentExecutable.path else {
                throw ServiceError("Refusing to overwrite an unrelated command: \(command.path)")
            }
        }
        if try exists(agent) {
            guard try files.attributesOfItem(atPath: agent.path)[.type] as? FileAttributeType == .typeRegular,
                  let actual = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? NSDictionary,
                  actual == agentProperties as NSDictionary else {
                throw ServiceError("Refusing to overwrite an unrelated LaunchAgent: \(agent.path)")
            }
        }
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

    func stage(_ package: ReleasePackage) throws -> ReleasePackage {
        try ensureDirectory(versions)
        let destination = versions.appendingPathComponent(package.manifest.version)
        if try exists(destination) {
            let installed = try ReleasePackage(directory: destination)
            guard installed.manifest == package.manifest,
                  files.contentsEqual(atPath: destination.path, andPath: package.directory.path) else {
                throw ServiceError("Version \(package.manifest.version) is already installed with different contents. Publish a new version.")
            }
            return installed
        }
        try ensureDirectory(staging)
        let stagedPackage = staging.appendingPathComponent("package-\(UUID().uuidString)")
        do {
            try files.copyItem(at: package.directory, to: stagedPackage)
            _ = try ReleasePackage(directory: stagedPackage)
            guard Darwin.renamex_np(stagedPackage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw ServiceError("Cannot publish installed release: \(String(cString: strerror(errno)))")
            }
        } catch {
            if try exists(stagedPackage) { try files.removeItem(at: stagedPackage) }
            throw error
        }
        return try ReleasePackage(directory: destination)
    }

    func select(_ package: ReleasePackage?) throws {
        guard let package else {
            if try exists(current) { try files.removeItem(at: current) }
            return
        }
        try ensureDirectory(staging)
        let temporary = staging.appendingPathComponent("current-\(UUID().uuidString)")
        try files.createSymbolicLink(atPath: temporary.path, withDestinationPath: "versions/\(package.manifest.version)")
        if Darwin.rename(temporary.path, current.path) != 0 {
            let failure = errno
            try files.removeItem(at: temporary)
            throw ServiceError("Cannot select release: \(String(cString: strerror(failure)))")
        }
    }

    func writeCommand() throws {
        try ensureDirectory(command.deletingLastPathComponent())
        try files.createSymbolicLink(atPath: command.path, withDestinationPath: persistentExecutable.path)
    }

    func writeAgent() throws {
        try ensureDirectory(agent.deletingLastPathComponent())
        let data = try PropertyListSerialization.data(fromPropertyList: agentProperties, format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    }

    func remove(_ url: URL) throws { try files.removeItem(at: url) }

    func validateRemoval() throws {
        try requireOwnership()
        let expected: Set<String> = [".owner", ".lock", "versions", "current", "staging", "activation.log"]
        guard Set(try files.contentsOfDirectory(atPath: root.path)).isSubset(of: expected) else {
            throw ServiceError("The installation contains unrecognized files; refusing to delete it: \(root.path)")
        }
        _ = try ownedServicePaths()
    }

    func ownedServicePaths() throws -> Set<String> {
        guard try exists(versions) else { return [] }
        var services: Set<String> = []
        for name in try files.contentsOfDirectory(atPath: versions.path) {
            let package = try ReleasePackage(directory: versions.appendingPathComponent(name))
            guard package.manifest.version == name else { throw ServiceError("Unrecognized installed release: \(name)") }
            services.insert(package.service.path)
        }
        return services
    }

    func removePayloads() throws {
        for url in [current, versions, staging, root.appendingPathComponent("activation.log")] {
            if try exists(url) { try remove(url) }
        }
        // Keep the lock inode and its owner marker: a waiting invocation may
        // already hold this inode open when uninstall finishes.
    }

    private func discardStaging() throws {
        guard try exists(staging) else { return }
        guard try files.attributesOfItem(atPath: staging.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ServiceError("Refusing an unrecognized staging path: \(staging.path)")
        }
        // Only the lock holder writes here; after an interruption these bytes
        // are disposable and must never be interpreted as installed versions.
        try files.removeItem(at: staging)
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
            guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceError("Expected a directory, not a file or symbolic link: \(directory.path)")
            }
        }
    }
}
