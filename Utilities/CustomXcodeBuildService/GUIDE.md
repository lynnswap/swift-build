# Custom Xcode Build Service guide

[日本語](GUIDE.ja.md)

This guide covers details and troubleshooting. For installation, updates, and
local builds, see the [README](README.md).

## Read the status output

`custom-xcode-build-service status` reports on two packages: the package that
contains the command you ran and the selected package. They differ when you have
more than one package, such as Homebrew, several mise versions, or local builds.
For example, when you run the Homebrew command while a local build is selected,
the output begins like this:

```text
Installed: v0.5.2
  Source: 456d28b99d547ff959b9e696480ada246ef2318a
  Built with Xcode: 27.0 (27A266a)
Selected service: custom
Selected custom package: v0.0.0-local (/Users/you/Library/Developer/CustomXcodeBuildServiceBuilds/1a2b3c4/payload)
  Source: 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d
  Built with Xcode: 27.1 (27A9275)
```

| Line | Meaning |
| --- | --- |
| `Installed` | Version of the package that contains the command you ran |
| `Selected service` | Saved selection: `custom` or `bundled` |
| `Selected custom package` | Version and path of the selected package |
| `Source`, `Built with Xcode` | Indented under `Installed` or `Selected custom package`: the commit that package was built from and the Xcode used to build it |
| `Installed custom service` | Fixed path that Xcode starts the custom service from, through a link to the selected package |
| `Launchd selection` | Service selected in the GUI (`Aqua`) launchd environment for newly started processes |
| `XCBBUILDSERVICE_PATH`, `SWBBUILDSERVICE_PATH` | Current values in the GUI launchd environment |
| `Background launchd selection` | Service selected in the Background launchd environment for newly started processes |
| `Background XCBBUILDSERVICE_PATH`, `Background SWBBUILDSERVICE_PATH` | Current values in the Background launchd environment |
| `Login job` | Whether the LaunchAgent that reapplies the selection at login is loaded |
| `Running build services` | Build service processes of your user. The custom service has the `[managed custom service]` label. |

`Launchd selection` and `Background launchd selection` describe the environment
that launchd gives to newly started processes. Running apps, shells, and tmux
servers keep their existing environment. `Running build services` lists the
build service processes that are running. A process with the
`[managed custom service]` label was started from a custom package, but the list
does not show which package version the process loaded or which app started it.

If part of the inspection fails, `status` prints what it could read along with
the errors and exits with a nonzero status. `custom-xcode-build-service --version`
prints only the package version and does not read desktop settings.

## Files and settings that the command changes

`use custom` makes these changes for your user account:

| Item | Change |
| --- | --- |
| `XCBBUILDSERVICE_PATH` in the GUI and Background launchd environments | Set to `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle/SWBBuildServiceBundle`, expanded to an absolute path. Xcode starts the service from this path. |
| `~/Library/Developer/CustomXcodeBuildService/SWBBuildService.bundle` | Link to the whole service bundle of the selected package, including its resources and plugins |
| `~/Library/LaunchAgents/io.github.lynnswap.custom-xcode-build-service.plist` | LaunchAgent that runs `activate` at desktop login to reapply the selection in both launchd environments |

Every custom package uses the same service path; selecting another package only
changes the link. This is why switching between custom packages does not require
restarting apps.

The LaunchAgent is the only record of the selection. Its presence means that
custom is selected, and the command path in it identifies the selected package.
Homebrew or mise owns the package files; the command does not copy or delete
them.

`use bundled` removes `XCBBUILDSERVICE_PATH` from both launchd environments and
removes the LaunchAgent. It works even if the selected package has been deleted.
`uninstall` also removes the files that the command keeps in
`~/Library/Developer/CustomXcodeBuildService`, including
files left by older standalone versions, and the
`~/.local/bin/custom-xcode-build-service` link from those versions. The directory
itself stays with its `.lock` and `.owner` files. `uninstall` refuses to run while
Xcode, `xcodebuild`, or the custom service is running.

Earlier releases also set `DisableConcurrentDependencyResolution` to `0` in the
launchd environment, which overrode your `org.swift.swift-build` defaults.
`use custom`, `use bundled`, and `uninstall` remove that value and ask you to
restart apps, because apps that are already running keep it.

## Reload services

Running services keep the code that they loaded at startup. The following
commands stop the custom service so that Xcode starts the selected service again
on its next request. Xcode and MCP clients keep running, but builds and other
requests in progress are interrupted. Finish builds first, and retry any request
that was interrupted.

Both commands send a termination request to each process and print the PIDs. They
do not wait for the processes to exit. Before you delete the files of a previous
package, check that those PIDs no longer appear in `status`.

| Command | When to use it |
| --- | --- |
| `reload` | The selected package was replaced at the same path, for example by `brew upgrade` or by replacing a local build in place. The selection does not change. Nothing happens if Xcode's service is selected. |
| `use custom --reload` | You switch to another package. The command selects the package that contains it and stops the services of the previously selected package. If that package is already selected, nothing is stopped; use `reload` instead. |

If a process cannot be stopped, the new selection stays and the error lists the
processes. If selecting fails, no service is stopped. Installing or upgrading a
package never changes the selection.

After `brew upgrade`, a service that was already running keeps the previous
version's code until `reload` stops it or it exits. Homebrew deletes the previous
version's files during the upgrade by default, so run `reload` right after
upgrading.

