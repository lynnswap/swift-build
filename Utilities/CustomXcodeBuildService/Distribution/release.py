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

"""Release builds, Homebrew source packaging, and relocation checks."""

import argparse
import gzip
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path, PurePosixPath

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
DISTRIBUTION_PATH = Path("Utilities/CustomXcodeBuildService/Distribution")
ARCHIVE = "custom-xcode-build-service-darwin-arm64.tar.gz"
ASSETS = (ARCHIVE,)
SERVICE_BUNDLE = Path("libexec/swift-build/SWBBuildService.bundle")
SERVICE_BINARY = SERVICE_BUNDLE / "SWBBuildServiceBundle"
HOST_PLUGIN = SERVICE_BUNDLE / "PlugIns/HostPlatformPlugins.bundle"
HOST_PLUGIN_BINARY = HOST_PLUGIN / "Contents/MacOS/HostPlatformPlugins"
BUNDLES = tuple(
    sorted(
        f"SwiftBuild_{name}.bundle"
        for name in (
            "SWBAndroidPlatform",
            "SWBApplePlatform",
            "SWBCore",
            "SWBGenericUnixPlatform",
            "SWBQNXPlatform",
            "SWBUniversalPlatform",
            "SWBWebAssemblyPlatform",
            "SWBWindowsPlatform",
        )
    )
)
VERSION_PATTERN = (
    r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"
)
REVISION_PATTERN = r"[0-9a-f]{40}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def xcode_version(environment=None):
    lines = output(
        ["/usr/bin/xcrun", "xcodebuild", "-version"], env=environment
    ).splitlines()
    require(
        len(lines) == 2 and re.fullmatch(r"Xcode [0-9]+(?:\.[0-9]+)+", lines[0]),
        "Could not read the selected Xcode version.",
    )
    require(
        re.fullmatch(r"Build version [0-9A-Za-z]+", lines[1]),
        "Unexpected Xcode build version.",
    )
    return lines[0].removeprefix("Xcode "), lines[1].removeprefix("Build version ")


def empty_directory(path):
    require(not path.is_symlink(), f"Output must not be a symlink: {path}")
    path.mkdir(parents=True, exist_ok=True)
    require(not any(path.iterdir()), f"Output directory must be empty: {path}")


def regular_tree(root):
    require(root.is_dir() and not root.is_symlink(), f"Missing directory: {root}")
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        require(
            stat.S_ISDIR(mode) or stat.S_ISREG(mode),
            f"Non-regular payload entry: {path}",
        )


def service_path(payload, manifest):
    return payload / (
        "libexec/swift-build/SWBBuildServiceBundle"
        if manifest["schemaVersion"] == 1 else SERVICE_BINARY
    )


