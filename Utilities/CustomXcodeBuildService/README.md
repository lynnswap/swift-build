# Custom Xcode Build Service

Use this fork's Swift Build service with Xcode. Homebrew manages the CLI, service
bundle, resources, and upgrades. The CLI selects which service your macOS user
account uses, including after login.

## Install

Install the CLI and service bundle through Homebrew:

```sh
brew install lynnswap/tap/custom-xcode-build-service
"$(brew --prefix lynnswap/tap/custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
```

Requires Apple silicon and macOS 26 or later. Homebrew installs a prebuilt bottle
on macOS 26 and later. The tap builds it with Xcode 27 on the `xcode-27` runner
(macOS 27), targeting macOS 26. Xcode 27 or later is required to build from source
and run the Formula test. Xcode is also needed to run builds using the service.
The Xcode version recorded in the manifest describes the build toolchain; it does
not restrict which client Xcode can use the service.

Installing or upgrading the Formula does not change your service selection.
Run setup with the Homebrew CLI's full path so an older command on `PATH` cannot
intercept it. `use custom` migrates the login helper and service settings and
removes this tool's old standalone CLI link. Existing standalone payloads remain
available to already running services.
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
| `use custom` | Select the payload packaged with this CLI and restore it at login. |
| `use bundled` | Restore Xcode's service and remove the login helper and overrides. |
| `status` | Show this CLI's packaged version, the selected custom payload, launchd settings, and running services. |
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

For a `custom-v*` standalone installation, run
[the release installer](#migrate-a-standalone-installation) first.

Finish builds before upgrading, then run:

```sh
brew update
brew upgrade lynnswap/tap/custom-xcode-build-service
custom-xcode-build-service reload
```

`brew update` refreshes the tap's Formula definitions. Homebrew offers a new
version after its Formula update is published in the tap.

When the Homebrew payload is selected, its stable `opt` path follows upgrades
without another `use custom`. The next launch uses the upgraded service; already
running services keep their loaded code until reloaded. `reload` and `activate`
preserve the saved custom payload selection, including a local build; only
`use custom` selects the payload packaged with the CLI you invoke. `reload` stops
only this user's managed custom service processes, not Xcode or MCP clients.
Interrupted requests may need to be retried. If bundled is selected, an upgrade
preserves that selection and `reload` leaves it alone.

## Migrate a standalone installation

Run the familiar installer once to switch an old `custom-v*` installation to
Homebrew:

```sh
curl -fsSL https://github.com/lynnswap/swift-build/releases/latest/download/install.sh | sh
```

The installer checks the new CLI and migrates an owned standalone selection to
the Homebrew payload. If bundled or a separate local build is selected, it keeps
that selection. The existing `~/.local/bin/custom-xcode-build-service` link now
follows Homebrew upgrades, so absolute command paths keep working. Fresh
installations still use `use custom` to select the service.

`--dry-run` reports the migration scope without running Homebrew or changing
files. Migration uses the existing installation lock and rollback transaction.
Old payloads remain available to running services; no build or service process
is stopped. Restart Xcode, Xcode Service (for MCP), terminals, and AI agents to
inherit a changed selection. No separate cleanup command is needed.
New releases use tags such as `v0.3.0`; existing `custom-v*` tags remain unchanged.

## Uninstall

Finish builds and quit Xcode and other build clients, then restore the bundled
service before removing the Formula:

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

The per-user bundle link points to the whole selected bundle, keeping resources
and plugins together. The CLI does not copy or remove the Homebrew payload.
A helper in `~/Library/LaunchAgents` reapplies custom at login. Its presence is
the saved custom selection, and its executable path records the selected payload;
there is no second settings file. In `status`, `Installed` describes this CLI's
payload and `Selected custom package` describes that saved selection. If macOS
restores Xcode before the helper runs, check `status` and restart Xcode.

SwiftPM's Swift Build backend continues to use its in-process engine. The host
plugin loads platform plugins from that engine's own Xcode installation. Changing
`DEVELOPER_DIR` or `xcode-select` does not require reinstalling the Formula.

## Development and verification

Select Xcode 27 with `xcode-select` or `DEVELOPER_DIR`, then build the committed
`HEAD` into a new output directory. Finish builds and quit Xcode and other build
clients before selecting the local payload:

```sh
python3 Utilities/CustomXcodeBuildService/Distribution/release.py build \
  --version v0.0.0-local --output-dir /path/to/build
/path/to/build/payload/bin/custom-xcode-build-service use custom
```

The build does not select or install the service. Keep the payload directory while
it is selected, including across logins, and restart clients after selection. To
switch back to Homebrew, finish builds and quit clients, then invoke its CLI:

```sh
"$(brew --prefix custom-xcode-build-service)/bin/custom-xcode-build-service" use custom
```

Restart clients before resuming builds. To stop using custom altogether, run
`use bundled` before deleting the selected local payload. Homebrew source builds
use `--source-dir` and read the commit from the downloaded Git archive, so they do
not need a `.git` directory.
Dependencies are pinned in `Distribution/ServiceDependencies.resolved`.

Run the management CLI and distribution tests from the repository root:

```sh
(cd Utilities/CustomXcodeBuildService && xcodebuild test \
  -scheme CustomXcodeBuildService -testPlan CustomXcodeBuildService \
  -destination 'platform=macOS,arch=arm64')
python3 -m unittest discover -s Utilities/CustomXcodeBuildService/Distribution/tests -p 'test_*.py'
```

`brew test custom-xcode-build-service` checks the CLI version, Xcode C builds,
and SwiftPM build/run/test against the installed payload. Xcode's Swift package
manifest loader needs its own sandbox, so those Xcode integration tests run
outside Homebrew's test sandbox. `Distribution/test-homebrew.sh` runs both sets
of tests after source installation and again after bottle reinstallation.
All service overrides are limited to test child processes; GUI selection is unchanged.
The source CI runs this verification script. Its compatibility jobs test
one service artifact with installed stable Xcode 26/27 releases and the latest beta
across `macos-26` and `xcode-27`. This matrix describes the tested combinations;
it does not restrict which client Xcode can use the service.

## Releases

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

While tap delivery is pending, CI keeps the Draft and an immutable preparation
receipt. The
[resume workflow](../../.github/workflows/custom-xcode-build-service-resume.yml)
checks every 15 minutes and reruns delivery verification and its dependent jobs
after the matching bottle is public. It reuses completed build and compatibility
checks. You can also dispatch that workflow manually. Changed approval content,
failed installation checks, expired artifacts, and runs older than 30 days require
attention; the resume
workflow does not bypass them. Prepared artifacts are retained for 35 days.

### One-time tap dispatch setup

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
inspect tap Actions before retrying, since acceptance may be uncertain. Periodic
discovery remains a recovery path. Bottle publication revalidates the same-repository
maintainer/bot PR, its successful CI, and the exact tested artifact before updating
the tap.

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

### Source publication App permissions

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

The source packager reads `Distribution/installer.json` from the approved source
commit, fetches the shared installer at its full homebrew-tap revision, verifies
its SHA-256, and embeds it in `install.sh`. The generated installer uses macOS
Bash and downloads no extra migration code. Update the pin deliberately when
adopting shared changes. Stable publication requires the matching Homebrew
release, including this CLI's internal `__migrate-standalone` hook, before the
installer becomes public. Prereleases omit `install.sh` because they do not update
the stable tap.
