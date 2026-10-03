# Custom Xcode Build Service

Use this fork's Swift Build service with Xcode. Homebrew manages the CLI, service
bundle, resources, and upgrades. The CLI selects which service your macOS user
account uses, including after login.

## Install

```sh
brew install lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service use custom
```

Requires Apple silicon and macOS 26 or later. The tap builds bottles with Xcode 27
on the `xcode-27` runner (macOS 27). On macOS 26, Homebrew builds from source and
requires Xcode 27 or later. Xcode is also needed to run builds and the Formula test.
The Xcode version recorded in the manifest describes the build toolchain; it does
not restrict which client Xcode can use the service.

Installing or upgrading the Formula does not change your service selection.
`use custom` requires a logged-in desktop session. In an Aqua session it needs no
administrator authentication. From a Background session it requests `sudo` to
enter your desktop session, then drops administrator privileges before applying
your settings.

After first selecting custom, or switching between custom and bundled, restart
**Xcode, Xcode Service (for MCP), terminal applications, and AI agent applications**
so they inherit the selection. Xcode Service can outlive the Xcode or AI app UI.
Start terminal-based agents from the restarted terminal.

## Commands

| Command | What it does |
| --- | --- |
| `use custom` | Select this Homebrew service and restore it at login. |
| `use bundled` | Restore Xcode's service and remove the login helper and overrides. |
| `status` | Show the packaged version, saved selection, launchd settings, and running services. |
| `--version` | Print the packaged release version without accessing GUI settings. |
| `reload` | Restart this user's managed custom build services after an upgrade. |
| `uninstall` | Remove user settings and old standalone files; keep Homebrew files. |
| `activate` | Reapply custom at login if it is still selected. |

`status` reports the information it can read without requesting authentication.
From a Background session, use `sudo` with the full CLI path to also read GUI
settings. Partial inspection failures preserve the readable information and
produce a nonzero exit status. A missing payload does not prevent `use bundled`
or cleanup of owned settings.

## Upgrade

Finish builds before upgrading, then run:

```sh
brew upgrade custom-xcode-build-service
custom-xcode-build-service reload
```

The CLI and service bundle use Homebrew's stable `opt` path. The next launch uses
the upgraded service; already running services keep their loaded code until
reloaded. `reload` stops only this user's managed custom service processes, not
Xcode or MCP clients. Interrupted requests may need to be retried. If bundled is
selected, an upgrade preserves that selection and `reload` leaves it alone.

## Migrate a standalone installation

Older `custom-v*` releases installed a separate payload under your home directory.
Quit Xcode and finish command-line builds, then install the Formula and invoke
its CLI by full path to avoid an older command earlier on `PATH`:

```sh
brew install lynnswap/tap/custom-xcode-build-service
"$(brew --prefix)/bin/custom-xcode-build-service" uninstall
"$(brew --prefix)/bin/custom-xcode-build-service" use custom
```

Cleanup removes only the owned standalone payload, its `~/.local/bin` link, and
user settings. It preserves the Homebrew package. Restart clients afterward;
clients from the standalone installation can still retain old versioned paths.
New releases use tags such as `v0.3.0`; existing `custom-v*` tags remain unchanged.

## Uninstall

Restore the bundled service before removing the Formula:

```sh
custom-xcode-build-service use bundled
brew uninstall custom-xcode-build-service
```

Restart clients after switching. For complete removal of per-user links and old
standalone files, quit Xcode and finish command-line builds, then run the CLI's
`uninstall` command **before** `brew uninstall`.

## Configuration

While custom is selected, the CLI manages these launchd environment settings:

| Setting | Value |
| --- | --- |
| `XCBBUILDSERVICE_PATH` | `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle/SWBBuildServiceBundle`, expanded to an absolute path. |
| `DisableConcurrentDependencyResolution` | `0` (parallel dependency resolution). |

The per-user bundle link points to the whole Homebrew bundle, keeping resources
and plugins together. The CLI does not copy or remove the Homebrew payload.
A helper in `~/Library/LaunchAgents` reapplies custom at login. Its presence is
the saved selection; there is no second settings file. If macOS restores Xcode
before the helper runs, check `status` and restart Xcode.

SwiftPM's Swift Build backend continues to use its in-process engine. The host
plugin loads platform plugins from that engine's own Xcode installation. Changing
`DEVELOPER_DIR` or `xcode-select` does not require reinstalling the Formula.

## Development and verification

Build the committed `HEAD` with Xcode 27 into a directory you keep while using it:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
  --version v0.0.0-local --output-dir /path/to/build
/path/to/build/payload/bin/custom-xcode-build-service use custom
```

The build does not select or install the service. Switch to bundled before deleting
a selected local build. Homebrew source builds use `--source-dir` and read the
commit from the downloaded Git archive, so they do not need a `.git` directory.
Dependencies are pinned in `Distribution/ServiceDependencies.resolved`.

Run the management CLI and distribution tests from the repository root:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

`brew test custom-xcode-build-service` runs C builds, Swift tests through
`xcodebuild`, and SwiftPM build/run/test against the installed payload. It sets
service overrides only in test child processes; it does not change GUI selection.
The source CI builds one artifact and tests installed stable Xcode 26/27 releases
and the latest beta across `macos-26` and `xcode-27`. This matrix is test coverage,
not an Xcode installation allowlist.

## Releases

Prepare a Draft Release with reviewed notes, then push its `vX.Y.Z` tag to run the
[release workflow](../../.github/workflows/custom-xcode-build-service.yml).
Existing `custom-v*` tags do not trigger the new publication path. Stable tags
become Latest; prereleases do not replace Latest.

The workflow checks the public tag archive against the tagged Git commit and
publishes that source archive, `custom-xcode-build-service.rb`, and `SHA256SUMS.txt`
after build and compatibility checks. Internal binary archives are CI artifacts.
The old standalone installer is no longer published.

For the first Homebrew release, submit the generated Formula under `Formula/` in
[lynnswap/homebrew-tap](https://github.com/lynnswap/homebrew-tap). The public tag
archive must exist before bottle CI runs. The tap owns bottle builds and protected
publication; approve the tested Formula through its existing `homebrew-publish`
Environment. Its scoped Renovate configuration proposes later stable `v*` updates.
Changes to installation or tests require updating the recipe from this repository.