def validate_payload(payload):
    regular_tree(payload)
    require(
        {p.name for p in payload.iterdir()}
        == {"bin", "libexec", "manifest.json", "licenses"},
        "Unexpected payload root layout.",
    )
    manifest = json.loads((payload / "manifest.json").read_text())
    require(manifest["schemaVersion"] in (1, 2), "Unsupported manifest schema.")
    require(
        re.fullmatch(VERSION_PATTERN, manifest["version"]), "Invalid release version."
    )
    require(
        re.fullmatch(REVISION_PATTERN, manifest["sourceRevision"]),
        "Invalid source revision.",
    )
    require(
        re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", manifest["xcodeVersion"]), "Invalid Xcode version."
    )
    require(
        re.fullmatch(r"[0-9A-Za-z]+", manifest["xcodeBuildVersion"]),
        "Invalid Xcode build version.",
    )
    require(
        manifest["architecture"] == "arm64"
        and manifest["minimumMacOSVersion"] == "26.0",
        "Expected an arm64 / macOS 26 distribution.",
    )
    require(
        manifest["resourceBundles"] == list(BUNDLES), "Unexpected resource bundle set."
    )
    require(
        {p.name for p in (payload / "bin").iterdir()} == {"custom-xcode-build-service"},
        "Unexpected management binary layout.",
    )
    require(
        {p.name for p in (payload / "libexec").iterdir()} == {"swift-build"},
        "Unexpected service directory layout.",
    )
    service_dir = payload / "libexec/swift-build"
    binaries = [payload / "bin/custom-xcode-build-service", service_path(payload, manifest)]
    if manifest["schemaVersion"] == 2:
        require(
            {p.name for p in service_dir.iterdir()} == {"SWBBuildService.bundle"},
            "Unexpected service bundle layout.",
        )
        service_dir = payload / SERVICE_BUNDLE
        require(
            {p.name for p in (service_dir / "PlugIns").iterdir()}
            == {"HostPlatformPlugins.bundle"},
            "Unexpected service bundle contents.",
        )
        binaries.append(payload / HOST_PLUGIN_BINARY)
    service_contents = {"SWBBuildServiceBundle", *BUNDLES}
    if manifest["schemaVersion"] == 2:
        service_contents.update({"Info.plist", "PlugIns", "_CodeSignature"})
    require(
        {p.name for p in service_dir.iterdir()} == service_contents,
        "Missing or unexpected service resources.",
    )
    for bundle in BUNDLES:
        resources = service_dir / bundle
        require(
            resources.is_dir() and any(p.is_file() for p in resources.rglob("*")),
            f"Empty resource bundle: {bundle}",
        )
    for binary in binaries:
        require(
            binary.is_file() and os.access(binary, os.X_OK),
            f"Missing executable: {binary}",
        )
    identities = set()
    for dependency in manifest["dependencies"]:
        identity = dependency["identity"]
        require(
            re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity),
            f"Invalid dependency identity: {identity}",
        )
        require(
            identity not in identities, f"Duplicate dependency identity: {identity}"
        )
        identities.add(identity)
        require(
            re.fullmatch(REVISION_PATTERN, dependency["revision"]),
            f"Invalid revision: {identity}",
        )
    require(identities, "Dependency revisions are missing.")
    require(
        {p.name for p in (payload / "licenses").iterdir()}
        == identities | {"swift-build"},
        "License directories do not match the dependency manifest.",
    )
    for directory in (payload / "licenses").iterdir():
        require(
            directory.is_dir() and any(p.is_file() for p in directory.rglob("*")),
            f"Missing license text: {directory.name}",
        )
    return manifest


def check_binary(binary):
    require(
        output(["/usr/bin/lipo", "-archs", str(binary)]) == "arm64",
        f"Expected arm64 binary: {binary}",
    )
    load_commands = output(["/usr/bin/otool", "-l", str(binary)])
    minimum_versions = re.findall(
        r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:1|MACOS)\s+minos ([0-9.]+)",
        load_commands,
    )
    require(len(minimum_versions) == 1, f"Missing macOS deployment target: {binary}")
    minimum = tuple(int(component) for component in minimum_versions[0].split("."))
    require(
        (minimum + (0, 0, 0))[:3] <= (26, 0, 0),
        "Binary requires a newer OS than the distribution's "
        f"macOS 26 minimum: {binary}",
    )
    dependencies = output(["/usr/bin/otool", "-L", str(binary)]).splitlines()[1:]
    require(dependencies, f"No Mach-O dependency information: {binary}")
    for line in dependencies:
        library = line.strip().split(" (", 1)[0]
        require(
            library.startswith(("/usr/lib/", "/System/Library/")),
            f"Non-system dynamic dependency in {binary.name}: {library}",
        )
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True
    )


def copy_binary(source, destination):
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    load_commands = output(["/usr/bin/otool", "-l", str(destination)])
    # SwiftPM adds producer-toolchain search paths;
    # shipped binaries use system libraries.
    for path in re.findall(
        r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)", load_commands
    ):
        if path.startswith("/") and not path.startswith(
            ("/usr/lib/", "/System/Library/")
        ):
            subprocess.run(
                ["/usr/bin/install_name_tool", "-delete_rpath", path, str(destination)],
                check=True,
            )
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", str(destination)], check=True
    )
    check_binary(destination)


def copy_licenses(source, destination):
    count = 0
    for parent, directories, files in os.walk(source):
        directories[:] = [
            d for d in directories if d not in {".git", ".build", ".swiftpm"}
        ]
        for name in files:
            if name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
                path = Path(parent) / name
                require(
                    not path.is_symlink(), f"License must be a regular file: {path}"
                )
                target = destination / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
                count += 1
    require(count > 0, f"No license texts found: {source}")


