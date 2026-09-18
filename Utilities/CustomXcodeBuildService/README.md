# Custom Xcode Build Service

Use this fork's prebuilt Swift Build service with Xcode. Install it once, then
open workspaces from Finder or Xcode as usual. The selection applies to all
projects for your macOS user account and is restored at login.

## Commands

Use `custom-xcode-build-service <command>`:

| Command | What it does |
| --- | --- |
| `install [--package DIR]` | Install or update an extracted release package. |
| `use custom` | Select the installed custom service, including after login. |
| `use bundled` | Select Xcode's bundled service, keeping the CLI and installed releases. |
| `status` | Show the installed release, selected service, and running services. |
| `uninstall` | Remove the tool and restore Xcode's bundled service. |
| `activate` | Reapply custom if selected; the login helper runs this automatically. |
| `--help` | Show usage and options. |

## Requirements

- Apple silicon and macOS 26+.
- Xcode selected in **Settings > Locations > Command Line Tools** for builds.
- A terminal in your logged-in macOS desktop session. Run without `sudo`.

## Install or Update

```sh
curl -fsSL https://github.com/lynnswap/swift-build/releases/latest/download/install.sh | sh
```

This downloads and verifies the prebuilt release. The first install selects the
custom service. Run the same command to update; updates preserve your choice of
custom or bundled service.

The CLI is installed in `~/.local/bin`. If that directory is not on your `PATH`,
add the following to your shell configuration (`~/.zshrc` for zsh):

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Quit and reopen **Xcode, your terminal application, and AI agent applications**.
Start terminal-based agents from the restarted terminal. Then open a workspace
or run `make` / `xcodebuild` as usual.

<details>
<summary>Install a downloaded archive</summary>

For a downloaded and verified archive, extract it and run from its root:

```sh
./bin/custom-xcode-build-service install
```

Without `--package`, `install` uses the package containing that executable.
Keep the extracted directory structure intact.

</details>

## Select a Service

Switch to Xcode's bundled service while keeping the custom service installed:

```sh
custom-xcode-build-service use bundled
```

Switch back to the installed custom service:

```sh
custom-xcode-build-service use custom
```

Your choice applies to all projects for your macOS user account and persists
across logins and updates. Repeating either command succeeds. Selecting custom
requires an installed release. Xcode updates do not change your selection.
The Xcode version recorded in a release identifies its build toolchain; it does
not restrict which Xcode can use it. Compatibility depends on the client/service
protocol and the selected SDK and tools.

SwiftPM's Swift Build backend continues to use its in-process engine while custom
is selected. The service bundle loads platform plugins from that engine's own
Xcode installation, so changing `DEVELOPER_DIR` or `xcode-select` does not require
reinstalling the custom service. Xcode and `xcodebuild` use the custom executable.

After switching, quit and reopen **Xcode, your terminal application, and AI agent
applications**. Start terminal-based agents from the restarted terminal.
Existing processes retain their previous environment. The command does not
close applications or stop builds.

Check the saved selection and the current environment:

```sh
custom-xcode-build-service status
```

Status shows the installed release, the selected service (`custom` or `bundled`),
the launchd settings for future processes, and the build services actually
running. The displayed Xcode version records which Xcode built the release.
Running services can still reflect the previous choice until
applications are restarted. If the launchd settings differ from the saved
selection, status reports the mismatch and the command to reapply your choice.
If the installed release or login configuration cannot be read, status includes
the error alongside launchd settings and running services and exits with failure.

## Uninstall

Quit Xcode and let command-line builds finish, then run:

```sh
custom-xcode-build-service uninstall
```

Restart terminal and AI agent applications afterward to use Xcode's bundled
service in new builds.

## Configuration

While custom is selected, the tool manages these settings through `launchctl`:

| Setting | Value |
| --- | --- |
| `XCBBUILDSERVICE_PATH` | The installed service executable. |
| `DisableConcurrentDependencyResolution` | `0` (parallel dependency resolution). |

Releases are stored in `~/Library/Developer/CustomXcodeBuildService`. When custom
is selected, a helper in `~/Library/LaunchAgents` reapplies it at login. Selecting
bundled removes that helper and the tool's environment overrides while keeping
the installed releases and CLI. If macOS restores Xcode before the custom helper
runs, restart Xcode after checking `status`.

## Development

### Build and install locally

From the repository root, build and install the committed `HEAD`:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py install
```

The command generates a local version, builds in a temporary directory, installs
the result, and selects custom. It removes the temporary directory afterward.
Commit source changes before running it; uncommitted changes are not included.
The build isolates inherited service overrides, so it can run while an older
custom service is selected. Installation copies the payload into the managed
installation directory; no GitHub release is needed.

Quit and reopen **Xcode, your terminal application, and AI agent applications**
after installation. Existing processes keep their previous service selection.

### Checks

Run checks from the repository root:

```sh
swift test --package-path Utilities/CustomXcodeBuildService
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

This fork's CI tests the installer and Xcode compatibility. It builds one service
artifact and discovers installed Xcode 26 and 27 releases on the `macos-26` and
`xcode-27` hosted runners. It tests every stable release and the latest beta across
both inventories, once per Xcode build, using the runner where it was found.
The Xcode and macOS versions are printed for each run. This selection defines
test coverage, not an installation allowlist.

<details>
<summary>Build and publish a release</summary>

With the intended `custom-v*` release tag checked out, run from the repository
root. The version comes from that tag:

```sh
custom_release_version="$(git describe --tags --exact-match HEAD)"
custom_build_dir="$(mktemp -d /tmp/custom-service-build.XXXXXX)"
custom_release_dir="$(mktemp -d /tmp/custom-service-release.XXXXXX)"

python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
    --version "$custom_release_version" --output-dir "$custom_build_dir" &&
python3 Utilities/CustomXcodeBuildService/Distribution/release.py package \
    --build-dir "$custom_build_dir" --output-dir "$custom_release_dir" &&
python3 Utilities/CustomXcodeBuildService/Distribution/release.py verify \
    --release-dir "$custom_release_dir"
```

Builds use committed source and pinned dependencies in an isolated directory.
The output contains the archive, checksums, and a version-specific installer.
Verification builds a C project, runs Swift tests through `xcodebuild`, and runs
`swift build`, `swift run`, and `swift test` with the extracted custom service
selected. It uses the currently selected Xcode without requiring its build number
to match the release metadata.

Create a draft GitHub Release for the `custom-v*` tag and write its title and
release notes there. Then push that tag to run the
[release workflow](../../.github/workflows/custom-xcode-build-service.yml), which
uploads the verified assets and publishes the draft without changing its title
or notes.
Stable releases become **Latest**; prereleases do not replace it.

</details>
