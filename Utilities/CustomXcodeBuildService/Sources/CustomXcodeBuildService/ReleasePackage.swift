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

struct ReleasePackage {
    struct Manifest: Codable {
        struct Dependency: Codable {
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
    static func servicePath(schemaVersion: Int) -> String {
        schemaVersion == 1 ? "libexec/swift-build/SWBBuildServiceBundle"
            : "libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle"
    }
    var service: URL { directory.appendingPathComponent(Self.servicePath(schemaVersion: manifest.schemaVersion)) }
    var resources: URL {
        directory.appendingPathComponent(manifest.schemaVersion == 1
            ? "libexec/swift-build" : "libexec/swift-build/SWBBuildService.bundle")
    }
    var hostPlugin: URL {
        resources.appendingPathComponent("PlugIns/HostPlatformPlugins.bundle/Contents/MacOS/HostPlatformPlugins")
    }

    init(directory: URL) throws {
        let files = FileManager.default
        let directory = directory.standardizedFileURL
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ServiceError("Package must be an extracted directory: \(directory.path)")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard [1, 2].contains(manifest.schemaVersion),
              Self.matches(manifest.version, "^[A-Za-z0-9][A-Za-z0-9._-]*$"),
              !manifest.resourceBundles.isEmpty,
              manifest.resourceBundles.allSatisfy({ Self.matches($0, "^SwiftBuild_[A-Za-z0-9_]+\\.bundle$") }) else {
            throw ServiceError("Invalid or unsupported release manifest in \(directory.path).")
        }
        self.directory = directory
        self.manifest = manifest
    }

    func validateForUse() throws {
        let files = FileManager.default
        for executable in [executable, service] + (manifest.schemaVersion == 2 ? [hostPlugin] : []) {
            guard try files.attributesOfItem(atPath: executable.path)[.type] as? FileAttributeType == .typeRegular,
                  files.isExecutableFile(atPath: executable.path) else {
                throw ServiceError("Missing executable: \(executable.path)")
            }
        }
        for resource in manifest.resourceBundles {
            let bundle = resources.appendingPathComponent(resource)
            guard try files.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType == .typeDirectory,
                  !(try files.contentsOfDirectory(atPath: bundle.path)).isEmpty else {
                throw ServiceError("Missing or empty resource bundle: \(resource)")
            }
        }
        if manifest.schemaVersion == 2 {
            for plist in [resources.appendingPathComponent("Info.plist"), hostPlugin.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")] {
                guard try files.attributesOfItem(atPath: plist.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw ServiceError("Missing bundle property list: \(plist.path)")
                }
            }
        }
    }

    func validateForInstallation() throws {
        try validateForUse()
        try Self.validateTree(directory)
    }

    func matchesInstalledContents(at installedDirectory: URL) throws -> Bool {
        let files = FileManager.default
        for path in try files.subpathsOfDirectory(atPath: directory.path) {
            let source = directory.appendingPathComponent(path)
            let installed = installedDirectory.appendingPathComponent(path)
            let sourceType = try files.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
            let installedType: FileAttributeType?
            do {
                installedType = try files.attributesOfItem(atPath: installed.path)[.type] as? FileAttributeType
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return false
            }
            guard sourceType == installedType else { return false }
            if sourceType != .typeDirectory && !files.contentsEqual(atPath: source.path, andPath: installed.path) {
                return false
            }
        }
        return true
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
