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

struct ProcessResult {
    let status: Int32
    let output: String

    func requireSuccess(_ command: String) throws -> String {
        guard status == 0 else { throw ServiceError("\(command) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return output
    }
}

protocol ProcessRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
    func runAttached(_ executable: String, _ arguments: [String]) throws -> Int32
}

struct ProcessRunner: ProcessRunning {
    func runAttached(_ executable: String, _ arguments: [String]) throws -> Int32 {
        var argv = ([executable] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        argv.append(nil)
        var pid: pid_t = 0
        // Foundation.Process creates a separate process group. Interactive sudo
        // must inherit our foreground group and controlling terminal instead.
        let error = posix_spawn(&pid, executable, nil, nil, &argv, environ)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        var information = siginfo_t()
        while waitid(P_PID, id_t(pid), &information, WEXITED) != 0 {
            let error = errno
            if error == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return information.si_code == CLD_EXITED ? information.si_status : 128 + information.si_status
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        // A single drained pipe prevents either output stream from blocking the child.
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
