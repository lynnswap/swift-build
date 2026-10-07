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

"""Verify the release with stable Xcodes and the latest beta installed on this host."""

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path


def discover(applications):
    installations = {}
    for application in sorted(applications.glob("Xcode*.app")):
        application = application.resolve()
        version_file = application / "Contents/version.plist"
        if not version_file.is_file():
            continue
        with version_file.open("rb") as stream:
            version = plistlib.load(stream)
        number = version["CFBundleShortVersionString"]
        if int(number.split(".")[0]) not in (26, 27):
            continue
        with (application / "Contents/Resources/LicenseInfo.plist").open("rb") as stream:
            license_info = plistlib.load(stream)
        # The runner image installer uses licenseType to distinguish beta Xcodes.
        beta = "beta" in license_info["licenseType"].lower()
        build = version["ProductBuildVersion"]
        installations.setdefault((number, build), {
            "version": number,
            "build": build,
            "bundle_version": version["CFBundleVersion"],
            "beta": beta,
            "developer_dir": str(application / "Contents/Developer"),
        })
    return list(installations.values())


def select(installations):
    stable = [xcode for xcode in installations if not xcode["beta"]]
    betas = [xcode for xcode in installations if xcode["beta"]]

    def version_key(xcode):
        version = tuple(int(part) for part in xcode["version"].split("."))
        return (
            version + (0,) * max(0, 3 - len(version)),
            tuple(int(part) for part in xcode["bundle_version"].split(".")),
        )

    selected = sorted(stable, key=version_key)
    if betas:
        selected.append(max(betas, key=version_key))
    if not selected:
        raise ValueError("No installed Xcode 26 or 27 was found on this host.")
    return selected


def verify(applications, release_dir):
    # Hosted runner labels can span image revisions during a rollout. Discover
    # and test on the same host instead of sharing paths between jobs.
    selected = select(discover(applications))
    failures = []
    for xcode in selected:
        label = f"Xcode {xcode['version']} ({xcode['build']})"
        print(f"::group::IPC and SwiftPM compatibility: {label}", flush=True)
        environment = os.environ.copy()
        environment["DEVELOPER_DIR"] = xcode["developer_dir"]
        try:
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("release.py")),
                 "verify", "--release-dir", str(release_dir)],
                env=environment, check=True,
            )
        except subprocess.CalledProcessError:
            failures.append(label)
        finally:
            print("::endgroup::", flush=True)
    if failures:
        raise ValueError(f"Compatibility checks failed: {', '.join(failures)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify(Path("/Applications"), args.release_dir)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
