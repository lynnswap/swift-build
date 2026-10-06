# Custom Xcode Build Service release process

[Back to README](README.md)

## Publish a release

Review the version, full commit SHA, title, and release notes, then start the
approved release from the repository root:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/publish_release.py start vX.Y.Z \
  --repo lynnswap/swift-build --target FULL_COMMIT_SHA --notes-file /path/to/notes.md
```

This creates or reuses the matching Draft and dispatches the
[release workflow](../../.github/workflows/custom-xcode-build-service-release.yml)
from the default branch. The workflow runs the distribution, CLI, and Xcode
compatibility checks against the approved commit, then prepares the public source
tag and assets automatically while the Release remains a Draft. Review the pinned
workflow code and prepared assets in the summary, then approve `release-publish`
for the job that uses the GitHub App private key to dispatch the tap update.
Tap notification and source publication each require approval before using their
App private key. The tap's Formula PR, bottle CI, publication,
and the source Release's installation checks then proceed automatically.
Local tag pushes do not start publication.

For a stable release, the matching Formula and bottle must be public in
[lynnswap/homebrew-tap](https://github.com/lynnswap/homebrew-tap). The tap owns bottle
builds and automatic publication after successful CI. Its Renovate configuration
proposes stable source-tag updates from that notification; installation, caveat, dependency, and test
changes also require syncing the generated recipe. Let the protected tap
publisher finish the Formula PR instead of merging it before bottle publication.

The source workflow installs the published bottle on macOS 26, checks its version
and source commit, and runs Xcode and SwiftPM smoke builds with that installed
payload. It then rechecks the tested Formula and bottle before publishing the
source archive, `custom-xcode-build-service.rb`, stable `install.sh`, and `SHA256SUMS.txt`. Stable
releases become Latest. Prereleases use isolated Formula/bottle checks and do not
require delivery through the stable tap or replace Latest. Binary archives remain
internal CI artifacts.

## Resume pending tap delivery

While tap delivery is pending, CI keeps the Draft and an immutable preparation
receipt. The
[resume workflow](../../.github/workflows/custom-xcode-build-service-resume.yml)
runs after the tap publishes the bottle and updates its Formula on `main`. The
tap's notification job requires `source-notification` approval before using its
dedicated App key to start this workflow.
Successful source-release completion also triggers the check, covering a tap
notification that arrives before source preparation finishes. There is no
scheduled polling. The workflow reruns delivery verification and its dependent
jobs after the matching bottle is public, reusing completed build and compatibility
checks. You can also dispatch it manually. Changed approval content,
failed installation checks, expired artifacts, and runs older than 30 days require
attention; the resume
workflow does not bypass them. Prepared artifacts are retained for 35 days.

## One-time tap dispatch setup

Register a private GitHub App under `lynnswap` with the repository permission
**Actions: read and write**, and install it on `homebrew-tap` only. Webhooks and
user authorization are not needed. The App only starts the tap's existing update
workflow; the tap uses its own token for PR creation and protected bottle
publication.

In swift-build's `release-publish` Environment, register the App's Client ID as the
variable `TAP_DISPATCH_APP_CLIENT_ID` and its PEM private key as the secret
`TAP_DISPATCH_APP_PRIVATE_KEY`:

```sh
gh variable set TAP_DISPATCH_APP_CLIENT_ID --repo lynnswap/swift-build \
  --env release-publish --body APP_CLIENT_ID
gh secret set TAP_DISPATCH_APP_PRIVATE_KEY --repo lynnswap/swift-build \
  --env release-publish < /path/to/app.private-key.pem
```

Only the approved tap-dispatch job receives the tap-dispatch App private key. It checks out
trusted code from the workflow's immutable commit, revalidates the approved Draft,
and requests a short-lived token restricted to `homebrew-tap` and `Actions: write`.
The token is revoked when the job ends. Authentication or notification failure
leaves the public source tag and prepared assets and reports the failed dispatch;
inspect tap Actions before retrying, since acceptance may be uncertain. Daily or
manual tap maintenance remains a recovery path. Bottle publication revalidates the same-repository
maintainer/bot PR, its successful CI, and the exact tested artifact before updating
the tap.

## Retry final publication

If only the final publisher failed after successful preparation and installed
bottle verification, dispatch
[Publish prepared custom build service release](../../.github/workflows/custom-xcode-build-service-publish-prepared.yml)
on `main` with the Draft ID and original preparation run ID. It checks the
canonical source workflow, successful checks, unchanged approved Draft/tag,
immutable source artifacts, and the exact Formula/bottle tested by installation.
After `release-publish` approval, it retries publication without another build or
changing the release target. Its App token also requests Actions read permission
to retrieve the original run's checks, artifacts, and installation evidence.
Changed delivery or a failed build/install check requires fresh verification.
The publisher reasserts the approved tag, target, and notes in the final API
request. Permission errors include GitHub's required-permission header when supplied.

## Source publication App permissions

Publishing a release whose target changes workflow files can require
**Workflows: read and write** in addition to **Contents: read and write**.
`GITHUB_TOKEN` cannot receive Workflows write permission. Install a private
GitHub App on `swift-build` with those permissions and **Actions: read** for
reusing prepared CI/artifacts, then register its Client ID as
`SOURCE_RELEASE_APP_CLIENT_ID` and its PEM key as `SOURCE_RELEASE_APP_PRIVATE_KEY`
in the `release-publish` Environment. The existing dispatch App can be used after
adding these permissions and installing it on this repository; each job requests
a token restricted to its destination repository and needed permissions.

The source publisher also uses `release-publish` approval before receiving its
key. It executes pinned trusted workflow code, validates the approved source and
assets, and requests a short-lived token for `swift-build` with Contents and
Workflows write permission. It never edits the approval content or executes
release-target code with that token. The App token is revoked when the job ends.

## Shared installer

The source packager reads `Distribution/installer.json` from the approved source
commit, fetches the shared installer at its full homebrew-tap revision, verifies
its SHA-256, and embeds it in `install.sh`. The generated installer uses macOS
Bash and downloads no extra migration code. Update the pin deliberately when
adopting shared changes. Stable publication requires the matching Homebrew
release, including this CLI's internal `__migrate-standalone` hook, before the
installer becomes public. Prereleases omit `install.sh` because they do not update
the stable tap.
