# Custom Xcode Build Service

The Xcode build service from [lynnswap/swift-build](https://github.com/lynnswap/swift-build), distributed through Homebrew.

## Install

Requires an Apple silicon Mac, macOS 26 or later, Homebrew, and Xcode.

```sh
brew install lynnswap/tap/custom-xcode-build-service
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
```

After switching, restart Xcode, Xcode Service (for MCP), terminal apps, and AI agents.
Start terminal-based agents from the restarted terminal. The selection persists across logins.

## Upgrade

For an older `custom-v*` installation, [migrate to Homebrew](GUIDE.md#migrate-a-standalone-installation) first.

```sh
brew update
brew upgrade lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service reload
```

You do not need to run `use custom` again.

## Status

```sh
custom-xcode-build-service status
```

Shows the selected service, package versions, and running services.

## Restore Xcode's bundled service

```sh
custom-xcode-build-service use bundled
```

Restart the apps listed under [Install](#install) after switching.

## Uninstall

Quit Xcode and other build clients, then run:

```sh
custom-xcode-build-service uninstall
brew uninstall custom-xcode-build-service
```

Restart terminal apps and AI agents afterward.

## Documentation

- [Detailed guide](GUIDE.md): status, migration, configuration, local builds, and tests.
- [Release process](RELEASING.md)

Run `custom-xcode-build-service --help` for all commands.
