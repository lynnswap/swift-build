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

"""Discover installed Xcodes and select compatibility jobs on their host runners."""

import argparse
import json
import plistlib
from pathlib import Path


def discover(applications, runner):
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
            "runner": runner,
            "developer_dir": str(application / "Contents/Developer"),
        })
    return list(installations.values())


def select(inventories):
    installations = {}
    for inventory in inventories:
        for xcode in inventory:
            installations.setdefault((xcode["version"], xcode["build"]), xcode)
    stable = [xcode for xcode in installations.values() if not xcode["beta"]]
    betas = [xcode for xcode in installations.values() if xcode["beta"]]

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
        raise ValueError("No installed Xcode 26 or 27 was found on the runners.")
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    discovery = commands.add_parser("discover")
    discovery.add_argument("--runner", required=True)
    discovery.add_argument("--github-output", type=Path)
    planning = commands.add_parser("plan")
    planning.add_argument("--inventories", nargs="+", required=True)
    planning.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "discover":
            key = "xcodes"
            value = discover(Path("/Applications"), args.runner)
        else:
            key = "matrix"
            value = {"include": select([json.loads(item) for item in args.inventories])}
        serialized = json.dumps(value)
        print(serialized)
        if args.github_output:
            with args.github_output.open("a") as stream:
                stream.write(f"{key}={serialized}\n")
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
