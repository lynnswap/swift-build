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

"""Exercise the download bootstrap without installing a service or contacting GitHub."""

import hashlib
import io
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ARCHIVE = "custom-xcode-build-service-darwin-arm64.tar.gz"
TEMPLATE = Path(__file__).resolve().parents[1] / "install.sh.in"


class ReleaseInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="custom-swb-installer-test-"
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.commands = self.root / "commands"
        self.commands.mkdir()
        curl = self.commands / "curl"
        curl.write_text(
            "#!/usr/bin/python3\n"
            "import os, pathlib, shutil, sys\n"
            "arguments = sys.argv[1:]\n"
            "url = arguments[-1]\n"
            "assert url.startswith('https://github.com/lynnswap/"
            "swift-build/releases/download/custom-v0.1.0/')\n"
            "assert arguments[arguments.index('--proto') + 1] == '=https'\n"
            "destination = arguments[arguments.index('--output') + 1]\n"
            "shutil.copyfile(pathlib.Path(os.environ['INSTALLER_TEST_ASSETS']) "
            "/ url.rsplit('/', 1)[1], destination)\n"
        )
        curl.chmod(0o755)
        self.installer = self.root / "install.sh"
        self.installer.write_text(
            TEMPLATE.read_text()
            .replace("@VERSION@", "custom-v0.1.0")
            .replace("@REPOSITORY@", "lynnswap/swift-build")
        )
        self.record = self.root / "invocation.txt"
        self.environment = dict(os.environ)
        self.environment.update(
            {
                "PATH": str(self.commands) + os.pathsep + os.environ["PATH"],
                "TMPDIR": str(self.root),
                "INSTALLER_TEST_ASSETS": str(self.assets),
                "INSTALL_RECORD": str(self.record),
            }
        )

    def make_archive(self, extra=None):
        with tarfile.open(self.assets / ARCHIVE, "w:gz") as archive:
            contents = (
                b'#!/bin/sh\nprintf "%s\\n" "$@" > "$INSTALL_RECORD"\n'
                b'test -f "$3/libexec/swift-build/'
                b'SwiftBuild_SWBCore.bundle/Contents/Resources/example.xcspec"\n'
            )
            executable = tarfile.TarInfo("bin/custom-xcode-build-service")
            executable.mode = 0o755
            executable.size = len(contents)
            archive.addfile(executable, io.BytesIO(contents))
            resource = tarfile.TarInfo(
                "libexec/swift-build/SwiftBuild_SWBCore.bundle/"
                "Contents/Resources/example.xcspec"
            )
            resource.size = 4
            archive.addfile(resource, io.BytesIO(b"spec"))
            if extra is not None:
                archive.addfile(extra, io.BytesIO(b""))
        self.write_checksum()

    def write_checksum(self):
        digest = hashlib.sha256((self.assets / ARCHIVE).read_bytes()).hexdigest()
        (self.assets / "SHA256SUMS.txt").write_text(f"{digest}  {ARCHIVE}\n")

    def run_installer(self, *arguments):
        return subprocess.run(
            ["/bin/sh", str(self.installer), *arguments],
            env=self.environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_verified_payload_is_installed_and_temporary_files_are_removed(
        self,
    ):
        self.make_archive()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.record.read_text().splitlines()
        self.assertEqual(arguments[:2], ["install", "--package"])
        self.assertFalse(Path(arguments[2]).exists())

    def test_corrupt_download_is_rejected_before_execution(self):
        self.make_archive()
        with (self.assets / ARCHIVE).open("ab") as archive:
            archive.write(b"corrupted")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_ambiguous_checksum_is_rejected(self):
        self.make_archive()
        checksums = self.assets / "SHA256SUMS.txt"
        checksums.write_text(checksums.read_text() * 2)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one SHA256", result.stderr)
        self.assertFalse(self.record.exists())

    def test_links_and_escaping_paths_are_rejected_before_execution(self):
        for kind in ["traversal", "symlink", "hardlink", "fifo"]:
            with self.subTest(kind=kind):
                entry = tarfile.TarInfo(
                    "../escaped" if kind == "traversal" else "licenses/extra"
                )
                if kind == "symlink":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "/tmp"
                elif kind == "hardlink":
                    entry.type = tarfile.LNKTYPE
                    entry.linkname = "bin/custom-xcode-build-service"
                elif kind == "fifo":
                    entry.type = tarfile.FIFOTYPE
                self.make_archive(entry)
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.record.exists())

    def test_help_does_not_download_or_install(self):
        result = self.run_installer("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prebuilt", result.stdout)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
