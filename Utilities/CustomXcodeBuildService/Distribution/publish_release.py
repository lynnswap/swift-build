#!/usr/bin/env python3
"""Create an approved draft and dispatch CI, or verify/publish it from Actions."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
from urllib.parse import quote

from release import ARCHIVE, VERSION_PATTERN, asset_names


WORKFLOW = "custom-xcode-build-service-release.yml"


def verify_assets(root, tag, checksums_sha256=None, target=None):
    names = asset_names(tag)
    if {path.name for path in root.iterdir()} != set(names):
        raise ReleaseError("The prepared release asset set is not exact.")
    sums = root / "SHA256SUMS.txt"
    if checksums_sha256 and hashlib.sha256(sums.read_bytes()).hexdigest() != checksums_sha256:
        raise ReleaseError("The checksums file changed after verification.")
    expected = "".join(f"{hashlib.sha256((root / name).read_bytes()).hexdigest()}  {name}\n"
                       for name in names[:-1])
    if sums.read_text() != expected:
        raise ReleaseError("Prepared release checksums do not match.")
    with tarfile.open(root / ARCHIVE, "r:gz") as archive:
        manifest = json.load(archive.extractfile("manifest.json"))
    if manifest["version"] != tag or (target and manifest["sourceRevision"] != target):
        raise ReleaseError("The binary archive does not describe the approved version and commit.")

HOMEBREW_TAP = "lynnswap/homebrew-tap"


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, method="GET", data=None):
        command = ["gh", "api", "--include", "--method", method,
                   f"repos/{self.repository}/{path}".rstrip("/")]
        if data is not None:
            command += ["--input", "-"]
        result = subprocess.run(
            command, input=json.dumps(data) if data is not None else None,
            capture_output=True, text=True, check=False,
        )
        header, separator, body = result.stdout.partition("\n\n")
        if not separator or not header.startswith("HTTP/"):
            raise ReleaseError(result.stderr.strip() or "GitHub returned no HTTP response.")
        status = int(header.splitlines()[0].split()[1])
        payload = json.loads(body) if body.strip() else None
        if result.returncode or not 200 <= status < 300:
            message = payload.get("message", body) if isinstance(payload, dict) else body
            accepted = next((line.partition(":")[2].strip() for line in header.splitlines()
                             if line.lower().startswith("x-accepted-github-permissions:")), None)
            detail = f" Required permissions: {accepted}." if accepted else ""
            raise APIError(status, f"{method} {path}: {message}{detail}")
        return payload

    def upload(self, tag, paths):
        subprocess.run(
            ["gh", "release", "upload", tag, "--repo", self.repository,
             "--clobber", *map(str, paths)], check=True,
        )


def publication_fields(release):
    return {key: release[key] for key in
            ("tag_name", "target_commitish", "name", "body", "prerelease")}


def fingerprint(release):
    # Assets are produced by CI; approval covers only the publication content.
    content = dict(publication_fields(release), id=release["id"])
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def check_sha(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError("Use the full lowercase 40-character target commit SHA.")


def is_prerelease(tag):
    if not re.fullmatch(VERSION_PATTERN, tag):
        raise ReleaseError("Use a vX.Y.Z or vX.Y.Z-prerelease version tag.")
    return "-" in tag


def tag_commit(github, tag):
    try:
        entry = github.api("git/ref/tags/" + quote(tag, safe=""))
    except APIError as error:
        if error.status == 404:
            return None
        raise
    obj = entry["object"]
    while obj["type"] == "tag":
        obj = github.api("git/tags/" + obj["sha"])["object"]
    if obj["type"] != "commit":
        raise ReleaseError(f"Tag {tag} does not point to a commit.")
    return obj["sha"]


def check_tag(github, tag, sha):
    actual = tag_commit(github, tag)
    if actual is not None and actual != sha:
        raise ReleaseError(f"Tag {tag} points to {actual}, not approved commit {sha}.")
    return actual


def ensure_tag(github, tag, sha):
    if check_tag(github, tag, sha) is None:
        try:
            github.api("git/refs", "POST", dict(ref="refs/tags/" + tag, sha=sha))
        except APIError as error:
            if error.status != 422 or check_tag(github, tag, sha) is None:
                raise ReleaseError(
                    f"{error}\nGITHUB_TOKEN could not create the tested tag. Inspect tag rules "
                    "and workflow-file differences from the default branch before retrying. "
                    "Publication stopped; do not change the approved target without a new approval."
                ) from error


def matching_releases(github, tag):
    matches = []
    page = 1
    while True:
        releases = github.api(f"releases?per_page=100&page={page}")
        matches += [release for release in releases if release["tag_name"] == tag]
        if len(releases) < 100:
            return matches
        page += 1


def dispatch_tap(github, source_repository, tag):
    if is_prerelease(tag):
        print("Prereleases do not start stable tap updates.")
        return
    source = GitHub(source_repository)
    published = source.api("releases/tags/" + quote(tag, safe=""))
    if published["draft"] or published["prerelease"]:
        raise ReleaseError("Publish the stable binary release before notifying the tap.")
    sha = published["target_commitish"]
    check_sha(sha)
    if tag_commit(source, tag) != sha:
        raise ReleaseError("The published tag no longer matches its source commit.")
    assets = {asset["name"]: asset for asset in published["assets"]}
    def digest(name):
        asset = assets.get(name, {})
        value = asset.get("digest", "")
        if asset.get("state") != "uploaded" or not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
            raise ReleaseError(f"The published release has no verified asset digest: {name}")
        return value.removeprefix("sha256:")
    inputs = dict(source_repository=source_repository, source_tag=tag, source_sha=sha,
                  source_sha256=digest(ARCHIVE), formula_sha256=digest("custom-xcode-build-service.rb"))
    try:
        github.api("actions/workflows/update-formula.yml/dispatches", "POST", dict(ref="main", inputs=inputs))
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nRelease {tag} remains published and available through mise. "
            "Tap dispatch acceptance may be uncertain; inspect the tap's Actions runs before retrying."
        ) from error
    print(f"Tap update dispatch accepted for {source_repository} {tag}.")


def start(github, tag, sha, title, notes):
    check_sha(sha)
    prerelease = is_prerelease(tag)
    if not notes.strip():
        raise ReleaseError("Supply the approved release notes before starting publication.")
    if github.api("commits/" + sha)["sha"] != sha:
        raise ReleaseError("The target is not the requested commit.")
    branch = github.api("")["default_branch"]
    check_tag(github, tag, sha)
    matches = matching_releases(github, tag)
    if len(matches) > 1:
        raise ReleaseError(f"Multiple releases use {tag}; select the intended draft first.")
    requested = dict(tag_name=tag, target_commitish=sha, name=title,
                     body=notes, prerelease=prerelease)
    if matches:
        release = matches[0]
        if not release["draft"]:
            raise ReleaseError(f"{tag} is already published.")
        if any(release[key] != value for key, value in requested.items()):
            raise ReleaseError("The existing draft differs from the supplied target or content; it was not changed.")
    else:
        release = github.api("releases", "POST", dict(requested, draft=True))
    print(f"Draft: {release['html_url']}", flush=True)
    inputs = dict(release_id=str(release["id"]), target_sha=sha,
                  content_digest=fingerprint(release))
    try:
        github.api(f"actions/workflows/{WORKFLOW}/dispatches", "POST",
                   dict(ref=branch, inputs=inputs))
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nDraft {release['id']} remains. Dispatch acceptance may be uncertain; "
            "inspect Actions before retrying the same command."
        ) from error
    print(f"Target: {sha}")
    print("Release workflow dispatch accepted. Successful checks will publish this draft.")
    print(f"Actions: https://github.com/{github.repository}/actions/workflows/{WORKFLOW}")


def verify(github, release_id, sha, digest):
    check_sha(sha)
    release = github.api(f"releases/{release_id}")
    if release["target_commitish"] != sha or fingerprint(release) != digest:
        raise ReleaseError("The release target or approved content changed; publication stopped.")
    if release["prerelease"] != is_prerelease(release["tag_name"]):
        raise ReleaseError("The prerelease state does not match the version tag.")
    check_tag(github, release["tag_name"], sha)
    return release


def verify_uploaded_assets(release, expected):
    assets = release["assets"]
    if sorted(asset["name"] for asset in assets) != sorted(expected):
        raise ReleaseError("The uploaded release asset set is not exact.")
    for asset in assets:
        if asset["state"] != "uploaded" or asset.get("digest") != expected[asset["name"]]:
            raise ReleaseError(f"Uploaded asset does not match the verified file: {asset['name']}")


def publish(github, release_id, sha, digest, release_dir, checksums_sha256=None):
    release = verify(github, release_id, sha, digest)
    tag = release["tag_name"]
    if not release["draft"]:
        if tag_commit(github, tag) != sha:
            raise ReleaseError("The published release no longer has its approved tag.")
        print(f"Already published: {release['html_url']}")
        return
    names = asset_names(tag)
    unexpected = [asset["name"] for asset in release["assets"] if asset["name"] not in names]
    if unexpected:
        raise ReleaseError(f"Remove unexpected draft assets before retrying: {', '.join(unexpected)}")
    verify_assets(release_dir, tag, checksums_sha256, target=sha)
    paths = [release_dir / name for name in names]
    expected = {path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
                for path in paths}
    try:
        github.upload(tag, paths)
        release = verify(github, release_id, sha, digest)
        verify_uploaded_assets(release, expected)
        ensure_tag(github, tag, sha)
        # Tag creation and asset uploads are separate from publication on GitHub.
        release = verify(github, release_id, sha, digest)
        verify_uploaded_assets(release, expected)
        published = github.api(
            f"releases/{release_id}", "PATCH",
            dict(publication_fields(release), draft=False,
                 make_latest="false" if release["prerelease"] else "legacy"),
        )
    except (ReleaseError, subprocess.CalledProcessError) as error:
        raise ReleaseError(
            f"{error}\nDraft/assets or tag {tag} may remain; publication may be uncertain. "
            "Inspect the release and address the reported failure before retrying."
        ) from error
    if published["draft"] or fingerprint(published) != digest:
        raise ReleaseError("GitHub's publication response did not preserve the approved release.")
    verify_uploaded_assets(published, expected)
    print(f"Published: {published['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("start", help="Create/reuse a draft and start automatic publication")
    launch.add_argument("version")
    launch.add_argument("--target", required=True, help="Approved full commit SHA")
    launch.add_argument("--notes-file", required=True, type=Path)
    launch.add_argument("--title", help="Defaults to the version")
    launch.add_argument("--repo", required=True)
    assets = commands.add_parser("verify-assets", help="Check the tested binary release and its checksums")
    assets.add_argument("--version", required=True)
    assets.add_argument("--release-dir", required=True, type=Path)
    assets.add_argument("--checksums-sha256")
    notify = commands.add_parser("dispatch-tap", help="Start the tap update after stable binary publication")
    notify.add_argument("--source-repository", required=True)
    notify.add_argument("--version", required=True)
    for name in ("verify", "publish"):
        command = commands.add_parser(name, help="Internal Actions entry point")
        command.add_argument("--repo", required=True)
        command.add_argument("--release-id", required=True, type=int)
        command.add_argument("--target", required=True)
        command.add_argument("--digest", required=True)
        if name != "publish":
            command.add_argument("--github-output", type=Path)
        else:
            command.add_argument("--release-dir", required=True, type=Path)
            command.add_argument("--checksums-sha256", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "dispatch-tap":
            dispatch_tap(GitHub(HOMEBREW_TAP), arguments.source_repository, arguments.version)
            return 0
        if arguments.command == "verify-assets":
            verify_assets(arguments.release_dir, arguments.version, arguments.checksums_sha256)
            return 0
        github = GitHub(arguments.repo)
        if arguments.command == "start":
            start(github, arguments.version, arguments.target,
                  arguments.title or arguments.version,
                  arguments.notes_file.read_text(encoding="utf-8"))
        elif arguments.command != "publish":
            release = verify(github, arguments.release_id, arguments.target, arguments.digest)
            if arguments.github_output:
                with arguments.github_output.open("a", encoding="utf-8") as output:
                    output.write(f"version={release['tag_name']}\n")
                    output.write(f"prerelease={'true' if release['prerelease'] else 'false'}\n")
                    output.write(f"release_url={release['html_url']}\n")
            print(f"Verified: {release['html_url']} at {arguments.target}")
        else:
            publish(github, arguments.release_id, arguments.target, arguments.digest,
                    arguments.release_dir, arguments.checksums_sha256)
    except (ReleaseError, ValueError, KeyError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
