import Darwin
import Foundation

@main
struct CustomXcodeBuildService {
    static func main() {
        do {
            let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
            if command == .help { print(Command.helpText); return }
            let runner = ProcessRunner()
            let manager = InstallationManager(
                store: InstallationStore(home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()),
                environment: LaunchEnvironment(runner: runner, userID: getuid())
            )
            let output: String
            switch command {
            case .install(let package):
                let directory: URL
                if let package {
                    directory = URL(fileURLWithPath: package).standardizedFileURL
                } else {
                    var size: UInt32 = 0
                    _ = _NSGetExecutablePath(nil, &size)
                    var buffer = [CChar](repeating: 0, count: Int(size))
                    guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw ServiceError("Cannot locate this executable. Pass --package DIRECTORY.") }
                    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                }
                output = try manager.install(from: directory)
            case .status: output = try manager.status()
            case .uninstall: output = try manager.uninstall()
            case .activate: output = try manager.activate()
            case .help: output = Command.helpText
            }
            print(output)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
