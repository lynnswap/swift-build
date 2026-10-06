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
    case use(BuildService, reload: Bool = false)
    case status
    case version
    case uninstall
    case activate
    case migrateStandalone
    case reload
    case help

    init(arguments: [String]) throws {
        switch arguments {
        case [], ["--help"], ["-h"], ["help"]: self = .help
        case ["use", "custom"]: self = .use(.custom)
        case ["use", "custom", "--reload"]: self = .use(.custom, reload: true)
        case ["use", "bundled"]: self = .use(.bundled)
        case ["status"]: self = .status
        case ["--version"]: self = .version
        case ["uninstall"]: self = .uninstall
        case ["__migrate-standalone"]: self = .migrateStandalone
        case ["activate"]: self = .activate
        case ["reload"]: self = .reload
        default: throw ServiceError("Invalid arguments. Run custom-xcode-build-service --help.")
        }
    }

    static let helpText = """
    Select the custom Xcode build service from lynnswap/swift-build.

    Usage:
      custom-xcode-build-service use custom [--reload]
      custom-xcode-build-service use bundled
      custom-xcode-build-service status
      custom-xcode-build-service --version
      custom-xcode-build-service reload
      custom-xcode-build-service uninstall
      custom-xcode-build-service activate

    Homebrew and mise install the CLI and service together.
    Homebrew:
      brew install lynnswap/tap/custom-xcode-build-service

    mise (use the version pinned in your project's mise.toml and mise.lock):
      mise install --locked github:lynnswap/swift-build
      mise exec -- custom-xcode-build-service use custom

    Invoke the CLI from the package you want to select.
    Setup migrates this tool's old standalone CLI link and settings.

    After installing another version, finish builds and run its CLI with:
      custom-xcode-build-service use custom --reload

    use custom   Select this packaged service, including after login.
    --reload     Also stop previous custom services when selecting a different package.
    use bundled  Restore Xcode's bundled service and remove the login helper.
    status       Show the packaged release, selection, and running services.
    reload       Restart this user's managed custom services without changing selection.
    uninstall    Remove user settings and legacy standalone files. Quit Xcode first.
                 Packaged files remain; remove them with Homebrew or mise.
    activate     Reapply the saved custom selection at login.

    Selection requires a desktop login. From a Background session, the command
    requests administrator authentication, enters that session, then runs as you.
    Status never requests authentication. Use sudo with its full path for GUI status.
    After switching services, restart Xcode, Xcode Service (for MCP), terminal
    applications, and AI agents so they inherit the new selection.
    Interrupted requests may need to be retried. Installing or upgrading does
    not change your selection.
    """
}

struct ServiceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
