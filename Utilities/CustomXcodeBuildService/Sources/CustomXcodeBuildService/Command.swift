import Foundation

enum Command: Equatable {
    case install(package: String?)
    case status
    case uninstall
    case activate
    case help

    init(arguments: [String]) throws {
        switch arguments {
        case [], ["--help"], ["-h"], ["help"]: self = .help
        case ["install"]: self = .install(package: nil)
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
      custom-xcode-build-service status
      custom-xcode-build-service uninstall
      custom-xcode-build-service activate

    install    Validate and install an extracted release package. Without --package,
               use the package containing this executable. No source build occurs.
    status     Show the selected release, launchd settings, and running services.
    uninstall  Remove owned settings and installed releases. Quit Xcode first.
    activate   Reapply the selected release at login (used by the LaunchAgent).

    Requires Apple Silicon, macOS 26, and the exact Xcode 27 build in the manifest.
    Do not use sudo. Activation affects all future GUI Xcode processes for this user.
    Quit and reopen Xcode after installing, updating, or uninstalling. Existing
    terminals do not inherit launchd changes. No Xcode processes are terminated.
    If macOS restores Xcode before the login job runs, quit and reopen Xcode.
    """
}

struct ServiceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
