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

enum BuildService: String {
    case custom
    case bundled
}

enum Command: Equatable {
    case install(package: String?)
    case use(BuildService)
    case status
    case uninstall
    case activate
    case reload
    case help

    init(arguments: [String]) throws {
        switch arguments {
        case [], ["--help"], ["-h"], ["help"]: self = .help
        case ["install"]: self = .install(package: nil)
        case ["use", "custom"]: self = .use(.custom)
        case ["use", "bundled"]: self = .use(.bundled)
        case ["status"]: self = .status
        case ["uninstall"]: self = .uninstall
        case ["activate"]: self = .activate
        case ["reload"]: self = .reload
        default:
            guard arguments.count == 3, arguments[0] == "install", arguments[1] == "--package",
                  !arguments[2].isEmpty, !arguments[2].hasPrefix("-") else {
                throw ServiceError("Invalid arguments. Run custom-xcode-build-service --help.")
            }
            self = .install(package: arguments[2])
        }
    }

    static let helpText = """
    Manage the prebuilt custom Xcode build service from lynnswap/swift-build.

    Usage:
      custom-xcode-build-service install [--package DIRECTORY]
      custom-xcode-build-service use custom
      custom-xcode-build-service use bundled
      custom-xcode-build-service status
      custom-xcode-build-service uninstall
      custom-xcode-build-service activate
      custom-xcode-build-service reload

    install    Validate and install an extracted release package. Without --package,
               use the package containing this executable. Select custom and reload
               managed services when custom was already selected. Otherwise, report
               that clients must restart to inherit the new selection. No source build occurs.
    use custom   Select the installed custom service, including after login.
    use bundled  Select Xcode's bundled service, keeping the CLI and installed payload.
    status     Show the installed release, selected service, launchd settings,
               and running services.
    uninstall  Remove owned settings and the installed payload. Quit Xcode first.
    activate   Reapply custom at login if selected (used by the LaunchAgent).
    reload     Redirect legacy installation paths and stop only this user's managed
               build services. Open Xcode clients start the updated service on demand.

    Installing or selecting custom requires Apple Silicon and macOS 26 or later.
    A macOS desktop login is required for the invoking user. In an Aqua session,
    installation needs no sudo. From a Background session, the command requests
    administrator authentication to enter your desktop session, then runs as you.
    Status reports the information available without requesting authentication;
    use sudo with the full executable path to inspect GUI settings from Background.
    Selection affects future processes for this macOS user account.
    Updating an already selected custom service reloads it automatically; Xcode can
    remain open. In-flight service requests may fail and need to be retried.
    After initially selecting custom, switching to bundled, or uninstalling, restart
    Xcode, Xcode Service (for MCP), terminal applications, and AI agents to refresh their environment.
    If macOS restores Xcode before the login job runs, quit and reopen Xcode.
    """
}

struct ServiceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
