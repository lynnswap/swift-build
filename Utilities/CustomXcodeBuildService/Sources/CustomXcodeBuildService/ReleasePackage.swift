import Foundation

struct ReleasePackage {
    struct Manifest: Codable, Equatable {
        struct Dependency: Codable, Equatable {
            let identity: String
            let revision: String
        }
        let schemaVersion: Int
        let version: String
        let sourceRevision: String
        let xcodeVersion: String
        let xcodeBuildVersion: String
        let architecture: String
        let minimumMacOSVersion: String
        let resourceBundles: [String]
        let dependencies: [Dependency]
    }

    let directory: URL
    let manifest: Manifest
    var executable: URL { directory.appendingPathComponent("bin/custom-xcode-build-service") }
    var service: URL { directory.appendingPathComponent("libexec/swift-build/SWBBuildServiceBundle") }

    init(directory: URL) throws {
        let files = FileManager.default
        let directory = directory.standardizedFileURL
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ServiceError("Package must be an extracted directory: \(directory.path)")
        }
        try Self.validateTree(directory)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == 1,
              Self.matches(manifest.version, "^custom-v[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$"),
              Self.matches(manifest.sourceRevision, "^[a-fA-F0-9]{40}$"),
              Self.matches(manifest.xcodeVersion, "^27(?:\\.[0-9]+){0,2}$"),
              Self.matches(manifest.xcodeBuildVersion, "^27[A-Za-z0-9]+$"),
              manifest.architecture == "arm64", manifest.minimumMacOSVersion == "26.0",
              !manifest.resourceBundles.isEmpty,
              Set(manifest.resourceBundles).count == manifest.resourceBundles.count,
              manifest.resourceBundles.allSatisfy({ Self.matches($0, "^SwiftBuild_[A-Za-z0-9_]+\\.bundle$") }),
              !manifest.dependencies.isEmpty,
              Set(manifest.dependencies.map(\.identity)).count == manifest.dependencies.count,
              manifest.dependencies.allSatisfy({ Self.matches($0.identity, "^[a-zA-Z0-9_-]+$") && Self.matches($0.revision, "^[a-fA-F0-9]{40}$") }) else {
            throw ServiceError("Invalid or unsupported release manifest in \(directory.path).")
        }
        let actual = try files.contentsOfDirectory(atPath: directory.path)
        guard Set(actual) == ["manifest.json", "bin", "libexec", "licenses"],
              try files.contentsOfDirectory(atPath: directory.appendingPathComponent("bin").path) == ["custom-xcode-build-service"],
              try files.contentsOfDirectory(atPath: directory.appendingPathComponent("libexec").path) == ["swift-build"],
              Set(try files.contentsOfDirectory(atPath: directory.appendingPathComponent("libexec/swift-build").path)) == Set(manifest.resourceBundles + ["SWBBuildServiceBundle"]),
              !(try files.contentsOfDirectory(atPath: directory.appendingPathComponent("licenses").path)).isEmpty else {
            throw ServiceError("Release package layout does not match its manifest.")
        }
        self.directory = directory
        self.manifest = manifest
        for executable in [executable, service] {
            guard try files.attributesOfItem(atPath: executable.path)[.type] as? FileAttributeType == .typeRegular,
                  files.isExecutableFile(atPath: executable.path) else {
                throw ServiceError("Missing executable: \(executable.path)")
            }
        }
        for resource in manifest.resourceBundles {
            let bundle = directory.appendingPathComponent("libexec/swift-build/\(resource)")
            guard try files.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType == .typeDirectory,
                  !(try files.contentsOfDirectory(atPath: bundle.path)).isEmpty else {
                throw ServiceError("Missing or empty resource bundle: \(resource)")
            }
        }
    }

    func requireCompatibleHost(using runner: any ProcessRunning) throws {
        let architecture = try runner.run("/usr/bin/uname", ["-m"]).requireSuccess("uname").trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == manifest.architecture else { throw ServiceError("This release requires Apple Silicon (arm64).") }
        let version = try runner.run("/usr/bin/xcodebuild", ["-version"]).requireSuccess("xcodebuild -version")
        let lines = version.split(whereSeparator: \.isNewline).map(String.init)
        guard lines == ["Xcode \(manifest.xcodeVersion)", "Build version \(manifest.xcodeBuildVersion)"] else {
            throw ServiceError("This release requires Xcode \(manifest.xcodeVersion) (\(manifest.xcodeBuildVersion)). Selected Xcode: \(version.trimmingCharacters(in: .whitespacesAndNewlines)). Select the matching Xcode or install a compatible release.")
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func validateTree(_ directory: URL) throws {
        let files = FileManager.default
        for name in try files.contentsOfDirectory(atPath: directory.path) {
            let child = directory.appendingPathComponent(name)
            let attributes = try files.attributesOfItem(atPath: child.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory: try validateTree(child)
            case .typeRegular: break
            default: throw ServiceError("Release packages must contain only regular files and directories (no symbolic links): \(child.path)")
            }
        }
    }
}
