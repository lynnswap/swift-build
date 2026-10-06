"""Release protocol tests; all GitHub writes are in-memory."""
import copy
import contextlib
import io
import hashlib
from pathlib import Path
import tempfile
import json
import subprocess
import tarfile
import unittest
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import publish_release as release

SHA = "a" * 40
OTHER = "b" * 40


def draft(**changes):
    value = dict(id=42, tag_name="v0.1.0", target_commitish=SHA,
                 name="First release", body="One\n\nTwo\n", prerelease=False,
                 draft=True, assets=[], html_url="https://github.com/example/project/releases/42")
    value.update(changes)
    return value


class FakeGitHub:
    repository = "example/project"

    def __init__(self, item=None):
        self.release = copy.deepcopy(item)
        self.tag = None
        self.calls = []
        self.dispatch_error = False
        self.publish_error = False
        self.tag_error = False
        self.after_tag = None
        self.before_publish = None
        self.older_page = False
        self.upload_error = False
        self.after_upload = None

    @property
    def writes(self):
        return [call for call in self.calls if call[1] != "GET"]

    def upload(self, tag, paths):
        self.calls.append(("upload", "POST", tag))
        self.release["assets"] = [dict(name=path.name, state="uploaded",
            digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()) for path in paths]
        if self.upload_error:
            self.release["assets"].pop()
            raise subprocess.CalledProcessError(1, "gh release upload")
        if self.after_upload:
            self.after_upload(self)

    def api(self, path, method="GET", data=None):
        self.calls.append((path, method, copy.deepcopy(data)))
        if path == "":
            return {"default_branch": "main"}
        if path.startswith("commits/"):
            return {"sha": path.split("/")[-1]}
        if path.startswith("git/ref/tags/"):
            if self.tag is None:
                raise release.APIError(404, "Not Found")
            return {"object": dict(type="commit", sha=self.tag)}
        if path.startswith("releases?"):
            if self.older_page and path.endswith("page=1"):
                return [draft(id=i, tag_name=f"old-{i}") for i in range(100)]
            return [copy.deepcopy(self.release)] if self.release else []
        if path == "releases" and method == "POST":
            self.release = dict(data, id=42, assets=[], html_url="https://github.com/example/project/releases/42")
            return copy.deepcopy(self.release)
        if path in ("actions/workflows/custom-xcode-build-service-release.yml/dispatches",
                    "actions/workflows/update-formula.yml/dispatches"):
            if self.dispatch_error:
                raise release.APIError(503, "Dispatch response unavailable")
            return None
        if path == "git/refs" and method == "POST":
            if self.tag_error:
                raise release.APIError(403, "Resource not accessible by integration: workflows permission required")
            self.tag = data["sha"]
            if self.after_tag:
                self.after_tag(self)
            return {"ref": data["ref"]}
        if path.startswith("releases/tags/"):
            return copy.deepcopy(self.release)
        if path == "releases/42":
            if method == "PATCH":
                if self.publish_error:
                    raise release.APIError(503, "Publication failed")
                if self.before_publish:
                    self.before_publish(self)
                self.release.update({key: value for key, value in data.items() if key != "make_latest"})
            return copy.deepcopy(self.release)
        raise AssertionError((path, method, data))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.release_dir = Path(directory.name)
        self.write_release()

    def write_release(self, tag="v0.1.0", sha=SHA):
        for path in self.release_dir.iterdir():
            path.unlink()
        names = release.asset_names(tag)
        for name in names[:-1]:
            (self.release_dir / name).write_text("verified " + name)
        with tarfile.open(self.release_dir / release.ARCHIVE, "w:gz") as archive:
            data = json.dumps(dict(version=tag, sourceRevision=sha)).encode()
            info = tarfile.TarInfo("manifest.json")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        (self.release_dir / names[-1]).write_text("".join(
            f"{hashlib.sha256((self.release_dir / name).read_bytes()).hexdigest()}  {name}\n"
            for name in names[:-1]))
        self.checksums_sha256 = hashlib.sha256((self.release_dir / names[-1]).read_bytes()).hexdigest()

    def published_source(self):
        source = FakeGitHub(draft())
        source.repository = "lynnswap/swift-build"
        self.publish(source, release.fingerprint(source.release))
        return source

    def tearDown(self):
        self.redirect.__exit__(None, None, None)

    def start(self, github, **overrides):
        values = dict(tag="v0.1.0", sha=SHA, title="First release",
                      notes="One\n\nTwo\n")
        values.update(overrides)
        release.start(github, **values)

    def publish(self, github, digest):
        release.publish(github, 42, SHA, digest, self.release_dir, self.checksums_sha256)

    def test_stable_release_notification_sends_the_published_binary_and_recipe_digests(self):
        github = FakeGitHub()
        source = self.published_source()
        with patch("publish_release.GitHub", return_value=source):
            release.dispatch_tap(github, source.repository, "v0.1.0")
        self.assertEqual(github.writes, [("actions/workflows/update-formula.yml/dispatches", "POST",
            dict(ref="main", inputs=dict(source_repository=source.repository, source_tag="v0.1.0",
                source_sha=SHA, source_sha256=hashlib.sha256((self.release_dir / release.ARCHIVE).read_bytes()).hexdigest(),
                formula_sha256=hashlib.sha256((self.release_dir / "custom-xcode-build-service.rb").read_bytes()).hexdigest())))])
        self.assertIsNone(github.tag)
        self.assertIsNone(github.release)

    def test_unpublished_or_replaced_source_cannot_start_a_tap_update(self):
        for mutation in (lambda g: g.release.update(draft=True),
                         lambda g: setattr(g, "tag", OTHER),
                         lambda g: g.release["assets"].pop(0)):
            source = self.published_source()
            mutation(source)
            github = FakeGitHub()
            with patch("publish_release.GitHub", return_value=source), self.assertRaises(release.ReleaseError):
                release.dispatch_tap(github, source.repository, "v0.1.0")
            self.assertEqual(github.writes, [])

    def test_prereleases_and_invalid_tags_do_not_notify_the_stable_tap(self):
        github = FakeGitHub()
        release.dispatch_tap(github, "lynnswap/swift-build", "v0.3.5-rc.1")
        for tag in ("custom-v0.3.4", "main", "v0.3.4\n", "v0.3.4; command"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.dispatch_tap(github, "lynnswap/swift-build", tag)
        self.assertEqual(github.calls, [])

    def test_failed_notification_preserves_the_public_release_without_retrying(self):
        source = self.published_source()
        github = FakeGitHub()
        github.dispatch_error = True
        with patch("publish_release.GitHub", return_value=source), self.assertRaisesRegex(
                release.ReleaseError, "Release v0.1.0 remains published"):
            release.dispatch_tap(github, source.repository, "v0.1.0")
        self.assertEqual(len(github.writes), 1)
        self.assertFalse(source.release["draft"])

    def test_start_keeps_notes_and_pins_dispatch_without_creating_tag(self):
        github = FakeGitHub()
        self.start(github)
        self.assertEqual(github.release, draft())
        self.assertIsNone(github.tag)
        self.assertEqual([call[0] for call in github.writes],
                         ["releases", "actions/workflows/custom-xcode-build-service-release.yml/dispatches"])
        dispatch = github.writes[-1][2]
        self.assertEqual(dispatch["ref"], "main")
        self.assertEqual(dispatch["inputs"], dict(
            release_id="42", target_sha=SHA, content_digest=release.fingerprint(draft())))

    def test_start_reuses_matching_draft_in_later_page(self):
        github = FakeGitHub(draft())
        github.older_page = True
        self.start(github)
        self.assertEqual(len(github.writes), 1)
        self.assertIn("dispatches", github.writes[0][0])

    def test_existing_content_or_published_release_is_not_overwritten(self):
        for changes in (dict(body="Changed"), dict(name="Changed"),
                        dict(target_commitish=OTHER), dict(prerelease=True), dict(draft=False)):
            with self.subTest(changes=changes):
                github = FakeGitHub(draft(**changes))
                with self.assertRaises(release.ReleaseError):
                    self.start(github)
                self.assertEqual(github.writes, [])

    def test_dispatch_failure_leaves_reusable_draft(self):
        github = FakeGitHub()
        github.dispatch_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Draft 42 remains"):
            self.start(github)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        github.dispatch_error = False
        self.start(github)
        self.assertEqual(sum(call[0] == "releases" for call in github.writes), 1)

    def test_branch_target_or_conflicting_tag_never_creates_draft(self):
        for target, tag in (("main", None), (SHA, OTHER)):
            github = FakeGitHub()
            github.tag = tag
            with self.assertRaises(release.ReleaseError):
                self.start(github, sha=target)
            self.assertEqual(github.writes, [])

    def test_annotated_tags_are_peeled(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=[
            {"object": {"type": "tag", "sha": OTHER}},
            {"object": {"type": "commit", "sha": SHA}},
        ]):
            self.assertEqual(release.check_tag(github, "v0.1.0", SHA), SHA)

    def test_lookup_failure_is_not_treated_as_missing_tag(self):
        github = FakeGitHub()
        with patch.object(github, "api", side_effect=release.APIError(403, "Forbidden")):
            with self.assertRaises(release.APIError):
                release.tag_commit(github, "v0.1.0")

    def test_verify_detects_content_target_and_tag_changes_without_writes(self):
        original = draft()
        for changes in (dict(body="Changed"), dict(name="Changed"), dict(prerelease=True),
                        dict(tag_name="v0.2.0"), dict(target_commitish=OTHER)):
            github = FakeGitHub(draft(**changes))
            with self.assertRaises(release.ReleaseError):
                release.verify(github, 42, SHA, release.fingerprint(original))
            self.assertEqual(github.writes, [])
        github = FakeGitHub(original)
        github.tag = OTHER
        with self.assertRaises(release.ReleaseError):
            self.publish(github, release.fingerprint(original))
        self.assertEqual(github.writes, [])

    def test_verify_ignores_unrelated_metadata_and_never_publishes(self):
        github = FakeGitHub(draft(updated_at="later", download_count=10))
        release.verify(github, 42, SHA, release.fingerprint(draft()))
        self.assertEqual(github.writes, [])
        self.assertTrue(github.release["draft"])

    def test_publish_creates_exact_tag_and_preserves_stable_or_prerelease_content(self):
        for prerelease in (False, True):
            tag = "v0.1.0-rc.1" if prerelease else "v0.1.0"
            self.write_release(tag)
            github = FakeGitHub(draft(tag_name=tag, prerelease=prerelease))
            digest = release.fingerprint(github.release)
            self.publish(github, digest)
            self.assertEqual(github.tag, SHA)
            self.assertFalse(github.release["draft"])
            self.assertEqual(release.fingerprint(github.release), digest)
            self.assertEqual(github.writes[1], ("git/refs", "POST", dict(ref="refs/tags/" + tag, sha=SHA)))
            self.assertEqual(github.writes[2][2], dict(
                tag_name=tag, target_commitish=SHA, name="First release",
                body="One\n\nTwo\n", prerelease=prerelease, draft=False,
                make_latest="false" if prerelease else "legacy"))

    def test_publish_writes_approved_fields_even_if_the_draft_changes_after_verification(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.before_publish = lambda state: state.release.update(
            name="Unapproved title", body="Unapproved notes", tag_name="v9.9.9",
            target_commitish=OTHER, prerelease=True)
        self.publish(github, digest)
        self.assertEqual(release.fingerprint(github.release), digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(github.tag, SHA)

    def test_publication_request_preserves_the_approved_tag_and_target(self):
        github = FakeGitHub(draft())
        github.tag = SHA
        self.publish(github, release.fingerprint(github.release))
        patch_request = next(call[2] for call in github.writes if call[1] == "PATCH")
        self.assertEqual(patch_request["tag_name"], "v0.1.0")
        self.assertEqual(patch_request["target_commitish"], SHA)
        self.assertEqual(github.release["tag_name"], "v0.1.0")
        self.assertEqual(github.release["target_commitish"], SHA)

    def test_unexpected_assets_stop_publication_without_removing_them(self):
        github = FakeGitHub(draft(assets=[{"id": 91, "name": "unapproved.zip"}]))
        with self.assertRaisesRegex(release.ReleaseError, "Remove unexpected draft assets"):
            self.publish(github, release.fingerprint(draft()))
        self.assertEqual(github.writes, [])
        self.assertEqual(github.release["assets"][0]["id"], 91)

    def test_failed_upload_leaves_draft_and_can_resume(self):
        github = FakeGitHub(draft())
        github.upload_error = True
        digest = release.fingerprint(draft())
        with self.assertRaisesRegex(release.ReleaseError, "Draft/assets or tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        github.upload_error = False
        self.publish(github, digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual({asset["name"] for asset in github.release["assets"]}, set(release.asset_names("v0.1.0")))

    def test_changed_uploads_stop_publication(self):
        def corrupt(state):
            state.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        def missing(state):
            state.release["assets"].pop()
        def extra(state):
            state.release["assets"].append(dict(name="unknown.zip"))
        def notes(state):
            state.release["body"] = "Unapproved notes"
        for mutation in (corrupt, missing, extra, notes):
            with self.subTest(mutation=mutation.__name__):
                github = FakeGitHub(draft())
                github.after_upload = mutation
                with self.assertRaises(release.ReleaseError):
                    self.publish(github, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])
                self.assertIsNone(github.tag)

    def test_start_classifies_prerelease_and_rejects_empty_notes(self):
        github = FakeGitHub()
        self.start(github, tag="v0.1.0-rc.1")
        self.assertTrue(github.release["prerelease"])
        github = FakeGitHub()
        with self.assertRaisesRegex(release.ReleaseError, "approved release notes"):
            self.start(github, notes="  ")
        self.assertEqual(github.writes, [])

    def test_failed_publication_can_resume_without_recreating_tag(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.publish_error = True
        with self.assertRaisesRegex(release.ReleaseError, "Draft/assets or tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertEqual(github.tag, SHA)
        github.publish_error = False
        self.publish(github, digest)
        self.assertFalse(github.release["draft"])
        self.assertEqual(sum(call[0] == "git/refs" for call in github.writes), 1)
        github.calls = []
        self.publish(github, digest)
        self.assertEqual(github.writes, [])

    def test_publication_is_independent_of_tap_availability(self):
        github = FakeGitHub(draft())
        with patch("publish_release.GitHub", side_effect=AssertionError("No tap lookup during publication")):
            self.publish(github, release.fingerprint(github.release))
        self.assertFalse(github.release["draft"])

    def test_changed_checked_artifact_stops_publication_before_writes(self):
        checked = self.checksums_sha256
        self.write_release(sha=OTHER)
        github = FakeGitHub(draft())
        with self.assertRaisesRegex(release.ReleaseError, "checksums file changed"):
            release.publish(github, 42, SHA, release.fingerprint(github.release), self.release_dir, checked)
        self.assertEqual(github.writes, [])

    def test_other_commit_or_version_cannot_be_published_as_the_approved_release(self):
        for tag, sha in (("v0.1.0", OTHER), ("v0.2.0", SHA)):
            self.write_release(tag, sha)
            github = FakeGitHub(draft())
            with self.assertRaisesRegex(release.ReleaseError, "approved version and commit"):
                self.publish(github, release.fingerprint(github.release))
            self.assertEqual(github.writes, [])

    def test_change_during_tag_creation_stops_publication(self):
        github = FakeGitHub(draft())
        github.after_tag = lambda state: state.release.update(body="Edited during CI")
        with self.assertRaises(release.ReleaseError):
            self.publish(github, release.fingerprint(draft()))
        self.assertTrue(github.release["draft"])
        self.assertEqual(len(github.writes), 2)

    def test_tag_permission_failure_preserves_draft_and_can_resume_after_fixing_rules(self):
        github = FakeGitHub(draft())
        digest = release.fingerprint(github.release)
        github.tag_error = True
        with self.assertRaisesRegex(release.ReleaseError, "GITHUB_TOKEN could not create the tested tag"):
            self.publish(github, digest)
        self.assertTrue(github.release["draft"])
        self.assertIsNone(github.tag)
        self.assertFalse(any(call[1] == "PATCH" for call in github.writes))
        github.tag_error = False
        self.publish(github, digest)
        self.assertEqual(github.tag, SHA)
        self.assertFalse(github.release["draft"])

    def test_racing_tag_creation_only_accepts_the_same_commit(self):
        for actual in (SHA, OTHER):
            github = FakeGitHub(draft())
            def create(state):
                state.tag = actual
                raise release.APIError(422, "Reference already exists")
            github.after_tag = create
            if actual == SHA:
                self.publish(github, release.fingerprint(draft()))
                self.assertFalse(github.release["draft"])
            else:
                with self.assertRaises(release.ReleaseError):
                    self.publish(github, release.fingerprint(draft()))
                self.assertTrue(github.release["draft"])

    def test_gh_transport_preserves_json_and_distinguishes_http_failure(self):
        github = release.GitHub("example/project")
        with patch("publish_release.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, 'HTTP/2.0 201 Created\nX: value\n\n{"id":42}', "")
            self.assertEqual(github.api("releases", "POST", {"body": "first\nsecond"}), {"id": 42})
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "first\nsecond"})
            run.return_value = subprocess.CompletedProcess([], 1, 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}', "")
            with self.assertRaises(release.APIError) as caught:
                github.api("releases/42")
            self.assertEqual(caught.exception.status, 404)
            run.return_value = subprocess.CompletedProcess([], 1,
                'HTTP/2.0 403 Forbidden\nX-Accepted-GitHub-Permissions: contents=write,workflows=write\n\n{"message":"Resource not accessible by integration"}', "")
            with self.assertRaisesRegex(release.APIError, "contents=write,workflows=write"):
                github.api("releases/42", "PATCH", {"draft": False})
            run.return_value = subprocess.CompletedProcess([], 0, "HTTP/2.0 204 No Content\nX: value\n\n", "")
            self.assertIsNone(github.api("actions/workflows/custom-xcode-build-service-release.yml/dispatches", "POST", {}))
            run.return_value = subprocess.CompletedProcess([], 0, 'HTTP/2.0 200 OK\n\n{"default_branch":"main"}', "")
            self.assertEqual(github.api("")["default_branch"], "main")
            self.assertEqual(run.call_args.args[0][-1], "repos/example/project")


if __name__ == "__main__":
    unittest.main()