def build(args):
    require(
        re.fullmatch(VERSION_PATTERN, args.version),
        "Version must look like v1.2.3 or v1.2.3-beta.1.",
    )
    require(args.jobs > 0, "--jobs must be positive.")
    require(
        platform.system() == "Darwin" and platform.machine() == "arm64",
        "Building this distribution requires an Apple Silicon Mac.",
    )
    source_dir = getattr(args, "source_dir", None)
    if source_dir is None:
        revision = output(["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--verify",
                           "--end-of-options", f"{args.revision}^{{commit}}"])
    else:
        revision = args.source_revision
        if revision is None and args.source_archive is not None:
            with tarfile.open(args.source_archive) as archive:
                revision = archive.pax_headers.get("comment")
        require(re.fullmatch(REVISION_PATTERN, revision or ""),
                "Source archive builds require a Git archive commit comment or --source-revision.")
    environment = dict(os.environ)
    # Keep every build, test, and metadata query on the initially selected toolchain.
    environment["DEVELOPER_DIR"] = environment.get("DEVELOPER_DIR") or output(
        ["/usr/bin/xcode-select", "--print-path"]
    )
    version, build_version = xcode_version(environment)
    empty_directory(args.output_dir)
    directory = args.output_dir.resolve()
    source = directory / "source"
    (directory / "build").mkdir()
    if source_dir is None:
        source.mkdir()
        with tempfile.TemporaryFile() as archive:
            subprocess.run(["git", "-C", str(REPOSITORY_ROOT), "archive", revision],
                           stdout=archive, check=True)
            archive.seek(0)
            subprocess.run(["/usr/bin/tar", "-x", "-C", str(source)], stdin=archive, check=True)
    else:
        source_dir = source_dir.resolve()
        def exclude_build(path, names):
            return [name for name in names if name in (".git", ".build")
                    or (Path(path) / name).resolve() == directory]
        shutil.copytree(source_dir, source, ignore=exclude_build)
    pins = source / DISTRIBUTION_PATH / "ServiceDependencies.resolved"
    shutil.copy2(pins, source / "Package.resolved")
    (directory / "source-revision.txt").write_text(revision + "\n")

    # These options change the dependency graph or service independently of the pins.
    for key in (
        "SWIFTCI_USE_LOCAL_DEPS",
        "SWIFTBUILD_LLBUILD_FWK",
        "SWIFTBUILD_STATIC_LINK",
        "XCBBUILDSERVICE_PATH",
        "SWBBUILDSERVICE_PATH",
    ):
        environment.pop(key, None)
    common = [
        "--configuration",
        "release",
        "--arch",
        "arm64",
        "--jobs",
        str(args.jobs),
        "--build-system",
        "swiftbuild",
        "--cache-path",
        str(directory / "build/cache"),
        "--config-path",
        str(directory / "build/config"),
        "--security-path",
        str(directory / "build/security"),
    ]
    if getattr(args, "disable_sandbox", False):
        common.append("--disable-sandbox")
    service_args = [
        *common,
        "--package-path",
        str(source),
        "--scratch-path",
        str(directory / "build/service"),
        "--force-resolved-versions",
    ]
    cli_args = [
        *common,
        "--package-path",
        str(source / "Utilities/CustomXcodeBuildService"),
        "--scratch-path",
        str(directory / "build/cli"),
    ]
    print(f"Xcode {version}\nBuild version {build_version}", flush=True)
    subprocess.run(
        ["/usr/bin/xcrun", "swift", "--version"], env=environment, check=True
    )
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swift",
            "build",
            *service_args,
            "--product",
            "SWBBuildServiceBundle",
        ],
        env=environment,
        check=True,
    )
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swift",
            "build",
            *cli_args,
            "--product",
            "custom-xcode-build-service",
        ],
        env=environment,
        check=True,
    )
    service_bin = output(
        ["/usr/bin/xcrun", "swift", "build", *service_args, "--show-bin-path"],
        env=environment,
    )
    cli_bin = output(
        ["/usr/bin/xcrun", "swift", "build", *cli_args, "--show-bin-path"],
        env=environment,
    )
    subprocess.run(
        [
            sys.executable,
            str(source / DISTRIBUTION_PATH / "release.py"),
            "stage",
            "--build-dir",
            str(directory),
            "--service-bin",
            service_bin,
            "--cli-bin",
            cli_bin,
            "--version",
            args.version,
        ],
        env=environment,
        check=True,
    )
    print(f"Built payload: {directory / 'payload'}")


