# Custom Xcode Build Service

The Xcode build service from [lynnswap/swift-build](https://github.com/lynnswap/swift-build), distributed as the same binary through Homebrew and mise.

Requires an Apple silicon Mac, macOS 26 or later, and Xcode.

## Install with mise

Add the following to your project's `mise.toml`, replacing `X.Y.Z` with a
[published version](https://github.com/lynnswap/swift-build/releases):

```toml
[tools."github:lynnswap/swift-build"]
version = "X.Y.Z"
asset_pattern = "custom-xcode-build-service-darwin-arm64.tar.gz"
bin_path = "bin"
```

Generate the lockfile once and review its download URL and SHA-256. Commit
`mise.toml` and `mise.lock` together:

```sh
mise lock --platform macos-arm64 github:lynnswap/swift-build
mise install --locked github:lynnswap/swift-build
mise exec -- custom-xcode-build-service use custom
```

Other checkouts install with `mise install --locked github:lynnswap/swift-build`.
Only regenerate the lockfile when intentionally changing the version or artifact.

## Install with Homebrew

```sh
brew install lynnswap/tap/custom-xcode-build-service
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
```

After selecting custom for the first time, restart Xcode, Xcode Service (for MCP),
terminal apps, and AI agents. Start terminal-based agents from the restarted
terminal. Selection applies to your macOS user account and persists across logins.
A project's mise configuration does not automatically change Xcode's selection.

For an older `custom-v*` installation, either installation method's `use custom`
also migrates the saved selection and removes this tool's old CLI link.

## Upgrade

Finish builds before reloading the service.

With mise, update the version in `mise.toml`, regenerate and review the lockfile,
then select the newly installed package:

```sh
mise lock --platform macos-arm64 github:lynnswap/swift-build
mise install --locked github:lynnswap/swift-build
mise exec -- custom-xcode-build-service use custom --reload
```

With Homebrew, the existing selection follows the `opt` path across upgrades:

```sh
brew update
brew upgrade lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service reload
```

`use custom --reload` selects the invoked CLI's package and stops the previously
selected custom services. `reload` alone preserves the saved selection. Installing
or upgrading a package does not select it.

## Status

```sh
custom-xcode-build-service status
```

Shows the selected service, package versions, and running services.
With mise, run CLI commands through `mise exec --` if mise is not active in your shell.

## Restore Xcode's bundled service

```sh
custom-xcode-build-service use bundled
```

Restart the apps listed under [Install with Homebrew](#install-with-homebrew) after switching.

## Uninstall

Quit Xcode and other build clients, then run:

```sh
custom-xcode-build-service uninstall
```

Remove the package with its manager: `brew uninstall custom-xcode-build-service`
or `mise uninstall github:lynnswap/swift-build@X.Y.Z`. Remove the mise tool entry
and update its lockfile if the project no longer needs it. Restart terminal apps
and AI agents afterward. Select a replacement before deleting a selected version.

## Documentation

- [Detailed guide](GUIDE.md): status, migration, configuration, local builds, and tests.
- [Release process](RELEASING.md)

Run `custom-xcode-build-service --help` for all commands.
