# Custom Xcode Build Service release process

[Back to README](README.md)

## Publish a release

Before the first binary release, deploy the tap receiver and installation workflow
from [homebrew-tap #47](https://github.com/lynnswap/homebrew-tap/issues/47). The
currently published source recipe stays in place until this repository publishes
the binary release; its notification then proposes the replacement recipe.

Review the version, full commit SHA, title, and release notes, then start the
approved release from the repository root:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/publish_release.py start vX.Y.Z \
  --repo lynnswap/swift-build --target FULL_COMMIT_SHA --notes-file /path/to/notes.md
```

This creates or reuses the matching Draft and dispatches the
[release workflow](../../.github/workflows/custom-xcode-build-service-release.yml)
from the default branch. Local tag pushes do not start publication.

The workflow builds the approved commit once. It runs the management CLI tests,
checks Xcode compatibility, and installs the same archive through Homebrew and
mise on macOS 26. The mise check uses the GitHub backend with a local HTTP URL for
the unpublished candidate; it does not need a public tag or change desktop settings.

After these checks pass, review the Draft and artifact link in the summary and
approve `release-publish`. The publisher uploads those tested bytes, creates the
approved tag, verifies the uploaded digests, and publishes the release. The assets are:

- `custom-xcode-build-service-darwin-arm64.tar.gz`: CLI, service, resources, manifest, and licenses.
- `custom-xcode-build-service.rb`: Homebrew recipe for that archive.
- `SHA256SUMS.txt`: checksums of both files.

Enable [immutable releases](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
in this repository before publication. Uploads happen while the release is a Draft;
publication locks its tag and assets. Fixes ship under a new version.
Stable releases become Latest. Prereleases use the same checks and do not update
the stable tap or replace Latest.

## Deliver to Homebrew

After stable publication, the separate tap notification job requests
`release-publish` approval before using its GitHub App key. It dispatches
`update-formula.yml` in [lynnswap/homebrew-tap](https://github.com/lynnswap/homebrew-tap)
with the public version, commit, archive checksum, and recipe checksum.

The tap validates the public assets and proposes the recipe update. Its CI installs
the shared archive and tests the CLI before merging. It does not rebuild the service,
create a bottle, or notify this repository to resume publication.

A tap failure leaves the binary release available through mise. Inspect the tap
workflow before retrying **Start stable tap update** because a failed response may
still have accepted the dispatch. No binary rebuild or release replacement is needed.
Homebrew users receive the new version when its Formula update is merged.

## Recover a failed publication

Use GitHub Actions' **Re-run failed jobs** on the original release run. Successful
build and verification jobs, their artifact IDs, and checksums are reused. Artifacts
are retained for 35 days; GitHub's rerun window is 30 days. If either has expired,
start a new run with the same approved Draft and commit and verify its new candidate.

An upload or tag failure can leave partial Draft assets or the tag in place. The
publisher reports the remaining state, validates approval again, and retries only
the prepared release. An already published release is not overwritten. Changed
approval content requires a new reviewed request.

## Publication credentials

Register the source publication GitHub App on `swift-build` with **Contents: read
and write** and **Workflows: read and write**. Workflow permission is needed when
a release target introduces workflow changes. Store its Client ID in
`SOURCE_RELEASE_APP_CLIENT_ID` and PEM key in `SOURCE_RELEASE_APP_PRIVATE_KEY` in
the `release-publish` Environment.

Register the tap dispatch App on `homebrew-tap` with **Actions: read and write**.
Store `TAP_DISPATCH_APP_CLIENT_ID` and `TAP_DISPATCH_APP_PRIVATE_KEY` in the same
Environment. Each job requests a short-lived token restricted to its destination
repository and required permissions, and revokes it when finished.

Only approved publication and notification jobs receive the private keys. They
execute trusted scripts from the workflow's immutable commit. The build, test,
and installation jobs have read-only repository access and receive no App keys.