def stage(args):
    source = args.build_dir / "source"
    payload = args.build_dir / "payload"
    empty_directory(payload)
    require(re.fullmatch(VERSION_PATTERN, args.version), "Invalid release version.")
    revision = (args.build_dir / "source-revision.txt").read_text().strip()
    require(re.fullmatch(REVISION_PATTERN, revision), "Invalid source revision.")
    version, build_version = xcode_version()
    service_dir = payload / SERVICE_BUNDLE
    (payload / SERVICE_BINARY).parent.mkdir(parents=True)
    (payload / HOST_PLUGIN_BINARY).parent.mkdir(parents=True)
    (payload / "bin").mkdir()
    copy_binary(
        args.service_bin / "SWBBuildServiceBundle",
        payload / SERVICE_BINARY,
    )
    copy_binary(
        args.cli_bin / "custom-xcode-build-service",
        payload / "bin/custom-xcode-build-service",
    )
    plugin = args.build_dir / "build/HostPlatformPlugins"
    subprocess.run(
        [
            "/usr/bin/xcrun", "clang", "-bundle", "-fobjc-arc", "-framework", "Foundation",
            "-arch", "arm64", "-mmacosx-version-min=26.0", "-Wall", "-Wextra", "-Werror",
            str(source / DISTRIBUTION_PATH / "HostPlatformPlugins.m"), "-o", str(plugin),
        ],
        check=True,
    )
    copy_binary(plugin, payload / HOST_PLUGIN_BINARY)
    for contents, identifier, executable in (
        (SERVICE_BUNDLE, "io.github.lynnswap.SWBBuildService", "SWBBuildServiceBundle"),
        (HOST_PLUGIN / "Contents", "io.github.lynnswap.HostPlatformPlugins", "HostPlatformPlugins"),
    ):
        (payload / contents / "Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier=identifier, CFBundleExecutable=executable,
            CFBundlePackageType="BNDL",
        )))
    require(
        tuple(sorted(p.name for p in args.service_bin.glob("SwiftBuild_*.bundle")))
        == BUNDLES,
        "Built resource bundles differ from the distribution contract.",
    )
    for bundle in BUNDLES:
        regular_tree(args.service_bin / bundle)
        shutil.copytree(args.service_bin / bundle, service_dir / bundle)
    # SwiftPM's Bundle.module accessors resolve resources at Bundle.main.bundleURL.
    # A shallow bundle keeps those paths valid and can seal them when signed.
    for bundle in (HOST_PLUGIN, SERVICE_BUNDLE):
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(payload / bundle)],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(payload / bundle)],
            check=True,
        )
    pins = json.loads(
        (source / DISTRIBUTION_PATH / "ServiceDependencies.resolved").read_text()
    )["pins"]
    dependencies = []
    for pin in pins:
        checkout = args.build_dir / "build/service/checkouts" / pin["identity"]
        actual_revision = output(["git", "-C", str(checkout), "rev-parse", "HEAD"])
        require(
            actual_revision == pin["state"]["revision"],
            f"Dependency revision changed: {pin['identity']}",
        )
        dependencies.append({"identity": pin["identity"], "revision": actual_revision})
        copy_licenses(checkout, payload / "licenses" / pin["identity"])
    copy_licenses(source, payload / "licenses/swift-build")
    manifest = dict(
        schemaVersion=2,
        version=args.version,
        sourceRevision=revision,
        xcodeVersion=version,
        xcodeBuildVersion=build_version,
        architecture="arm64",
        minimumMacOSVersion="26.0",
        resourceBundles=list(BUNDLES),
        dependencies=sorted(dependencies, key=lambda item: item["identity"]),
    )
    (payload / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    validate_payload(payload)


def checksum_file(directory):
    return "".join(
        f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
        for name in ASSETS
    )


def package(args):
    payload = args.build_dir / "payload"
    manifest = validate_payload(payload)
    empty_directory(args.output_dir)
    # Fixed tar/gzip metadata makes repackaging the same payload byte-for-byte stable.
    with (args.output_dir / ARCHIVE).open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(
                fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
            ) as archive:
                for path in sorted(payload.rglob("*")):
                    info = archive.gettarinfo(
                        str(path), arcname=path.relative_to(payload).as_posix()
                    )
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    info.pax_headers = {}
                    info.mode = (
                        0o755 if path.is_dir() or os.access(path, os.X_OK) else 0o644
                    )
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
            require(
                not path.is_absolute()
                and ".." not in path.parts
                and str(path) == member.name.rstrip("/"),
                f"Unsafe archive path: {member.name}",
            )
            require(str(path) not in names, f"Duplicate archive entry: {member.name}")
            names.add(str(path))
            require(
                member.isdir() or member.isfile(),
                f"Non-regular archive entry: {member.name}",
            )
            require(
                not member.mode & 0o7000, f"Unsafe archive permissions: {member.name}"
            )
        # All paths and types are checked before any extraction, including hard links.
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open(
                    "xb"
                ) as output_file:
                    shutil.copyfileobj(source, output_file)
            target.chmod(member.mode)


def smoke_build(payload, temporary, manifest, fixture=None):
    fixture = fixture or REPOSITORY_ROOT / "Tests/SwiftBuildTests/TestData/CommandLineTool"
    shutil.copytree(fixture, temporary / "Smoke")
    service = service_path(payload, manifest)
    environment = dict(os.environ)
    environment.pop("SWBBUILDSERVICE_PATH", None)
    environment.update(
        XCBBUILDSERVICE_PATH=str(service), DisableConcurrentDependencyResolution="0"
    )
    command = [
        "/usr/bin/xcrun",
        "xcodebuild",
        "-project",
        str(temporary / "Smoke/CommandLineTool.xcodeproj"),
        "-target",
        "CommandLineTool",
        "-configuration",
        "Release",
        "-sdk",
        "macosx",
        "CODE_SIGNING_ALLOWED=NO",
        "MACOSX_DEPLOYMENT_TARGET=26.0",
        "ALWAYS_SEARCH_USER_PATHS=NO",
        f"SYMROOT={temporary / 'products'}",
        f"OBJROOT={temporary / 'intermediates'}",
        "build",
    ]
    run_xcodebuild(command, environment, service)
    subprocess.run([str(temporary / "products/Release/CommandLineTool")], check=True)


def run_xcodebuild(command, environment, service, cwd=None):
    observed_service = False
    service = service.resolve()
    deadline = time.monotonic() + 600
    with subprocess.Popen(command, env=environment, cwd=cwd) as process:
        try:
            while True:
                # Xcode inspects the selected Mach-O;
                # a shell wrapper cannot prove selection.
                processes = output(["/bin/ps", "-axo", "pid=,ppid=,comm="]).splitlines()
                for row in processes:
                    fields = row.split(maxsplit=2)
                    if len(fields) == 3 and fields[1] == str(process.pid) and Path(fields[2]).resolve() == service:
                        observed_service = True
                return_code = process.poll()
                if return_code is not None:
                    require(
                        return_code == 0,
                        f"Relocated Xcode build failed (exit {return_code}).",
                    )
                    break
                require(
                    time.monotonic() < deadline,
                    "Relocated Xcode build timed out after 10 minutes.",
                )
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()  # ignore-unacceptable-language: subprocess API
    require(observed_service, "Xcode did not invoke the relocated custom service.")


def smoke_swift(payload, temporary, manifest, disable_sandbox=False, xcode_package_tests=True):
    package = temporary / "SwiftPMSmoke"
    (package / "Sources/Smoke").mkdir(parents=True)
    (package / "Tests/SmokeTests").mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Smoke", targets: [
    .executableTarget(name: "Smoke"),
    .testTarget(name: "SmokeTests", dependencies: ["Smoke"]),
])
''')
    (package / "Sources/Smoke/main.swift").write_text('func message() -> String { "SwiftPM smoke passed" }\nprint(message())\n')
    (package / "Tests/SmokeTests/SmokeTests.swift").write_text('''import Testing
