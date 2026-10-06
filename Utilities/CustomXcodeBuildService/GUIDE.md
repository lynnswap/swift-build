# Custom Xcode Build Service guide

[Back to README](README.md)

## Installation requirements

Homebrew provides a prebuilt bottle for macOS 26 and later. Source builds and
`brew test` require Xcode 27 or later. The tap builds the bottle with Xcode 27 on
the `xcode-27` runner (macOS 27), targeting macOS 26.

The Xcode version in the package manifest records the build toolchain. It does
not restrict which client Xcode can use the service.

## Read the status output

```sh
custom-xcode-build-service status
```

| Field | Meaning |
| --- | --- |
| `Installed` | Version of the package shipped with the CLI you invoked. |
| `Selected service` | Saved selection: `custom` or `bundled`. |
| `Selected custom package` | Version and path of the selected custom package. |
| `Built with Xcode` | Xcode used to build the package shipped with this CLI. |
| `Launchd selection` | Service settings for newly started apps. |
| `Running build services` | This user's running build services. Managed processes have a `[managed custom service]` label. |

`Installed` and `Selected custom package` can differ when you use both Homebrew
and local builds. `Launchd selection` alone does not show which service an
already running Xcode uses.

If part of the inspection fails, `status` still reports the readable information,
along with errors and a nonzero exit status. Use `custom-xcode-build-service --version`
to read just the packaged version without accessing desktop settings.

If macOS restores Xcode at login before the helper applies the custom settings,
check `status` and restart Xcode. Xcode Service can also keep running after the
Xcode or AI app UI closes.

## Run outside a desktop session

Selecting a service requires a logged-in macOS desktop session. No administrator
authentication is needed in that session. From a Background session, the CLI
requests `sudo` to enter the desktop session, then applies settings as your
original user.

`status` never requests authentication. To inspect desktop settings from a
Background session, invoke it with `sudo` and the full CLI path:

```sh
sudo "$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" status
```

## Upgrade behavior

The Homebrew selection uses the stable `opt` path to follow package upgrades.
Running services keep their loaded code, so run `reload` after upgrading.

`reload` sends a termination request to this user's managed custom services.
Clients start the selected service on demand. Xcode and MCP clients stay running;
retry any requests interrupted by the reload.

Installing or upgrading the Formula does not change the saved selection.
`reload` and `activate` also preserve it, including a selected local build.
To select another package, invoke that package's CLI with `use custom`.
If bundled is selected, `reload` leaves it alone.

## Migrate a standalone installation

For an older `custom-v*` installation, run the release installer once:

```sh
curl -fsSL https://github.com/lynnswap/swift-build/releases/latest/download/install.sh | sh
```

The installer checks the new CLI and moves an owned standalone selection to
Homebrew. It preserves bundled or separate local-build selections. The old
`~/.local/bin/custom-xcode-build-service` link follows the Homebrew launcher,
so existing absolute command paths keep working.

Migration keeps old payloads available to running services and does not stop
builds or service processes. No separate cleanup command is needed. Restart
Xcode, Xcode Service (for MCP), terminals, and AI agents if the selection changes.
On a fresh installation, select the service with `use custom`.

The installer's `--dry-run` reports the migration scope without running Homebrew
or changing files. Migration uses the existing installation lock and rollback
transaction. New releases use `v*` tags; existing `custom-v*` tags remain unchanged.

When setting up Homebrew directly, use the full CLI path shown in the README to
avoid an older command on `PATH`. That `use custom` call migrates the settings
and removes this tool's old standalone CLI link. Existing standalone payloads
remain available to running services.

## Configuration

Selecting custom sets these environment variables through `launchd`:

| Variable | Value |
| --- | --- |
| `XCBBUILDSERVICE_PATH` | `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle/SWBBuildServiceBundle`, expanded to an absolute path. |
| `DisableConcurrentDependencyResolution` | `0`, enabling parallel dependency resolution. |

The per-user bundle link points to the entire selected bundle, including its
resources and plugins. Homebrew owns the packaged files; the CLI does not copy
or remove them.

The login helper is stored at
`~/Library/LaunchAgents/io.github.lynnswap.custom-xcode-build-service.plist`.
Its presence records the custom selection, and its executable path records the
selected package. There is no separate selection file.

`use bundled` removes the service overrides and login helper. It works even when
the custom payload is missing. `uninstall` also removes owned user links and old
standalone files, while leaving the Homebrew package for `brew uninstall`.

## Try a local build

Select Xcode 27 with `xcode-select` or `DEVELOPER_DIR`, then run from the repository
root. Replace `/path/to/build` with a new output directory.

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
  --version v0.0.0-local --output-dir /path/to/build
```

This builds the committed `HEAD`; uncommitted changes are excluded.
Dependencies are pinned in `Distribution/ServiceDependencies.resolved`.
Building does not select or install the service.

Invoke the generated CLI to select it:

```sh
/path/to/build/payload/bin/custom-xcode-build-service use custom
```

Restart Xcode, Xcode Service, terminals, and AI agents. Keep the `payload`
directory while it is selected, including across logins.

To return to Homebrew, invoke its CLI and restart clients:

```sh
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
```

Run `use bundled` before deleting a selected local payload if you want to stop
using custom altogether.

Homebrew source builds use `--source-dir` and read the commit from the downloaded
Git archive, so they do not need a `.git` directory.

## SwiftPM

SwiftPM's Swift Build backend runs inside the SwiftPM process. Selecting Xcode's
build service does not replace that engine.

Platform plugins are loaded from the engine's own Xcode installation. Changing
`DEVELOPER_DIR` or `xcode-select` does not require reinstalling the Homebrew package.

## Tests

Run the management CLI and distribution tests from the repository root:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

To verify the installed package, select Xcode 27 or later and run:

```sh
brew test custom-xcode-build-service
```

This checks the CLI version, Xcode C builds, and SwiftPM build/run/test.
Xcode's Swift package manifest loader needs its own sandbox, so the Xcode package
tests run outside Homebrew's test sandbox.

`Distribution/test-homebrew.sh` runs both test sets after source installation
and again after bottle reinstallation. Service overrides are limited to test
child processes; the desktop selection is unchanged.

The compatibility CI tests one service artifact with installed stable Xcode 26/27
releases and the latest beta across `macos-26` and `xcode-27`. These are tested
combinations, not restrictions on the client Xcode version.
