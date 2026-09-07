import Darwin
import Foundation

struct InstallationStore {
    static let label = "io.github.lynnswap.custom-xcode-build-service"
    private static let owner = "lynnswap/swift-build custom-xcode-build-service schema 1\n"
    let home: URL
    private let files = FileManager.default
    var root: URL { home.appendingPathComponent("Library/Developer/CustomXcodeBuildService") }
    var versions: URL { root.appendingPathComponent("versions") }
    var current: URL { root.appendingPathComponent("current") }
    var command: URL { home.appendingPathComponent(".local/bin/custom-xcode-build-service") }
    var agent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    var persistentExecutable: URL { current.appendingPathComponent("bin/custom-xcode-build-service") }

    func exists(_ url: URL) throws -> Bool {
        do { _ = try files.attributesOfItem(atPath: url.path); return true }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    func withLock<T>(create: Bool, _ operation: () throws -> T) throws -> T {
        if try !exists(root) {
            guard create else { return try operation() }
            try ensureDirectory(root.deletingLastPathComponent())
            try files.createDirectory(at: root, withIntermediateDirectories: false)
            try Data(Self.owner.utf8).write(to: root.appendingPathComponent(".owner"), options: .atomic)
        }
        try requireOwnership()
        let descriptor = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ServiceError("Cannot open installation lock: \(String(cString: strerror(errno)))") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceError("Cannot lock installation: \(String(cString: strerror(errno)))") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func requireOwnership() throws {
        guard try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory,
              try files.attributesOfItem(atPath: root.appendingPathComponent(".owner").path)[.type] as? FileAttributeType == .typeRegular,
              try String(contentsOf: root.appendingPathComponent(".owner"), encoding: .utf8) == Self.owner else {
            throw ServiceError("Refusing an unrecognized installation directory: \(root.path)")
        }
    }

    func selectedPackage() throws -> ReleasePackage? {
        guard try exists(root) else { return nil }
        try requireOwnership()
        guard try exists(current) else { return nil }
        let destination = try files.destinationOfSymbolicLink(atPath: current.path)
        let selected = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : root.appendingPathComponent(destination)).standardizedFileURL
        guard selected.deletingLastPathComponent().path == versions.path else {
            throw ServiceError("The current link points outside the installation's versions directory.")
        }
        let package = try ReleasePackage(directory: selected)
        guard selected.lastPathComponent == package.manifest.version else {
            throw ServiceError("The selected release's directory and manifest version differ.")
        }
        return package
    }

    func validateExternalPaths() throws {
        if try exists(command) {
            guard try files.destinationOfSymbolicLink(atPath: command.path) == persistentExecutable.path else {
                throw ServiceError("Refusing to overwrite an unrelated command: \(command.path)")
            }
        }
        if try exists(agent) {
            guard try files.attributesOfItem(atPath: agent.path)[.type] as? FileAttributeType == .typeRegular,
                  let actual = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? NSDictionary,
                  actual == agentProperties as NSDictionary else {
                throw ServiceError("Refusing to overwrite an unrelated LaunchAgent: \(agent.path)")
            }
        }
    }

    var agentProperties: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [persistentExecutable.path, "activate"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": root.appendingPathComponent("activation.log").path,
            "StandardErrorPath": root.appendingPathComponent("activation.log").path,
        ]
    }

    func stage(_ package: ReleasePackage) throws -> ReleasePackage {
        try ensureDirectory(versions)
        let destination = versions.appendingPathComponent(package.manifest.version)
        if try exists(destination) {
            let installed = try ReleasePackage(directory: destination)
            guard installed.manifest == package.manifest,
                  files.contentsEqual(atPath: destination.path, andPath: package.directory.path) else {
                throw ServiceError("Version \(package.manifest.version) is already installed with different contents. Publish a new version.")
            }
            return installed
        }
        let staging = versions.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try files.copyItem(at: package.directory, to: staging)
            _ = try ReleasePackage(directory: staging)
            try files.moveItem(at: staging, to: destination)
        } catch {
            if try exists(staging) { try files.removeItem(at: staging) }
            throw error
        }
        return try ReleasePackage(directory: destination)
    }

    func select(_ package: ReleasePackage?) throws {
        guard let package else {
            if try exists(current) { try files.removeItem(at: current) }
            return
        }
        let temporary = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try files.createSymbolicLink(atPath: temporary.path, withDestinationPath: "versions/\(package.manifest.version)")
        if Darwin.rename(temporary.path, current.path) != 0 {
            let failure = errno
            try files.removeItem(at: temporary)
            throw ServiceError("Cannot select release: \(String(cString: strerror(failure)))")
        }
    }

    func writeCommand() throws {
        try ensureDirectory(command.deletingLastPathComponent())
        try files.createSymbolicLink(atPath: command.path, withDestinationPath: persistentExecutable.path)
    }

    func writeAgent() throws {
        try ensureDirectory(agent.deletingLastPathComponent())
        let data = try PropertyListSerialization.data(fromPropertyList: agentProperties, format: .xml, options: 0)
        try data.write(to: agent, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    }

    func remove(_ url: URL) throws { try files.removeItem(at: url) }

    func validateRemoval() throws {
        try requireOwnership()
        let expected: Set<String> = [".owner", ".lock", "versions", "current", "activation.log"]
        guard Set(try files.contentsOfDirectory(atPath: root.path)).isSubset(of: expected) else {
            throw ServiceError("The installation contains unrecognized files; refusing to delete it: \(root.path)")
        }
        _ = try ownedServicePaths()
    }

    func ownedServicePaths() throws -> Set<String> {
        guard try exists(versions) else { return [] }
        var services: Set<String> = []
        for name in try files.contentsOfDirectory(atPath: versions.path) {
            let package = try ReleasePackage(directory: versions.appendingPathComponent(name))
            guard package.manifest.version == name else { throw ServiceError("Unrecognized installed release: \(name)") }
            services.insert(package.service.path)
        }
        return services
    }

    func removePayloads() throws {
        for url in [current, versions, root.appendingPathComponent("activation.log")] {
            if try exists(url) { try remove(url) }
        }
        // Keep the lock inode and its owner marker: a waiting invocation may
        // already hold this inode open when uninstall finishes.
    }

    private func ensureDirectory(_ directory: URL) throws {
        guard directory.path.hasPrefix(home.path + "/") else {
            guard directory == home else { throw ServiceError("Installation path escapes the user's home.") }
            return
        }
        try ensureDirectory(directory.deletingLastPathComponent())
        if try exists(directory) {
            guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceError("Expected a directory, not a file or symbolic link: \(directory.path)")
            }
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }
}