## Select the service over SSH

`use custom`, `use bundled`, and `uninstall` update both the GUI and Background
launchd environments and require a logged-in macOS desktop session. In that
session, no administrator authentication is needed. From SSH or another
background session, the command asks for `sudo`, enters your desktop session, and
then applies the settings as your own user.

`status` never asks for authentication. To read the desktop settings from a
background session, run it with `sudo` and the full path:

```sh
sudo "$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" status
```

## Verify the mise archive

When `mise lock` creates the entry, mise checks the archive against the release's
GitHub attestation and records `provenance = "github-attestations"`. The
attestation is a signed record from GitHub that the archive belongs to this
repository's release. If the
entry has no `provenance` line, mise did not check the attestation, for example
because the check is turned off in its settings. In that case, compare
`checksum` with the archive's line in the release's `SHA256SUMS.txt`, or download
the archive from the release and check it with GitHub CLI:

```sh
gh release verify-asset vX.Y.Z custom-xcode-build-service-darwin-arm64.tar.gz -R lynnswap/swift-build
```

## Local build options and checks

Options of `release.py build`:

| Option | Description |
| --- | --- |
| `--version` | Version that `status` shows, in the form `v1.2.3` or `v1.2.3-label` |
| `--output-dir` | Directory for the source copy, build files, and `payload`. It must be new or empty. |
| `--revision` | Commit to build. The default is `HEAD`. |
| `--jobs` | Number of parallel build jobs. The default is 2. |

To check a build before you select it, run `verify-payload` against its
`payload` directory. Your selection does not change. The
[tests section](#test-the-command-and-the-distribution) describes what it checks.

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py verify-payload \
  --payload /path/to/build/payload
```

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| After you log in, Xcode uses its own service. | macOS can reopen Xcode before the LaunchAgent sets the environment. Run `status`, and if `Launchd selection` shows the custom service, restart Xcode. |
| `Background launchd selection` does not match the saved selection. | Run `use custom` or `use bundled` to reapply your choice to both launchd environments, then restart the clients. This also applies settings left unset by older releases. |
| MCP requests still use the previous service. | Xcode Service (for MCP) runs in the background and can keep running after you close Xcode or the AI app. When you restart apps after switching, quit Xcode Service as well, for example in Activity Monitor. |
| Builds in tmux still use the previous selection. | A running tmux server keeps its environment. Save your work and stop the existing server, then start a new server from a restarted terminal. Adding a pane does not update the server's environment. |
| The selected package was deleted, and Xcode cannot start the custom service. | Run `use bundled` with any copy of the command, such as a reinstalled Homebrew package. `use bundled` works without the selected package. The selection does not switch back by itself, because the LaunchAgent still points to the deleted command. |

## Migrate from a standalone installation

Older releases with `custom-v*` tags were installed with a standalone installer,
which put the command at `~/.local/bin/custom-xcode-build-service`. To move to
Homebrew or mise:

1. Install a current release with Homebrew or mise.
2. Run `use custom` with the new package's command. Use the full Homebrew path or
   `mise exec --` so that the old command on `PATH` is not used.
3. Restart Xcode, Xcode Service (for MCP), terminal apps, and AI agent apps.

`use custom` moves the selection to the new package and removes the old command
link. The old files stay so that running services keep working. To stop those
services right away, finish builds and run `use custom --reload` in step 2. If
the migration fails, the command rolls back its changes.

## Test the command and the distribution

Run these commands from the repository root.

Tests for the management command and the distribution scripts:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

`release.py verify-payload --payload <package>` runs smoke tests against an
installed package. It checks the layout and signatures, runs Xcode builds and
package tests with the package's service, and checks that `swift build`,
`swift run`, and `swift test` still work while the service path is set. SwiftPM
uses its own engine for these commands. Use one of these paths as `<package>`:

- Local build: `/path/to/build/payload`, where `/path/to/build` is the output
  directory of `release.py build`
- Homebrew: `$(brew --prefix custom-xcode-build-service)/libexec`
- mise: the directory that `mise where github:lynnswap/swift-build` prints

`brew test custom-xcode-build-service` checks only the version and help output.
Xcode's package manifest loader needs its own sandbox, so the Xcode integration
tests run in `verify-payload`, outside Homebrew's test sandbox.

To test the release archive, create the release assets from a local build:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py package \
  --build-dir /path/to/build --output-dir /path/to/release
```

Then run the scripts in `Utilities/CustomXcodeBuildService/Distribution` with the
release directory:

| Command | What it checks |
| --- | --- |
| `release.py verify --release-dir /path/to/release` | Checksums, archive layout, signatures, and smoke tests with the selected Xcode |
| `verify_xcodes.py --release-dir /path/to/release` | The same checks with each Xcode 26 and 27 release in `/Applications` and the latest beta |
| `test-homebrew.sh /path/to/release` | Installs the archive with Homebrew, then runs `verify-payload`. It refuses to run if the package is already installed. |
| `test-mise.py /path/to/release` | Installs the archive with mise in temporary directories, then runs `verify-payload` |

None of these checks change your selection. They set the service path only for
their child processes.

The service's dependencies are pinned in `Distribution/ServiceDependencies.resolved`.

CI builds one archive on the `xcode-27` runner for each pull request and release.
It tests that archive with Xcode 26, Xcode 27, and the latest beta on the
`macos-26` and `xcode-27` runners, and installs it with Homebrew and mise.