@testable import Smoke
@Test func smoke() { #expect(message() == "SwiftPM smoke passed") }
''')
    environment = dict(os.environ)
    environment.pop("SWBBUILDSERVICE_PATH", None)
    service = service_path(payload, manifest)
    environment.update(
        XCBBUILDSERVICE_PATH=str(service), DisableConcurrentDependencyResolution="0"
    )
    for command in ("build", "run", "test"):
        subprocess.run(
            ["/usr/bin/xcrun", "swift", command, "--build-system", "swiftbuild",
             *( ["--disable-sandbox"] if disable_sandbox else []), "--package-path", str(package)],
            env=environment, check=True, timeout=600,
        )
    if not xcode_package_tests:
        return
    run_xcodebuild(
        ["/usr/bin/xcrun", "xcodebuild", "-scheme", "Smoke", "-testPlan", "Smoke",
         "-destination", "platform=macOS,arch=arm64",
         "-derivedDataPath", str(temporary / "SwiftDerivedData"),
         "MACOSX_DEPLOYMENT_TARGET=26.0", "test"],
        environment, service, cwd=package,
    )
    smoke_system_library(payload, temporary, manifest)


def smoke_system_library(payload, temporary, manifest):
    package = temporary / "SystemLibrarySmoke"
    (package / "Sources/Smoke").mkdir(parents=True)
    (package / "Tests/SmokeTests").mkdir(parents=True)

    # Both the executable and a dynamic library use the same system-library
    # consumer, exercising Xcode's promotion of shared package targets.
    sqlite = package / "SQLiteConsumer"
    (sqlite / "Sources/SystemSQLite").mkdir(parents=True)
    (sqlite / "Sources/SQLiteConsumer").mkdir(parents=True)
    (sqlite / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SQLiteConsumer",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SQLiteConsumer", targets: ["SQLiteConsumer"])],
    targets: [
        .systemLibrary(name: "SystemSQLite"),
        .target(name: "SQLiteConsumer", dependencies: ["SystemSQLite"]),
    ]
)
''')
    (sqlite / "Sources/SystemSQLite/module.modulemap").write_text('''module SystemSQLite [system] {
    header "shim.h"
    link "sqlite3"
    export *
}
''')
    (sqlite / "Sources/SystemSQLite/shim.h").write_text('#include <sqlite3.h>\n')
    (sqlite / "Sources/SQLiteConsumer/SQLiteConsumer.swift").write_text('''import SystemSQLite
public func sqliteVersion() -> String { String(cString: sqlite3_libversion()) }
''')
    wrapper = package / "Wrapper"
    (wrapper / "Sources/Wrapper").mkdir(parents=True)
    (wrapper / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Wrapper",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Wrapper", type: .dynamic, targets: ["Wrapper"])],
    dependencies: [.package(path: "../SQLiteConsumer")],
    targets: [.target(name: "Wrapper", dependencies: [
        .product(name: "SQLiteConsumer", package: "SQLiteConsumer"),
    ])]
)
''')
    (wrapper / "Sources/Wrapper/Wrapper.swift").write_text('''import SQLiteConsumer
