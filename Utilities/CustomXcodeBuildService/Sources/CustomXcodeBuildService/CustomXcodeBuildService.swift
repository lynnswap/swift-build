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

@main
struct CustomXcodeBuildService {
    static func main() {
        do {
            let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
            if command == .help { print(Command.helpText); return }
            let runner = ProcessRunner()
            let currentUserID = getuid()
            let userID = try installationUserID(currentUserID: currentUserID, sudoUserID: ProcessInfo.processInfo.environment["SUDO_UID"])
            let environment = LaunchEnvironment(runner: runner, userID: userID)
            if currentUserID == 0 {
                exit(try relaunch(command, in: environment, currentUserID: currentUserID))
            }
            let manager = InstallationManager(
                store: InstallationStore(home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()),
                environment: environment
            )
            do { print(try run(command, manager: manager)) }
            catch is LaunchEnvironment.GUIRequired {
                FileHandle.standardError.write(Data("Entering your macOS desktop session. Administrator authentication may be required; installation runs as your user.\n".utf8))
                exit(try relaunch(command, in: environment, currentUserID: currentUserID))
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ command: Command, manager: InstallationManager) throws -> String {
        switch command {
        case .install(let package):
            let directory: URL
            if let package {
                directory = URL(fileURLWithPath: package).standardizedFileURL
            } else {
                directory = try executableURL().deletingLastPathComponent().deletingLastPathComponent()
            }
            return try manager.install(from: directory)
        case .use(let service): return try manager.use(service)
        case .status: return try manager.status()
        case .uninstall: return try manager.uninstall()
        case .activate: return try manager.activate()
        case .help: return Command.helpText
        }
    }

    private static func relaunch(_ command: Command, in environment: LaunchEnvironment, currentUserID: UInt32) throws -> Int32 {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if case .install(let package?) = command {
            arguments = ["install", "--package", URL(fileURLWithPath: package).standardizedFileURL.path]
        }
        return try environment.runInGUI(executableURL().path, arguments: arguments, currentUserID: currentUserID)
    }

    static func installationUserID(currentUserID: UInt32, sudoUserID: String?) throws -> UInt32 {
        guard currentUserID == 0 else { return currentUserID }
        guard let sudoUserID, let userID = UInt32(sudoUserID), userID != 0 else {
            throw ServiceError("Run using sudo from your logged-in user account; a root login has no installation user.")
        }
        return userID
    }

    private static func executableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw ServiceError("Cannot locate this executable.") }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}
