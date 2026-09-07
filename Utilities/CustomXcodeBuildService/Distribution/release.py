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

"""Producer-side builds, packaging, and relocation checks (Python standard library)."""

import argparse
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
DISTRIBUTION_PATH = Path("Utilities/CustomXcodeBuildService/Distribution")
ARCHIVE = "custom-xcode-build-service-darwin-arm64.tar.gz"
ASSETS = (ARCHIVE, "install.sh")
BUNDLES = tuple(sorted(f"SwiftBuild_{name}.bundle" for name in (
    "SWBAndroidPlatform", "SWBApplePlatform", "SWBCore", "SWBGenericUnixPlatform",
    "SWBQNXPlatform", "SWBUniversalPlatform", "SWBWebAssemblyPlatform", "SWBWindowsPlatform",
)))
VERSION_PATTERN = r"custom-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
REVISION_PATTERN = r"[0-9a-f]{40}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def xcode_version(environment=None):
    lines = output(["/usr/bin/xcrun", "xcodebuild", "-version"], env=environment).splitlines()
    require(len(lines) == 2 and re.fullmatch(r"Xcode 27(?:\.[0-9]+)+", lines[0]),
            "Select Xcode 27 before building or verifying a distribution.")
    require(re.fullmatch(r"Build version [0-9A-Za-z]+", lines[1]), "Unexpected Xcode build version.")
    return lines[0].removeprefix("Xcode "), lines[1].removeprefix("Build version ")


def empty_directory(path):
    require(not path.is_symlink(), f"Output must not be a symlink: {path}")
    path.mkdir(parents=True, exist_ok=True)
    require(not any(path.iterdir()), f"Output directory must be empty: {path}")


def regular_tree(root):
    require(root.is_dir() and not root.is_symlink(), f"Missing directory: {root}")
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), f"Non-regular payload entry: {path}")


def validate_payload(payload):
    regular_tree(payload)
    require({p.name for p in payload.iterdir()} == {"bin", "libexec", "manifest.json", "licenses"},
            "Unexpected payload root layout.")
    manifest = json.loads((payload / "manifest.json").read_text())
    require(manifest["schemaVersion"] == 1, "Unsupported manifest schema.")
    require(re.fullmatch(VERSION_PATTERN, manifest["version"]), "Invalid release version.")
    require(re.fullmatch(REVISION_PATTERN, manifest["sourceRevision"]), "Invalid source revision.")
    require(re.fullmatch(r"27(?:\.[0-9]+)+", manifest["xcodeVersion"]), "Expected Xcode 27.")
    require(re.fullmatch(r"[0-9A-Za-z]+", manifest["xcodeBuildVersion"]), "Invalid Xcode build version.")
    require(manifest["architecture"] == "arm64" and manifest["minimumMacOSVersion"] == "26.0",
            "Expected an arm64 / macOS 26 distribution.")
    require(manifest["resourceBundles"] == list(BUNDLES), "Unexpected resource bundle set.")
    require({p.name for p in (payload / "bin").iterdir()} == {"custom-xcode-build-service"},
            "Unexpected management binary layout.")
    require({p.name for p in (payload / "libexec").iterdir()} == {"swift-build"},
            "Unexpected service directory layout.")
    service_dir = payload / "libexec/swift-build"
    require({p.name for p in service_dir.iterdir()} == {"SWBBuildServiceBundle", *BUNDLES},
            "Missing or unexpected service resources.")
    for bundle in BUNDLES:
        resources = service_dir / bundle
        require(resources.is_dir() and any(p.is_file() for p in resources.rglob("*")),
                f"Empty resource bundle: {bundle}")
    for binary in (payload / "bin/custom-xcode-build-service", service_dir / "SWBBuildServiceBundle"):
        require(binary.is_file() and os.access(binary, os.X_OK), f"Missing executable: {binary}")
    identities = set()
    for dependency in manifest["dependencies"]:
        identity = dependency["identity"]
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity), f"Invalid dependency identity: {identity}")
        require(identity not in identities, f"Duplicate dependency identity: {identity}")
        identities.add(identity)
        require(re.fullmatch(REVISION_PATTERN, dependency["revision"]), f"Invalid revision: {identity}")
    require(identities, "Dependency revisions are missing.")
    require({p.name for p in (payload / "licenses").iterdir()} == identities | {"swift-build"},
            "License directories do not match the dependency manifest.")
    for directory in (payload / "licenses").iterdir():
        require(directory.is_dir() and any(p.is_file() for p in directory.rglob("*")),
                f"Missing license text: {directory.name}")
    return manifest