public func wrappedVersion() -> String { sqliteVersion() }
''')
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Smoke",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "SQLiteConsumer"), .package(path: "Wrapper")],
    targets: [
        .executableTarget(name: "Smoke", dependencies: [
            .product(name: "SQLiteConsumer", package: "SQLiteConsumer"),
            .product(name: "Wrapper", package: "Wrapper"),
        ]),
        .testTarget(name: "SmokeTests", dependencies: ["Smoke"]),
    ]
)
''')
    (package / "Sources/Smoke/main.swift").write_text('''import SQLiteConsumer
import Wrapper
func sqliteVersionsMatch() -> Bool {
    let version = sqliteVersion()
    return !version.isEmpty && version == wrappedVersion()
}
print(sqliteVersionsMatch())
''')
    (package / "Tests/SmokeTests/SmokeTests.swift").write_text('''import Testing
@testable import Smoke
@Test func sqliteLinkage() { #expect(sqliteVersionsMatch()) }
''')
    environment = dict(os.environ)
    environment.pop("SWBBUILDSERVICE_PATH", None)
    service = service_path(payload, manifest)
    environment.update(
        XCBBUILDSERVICE_PATH=str(service), DisableConcurrentDependencyResolution="0"
    )
    run_xcodebuild(
        ["/usr/bin/xcrun", "xcodebuild", "-scheme", "Smoke", "-testPlan", "Smoke",
         "-destination", "platform=macOS,arch=arm64",
         "-derivedDataPath", str(temporary / "SystemLibraryDerivedData"),
         "MACOSX_DEPLOYMENT_TARGET=26.0", "EAGER_LINKING=YES", "test"],
        environment, service, cwd=package,
    )


