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
    func runInBackground(_ executable: String, _ arguments: [String], userID: UInt32) throws -> ProcessResult
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

extension ProcessRunner {
    func runInBackground(_ executable: String, _ arguments: [String], userID: UInt32) throws -> ProcessResult {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("custom-build-environment-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let label = "io.github.lynnswap.custom-xcode-build-service.environment.\(UUID().uuidString)"
        let domain = "user/\(userID)"
        let job = "\(domain)/\(label)"
        var loaded = false
        let result: Result<ProcessResult, any Error>
        do {
            let output = directory.appendingPathComponent("output")
            let completion = directory.appendingPathComponent("completion")
            guard mkfifo(completion.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let reader = open(completion.path, O_RDONLY | O_NONBLOCK)
            guard reader >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(reader) }
            // A writer prevents EOF while launchd is starting the one-shot job.
            let writer = open(completion.path, O_WRONLY | O_NONBLOCK)
            guard writer >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(writer) }

            // Arguments stay separate from shell source, including paths with spaces.
            let script = """
            output=$1
            completion=$2
            shift 2
            "$@" > "$output" 2>&1
            command_status=$?
            printf '%s\\n' "$command_status" > "$completion"
            """
            let properties: [String: Any] = [
                "Label": label,
                "LimitLoadToSessionType": "Background",
                "ProgramArguments": ["/bin/sh", "-c", script, "launchd-environment", output.path, completion.path, executable] + arguments,
                "RunAtLoad": true,
            ]
            let agent = directory.appendingPathComponent("environment.plist")
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: agent)
            _ = try run("/bin/launchctl", ["bootstrap", domain, agent.path]).requireSuccess("launchctl bootstrap \(domain)")
            loaded = true

            // launchd owns this child, so wait for its completion pipe rather than waitpid.
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let deadline = Date().addingTimeInterval(30)
            var ready: Int32
            repeat {
                ready = poll(&descriptor, 1, Int32(max(0, deadline.timeIntervalSinceNow * 1_000)))
            } while ready < 0 && errno == EINTR
            guard ready >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                throw ServiceError("Timed out waiting for Background command in \(job).")
            }
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = read(reader, &buffer, buffer.count)
            guard count > 0, let status = Int32(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ServiceError("Cannot read Background command exit status from \(job).")
            }
            result = .success(ProcessResult(status: status, output: String(decoding: try Data(contentsOf: output), as: UTF8.self)))
        } catch {
            result = .failure(error)
        }

        var failures: [String] = []
        if loaded {
            do { _ = try run("/bin/launchctl", ["bootout", job]).requireSuccess("launchctl bootout \(job)") }
            catch { failures.append(String(describing: error)) }
        }
        do { try files.removeItem(at: directory) }
        catch { failures.append("Removing \(directory.path): \(error)") }
        if !failures.isEmpty {
            let operation: String
            switch result {
            case .success(let value): operation = "Background command finished (\(value.status)): \(value.output)"
            case .failure(let error): operation = String(describing: error)
            }
            throw ServiceError("\(operation)\nBackground command cleanup failed: \(failures.joined(separator: "; "))")
        }
        return try result.get()
    }
}
