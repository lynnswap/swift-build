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

struct LaunchEnvironment {
    struct Settings {
        let service: String?
        let concurrentResolution: String?
        let legacyService: String?

        // Earlier releases set DisableConcurrentDependencyResolution=0 together with the
        // service path, which overrode the user's Swift Build defaults. launchd does not
        // record who set a value, so a 0 the user set next to the service path also counts
        // as legacy; other values stay. Delete this once those releases are no longer in use.
        var hasLegacyConcurrentResolution: Bool { service != nil && concurrentResolution == "0" }

        func requireOwnership(in store: InstallationStore) throws {
            guard legacyService == nil else {
                throw ServiceError("SWBBUILDSERVICE_PATH is already set. Remove that override before using this command.")
            }
            if let service {
                guard store.ownsService(at: service) else {
                    throw ServiceError("XCBBUILDSERVICE_PATH belongs to another setup: \(service). Remove that override first.")
                }
            }
        }
    }

    let runner: any ProcessRunning
    let userID: UInt32
    var domain: String { "gui/\(userID)" }
    var job: String { "\(domain)/\(InstallationStore.label)" }

    func runAsUser(_ executable: String, arguments: [String]) throws -> Int32 {
        guard userID != 0 else { throw ServiceError("A non-root installation user is required.") }
        // An explicit sudo invocation drops credentials before touching user files.
        return try runner.runAttached("/usr/bin/sudo", ["-H", "-u", "#\(userID)", "--", executable] + arguments)
    }

    func settings(inBackground: Bool = false) throws -> Settings {
        try Settings(service: value("XCBBUILDSERVICE_PATH", inBackground: inBackground), concurrentResolution: value("DisableConcurrentDependencyResolution", inBackground: inBackground), legacyService: value("SWBBUILDSERVICE_PATH", inBackground: inBackground))
    }

    private func value(_ key: String, inBackground: Bool) throws -> String? {
        let output = try command(["getenv", key], inBackground: inBackground)
        let value = output.hasSuffix("\n") ? String(output.dropLast()) : output
        return value.isEmpty ? nil : value
    }

    func set(_ key: String, to value: String?, inBackground: Bool = false) throws {
        _ = try command(value.map { ["setenv", key, $0] } ?? ["unsetenv", key], inBackground: inBackground)
    }

    func isLoaded() throws -> Bool {
        let result = try runner.run("/bin/launchctl", ["print", job])
        // launchctl reports BOOTSTRAP_UNKNOWN_SERVICE (113) for an absent job.
        if result.status == 113 { return false }
        _ = try result.requireSuccess("launchctl print \(job)")
        return true
    }

    func bootstrap(_ agent: URL) throws {
        _ = try runner.run("/bin/launchctl", ["bootstrap", domain, agent.path]).requireSuccess("launchctl bootstrap \(domain)")
    }

    func bootout() throws {
        _ = try runner.run("/bin/launchctl", ["bootout", job]).requireSuccess("launchctl bootout \(job)")
    }

    private func command(_ arguments: [String], inBackground: Bool) throws -> String {
        let result = try runner.runInSession("/bin/launchctl", arguments, session: inBackground ? .background : .gui, userID: userID)
        return try result.requireSuccess("\(inBackground ? "Background " : "")launchctl \(arguments.first ?? "")")
    }
}