def verify(args):
    require(
        {p.name for p in args.release_dir.iterdir()} == {*ASSETS, "SHA256SUMS.txt"},
        "Unexpected release asset set.",
    )
    require(
        (args.release_dir / "SHA256SUMS.txt").read_text()
        == checksum_file(args.release_dir),
        "Release asset checksums do not match.",
    )
    with tempfile.TemporaryDirectory(prefix="custom service relocation ") as directory:
        temporary = Path(directory)
        payload = temporary / "payload"
        payload.mkdir()
        extract_archive(args.release_dir / ARCHIVE, payload)
        manifest = validate_payload(payload)
        version, build_version = xcode_version()
        print(
            f"Verifying with Xcode {version} ({build_version}); "
            f"built with Xcode {manifest['xcodeVersion']} "
            f"({manifest['xcodeBuildVersion']}).",
            flush=True,
        )
        binaries = [payload / "bin/custom-xcode-build-service", service_path(payload, manifest)]
        if manifest["schemaVersion"] == 2:
            binaries.append(payload / HOST_PLUGIN_BINARY)
        for binary in binaries:
            check_binary(binary)
        subprocess.run(
            [str(payload / "bin/custom-xcode-build-service"), "--help"], check=True
        )
        smoke_build(payload, temporary, manifest)
        smoke_swift(payload, temporary, manifest)
    print(
        "Verified checksums, archive layout, signatures, system libraries, "
        "relocated Xcode C build and Swift tests, and SwiftPM build/run/test "
        "with the service override."
    )


def source_package(args):
    require(re.fullmatch(VERSION_PATTERN, args.version), "Use a vX.Y.Z release tag.")
    revision = output(["git", "-C", str(REPOSITORY_ROOT), "rev-parse", "--verify", "--end-of-options", f"{args.revision}^{{commit}}"])
    # Compare source entries, since GitHub controls the public archive's compression.
    def contents(archive):
        entries = archive.getmembers()
        root = entries[0].name.split("/")[0]
        return sorted((entry.name.partition("/")[2], entry.type, entry.mode & 0o111,
                       entry.linkname, archive.extractfile(entry).read() if entry.isfile() else b"")
                      for entry in entries if entry.name.rstrip("/") != root)
    with tempfile.TemporaryFile() as source:
        subprocess.run(["git", "-C", str(REPOSITORY_ROOT), "archive", "--prefix=source/", revision], stdout=source, check=True)
        source.seek(0)
        with tarfile.open(fileobj=source) as expected, tarfile.open(args.source_archive) as downloaded:
            require(contents(expected) == contents(downloaded), "Public source archive differs from the selected commit.")
    empty_directory(args.output_dir)
    archive_name = f"custom-xcode-build-service-{args.version.removeprefix('v')}.tar.gz"
    shutil.copyfile(args.source_archive, args.output_dir / archive_name)
    digest = hashlib.sha256(args.source_archive.read_bytes()).hexdigest()
    template = (REPOSITORY_ROOT / DISTRIBUTION_PATH / "custom-xcode-build-service.rb.in").read_text()
    version = args.version.removeprefix("v")
    # Homebrew's URL parser drops some prerelease suffixes. Stable versions stay
    # inferred so updating the URL cannot leave a stale explicit version behind.
    explicit_version = f'  version "{version}"\n' if "-" in version else ""
    formula = (template.replace("@EXPLICIT_VERSION@\n", explicit_version)
               .replace("@VERSION@", version).replace("@SHA256@", digest))
    (args.output_dir / "custom-xcode-build-service.rb").write_text(formula)
    names = (archive_name, "custom-xcode-build-service.rb")
    (args.output_dir / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256((args.output_dir / name).read_bytes()).hexdigest()}  {name}\n" for name in names))


