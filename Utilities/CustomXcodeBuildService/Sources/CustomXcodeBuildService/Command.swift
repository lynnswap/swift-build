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

    install    Validate and install an extracted release package. Without --package,
               use the package containing this executable. First install selects
               custom; updates preserve the service selection. No source build occurs.
    use custom   Select the installed custom service, including after login.
    use bundled  Select Xcode's bundled service, keeping the CLI and installed releases.
    status     Show the installed release, selected service, launchd settings,
               and running services.
    uninstall  Remove owned settings and installed releases. Quit Xcode first.
    activate   Reapply custom at login if selected (used by the LaunchAgent).

    Installing or selecting custom requires Apple Silicon, macOS 26, and the exact
    Xcode 27 build in the manifest. Selecting bundled does not require a compatible Xcode.
    Do not use sudo. Selection affects future processes for this macOS user account.
    After installing, updating, switching, or uninstalling, quit and reopen Xcode,
    terminal applications, and AI agent applications. Start terminal-based agents
    from the restarted terminal. No applications or builds are stopped by this tool.
    If macOS restores Xcode before the login job runs, quit and reopen Xcode.
    """
}

struct ServiceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
