# Custom Xcode Build Service

[日本語](README.ja.md)

Custom Xcode Build Service switches Xcode's build service to the Swift Build built
from this fork, [lynnswap/swift-build](https://github.com/lynnswap/swift-build). It
gives Xcode fixes and features that its bundled service does not have yet. See
[Releases](https://github.com/lynnswap/swift-build/releases) for the changes in
each version.

You switch with the `custom-xcode-build-service` command. The selection applies to
all projects of your macOS user account, in both GUI and Background launchd
environments, and stays after you log in again. Xcode itself is not modified.

Requirements:

- An Apple silicon Mac with macOS 26 or later
- Xcode (tested with Xcode 26, Xcode 27, and the latest beta)

Ways to get it:

- [Homebrew](#install-with-homebrew): use it on your Mac.
- [mise](#install-with-mise): pin the version in a project so that everyone uses
  the same one.
- [Local build](#build-and-use-a-local-version): try changes before they are
  released.

## Install with Homebrew

1. Install the package.

   ```sh
   brew install lynnswap/tap/custom-xcode-build-service
   ```

2. Select the Homebrew package.

   ```sh
   "$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
   ```

3. Restart Xcode, Xcode Service (for MCP), terminals, and AI agents.

## Install with mise

`mise.lock` pins the version and checksum, so everyone on the project uses the
same archive. Run the commands in the project directory (tested with mise
2026.10.3).

1. Add the tool to `mise.toml`. `X.Y.Z` is a
   [release](https://github.com/lynnswap/swift-build/releases) version without the
   leading `v`.

   ```toml
   [tools]
   "github:lynnswap/swift-build" = "X.Y.Z"
   ```

2. Create `mise.lock`.

   ```sh
   mise lock --platform macos-arm64 github:lynnswap/swift-build
   ```

   Check that the new entry has `provenance = "github-attestations"`. If it
   doesn't, compare `checksum` with the archive's line in the release's
   `SHA256SUMS.txt`.

3. Install and select it.

   ```sh
   mise install --locked github:lynnswap/swift-build
   mise exec -- custom-xcode-build-service use custom
   ```

4. Restart Xcode, Xcode Service (for MCP), terminals, and AI agents.
5. Commit `mise.toml` and `mise.lock`.

Installing does not change the selection. Other members run steps 3 and 4 on
their own Macs.

## Switching and restarting

- `use custom` selects the package that contains the command you run. `status`,
  `reload`, `use bundled`, and `uninstall` work the same from any installed copy.
- After switching between Xcode's service and the custom service, restart Xcode,
  Xcode Service (for MCP), terminals, and AI agents. Start terminal-based agents
  from a restarted terminal.
- If you use tmux, save your work and stop the existing server, then start a new
  server from the restarted terminal. Adding a pane does not update the server's
  environment.
- Switching from one custom package to another needs no restart.
  `use custom --reload` asks the previous service to exit, and the next request
  uses the new one.
- `reload` and `--reload` only ask the service to exit; they don't wait for it.
  Delete an old package only after the PIDs they print no longer appear in
  `status`.
- SwiftPM commands such as `swift build` are not affected.

If the command is not on your `PATH`, run it with `mise exec --` in the project
directory for mise, or by the full path of `payload/bin/custom-xcode-build-service`
for a local build.

## Check the selection

```sh
custom-xcode-build-service status
```

`Selected service: custom` means that the custom service is selected.
`Selected custom package` shows its version and path, and the `Source` line below
it shows the commit it was built from. See the
[guide](GUIDE.md#read-the-status-output) for how to read the running services.

## Update

Update after running builds finish. The steps below ask the running custom
service to exit. You don't need to restart Xcode. Retry any request that was
interrupted.

### Homebrew

If the Homebrew package is selected, run:

```sh
brew update
brew upgrade lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service reload
```

To switch to the Homebrew package from another package, run this instead of the
last line:

```sh
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom --reload
```

### mise

1. Change the version in `mise.toml`.
2. Run `mise lock --platform macos-arm64 github:lynnswap/swift-build`, and check
   the entry as you did when installing.
3. Install and select it.

   ```sh
   mise install --locked github:lynnswap/swift-build
   mise exec -- custom-xcode-build-service use custom --reload
   ```

4. Commit `mise.toml` and `mise.lock`. Other members run step 3 after they pull
   the change.

If a release causes problems, [switch back to Xcode's
service](#switch-back-to-xcodes-service), or set an earlier version with mise.
The Homebrew tap provides only the latest release.

## Build and use a local version

These steps make your everyday Xcode use your own build. To try uncommitted
changes without changing your selection, use the
[`launch-xcode`](../../README.md#with-xcode) or
[`run-xcodebuild`](../../README.md#with-xcodebuild) plugin instead.

Select Xcode 27 or later with `xcode-select` or `DEVELOPER_DIR`. The build includes
only committed files, so commit your changes first (a local branch is fine).

1. In the repository root, build the package.

   ```sh
   build_dir="$HOME/Library/Developer/CustomXcodeBuildServiceBuilds/$(git rev-parse --short HEAD)"
   python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
     --version v0.0.0-local --output-dir "$build_dir"
   ```

   The package is created in `$build_dir/payload`. If the build fails, delete
   `$build_dir` before you try again.

2. After running builds finish, select the local build.

   ```sh
   "$build_dir/payload/bin/custom-xcode-build-service" use custom --reload
   ```

   If Xcode's service was selected, [restart Xcode and the other
   apps](#switching-and-restarting).

Don't delete `$build_dir` while it is selected. The
[guide](GUIDE.md#local-build-options-and-checks) covers build options and how to
check a build before you select it.

### Rebuild after more changes

Commit the changes and repeat steps 1 and 2. The directory name includes the
commit, so each build gets its own directory. Delete the previous directory after
the PIDs that `--reload` printed no longer appear in `status`.

### Return to a release

Run `use custom --reload` with the release package's command. After the PIDs that
it printed no longer appear in `status`, delete the local build directories.

```sh
# Homebrew
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom --reload

# mise (in the project directory)
mise exec -- custom-xcode-build-service use custom --reload
```

## Switch back to Xcode's service

```sh
custom-xcode-build-service use bundled
```

Then [restart Xcode and the other apps](#switching-and-restarting). The package
stays installed.

## Uninstall

1. Quit Xcode and Xcode Service (for MCP), and wait for command-line builds and
   the custom service to exit. `uninstall` refuses to run while any of them is
   running ([how to check](GUIDE.md#read-the-status-output)).
2. Remove the settings and files that the command added, which switches back to
   Xcode's service.

   ```sh
   custom-xcode-build-service uninstall
   ```

3. Remove the package. If you remove it before step 2, Xcode cannot start the
   custom service.
   - Homebrew: `brew uninstall custom-xcode-build-service`
   - mise: `mise uninstall github:lynnswap/swift-build@X.Y.Z`. To remove the tool
     from the project too, run `mise unuse github:lynnswap/swift-build` and
     `mise lock`, then commit.
   - Local build: delete the build directory.
4. Restart terminals and AI agents.

## More information

- [Guide](GUIDE.md): how it works, reading `status`, troubleshooting, and tests
- [Release process](RELEASING.md), for maintainers
- `custom-xcode-build-service --help`: all commands
