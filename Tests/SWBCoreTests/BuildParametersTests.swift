//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import SWBUtil
import SWBCore
import SWBProtocol
import SWBTestSupport

@Suite fileprivate struct BuildParametersTests {
    @Test
    func unchangedTransformationsPreserveParameters() {
        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .macOS, activeArchitecture: "arm64", overrides: ["FLAG": "YES"], commandLineOverrides: ["FLAG": "CLI"], toolchainOverride: "custom")
        let values = [parameters: "cached"]
        for transformed in [parameters.mergingOverrides([:]), parameters.mergingOverrides(["FLAG": "YES"]), parameters.replacing(activeRunDestination: .macOS, activeArchitecture: "arm64")] {
            #expect(transformed == parameters)
            #expect(values[transformed] == "cached")
        }

        let merged = parameters.mergingOverrides(["FLAG": "NO", "NEW": "VALUE"])
        #expect(merged.overrides == ["FLAG": "NO", "NEW": "VALUE"])
        #expect(merged.commandLineOverrides == parameters.commandLineOverrides)
        #expect(merged.toolchainOverride == parameters.toolchainOverride)
    }

    @Test
    func withoutOverridesClearsConfigurationFilePaths() {
        let parameters = BuildParameters(configuration: "Debug", commandLineConfigOverridesPath: Path("/tmp/Command.xcconfig"), environmentConfigOverridesPath: Path("/tmp/Environment.xcconfig"), toolchainOverride: "custom")
        let expected = BuildParameters(configuration: "Debug", toolchainOverride: "custom")
        let cleared = parameters.withoutOverrides
        #expect(cleared == expected)
        #expect([expected: "cached"][cleared.withoutOverrides] == "cached")
    }

    @Test(arguments: [false, true])
    func replacingUpdatesDestinationAndArchitectureIndependently(removesDestination: Bool) {
        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .macOS, activeArchitecture: "arm64", overrides: ["FLAG": "YES"])
        let destination: SWBCore.RunDestinationInfo? = removesDestination ? nil : .macOS
        let architecture: String? = removesDestination ? "arm64" : nil
        let replaced = parameters.replacing(activeRunDestination: destination, activeArchitecture: architecture)
        #expect(replaced.activeRunDestination == destination)
        #expect(replaced.activeArchitecture == architecture)
        #expect(replaced.overrides == parameters.overrides)
    }

    @Test
    func transformationsNormalizeDecodedPackageConfiguration() throws {
        let canonical = BuildParameters(configuration: "Debug")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical)) as? [String: Any])
        object["packageConfigurationOverride"] = "Release"
        let decoded = try JSONDecoder().decode(BuildParameters.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.packageConfigurationOverride == "Release")

        for transformed in [decoded.mergingOverrides([:]), decoded.withoutOverrides, decoded.replacing(activeRunDestination: nil, activeArchitecture: nil)] {
            #expect(transformed == canonical)
            #expect([canonical: "cached"][transformed] == "cached")
        }
    }

    @Test
    func serializationDoesNotContainUnstableHash() throws {
        let action = BuildAction.build
        let configuration = "Debug"
        let activeRunDestination = RunDestinationInfo(
            platform: "macosx",
            sdk: "macosx12.3",
            sdkVariant: "macos",
            targetArchitecture: "arm64",
            supportedArchitectures: ["arm64", "x86_64"],
            disableOnlyActiveArch: false
        )
        let activeArchitecture = "arm64"
        let overrides = [
            "ENABLE_PREVIEWS": "NO",
            "ONLY_ACTIVE_ARCH": "YES",
        ]
        let commandLineOverrides = overrides
        let commandLineConfigOverridesPath: Path? = nil
        let commandLineConfigOverrides = overrides
        let environmentConfigOverridesPath: Path? = nil
        let environmentConfigOverrides = overrides
        let toolchainOverride: String? = nil
        let arena = ArenaInfo.buildArena(derivedDataRoot: Path("/Users/username/Library/Developer/Xcode/DerivedData"), enableIndexDataStore: true)

        let bp = BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: overrides,
            commandLineOverrides: commandLineOverrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: commandLineConfigOverrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: environmentConfigOverrides,
            toolchainOverride: toolchainOverride,
            arena: arena
        )

        let data = try JSONEncoder().encode(bp)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("precomputedHash"), "The hash value isn't stable and shouldn't be encoded")

        let roundTrip = try JSONDecoder().decode(BuildParameters.self, from: data)
        #expect(bp == roundTrip)
    }
}
