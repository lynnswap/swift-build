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

        func requireOwnership(among ownedServices: Set<String>) throws {
            guard legacyService == nil else {
                throw ServiceError("SWBBUILDSERVICE_PATH is already set. Remove that override before using this command.")
            }
            if let service {
                guard ownedServices.contains(service) else {
                    throw ServiceError("XCBBUILDSERVICE_PATH belongs to another setup: \(service). Remove that override first.")
                }
                guard concurrentResolution == nil || concurrentResolution == "0" else {
                    throw ServiceError("DisableConcurrentDependencyResolution was changed outside this installation. Remove that override first.")
                }
            } else if concurrentResolution != nil {
                throw ServiceError("DisableConcurrentDependencyResolution is already set without an owned service. Remove that override first.")
            }
        }
    }

    let runner: any ProcessRunning
    let userID: UInt32
    var domain: String { "gui/\(userID)" }
    var job: String { "\(domain)/\(InstallationStore.label)" }

    func requireGUI() throws { _ = try command(["print", domain]) }

    func settings() throws -> Settings {
        try Settings(service: value("XCBBUILDSERVICE_PATH"), concurrentResolution: value("DisableConcurrentDependencyResolution"), legacyService: value("SWBBUILDSERVICE_PATH"))
    }

    private func value(_ key: String) throws -> String? {
        let output = try command(["getenv", key])
        let value = output.hasSuffix("\n") ? String(output.dropLast()) : output
        return value.isEmpty ? nil : value
    }

    func set(_ key: String, to value: String?) throws {
        _ = try command(value.map { ["setenv", key, $0] } ?? ["unsetenv", key])
    }

    func isLoaded() throws -> Bool {
        let result = try runner.run("/bin/launchctl", ["print", job])
        // launchctl reports BOOTSTRAP_UNKNOWN_SERVICE (113) for an absent job.
        if result.status == 113 { return false }
        _ = try result.requireSuccess("launchctl print \(job)")
        return true
    }

    func bootstrap(_ agent: URL) throws { _ = try command(["bootstrap", domain, agent.path]) }
    func bootout() throws { _ = try command(["bootout", job]) }

    private func command(_ arguments: [String]) throws -> String {
        try runner.run("/bin/launchctl", arguments).requireSuccess("launchctl \(arguments.first ?? "")")
    }
}
