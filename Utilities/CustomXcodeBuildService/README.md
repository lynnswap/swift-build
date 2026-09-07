# Custom Xcode Build Service

Use this fork's prebuilt Swift Build service with Xcode. Install it once, then
open workspaces from Finder or Xcode as usual. The selection applies to all
projects for your macOS user account and is restored at login.

## Commands

Use `custom-xcode-build-service <command>`:

| Command | What it does |
| --- | --- |
| `install [--package DIR]` | Install an extracted release package. |
| `status` | Show the installed release, selected service, and running services. |
| `uninstall` | Remove the tool and restore Xcode's bundled service. |
| `activate` | Reapply the selection; the login helper runs this automatically. |
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

This downloads and verifies the prebuilt release. Run the same command to update.

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

## Uninstall

Quit Xcode and let command-line builds finish, then run:

```sh
custom-xcode-build-service uninstall
```

Restart terminal and AI agent applications afterward to use Xcode's bundled
service in new builds.

## Configuration

The tool manages these settings through `launchctl`:

| Setting | Value |
| --- | --- |
| `XCBBUILDSERVICE_PATH` | The installed service executable. |
| `DisableConcurrentDependencyResolution` | `0` (parallel dependency resolution). |

Releases are stored in `~/Library/Developer/CustomXcodeBuildService`. A helper
in `~/Library/LaunchAgents` reapplies the selection at login. If macOS restores
Xcode before the helper runs, restart Xcode after checking `status`.

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
