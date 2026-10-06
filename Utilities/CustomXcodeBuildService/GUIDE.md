# Custom Xcode Build Service guide

[Back to README](README.md)

## Installation requirements

Homebrew and mise install the same prebuilt archive for Apple silicon and macOS
26 or later. Building the service from source requires Xcode 27 or later. The
release workflow builds once, then tests that artifact with multiple client Xcodes.

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

`Installed` and `Selected custom package` can differ when you use multiple mise versions, Homebrew,
or local builds. `Launchd selection` alone does not show which service an
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
Use `use custom --reload` to select it and stop the previously selected services
in one operation. Selecting the same package path again does not stop services;
use `reload` explicitly after replacing a local build or upgrading a Homebrew keg
behind the same `opt` path. If a stop fails, the new selection remains and the error reports
which processes could not be stopped. A failed selection does not stop services.
If bundled is selected, `reload` leaves it alone.

## Migrate a standalone installation

Install the desired release with Homebrew or mise, then invoke that package's
CLI with `use custom`. It migrates an owned standalone selection and removes
this tool's old `~/.local/bin/custom-xcode-build-service` link. Existing standalone
payloads remain available to running services. Finish builds before adding
`--reload` to stop those services after switching.

Use the full Homebrew CLI path from the README or `mise exec --` to avoid invoking
an older command through `PATH`. Restart clients if the selection changes from
bundled to custom. The migration uses the existing installation lock and rollback
transaction; it does not remove unrelated commands or configurations.

## Configuration

Selecting custom sets these environment variables through `launchd`:

| Variable | Value |
| --- | --- |
| `XCBBUILDSERVICE_PATH` | `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle/SWBBuildServiceBundle`, expanded to an absolute path. |
| `DisableConcurrentDependencyResolution` | `0`, enabling parallel dependency resolution. |

The per-user bundle link points to the entire selected bundle, including its
resources and plugins. Homebrew or mise owns the packaged files; the CLI does
not copy or remove them.

The login helper is stored at
`~/Library/LaunchAgents/io.github.lynnswap.custom-xcode-build-service.plist`.
Its presence records the custom selection, and its executable path records the
selected package. There is no separate selection file.

`use bundled` removes the service overrides and login helper. It works even when
the custom payload is missing. `uninstall` also removes owned user links and old
standalone files, while leaving package removal to Homebrew or mise.

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

## SwiftPM

SwiftPM's Swift Build backend runs inside the SwiftPM process. Selecting Xcode's
build service does not replace that engine.

Platform plugins are loaded from the engine's own Xcode installation. Changing
`DEVELOPER_DIR` or `xcode-select` does not require reinstalling the package.

## Tests

Run the management CLI and distribution tests from the repository root:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

`brew test custom-xcode-build-service` checks CLI version and help output. To run
Xcode C builds and SwiftPM build/run/test against an installed payload, use:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py verify-payload \
  --payload /path/to/package
```

For Homebrew, the payload is `$(brew --prefix custom-xcode-build-service)/libexec`;
for mise it is the directory reported by `mise where github:lynnswap/swift-build`.
Xcode's Swift package manifest loader needs its own sandbox, so these integration
tests run outside Homebrew's test sandbox.

`Distribution/test-homebrew.sh` and `Distribution/test-mise.py` install a candidate
archive and run the same payload checks. The Homebrew check requires a clean
Homebrew installation; it refuses to replace an existing keg. The mise check uses
temporary configuration and data directories. Service overrides are limited to
child processes, and neither check changes the desktop selection.

The compatibility CI tests one service artifact with installed stable Xcode 26/27
releases and the latest beta across `macos-26` and `xcode-27`. These are tested
combinations, not restrictions on the client Xcode version.