def check_binary(binary):
    require(output(["/usr/bin/lipo", "-archs", str(binary)]) == "arm64", f"Expected arm64 binary: {binary}")
    load_commands = output(["/usr/bin/otool", "-l", str(binary)])
    minimum_versions = re.findall(
        r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|MACOS)\s+minos ([0-9.]+)", load_commands)
    require(len(minimum_versions) == 1, f"Missing macOS deployment target: {binary}")
    minimum = tuple(int(component) for component in minimum_versions[0].split("."))
    require((minimum + (0, 0, 0))[:3] <= (26, 0, 0),
            f"Binary requires a newer OS than the distribution's macOS 26 minimum: {binary}")
    dependencies = output(["/usr/bin/otool", "-L", str(binary)]).splitlines()[1:]
    require(dependencies, f"No Mach-O dependency information: {binary}")
    for line in dependencies:
        library = line.strip().split(" (", 1)[0]
        require(library.startswith(("/usr/lib/", "/System/Library/")),
                f"Non-system dynamic dependency in {binary.name}: {library}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)


def copy_binary(source, destination):
    require(source.is_file(), f"Missing built binary: {source}")
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    load_commands = output(["/usr/bin/otool", "-l", str(destination)])
    # SwiftPM adds producer-toolchain search paths; shipped binaries use system libraries.
    for path in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)", load_commands):
        if path.startswith("/") and not path.startswith(("/usr/lib/", "/System/Library/")):
            subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", path, str(destination)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(destination)], check=True)
    check_binary(destination)


def copy_licenses(source, destination):
    count = 0
    for parent, directories, files in os.walk(source):
        directories[:] = [d for d in directories if d not in {".git", ".build", ".swiftpm"}]
        for name in files:
            if name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
                path = Path(parent) / name
                require(not path.is_symlink(), f"License must be a regular file: {path}")
                target = destination / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
                count += 1
    require(count > 0, f"No license texts found: {source}")


def build(args):
    require(re.fullmatch(VERSION_PATTERN, args.version),
            "Version must look like custom-v1.2.3 or custom-v1.2.3-beta.1.")
    require(args.jobs > 0, "--jobs must be positive.")
    require(platform.system() == "Darwin" and platform.machine() == "arm64",
            "Building this distribution requires an Apple Silicon Mac.")
    revision = output(["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--verify",
                       "--end-of-options", f"{args.revision}^{{commit}}"])
    environment = dict(os.environ)
    # Keep every build, test, and metadata query on the initially selected toolchain.
    environment["DEVELOPER_DIR"] = environment.get("DEVELOPER_DIR") or output(
        ["/usr/bin/xcode-select", "--print-path"])
    version, build_version = xcode_version(environment)
    empty_directory(args.output_dir)
    directory = args.output_dir.resolve()
    source = directory / "source"
    source.mkdir()
    (directory / "build").mkdir()
    with tempfile.TemporaryFile() as archive:
        subprocess.run(["git", "-C", str(REPOSITORY_ROOT), "archive", revision], stdout=archive, check=True)
        archive.seek(0)
        subprocess.run(["/usr/bin/tar", "-x", "-C", str(source)], stdin=archive, check=True)
    pins = source / DISTRIBUTION_PATH / "ServiceDependencies.resolved"
    shutil.copy2(pins, source / "Package.resolved")
    (directory / "source-revision.txt").write_text(revision + "\n")

    # These options change the dependency graph or service independently of the pins.
    for key in ("SWIFTCI_USE_LOCAL_DEPS", "SWIFTBUILD_LLBUILD_FWK", "SWIFTBUILD_STATIC_LINK",
                "XCBBUILDSERVICE_PATH", "SWBBUILDSERVICE_PATH"):
        environment.pop(key, None)
    common = ["--configuration", "release", "--arch", "arm64", "--jobs", str(args.jobs),
              "--build-system", "swiftbuild", "--cache-path", str(directory / "build/cache"),
              "--config-path", str(directory / "build/config"),
              "--security-path", str(directory / "build/security")]
    service_args = [*common, "--package-path", str(source),
                    "--scratch-path", str(directory / "build/service"), "--force-resolved-versions"]
    cli_args = [*common, "--package-path", str(source / "Utilities/CustomXcodeBuildService"),
                "--scratch-path", str(directory / "build/cli")]
    print(f"Xcode {version}\nBuild version {build_version}", flush=True)
    subprocess.run(["/usr/bin/xcrun", "swift", "--version"], env=environment, check=True)
    subprocess.run(["/usr/bin/xcrun", "swift", "build", *service_args, "--product", "SWBBuildServiceBundle"],
                   env=environment, check=True)
    require((source / "Package.resolved").read_bytes() == pins.read_bytes(),
            "Building the service changed its pinned dependencies.")
    subprocess.run(["/usr/bin/xcrun", "swift", "test", *cli_args, "--disable-xctest"],
                   env=environment, check=True)
    subprocess.run(["/usr/bin/xcrun", "swift", "build", *cli_args, "--product", "custom-xcode-build-service"],
                   env=environment, check=True)
    service_bin = output(["/usr/bin/xcrun", "swift", "build", *service_args, "--show-bin-path"], env=environment)
    cli_bin = output(["/usr/bin/xcrun", "swift", "build", *cli_args, "--show-bin-path"], env=environment)
    subprocess.run([sys.executable, str(source / DISTRIBUTION_PATH / "release.py"), "stage",
                    "--build-dir", str(directory), "--service-bin", service_bin,
                    "--cli-bin", cli_bin, "--version", args.version], env=environment, check=True)
    print(f"Built payload: {directory / 'payload'}")