def verify_payload(args):
    payload = args.payload.resolve()
    manifest = validate_payload(payload)
    for binary in [payload / "bin/custom-xcode-build-service", service_path(payload, manifest), payload / HOST_PLUGIN_BINARY]:
        check_binary(binary)
    with tempfile.TemporaryDirectory(prefix="custom-service-bottle-test-") as directory:
        temporary = Path(directory)
        smoke_build(payload, temporary, manifest, args.fixture_dir)
        smoke_swift(payload, temporary, manifest, args.disable_sandbox,
                    xcode_package_tests=not args.skip_xcode_package_tests)
    print("Verified installed payload: signatures, Xcode C build, and SwiftPM build/run/test.")
    print("Xcode Swift package tests were skipped." if args.skip_xcode_package_tests
          else "Xcode Swift package tests passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    building = commands.add_parser(
        "build",
        help="Build committed source with the selected Xcode on Apple Silicon",
        description="Build committed source in an isolated directory. "
        "The output must be "
        "absent or empty; source, builds, and payload remain there. Does not install.",
    )
    building.add_argument("--version", required=True)
    building.add_argument("--output-dir", type=Path, required=True)
    building.add_argument("--revision", default="HEAD")
    building.add_argument("--jobs", type=int, default=2)
    building.add_argument("--disable-sandbox", action="store_true", help="Avoid nesting SwiftPM's sandbox inside Homebrew's")
    building.add_argument("--source-dir", type=Path, help="Build an extracted source archive without .git")
    building.add_argument("--source-revision", help="Commit represented by --source-dir")
    building.add_argument("--source-archive", type=Path, help="Read the source commit from a Git archive")
    staging = commands.add_parser(
        "stage", help="Stage built binaries, resources, licenses, and metadata"
    )
    staging.add_argument("--build-dir", type=Path, required=True)
    staging.add_argument("--service-bin", type=Path, required=True)
    staging.add_argument("--cli-bin", type=Path, required=True)
    staging.add_argument("--version", required=True)
    packaging = commands.add_parser(
        "package", help="Package an existing build; the output must be absent or empty"
    )
    packaging.add_argument("--build-dir", type=Path, required=True)
    packaging.add_argument("--output-dir", type=Path, required=True)
    verification = commands.add_parser(
        "verify", help="Verify a release with the selected Xcode; does not install"
    )
    verification.add_argument("--release-dir", type=Path, required=True)
    sources = commands.add_parser("source", help="Prepare a source archive and Formula for a tagged release")
    sources.add_argument("--version", required=True)
    sources.add_argument("--revision", default="HEAD")
    sources.add_argument("--source-archive", type=Path, required=True)
    sources.add_argument("--output-dir", type=Path, required=True)
    installed = commands.add_parser("verify-payload", help="Run build smoke tests with an installed Homebrew payload")
    installed.add_argument("--payload", type=Path, required=True)
    installed.add_argument("--disable-sandbox", action="store_true")
    installed.add_argument("--skip-xcode-package-tests", action="store_true",
                           help="Skip Xcode package manifests, which require their own sandbox")
    installed.add_argument("--fixture-dir", type=Path, default=REPOSITORY_ROOT / "Tests/SwiftBuildTests/TestData/CommandLineTool")
    args = parser.parse_args()
    try:
        {"build": build, "stage": stage, "package": package, "verify": verify, "source": source_package, "verify-payload": verify_payload}[
            args.command
        ](args)
    except (
        ValueError,
        KeyError,
        OSError,
        subprocess.SubprocessError,
        tarfile.TarError,
    ) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
