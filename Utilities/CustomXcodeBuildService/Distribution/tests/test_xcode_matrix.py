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
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "xcode_matrix", Path(__file__).resolve().parents[1] / "xcode_matrix.py"
)
xcode_matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xcode_matrix)


class XcodeMatrixTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stable = self.root / "stable-runner"
        self.preview = self.root / "preview-runner"
        self.stable.mkdir()
        self.preview.mkdir()

    def install(self, directory, version, build, bundle_version, beta=False):
        application = directory / f"Xcode_{version}_{build}.app"
        resources = application / "Contents/Resources"
        resources.mkdir(parents=True)
        (application / "Contents/version.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version,
            "CFBundleVersion": bundle_version,
            "ProductBuildVersion": build,
        }))
        (resources / "LicenseInfo.plist").write_bytes(plistlib.dumps({
            "licenseType": "Beta" if beta else "GM",
        }))
        return application

    def inventories(self):
        return [
            xcode_matrix.discover(self.stable, "macos-26"),
            xcode_matrix.discover(self.preview, "xcode-27"),
        ]

    def test_discovers_both_series_and_deduplicates_aliases_and_copies(self):
        self.install(self.stable, "25.0", "16A100", "20000")
        self.install(self.stable, "28.0", "28A100", "30000")
        first = self.install(self.stable, "26.0.1", "17A400", "24000")
        self.install(self.stable, "27.0", "27A266a", "25183.107.5")
        (self.stable / "Xcode.app").symlink_to(first, target_is_directory=True)
        shutil.copytree(first, self.stable / "Xcode_copy.app")
        found = xcode_matrix.discover(self.stable, "macos-26")
        self.assertEqual({item["version"] for item in found}, {"26.0.1", "27.0"})
        self.assertEqual(len(found), 2)
        self.assertTrue(all(item["runner"] == "macos-26" for item in found))

    def test_selects_all_stable_builds_and_one_latest_beta_across_runners(self):
        self.install(self.stable, "26.0.1", "17A400", "24000")
        self.install(self.stable, "26.6", "17F113", "24959")
        self.install(self.stable, "26.7", "17G5000a", "26000", beta=True)
        self.install(self.preview, "27.0", "27A266a", "25183.107.5")
        self.install(self.preview, "27.1", "27B5000a", "25300", beta=True)
        self.install(self.preview, "27.2", "27B5018a", "25400.9", beta=True)
        latest = self.install(self.preview, "27.2", "27B5019j", "25400.10", beta=True)
        selected = xcode_matrix.select(self.inventories())
        self.assertEqual([item["version"] for item in selected], ["26.0.1", "26.6", "27.0", "27.2"])
        self.assertEqual(sum(item["beta"] for item in selected), 1)
        self.assertEqual(selected[-1]["developer_dir"], str(latest.resolve() / "Contents/Developer"))
        self.assertEqual(selected[-1]["runner"], "xcode-27")

    def test_same_build_on_two_runners_keeps_a_matching_host_and_path(self):
        first = self.install(self.stable, "27.0", "27A266a", "25183.107.5")
        self.install(self.preview, "27.0", "27A266a", "25183.107.5")
        selected = xcode_matrix.select(self.inventories())
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["runner"], "macos-26")
        self.assertEqual(selected[0]["developer_dir"], str(first.resolve() / "Contents/Developer"))

    def test_beta_selection_compares_version_components_numerically(self):
        self.install(self.preview, "27.9", "27J5000a", "29000", beta=True)
        self.install(self.preview, "27.10", "27K5000a", "29100", beta=True)
        selected = xcode_matrix.select(self.inventories())
        self.assertEqual([item["version"] for item in selected], ["27.10"])

    def test_missing_beta_does_not_require_any_named_minor_version(self):
        self.install(self.stable, "26.8", "17H100", "27000")
        selected = xcode_matrix.select(self.inventories())
        self.assertEqual([item["version"] for item in selected], ["26.8"])

    def test_empty_inventory_does_not_pass_without_testing_any_xcode(self):
        with self.assertRaisesRegex(ValueError, "No installed Xcode"):
            xcode_matrix.select(self.inventories())

    def test_plan_cli_writes_a_matrix_with_host_paths_to_github_output(self):
        self.install(self.stable, "26.6", "17F113", "24959")
        self.install(self.preview, "27.2", "27B5019j", "25400.27.8", beta=True)
        output = self.root / "github-output"
        result = subprocess.run(
            [sys.executable, xcode_matrix.__file__, "plan", "--inventories",
             *[json.dumps(inventory) for inventory in self.inventories()],
             "--github-output", str(output)],
            capture_output=True, text=True, check=True,
        )
        matrix = json.loads(result.stdout)
        self.assertEqual(matrix["include"], xcode_matrix.select(self.inventories()))
        self.assertEqual(json.loads(output.read_text().removeprefix("matrix=")), matrix)


if __name__ == "__main__":
    unittest.main()
