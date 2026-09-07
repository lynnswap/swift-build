# Custom Xcode Build Service

Use this fork's prebuilt Swift Build service with ordinary Xcode launches, including opening a workspace from Finder. The release contains the service, its resource bundles, and the `custom-xcode-build-service` management command. Installation does not build Swift sources or modify Xcode.app.

The setting applies to the current user's Xcode processes across all projects. It is not a workspace setting. Existing Xcode and build-service processes retain their previous environment until they exit.

## Requirements

- An Apple silicon Mac running macOS 26 or later.
- Xcode 27 selected in Xcode's **Settings > Locations > Command Line Tools**.
- A custom-service release built and verified with that exact Xcode build version. The release's `manifest.json` records this information, and installation checks it.

Use the command as your normal logged-in user, without `sudo`. It must run in your GUI login session.

## Install a published release

Download `install.sh` from the desired `custom-v*` release on the fork's [Releases page](https://github.com/lynnswap/swift-build/releases), then run:

```sh
sh install.sh
```

The installer downloads the archive for that release, verifies its SHA256 checksum, and invokes its management command. A release must be published before this download method is available.

If you have already downloaded and verified the archive, extract it and run this from its root directory:

```sh
./bin/custom-xcode-build-service install --package .
```

The installation lives in `~/Library/Developer/CustomXcodeBuildService`. Each release has its own directory under `versions`, and the `current` symlink selects the release. The command is made available at `~/.local/bin/custom-xcode-build-service`.

Quit and reopen Xcode after installation. You can then continue to open workspaces from Finder or use your usual Xcode shortcut. The command does not close Xcode or stop builds for you.

## Check the selected service

```sh
~/.local/bin/custom-xcode-build-service status
```

Status distinguishes the installed release, the service selected for future processes, and services that are actually running. If `~/.local/bin` is on your `PATH`, you can omit the directory prefix.

The command sets `XCBBUILDSERVICE_PATH` to the installed service executable and `DisableConcurrentDependencyResolution` to `0` through `launchctl`. It leaves persistent Xcode and Swift Build defaults unchanged. Existing settings belonging to another installation are reported instead of being overwritten.

A LaunchAgent at `~/Library/LaunchAgents/io.github.lynnswap.custom-xcode-build-service.plist` reapplies the selection when you log in. The helper runs once; it is not a resident service. If macOS restores Xcode before the helper runs, quit and reopen Xcode after checking status.

## Update or remove

To update, run the new release's `install.sh`. The new release is prepared before the selected version is changed. Old version directories remain available to processes that still use them. Restart Xcode to start using the new version.

To restore Xcode's bundled service, first quit Xcode and allow any command-line builds using the custom service to finish, then run:

```sh
~/.local/bin/custom-xcode-build-service uninstall
```

Uninstall removes the tool's login configuration, environment selection, command, and release payloads. It refuses to remove files while your Xcode, `xcodebuild`, or an installed service is running. It remains available if Xcode has been updated or removed. The installation directory retains only `.owner` and `.lock`, so simultaneous commands and later reinstalls continue to share the same lock.

An already-running terminal does not receive changes to the launchd environment. Restart terminal sessions that inherited the old selection. For a build from an existing terminal, explicitly pass the selected environment:

```sh
(
    service_path="$(launchctl getenv XCBBUILDSERVICE_PATH)"
    test -x "$service_path" || { echo "No installed custom service is selected." >&2; exit 1; }
    env XCBBUILDSERVICE_PATH="$service_path" DisableConcurrentDependencyResolution=0 \
        xcodebuild -workspace MyApp.xcworkspace -scheme MyApp build
)
```

## Build and package a release

Release creation requires committed source and Xcode 27. The build runs from an isolated copy of `HEAD` (or the explicit `--revision` commit) and uses the pinned service dependencies in `.github/custom-build-service/ServiceDependencies.resolved`. Uncommitted edits are not part of the release. The developer's checkout and `Package.resolved` are not rewritten.

From the repository root, use new or empty output directories:

```sh
Utilities/build-custom-xcode-build-service.sh \
    --version custom-v0.1.0 --output-dir /tmp/custom-service-build
Utilities/package-custom-xcode-build-service.sh \
    --build-dir /tmp/custom-service-build --output-dir /tmp/custom-service-release
Utilities/verify-custom-xcode-build-service.sh \
    --release-dir /tmp/custom-service-release
```

The release files are:

- `custom-xcode-build-service-darwin-arm64.tar.gz`: the command, service, adjacent resource bundles, licenses, and manifest.
- `SHA256SUMS.txt`: the checksums for the release files.
- `install.sh`: the download bootstrap with its repository and release version fixed at packaging time.

The manifest records the source revision, dependency revisions, architecture, minimum macOS version, and Xcode version used to build the release. Verify the extracted archive as a complete installation; copying only `SWBBuildServiceBundle` omits its required resources.

The **Custom Xcode build service** GitHub Actions workflow builds and verifies artifacts for relevant pull requests and manual runs. A manual run does not publish a release. Pushing a `custom-v*` tag to `lynnswap/swift-build` runs the same checks and publishes the verified assets for that tag. The `custom-` namespace keeps these distributions separate from upstream Swift release tags. Release builds default to two parallel jobs; `--jobs` can change the local build limit.

## Development

The management command is a separate macOS-only Swift package. It does not import the build-system libraries: installing a local tool has different platform and dependency requirements from Swift Build's cross-platform package. The two executables share a release archive and manifest, not a Swift API.

```sh
swift test --package-path Utilities/CustomXcodeBuildService
python3 Utilities/Tests/test_custom_xcode_build_service_installer.py
python3 -m unittest discover -s .github/custom-build-service -p 'test_*.py'
```

The management tests use temporary installation directories and a command runner at the process boundary. They do not change your login environment or stop Xcode.
