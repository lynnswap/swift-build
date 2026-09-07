[Custom Xcode Build Service](https://github.com/lynnswap/swift-build/tree/main/Utilities/CustomXcodeBuildService)

```sh
curl -fsSL https://github.com/lynnswap/swift-build/releases/download/custom-v0.1.2/install.sh | sh
```

### Bug Fixes

- Fixed failures in updates, reinstallation, uninstallation, status checks, and login activation caused by files generated during builds.
- Updating to a newer release and uninstalling now work even when an existing installation has missing or damaged files.