def stage(args):
    source = args.build_dir / "source"
    payload = args.build_dir / "payload"
    empty_directory(payload)
    require(re.fullmatch(VERSION_PATTERN, args.version), "Invalid release version.")
    revision = (args.build_dir / "source-revision.txt").read_text().strip()
    require(re.fullmatch(REVISION_PATTERN, revision), "Invalid source revision.")
    version, build_version = xcode_version()
    service_dir = payload / "libexec/swift-build"
    service_dir.mkdir(parents=True)
    (payload / "bin").mkdir()
    copy_binary(args.service_bin / "SWBBuildServiceBundle", service_dir / "SWBBuildServiceBundle")
    copy_binary(args.cli_bin / "custom-xcode-build-service", payload / "bin/custom-xcode-build-service")
    require(tuple(sorted(p.name for p in args.service_bin.glob("SwiftBuild_*.bundle"))) == BUNDLES,
            "Built resource bundles differ from the distribution contract.")
    for bundle in BUNDLES:
        regular_tree(args.service_bin / bundle)
        shutil.copytree(args.service_bin / bundle, service_dir / bundle)
    pins = json.loads((source / DISTRIBUTION_PATH / "ServiceDependencies.resolved").read_text())["pins"]
    dependencies = []
    for pin in pins:
        checkout = args.build_dir / "build/service/checkouts" / pin["identity"]
        actual_revision = output(["git", "-C", str(checkout), "rev-parse", "HEAD"])
        require(actual_revision == pin["state"]["revision"], f"Dependency revision changed: {pin['identity']}")
        dependencies.append({"identity": pin["identity"], "revision": actual_revision})
        copy_licenses(checkout, payload / "licenses" / pin["identity"])
    copy_licenses(source, payload / "licenses/swift-build")
    manifest = dict(schemaVersion=1, version=args.version, sourceRevision=revision,
                    xcodeVersion=version, xcodeBuildVersion=build_version, architecture="arm64",
                    minimumMacOSVersion="26.0", resourceBundles=list(BUNDLES),
                    dependencies=sorted(dependencies, key=lambda item: item["identity"]))
    (payload / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    validate_payload(payload)


def checksum_file(directory):
    return "".join(f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n" for name in ASSETS)


def package(args):
    payload = args.build_dir / "payload"
    manifest = validate_payload(payload)
    empty_directory(args.output_dir)
    template = (args.build_dir / "source" / DISTRIBUTION_PATH / "install.sh.in").read_text()
    require("@VERSION@" in template and "@REPOSITORY@" in template, "Missing installer template markers.")
    installer = template.replace("@VERSION@", manifest["version"]).replace("@REPOSITORY@", "lynnswap/swift-build")
    (args.output_dir / "install.sh").write_text(installer)
    (args.output_dir / "install.sh").chmod(0o755)
    subprocess.run(["/bin/bash", "-n", str(args.output_dir / "install.sh")], check=True)
    # Fixed tar/gzip metadata makes repackaging the same payload byte-for-byte stable.
    with (args.output_dir / ARCHIVE).open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in sorted(payload.rglob("*")):
                    info = archive.gettarinfo(str(path), arcname=path.relative_to(payload).as_posix())
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    info.pax_headers = {}
                    info.mode = 0o755 if path.is_dir() or os.access(path, os.X_OK) else 0o644
                    if path.is_file():
                        with path.open("rb") as contents:
                            archive.addfile(info, contents)
                    else:
                        archive.addfile(info)
    (args.output_dir / "SHA256SUMS.txt").write_text(checksum_file(args.output_dir))
    print(f"Created release assets: {args.output_dir}")


def extract_archive(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        names = set()
        for member in members:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts and str(path) == member.name.rstrip("/"),
                    f"Unsafe archive path: {member.name}")
            require(str(path) not in names, f"Duplicate archive entry: {member.name}")
            names.add(str(path))
            require(member.isdir() or member.isfile(), f"Non-regular archive entry: {member.name}")
            require(not member.mode & 0o7000, f"Unsafe archive permissions: {member.name}")
        # All paths and types are checked before any extraction, including hard links.
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("xb") as output_file:
                    shutil.copyfileobj(source, output_file)
            target.chmod(member.mode)


def smoke_build(payload, temporary):
    fixture = REPOSITORY_ROOT / "Tests/SwiftBuildTests/TestData/CommandLineTool"
    shutil.copytree(fixture, temporary / "Smoke")
    service = payload / "libexec/swift-build/SWBBuildServiceBundle"
    environment = dict(os.environ)
    environment.pop("SWBBUILDSERVICE_PATH", None)
    environment.update(XCBBUILDSERVICE_PATH=str(service), DisableConcurrentDependencyResolution="0")
    command = ["/usr/bin/xcrun", "xcodebuild", "-project", str(temporary / "Smoke/CommandLineTool.xcodeproj"),
               "-target", "CommandLineTool", "-configuration", "Release", "-sdk", "macosx",
               "CODE_SIGNING_ALLOWED=NO", "MACOSX_DEPLOYMENT_TARGET=26.0", "ALWAYS_SEARCH_USER_PATHS=NO",
               f"SYMROOT={temporary / 'products'}",
               f"OBJROOT={temporary / 'intermediates'}", "build"]
    observed_service = False
    deadline = time.monotonic() + 600
    with subprocess.Popen(command, env=environment) as process:
        try:
            while True:
                # Xcode inspects the selected Mach-O, so a shell wrapper cannot prove selection.
                executable_paths = output(["/bin/ps", "-axo", "comm="]).splitlines()
                observed_service |= str(service) in (path.strip() for path in executable_paths)
                return_code = process.poll()
                if return_code is not None:
                    require(return_code == 0, f"Relocated Xcode build failed (exit {return_code}).")
                    break
                require(time.monotonic() < deadline, "Relocated Xcode build timed out after 10 minutes.")
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
    require(observed_service, "Xcode did not invoke the relocated custom service.")
    subprocess.run([str(temporary / "products/Release/CommandLineTool")], check=True)


def verify(args):
    require({p.name for p in args.release_dir.iterdir()} == {*ASSETS, "SHA256SUMS.txt"},
            "Unexpected release asset set.")
    require((args.release_dir / "SHA256SUMS.txt").read_text() == checksum_file(args.release_dir),
            "Release asset checksums do not match.")
    subprocess.run(["/bin/bash", "-n", str(args.release_dir / "install.sh")], check=True)
    with tempfile.TemporaryDirectory(prefix="custom service relocation ") as directory:
        temporary = Path(directory)
        payload = temporary / "payload"
        payload.mkdir()
        extract_archive(args.release_dir / ARCHIVE, payload)
        manifest = validate_payload(payload)
        require(xcode_version() == (manifest["xcodeVersion"], manifest["xcodeBuildVersion"]),
                "Verify with the exact Xcode build used to produce the distribution.")
        for binary in (payload / "bin/custom-xcode-build-service", payload / "libexec/swift-build/SWBBuildServiceBundle"):
            check_binary(binary)
        subprocess.run([str(payload / "bin/custom-xcode-build-service"), "--help"], check=True)
        smoke_build(payload, temporary)
    print("Verified checksums, archive layout, signatures, system libraries, and relocated Xcode build.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    building = commands.add_parser("build", help="Build committed source with Xcode 27 on Apple Silicon",
                                   description="Build committed source in an isolated directory. The output must be "
                                   "absent or empty; source, builds, and payload remain there. Does not install.")
    building.add_argument("--version", required=True)
    building.add_argument("--output-dir", type=Path, required=True)
    building.add_argument("--revision", default="HEAD")
    building.add_argument("--jobs", type=int, default=2)
    staging = commands.add_parser("stage", help="Stage built binaries, resources, licenses, and metadata")
    staging.add_argument("--build-dir", type=Path, required=True)
    staging.add_argument("--service-bin", type=Path, required=True)
    staging.add_argument("--cli-bin", type=Path, required=True)
    staging.add_argument("--version", required=True)
    packaging = commands.add_parser("package", help="Package an existing build; the output must be absent or empty")
    packaging.add_argument("--build-dir", type=Path, required=True)
    packaging.add_argument("--output-dir", type=Path, required=True)
    verification = commands.add_parser("verify", help="Verify a release with the same Xcode build; does not install")
    verification.add_argument("--release-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        {"build": build, "stage": stage, "package": package, "verify": verify}[args.command](args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
