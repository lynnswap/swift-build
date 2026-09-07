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
