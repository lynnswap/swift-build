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

import importlib.util
import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "verify_xcodes", Path(__file__).resolve().parents[1] / "verify_xcodes.py"
)
verify_xcodes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_xcodes)


class XcodeCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.release_dir = self.root / "candidate release"
        self.release_dir.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.mock_release = self.root / "release.py"
        self.mock_release.write_text("""
import json
import os
import plistlib
import sys
from pathlib import Path

developer_dir = Path(os.environ["DEVELOPER_DIR"])
if not developer_dir.is_dir():
    sys.exit("missing DEVELOPER_DIR path")
with (developer_dir.parent / "version.plist").open("rb") as stream:
    version = plistlib.load(stream)
with Path(os.environ["TEST_CALLS"]).open("a") as stream:
    stream.write(json.dumps({"build": version["ProductBuildVersion"],
                             "developer_dir": str(developer_dir),
                             "arguments": sys.argv[1:]}) + "\\n")
if version["ProductBuildVersion"] == os.environ.get("TEST_FAIL_BUILD"):
    sys.exit(7)
""")

    def install(self, version, build, bundle_version, beta=False, applications=None):
        application = (applications or self.applications) / f"Xcode_{version}_{build}.app"
        resources = application / "Contents/Resources"
        resources.mkdir(parents=True)
        (application / "Contents/Developer").mkdir()
        (application / "Contents/version.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version,
            "CFBundleVersion": bundle_version,
            "ProductBuildVersion": build,
        }))
        (resources / "LicenseInfo.plist").write_bytes(plistlib.dumps({
            "licenseType": "Beta" if beta else "GM",
        }))
        return application

    def selected(self):
        return verify_xcodes.select(verify_xcodes.discover(self.applications))

    def recorded_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_discovers_both_series_and_deduplicates_aliases_and_copies(self):
        self.install("25.0", "16A100", "20000")
        self.install("28.0", "28A100", "30000")
        first = self.install("26.0.1", "17A400", "24000")
        self.install("27.0", "27A266a", "25183.107.5")
        (self.applications / "Xcode.app").symlink_to(first, target_is_directory=True)
        shutil.copytree(first, self.applications / "Xcode_copy.app")
        found = verify_xcodes.discover(self.applications)
        self.assertEqual({item["version"] for item in found}, {"26.0.1", "27.0"})
        self.assertEqual(len(found), 2)

    def test_selects_all_stable_builds_and_one_latest_beta_on_this_host(self):
        self.install("26.0.1", "17A400", "24000")
        self.install("26.6", "17F113", "24959")
        self.install("26.7", "17G5000a", "26000", beta=True)
        self.install("27.0", "27A266a", "25183.107.5")
        self.install("27.1", "27B5000a", "25300", beta=True)
        self.install("27.2", "27B5018a", "25400.9", beta=True)
        latest = self.install("27.2", "27B5019j", "25400.10", beta=True)
        selected = self.selected()
        self.assertEqual([item["version"] for item in selected], ["26.0.1", "26.6", "27.0", "27.2"])
        self.assertEqual(sum(item["beta"] for item in selected), 1)
        self.assertEqual(selected[-1]["developer_dir"], str(latest.resolve() / "Contents/Developer"))

    def test_beta_selection_compares_version_components_numerically(self):
        self.install("27.9", "27J5000a", "29000", beta=True)
        self.install("27.10", "27K5000a", "29100", beta=True)
        self.assertEqual([item["version"] for item in self.selected()], ["27.10"])

    def test_missing_beta_does_not_require_any_named_minor_version(self):
        self.install("26.8", "17H100", "27000")
        self.assertEqual([item["version"] for item in self.selected()], ["26.8"])

    def test_empty_inventory_does_not_pass_without_testing_any_xcode(self):
        with self.assertRaisesRegex(ValueError, "No installed Xcode"):
            self.selected()

    def test_cli_uses_its_own_host_when_the_build_runner_has_a_newer_image(self):
        build_applications = self.root / "build runner"
        newer = self.install("27.2", "27B5028f", "25400.40.6", beta=True,
                             applications=build_applications)
        self.install("27.0", "27A266a", "25183.107.5")
        older = self.install("27.2", "27B5019j", "25400.27.8", beta=True)
        inherited = str(newer / "Contents/Developer")
        environment = {"TEST_CALLS": str(self.calls), "DEVELOPER_DIR": inherited}
        inventory = verify_xcodes.discover(self.applications)
        with patch.dict(os.environ, environment), patch.object(
            verify_xcodes, "__file__", str(self.root / "verify_xcodes.py")
        ), patch.object(verify_xcodes, "discover", return_value=inventory), patch.object(
            sys, "argv", ["verify_xcodes.py", "--release-dir", str(self.release_dir)]
        ):
            verify_xcodes.main()
            self.assertEqual(os.environ["DEVELOPER_DIR"], inherited)
        calls = self.recorded_calls()
        self.assertEqual([call["build"] for call in calls], ["27A266a", "27B5019j"])
        self.assertEqual(calls[-1]["developer_dir"], str(older / "Contents/Developer"))
        self.assertTrue(all(call["arguments"] == ["verify", "--release-dir", str(self.release_dir)]
                            for call in calls))

    def test_failed_xcode_still_tests_remaining_targets_and_fails_the_job(self):
        self.install("26.6", "17F113", "24959")
        self.install("27.0", "27A266a", "25183.107.5")
        self.install("27.2", "27B5019j", "25400.27.8", beta=True)
        with patch.dict(os.environ, {"TEST_CALLS": str(self.calls), "TEST_FAIL_BUILD": "17F113"}), patch.object(
            verify_xcodes, "__file__", str(self.root / "verify_xcodes.py")
        ):
            with self.assertRaisesRegex(ValueError, r"Compatibility checks failed: Xcode 26.6 \(17F113\)"):
                verify_xcodes.verify(self.applications, self.release_dir)
        self.assertEqual([call["build"] for call in self.recorded_calls()],
                         ["17F113", "27A266a", "27B5019j"])

    def test_verification_rejects_an_empty_host_before_launching_a_build(self):
        with patch.object(verify_xcodes.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "No installed Xcode"):
                verify_xcodes.verify(self.applications, self.release_dir)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
