#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See http://swift.org/LICENSE.txt for license information
## See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

"""Distribution contract tests; no build or per-user installation is performed."""

import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release build tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "checkout"
        distribution = self.repository / release.DISTRIBUTION_PATH
        distribution.mkdir(parents=True)
        (distribution / "ServiceDependencies.resolved").write_text("committed dependency pins\n")
        (distribution / "release.py").write_text("committed staging implementation\n")
        (self.repository / "Package.swift").write_text("committed package\n")
        subprocess.run(["git", "init", "--quiet", str(self.repository)], check=True)
        subprocess.run(["git", "-C", str(self.repository), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repository), "-c", "user.name=Distribution Test",
                        "-c", "user.email=distribution-test@example.invalid", "-c", "commit.gpgsign=false",
                        "commit", "--quiet", "-m", "Fixture"], check=True)
        self.revision = release.output(["git", "-C", str(self.repository), "rev-parse", "HEAD"])
        (distribution / "ServiceDependencies.resolved").write_text("uncommitted dependency pins\n")
        (distribution / "release.py").write_text("uncommitted staging implementation\n")
        (self.repository / "Package.resolved").write_text("developer dependency pins\n")
        self.arguments = argparse.Namespace(version="custom-v1.2.3", output_dir=self.root / "output",
                                            revision="HEAD", jobs=2)
        self.commands = []
        self.run_process = subprocess.run
        self.process_environment = dict(os.environ)
        self.service_failure = False
        self.change_pins = False

    def run_command(self, command, **kwargs):
        environment = kwargs.get("env")
        self.commands.append((command, environment.copy() if environment is not None else None))
        if command[:2] == ["/usr/bin/xcode-select", "--print-path"]:
            return subprocess.CompletedProcess(command, 0, "/Applications/Selected Xcode.app/Contents/Developer\n")
        if command[:3] == ["/usr/bin/xcrun", "xcodebuild", "-version"]:
            return subprocess.CompletedProcess(command, 0, "Xcode 27.0\nBuild version 27A5252f\n")
        if command[:2] == ["/usr/bin/xcrun", "swift"]:
            if command[-2:] == ["--product", "SWBBuildServiceBundle"]:
                if self.service_failure:
                    raise subprocess.CalledProcessError(1, command)
                if self.change_pins:
                    (self.arguments.output_dir / "source/Package.resolved").write_text("changed during build\n")
            stdout = ""
            if command[-1] == "--show-bin-path":
                stdout = str(Path(command[command.index("--scratch-path") + 1]) / "arm64-apple-macosx/release")
            return subprocess.CompletedProcess(command, 0, stdout)
        if command[0] == sys.executable and command[2] == "stage":
            self.assertEqual(Path(command[1]).read_text(), "committed staging implementation\n")
            return subprocess.CompletedProcess(command, 0)
        kwargs.setdefault("env", self.process_environment)
        return self.run_process(command, **kwargs)

    def build(self, developer_dir="/Applications/Explicit Xcode.app/Contents/Developer"):
        environment = {"DEVELOPER_DIR": developer_dir, "SWIFTCI_USE_LOCAL_DEPS": "1",
                       "SWIFTBUILD_LLBUILD_FWK": "/local/llbuild.framework", "SWIFTBUILD_STATIC_LINK": "1",
                       "XCBBUILDSERVICE_PATH": "/installed/service", "SWBBUILDSERVICE_PATH": "/other/service"}
        with patch.object(release, "REPOSITORY_ROOT", self.repository), \
                patch.object(release.platform, "system", return_value="Darwin"), \
                patch.object(release.platform, "machine", return_value="arm64"), \
                patch.dict(os.environ, environment), \
                patch.object(release.subprocess, "run", side_effect=self.run_command):
            release.build(self.arguments)

    def test_build_isolates_committed_source_pins_toolchain_and_service_environment(self):
        self.build()
        source = self.arguments.output_dir / "source"
        self.assertEqual((source / "Package.resolved").read_text(), "committed dependency pins\n")
        self.assertEqual((self.repository / "Package.resolved").read_text(), "developer dependency pins\n")
        self.assertEqual((self.arguments.output_dir / "source-revision.txt").read_text(), self.revision + "\n")
        build_commands = [(command, environment) for command, environment in self.commands
                          if command[:2] == ["/usr/bin/xcrun", "swift"] or command[0] == sys.executable]
        self.assertEqual([command[2] for command, _ in build_commands],
                         ["--version", "build", "test", "build", "build", "build", "stage"])
        for command, environment in build_commands:
            self.assertEqual(environment["DEVELOPER_DIR"], "/Applications/Explicit Xcode.app/Contents/Developer")
            for key in ("SWIFTCI_USE_LOCAL_DEPS", "SWIFTBUILD_LLBUILD_FWK", "SWIFTBUILD_STATIC_LINK",
                        "XCBBUILDSERVICE_PATH", "SWBBUILDSERVICE_PATH"):
                self.assertNotIn(key, environment)
            if "--package-path" in command:
                self.assertTrue(Path(command[command.index("--package-path") + 1]).is_relative_to(source))
                self.assertEqual(command[command.index("--jobs") + 1], "2")
                self.assertEqual("--force-resolved-versions" in command,
                                 command[command.index("--package-path") + 1] == str(source))
        self.assertFalse(any(command[0] == "/usr/bin/xcode-select" for command, _ in self.commands))

    def test_service_build_failure_stops_cli_and_staging_after_selecting_toolchain_once(self):
        self.service_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.build(developer_dir="")
        self.assertEqual(sum(command[0] == "/usr/bin/xcode-select" for command, _ in self.commands), 1)
        self.assertFalse(any("test" in command or "stage" in command for command, _ in self.commands))
        for command, environment in self.commands:
            if command[0] == "/usr/bin/xcrun":
                self.assertEqual(environment["DEVELOPER_DIR"], "/Applications/Selected Xcode.app/Contents/Developer")
        self.assertEqual((self.repository / "Package.resolved").read_text(), "developer dependency pins\n")

    def test_pin_drift_stops_cli_and_staging(self):
        self.change_pins = True
        with self.assertRaisesRegex(ValueError, "changed its pinned dependencies"):
            self.build()
        self.assertFalse(any("test" in command or "stage" in command for command, _ in self.commands))
        self.assertEqual((self.repository / "Package.resolved").read_text(), "developer dependency pins\n")

    def test_existing_output_is_preserved_before_source_extraction(self):
        self.arguments.output_dir.mkdir()
        existing = self.arguments.output_dir / "existing"
        existing.write_text("preserve me\n")
        with self.assertRaisesRegex(ValueError, "must be empty"):
            self.build()
        self.assertEqual(existing.read_text(), "preserve me\n")
        self.assertEqual(list(self.arguments.output_dir.iterdir()), [existing])
        self.assertFalse(any("archive" in command or "swift" in command for command, _ in self.commands))


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "build"
        self.payload = self.build / "payload"
        (self.payload / "bin").mkdir(parents=True)
        service = self.payload / "libexec/swift-build"
        service.mkdir(parents=True)
        for path in (self.payload / "bin/custom-xcode-build-service", service / "SWBBuildServiceBundle"):
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        for name in release.BUNDLES:
            resources = service / name / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "spec.xcspec").write_bytes(b"resource content\x00\xff")
        for name in ("swift-build", "swift-driver"):
            directory = self.payload / "licenses" / name
            directory.mkdir(parents=True)
            (directory / "LICENSE.txt").write_text(f"License for {name}\n")
        self.manifest = dict(schemaVersion=1, version="custom-v1.2.3-beta.1", sourceRevision="a" * 40,
                             xcodeVersion="27.0", xcodeBuildVersion="27A5252f", architecture="arm64",
                             minimumMacOSVersion="26.0", resourceBundles=list(release.BUNDLES),
                             dependencies=[dict(identity="swift-driver", revision="b" * 40)])
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        template = self.build / "source" / release.DISTRIBUTION_PATH / "install.sh.in"
        template.parent.mkdir(parents=True)
        template.write_text('#!/bin/bash\nversion="@VERSION@"\nrepository="@REPOSITORY@"\n')

    def package(self, name="release"):
        destination = self.root / name
        release.package(argparse.Namespace(build_dir=self.build, output_dir=destination))
        return destination

    def test_round_trip_preserves_resources_binaries_licenses_and_manifest(self):
        directory = self.package()
        extracted = self.root / "unpacked elsewhere"
        extracted.mkdir()
        release.extract_archive(directory / release.ARCHIVE, extracted)
        self.assertEqual(release.validate_payload(extracted), self.manifest)
        self.assertEqual((directory / "SHA256SUMS.txt").read_text(), release.checksum_file(directory))
        for source in self.payload.rglob("*"):
            if source.is_file():
                destination = extracted / source.relative_to(self.payload)
                self.assertEqual(source.read_bytes(), destination.read_bytes())
                self.assertEqual(bool(source.stat().st_mode & 0o111), bool(destination.stat().st_mode & 0o111))
        self.assertIn('version="custom-v1.2.3-beta.1"', (directory / "install.sh").read_text())
        self.assertIn('repository="lynnswap/swift-build"', (directory / "install.sh").read_text())

    def test_repackaging_is_stable_and_refuses_existing_output(self):
        first = self.package("first")
        second = self.package("second")
        self.assertEqual((first / release.ARCHIVE).read_bytes(), (second / release.ARCHIVE).read_bytes())
        with self.assertRaisesRegex(ValueError, "must be empty"):
            self.package("first")
        self.assertEqual((first / release.ARCHIVE).read_bytes(), (second / release.ARCHIVE).read_bytes())

    def test_missing_bundle_is_rejected_before_archive_is_created(self):
        import shutil
        shutil.rmtree(self.payload / "libexec/swift-build" / release.BUNDLES[0])
        with self.assertRaisesRegex(ValueError, "resources"):
            self.package()
        self.assertFalse((self.root / "release").exists())

    def test_external_payload_symlink_is_rejected(self):
        (self.payload / "licenses/swift-driver/external").symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "Non-regular payload"):
            self.package()

    def test_archive_traversal_links_and_duplicates_are_rejected_before_extraction(self):
        cases = (("../outside", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                 ("bin/link", tarfile.SYMTYPE), ("bin/hardlink", tarfile.LNKTYPE),
                 ("bin/fifo", tarfile.FIFOTYPE), ("bin/file", tarfile.REGTYPE))
        for index, (name, kind) in enumerate(cases):
            with self.subTest(name=name):
                archive_path = self.root / f"unsafe-{index}.tar.gz"
                with tarfile.open(archive_path, "w:gz") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/etc/passwd" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
                    archive.addfile(member, io.BytesIO())
                    if name == "bin/file":
                        archive.addfile(member, io.BytesIO())
                destination = self.root / f"extracted-{index}"
                destination.mkdir()
                with self.assertRaises(ValueError):
                    release.extract_archive(archive_path, destination)
                self.assertEqual(list(destination.iterdir()), [])

    def test_tampered_asset_fails_before_platform_or_executable_checks(self):
        directory = self.package()
        with (directory / release.ARCHIVE).open("ab") as contents:
            contents.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksums"):
            release.verify(argparse.Namespace(release_dir=directory))

    def test_dependency_requires_license_and_unique_revision_entry(self):
        self.manifest["dependencies"].append(dict(identity="swift-system", revision="c" * 40))
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "License directories"):
            release.validate_payload(self.payload)
        self.manifest["dependencies"][1] = self.manifest["dependencies"][0]
        (self.payload / "manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "Duplicate dependency"):
            release.validate_payload(self.payload)


if __name__ == "__main__":
    unittest.main()
