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
- Xcode 27 selected in **Settings > Locations > Command Line Tools**, matching
  the exact build listed in the [release notes](https://github.com/lynnswap/swift-build/releases).
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
<summary>Other install options</summary>

Install a specific version using its release tag:

```sh
curl -fsSL https://github.com/lynnswap/swift-build/releases/download/custom-v0.1.1/install.sh | sh
```

For a downloaded and verified archive, extract it and run from its root:

```sh
./bin/custom-xcode-build-service install
```

Without `--package`, `install` uses the package containing that executable.
Keep its resource bundles beside the service binary.

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
requires an installed release and its exact Xcode build; selecting bundled also
works after Xcode has been updated or removed.

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
running. Running services can still reflect the previous choice until
applications are restarted. If the launchd settings differ from the saved
selection, status reports the mismatch and the command to reapply your choice.

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

Run checks from the repository root:

```sh
swift test --package-path Utilities/CustomXcodeBuildService
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

<details>
<summary>Build and publish a release</summary>

From the repository root, use new or empty output directories:

```sh
cd Utilities/CustomXcodeBuildService
python3 Distribution/release.py build \
    --version custom-v0.1.1 --output-dir /tmp/custom-service-build
python3 Distribution/release.py package \
    --build-dir /tmp/custom-service-build --output-dir /tmp/custom-service-release
python3 Distribution/release.py verify \
    --release-dir /tmp/custom-service-release
```

Builds use committed source and pinned dependencies in an isolated directory.
The output contains the archive, checksums, and a version-specific installer.

Create a draft GitHub Release for the `custom-v*` tag and write its title and
release notes there. Then push that tag to run the
[release workflow](../../.github/workflows/custom-xcode-build-service.yml), which
uploads the verified assets and publishes the draft without changing its title
or notes.
Stable releases become **Latest**; prereleases do not replace it.

</details>
