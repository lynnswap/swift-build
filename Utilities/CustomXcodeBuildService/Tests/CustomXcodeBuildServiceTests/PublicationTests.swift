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
import Dispatch
import Foundation
import Testing
@testable import CustomXcodeBuildService

@Test func competingRootPublisherPreservesExistingOwnerAndLock() throws {
    let fixture = try Fixture()
    try fixture.store.initializeRoot()
    let lock = fixture.store.root.appendingPathComponent(".lock")
    let inode = try #require(FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
    let contents = try Data(contentsOf: fixture.store.root.appendingPathComponent(".owner"))

    // The second publisher takes RENAME_EXCL's EEXIST path deterministically.
    try fixture.store.initializeRoot()

    #expect(try FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber == inode)
    #expect(try Data(contentsOf: fixture.store.root.appendingPathComponent(".owner")) == contents)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.deletingLastPathComponent().path) == ["CustomXcodeBuildService"])
}

@Test func simultaneousFirstInstallersObserveCompleteRootAndShareOneLock() throws {
    let fixture = try Fixture()
    let home = fixture.store.home
    let counter = fixture.directory.appendingPathComponent("counter")
    try fixture.write("0", to: counter)

    DispatchQueue.concurrentPerform(iterations: 16) { _ in
        let store = InstallationStore(home: home, packageDirectory: home.appendingPathComponent("unused-package"))
        do {
            try store.withInstallationLock {
                try store.requireOwnership()
                #expect(try store.exists(store.root.appendingPathComponent(".lock")))
                let value = try #require(Int(String(contentsOf: counter, encoding: .utf8)))
                try Data(String(value + 1).utf8).write(to: counter, options: .atomic)
            }
        } catch { Issue.record(error) }
    }

    #expect(try String(contentsOf: counter, encoding: .utf8) == "16")
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path)) == [".owner", ".lock"])
}

@Test func rootPublisherDoesNotReplaceForeignEmptyDirectory() throws {
    let fixture = try Fixture()
    try FileManager.default.createDirectory(at: fixture.store.root, withIntermediateDirectories: true)
    let inode = try #require(FileManager.default.attributesOfItem(atPath: fixture.store.root.path)[.systemFileNumber] as? NSNumber)
    #expect(throws: (any Error).self) { try fixture.store.initializeRoot() }
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.store.root.path)[.systemFileNumber] as? NSNumber == inode)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path).isEmpty)
}

@Test func incompleteUnpublishedRootDoesNotBlockInitialInstall() throws {
    let fixture = try Fixture()
    let abandoned = fixture.store.root.deletingLastPathComponent().appendingPathComponent(".CustomXcodeBuildService-initializing-abandoned")
    try fixture.write("incomplete initialization", to: abandoned.appendingPathComponent(".owner"))
    _ = try fixture.enable( fixture.package("v1.0.0"))
    #expect(try fixture.store.packagedRelease()?.manifest.version == "v1.0.0")
    #expect(try fixture.store.exists(fixture.store.root.appendingPathComponent(".lock")))
}

@Test(arguments: ["read", "modify"])
func absentInstallationDoesNotInvokeUnlockedCallback(access: String) throws {
    let fixture = try Fixture()
    var invoked = false
    let result = try fixture.store.withExistingLock(access: access == "read" ? .read : .modify) {
        invoked = true
        try fixture.store.initializeRoot()
        return "ran without a published lock"
    }
    #expect(result == nil)
    #expect(!invoked)
    #expect(try !fixture.store.exists(fixture.store.root))
}

@Test func concurrentFirstInstallAndUninstallCallbacksAlwaysHoldPublishedLock() throws {
    let fixture = try Fixture()
    let home = fixture.store.home
    let counter = fixture.directory.appendingPathComponent("mutations")
    try fixture.write("0", to: counter)

    DispatchQueue.concurrentPerform(iterations: 32) { index in
        let store = InstallationStore(home: home, packageDirectory: home.appendingPathComponent("unused-package"))
        let mutation = {
            let descriptor = Darwin.open(store.root.appendingPathComponent(".lock").path, O_RDWR)
            guard descriptor >= 0 else { throw ServiceError("Mutation ran before a lock was published.") }
            defer { Darwin.close(descriptor) }
            let result = flock(descriptor, LOCK_EX | LOCK_NB)
            let failure = errno
            #expect(result == -1 && failure == EWOULDBLOCK)
            let value = try #require(Int(String(contentsOf: counter, encoding: .utf8)))
            try Data(String(value + 1).utf8).write(to: counter, options: .atomic)
        }
        do {
            if index.isMultiple(of: 2) {
                try store.withInstallationLock(mutation)
            } else {
                _ = try store.withExistingLock(access: .modify, mutation)
            }
        } catch { Issue.record(error) }
    }

    let mutations = try #require(Int(String(contentsOf: counter, encoding: .utf8)))
    #expect((16...32).contains(mutations))
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path)) == [".owner", ".lock"])
}
