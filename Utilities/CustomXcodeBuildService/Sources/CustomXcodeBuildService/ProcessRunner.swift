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
}

struct ProcessRunner: ProcessRunning {
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
