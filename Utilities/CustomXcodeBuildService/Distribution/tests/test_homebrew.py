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

"""Run the Homebrew verification entry point with local package-manager mocks."""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "test-homebrew.sh"


class HomebrewVerificationTests(unittest.TestCase):
    def run_verification(self, failure="", existing=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("bin", "tap/Formula", "release", "prefix/bin", "scratch"):
                (root / name).mkdir(parents=True)
            manifest = json.dumps({"version": "v1.2.3"}).encode()
            with tarfile.open(root / "release/custom-xcode-build-service-darwin-arm64.tar.gz", "w:gz") as archive:
                entry = tarfile.TarInfo("manifest.json")
                entry.size = len(manifest)
                archive.addfile(entry, io.BytesIO(manifest))
            (root / "release/custom-xcode-build-service.rb").write_text("candidate recipe\n")
            cli = root / "prefix/bin/custom-xcode-build-service"
            cli.write_text('#!/bin/sh\nprintf "v1.2.3\\n"\n')
            cli.chmod(0o755)
            (root / "bin/brew").write_text(f"#!{sys.executable}\n" + '''
import json, os
from pathlib import Path
import sys
root = Path(os.environ["MOCK_HOMEBREW_ROOT"])
args = sys.argv[1:]
with (root / "commands").open("a") as log:
    log.write(json.dumps(args) + "\\n")
state = root / "installed"
command = args[0]
if command == "list":
    sys.exit(0 if state.exists() or os.environ.get("MOCK_EXISTING") else 1)
if command == os.environ.get("MOCK_FAILURE"):
    sys.exit(1)
if command == "--repository":
    print(root / "tap")
elif command == "--cache":
    print(root / "cache/archive.tar.gz")
elif command == "--prefix":
    print(root / "prefix")
elif command == "install":
    state.touch()
elif command == "uninstall":
    state.unlink(missing_ok=True)
''')
            (root / "bin/python3").write_text(f"#!{sys.executable}\n" + '''
import json, os
from pathlib import Path
import subprocess, sys
args = sys.argv[1:]
root = Path(os.environ["MOCK_HOMEBREW_ROOT"])
if args and Path(args[0]).name == "release.py":
    with (root / "commands").open("a") as log:
        log.write(json.dumps(["verify-payload", *args[1:]]) + "\\n")
    sys.exit(1 if os.environ.get("MOCK_FAILURE") == "verify-payload" else 0)
sys.exit(subprocess.run([os.environ["REAL_PYTHON"], *args]).returncode)
''')
            for name in ("brew", "python3"):
                (root / "bin" / name).chmod(0o755)
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                               MOCK_HOMEBREW_ROOT=str(root), MOCK_FAILURE=failure,
                               MOCK_EXISTING="1" if existing else "", REAL_PYTHON=sys.executable,
                               TMPDIR=str(root / "scratch"))
            result = subprocess.run(["bash", str(SCRIPT), str(root / "release")],
                                    env=environment, text=True, capture_output=True)
            commands = [json.loads(line) for line in (root / "commands").read_text().splitlines()]
            installed = (root / "installed").exists()
            return result, commands, installed

    def test_candidate_is_checked_installed_verified_and_cleaned(self):
        result, commands, installed = self.run_verification()
        self.assertEqual(result.returncode, 0, result.stderr)
        stages = [command[0] for command in commands]
        self.assertLess(stages.index("style"), stages.index("install"))
        self.assertLess(stages.index("audit"), stages.index("install"))
        self.assertIn(["audit", "--except=installed", "custom-xcode-build-service/verification/custom-xcode-build-service"], commands)
        self.assertIn("test", stages)
        self.assertIn("verify-payload", stages)
        self.assertIn("uninstall", stages)
        self.assertFalse(installed)

    def test_failed_checks_stop_installation_and_verification_failures_clean_up(self):
        for failure in ("style", "audit", "install", "test", "verify-payload"):
            with self.subTest(failure=failure):
                result, commands, installed = self.run_verification(failure)
                self.assertNotEqual(result.returncode, 0)
                stages = [command[0] for command in commands]
                if failure in ("style", "audit"):
                    self.assertNotIn("install", stages)
                if failure in ("test", "verify-payload"):
                    self.assertIn("uninstall", stages)
                self.assertIn("untap", stages)
                self.assertIn("untrust", stages)
                self.assertFalse(installed)

    def test_existing_user_installation_is_left_untouched(self):
        result, commands, _ = self.run_verification(existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Uninstall the existing", result.stderr)
        self.assertEqual([command[0] for command in commands], ["list"])


if __name__ == "__main__":
    unittest.main()
